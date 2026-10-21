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

    /// A regular species that can also be caught as a Shadow.
    var isShadowEligible: Bool {
        tags?.contains("shadoweligible") ?? false
    }

    /// Whether this species carries a given gamemaster tag (e.g. "mega",
    /// "include1500", "duplicate1500") — used by cup eligibility filters.
    func hasTag(_ tag: String) -> Bool {
        tags?.contains(tag) ?? false
    }

    /// PvPoke's `getEvolutionStage()` (`GameMaster.js`/`Pokemon.js`), used by
    /// cup `evolution` filters (e.g. Little Cup's "unevolved with an
    /// evolution ahead of it"): 0 = no family at all, 1 = base of a
    /// multi-stage line, 2 = a middle stage (has both a parent and further
    /// evolutions), 3 = a final stage (has a parent, no further evolutions).
    var evolutionStage: Int {
        guard let family else { return 0 }
        let hasEvolutions = !(family.evolutions?.isEmpty ?? true)
        let hasParent = family.parent != nil
        if hasEvolutions, !hasParent { return 1 }
        if hasEvolutions, hasParent { return 2 }
        if !hasEvolutions, hasParent { return 3 }
        return 0
    }

    /// A Mega Evolution — banned from standard GO Battle League formats
    /// (Great/Ultra/Master), only legal in dedicated Mega cups.
    var isMegaEvolution: Bool {
        tags?.contains("mega") ?? false
    }

    /// The Mega Evolution(s) of this species (e.g. Charizard → Mega Charizard
    /// X/Y), or empty if it has none. Mega entries share their base form's
    /// dex number but don't link back to it via `family` the way regular
    /// evolutions do, so dex number is the reliable match.
    static func megaEvolutions(ofDex dex: Int, pokemonById: [String: Pokemon]) -> [Pokemon] {
        pokemonById.values.filter { $0.dex == dex && $0.isMegaEvolution }
    }

    /// Mimikyu's Disguise: a one-time block of the first charged move.
    var hasDisguise: Bool {
        formChange?.effect == "protect"
    }

    /// Cramorant's Gulp Missile: using Surf or Dive catches prey, and an
    /// unshielded charged hit while holding it fires a counterattack.
    var hasGulpMissile: Bool {
        speciesId == "cramorant"
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

    /// Resolves a ranking-entry species id to its species + shadow flag.
    /// Shadow Pokémon are their own gamemaster entries (tagged "shadow");
    /// falls back to stripping a "_shadow" suffix if the entry is ever missing.
    static func resolve(
        speciesId: String, pokemonById: [String: Pokemon]
    ) -> (species: Pokemon, shadow: Bool)? {
        var species = pokemonById[speciesId]
        if species == nil, speciesId.hasSuffix("_shadow") {
            species = pokemonById[String(speciesId.dropLast("_shadow".count))]
        }
        guard let species else { return nil }
        return (species, species.isShadow || speciesId.hasSuffix("_shadow"))
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

    /// A form transformation. `effect` ("protect" for Disguise) and the
    /// trigger fields (`battle_start` / `hp` for Minior) are what the engine reads.
    struct FormChange: Decodable, Hashable {
        let effect: String?
        let trigger: String?
        /// For `hp` triggers: the HP fraction below which the form changes.
        let amount: Double?
        let alternativeFormId: String?
        /// Time (ms) the form-change animation adds to the battle clock.
        let animationTime: Int?
    }

    /// An HP-triggered form shift (Minior's Shields Down), resolved against
    /// the other form's entry when the gamemaster loads — a single entry
    /// only knows the other form's id.
    struct HPFormShift: Decodable, Hashable {
        /// Shifts when HP / max HP falls below this fraction.
        let threshold: Double
        let animationTime: Int
        /// Base stats the Pokémon starts the battle with (Meteor for Minior).
        let initialBase: BaseStats
        /// Base stats after the shift (Core for Minior).
        let shiftedBase: BaseStats
    }

    /// Set by `resolvingFormShift(pokemonById:)`; nil for species without one.
    var hpFormShift: HPFormShift? = nil

    /// Resolves `hpFormShift` from `formChange`. A `battle_start` form (Minior
    /// Core) begins as its alternate form, whose own `hp` change shifts back;
    /// an `hp` form (Minior Meteor) begins as itself.
    func resolvingFormShift(pokemonById: [String: Pokemon]) -> Pokemon {
        guard let change = formChange, let altId = change.alternativeFormId,
              let alt = pokemonById[altId] else { return self }
        var copy = self
        switch change.trigger {
        case "battle_start":
            guard let back = alt.formChange, back.trigger == "hp", let amount = back.amount,
                  back.alternativeFormId == speciesId, alt.baseStats.hp == baseStats.hp else { return self }
            copy.hpFormShift = HPFormShift(
                threshold: amount, animationTime: back.animationTime ?? 0,
                initialBase: alt.baseStats, shiftedBase: baseStats)
        case "hp":
            guard let amount = change.amount, alt.baseStats.hp == baseStats.hp else { return self }
            copy.hpFormShift = HPFormShift(
                threshold: amount, animationTime: change.animationTime ?? 0,
                initialBase: baseStats, shiftedBase: alt.baseStats)
        default:
            return self
        }
        return copy
    }
}
