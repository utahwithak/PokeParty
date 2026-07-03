//
//  Pokemon.swift
//  PokeParty
//
//  A Pokémon entry from PvPoke's gamemaster data.
//

import Foundation

/// A Pokémon's static data: dex number, base stats, types and available moves.
struct Pokemon: Decodable, Identifiable, Hashable {
    let dex: Int
    let speciesName: String
    let speciesId: String
    let baseStats: BaseStats
    let types: [String]
    let fastMoves: [String]
    let chargedMoves: [String]
    let tags: [String]?
    let released: Bool?
    let family: Family?
    let formChange: FormChange?

    var id: String { speciesId }

    /// Types with the placeholder "none" (used for single-type Pokémon) removed.
    var displayTypes: [String] {
        types.filter { $0 != "none" }
    }

    /// Shadow Pokémon (1.2× attack, 0.833× defense in battle).
    var isShadow: Bool {
        tags?.contains("shadow") ?? false
    }

    /// Mimikyu's Disguise: a one-time block of the first charged move.
    var hasDisguise: Bool {
        formChange?.effect == "protect"
    }

    struct BaseStats: Decodable, Hashable {
        let atk: Int
        let def: Int
        let hp: Int
    }

    struct Family: Decodable, Hashable {
        let id: String?
        let parent: String?
        let evolutions: [String]?
    }

    /// A form transformation (only `effect` is needed — e.g. "protect" for Disguise).
    struct FormChange: Decodable, Hashable {
        let effect: String?
    }
}
