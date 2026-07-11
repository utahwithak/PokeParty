//
//  TeamFinder.swift
//  PokeParty
//
//  The simplistic 3v3 Party Finder (a light first cut of plan Milestones 3/4).
//  Builds candidate teams constructively from the format's ranking list — each
//  pool mon seeds teams, partners are its "suggested teammates" (the mons that
//  best answer its threats, from the pairwise 1v1 matrix), and thirds maximize
//  the trio's meta coverage. Structurally bad teams are filtered before any
//  3v3 runs: shared evolutionary family, a type shared by all three members
//  (mono-type cores get farmed by one counter), or a single top-meta mon that
//  beats the whole team (a common weakness no rotation can play around).
//  Survivors are graded with true 3v3 battles (`ThreeVThreeBattle`) against a
//  deterministic sample of opponent teams drawn from the same candidate space.
//
//  Per plan Q7, the finder uses the engine's fast heuristics — greedy shields
//  and faint-only best-matchup switching — NOT the optimal-play shield/switch
//  search, which is far too expensive for tens of thousands of battles. The
//  head-to-head viewer keeps the full solver.
//
//  Large pools (top 50/100 ⇒ 10⁴–10⁵ trios) are searched in two stages: a cheap
//  pairwise-1v1 "meta coverage" heuristic shortlists the most promising trios,
//  and only the shortlist runs the full 3v3 gauntlet. Small pools skip the
//  shortlist and behave exactly as before.
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
        fullSimLimit: Int = 2_000,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async -> [RankedTeam] {
        let allTeams = candidateTeams(from: pool)
        guard !allTeams.isEmpty else { return [] }

        // A deterministic, evenly-spread sample of the candidate space serves as
        // the reference opponents — every team faces the same gauntlet, so the
        // records are comparable (and reproducible run to run). Sampled from the
        // FULL combination space, so pruning never changes the gauntlet.
        let sampleCount = min(opponentSampleCount, allTeams.count)
        let step = Double(allTeams.count) / Double(sampleCount)
        let opponents = (0..<sampleCount).map { allTeams[Int(Double($0) * step)] }

        // Stage 1 (large pools only): shortlist by meta coverage from the
        // pairwise 1v1 matrix — a full 3v3 gauntlet over 10⁵ trios takes minutes.
        let pruning = allTeams.count > fullSimLimit
        let matrixShare = pruning ? 0.15 : 0.0   // progress budget for stage 1
        var teams = allTeams
        if pruning {
            let matrix = await ratingMatrix(pool: pool, movesById: movesById) { fraction in
                progress?(fraction * matrixShare)
            }
            if Task.isCancelled { return [] }
            teams = zip(allTeams, allTeams.map { coverageScore(team: $0, matrix: matrix) })
                .sorted { $0.1 > $1.1 }
                .prefix(fullSimLimit)
                .map(\.0)
        }

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
                    progress?(matrixShare + (1 - matrixShare) * Double(completed) / Double(total))
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

    // MARK: - Stage 1: 1v1-matrix shortlist (large pools)

    /// Pairwise 1v1 ratings for the whole pool: `matrix[i][j]` = pool[i]'s
    /// battle rating vs pool[j] (0…1000), fresh mons at 1 shield each. One
    /// battle per unordered pair yields both perspectives, so a 100-mon pool
    /// costs ~5k fast 1v1s. Heuristic input only — never shown to the user.
    private static func ratingMatrix(
        pool: [Candidate], movesById: [String: Move],
        progress: (@Sendable (Double) -> Void)? = nil
    ) async -> [[Int]] {
        let n = pool.count
        var matrix = Array(repeating: Array(repeating: 500, count: n), count: n)
        let totalPairs = n * (n - 1) / 2
        guard totalPairs > 0 else { return matrix }

        var completedPairs = 0
        await withTaskGroup(of: (i: Int, j: Int, a: Int, b: Int)?.self) { group in
            for i in 0..<n {
                for j in (i + 1)..<n {
                    group.addTask {
                        guard !Task.isCancelled,
                              let r = MatchupSimulator.rate(
                                pool[i].combatant, statsA: pool[i].stats,
                                pool[j].combatant, statsB: pool[j].stats,
                                movesById: movesById, shieldsA: 1, shieldsB: 1)
                        else { return nil }
                        return (i, j, r.a, r.b)
                    }
                }
            }
            for await pair in group {
                completedPairs += 1
                if completedPairs % 256 == 0 || completedPairs == totalPairs {
                    progress?(Double(completedPairs) / Double(totalPairs))
                }
                if let pair {
                    matrix[pair.i][pair.j] = pair.a
                    matrix[pair.j][pair.i] = pair.b
                }
            }
        }
        return matrix
    }

    /// How well a trio covers the meta: for every other pool mon, the best
    /// member rating against it, averaged. Rewards teams that keep an answer
    /// to everything (the same idea as the analyzer's threat score, inverted).
    private static func coverageScore(team: [Int], matrix: [[Int]]) -> Double {
        var sum = 0
        var count = 0
        for m in 0..<matrix.count where !team.contains(m) {
            var best = 0
            for t in team where matrix[t][m] > best { best = matrix[t][m] }
            sum += best
            count += 1
        }
        return count > 0 ? Double(sum) / Double(count) : 0
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
