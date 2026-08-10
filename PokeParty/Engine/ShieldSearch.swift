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

    /// One distinct (A-policy, B-policy) outcome within a fixed shield-count matchup.
    struct ScenarioItem: Sendable, Hashable {
        let policyA: Set<Int>
        let policyB: Set<Int>
        let ratingA: Int
    }

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

        /// Every distinct (A-policy, B-policy) outcome, best-for-A first.
        let scenarios: [ScenarioItem]

        var winRate: Double { scenarioCount > 0 ? Double(scenarioWins) / Double(scenarioCount) : 0 }
    }

    /// Candidate shield policies for a side: every subset of the first `shields + 2`
    /// faced charged moves with size ≤ its shield count (so it can skip early moves
    /// and save shields for later). With 2 shields that's 11 policies.
    /// Precomputed for the only shield counts that occur in play (0…2).
    private static let cachedPolicies: [[Set<Int>]] = (0...2).map(computePolicies(shields:))

    private static func policies(shields: Int) -> [Set<Int>] {
        (0...2).contains(shields) ? cachedPolicies[shields] : computePolicies(shields: shields)
    }

    private static func computePolicies(shields: Int) -> [Set<Int>] {
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
        var items: [ScenarioItem] = []
        for r in rowIdx {
            for c in colIdx {
                let v = matrix[r][c]
                if v > 500 { wins += 1 } else if v < 500 { losses += 1 } else { ties += 1 }
                items.append(ScenarioItem(policyA: polA[r], policyB: polB[c], ratingA: v))
            }
        }
        items.sort { $0.ratingA > $1.ratingA }
        let flat = matrix.flatMap { $0 }

        return Solution(
            ratingA: matrix[bestRow][bestCol],
            policyA: polA[bestRow], policyB: polB[bestCol],
            scenarioWins: wins, scenarioLosses: losses, scenarioTies: ties,
            scenarioCount: rowIdx.count * colIdx.count,
            bestCaseA: flat.max() ?? 500, worstCaseA: flat.min() ?? 500,
            scenarios: items)
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
        guard let pa = MatchupSimulator.makeBattlePokemon(a, stats: statsA, movesById: movesById, shields: shieldsA),
              let pb = MatchupSimulator.makeBattlePokemon(b, stats: statsB, movesById: movesById, shields: shieldsB)
        else { return nil }
        return solve(a: pa, b: pb, polA: policies(shields: shieldsA), polB: policies(shields: shieldsB))
    }

    /// Optimal shield play + scenario distribution for a 1v1 starting from two live
    /// Pokémon's *current* carried state (used per 3v3 segment). Evaluates on clones
    /// and does not mutate the originals; uses each mon's `startingShields` as its pool.
    static func optimalSolution(_ a: BattlePokemon, _ b: BattlePokemon) -> Solution {
        solve(a: a, b: b,
              polA: policies(shields: a.startingShields),
              polB: policies(shields: b.startingShields))
    }

    /// Fills the payoff matrix and solves it. One battle serves every cell —
    /// `simulate()` rebuilds all battle state from the `start*` fields, so only
    /// the shield policy differs between runs. `a`/`b` are consumed (mutated).
    ///
    /// Cells are memoized: a deterministic battle depends only on the shield
    /// decisions at opportunities that actually arose, so a fought battle's
    /// rating covers every policy pair that agrees on those first
    /// `shieldOpportunities` decisions. That collapses most of the matrix.
    private static func solve(a: BattlePokemon, b: BattlePokemon,
                              polA: [Set<Int>], polB: [Set<Int>]) -> Solution {
        let battle = Battle(a, b)
        // Policies as bitmasks for cheap truncated comparison. Opportunity
        // counts can exceed the policies' 4-bit range; clamping keeps the
        // truncation exact (higher bits are always zero) and the shift safe.
        func mask(_ s: Set<Int>) -> UInt32 { s.reduce(0) { $0 | (1 << UInt32($1)) } }
        func truncated(_ m: UInt32, _ faced: Int) -> UInt32 { m & ((1 << UInt32(min(faced, 8))) - 1) }
        let masksA = polA.map(mask)
        let masksB = polB.map(mask)

        struct Fought { let truncA: UInt32; let facedA: Int; let truncB: UInt32; let facedB: Int; let rating: Int }
        var fought: [Fought] = []

        var matrix = [[Int]](repeating: [Int](repeating: 500, count: polB.count), count: polA.count)
        for i in polA.indices {
            let pa = polA[i], ma = masksA[i]
            for j in polB.indices {
                let pb = polB[j], mb = masksB[j]
                if let hit = fought.first(where: {
                    truncated(ma, $0.facedA) == $0.truncA && truncated(mb, $0.facedB) == $0.truncB
                }) {
                    matrix[i][j] = hit.rating
                    continue
                }
                battle.shieldOverride = { defenderIndex, opportunity in
                    defenderIndex == 0 ? pa.contains(opportunity) : pb.contains(opportunity)
                }
                battle.simulate()
                let rating = battle.battleRating(forIndex: 0)
                matrix[i][j] = rating
                let facedA = battle.shieldOpportunities[0]
                let facedB = battle.shieldOpportunities[1]
                fought.append(Fought(truncA: truncated(ma, facedA), facedA: facedA,
                                     truncB: truncated(mb, facedB), facedB: facedB,
                                     rating: rating))
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
