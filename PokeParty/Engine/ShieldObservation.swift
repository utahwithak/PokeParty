//
//  ShieldObservation.swift
//  PokeParty
//
//  RL milestone 1 (shield policy): the observation vector for a single shield
//  decision, captured at the instant a charged move is incoming (via
//  `Battle.shieldDecisionObserver`). Used both to log training data against the
//  ShieldSearch oracle and, later, to feed the learned policy at inference.
//
//  Every feature is revealed-info only — nothing a human player couldn't know
//  mid-battle: HP bars, shield counts, energy inferred by counting fast moves,
//  and the identity of the move being thrown. No opponent IVs, no unrevealed
//  moves are consulted beyond what the engine has already shown.
//

import Foundation

nonisolated enum ShieldObservation {

    /// Stable feature order; the Python trainer reads these names from the
    /// dataset metadata so the two sides can never drift silently.
    static let featureNames: [String] = [
        "def_hp_frac",            // defender HP / max HP
        "def_post_move_hp_frac",  // HP after eating the move unshielded (clamped ≥ -1)
        "def_shields",            // defender shields incl. this one (/2)
        "def_energy",             // defender energy (/100)
        "def_buff_atk",           // defender attack stage (/4)
        "def_buff_def",           // defender defense stage (/4)
        "att_hp_frac",            // attacker HP / max HP
        "att_shields",            // attacker shields (/2)
        "att_energy_after",       // attacker energy banked after this throw (/100)
        "att_buff_atk",           // attacker attack stage (/4)
        "att_buff_def",           // attacker defense stage (/4)
        "move_energy",            // incoming move cost (/100)
        "move_dmg_over_hp",       // incoming damage / defender current HP (clamped ≤ 2, /2)
        "move_dmg_over_max_hp",   // incoming damage / defender max HP
        "move_self_debuffing",    // 1 = the throw debuffs the attacker (e.g. Superpower)
        "move_debuffs_defender",  // 1 = shielding also negates a defender debuff (e.g. Icy Wind)
        "att_refill_turns",       // fast-move turns until the attacker can rethrow (/20)
        "att_cycle_dmg_over_hp",  // fast damage until rethrow + 1, vs defender HP (wouldShield's cycle quantity)
        "att_followup_dmg_over_hp", // biggest already-affordable follow-up charged move vs defender HP
        "att_fast_dpt_over_max_hp", // attacker fast damage per turn / defender max HP
        "def_fast_dpt_over_att_hp", // defender fast damage per turn / attacker current HP
        "def_best_charged_over_att_hp", // defender's best affordable charged move vs attacker HP
        "time_frac",              // battle clock (/240s)
        "opportunity",            // how many shield decisions this side has faced (/4)
    ]

    static var featureCount: Int { featureNames.count }

    /// Builds the feature vector for a shield decision. Call from a
    /// `Battle.shieldDecisionObserver` closure — i.e. after the attacker's energy
    /// was debited for `move` (the "energy after throw" convention below).
    static func capture(battle: Battle, defenderIndex: Int, opportunity: Int, move: BattleMove) -> [Double] {
        let defender = battle.pokemon[defenderIndex]
        let attacker = battle.pokemon[defenderIndex == 0 ? 1 : 0]

        let defMaxHp = Double(defender.stats.hp)
        let defHp = Double(defender.hp)
        let attMaxHp = Double(attacker.stats.hp)
        let attHp = Double(max(attacker.hp, 1))

        let damage = Double(DamageCalculator.damage(attacker, defender, move))
        let postMoveHpFrac = max((defHp - damage) / defMaxHp, -1)

        // Shielding negates opponent-targeted debuffs (see Battle.applyBuffs) —
        // an extra reason to shield moves like Icy Wind even at low damage.
        let debuffsDefender = move.buffTarget == "opponent"
            && move.buffApplyChance >= 1
            && (move.buffs ?? []).contains { $0 < 0 }

        // How long until the attacker can throw this move again, and the fast-move
        // chip we absorb while waiting (wouldShield's cycle-damage quantity).
        let fastDamage = Double(DamageCalculator.damage(attacker, defender, attacker.fastMove))
        let energyAfter = Double(attacker.energy) // already debited for `move`
        let gain = Double(max(attacker.fastMove.energyGain, 1))
        let fastAttacksToRefill = max(ceil((Double(move.energy) - energyAfter) / gain), 0)
        let refillTurns = fastAttacksToRefill * Double(attacker.fastMove.turns)
        let cycleDamage = fastAttacksToRefill * fastDamage + 1

        // The biggest charged move the attacker can already afford as a follow-up
        // (the "they have another one banked" signal).
        var followupDamage = 0.0
        for m in attacker.chargedMoves where Double(m.energy) <= energyAfter {
            followupDamage = max(followupDamage, Double(DamageCalculator.damage(attacker, defender, m)))
        }

        // Our own pressure: how hard we hit back if we keep farming / throw now.
        let defFastDamage = Double(DamageCalculator.damage(defender, attacker, defender.fastMove))
        let defFastDPT = defFastDamage / Double(max(defender.fastMove.turns, 1))
        var defBestCharged = 0.0
        for m in defender.chargedMoves where m.energy <= defender.energy {
            defBestCharged = max(defBestCharged, Double(DamageCalculator.damage(defender, attacker, m)))
        }

        let attFastDPT = fastDamage / Double(max(attacker.fastMove.turns, 1))

        return [
            defHp / defMaxHp,
            postMoveHpFrac,
            Double(defender.shields) / 2,
            Double(defender.energy) / 100,
            Double(defender.statBuffs[0]) / 4,
            Double(defender.statBuffs[1]) / 4,
            Double(attacker.hp) / attMaxHp,
            Double(attacker.shields) / 2,
            energyAfter / 100,
            Double(attacker.statBuffs[0]) / 4,
            Double(attacker.statBuffs[1]) / 4,
            Double(move.energy) / 100,
            min(damage / max(defHp, 1), 2) / 2,
            damage / defMaxHp,
            move.selfDebuffing ? 1 : 0,
            debuffsDefender ? 1 : 0,
            min(refillTurns, 20) / 20,
            min(cycleDamage / max(defHp, 1), 2) / 2,
            min(followupDamage / max(defHp, 1), 2) / 2,
            attFastDPT / defMaxHp,
            min(defFastDPT / attHp, 1),
            min(defBestCharged / attHp, 2) / 2,
            min(Double(battle.time) / 240_000, 1),
            min(Double(opportunity), 4) / 4,
        ]
    }
}
