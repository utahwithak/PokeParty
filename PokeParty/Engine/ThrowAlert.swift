//
//  ThrowAlert.swift
//  PokeParty
//
//  The prompt that fires when they throw a charged move: shield it or let it
//  through?
//
//  The shield call is the engine's own `ActionLogic.wouldShield`, the decision
//  the sims' opponent uses, with one override: a hit that would faint you is
//  always shielded if you can. Damage is against your HP as last read, which is
//  a few percent stale at best.
//

import Foundation

nonisolated enum ThrowAlert {

    enum Call: Equatable, Sendable {
        /// Spend a shield on it.
        case shield
        /// Take it and keep the shield.
        case takeIt
        /// You have no shield to spend.
        case noShields
    }

    struct Incoming: Equatable, Sendable {
        let moveName: String
        let call: Call
        /// Damage as a share of your current HP (0…1+).
        let damageShare: Double
        /// It would faint you.
        let lethal: Bool

        var headline: String {
            switch call {
            case .shield: return "Shield \(moveName)"
            case .takeIt: return "Tank \(moveName)"
            case .noShields: return "\(moveName) is coming"
            }
        }

        var detail: String {
            let percent = "\(Int((min(damageShare, 9.99) * 100).rounded()))%"
            switch (call, lethal) {
            case (.shield, true): return "It would faint you (\(percent) of your HP)."
            case (.shield, false): return "\(percent) of your HP, and the sim's AI would spend a shield on it."
            case (.takeIt, _): return "Only \(percent) of your HP — save the shield."
            case (.noShields, true): return "No shields left and it would faint you (\(percent) of your HP)."
            case (.noShields, false): return "No shields left; it takes \(percent) of your HP."
            }
        }
    }

    /// Their `moveId` just went off against your Pokémon. `attacker` is theirs,
    /// `defender` yours; HP as 0…1 fractions (nil = full). Energy isn't known, so the
    /// attacker is taken to have spent it all. Nil if the attacker doesn't have that move.
    static func incoming(
        moveId: String, attacker: BattlePokemon, defender: BattlePokemon,
        defenderShields: Int, attackerShields: Int,
        defenderHP: Double?, attackerHP: Double?
    ) -> Incoming? {
        guard attacker.chargedMoves.contains(where: { $0.moveId == moveId }) else { return nil }

        var a = attacker, b = defender
        a.startingShields = attackerShields
        b.startingShields = defenderShields
        a.startHp = startHP(attackerHP, of: a)
        b.startHp = startHP(defenderHP, of: b)
        a.reset(opponent: b)
        b.reset(opponent: a)
        a.energy = 0
        b.energy = 0
        guard let move = a.chargedMoves.first(where: { $0.moveId == moveId }) else { return nil }

        let damage = DamageCalculator.damage(a, b, move)
        let lethal = damage >= b.hp
        let call: Call
        if defenderShields <= 0 {
            call = .noShields
        } else if lethal || ActionLogic.wouldShield(Battle(a, b), a, b, move).value {
            call = .shield
        } else {
            call = .takeIt
        }
        return Incoming(moveName: move.name, call: call,
                        damageShare: Double(damage) / Double(max(1, b.hp)), lethal: lethal)
    }

    private static func startHP(_ fraction: Double?, of pokemon: BattlePokemon) -> Int {
        guard let fraction else { return 0 }   // 0 = full
        return max(1, Int((min(max(fraction, 0), 1) * Double(pokemon.stats.hp)).rounded()))
    }
}
