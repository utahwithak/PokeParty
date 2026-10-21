//
//  SavedTournamentsStore.swift
//  PokeParty
//
//  A completed Party Finder tournament, persisted (and synced across the
//  user's devices) by `SyncedRunsStore`. A full round robin is expensive and
//  the meta rarely changes, so a finished run is worth keeping around to
//  review later without re-simulating. Runs are deduplicated by
//  configuration (format + pool + field): re-running the same setup replaces
//  the old result.
//

import Foundation

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
    /// Set when this run was imported from somebody else's shared file.
    var importedAt: Date? = nil

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

nonisolated extension SavedTournament: SyncedRun {
    static var kind: ResultsKind { .tournament }
    static var folderName: String { "Tournaments" }
    static var legacyFilename: String { "SavedTournaments.json" }
    var shareTitle: String { "\(formatTitle) tournament" }
}

typealias SavedTournamentsStore = SyncedRunsStore<SavedTournament>
