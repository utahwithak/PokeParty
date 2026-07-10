//
//  TeamFinderModel.swift
//  PokeParty
//
//  Observable state for the 3v3 Party Finder. Picks a format (independent of
//  the sidebar selection), loads that format's rankings, builds a candidate
//  pool from the top of the list, and runs `TeamFinder` to produce suggested
//  teams ranked by their simulated 3v3 record.
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
    static let poolSizes = [10, 15, 20, 25]

    private(set) var phase: Phase = .idle
    /// Search progress, 0…1 (meaningful while `phase == .searching`).
    private(set) var progress: Double = 0
    private(set) var results: [TeamFinder.RankedTeam] = []
    /// The format and pool size the current `results` were computed for.
    private(set) var resultsFormat: RankingFormat?
    private(set) var resultsPoolSize = 0

    private var searchTask: Task<Void, Never>?

    var isRunning: Bool { phase == .loadingRankings || phase == .searching }

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        if isRunning { phase = results.isEmpty ? .idle : .done }
    }

    /// Loads the chosen format's rankings and searches for the best teams.
    func run(using store: RankingsStore) {
        searchTask?.cancel()
        let format = format
        let poolSize = poolSize
        let movesById = store.movesById
        let pokemonById = store.pokemonById

        phase = .loadingRankings
        progress = 0
        results = []
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
            let found = await TeamFinder.findTeams(pool: pool, movesById: movesById) { fraction in
                Task { @MainActor in self.progress = fraction }
            }
            if Task.isCancelled { return }
            results = found
            resultsFormat = format
            resultsPoolSize = pool.count
            phase = .done
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
