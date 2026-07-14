//
//  TeamFinderModel.swift
//  PokeParty
//
//  Observable state for the 3v3 Party Finder. Picks a format (independent of
//  the sidebar selection), loads that format's rankings, builds a candidate
//  pool from the top of the list, and runs the `TeamFinder` round-robin
//  tournament — publishing live `Standings` snapshots so the leaderboard
//  animates as battles resolve. Completed runs are saved automatically so
//  an expensive tournament can be reviewed later without re-simulating.
//

import SwiftUI

@MainActor
@Observable
final class TeamFinderModel {

    enum Phase: Equatable {
        case idle
        case loadingRankings
        case searching
        case done
        case failed(String)
    }

    /// The format whose meta to build teams from (defaults to Great League;
    /// switchable to any core league or active cup).
    var format: RankingFormat = .great
    /// How many of the format's top-ranked Pokémon form the candidate pool.
    var poolSize: Int = 15
    static let poolSizes = [10, 15, 20, 25, 50, 75, 100, 125, 150, 200]

    /// How many coverage-seeded teams enter the round robin (slider-driven;
    /// the tournament fights fieldSize·(fieldSize−1)/2 battles).
    var fieldSize: Int = 500
    static let fieldSizeRange = 100.0...10000.0
    static let fieldSizeStep = 100.0

    /// Completed runs, persisted across launches.
    let savedTournaments = SavedTournamentsStore()

    private(set) var phase: Phase = .idle
    /// Seeding progress, 0…1 — the pairwise 1v1 matrix + field shortlist
    /// (meaningful while `phase == .searching` and `standings == nil`).
    private(set) var progress: Double = 0
    /// Live tournament snapshot; nil until seeding completes. Stays populated
    /// after the run (and after a cancel) so the leaderboard remains browsable.
    private(set) var standings: TeamFinder.Standings?
    /// Final ranked teams (set when the tournament completes).
    private(set) var results: [TeamFinder.RankedTeam] = []
    /// The format and pool size the current run was started with.
    private(set) var resultsFormat: RankingFormat?
    private(set) var resultsPoolSize = 0

    private var searchTask: Task<Void, Never>?

    var isRunning: Bool { phase == .loadingRankings || phase == .searching }

    /// Battles a full round robin of the current field size will fight.
    var estimatedBattles: Int { fieldSize * (fieldSize - 1) / 2 }

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        if isRunning { phase = standings == nil ? .idle : .done }
    }

    /// Shows a previously saved tournament in the leaderboard.
    func load(_ run: SavedTournament) {
        guard !isRunning else { return }
        results = run.teams
        resultsFormat = run.format
        resultsPoolSize = run.poolSize
        standings = TeamFinder.Standings(
            teams: run.teams,
            totalEntrants: run.fieldSize,
            battlesFought: run.battlesFought, totalBattles: run.battlesFought,
            round: max(run.fieldSize - 1, 0), totalRounds: max(run.fieldSize - 1, 0),
            isComplete: true)
        phase = .done
    }

    /// Loads the chosen format's rankings and runs the tournament.
    func run(using store: RankingsStore) {
        searchTask?.cancel()
        let format = format
        let poolSize = poolSize
        let fieldSize = fieldSize
        let movesById = store.movesById
        let pokemonById = store.pokemonById

        phase = .loadingRankings
        progress = 0
        results = []
        standings = nil
        resultsFormat = nil

        searchTask = Task {
            let entries: [RankingEntry]
            do {
                entries = try await DataService.shared.rankings(for: format)
            } catch {
                if !Task.isCancelled { phase = .failed(error.localizedDescription) }
                return
            }
            if Task.isCancelled { return }

            let pool = Self.buildPool(
                entries: entries, poolSize: poolSize,
                cpCap: format.cp, pokemonById: pokemonById)
            guard pool.count >= 3 else {
                phase = .failed("Not enough ranked Pokémon in this format to build teams.")
                return
            }

            phase = .searching
            resultsFormat = format
            resultsPoolSize = pool.count
            let final = await TeamFinder.findTeams(
                pool: pool, movesById: movesById, fieldSize: fieldSize,
                onSeedingProgress: { fraction in
                    Task { @MainActor in self.progress = max(self.progress, fraction) }
                },
                onStandings: { snapshot in
                    Task { @MainActor in
                        // Snapshots hop actors independently; never regress.
                        guard snapshot.battlesFought >= (self.standings?.battlesFought ?? -1) else { return }
                        withAnimation(.spring(duration: 0.6)) { self.standings = snapshot }
                    }
                })
            if Task.isCancelled { return }
            results = final.teams
            withAnimation(.spring(duration: 0.6)) { standings = final }
            phase = .done

            // Only a finished round robin is worth keeping — a cancelled
            // run's records aren't a full account of the field.
            if final.isComplete {
                savedTournaments.save(SavedTournament(
                    date: .now,
                    formatTitle: format.title, cup: format.cup, cp: format.cp,
                    poolSize: pool.count, fieldSize: final.totalEntrants,
                    battlesFought: final.battlesFought,
                    teams: final.teams))
            }
        }
    }

    /// The top `poolSize` ranked Pokémon as battle-ready candidates, using the
    /// recommended moveset and IV-optimal stats already in the ranking data
    /// (the IV optimizer only runs for the rare unranked-stats entry).
    private static func buildPool(
        entries: [RankingEntry], poolSize: Int, cpCap: Int,
        pokemonById: [String: Pokemon]
    ) -> [TeamFinder.Candidate] {
        var pool: [TeamFinder.Candidate] = []
        for entry in entries {
            guard pool.count < poolSize else { break }
            guard entry.moveset.count >= 2,
                  let r = resolve(speciesId: entry.speciesId, pokemonById: pokemonById)
            else { continue }
            let combatant = MatchupSimulator.Combatant(
                species: r.species, shadow: r.shadow,
                fastMoveId: entry.moveset[0],
                chargedMoveIds: Array(entry.moveset[1...].prefix(2)))
            let stats = entry.stats.map {
                BattlePokemon.Stats(atk: $0.atk, def: $0.def, hp: Int($0.hp))
            } ?? MatchupSimulator.optimalStats(for: combatant, cpCap: cpCap)
            guard let stats else { continue }

            let member = TeamMember(
                speciesId: r.species.speciesId,
                fastMoveId: combatant.fastMoveId,
                chargedMoveIds: combatant.chargedMoveIds,
                shadow: r.shadow)
            pool.append(.init(
                member: member,
                speciesName: r.species.speciesName,
                types: r.species.types.filter { $0 != "none" },
                shadow: r.shadow,
                familyId: r.species.family?.id,
                dex: r.species.dex,
                combatant: combatant,
                stats: stats))
        }
        return pool
    }

    /// Resolves a ranking-entry species id to its species + shadow flag.
    /// (Mirrors RankingsStore's private resolver.)
    private static func resolve(
        speciesId: String, pokemonById: [String: Pokemon]
    ) -> (species: Pokemon, shadow: Bool)? {
        var species = pokemonById[speciesId]
        if species == nil, speciesId.hasSuffix("_shadow") {
            species = pokemonById[String(speciesId.dropLast("_shadow".count))]
        }
        guard let species else { return nil }
        return (species, species.isShadow || speciesId.hasSuffix("_shadow"))
    }
}
