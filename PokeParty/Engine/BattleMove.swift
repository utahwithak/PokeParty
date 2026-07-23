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
    /// Index of `type` in `TypeChart.allTypes` (-1 if unknown) for flat lookups.
    let typeIndex: Int
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
        typeIndex = TypeChart.index(of: type)
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
        if let b, move.buffTarget == "self",
           chance >= 0.5, move.moveId != "DRAGON_ASCENT", (b.first ?? 0) < 0 || (b.count > 1 && b[1] < 0) {
            selfDebuffing = true
        } else {
            selfDebuffing = false
        }
        // PvPoke sets these for ANY move carrying a negative attack/defense buff,
        // regardless of target or apply chance (used by move-ordering and shield AI).
        selfAttackDebuffing = (b?.first ?? 0) < 0
        selfDefenseDebuffing = (b?.count ?? 0) > 1 && (b?[1] ?? 0) < 0

        if let b, chance == 1,
           (move.buffTarget == "opponent" || (move.buffTarget == "self" && ((b.first ?? 0) > 0 || (b.count > 1 && b[1] > 0)))) {
            selfBuffing = true
        } else {
            selfBuffing = false
        }

        if b != nil, chance < 1, chance > 0 {
            // Deterministic buff accumulator (PvPoke seeds the meter at the chance).
            buffApplyMeter = chance == 0.5 ? 0 : chance
        }
    }

    /// Copies every field (used to clone a Pokémon into a throwaway battle).
    private init(copy m: BattleMove) {
        moveId = m.moveId; name = m.name; type = m.type; typeIndex = m.typeIndex; power = m.power
        energy = m.energy; energyGain = m.energyGain; cooldown = m.cooldown; turns = m.turns
        buffs = m.buffs; buffTarget = m.buffTarget; buffApplyChance = m.buffApplyChance
        selfDebuffing = m.selfDebuffing; selfBuffing = m.selfBuffing
        selfAttackDebuffing = m.selfAttackDebuffing; selfDefenseDebuffing = m.selfDefenseDebuffing
        stab = m.stab; damage = m.damage; dpe = m.dpe; buffApplyMeter = m.buffApplyMeter
    }

    func clone() -> BattleMove { BattleMove(copy: self) }
}
