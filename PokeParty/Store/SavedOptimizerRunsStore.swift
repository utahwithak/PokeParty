//
//  SavedOptimizerRunsStore.swift
//  PokeParty
//
//  Persists completed AI Optimizer (hill-climbing) runs as a JSON file in
//  Application Support — same pattern as SavedTournamentsStore. A run's
//  climbers are expensive to converge and the meta rarely changes, so a
//  finished run is worth keeping around to review later without re-climbing.
//  Runs are deduplicated by configuration (format + pool + meta field +
//  restarts): re-running the same setup replaces the old result.
//

import Foundation
import SwiftUI

/// A completed AI Optimizer run: its configuration, when it ran, and the
/// resulting teams. `RankingFormat` is only Decodable, so the identifying
/// fields are stored flat and the format is rebuilt on demand (mirrors
/// `SavedTournament`).
nonisolated struct SavedOptimizerRun: Identifiable, Codable {
    var id = UUID()
    var date: Date
    var formatTitle: String
    var cup: String
    var cp: Int
    var poolSize: Int
    var metaSize: Int
    var restarts: Int
    /// Config needed to deterministically rebuild the exact candidate pool
    /// this run searched — `TeamOptimizer.buildPool` is a pure function of
    /// (entries, poolSize, cpCap, exploreAlternateMovesets, lockedMembers),
    /// so replaying it later with these values reproduces the same pool the
    /// saved `teams[].poolIndices` index into, without persisting the pool
    /// itself (a broad-field validation pass can then run on a reloaded run
    /// exactly as it would on a freshly completed one).
    var exploreAlternateMovesets: Bool
    var lockedMembers: [TeamMember]
    /// User-picked Pokémon the hill-climb was asked to weight teams strongly
    /// against (0–4) — not part of `TeamOptimizer.buildPool`'s inputs (it only
    /// shapes the meta field's scoring, not the candidate pool), so it isn't
    /// needed to replay a broad-field validation pass, but is kept here so a
    /// reloaded run can still show what it was optimized against.
    var strongAgainstMembers: [TeamMember] = []
    var teams: [TeamOptimizer.OptimizedTeam]
    /// The broad-field validation field size configured when this run was
    /// started, restored on `TeamFinderModel.load(_:)` so a later "Validate
    /// vs Full Meta" pass on a reloaded run uses the same size the run was
    /// set up with rather than whatever the slider happens to be at now.
    var broadFieldSize: Int = 3000

    var format: RankingFormat {
        RankingFormat(title: formatTitle, cup: cup, cp: cp, hideRankings: false, showFormat: nil)
    }

    /// True when `other` was run with the same configuration (and so should
    /// replace this run rather than sit beside it).
    func sameConfiguration(as other: SavedOptimizerRun) -> Bool {
        cup == other.cup && cp == other.cp
            && poolSize == other.poolSize && metaSize == other.metaSize && restarts == other.restarts
            && exploreAlternateMovesets == other.exploreAlternateMovesets
            && lockedMembers.map(\.speciesId) == other.lockedMembers.map(\.speciesId)
            && strongAgainstMembers.map(\.speciesId) == other.strongAgainstMembers.map(\.speciesId)
    }
}

@MainActor
@Observable
final class SavedOptimizerRunsStore {

    private(set) var runs: [SavedOptimizerRun] = []

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        // Decoding saved runs can be sizable JSON — kept off the main thread.
        Task { await load() }
    }

    private var isLoaded = false

    /// Reads the saved runs from disk off the main actor and merges them with
    /// anything already saved this session.
    func load() async {
        guard !isLoaded else { return }
        let url = fileURL
        let loaded: [SavedOptimizerRun] = await Task.detached(priority: .utility) { Self.load(from: url) }.value
        merge(loaded)
    }

    /// Synchronous fallback so a save/delete that races the async load never
    /// clobbers the file on disk with a partial list.
    private func loadNowIfNeeded() {
        guard !isLoaded else { return }
        merge(Self.load(from: fileURL))
    }

    private func merge(_ loaded: [SavedOptimizerRun]) {
        guard !isLoaded else { return }
        isLoaded = true
        let existingIDs = Set(runs.map(\.id))
        runs += loaded.filter { !existingIDs.contains($0.id) }
    }

    /// Saves a completed run, replacing any earlier run of the same
    /// configuration. Newest first.
    func save(_ run: SavedOptimizerRun) {
        loadNowIfNeeded()
        runs.removeAll { $0.sameConfiguration(as: run) }
        runs.insert(run, at: 0)
        persist()
    }

    func delete(_ run: SavedOptimizerRun) {
        loadNowIfNeeded()
        runs.removeAll { $0.id == run.id }
        persist()
    }

    // MARK: - Disk

    private static var defaultFileURL: URL {
        JSONFileStore.defaultFileURL(filename: "SavedOptimizerRuns.json")
    }

    nonisolated private static func load(from url: URL) -> [SavedOptimizerRun] {
        JSONFileStore.load(from: url)
    }

    private func persist() {
        guard let data = JSONFileStore.encode(runs) else { return }
        JSONFileStore.write(data, to: fileURL)
    }
}
