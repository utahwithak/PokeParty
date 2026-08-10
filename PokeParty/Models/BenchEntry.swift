//
//  BenchEntry.swift
//  PokeParty
//
//  A Pokémon the player personally owns, stored in their bench with their
//  actual IVs and chosen moveset.
//

import Foundation

struct BenchEntry: Identifiable, Hashable, Codable {
    var id = UUID()
    var speciesId: String
    /// Optional custom label; falls back to the species name when empty.
    var nickname: String = ""
    var fastMoveId: String
    /// Up to two charged move ids.
    var chargedMoveIds: [String] = []
    var shadow: Bool = false
    /// Which league this Pokémon is built for. IVs optimised for GL differ
    /// from those for UL or ML.
    var league: League = .great
    /// The player's actual IVs (0–15 each). nil = use PvP-optimal stats for
    /// the entry's league CP cap.
    var ivs: IVs? = nil
    /// Best Buddy bonus: allows the Pokémon to be powered up one extra level
    /// (level 51 instead of 50), raising its stats and CP ceiling.
    var isBestBuddy: Bool = false

    /// Converts this bench entry into a team member, carrying IVs and Best Buddy flag.
    func asTeamMember() -> TeamMember {
        TeamMember(
            speciesId: speciesId,
            fastMoveId: fastMoveId,
            chargedMoveIds: chargedMoveIds,
            shadow: shadow,
            ivs: ivs,
            isBestBuddy: isBestBuddy
        )
    }

    fileprivate enum CodingKeys: String, CodingKey {
        case id, speciesId, nickname, fastMoveId, chargedMoveIds, shadow, league, ivs, isBestBuddy
    }
}

// Extension keeps init(from:) out of the struct body so Swift still synthesises
// the memberwise init. Custom inits in extensions never suppress it.
extension BenchEntry {
    // Swift's synthesised decoder calls decode(_:forKey:) for non-Optional
    // properties, throwing if a key is absent — breaking migration when new
    // fields are added. decodeIfPresent with defaults handles older saved data.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id             = try c.decode(UUID.self, forKey: .id)
        speciesId      = try c.decode(String.self, forKey: .speciesId)
        nickname       = try c.decodeIfPresent(String.self,   forKey: .nickname)       ?? ""
        fastMoveId     = try c.decode(String.self, forKey: .fastMoveId)
        chargedMoveIds = try c.decodeIfPresent([String].self, forKey: .chargedMoveIds) ?? []
        shadow         = try c.decodeIfPresent(Bool.self,     forKey: .shadow)         ?? false
        league         = try c.decodeIfPresent(League.self,   forKey: .league)         ?? .great
        ivs            = try c.decodeIfPresent(IVs.self,      forKey: .ivs)
        isBestBuddy    = try c.decodeIfPresent(Bool.self,     forKey: .isBestBuddy)    ?? false
    }
}
