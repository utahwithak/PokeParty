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
}
