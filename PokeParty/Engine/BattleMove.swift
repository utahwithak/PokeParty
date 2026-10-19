//
//  BattleMove.swift
//  PokeParty
//
//  A move in its battle-ready form, with derived flags and per-battle scratch
//  values. Ported from PvPoke's move objects (GameMaster.js + Pokemon.js).
//

import Foundation

/// Value type — the engine mutates `damage`, `dpe`, `stab`, and
/// `buffApplyMeter` during simulation (written back through the owning
/// BattlePokemon's stored arrays, eliminating ARC overhead).
nonisolated struct BattleMove {
    /// The immutable, string-heavy half of a move. Held by reference so copying
    /// a `BattleMove` (which the engine does constantly) is one retain instead
    /// of one per String/array field.
    final class Static: Sendable {
        let moveId: String
        let name: String
        let type: String
        let buffs: [Int]?
        let buffTarget: String?

        init(moveId: String, name: String, type: String, buffs: [Int]?, buffTarget: String?) {
            self.moveId = moveId
            self.name = name
            self.type = type
            self.buffs = buffs
            self.buffTarget = buffTarget
        }
    }

    private let shared: Static
    var moveId: String { shared.moveId }
    var name: String { shared.name }
    var type: String { shared.type }
    /// Index of `type` in `TypeChart.allTypes` (-1 if unknown) for flat lookups.
    let typeIndex: Int
    let power: Int
    let energy: Int          // charged-move cost; 0 for fast moves
    let energyGain: Int      // fast-move energy gained
    let cooldown: Int        // milliseconds
    let turns: Int           // duration in 500ms turns (fast moves)

    // Buff effects
    var buffs: [Int]? { shared.buffs }
    var buffTarget: String? { shared.buffTarget }
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
        let lowercasedType = move.type.lowercased()
        typeIndex = TypeChart.index(of: lowercasedType)
        power = move.power
        energy = move.energy
        energyGain = move.energyGain
        // Fast-move turn count: prefer explicit `turns`, else derive from cooldown.
        turns = move.turns ?? max(move.cooldown / 500, 1)
        cooldown = move.cooldown

        let b = move.buffs
        shared = Static(
            moveId: move.moveId, name: move.name, type: lowercasedType,
            buffs: b, buffTarget: move.buffTarget)
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
}
