//
//  Team.swift
//  PokeParty
//
//  A user-built team of up to three Pokémon for the 3v3 Team Builder.
//  See docs/TeamBuilder-Plan.md (Milestone 1).
//

import Foundation

/// One member of a team: a species plus its chosen moveset.
nonisolated struct TeamMember: Identifiable, Hashable, Codable {
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

    /// Sets (or clears, with `nil`) a charged-move slot (0 = first, 1 =
    /// second). No-ops if `id` is already in the other slot, or if clearing
    /// would leave zero charged moves. Shared by every store that edits
    /// movesets slot-by-slot (Team Builder, Matchup Simulator, Breakpoints).
    mutating func setChargedMove(_ id: String?, slot: Int) {
        var charged = chargedMoveIds
        if let id {
            // Don't allow the same move in both charged slots.
            if charged.enumerated().contains(where: { $0.offset != slot && $0.element == id }) { return }
            if slot < charged.count {
                charged[slot] = id
            } else {
                // Pad any skipped earlier slots so `id` lands at `slot`,
                // not wherever `append` would put it (e.g. setting slot 1
                // before slot 0 is ever chosen).
                while charged.count < slot { charged.append("") }
                charged.append(id)
            }
        } else if slot < charged.count {
            charged.remove(at: slot)
        }
        // Drop trailing placeholders left behind by a removal (e.g. slot 1
        // cleared after being set without slot 0), so storage never holds a
        // dangling "" with nothing real after it.
        while charged.last == "" { charged.removeLast() }
        guard !charged.isEmpty else { return }
        chargedMoveIds = charged
    }
}

nonisolated extension TeamMember {
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
    /// The format this team was saved for (a `RankingFormat`'s `cup`/`cp`).
    /// Defaults to Great League for teams saved before league-scoping existed.
    var cup: String = "all"
    var cp: Int = 1500

    var isComplete: Bool { members.count == 3 }

    /// True when this team was saved for the given format.
    func matches(_ format: RankingFormat) -> Bool {
        cup == format.cup && cp == format.cp
    }

    fileprivate enum CodingKeys: String, CodingKey {
        case id, name, members, cup, cp
    }
}

extension Team {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id      = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name    = try c.decodeIfPresent(String.self, forKey: .name) ?? "New Team"
        members = try c.decodeIfPresent([TeamMember].self, forKey: .members) ?? []
        cup     = try c.decodeIfPresent(String.self, forKey: .cup) ?? "all"
        cp      = try c.decodeIfPresent(Int.self, forKey: .cp) ?? 1500
    }
}
