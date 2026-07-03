//
//  RankCheckerModel.swift
//  PokeParty
//
//  Observable input state for the IV Rank Checker.
//

import SwiftUI

/// Holds the user's Rank Checker inputs: the searched/selected Pokémon and the
/// IV values to evaluate. Results are computed on demand by the views.
@MainActor
@Observable
final class RankCheckerModel {
    var searchText: String = ""
    var selectedSpeciesId: String?

    /// Maximum level a Pokémon can be powered to (50 = max, 51 = Best Buddy).
    var levelCap: Double = 50

    /// IVs clamped to the valid 0–15 range.
    var atk: Int = 15 { didSet { atk = clamp(atk) } }
    var def: Int = 15 { didSet { def = clamp(def) } }
    var hp: Int = 15 { didSet { hp = clamp(hp) } }

    var ivs: IVs { IVs(atk: atk, def: def, hp: hp) }

    private func clamp(_ value: Int) -> Int { min(max(value, 0), 15) }
}
