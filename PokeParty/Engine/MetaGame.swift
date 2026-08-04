//
//  MetaGame.swift
//  PokeParty
//
//  Team selection as a game: given a pairwise win matrix over teams, the
//  metagame is a symmetric zero-sum game whose Nash equilibrium is the
//  "meta" — the mixture of teams none of which can be exploited. A team's
//  quality is then its expected score against that mixture (its "meta score"),
//  which — unlike raw round-robin win rate — gives no credit for farming weak
//  teams. Solved by incremental fictitious play, which converges to the
//  equilibrium in zero-sum games.
//

import Foundation

nonisolated enum MetaGame {

    /// Solves the symmetric zero-sum game for a win matrix (`w[i][j]` = team
    /// i's expected score vs team j, 0…1, diagonal 0.5). Returns each team's
    /// equilibrium weight (how much of the meta it makes up) and its expected
    /// score against the equilibrium mixture.
    static func solve(
        winMatrix w: [[Double]], iterations: Int = 200_000
    ) -> (weights: [Double], metaScores: [Double]) {
        let n = w.count
        guard n > 1 else { return (Array(repeating: 1, count: n), Array(repeating: 0.5, count: n)) }

        // Fictitious play with an incrementally-maintained payoff vector:
        // each round the best response to the opponent's empirical mixture
        // joins the population (O(n) per round).
        var counts = [Double](repeating: 0, count: n)
        var payoff = [Double](repeating: 0, count: n)
        for _ in 0..<iterations {
            var best = 0
            for i in 1..<n where payoff[i] > payoff[best] { best = i }
            counts[best] += 1
            for i in 0..<n { payoff[i] += w[i][best] }
        }

        let weights = counts.map { $0 / Double(iterations) }
        var metaScores = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var s = 0.0
            for j in 0..<n { s += w[i][j] * weights[j] }
            metaScores[i] = s
        }
        return (weights, metaScores)
    }
}
