//
//  BattleActiveMatcher.swift
//  PokeParty
//
//  Works out which of *your* Pokémon is on the field from its header panel.
//  Like the opponent's, the panel gives a name plus type icons — but a player's
//  Pokémon often carry a nickname or a numeric suffix ("Greninja158"), and the
//  CP can't be matched because a team rarely shares one IV spread and level
//  with the ranked data. So: name first (digits dropped), then type icons.
//

import Foundation

nonisolated enum BattleActiveMatcher {

    /// Index into `team` of the Pokémon on the field, or nil when the name and
    /// icons don't single one out. `team` holds the regular form of each member
    /// (a shadow's regular species), in team order.
    static func activeIndex(name: String, icons: [IconColor], team: [Pokemon]) -> Int? {
        guard !team.isEmpty else { return nil }

        let indices = { (pokemon: [Pokemon]) -> [Int] in
            pokemon.compactMap { match in team.firstIndex { $0.speciesId == match.speciesId } }
        }

        let cleaned = String(name.filter { $0.isLetter || " '-.".contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.filter(\.isLetter).count >= 3 {
            let byName = OpponentNameMatcher.candidates(for: cleaned, in: team)
            let named = indices(byName)
            if named.count == 1 { return named[0] }
            if named.count > 1 {
                let narrowed = indices(OpponentNameMatcher.narrow(byName, byIcons: icons))
                if narrowed.count == 1 { return narrowed[0] }
                return nil
            }
        }

        // No usable name (a nickname): let the type icons pick, if they can.
        guard !icons.isEmpty else { return nil }
        let narrowed = indices(OpponentNameMatcher.narrow(team, byIcons: icons))
        return narrowed.count == 1 ? narrowed[0] : nil
    }
}
