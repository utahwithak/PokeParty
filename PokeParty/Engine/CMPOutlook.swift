//
//  CMPOutlook.swift
//  PokeParty
//
//  Charge move priority: when both sides throw a charged move on the same
//  turn, the higher Attack stat goes first. Whether you win that tie depends
//  on IVs, so this compares the Attack range each side can have under the
//  league's CP cap.
//

import Foundation

nonisolated enum CMPOutlook: Equatable {
    /// Your Attack beats theirs at every IV spread they could have.
    case alwaysWins
    /// Whether you go first depends on the IVs.
    case ivDependent
    /// Their Attack beats yours at every IV spread.
    case cannotWin

    /// The lowest and highest Attack a species can reach under `cpCap`.
    /// A known `ivs` pins it to one value; otherwise every spread counts.
    static func attackRange(species: Pokemon, shadow: Bool, megaLevel: Int?,
                            isBestBuddy: Bool, ivs: IVs?, cpCap: Int) -> ClosedRange<Double>? {
        let levelCap = species.levelCap(megaLevel: megaLevel, isBestBuddy: isBestBuddy, cpCap: cpCap)
        let base = species.baseStats
        let multiplier = shadow ? DamageMultiplier.shadowAtk : 1
        let spreads: [IVs]
        if let ivs {
            spreads = [ivs]
        } else {
            spreads = (0...15).flatMap { atk in
                (0...15).flatMap { def in (0...15).map { IVs(atk: atk, def: def, hp: $0) } }
            }
        }
        var low = Double.greatestFiniteMagnitude
        var high = 0.0
        for spread in spreads {
            guard let stats = IVCalculator.stats(baseAtk: base.atk, baseDef: base.def, baseHp: base.hp,
                                                 ivs: spread, cpCap: cpCap, levelCap: levelCap)
            else { continue }
            low = min(low, stats.atk * multiplier)
            high = max(high, stats.atk * multiplier)
        }
        return low <= high ? low...high : nil
    }

    /// How the CMP tie plays out between `mine` and `theirs`. Equal Attack
    /// counts as winning, as the battle engine resolves it.
    static func compare(mine: ClosedRange<Double>, theirs: ClosedRange<Double>) -> CMPOutlook {
        if mine.lowerBound >= theirs.upperBound { return .alwaysWins }
        if mine.upperBound < theirs.lowerBound { return .cannotWin }
        return .ivDependent
    }
}
