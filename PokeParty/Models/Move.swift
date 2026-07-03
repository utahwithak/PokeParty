//
//  Move.swift
//  PokeParty
//
//  A fast or charged move as defined in PvPoke's gamemaster data.
//

import Foundation

/// A single move. PvPoke stores fast and charged moves in the same list;
/// fast moves have `energy == 0` (they generate energy via `energyGain`),
/// while charged moves cost `energy` to use.
struct Move: Decodable, Identifiable, Hashable {
    let moveId: String
    let name: String
    let type: String
    let power: Int
    let energy: Int
    let energyGain: Int
    let cooldown: Int
    let turns: Int?
    let buffs: [Int]?
    let buffTarget: String?
    /// PvPoke stores this as a string (e.g. "1", "0.5"); decoded leniently.
    let buffApplyChance: String?

    var id: String { moveId }

    /// Fast moves charge energy and cost none to throw.
    var isFast: Bool { energy == 0 }

    /// Numeric form of `buffApplyChance` (0 when absent).
    var buffApplyChanceValue: Double? {
        buffApplyChance.flatMap(Double.init)
    }
}
