//
//  ShieldSearch.swift
//  PokeParty
//
//  M8.2 — optimal shield play for a 1v1. Instead of the engine's greedy "shield
//  the first charged moves" default, this explores which of the charged moves each
//  side should shield (subsets of its 2-shield pool over the first few
//  opportunities) by replaying the battle with `Battle.shieldOverride`, then solves
//  the resulting payoff matrix game-theoretically: A maximizes its rating, B
//  minimizes it. Returns the game value, the chosen shield timing for each side,
//  and the win/loss distribution across all shield scenarios.
//

import Foundation

nonisolated enum ShieldSearch {

    struct Solution: Sendable, Hashable {
        /// Game value: A's rating under optimal play (maximin / best response).
        let ratingA: Int
        /// Which shield opportunities (0 = first charged move faced, …) each side shields.
        let policyA: Set<Int>
        let policyB: Set<Int>

        // Distribution across every distinct shield scenario (both sides' choices).
        let scenarioWins: Int      // A wins (rating > 500)
        let scenarioLosses: Int    // A loses (rating < 500)
        let scenarioTies: Int      // even (rating == 500)
        let scenarioCount: Int     // total distinct scenarios
        let bestCaseA: Int         // A's best achievable rating
        let worstCaseA: Int        // A's worst achievable rating

        var winRate: Double { scenarioCount > 0 ? Double(scenarioWins) / Double(scenarioCount) : 0 }
    }

    /// Candidate shield policies for a side: every subset of the first `shields + 2`
    /// faced charged moves with size ≤ its shield count (so it can skip early moves
    /// and save shields for later). With 2 shields that's 11 policies.
    private static func policies(shields: Int) -> [Set<Int>] {
        guard shields > 0 else { return [[]] }
        let opportunities = Array(0..<(shields + 2))
        var result: [Set<Int>] = []
        for size in 0...shields {
            result.append(contentsOf: combinations(opportunities, choose: size).map(Set.init))
        }
        return result
    }

    private static func combinations(_ items: [Int], choose k: Int) -> [[Int]] {
        if k == 0 { return [[]] }
        guard k <= items.count, let first = items.first else { return [] }
        let rest = Array(items.dropFirst())
        return combinations(rest, choose: k - 1).map { [first] + $0 } + combinations(rest, choose: k)
    }

    /// Runs one 1v1 with fixed shield policies; returns A's rating and, if recording,
    /// the timeline.
    static func play(
        _ a: MatchupSimulator.Combatant, statsA: BattlePokemon.Stats,
        _ b: MatchupSimulator.Combatant, statsB: BattlePokemon.Stats,
        movesById: [String: Move],
        shieldsA: Int, shieldsB: Int,
        policyA: Set<Int>, policyB: Set<Int>,
        record: Bool = false
    ) -> (ratingA: Int, log: BattleLog?)? {
        guard let pa = MatchupSimulator.makeBattlePokemon(a, stats: statsA, movesById: movesById, shields: shieldsA),
              let pb = MatchupSimulator.makeBattlePokemon(b, stats: statsB, movesById: movesById, shields: shieldsB)
        else { return nil }
        let battle = Battle(pa, pb, record: record)
        battle.shieldOverride = { defenderIndex, opportunity in
            defenderIndex == 0 ? policyA.contains(opportunity) : policyB.contains(opportunity)
        }
        battle.simulate()
        return (battle.battleRating(forIndex: 0), record ? battle.makeLog() : nil)
    }

    // MARK: - Solving

    /// Solves a payoff matrix (`M[i][j]` = A's rating) into a `Solution`: A's maximin
    /// policy, B's best response, and the win/loss distribution over distinct
    /// strategies (identical rows/columns deduped so redundant policies don't inflate).
    private static func solve(matrix: [[Int]], polA: [Set<Int>], polB: [Set<Int>]) -> Solution {
        var bestRow = 0, bestRowValue = Int.min
        for i in polA.indices {
            let worst = matrix[i].min() ?? 500
            if worst > bestRowValue { bestRowValue = worst; bestRow = i }
        }
        var bestCol = 0, bestColValue = Int.max
        for j in polB.indices where matrix[bestRow][j] < bestColValue {
            bestColValue = matrix[bestRow][j]; bestCol = j
        }

        let rowIdx = distinctIndices(matrix)
        let cols = polB.indices.map { j in polA.indices.map { matrix[$0][j] } }
        let colIdx = distinctIndices(cols)
        var wins = 0, losses = 0, ties = 0
        for r in rowIdx {
            for c in colIdx {
                let v = matrix[r][c]
                if v > 500 { wins += 1 } else if v < 500 { losses += 1 } else { ties += 1 }
            }
        }
        let flat = matrix.flatMap { $0 }

        return Solution(
            ratingA: matrix[bestRow][bestCol],
            policyA: polA[bestRow], policyB: polB[bestCol],
            scenarioWins: wins, scenarioLosses: losses, scenarioTies: ties,
            scenarioCount: rowIdx.count * colIdx.count,
            bestCaseA: flat.max() ?? 500, worstCaseA: flat.min() ?? 500)
    }

    /// Indices of the first occurrence of each distinct vector (dedupe helper).
    private static func distinctIndices(_ vectors: [[Int]]) -> [Int] {
        var seen: [[Int]] = []
        var indices: [Int] = []
        for (i, v) in vectors.enumerated() where !seen.contains(v) {
            seen.append(v)
            indices.append(i)
        }
        return indices
    }

    /// Explores both sides' shield timings for a matchup and returns the game-optimal
    /// outcome + scenario distribution.
    static func optimal(
        _ a: MatchupSimulator.Combatant, statsA: BattlePokemon.Stats,
        _ b: MatchupSimulator.Combatant, statsB: BattlePokemon.Stats,
        movesById: [String: Move],
        shieldsA: Int, shieldsB: Int
    ) -> Solution? {
        let polA = policies(shields: shieldsA)
        let polB = policies(shields: shieldsB)
        var matrix = [[Int]](repeating: [Int](repeating: 500, count: polB.count), count: polA.count)
        for i in polA.indices {
            for j in polB.indices {
                guard let r = play(a, statsA: statsA, b, statsB: statsB, movesById: movesById,
                                   shieldsA: shieldsA, shieldsB: shieldsB,
                                   policyA: polA[i], policyB: polB[j]) else { return nil }
                matrix[i][j] = r.ratingA
            }
        }
        return solve(matrix: matrix, polA: polA, polB: polB)
    }

    /// Optimal shield play + scenario distribution for a 1v1 starting from two live
    /// Pokémon's *current* carried state (used per 3v3 segment). Evaluates on clones
    /// and does not mutate the originals; uses each mon's `startingShields` as its pool.
    static func optimalSolution(_ a: BattlePokemon, _ b: BattlePokemon) -> Solution {
        let polA = policies(shields: a.startingShields)
        let polB = policies(shields: b.startingShields)
        var matrix = [[Int]](repeating: [Int](repeating: 500, count: polB.count), count: polA.count)
        for i in polA.indices {
            for j in polB.indices {
                let ca = a.clone(), cb = b.clone()
                let battle = Battle(ca, cb)
                battle.shieldOverride = { defenderIndex, opportunity in
                    defenderIndex == 0 ? polA[i].contains(opportunity) : polB[j].contains(opportunity)
                }
                battle.simulate()
                matrix[i][j] = battle.battleRating(forIndex: 0)
            }
        }
        return solve(matrix: matrix, polA: polA, polB: polB)
    }

    /// Optimal shield play recorded for the timeline viewer.
    static func optimalLog(
        _ a: MatchupSimulator.Combatant, statsA: BattlePokemon.Stats,
        _ b: MatchupSimulator.Combatant, statsB: BattlePokemon.Stats,
        movesById: [String: Move],
        shieldsA: Int, shieldsB: Int
    ) -> BattleLog? {
        guard let sol = optimal(a, statsA: statsA, b, statsB: statsB, movesById: movesById,
                                shieldsA: shieldsA, shieldsB: shieldsB) else { return nil }
        return play(a, statsA: statsA, b, statsB: statsB, movesById: movesById,
                    shieldsA: shieldsA, shieldsB: shieldsB,
                    policyA: sol.policyA, policyB: sol.policyB, record: true)?.log
    }
}
