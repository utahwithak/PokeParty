//
//  Consistency.swift
//  PokeParty
//
//  Faithful port of PvPoke's Pokemon.calculateConsistency() (src/js/pokemon/
//  Pokemon.js). A 0–100 measure of how bait-independent a moveset is; feeds the
//  team's Consistency grade. Every constant, comparison, special-case move id and
//  the operator structure of the big baiting condition match the source.
//

import Foundation

nonisolated enum Consistency {

    /// A charged/fast move in the form calculateConsistency needs. Reference type
    /// because the algorithm sorts the array and mutates `dpe` in place.
    private final class CMove {
        let moveId: String
        let name: String
        let type: String
        let energy: Int
        let energyGain: Int
        let buffs: [Int]?
        let buffApplyChance: Double
        let selfBuffing: Bool
        let selfDebuffing: Bool
        let selfAttackDebuffing: Bool
        let selfDefenseDebuffing: Bool
        var stab: Double
        var damage: Double
        var dpe: Double = 0

        init(move: Move, types: Set<String>) {
            moveId = move.moveId
            name = move.name
            type = move.type.lowercased()
            energy = move.energy
            energyGain = move.energyGain
            let b = move.buffs
            buffs = b
            let chance = move.buffApplyChanceValue ?? 0
            buffApplyChance = chance

            // Flag derivation, matching PvPoke's GameMaster.getMoveById exactly.
            let target = move.buffTarget
            if let b, chance == 1,
               target == "opponent" || (target == "self" && ((b.first ?? 0) > 0 || (b.count > 1 && b[1] > 0))) {
                selfBuffing = true
            } else {
                selfBuffing = false
            }
            if let b, target == "self", chance >= 0.5, move.moveId != "DRAGON_ASCENT",
               (b.first ?? 0) < 0 || (b.count > 1 && b[1] < 0) {
                selfDebuffing = true
            } else {
                selfDebuffing = false
            }
            // NOTE: PvPoke sets these for ANY move with a negative attack/defense
            // buff, regardless of target or chance.
            selfAttackDebuffing = (b?.first ?? 0) < 0
            selfDefenseDebuffing = (b?.count ?? 0) > 1 && (b?[1] ?? 0) < 0

            stab = types.contains(type) ? 1.2 : 1     // DamageMultiplier.STAB
            damage = Double(move.power) * stab         // power * stab (no floor)
        }
    }

    /// Consistency score in 0…100 for a member's moveset.
    static func score(
        fastMoveId: String,
        chargedMoveIds: [String],
        types: [String],
        movesById: [String: Move]
    ) -> Double {
        guard let fastData = movesById[fastMoveId] else { return 100 }
        let typeSet = Set(types.map { $0.lowercased() })
        let fast = CMove(move: fastData, types: typeSet)
        var charged = chargedMoveIds.compactMap { movesById[$0] }.map { CMove(move: $0, types: typeSet) }

        var consistencyScore = 1.0

        // Only calculated with exactly two charged moves; otherwise stays 1 (→100).
        if charged.count == 2 {
            var scenarios: [[Double]] = [[1, 1]]
            if charged[0].type != charged[1].type {
                scenarios.append([0.625, 1])
                scenarios.append([1, 0.625])
            }

            for eff in scenarios {
                // Deterministic starting order (by name, descending), then by DPE.
                charged.sort { $0.name > $1.name }
                charged[0].dpe = (charged[0].damage / Double(charged[0].energy)) * eff[0]
                charged[1].dpe = (charged[1].damage / Double(charged[1].energy)) * eff[1]
                charged.sort { $0.dpe > $1.dpe }

                // Power-Up Punch is spammable, so treat its value as doubled.
                if charged[1].moveId == "POWER_UP_PUNCH" {
                    charged[1].dpe *= 2
                    charged.sort { $0.dpe > $1.dpe }
                }

                let cycleFastMoves = (Double(charged[0].energy) / Double(fast.energyGain)).rounded(.up)
                var cycleFastDamage = fast.damage * cycleFastMoves
                let cycleDamage = cycleFastDamage + charged[0].damage
                if fast.type == charged[0].type {
                    cycleFastDamage *= eff[0]
                } else if fast.type == charged[1].type {
                    cycleFastDamage *= eff[1]
                }

                var factor = 1.0
                let energyDiff = charged[1].energy - charged[0].energy
                if charged[0].energy > charged[1].energy
                    || (charged[0].energy == charged[1].energy && charged[1].moveId == "ACID_SPRAY")
                    || (charged[0].selfAttackDebuffing && !charged[1].selfDebuffing && energyDiff <= 10)
                    || (charged[0].selfDebuffing && charged[0].energy > 50 && !charged[1].selfDebuffing && energyDiff <= 10) {
                    factor = (cycleFastDamage / cycleDamage)
                        + ((charged[0].damage / cycleDamage) * (charged[1].dpe / charged[0].dpe))

                    // Small energy gaps improve consistency (players play straight more).
                    if charged[1].energy < charged[0].energy && !charged[0].selfBuffing {
                        factor += (1 - factor) * (Double(charged[1].energy - 30) / Double(charged[0].energy - 30)) * 0.5
                    } else if charged[1].energy < charged[0].energy && charged[0].selfBuffing {
                        factor += (1 - factor) * (Double(charged[1].energy - 20) / Double(charged[0].energy - 20))
                    }
                }

                // Probabilistic buff moves add chaos, reducing consistency.
                var buffChanceFactor = 0.0
                for m in charged {
                    if let bs = m.buffs, m.buffApplyChance < 1, m.buffApplyChance > 0.15 {
                        let buffStages = Double(abs(bs.first ?? 0) + abs(bs.count > 1 ? bs[1] : 0))
                        let buffConsistency = 0.5 + abs(0.5 - m.buffApplyChance)
                        let buffsAsDamage = m.damage + (buffStages * 25 * (1 - buffConsistency))
                        buffChanceFactor += buffsAsDamage != 0 ? m.damage / buffsAsDamage : 1
                    } else {
                        buffChanceFactor += 1
                    }
                }
                buffChanceFactor /= Double(charged.count)

                consistencyScore *= factor * buffChanceFactor
            }

            consistencyScore = pow(consistencyScore, 1.0 / Double(scenarios.count))
        }

        // Per-move penalties (checked across the whole moveset, like `hasMove`).
        let allMoveIds = Set([fastMoveId] + chargedMoveIds)
        if allMoveIds.contains("POWER_UP_PUNCH") { consistencyScore *= 0.85 }
        if allMoveIds.contains("LUNGE") { consistencyScore *= 0.85 }
        if allMoveIds.contains("FEATHER_DANCE") { consistencyScore *= 0.75 }
        if allMoveIds.contains("BUBBLE_BEAM") { consistencyScore *= 0.75 }

        return (consistencyScore * 1000).rounded() / 10
    }
}
