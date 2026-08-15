//
//  ScannerModel.swift
//  PokeParty
//
//  Observable model backing the scan sheet. Runs a continuous scan loop
//  (capture + OCR every few seconds) that feeds a "live" panel; the user
//  reviews/edits a copy of that data in a separate "staged" panel before
//  adding it to the bench, without interrupting the live loop.
//
//  Built on ScreenScanner, which captures the iPhone Mirroring window and
//  is macOS-only, so this whole file is unavailable on iOS.
//

#if os(macOS)

import Foundation
import SwiftUI
import Vision

@MainActor
@Observable
final class ScannerModel {

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
        var candidates: [IVCandidate]
    }

    struct IVCandidate: Identifiable {
        let id = UUID()
        let ivs: IVs
        let rank: Int
        let percent: Double
        let level: Double
        let cp: Int
    }

    /// The editable entry the user is about to add to the bench.
    struct StagedEntry {
        var speciesId: String?
        var ivs = IVs(atk: 15, def: 15, hp: 15)
        var cp: Int?
        /// Snapshot of the live scan's candidate list at the moment it was pulled down.
        var candidates: [IVCandidate] = []
    }

    // MARK: - State

    var liveStatus: LiveStatus = .idle
    var staged = StagedEntry()
    var selectedLeague: League = .great

    var isLiveScanning: Bool { liveTask != nil }

    // MARK: - Actions

    private let scanner = ScreenScanner()
    private var liveTask: Task<Void, Never>?

    /// Starts the continuous capture → OCR loop. Safe to call repeatedly;
    /// no-ops if already running.
    func startLiveScanning(store: RankingsStore) {
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

    func stopLiveScanning() {
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
            stopLiveScanning()
            liveStatus = .error("Screen Recording access failed. If you just granted permission, restart PokeParty — then tap Retry.")
        }
    }

    /// Recomputes the live panel's candidates after the user switches leagues,
    /// without waiting for the next scan-loop tick or re-running OCR.
    func recomputeLiveCandidates(store: RankingsStore) {
        guard case .found(var live) = liveStatus, let speciesId = live.speciesId else { return }
        live.candidates = computeCandidates(
            speciesId: speciesId, cp: live.cp, level: live.level, maxHP: live.maxHP, barIVs: live.barIVs, store: store
        )
        liveStatus = .found(live)
    }

    /// Copies the current live scan down into the editable staging panel.
    func pullDown() {
        guard case .found(let live) = liveStatus else { return }
        staged.speciesId = live.speciesId
        // A complete bar reading is the measured spread itself, so prefer it
        // over the top candidate — candidates are ordered by stat product, so
        // the best-ranked one within the bars' tolerance usually isn't the one
        // the bars actually showed.
        if let atk = live.barIVs?.atk, let def = live.barIVs?.def, let hp = live.barIVs?.hp {
            staged.ivs = IVs(atk: atk, def: def, hp: hp)
        } else if let top = live.candidates.first {
            staged.ivs = top.ivs
        }
        staged.cp = live.cp
        staged.candidates = live.candidates
    }

    /// The level implied by the staged CP + IVs — lets the user sanity-check
    /// a chosen IV spread against the level actually read off the phone.
    func stagedDerivedLevel(store: RankingsStore) -> Double? {
        guard let speciesId = staged.speciesId,
              let species = store.pokemonById[speciesId],
              let cp = staged.cp else { return nil }
        return IVCalculator.level(
            baseAtk: species.baseStats.atk, baseDef: species.baseStats.def, baseHp: species.baseStats.hp,
            ivs: staged.ivs, targetCP: cp
        )
    }

    /// Adds the staged entry to the bench, then clears the staging panel so
    /// the live loop can keep feeding the next Pokémon. The live scan loop is
    /// left running.
    @discardableResult
    func addStagedToBench(bench: BenchStore, store: RankingsStore) -> BenchEntry.ID? {
        guard let speciesId = staged.speciesId else { return nil }
        var entry = bench.addFromRankings(speciesId: speciesId, store: store, league: selectedLeague)
        entry.ivs = staged.ivs
        bench.update(entry)
        staged = StagedEntry()
        return entry.id
    }

    func clearStaged() {
        staged = StagedEntry()
    }

    // MARK: - Private

    private func computeCandidates(
        speciesId: String, cp: Int?, level: Double?, maxHP: Int?, barIVs: BarIVs?, store: RankingsStore
    ) -> [IVCandidate] {
        guard let species = store.pokemonById[speciesId] else { return [] }
        let combos = IVCalculator.rankedCombos(
            baseAtk: species.baseStats.atk,
            baseDef: species.baseStats.def,
            baseHp:  species.baseStats.hp,
            cpCap:   selectedLeague.cp
        )
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
                ivs:     combo.ivs,
                rank:    index + 1,
                percent: combo.statProduct / bestProduct * 100,
                level:   combo.level,
                cp:      combo.cp
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
