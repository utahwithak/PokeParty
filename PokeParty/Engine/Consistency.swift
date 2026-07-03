//
//  Consistency.swift
//  PokeParty
//
//  Port of PvPoke's Pokemon.calculateConsistency() (plan §2.6): a 0–100 measure
//  of how bait-independent a moveset is. Feeds the team's Consistency grade.
//
//  APPROX: this captures the core of PvPoke's algorithm — DPE relationship of the
//  two charged moves, energy proximity, buff-chance penalty, and the flat
//  per-move penalties — using neutral (no-opponent) move damage. It is not yet a
//  byte-for-byte port; a few tie-break special cases are simplified. See M1.4 /
//  the plan for the exact reference to finish porting.
//

import Foundation

enum Consistency {

    /// Consistency score in 0…100 for a member's moveset.
    static func score(
        fastMoveId: String,
        chargedMoveIds: [String],
        types: [String],
        movesById: [String: Move]
    ) -> Double {
        let charged = chargedMoveIds.compactMap { movesById[$0] }
        // With fewer than two charged moves there is no bait decision to make.
        guard charged.count >= 2 else { return 100 }

        let lowerTypes = Set(types.map { $0.lowercased() })
        func stab(_ m: Move) -> Double { lowerTypes.contains(m.type.lowercased()) ? 1.2 : 1 }
        func neutralDamage(_ m: Move, _ eff: Double) -> Double {
            Double(m.power) * stab(m) * eff
        }
        func dpe(_ m: Move, _ eff: Double) -> Double {
            guard m.energy > 0 else { return 0 }
            var d = neutralDamage(m, eff) / Double(m.energy)
            if m.moveId == "POWER_UP_PUNCH" { d *= 2 }   // treated as high value
            return d
        }

        // Effectiveness scenarios: neutral always; if the two charged moves are
        // different types also test each being resisted.
        var scenarios: [[Double]] = [[1, 1]]
        if charged[0].type != charged[1].type {
            scenarios.append([0.625, 1])
            scenarios.append([1, 0.625])
        }

        var consistencyScore = 1.0
        for eff in scenarios {
            // Rank the two moves by DPE under this scenario.
            let d0 = dpe(charged[0], eff[0])
            let d1 = dpe(charged[1], eff[1])
            let (highDPE, lowDPE) = d0 >= d1 ? (d0, d1) : (d1, d0)

            // Identify cheaper (spammable) vs expensive move by energy cost.
            let zeroIsCheaper = charged[0].energy <= charged[1].energy
            let cheaper = zeroIsCheaper ? charged[0] : charged[1]
            let expensive = zeroIsCheaper ? charged[1] : charged[0]

            // Base factor: how close the moves' DPE are (relying on one move is
            // fine when both hit similarly hard).
            var factor = highDPE > 0 ? (lowDPE / highDPE) : 1

            // Energy-proximity bonus: if the cheaper move's energy is close to the
            // expensive one, the moveset is more consistent.
            let expE = Double(expensive.energy)
            let cheapE = Double(cheaper.energy)
            if expE > 30 {
                let proximity = max(0, min(1, (cheapE - 30) / (expE - 30)))
                factor += (1 - factor) * proximity * 0.5
            }
            factor = max(0, min(1, factor))

            // Buff-chance penalty for probabilistic buff moves (chance in .15…1).
            var buffChanceFactor = 1.0
            var buffCount = 0
            var buffSum = 0.0
            for m in charged {
                if let chance = m.buffApplyChanceValue, chance > 0.15, chance < 1, m.buffs != nil {
                    let buffConsistency = 0.5 + abs(0.5 - chance)
                    let stages = Double(m.buffs?.reduce(0) { $0 + abs($1) } ?? 0)
                    let dmg = neutralDamage(m, 1)
                    let buffsAsDamage = dmg + stages * 25 * (1 - buffConsistency)
                    buffSum += buffsAsDamage > 0 ? dmg / buffsAsDamage : 1
                } else {
                    buffSum += 1
                }
                buffCount += 1
            }
            if buffCount > 0 { buffChanceFactor = buffSum / Double(buffCount) }

            consistencyScore *= factor * buffChanceFactor
        }

        // Geometric mean across scenarios.
        consistencyScore = pow(consistencyScore, 1.0 / Double(scenarios.count))

        // Flat per-move penalties.
        let ids = Set(chargedMoveIds)
        if ids.contains("POWER_UP_PUNCH") { consistencyScore *= 0.85 }
        if ids.contains("LUNGE") { consistencyScore *= 0.85 }
        if ids.contains("FEATHER_DANCE") { consistencyScore *= 0.75 }
        if ids.contains("BUBBLE_BEAM") { consistencyScore *= 0.75 }

        return (consistencyScore * 1000).rounded() / 10
    }
}
