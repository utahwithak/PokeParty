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
    /// Canonical type order for integer-indexed effectiveness lookups.
    static let allTypes = ["normal", "fighting", "flying", "poison", "ground", "rock",
                           "bug", "ghost", "steel", "fire", "water", "grass",
                           "electric", "psychic", "ice", "dragon", "dark", "fairy"]

    private static let indexByType: [String: Int] =
        Dictionary(uniqueKeysWithValues: allTypes.enumerated().map { ($1, $0) })

    /// Index of a (lowercase) type name in `allTypes`, or -1 for unknown/"none".
    static func index(of type: String) -> Int {
        indexByType[type] ?? indexByType[type.lowercased()] ?? -1
    }

    /// Flat 18×18 matrix: `matrix[moveType * 18 + defenderType]`, built once
    /// from `traits(for:)` so it stays byte-identical to the PvPoke port.
    static let matrix: [Double] = {
        var m = [Double](repeating: 1, count: allTypes.count * allTypes.count)
        for (d, defender) in allTypes.enumerated() {
            let t = traits(for: defender)
            for (a, move) in allTypes.enumerated() {
                if t.weaknesses.contains(move) {
                    m[a * allTypes.count + d] = DamageMultiplier.superEffective
                } else if t.resistances.contains(move) {
                    m[a * allTypes.count + d] = DamageMultiplier.resisted
                } else if t.immunities.contains(move) {
                    m[a * allTypes.count + d] = DamageMultiplier.doubleResisted
                }
            }
        }
        return m
    }()

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
        let a = index(of: moveType)
        guard a >= 0 else { return 1 }
        var effectiveness = 1.0
        for raw in targetTypes {
            let d = index(of: raw)
            if d >= 0 { effectiveness *= matrix[a * allTypes.count + d] }
        }
        return effectiveness
    }
}
