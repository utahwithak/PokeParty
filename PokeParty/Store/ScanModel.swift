//
//  ScanModel.swift
//  PokeParty
//
//  Observable model backing the Scan tool. Runs a continuous capture + OCR
//  loop against the iPhone Mirroring window and exposes the best currently-
//  known IVs for whatever Pokémon is on screen. Staging a bench pick (via a
//  tap on the IV grid) snapshots those IVs so the live loop can keep scanning
//  the next Pokémon without disturbing a pick still under review.
//
//  Built on ScreenScanner, which captures the iPhone Mirroring window and is
//  macOS-only, so this whole file is unavailable on iOS.
//

#if os(macOS)

import Foundation
import SwiftUI

@MainActor
@Observable
final class ScanModel {

    // MARK: - Types

    enum LiveStatus {
        case idle
        case scanning
        case found(LiveScan)
        case error(String)
    }

    /// A snapshot from one iteration of the live scan loop.
    struct LiveScan {
        var rawName: String
        var cp: Int?
        var level: Double?
        var maxHP: Int?
        var barIVs: BarIVs?
        var speciesId: String?
        /// Best-guess spreads when the bars can't be read cleanly, ranked by
        /// stat product; `.first` seeds `currentIVs` as a fallback.
        var candidates: [IVCandidate]
    }

    struct IVCandidate: Identifiable {
        let id = UUID()
        let ivs: IVs
        let rank: Int
        let percent: Double
    }

    /// One distinct Pokémon the live loop landed on — recorded so a session
    /// of auto-advancing through a box leaves a browsable trail behind.
    struct HistoryEntry: Identifiable {
        let id = UUID()
        var date: Date
        var speciesId: String?
        var speciesName: String
        var ivs: IVs
        var bestRank: RankHit?
    }

    /// A grid cell staged for the bench: species + chosen league + the IVs
    /// (and capture date) in effect at the moment it was tapped. Kept
    /// separate from the live loop so scanning the next Pokémon doesn't
    /// disturb a pick still under review; the IVs are editable afterward in
    /// case the scan misread them.
    struct StagedPick {
        var speciesId: String
        var speciesName: String
        var league: League
        var ivs: IVs
        var capturedDate: Date
        var shadow: Bool = false
    }

    // MARK: - State

    var liveStatus: LiveStatus = .idle
    var staged: StagedPick?
    /// Set when confirming `staged` would create a likely duplicate bench
    /// entry; cleared on any staging change or a forced add.
    var duplicateWarning: BenchEntry?

    /// Master toggle for auto-advance; off by default so Scan doesn't start
    /// swiping through the box unexpectedly the moment it's opened. Use
    /// `setAutoAdvance` rather than setting this directly so the
    /// paused-reason banner clears along with it.
    var autoAdvance: Bool = false
    /// Auto-advance stops swiping once the current Pokémon's best rank
    /// across Great/Ultra/Master League is at or better than this.
    var autoAdvanceThreshold: Int = 100
    /// Set when auto-advance pauses itself after finding a match at or
    /// better than `autoAdvanceThreshold`; cleared the next time a scan's
    /// best rank no longer qualifies (e.g. once the user manually swipes
    /// past it or catches it).
    var autoAdvancePausedReason: String?
    /// Set when the swipe gesture itself fails (e.g. missing Accessibility
    /// permission or no mirroring window) — kept separate from `liveStatus`
    /// so a swipe failure doesn't hide the Pokémon that was just found.
    var swipeError: String?
    /// True when `swipeError` is specifically the missing-Accessibility-
    /// permission case, so ScanView can offer a shortcut into System
    /// Settings rather than just showing the error text.
    var swipeErrorNeedsAccessibility = false

    /// Distinct Pokémon seen this session, most recent first.
    private(set) var history: [HistoryEntry] = []
    private static let maxHistory = 50

    func clearHistory() { history.removeAll() }

    func setAutoAdvance(_ enabled: Bool) {
        autoAdvance = enabled
        if !enabled { autoAdvancePausedReason = nil }
    }

    var isScanning: Bool { liveTask != nil }

    /// The best currently-known IV spread: bar readings when complete,
    /// otherwise the top guessed candidate, otherwise a neutral default.
    /// Callers that show this to the user (rank/percent displays, history)
    /// should check `hasResolvedIVs` first — the neutral default exists so
    /// staging/editing always has *some* value to bind to, not because it's
    /// a safe guess to display as though it were real.
    var currentIVs: IVs {
        guard case .found(let live) = liveStatus else { return IVs(atk: 15, def: 15, hp: 15) }
        if let atk = live.barIVs?.atk, let def = live.barIVs?.def, let hp = live.barIVs?.hp {
            return IVs(atk: atk, def: def, hp: hp)
        }
        return live.candidates.first?.ivs ?? IVs(atk: 15, def: 15, hp: 15)
    }

    /// Whether `currentIVs` reflects an actual reading — full bars, or at
    /// least one CP/HP-narrowed candidate — rather than the neutral
    /// 15/15/15 placeholder. A detail screen with no appraisal bars and no
    /// candidates narrowed down would otherwise silently display as a
    /// hundo (#1, 100%) with nothing to back it up.
    var hasResolvedIVs: Bool {
        guard case .found(let live) = liveStatus else { return false }
        if live.barIVs?.atk != nil, live.barIVs?.def != nil, live.barIVs?.hp != nil { return true }
        return live.candidates.first != nil
    }

    var currentSpeciesId: String? {
        guard case .found(let live) = liveStatus else { return nil }
        return live.speciesId
    }

    // MARK: - Scanning

    private let scanner = ScreenScanner()
    private var liveTask: Task<Void, Never>?

    /// One frame's OCR + bar reading, compared against the previous frame's
    /// to gate `liveStatus` updates on agreement rather than any single
    /// frame. A blurry or mid-swipe transitional frame reads *something*
    /// almost every time; requiring consecutive matching reads before
    /// treating a change as real means one bad frame can't flip the
    /// displayed Pokémon, trigger a false auto-advance, or spam history.
    private struct FrameReading: Equatable {
        var rawName: String
        var speciesId: String?
        var cp: Int?
        var level: Double?
        var maxHP: Int?
        var barIVs: BarIVs?
    }

    private var pendingReading: FrameReading?
    private var pendingStreak = 0
    private var missStreak = 0
    /// Consecutive matching (or failing) frames required before committing
    /// a change. At the ~3fps the frame stream runs, this adds well under
    /// a second of latency versus the old fixed-delay poll, while filtering
    /// out the transitional frame every swipe produces.
    private static let requiredStreak = 2

    /// Starts the continuous frame-stream → OCR loop. Safe to call
    /// repeatedly; no-ops if already running.
    func startScanning(store: RankingsStore) {
        guard liveTask == nil else { return }
        // Gate on the CoreGraphics screen-recording permission check. On macOS 15+
        // SCK can still fail even when this returns true (a process restart is
        // sometimes needed after first grant); runFrameLoop handles that by
        // stopping the loop so the OS dialog can't re-trigger automatically.
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            liveStatus = .error("Screen Recording permission is required. Grant access in System Settings, then tap Retry.")
            return
        }
        liveStatus = .scanning
        pendingReading = nil
        pendingStreak = 0
        missStreak = 0
        liveTask = Task { [weak self] in
            guard let self else { return }
            await self.runFrameLoop(store: store)
            self.liveTask = nil
        }
    }

    func stopScanning() {
        liveTask?.cancel()
        liveTask = nil
    }

    /// Consumes frames from `ScreenScanner`'s stream until cancelled or a
    /// fatal error. The mirroring window not existing yet is treated as
    /// recoverable — rather than making the user tap Retry once they open
    /// it, this waits a couple of seconds and tries again.
    private func runFrameLoop(store: RankingsStore) async {
        while !Task.isCancelled {
            do {
                let frames = try await scanner.startFrameStream()
                liveStatus = .scanning
                for try await image in frames {
                    await processFrame(image, store: store)
                }
                return // Stream ended normally (deliberate stop).
            } catch ScanError.windowNotFound {
                liveStatus = .error(ScanError.windowNotFound.localizedDescription)
                try? await Task.sleep(for: .seconds(2))
            } catch is CancellationError {
                return
            } catch let error as ScanError {
                liveStatus = .error(error.localizedDescription)
                return
            } catch {
                // Unexpected system error — most likely SCK access denied (on macOS 15+
                // the process sometimes needs a restart after first permission grant).
                // Stop outright so the OS dialog can't re-trigger automatically.
                liveStatus = .error("Screen Recording access failed. If you just granted permission, restart PokeParty — then tap Retry.")
                return
            }
        }
    }

    /// Runs OCR + bar reading on one streamed frame and, once the reading
    /// has agreed with itself for `requiredStreak` consecutive frames,
    /// commits it: updates `liveStatus`, records history, and considers
    /// auto-advance.
    private func processFrame(_ image: CGImage, store: RankingsStore) async {
        do {
            let observations = try await scanner.recognizeText(in: image)
            guard let info = await scanner.extractPokemonInfo(from: observations) else {
                registerMiss()
                return
            }

            let speciesId = fuzzyMatch(info.name, in: store.pokemonById)
            let barIVs = await scanner.extractBarIVs(from: observations, image: image)
            let reading = FrameReading(
                rawName: info.name, speciesId: speciesId, cp: info.cp,
                level: info.level, maxHP: info.maxHP, barIVs: barIVs)

            missStreak = 0
            if reading == pendingReading {
                pendingStreak += 1
            } else {
                pendingReading = reading
                pendingStreak = 1
            }
            // `==`, not `>=`: this block fires exactly once when a reading
            // first becomes stable. With `>=` it re-fired on every later
            // frame that still matched the same committed reading — while
            // sitting on an already-advanced Pokémon, each of those re-fired
            // `handleAutoAdvance`, so a swipe could go out again before the
            // first one's animation even finished (a double-swipe that skips
            // the next Pokémon in the box).
            guard pendingStreak == Self.requiredStreak else { return }

            let candidates = speciesId.map {
                computeCandidates(speciesId: $0, cp: info.cp, level: info.level, maxHP: info.maxHP, barIVs: barIVs, store: store)
            } ?? []

            liveStatus = .found(LiveScan(
                rawName: info.name, cp: info.cp, level: info.level, maxHP: info.maxHP, barIVs: barIVs,
                speciesId: speciesId, candidates: candidates
            ))
            recordHistory(store: store)
            await handleAutoAdvance(store: store)
        } catch {
            // Vision choked on this particular frame — rare, and no reason
            // to tear down the whole stream over it; treat like any other miss.
            registerMiss()
        }
    }

    /// After `requiredStreak` consecutive frames fail to read a Pokémon at
    /// all, surfaces the parse-failure error — but not on the first miss,
    /// since that's exactly what every swipe transition looks like for a
    /// frame or two.
    private func registerMiss() {
        pendingReading = nil
        pendingStreak = 0
        missStreak += 1
        guard missStreak >= Self.requiredStreak else { return }
        liveStatus = .error(ScanError.parseFailure.localizedDescription)
    }

    /// If auto-advance is on, swipes to the next Pokémon — but only once the
    /// scan has actually determined a species and IVs, never on a still-
    /// resolving or unrecognized read. Stops auto-advance outright (rather
    /// than a self-resuming pause) once the current Pokémon's best rank
    /// already meets `autoAdvanceThreshold`, so a good find can't start
    /// swiping again on its own — e.g. from a transient OCR blip — while
    /// the toggle is still nominally on and the mouse happens to be back
    /// over the window. Also holds off (without disabling the toggle) while
    /// the mouse is outside the mirroring window, since a swipe visibly
    /// relocates the real cursor and shouldn't yank it away from whatever
    /// else it's doing.
    private func handleAutoAdvance(store: RankingsStore) async {
        guard autoAdvance else { return }
        guard case .found(let live) = liveStatus, live.speciesId != nil else {
            // Species not resolved yet (mid-transition, garbled OCR, or an
            // unrecognized screen) — wait for a clean read before advancing.
            return
        }
        let barsComplete = live.barIVs?.atk != nil && live.barIVs?.def != nil && live.barIVs?.hp != nil
        guard barsComplete || !live.candidates.isEmpty else {
            // Species matched but no usable IV signal yet (bars unread and
            // no candidates narrowed down) — same as above, wait it out.
            return
        }
        guard let hit = bestRankHit(store: store) else { return }
        if hit.rank <= autoAdvanceThreshold {
            autoAdvancePausedReason = "Rank #\(hit.rank) in \(hit.league.title) League as \(hit.speciesName) — auto-advance stopped."
            autoAdvance = false
            return
        }
        guard await scanner.isMouseOverMirroringWindow() else {
            autoAdvancePausedReason = "Move the mouse back over iPhone Mirroring to resume auto-advance."
            return
        }
        autoAdvancePausedReason = nil
        if !(await performSwipe()) {
            // Swiping is broken (e.g. permission not granted) — stop
            // retrying and surfacing the same failure over and over.
            autoAdvance = false
        }
    }

    /// Appends a history entry when the live loop lands on a Pokémon
    /// different from the last one recorded — repeated idle re-scans of an
    /// unchanged screen (while waiting or paused) shouldn't spam the list.
    /// Requires a resolved species: OCR sometimes picks up incidental screen
    /// text (e.g. "Show off this Pokémon with a Catch") that fails to match
    /// any real Pokémon, and that shouldn't get logged as a scan at all.
    private func recordHistory(store: RankingsStore) {
        guard case .found(let live) = liveStatus, let speciesId = live.speciesId, hasResolvedIVs else { return }
        let ivs = currentIVs
        if let last = history.first, last.speciesId == speciesId, last.ivs == ivs { return }
        let name = store.pokemonById[speciesId]?.speciesName ?? live.rawName
        history.insert(HistoryEntry(
            date: .now, speciesId: speciesId, speciesName: name,
            ivs: ivs, bestRank: bestRankHit(store: store)), at: 0)
        if history.count > Self.maxHistory { history.removeLast() }
    }

    /// Fires the swipe-to-next gesture once, independent of auto-advance —
    /// backs the manual "Swipe to Next" button in ScanView.
    func advanceManually() {
        Task { [weak self] in
            await self?.performSwipe()
        }
    }

    /// Sends the swipe-to-next gesture, surfacing any failure via
    /// `swipeError` rather than `liveStatus`. Returns whether it succeeded.
    @discardableResult
    private func performSwipe() async -> Bool {
        do {
            try await scanner.swipeToNextPokemon()
            swipeError = nil
            swipeErrorNeedsAccessibility = false
            return true
        } catch ScanError.accessibilityDenied {
            swipeError = ScanError.accessibilityDenied.localizedDescription
            swipeErrorNeedsAccessibility = true
        } catch let error as ScanError {
            swipeError = error.localizedDescription
            swipeErrorNeedsAccessibility = false
        } catch {
            swipeError = "Couldn't send the swipe gesture: \(error.localizedDescription)"
            swipeErrorNeedsAccessibility = false
        }
        return false
    }

    struct RankHit {
        let rank: Int
        let league: CheckLeague
        /// Which evolution family member this rank belongs to — since IVs
        /// carry through evolution, the best rank often belongs to a
        /// different stage than whatever's currently on screen.
        let speciesName: String
    }

    /// The best (lowest-numbered) IV rank across the current scan's species
    /// and every later evolution (never an earlier stage — you can't
    /// devolve) across Great/Ultra/Master League, with the currently-known
    /// IVs. This mirrors every cell the Scan grid shows, so a great roll
    /// that only shows up once a Pokémon evolves (or only in Ultra/Master)
    /// is caught the same as a great roll on the current form/league.
    /// Exposed (not just used internally by auto-advance) so ScanView can
    /// show it continuously rather than only inside the paused-reason banner.
    func bestRankHit(store: RankingsStore) -> RankHit? {
        guard case .found(let live) = liveStatus, let sid = live.speciesId else { return nil }
        let ivs = currentIVs
        let level = determinedLevel(store: store)
        let cpm = level.flatMap { IVCalculator.cpm(forLevel: $0) }
        var best: RankHit?
        for pokemon in store.family(for: sid, excludingPreEvolutions: true) {
            // The optimal-build rank below assumes the Pokémon could be
            // leveled down to whatever fits a league's cap — but a scan
            // reports an actual, fixed CP. Skip leagues the Pokémon is
            // really over cap for right now, mirroring the eligibility
            // check IVLeagueGridView uses for its red-X cells.
            let nowCP = cpm.map {
                IVCalculator.cp(
                    baseAtk: pokemon.baseStats.atk, baseDef: pokemon.baseStats.def, baseHp: pokemon.baseStats.hp,
                    ivs: ivs, cpm: $0)
            }
            for league in [CheckLeague.great, .ultra, .master] {
                if let nowCP, nowCP > league.cap { continue }
                guard let result = IVRankCache.rank(
                    baseAtk: pokemon.baseStats.atk, baseDef: pokemon.baseStats.def, baseHp: pokemon.baseStats.hp,
                    cpCap: league.cap, ivs: ivs
                ) else { continue }
                if best == nil || result.rank < best!.rank {
                    best = RankHit(rank: result.rank, league: league, speciesName: pokemon.speciesName)
                }
            }
        }
        return best
    }

    /// Infers the actual current level from the scanned maxHP and known IVs.
    /// HP = floor(cpm × (baseHp + hpIV)) is an exact formula, so iterating
    /// the CPM table gives an exact level match; falls back to the OCR'd level.
    func determinedLevel(store: RankingsStore) -> Double? {
        guard case .found(let live) = liveStatus, let sid = live.speciesId,
              let species = store.pokemonById[sid] else { return nil }

        // Only reverse-solve from maxHP when the HP IV is an actual
        // reading — `currentIVs.hp` falls back to a neutral 15 when
        // nothing's resolved, and solving against that fake value
        // produces a level that looks exact but isn't backed by anything.
        if hasResolvedIVs, let maxHP = live.maxHP {
            let baseHpPlusIV = Double(species.baseStats.hp + currentIVs.hp)
            var matches: [Double] = []
            for (index, cpm) in IVCalculator.cpms.enumerated() {
                if Int((cpm * baseHpPlusIV).rounded(.down)) == maxHP {
                    matches.append(1.0 + Double(index) * 0.5)
                }
            }
            if !matches.isEmpty {
                if let sl = live.level {
                    return matches.min(by: { abs($0 - sl) < abs($1 - sl) })
                }
                return matches.first
            }
        }
        return live.level
    }

    // MARK: - Staging

    /// Snapshots the current live scan's species + IVs into a staged bench
    /// pick for the tapped league.
    func stage(pokemon: Pokemon, league checkLeague: CheckLeague) {
        guard let league = League(rawValue: checkLeague.cap) else { return }
        staged = StagedPick(
            speciesId: pokemon.speciesId, speciesName: pokemon.speciesName,
            league: league, ivs: currentIVs, capturedDate: .now,
            shadow: pokemon.isShadow)
        duplicateWarning = nil
    }

    func clearStaged() {
        staged = nil
        duplicateWarning = nil
    }

    /// Confirms the staged pick, adding it to the bench. If a likely
    /// duplicate exists (same evolution family + IVs + captured day) and
    /// `force` is false, sets `duplicateWarning` instead of adding — call
    /// again with `force: true` to add anyway.
    @discardableResult
    func confirmStaged(bench: BenchStore, store: RankingsStore, force: Bool = false) -> BenchEntry.ID? {
        guard let staged else { return nil }
        if !force, let dup = bench.duplicate(
            speciesId: staged.speciesId, ivs: staged.ivs, capturedDate: staged.capturedDate, store: store
        ) {
            duplicateWarning = dup
            return nil
        }
        let entry = bench.addFromScan(
            speciesId: staged.speciesId, ivs: staged.ivs, capturedDate: staged.capturedDate,
            shadow: staged.shadow, league: staged.league, store: store)
        self.staged = nil
        duplicateWarning = nil
        return entry.id
    }

    // MARK: - Private

    private func computeCandidates(
        speciesId: String, cp: Int?, level: Double?, maxHP: Int?, barIVs: BarIVs?, store: RankingsStore
    ) -> [IVCandidate] {
        guard let species = store.pokemonById[speciesId] else { return [] }
        // Master League's cap barely constrains the level climb for any real
        // Pokémon, so this is a league-agnostic best guess — the IV grid
        // separately ranks the resolved IVs per league once known.
        let combos = IVCalculator.rankedCombos(
            baseAtk: species.baseStats.atk,
            baseDef: species.baseStats.def,
            baseHp:  species.baseStats.hp,
            cpCap:   League.master.cp)
        let bestProduct = combos.first?.statProduct ?? 1.0

        // HP is a reliable OCR'd signal: given the actual level, it pins down
        // the HP IV exactly (or to a small set) via the CPM table, since
        // HP = floor(cpm * (baseHp + hpIV)).
        let hpIVs: Set<Int>? = {
            guard let maxHP, let level else { return nil }
            return possibleHpIVs(baseHp: species.baseStats.hp, maxHP: maxHP, level: level)
        }()

        // `combo.cp` (from `rankedCombos`) is each combo's CP at ITS OWN
        // best level under the Master cap — in practice close to level 51
        // — not at the Pokémon's actual current level. A freshly-caught
        // level-8 Wooper's CP143 has nothing to do with what that same IV
        // spread would be at level 51, so comparing against `combo.cp`
        // directly rejects nearly everything regardless of the true IVs.
        // Recomputing CP at the observed level fixes that; without a known
        // level there's no comparable CP to compute at all, so this signal
        // just doesn't apply rather than comparing the wrong thing.
        let observedCpm: Double? = level.flatMap { IVCalculator.cpm(forLevel: $0) }

        // Only report candidates when at least one narrowing signal was
        // actually applied — with no bars, no HP+level match, and no
        // CP+level match, every one of the 4096 combos would trivially
        // pass every `if let` check below, silently returning the global
        // top-20 by stat product with zero evidence behind them.
        guard hpIVs != nil || (cp != nil && observedCpm != nil)
            || barIVs?.atk != nil || barIVs?.def != nil || barIVs?.hp != nil
        else { return [] }

        // The Attack/Defense/HP fill bars give all three IVs directly (each
        // bar's fill fraction is that stat's IV / 15) — by far the strongest
        // signal, since CP alone can't distinguish atk/def IVs at all.
        // ±1 tolerance absorbs pixel-measurement/rounding noise.
        var candidates: [IVCandidate] = []
        for (index, combo) in combos.enumerated() {
            if let hpIVs, !hpIVs.contains(combo.ivs.hp) { continue }
            if let cp, let observedCpm {
                let atLevelCP = IVCalculator.cp(
                    baseAtk: species.baseStats.atk, baseDef: species.baseStats.def, baseHp: species.baseStats.hp,
                    ivs: combo.ivs, cpm: observedCpm)
                if abs(atLevelCP - cp) > 3 { continue }
            }
            if let barAtk = barIVs?.atk, abs(combo.ivs.atk - barAtk) > 1 { continue }
            if let barDef = barIVs?.def, abs(combo.ivs.def - barDef) > 1 { continue }
            if let barHp  = barIVs?.hp,  abs(combo.ivs.hp  - barHp)  > 1 { continue }
            candidates.append(IVCandidate(
                ivs: combo.ivs, rank: index + 1, percent: combo.statProduct / bestProduct * 100
            ))
            if candidates.count >= 20 { break }
        }
        return candidates
    }

    /// The HP IV value(s) consistent with a scanned max HP at a known level.
    /// Usually resolves to a single value since `cpm` steps are large enough
    /// that consecutive HP IVs land in different floor buckets.
    private func possibleHpIVs(baseHp: Int, maxHP: Int, level: Double) -> Set<Int>? {
        guard let cpm = IVCalculator.cpm(forLevel: level) else { return nil }
        var result: Set<Int> = []
        for hpIV in 0...15 {
            let computed = Int((cpm * Double(baseHp + hpIV)).rounded(.down))
            if computed == maxHP { result.insert(hpIV) }
        }
        return result.isEmpty ? nil : result
    }

    /// `normalized(pokemon.speciesName)` per species id, rebuilt only when the
    /// game master's Pokémon set changes size — `fuzzyMatch` runs on every
    /// ~1-2s scan tick, so refolding/diacritic-stripping every species name
    /// from scratch each time was needless repeated work against a set that
    /// only ever loads once per launch.
    private var normalizedNameCache: [String: String] = [:]

    private func normalizedNames(for pokemonById: [String: Pokemon]) -> [String: String] {
        if normalizedNameCache.count != pokemonById.count {
            normalizedNameCache = pokemonById.mapValues { normalized($0.speciesName) }
        }
        return normalizedNameCache
    }

    /// Fuzzy-matches a raw OCR string against every species name in the game master.
    /// Score 3 = exact, 2 = prefix, 1 = substring; returns the highest-scoring species id.
    private func fuzzyMatch(_ raw: String, in pokemonById: [String: Pokemon]) -> String? {
        let needle = normalized(raw)
        guard !needle.isEmpty else { return nil }
        var best: (id: String, score: Int)? = nil
        for (id, hay) in normalizedNames(for: pokemonById) {
            let score: Int
            if      hay == needle                                      { score = 3 }
            else if hay.hasPrefix(needle) || needle.hasPrefix(hay)     { score = 2 }
            else if hay.contains(needle)  || needle.contains(hay)      { score = 1 }
            else { continue }
            if best == nil || score > best!.score { best = (id, score) }
        }
        return best?.id
    }

    /// Folds diacritics before comparing — the game master stores some
    /// species names in plain ASCII ("Flabebe") while Pokémon GO's on-screen
    /// text uses the accented form ("Flabébé"). "é" (U+00E9) and "e" aren't
    /// the same Unicode scalar, so without folding, an otherwise-exact match
    /// silently fails every scoring tier and the species goes unmatched.
    ///
    /// The gender symbols get a *leading* space, not a bare letter — the
    /// game master spells Nidoran's forms out as "Nidoran Male"/"Nidoran
    /// Female", and mapping "♂" straight to "m" fuses it onto the previous
    /// word ("Nidoranm") with no token boundary, so it can never prefix-
    /// match "nidoran male" no matter how cleanly OCR reads the symbol.
    private func normalized(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "♀", with: " f")
            .replacingOccurrences(of: "♂", with: " m")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

#endif
