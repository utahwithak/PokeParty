//
//  BenchFinderModel.swift
//  PokeParty
//
//  Two-phase bench team evaluation:
//
//  Phase 1 — Static grade analysis: every distinct bench trio is graded
//  against the full meta field (Coverage, Bulk, Safety, Consistency) using
//  the same formulas as the Team Builder. The top-graded trios advance.
//
//  Phase 2 — Tournament: the bench trios are seeded into a round-robin
//  alongside meta-seeded teams from the real rankings. After the tournament
//  completes, only the bench teams' records are shown — ranked by how they
//  actually performed against a competitive field, not just static grades.
//

import SwiftUI

@MainActor
@Observable
final class BenchFinderModel {

    enum Phase: Equatable {
        case idle
        case loadingRankings
        case gradingBench       // Phase 1: static analysis
        case searching          // Phase 2: tournament seeding + round robin
        case done
        case failed(String)
    }

    /// Top-N meta Pokémon used as the "field" for both grade scoring and
    /// as filler opponents in the tournament.
    static let metaPoolSize = 50

    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0

    /// Phase 1 results — bench trios ordered by static grade.
    private(set) var gradedBenchTeams: [GradeFinder.GradedTeam] = []

    /// Phase 2 results — live tournament snapshot (bench + meta teams).
    /// Filter with `benchTeamIds` to see only bench team records.
    private(set) var standings: TeamFinder.Standings?
    /// IDs of the bench trios in the tournament (for filtering standings).
    private(set) var benchTeamIds: Set<String> = []

    private(set) var resultsLeague: League?
    private(set) var benchCount = 0
    private(set) var tournamentFieldSize = 0

    var isRunning: Bool {
        phase == .loadingRankings || phase == .gradingBench || phase == .searching
    }

    private var searchTask: Task<Void, Never>?

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        if isRunning { phase = standings == nil ? .idle : .done }
    }

    /// Bench teams from the current standings (filtered from the full field).
    var benchStandings: [TeamFinder.RankedTeam] {
        (standings?.teams ?? []).filter { benchTeamIds.contains($0.id) }
    }

    func run(league: League, bench: BenchStore, store: RankingsStore) {
        searchTask?.cancel()
        let format = league.format
        let pokemonById = store.pokemonById
        let movesById = store.movesById
        let benchEntries = bench.entries.filter { $0.league == league }

        guard benchEntries.count >= 3 else {
            phase = .failed(benchEntries.count == 0
                ? "No bench Pokémon for \(league.title) League."
                : "Need at least 3 bench Pokémon in \(league.title) League.")
            return
        }

        phase = .loadingRankings
        progress = 0
        gradedBenchTeams = []
        standings = nil
        benchTeamIds = []
        resultsLeague = nil
        benchCount = 0
        tournamentFieldSize = 0

        searchTask = Task {
            let entries: [RankingEntry]
            do {
                entries = try await DataService.shared.rankings(for: format)
            } catch {
                if !Task.isCancelled { phase = .failed(error.localizedDescription) }
                return
            }
            if Task.isCancelled { return }

            let metaCandidates = TeamFinderModel.buildPool(
                entries: entries, poolSize: Self.metaPoolSize,
                cpCap: format.cp, pokemonById: pokemonById)
            let benchCandidates = TeamFinderModel.buildBenchPool(
                entries: benchEntries, cpCap: format.cp, pokemonById: pokemonById)

            guard !metaCandidates.isEmpty else {
                phase = .failed("Could not load meta rankings for \(league.title) League.")
                return
            }
            guard benchCandidates.count >= 3 else {
                phase = .failed("Not enough bench Pokémon could be resolved for \(league.title) League.")
                return
            }
            if Task.isCancelled { return }

            resultsLeague = league
            benchCount = benchCandidates.count

            // --- Phase 1: grade bench trios against the meta ---
            phase = .gradingBench
            // All viable bench trios (no cap — we want every one in the tournament)
            let maxBenchTrios = benchCandidates.count * (benchCandidates.count - 1) * (benchCandidates.count - 2) / 6
            let graded = await GradeFinder.findBenchTeams(
                bench: benchCandidates,
                meta: metaCandidates,
                cpCap: format.cp,
                movesById: movesById,
                maxResults: max(maxBenchTrios, 200),
                onProgress: { fraction in
                    Task { @MainActor in self.progress = max(self.progress, fraction * 0.45) }
                })

            if Task.isCancelled { return }

            guard !graded.isEmpty else {
                phase = .failed("No valid bench teams found for \(league.title) League.")
                return
            }

            gradedBenchTeams = graded
            benchTeamIds = Set(graded.map(\.id))

            // --- Phase 2: tournament ---
            // Combined pool: bench first (so poolIndices from grade check are valid),
            // followed by the meta candidates that fill the remaining field slots.
            let combinedPool = benchCandidates + metaCandidates
            let seededField = graded.map(\.poolIndices)

            // Field: all bench trios + enough meta teams to give a meaningful field.
            let totalField = max(graded.count + 50, 100)
            tournamentFieldSize = totalField

            phase = .searching

            let final = await TeamFinder.findTeams(
                pool: combinedPool,
                movesById: movesById,
                fieldSize: totalField,
                voluntarySwitching: false,
                optimalShields: false,
                learnedShields: true,
                learnedSwitches: true,
                seededField: seededField,
                onSeedingProgress: { fraction in
                    Task { @MainActor in
                        self.progress = max(self.progress, 0.45 + fraction * 0.25)
                    }
                },
                onStandings: { snapshot in
                    Task { @MainActor in
                        guard snapshot.battlesFought >= (self.standings?.battlesFought ?? -1) else { return }
                        withAnimation(.spring(duration: 0.6)) { self.standings = snapshot }
                        let battleFraction = Double(snapshot.battlesFought) / Double(max(snapshot.totalBattles, 1))
                        self.progress = max(self.progress, 0.7 + battleFraction * 0.3)
                    }
                })

            if Task.isCancelled { return }
            withAnimation(.spring(duration: 0.6)) { standings = final }
            phase = .done
        }
    }
}
