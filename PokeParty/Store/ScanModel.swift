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
    }

    // MARK: - State

    var liveStatus: LiveStatus = .idle
    var staged: StagedPick?
    /// Set when confirming `staged` would create a likely duplicate bench
    /// entry; cleared on any staging change or a forced add.
    var duplicateWarning: BenchEntry?

    var isScanning: Bool { liveTask != nil }

    /// The best currently-known IV spread: bar readings when complete,
    /// otherwise the top guessed candidate, otherwise a neutral default.
    var currentIVs: IVs {
        guard case .found(let live) = liveStatus else { return IVs(atk: 15, def: 15, hp: 15) }
        if let atk = live.barIVs?.atk, let def = live.barIVs?.def, let hp = live.barIVs?.hp {
            return IVs(atk: atk, def: def, hp: hp)
        }
        return live.candidates.first?.ivs ?? IVs(atk: 15, def: 15, hp: 15)
    }

    var currentSpeciesId: String? {
        guard case .found(let live) = liveStatus else { return nil }
        return live.speciesId
    }

    // MARK: - Scanning

    private let scanner = ScreenScanner()
    private var liveTask: Task<Void, Never>?

    /// Starts the continuous capture → OCR loop. Safe to call repeatedly;
    /// no-ops if already running.
    func startScanning(store: RankingsStore) {
        guard liveTask == nil else { return }
        // Gate on the CoreGraphics screen-recording permission check. On macOS 15+
        // SCK can still fail even when this returns true (a process restart is
        // sometimes needed after first grant); performOneScan handles that by
        // stopping the loop so the OS dialog can't re-trigger automatically.
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            liveStatus = .error("Screen Recording permission is required. Grant access in System Settings, then tap Retry.")
            return
        }
        liveStatus = .scanning
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.performOneScan(store: store)
                try? await Task.sleep(for: .seconds(4.5))
            }
        }
    }

    func stopScanning() {
        liveTask?.cancel()
        liveTask = nil
    }

    private func performOneScan(store: RankingsStore) async {
        do {
            let image = try await scanner.capturePhoneMirroringFrame()
            let observations = try await scanner.recognizeText(in: image)

            guard let info = await scanner.extractPokemonInfo(from: observations) else {
                liveStatus = .error(ScanError.parseFailure.localizedDescription)
                return
            }

            let speciesId = fuzzyMatch(info.name, in: store.pokemonById)
            let barIVs = await scanner.extractBarIVs(from: observations, image: image)

            let candidates = speciesId.map {
                computeCandidates(speciesId: $0, cp: info.cp, level: info.level, maxHP: info.maxHP, barIVs: barIVs, store: store)
            } ?? []

            liveStatus = .found(LiveScan(
                rawName: info.name, cp: info.cp, level: info.level, maxHP: info.maxHP, barIVs: barIVs,
                speciesId: speciesId, candidates: candidates
            ))
        } catch let error as ScanError {
            // Transient: no mirroring window or parse failure — keep looping.
            liveStatus = .error(error.localizedDescription)
        } catch {
            // Unexpected system error — most likely SCK access denied (on macOS 15+
            // the process sometimes needs a restart after first permission grant).
            // Stop the loop immediately so the OS dialog can't re-trigger.
            stopScanning()
            liveStatus = .error("Screen Recording access failed. If you just granted permission, restart PokeParty — then tap Retry.")
        }
    }

    /// Infers the actual current level from the scanned maxHP and known IVs.
    /// HP = floor(cpm × (baseHp + hpIV)) is an exact formula, so iterating
    /// the CPM table gives an exact level match; falls back to the OCR'd level.
    func determinedLevel(store: RankingsStore) -> Double? {
        guard case .found(let live) = liveStatus, let sid = live.speciesId,
              let species = store.pokemonById[sid] else { return nil }

        if let maxHP = live.maxHP {
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
            league: league, ivs: currentIVs, capturedDate: .now)
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
            league: staged.league, store: store)
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

        // The Attack/Defense/HP fill bars give all three IVs directly (each
        // bar's fill fraction is that stat's IV / 15) — by far the strongest
        // signal, since CP alone can't distinguish atk/def IVs at all.
        // ±1 tolerance absorbs pixel-measurement/rounding noise.
        var candidates: [IVCandidate] = []
        for (index, combo) in combos.enumerated() {
            if let hpIVs, !hpIVs.contains(combo.ivs.hp) { continue }
            if let cp, abs(combo.cp - cp) > 3 { continue }
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

    /// Fuzzy-matches a raw OCR string against every species name in the game master.
    /// Score 3 = exact, 2 = prefix, 1 = substring; returns the highest-scoring species id.
    private func fuzzyMatch(_ raw: String, in pokemonById: [String: Pokemon]) -> String? {
        let needle = normalized(raw)
        guard !needle.isEmpty else { return nil }
        var best: (id: String, score: Int)? = nil
        for (id, pokemon) in pokemonById {
            let hay = normalized(pokemon.speciesName)
            let score: Int
            if      hay == needle                                      { score = 3 }
            else if hay.hasPrefix(needle) || needle.hasPrefix(hay)     { score = 2 }
            else if hay.contains(needle)  || needle.contains(hay)      { score = 1 }
            else { continue }
            if best == nil || score > best!.score { best = (id, score) }
        }
        return best?.id
    }

    private func normalized(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "♀", with: "f")
            .replacingOccurrences(of: "♂", with: "m")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

#endif
