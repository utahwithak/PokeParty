//
//  MetaGameTests.swift
//  PokePartyTests
//
//  The metagame solver against games with known Nash equilibria.
//

import Testing
@testable import PokeParty

struct MetaGameTests {

    /// Rock–paper–scissors: the unique equilibrium is uniform, and every
    /// strategy scores exactly 0.5 against it.
    @Test func rockPaperScissorsIsUniform() {
        let w: [[Double]] = [
            [0.5, 1.0, 0.0],
            [0.0, 0.5, 1.0],
            [1.0, 0.0, 0.5],
        ]
        let solution = MetaGame.solve(winMatrix: w)
        for weight in solution.weights {
            #expect(abs(weight - 1.0 / 3.0) < 0.02)
        }
        for score in solution.metaScores {
            #expect(abs(score - 0.5) < 0.02)
        }
    }

    /// A strictly dominant strategy takes the whole meta, and the dominated
    /// ones score below 0.5 against it.
    @Test func dominantStrategyTakesTheMeta() {
        let w: [[Double]] = [
            [0.5, 0.9, 0.8],
            [0.1, 0.5, 0.6],
            [0.2, 0.4, 0.5],
        ]
        let solution = MetaGame.solve(winMatrix: w)
        #expect(solution.weights[0] > 0.98)
        #expect(solution.metaScores[0] > solution.metaScores[1])
        #expect(solution.metaScores[0] > solution.metaScores[2])
        #expect(solution.metaScores[1] < 0.5)
        #expect(solution.metaScores[2] < 0.5)
    }

    /// The meta score punishes farming: a team that beats the weak field but
    /// loses to the equilibrium core ranks below the core despite a higher
    /// raw win rate. Two core teams that trade evenly and beat everything
    /// else; one "bully" that crushes three fodder teams but loses to both
    /// core teams — the bully's raw record is competitive, its meta score isn't.
    @Test func farmingWeakTeamsDoesNotPay() {
        // Teams: 0-1 core, 2 bully, 3-5 fodder.
        var w = [[Double]](repeating: [Double](repeating: 0.5, count: 6), count: 6)
        func set(_ i: Int, _ j: Int, _ v: Double) { w[i][j] = v; w[j][i] = 1 - v }
        set(0, 2, 0.9); set(1, 2, 0.9)                    // core beats bully
        for f in 3...5 {
            set(0, f, 0.7); set(1, f, 0.7)                // core beats fodder
            set(2, f, 1.0)                                // bully crushes fodder
        }
        let solution = MetaGame.solve(winMatrix: w)
        // Raw win rate: bully = (0.1+0.1+3)/5 = 0.64, core = (0.5+0.9+2.1)/5 = 0.70.
        // Close on paper — but the equilibrium is core-only, so the bully's
        // meta score collapses toward its core matchup (0.1).
        #expect(solution.metaScores[2] < 0.2)
        #expect(solution.weights[2] < 0.02)
        #expect(solution.weights[0] + solution.weights[1] > 0.95)
    }
}
