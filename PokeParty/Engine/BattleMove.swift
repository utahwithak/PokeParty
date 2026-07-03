//
//  BattleMove.swift
//  PokeParty
//
//  A move in its battle-ready form, with derived flags and per-battle scratch
//  values. Ported from PvPoke's move objects (GameMaster.js + Pokemon.js).
//

import Foundation

/// Reference type: the engine mutates `damage`, `dpe`, `stab`, and
/// `buffApplyMeter` during simulation, matching PvPoke's mutable move objects.
nonisolated final class BattleMove {
    let moveId: String
    let name: String
    let type: String
    let power: Int
    let energy: Int          // charged-move cost; 0 for fast moves
    let energyGain: Int      // fast-move energy gained
    let cooldown: Int        // milliseconds
    let turns: Int           // duration in 500ms turns (fast moves)

    // Buff effects
    let buffs: [Int]?
    let buffTarget: String?  // "self" | "opponent" | "both"
    let buffApplyChance: Double
    let selfDebuffing: Bool
    let selfBuffing: Bool
    let selfAttackDebuffing: Bool
    let selfDefenseDebuffing: Bool

    // Per-battle scratch values
    var stab: Double = 1
    var damage: Int = 0
    var dpe: Double = 0      // damage per energy
    var buffApplyMeter: Double = 0

    var isFast: Bool { energy == 0 }

    init(from move: Move) {
        moveId = move.moveId
        name = move.name
        type = move.type.lowercased()
        power = move.power
        energy = move.energy
        energyGain = move.energyGain
        // Fast-move turn count: prefer explicit `turns`, else derive from cooldown.
        turns = move.turns ?? max(move.cooldown / 500, 1)
        cooldown = move.cooldown

        let b = move.buffs
        buffs = b
        buffTarget = move.buffTarget
        let chance = Double(move.buffApplyChanceValue ?? 0)
        buffApplyChance = chance

        // Derived flags (GameMaster.js logic).
        if let b, let target = move.buffTarget, target == "self",
           chance >= 0.5, move.moveId != "DRAGON_ASCENT", (b.first ?? 0) < 0 || (b.count > 1 && b[1] < 0) {
            selfDebuffing = true
            selfAttackDebuffing = (b.first ?? 0) < 0
            selfDefenseDebuffing = (b.count > 1 && b[1] < 0)
        } else {
            selfDebuffing = false
            selfAttackDebuffing = false
            selfDefenseDebuffing = false
        }

        if let b, chance == 1,
           (move.buffTarget == "opponent" || (move.buffTarget == "self" && ((b.first ?? 0) > 0 || (b.count > 1 && b[1] > 0)))) {
            selfBuffing = true
        } else {
            selfBuffing = false
        }

        if let b, chance < 1, chance > 0 {
            // Deterministic buff accumulator (PvPoke seeds the meter at the chance).
            buffApplyMeter = chance == 0.5 ? 0 : chance
        }
    }
}
