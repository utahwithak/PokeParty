//
//  RankingEntry.swift
//  PokeParty
//
//  One Pokémon's entry in a league's overall ranking list.
//

import Foundation

/// A Pokémon's ranking within a league, as computed by PvPoke's simulator.
///
/// - `score` is the headline 0–100 ranking score shown in lists.
/// - `rating` is the average battle rating (0–1000).
/// - Matchup/counter `rating` is a per-opponent battle rating where 500 is even.
struct RankingEntry: Decodable, Identifiable, Hashable {
    let speciesId: String
    let speciesName: String
    let rating: Double
    let score: Double?
    /// PvPoke's per-category sub-scores (0–100), in the order
    /// [leads, closers, switches, chargers, attackers, consistency].
    let scores: [Double]?
    let moveset: [String]
    let matchups: [Matchup]
    let counters: [Matchup]
    let moves: Moves?
    let stats: Stats?

    var id: String { speciesId }

    /// Preferred number to display in lists (0–100). Falls back to `rating`.
    var displayScore: Double { score ?? rating }

    /// The "switches" category score (index 2) — how safely this Pokémon can come
    /// in at an energy disadvantage. Drives the team Safety grade.
    var switchesScore: Double? { (scores?.count ?? 0) > 2 ? scores?[2] : nil }

    /// A battle outcome against a specific opponent.
    struct Matchup: Decodable, Identifiable, Hashable {
        let opponent: String
        let rating: Int

        var id: String { opponent }

        /// True when this Pokémon wins the matchup (rating above the even point).
        var isFavorable: Bool { rating > 500 }
    }

    /// Recommended moves with simulated usage weights.
    struct Moves: Decodable, Hashable {
        let fastMoves: [Usage]
        let chargedMoves: [Usage]

        struct Usage: Decodable, Identifiable, Hashable {
            let moveId: String
            /// Simulated usage weight. Absent for a few moves, so optional.
            let uses: Double?
            var id: String { moveId }
        }
    }

    /// The IV-optimized stat product for the league's CP cap.
    struct Stats: Decodable, Hashable {
        let product: Double?
        let atk: Double
        let def: Double
        let hp: Double
    }
}
