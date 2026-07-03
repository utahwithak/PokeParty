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
    ///
    /// Clamping happens in the setters rather than in a `didSet`: under the
    /// `@Observable` macro these become computed properties, so assigning to
    /// them inside their own `didSet` re-enters the synthesized setter and
    /// recurses infinitely. The private stored backing properties are still
    /// tracked by observation.
    var atk: Int {
        get { atkStorage }
        set { atkStorage = clamp(newValue) }
    }
    var def: Int {
        get { defStorage }
        set { defStorage = clamp(newValue) }
    }
    var hp: Int {
        get { hpStorage }
        set { hpStorage = clamp(newValue) }
    }

    private var atkStorage: Int = 15
    private var defStorage: Int = 15
    private var hpStorage: Int = 15

    var ivs: IVs { IVs(atk: atk, def: def, hp: hp) }

    private func clamp(_ value: Int) -> Int { min(max(value, 0), 15) }
}
