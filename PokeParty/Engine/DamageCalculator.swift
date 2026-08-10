//
//  DamageCalculator.swift
//  PokeParty
//
//  Damage formula, ported from PvPoke's DamageCalculator.js.
//

import Foundation

nonisolated enum DamageCalculator {
    /// Damage dealt by `move` from `attacker` to `defender`.
    static func damage(_ attacker: BattlePokemon, _ defender: BattlePokemon, _ move: BattleMove) -> Int {
        let effectiveness = defender.typeEffectiveness(forTypeIndex: move.typeIndex)
        let attackStat = attacker.getEffectiveStat(0)
        let defenseStat = defender.getEffectiveStat(1)
        let value = (Double(move.power) * move.stab * (attackStat / defenseStat)
                     * effectiveness * 0.5 * DamageMultiplier.bonus)
        return Int(value.rounded(.down)) + 1
    }

    /// Damage with an explicit attack-buff offset — avoids copying BattlePokemon
    /// in DP searches where only the buff stage changes between hypothetical states.
    static func damage(_ attacker: BattlePokemon, _ defender: BattlePokemon, _ move: BattleMove, atkBuff: Int) -> Int {
        let combinedStage = attacker.statBuffs[0] + atkBuff
        guard combinedStage != 0 else { return damage(attacker, defender, move) }
        let stage = min(max(combinedStage, -4), 4)
        let buffMult: Double = stage > 0 ? (4.0 + Double(stage)) / 4.0 : 4.0 / (4.0 - Double(stage))
        var atkStat = attacker.stats.atk * buffMult
        if attacker.shadow { atkStat *= attacker.shadowAtkMult }
        let effectiveness = defender.typeEffectiveness(forTypeIndex: move.typeIndex)
        let defenseStat = defender.getEffectiveStat(1)
        let value = Double(move.power) * move.stab * (atkStat / defenseStat) * effectiveness * 0.5 * DamageMultiplier.bonus
        return Int(value.rounded(.down)) + 1
    }
}
