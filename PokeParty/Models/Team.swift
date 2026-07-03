//
//  Team.swift
//  PokeParty
//
//  A user-built team of up to three Pokémon for the 3v3 Team Builder.
//  See docs/TeamBuilder-Plan.md (Milestone 1).
//

import Foundation

/// One member of a team: a species plus its chosen moveset.
struct TeamMember: Identifiable, Hashable, Codable {
    var id = UUID()
    /// The gamemaster species id (e.g. "azumarill").
    var speciesId: String
    var fastMoveId: String
    /// Charged move ids (usually two; one is allowed).
    var chargedMoveIds: [String]
    var shadow: Bool = false

    init(id: UUID = UUID(), speciesId: String, fastMoveId: String,
         chargedMoveIds: [String], shadow: Bool = false) {
        self.id = id
        self.speciesId = speciesId
        self.fastMoveId = fastMoveId
        self.chargedMoveIds = chargedMoveIds
        self.shadow = shadow
    }
}

/// A named team of up to three members. Codable so it can be persisted or
/// shared later (see plan Q3).
struct Team: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String = "New Team"
    var members: [TeamMember] = []

    var isComplete: Bool { members.count == 3 }
}
