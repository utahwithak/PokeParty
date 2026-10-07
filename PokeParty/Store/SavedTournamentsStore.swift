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
struct SavedTournament: Identifiable, Codable {
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
        runs = Self.load(from: self.fileURL)
    }

    /// Saves a completed run, replacing any earlier run of the same
    /// configuration. Newest first.
    func save(_ run: SavedTournament) {
        runs.removeAll { $0.sameConfiguration(as: run) }
        runs.insert(run, at: 0)
        persist()
    }

    func delete(_ run: SavedTournament) {
        runs.removeAll { $0.id == run.id }
        persist()
    }

    // MARK: - Disk

    private static var defaultFileURL: URL {
        JSONFileStore.defaultFileURL(filename: "SavedTournaments.json")
    }

    private static func load(from url: URL) -> [SavedTournament] {
        JSONFileStore.load(from: url)
    }

    private func persist() {
        guard let data = JSONFileStore.encode(runs) else { return }
        JSONFileStore.write(data, to: fileURL)
    }
}
