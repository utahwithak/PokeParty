//
//  Pokemon.swift
//  PokeParty
//
//  A Pokémon entry from PvPoke's gamemaster data.
//

import Foundation

/// A Pokémon's static data: dex number, base stats, types and available moves.
nonisolated struct Pokemon: Decodable, Identifiable, Hashable {
    let dex: Int
    let speciesName: String
    let speciesId: String
    let baseStats: BaseStats
    let types: [String]
    let fastMoves: [String]
    let chargedMoves: [String]
    /// Moves only obtainable with an Elite TM.
    let eliteMoves: [String]?
    /// Moves no longer obtainable at all (event/legacy exclusives).
    let legacyMoves: [String]?
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

    /// Special availability of a move outside the normal TM pool.
    enum MoveDesignation {
        case elite
        case legacy

        var label: String {
            switch self {
            case .elite: return "Elite TM"
            case .legacy: return "Legacy"
            }
        }

        /// Tooltip text explaining the marker.
        var help: String {
            switch self {
            case .elite: return "Requires an Elite TM"
            case .legacy: return "Legacy move — no longer obtainable"
            }
        }
    }

    /// How `moveId` is specially obtained, or nil for a normally available move.
    func moveDesignation(for moveId: String) -> MoveDesignation? {
        if eliteMoves?.contains(moveId) == true { return .elite }
        if legacyMoves?.contains(moveId) == true { return .legacy }
        return nil
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
