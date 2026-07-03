//
//  TypeChart.swift
//  PokeParty
//
//  Type effectiveness, ported verbatim from PvPoke's DamageCalculator.js.
//

import Foundation

/// Damage multiplier constants (exactly as PvPoke defines them).
nonisolated enum DamageMultiplier {
    static let bonus = 1.2999999523162841796875
    static let superEffective = 1.60000002384185791015625
    static let resisted = 0.625
    static let doubleResisted = 0.390625
    static let stab = 1.2000000476837158203125
    static let shadowAtk = 1.2
    static let shadowDef = 0.83333331
}

nonisolated enum TypeChart {
    struct Traits {
        var weaknesses: Set<String> = []
        var resistances: Set<String> = []
        var immunities: Set<String> = []
    }

    /// Defensive traits for a given type (what it's weak/resistant/immune to).
    static func traits(for type: String) -> Traits {
        switch type {
        case "normal": Traits(weaknesses: ["fighting"], immunities: ["ghost"])
        case "fighting": Traits(weaknesses: ["flying", "psychic", "fairy"], resistances: ["rock", "bug", "dark"])
        case "flying": Traits(weaknesses: ["rock", "electric", "ice"], resistances: ["fighting", "bug", "grass"], immunities: ["ground"])
        case "poison": Traits(weaknesses: ["ground", "psychic"], resistances: ["fighting", "poison", "bug", "fairy", "grass"])
        case "ground": Traits(weaknesses: ["water", "grass", "ice"], resistances: ["poison", "rock"], immunities: ["electric"])
        case "rock": Traits(weaknesses: ["fighting", "ground", "steel", "water", "grass"], resistances: ["normal", "flying", "poison", "fire"])
        case "bug": Traits(weaknesses: ["flying", "rock", "fire"], resistances: ["fighting", "ground", "grass"])
        case "ghost": Traits(weaknesses: ["ghost", "dark"], resistances: ["poison", "bug"], immunities: ["normal", "fighting"])
        case "steel": Traits(weaknesses: ["fighting", "ground", "fire"], resistances: ["normal", "flying", "rock", "bug", "steel", "grass", "psychic", "ice", "dragon", "fairy"], immunities: ["poison"])
        case "fire": Traits(weaknesses: ["ground", "rock", "water"], resistances: ["bug", "steel", "fire", "grass", "ice", "fairy"])
        case "water": Traits(weaknesses: ["grass", "electric"], resistances: ["steel", "fire", "water", "ice"])
        case "grass": Traits(weaknesses: ["flying", "poison", "bug", "fire", "ice"], resistances: ["ground", "water", "grass", "electric"])
        case "electric": Traits(weaknesses: ["ground"], resistances: ["flying", "steel", "electric"])
        case "psychic": Traits(weaknesses: ["bug", "ghost", "dark"], resistances: ["fighting", "psychic"])
        case "ice": Traits(weaknesses: ["fighting", "fire", "steel", "rock"], resistances: ["ice"])
        case "dragon": Traits(weaknesses: ["dragon", "ice", "fairy"], resistances: ["fire", "water", "grass", "electric"])
        case "dark": Traits(weaknesses: ["fighting", "fairy", "bug"], resistances: ["ghost", "dark"], immunities: ["psychic"])
        case "fairy": Traits(weaknesses: ["poison", "steel"], resistances: ["fighting", "bug", "dark"], immunities: ["dragon"])
        default: Traits()
        }
    }

    /// Final type-effectiveness multiplier of a move type against defending types.
    static func effectiveness(moveType: String, targetTypes: [String]) -> Double {
        var effectiveness = 1.0
        let moveType = moveType.lowercased()
        for raw in targetTypes {
            let t = raw.lowercased()
            guard t != "none" else { continue }
            let traits = traits(for: t)
            if traits.weaknesses.contains(moveType) {
                effectiveness *= DamageMultiplier.superEffective
            } else if traits.resistances.contains(moveType) {
                effectiveness *= DamageMultiplier.resisted
            } else if traits.immunities.contains(moveType) {
                effectiveness *= DamageMultiplier.doubleResisted
            }
        }
        return effectiveness
    }
}
