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
        return ChargeTiming.format(Self.readyCounts(cost: energy, gain: gain, throwCount: 5))
    }

    /// One-line summary for a move picker: a fast move's duration and energy
    /// gain, or a charged move's cost and how many fast moves it takes.
    func detailText(fastEnergyGain: Int?) -> String {
        if isFast {
            let turnCount = turns ?? cooldown / 500
            return "\(turnCount) turn\(turnCount == 1 ? "" : "s") · +\(energyGain) energy"
        }
        guard let gain = fastEnergyGain, gain > 0, energy > 0 else { return "\(energy) energy" }
        let counts = Self.readyCounts(cost: energy, gain: gain, throwCount: 5)
        if let first = counts.first, counts.allSatisfy({ $0 == first }) {
            return "\(energy) energy · every \(first) fast move\(first == 1 ? "" : "s")"
        }
        return "\(energy) energy · fast moves: " + counts.map(String.init).joined(separator: " - ")
    }

    /// Fast moves needed purely for energy before each of the next
    /// `throwCount` throws, carrying leftover energy between them.
    static func readyCounts(cost: Int, gain: Int, throwCount: Int) -> [Int] {
        var stored = 0
        var counts: [Int] = []
        for _ in 0..<throwCount {
            let needed = max(0, cost - stored)
            let fastMoves = Int((Double(needed) / Double(gain)).rounded(.up))
            counts.append(fastMoves)
            stored += fastMoves * gain - cost
        }
        return counts
    }
}
