//
//  TeamFinder.swift
//  PokeParty
//
//  The simplistic 3v3 Party Finder (a light first cut of plan Milestones 3/4).
//  Builds every 3-Pokémon combination from the top of a format's ranking list
//  and scores each one with true 3v3 battles (`ThreeVThreeBattle`) against a
//  deterministic sample of opponent teams drawn from the same candidate space.
//
//  Per plan Q7, the finder uses the engine's fast heuristics — greedy shields
//  and faint-only best-matchup switching — NOT the optimal-play shield/switch
//  search, which is far too expensive for tens of thousands of battles. The
//  head-to-head viewer keeps the full solver.
//

import Foundation

nonisolated enum TeamFinder {

    /// A meta Pokémon eligible for suggested teams, prepared for battle once so
    /// every 3v3 can reuse its stats without touching the IV optimizer.
    struct Candidate: Sendable {
        /// Ready to load into the Team Builder.
        let member: TeamMember
        let speciesName: String
        let types: [String]
        let shadow: Bool
        let familyId: String?
        let dex: Int
        let combatant: MatchupSimulator.Combatant
        let stats: BattlePokemon.Stats
    }

    /// One suggested team with its aggregate 3v3 record. Members are in team
    /// order (index 0 = lead), which follows the ranking order of the pool.
    struct RankedTeam: Identifiable, Sendable {
        let members: [Candidate]
        let wins: Int
        let losses: Int
        let ties: Int
        /// 0…1 across the opponent sample; a tie counts as half a win.
        let winRate: Double
        /// Mean team battle rating (0–1000, 500 = even) across the sample.
        let averageRating: Double

        var id: String { members.map { $0.member.speciesId }.joined(separator: "+") }
    }

    /// Scores every candidate team against the opponent sample and returns the
    /// best `maxResults`, best-first. Fans out across all cores; supports
    /// cancellation via the surrounding task. `progress` (0…1) is called from
    /// off the main actor.
    static func findTeams(
        pool: [Candidate],
        movesById: [String: Move],
        opponentSampleCount: Int = 24,
        maxResults: Int = 30,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async -> [RankedTeam] {
        let teams = candidateTeams(from: pool)
        guard !teams.isEmpty else { return [] }

        // A deterministic, evenly-spread sample of the candidate space serves as
        // the reference opponents — every team faces the same gauntlet, so the
        // records are comparable (and reproducible run to run).
        let sampleCount = min(opponentSampleCount, teams.count)
        let step = Double(teams.count) / Double(sampleCount)
        let opponents = (0..<sampleCount).map { teams[Int(Double($0) * step)] }

        let total = teams.count
        var completed = 0
        var scored: [RankedTeam] = []
        scored.reserveCapacity(total)

        await withTaskGroup(of: RankedTeam?.self) { group in
            for team in teams {
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    return score(team: team, opponents: opponents, pool: pool, movesById: movesById)
                }
            }
            for await result in group {
                completed += 1
                if completed % 32 == 0 || completed == total {
                    progress?(Double(completed) / Double(total))
                }
                if let result { scored.append(result) }
            }
        }

        return Array(
            scored
                .sorted {
                    $0.winRate != $1.winRate
                        ? $0.winRate > $1.winRate
                        : $0.averageRating > $1.averageRating
                }
                .prefix(maxResults))
    }

    /// All 3-member combinations of the pool (as pool indices, ascending — so
    /// the better-ranked member leads), skipping teams that double up on a
    /// species or evolutionary family (e.g. a shadow + regular pair).
    static func candidateTeams(from pool: [Candidate]) -> [[Int]] {
        var teams: [[Int]] = []
        for i in 0..<pool.count {
            for j in (i + 1)..<pool.count where distinct(pool[i], pool[j]) {
                for k in (j + 1)..<pool.count
                where distinct(pool[i], pool[k]) && distinct(pool[j], pool[k]) {
                    teams.append([i, j, k])
                }
            }
        }
        return teams
    }

    private static func distinct(_ a: Candidate, _ b: Candidate) -> Bool {
        if a.dex == b.dex { return false }
        if let fa = a.familyId, let fb = b.familyId, fa == fb { return false }
        return true
    }

    /// Runs one candidate team through the whole opponent sample.
    private static func score(
        team: [Int], opponents: [[Int]],
        pool: [Candidate], movesById: [String: Move]
    ) -> RankedTeam? {
        let mySet = Set(team)
        let members = team.map { pool[$0] }
        var wins = 0, losses = 0, ties = 0
        var ratingSum = 0
        var battles = 0

        for opponent in opponents {
            if Task.isCancelled { return nil }
            if Set(opponent) == mySet { continue }   // skip the mirror match
            guard let a = makeTeam(members, movesById: movesById),
                  let b = makeTeam(opponent.map { pool[$0] }, movesById: movesById)
            else { return nil }

            let result = ThreeVThreeBattle(
                teamA: a, teamB: b,
                switchPolicy: .bestMatchup,
                optimalShields: false).run()
            switch result.winner {
            case .teamA: wins += 1
            case .teamB: losses += 1
            case .tie: ties += 1
            }
            ratingSum += result.ratingA
            battles += 1
        }

        guard battles > 0 else { return nil }
        return RankedTeam(
            members: members,
            wins: wins, losses: losses, ties: ties,
            winRate: (Double(wins) + Double(ties) * 0.5) / Double(battles),
            averageRating: Double(ratingSum) / Double(battles))
    }

    /// Fresh `BattlePokemon`s per battle — the 3v3 engine mutates its teams.
    private static func makeTeam(_ members: [Candidate], movesById: [String: Move]) -> [BattlePokemon]? {
        ThreeVThreeBattle.makeTeam(
            members.map(\.combatant), stats: members.map(\.stats), movesById: movesById)
    }
}
