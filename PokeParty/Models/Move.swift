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
nonisolated struct Move: Decodable, Identifiable, Hashable {
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

    /// Fast moves needed to reach this charged move on each of the next 5
    /// throws, carrying leftover energy between throws. "Straight N" when
    /// every throw is the same, otherwise a dash-separated series like
    /// "5 - 4 - 4 - 4 - 4". nil for a fast move, or when `fastEnergyGain`
    /// is unavailable.
    func chargeCounts(fastEnergyGain: Int?) -> String? {
        guard !isFast, let gain = fastEnergyGain, gain > 0, energy > 0 else { return nil }
        var stored = 0
        var counts: [Int] = []
        for _ in 0..<5 {
            let needed = max(0, energy - stored)
            let fastMoves = Int((Double(needed) / Double(gain)).rounded(.up))
            counts.append(fastMoves)
            stored += fastMoves * gain - energy
        }
        if let first = counts.first, counts.allSatisfy({ $0 == first }) {
            return "Straight \(first)"
        }
        return counts.map(String.init).joined(separator: " - ")
    }
}
