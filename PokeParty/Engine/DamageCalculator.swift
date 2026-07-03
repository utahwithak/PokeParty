//
//  DamageCalculator.swift
//  PokeParty
//
//  Damage formula, ported from PvPoke's DamageCalculator.js.
//

import Foundation

enum DamageCalculator {
    /// Damage dealt by `move` from `attacker` to `defender` (charge defaults to 1).
    static func damage(_ attacker: BattlePokemon, _ defender: BattlePokemon, _ move: BattleMove, charge: Double = 1) -> Int {
        let effectiveness = defender.typeEffectiveness(for: move.type)
        let attackStat = attacker.getEffectiveStat(0)
        let defenseStat = defender.getEffectiveStat(1)
        let value = (Double(move.power) * move.stab * (attackStat / defenseStat)
                     * effectiveness * charge * 0.5 * DamageMultiplier.bonus)
        return Int(value.rounded(.down)) + 1
    }
}
