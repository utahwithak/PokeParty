//
//  SavedOptimizerRunsStore.swift
//  PokeParty
//
//  A completed AI Optimizer (hill-climbing) run, persisted (and synced across
//  the user's devices) by `SyncedRunsStore` — same pattern as
//  SavedTournamentsStore. A run's climbers are expensive to converge and the
//  meta rarely changes, so a finished run is worth keeping around to review
//  later without re-climbing. Runs are deduplicated by configuration (format
//  + pool + meta field + restarts): re-running the same setup replaces the
//  old result.
//

import Foundation

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
    /// exactly as it would on a freshly completed one). That only holds while
    /// the rankings data is unchanged, so `TeamFinderModel` checks the
    /// rebuilt pool against each team's stored members before validating
    /// (a run synced or shared from another device may predate a data update).
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
    /// Set when this run was imported from somebody else's shared file.
    var importedAt: Date? = nil

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

nonisolated extension SavedOptimizerRun: SyncedRun {
    static var kind: ResultsKind { .optimizerRun }
    static var folderName: String { "OptimizerRuns" }
    static var legacyFilename: String { "SavedOptimizerRuns.json" }
    var shareTitle: String { "\(formatTitle) AI Optimizer run" }
}

typealias SavedOptimizerRunsStore = SyncedRunsStore<SavedOptimizerRun>
