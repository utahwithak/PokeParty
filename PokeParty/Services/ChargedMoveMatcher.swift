//
//  ChargedMoveMatcher.swift
//  PokeParty
//
//  Charged-move banners on the battle screen. When a charged move goes off the
//  screen says "<Pokémon> used <Move>!" ("Ampharos 1 used Trailblaze!" — the
//  "1" is the shadow icon). Your own charged-move buttons also show the move
//  names, in capitals, the whole time, so a move name alone means nothing: a
//  banner needs the word "used". The Pokémon's name says whose it is.
//

import Foundation

nonisolated enum ChargedMoveMatcher {

    /// A Pokémon on the field and the charged moves it could use.
    struct Mover: Equatable, Sendable {
        /// Its name as shown on screen ("Ampharos"), without any "(Shadow)" suffix.
        let name: String
        let moves: [(id: String, name: String)]

        static func == (a: Mover, b: Mover) -> Bool {
            a.name == b.name && a.moves.map(\.id) == b.moves.map(\.id)
        }
    }

    struct Match: Equatable, Sendable {
        let moveId: String
        /// Whose move it was; nil when the banner doesn't say and both could have it.
        let mine: Bool?
    }

    /// The charged moves named by `lines`' "used" banners, at most one per line.
    static func matchBanners(_ lines: [String], mine: Mover, theirs: Mover) -> [Match] {
        var found: [Match] = []
        for line in lines {
            guard let (prefix, suffix) = splitAtUsed(line), !suffix.isEmpty else { continue }

            // Who: the name before "used".
            let mineSaid = says(prefix, mine.name), theirsSaid = says(prefix, theirs.name)
            let owner: Bool? = (mineSaid && theirsSaid) ? nil : (mineSaid ? true : (theirsSaid ? false : nil))
            if !mineSaid && !theirsSaid && !prefix.isEmpty { continue }   // someone else's banner

            // What: the move after it, among that Pokémon's moves.
            var candidates: [(id: String, name: String, mine: Bool?)] = []
            for move in mine.moves where owner != false { candidates.append((move.id, move.name, owner == true ? true : nil)) }
            for move in theirs.moves where owner != true { candidates.append((move.id, move.name, owner == false ? false : nil)) }

            let text = letters(of: suffix)
            var best: (id: String, mine: Bool?, score: Int)?
            for candidate in candidates {
                let name = letters(of: candidate.name)
                guard name.count >= 3, let score = score(text, name) else { continue }
                if score > (best?.score ?? .min) { best = (candidate.id, candidate.mine, score) }
            }
            guard let best else { continue }
            // With no name to go on, a move only one side has settles it.
            var resolved = best.mine
            if resolved == nil {
                let inMine = mine.moves.contains { $0.id == best.id }, inTheirs = theirs.moves.contains { $0.id == best.id }
                if inMine != inTheirs { resolved = inMine }
            }
            if !found.contains(where: { $0.moveId == best.id }) {
                found.append(Match(moveId: best.id, mine: resolved))
            }
        }
        return found
    }

    /// "NICE!", "GREAT!" and "EXCELLENT!" — the rating of your charge-up swipe,
    /// shown after each charged move you throw.
    static func isThrowRating(_ line: String) -> Bool {
        ["nice", "great", "excellent"].contains(letters(of: line))
    }

    // MARK: - Parsing

    /// The text before and after the word "used", tolerating an OCR slip in it
    /// (including the common "d" read as "cl": "usecl").
    private static func splitAtUsed(_ line: String) -> (prefix: String, suffix: String)? {
        let words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let index = words.firstIndex(where: { word in
            let letters = letters(of: word)
            guard letters.count >= 3 && letters.count <= 5 else { return false }
            return [letters, letters.replacingOccurrences(of: "cl", with: "d")]
                .contains { FaintedMessage.editDistance($0, "used") <= 1 }
        }) else { return nil }
        return (words[..<index].joined(separator: " "), words[(index + 1)...].joined(separator: " "))
    }

    /// Whether `prefix` (the words before "used") names `name`: contains it, or
    /// is within a slip of it.
    private static func says(_ prefix: String, _ name: String) -> Bool {
        let text = letters(of: prefix), name = letters(of: name)
        guard text.count >= 3, name.count >= 3 else { return false }
        if text.contains(name) { return true }
        return abs(text.count - name.count) <= 1 && FaintedMessage.editDistance(text, name) <= max(1, name.count / 6)
    }

    /// How well `name` fits `text` (higher is better), or nil if it doesn't.
    private static func score(_ text: String, _ name: String) -> Int? {
        if text == name { return 1000 + name.count }
        if name.count >= 5, text.contains(name) { return 500 + name.count }
        // Close to the whole text: tolerate about one slip per six letters.
        let slips = max(1, name.count / 6)
        if name.count >= 4, abs(text.count - name.count) <= slips,
           FaintedMessage.editDistance(text, name) <= slips {
            return 100 + name.count
        }
        return nil
    }

    /// Lowercased letters only, accents folded: "Hydro Pump!" → "hydropump".
    private static func letters(of text: String) -> String {
        String(text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased().filter(\.isLetter))
    }
}
