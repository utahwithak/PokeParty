//
//  OpponentNameMatcher.swift
//  PokeParty
//
//  Resolves an OCR'd opponent name to gamemaster species.
//

import Foundation

nonisolated enum OpponentNameMatcher {

    /// Species matching `ocrName`, best match first. More than one result
    /// means the name is ambiguous between forms (Zacian, Kyurem, Necrozma…)
    /// and the user should pick.
    ///
    /// Matching is by *word set*, so Pokémon GO's "Alolan Vulpix" and
    /// PvPoke's "Vulpix (Alolan)" agree. A full-name match wins outright;
    /// otherwise every non-shadow, non-Mega form sharing the base name is
    /// returned; otherwise the closest base name within a small edit distance
    /// (OCR slips like "Mewtwo" → "Mewtw0").
    static func candidates(for ocrName: String, in species: [Pokemon]) -> [Pokemon] {
        let wanted = words(in: ocrName)
        guard !wanted.isEmpty else { return [] }

        let exact = species.filter { words(in: $0.speciesName) == wanted }
        if !exact.isEmpty { return exact }

        // Base name = the words outside any parentheses: "Kyurem (Black)" → ["kyurem"].
        let forms = species.filter { !$0.isShadow && !$0.isMegaEvolution }
        let sameBase = forms.filter { baseWords($0.speciesName) == wanted }
        if !sameBase.isEmpty { return sameBase }

        let wantedKey = wanted.sorted().joined()
        var best: (distance: Int, matches: [Pokemon])?
        for candidate in forms {
            let key = baseWords(candidate.speciesName).sorted().joined()
            let limit = key.count >= 9 ? 2 : 1
            let distance = editDistance(wantedKey, key, limit: limit)
            guard distance <= limit else { continue }
            if let current = best, current.distance < distance { continue }
            if let current = best, current.distance == distance {
                best = (distance, current.matches + [candidate])
            } else {
                best = (distance, [candidate])
            }
        }
        return best?.matches ?? []
    }

    /// Every non-shadow, non-Mega form sharing a base name with `matches` —
    /// "Corsola" and "Corsola (Galarian)" are one family. An exact name match
    /// ("Corsola") never lists its regional variants, so this widens it for
    /// icon narrowing and for spotting an opponent that's already in a slot.
    static func family(of matches: [Pokemon], in species: [Pokemon]) -> [Pokemon] {
        let bases = Set(matches.map { baseWords($0.speciesName) })
        return species.filter {
            !$0.isShadow && !$0.isMegaEvolution && bases.contains(baseWords($0.speciesName))
        }
    }

    /// Narrows name-matched forms using the opponent's type icons: each form
    /// is scored by how well its types' colours line up with the icons
    /// seen (the icon count must match too), and only the best-fitting forms
    /// survive. If nothing fits convincingly — icons missed, or an unknown
    /// colour — every candidate is returned, so this can only help.
    static func narrow(_ candidates: [Pokemon], byIcons icons: [IconColor]) -> [Pokemon] {
        guard candidates.count > 1, !icons.isEmpty else { return candidates }

        let scored = candidates.map { (pokemon: $0, cost: typeCost(of: $0, against: icons)) }
        guard let best = scored.map(\.cost).min(), best <= maxAcceptableCost else { return candidates }
        // A form must also be clearly better than the rest to be singled out;
        // near-ties (similar colours) stay together for the user to pick.
        return scored.filter { $0.cost <= best + tieMargin }.map(\.pokemon)
    }

    /// Total colour distance for the best pairing of icons to a form's types.
    /// Infinite when the counts differ or a type has no known colour.
    private static let maxAcceptableCost = 120.0
    private static let tieMargin = 40.0

    private static func typeCost(of pokemon: Pokemon, against icons: [IconColor]) -> Double {
        let types = pokemon.displayTypes.compactMap { TypeColors.table[$0] }
        guard types.count == pokemon.displayTypes.count, types.count == icons.count else { return .infinity }
        if types.count == 1 { return icons[0].distance(to: types[0]) }
        // Two types: try both pairings, since slot order isn't relied on.
        let straight = icons[0].distance(to: types[0]) + icons[1].distance(to: types[1])
        let swapped = icons[0].distance(to: types[1]) + icons[1].distance(to: types[0])
        return min(straight, swapped)
    }

    private static func baseWords(_ name: String) -> Set<String> {
        let base = name.split(separator: "(", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? name
        return words(in: base)
    }

    /// Lowercased, accent-folded words, punctuation dropped.
    private static func words(in text: String) -> Set<String> {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return Set(folded.split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    /// Levenshtein distance, bailing out early once the length gap alone exceeds `limit`.
    private static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        if abs(a.count - b.count) > limit { return limit + 1 }
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        return previous[b.count]
    }
}
