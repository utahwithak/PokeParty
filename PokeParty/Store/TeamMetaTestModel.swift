//
//  TeamMetaTestModel.swift
//  PokeParty
//
//  Observable state for the Team Builder's "Test Against Meta" action:
//  battles the current team against a randomly generated field of meta-team
//  opponents using the full 3v3 engine (`MetaFieldTester`), reporting
//  win/loss records per lead. Runs against whichever format is currently
//  selected in the Team Builder.
//

import SwiftUI

@MainActor
@Observable
final class TeamMetaTestModel {

    enum Phase: Equatable {
        case idle
        case loadingRankings
        case testing
        case done
        case failed(String)
    }

    /// How many of the format's top-ranked Pokémon form the opponent candidate pool.
    var poolSize: Int = 15
    static let poolSizes = TeamFinderModel.poolSizes

    /// How many randomly generated opponent trios to battle against.
    var fieldSize: Int = 300
    static let fieldSizeRange = 50.0...2000.0
    static let fieldSizeStep = 50.0

    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0
    private(set) var results: MetaFieldTester.Results?

    private var runTask: Task<Void, Never>?

    var isRunning: Bool { phase == .loadingRankings || phase == .testing }

    /// Distinct opposing-lead species encountered in the last run's
    /// generated field — feeds the switch/stay filter over the Team
    /// Builder's existing threat grid.
    var encounteredLeadSpeciesIds: Set<String> {
        guard let results else { return [] }
        return Set(results.opponents.compactMap { $0.members.first?.member.speciesId })
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        if isRunning { phase = results == nil ? .idle : .done }
    }

    /// Battles `team` against a generated field drawn from `store`'s current format.
    func run(team: [TeamMember], using store: RankingsStore) {
        runTask?.cancel()
        guard !team.isEmpty, let built = TeamBuilderModel.buildTeam(team, store: store) else { return }
        let format = store.format
        let poolSize = poolSize
        let fieldSize = fieldSize
        let movesById = store.movesById
        let pokemonById = store.pokemonById

        phase = .loadingRankings
        progress = 0
        results = nil

        runTask = Task {
            let entries: [RankingEntry]
            do {
                entries = try await DataService.shared.rankings(for: format)
            } catch {
                if !Task.isCancelled { phase = .failed(error.localizedDescription) }
                return
            }
            if Task.isCancelled { return }

            let pool = TeamFinderModel.buildPool(
                entries: entries, poolSize: poolSize,
                cpCap: format.cp, pokemonById: pokemonById)
            guard pool.count >= 3,
                  let yourTeam = ThreeVThreeBattle.makeTeam(
                    built.combatants, stats: built.stats, movesById: movesById)
            else {
                phase = .failed("Not enough ranked Pokémon in this format to build an opponent field.")
                return
            }

            phase = .testing
            let final = await MetaFieldTester.run(
                yourTeam: yourTeam, pool: pool, fieldSize: fieldSize, movesById: movesById,
                onProgress: { fraction in
                    Task { @MainActor in self.progress = max(self.progress, fraction) }
                },
                onResults: { snapshot in
                    Task { @MainActor in
                        guard snapshot.completed >= (self.results?.completed ?? -1) else { return }
                        withAnimation(.spring(duration: 0.6)) { self.results = snapshot }
                    }
                })
            if Task.isCancelled { return }
            withAnimation(.spring(duration: 0.6)) { results = final }
            phase = .done
        }
    }
}
