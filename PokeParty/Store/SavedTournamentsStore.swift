//
//  SavedTournamentsStore.swift
//  PokeParty
//
//  Persists completed Party Finder tournaments as a JSON file in Application
//  Support (same pattern as SavedTeamsStore). A full round robin is expensive
//  and the meta rarely changes, so a finished run is worth keeping around to
//  review later without re-simulating. Runs are deduplicated by configuration
//  (format + pool + field): re-running the same setup replaces the old result.
//

import Foundation
import SwiftUI

/// A completed tournament: its configuration, when it ran, and the final
/// leaderboard. `RankingFormat` is only Decodable, so the identifying fields
/// are stored flat and the format is rebuilt on demand.
nonisolated struct SavedTournament: Identifiable, Codable {
    var id = UUID()
    var date: Date
    var formatTitle: String
    var cup: String
    var cp: Int
    var poolSize: Int
    var fieldSize: Int
    var battlesFought: Int
    var teams: [TeamFinder.RankedTeam]

    var format: RankingFormat {
        RankingFormat(title: formatTitle, cup: cup, cp: cp, hideRankings: false, showFormat: nil)
    }

    /// True when `other` was run with the same configuration (and so should
    /// replace this run rather than sit beside it).
    func sameConfiguration(as other: SavedTournament) -> Bool {
        cup == other.cup && cp == other.cp
            && poolSize == other.poolSize && fieldSize == other.fieldSize
    }
}

@MainActor
@Observable
final class SavedTournamentsStore {

    private(set) var runs: [SavedTournament] = []

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
        let loaded: [SavedTournament] = await Task.detached(priority: .utility) { Self.load(from: url) }.value
        merge(loaded)
    }

    /// Synchronous fallback so a save/delete that races the async load never
    /// clobbers the file on disk with a partial list.
    private func loadNowIfNeeded() {
        guard !isLoaded else { return }
        merge(Self.load(from: fileURL))
    }

    private func merge(_ loaded: [SavedTournament]) {
        guard !isLoaded else { return }
        isLoaded = true
        let existingIDs = Set(runs.map(\.id))
        runs += loaded.filter { !existingIDs.contains($0.id) }
    }

    /// Saves a completed run, replacing any earlier run of the same
    /// configuration. Newest first.
    func save(_ run: SavedTournament) {
        loadNowIfNeeded()
        runs.removeAll { $0.sameConfiguration(as: run) }
        runs.insert(run, at: 0)
        persist()
    }

    func delete(_ run: SavedTournament) {
        loadNowIfNeeded()
        runs.removeAll { $0.id == run.id }
        persist()
    }

    // MARK: - Disk

    private static var defaultFileURL: URL {
        JSONFileStore.defaultFileURL(filename: "SavedTournaments.json")
    }

    nonisolated private static func load(from url: URL) -> [SavedTournament] {
        JSONFileStore.load(from: url)
    }

    private func persist() {
        guard let data = JSONFileStore.encode(runs) else { return }
        JSONFileStore.write(data, to: fileURL)
    }
}
