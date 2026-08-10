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
    /// The player's actual IVs for this Pokémon. nil = use PvP-optimal stats.
    var ivs: IVs? = nil
    /// Best Buddy level bonus: powers the Pokémon up one extra level (51 vs 50).
    var isBestBuddy: Bool = false

    init(id: UUID = UUID(), speciesId: String, fastMoveId: String,
         chargedMoveIds: [String], shadow: Bool = false, ivs: IVs? = nil,
         isBestBuddy: Bool = false) {
        self.id = id
        self.speciesId = speciesId
        self.fastMoveId = fastMoveId
        self.chargedMoveIds = chargedMoveIds
        self.shadow = shadow
        self.ivs = ivs
        self.isBestBuddy = isBestBuddy
    }

    fileprivate enum CodingKeys: String, CodingKey {
        case id, speciesId, fastMoveId, chargedMoveIds, shadow, ivs, isBestBuddy
    }
}

extension TeamMember {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id             = try c.decodeIfPresent(UUID.self,      forKey: .id)             ?? UUID()
        speciesId      = try c.decode(String.self, forKey: .speciesId)
        fastMoveId     = try c.decode(String.self, forKey: .fastMoveId)
        chargedMoveIds = try c.decode([String].self, forKey: .chargedMoveIds)
        shadow         = try c.decodeIfPresent(Bool.self,      forKey: .shadow)         ?? false
        ivs            = try c.decodeIfPresent(IVs.self,       forKey: .ivs)
        isBestBuddy    = try c.decodeIfPresent(Bool.self,      forKey: .isBestBuddy)    ?? false
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
