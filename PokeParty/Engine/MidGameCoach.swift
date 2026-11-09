//
//  MidGameCoach.swift
//  PokeParty
//
//  Coaching once the lead matchup is over: somebody swapped or fainted, so the
//  battle is about shields and getting to a winnable endgame. Two sim-backed
//  numbers feed a set of heuristics:
//
//  • Shield swing — for the two Pokémon on the field, how much the 1v1 rating
//    moves if you spend a shield, and if they do. A big number means that shield
//    decides the matchup; a small one means spend it freely.
//
//  • Endgame ranking — each of your living Pokémon against everything the
//    opponent could still have (the revealed ones plus likely back-line picks)
//    with no shields left, so you know which one to close with and which is
//    spare to sacrifice.
//
//  The sims assume the energy each Pokémon would have fresh (it isn't on screen);
//  HP is used where the bars have been read. The heuristics are plain rules of
//  thumb and say so in their wording.
//

import Foundation

nonisolated enum MidGameCoach {

    /// What the screen shows, in the words the tips use.
    struct Situation: Sendable, Equatable {
        var myShields: Int
        var theirShields: Int
        /// Your Pokémon still standing, and theirs (revealed or not).
        var myAlive: Int
        var theirAlive: Int
        var myActiveName: String
        var theirActiveName: String
        /// HP left (0…1) of the two on the field, when read.
        var myActiveHP: Double?
        var theirActiveHP: Double?
        /// Names of your living Pokémon, in the order `Insight.endgame` indexes them.
        var myNames: [String]
        /// Index into `myNames` of the one on the field.
        var myActive: Int
    }

    /// How much the shields on the field matter, in rating points (0…1000 scale).
    struct ShieldSwing: Sendable, Equatable {
        /// Rating now, with the shields as they stand.
        let rating: Int
        /// Rating you lose if you spend a shield (0 when you have none).
        let costOfSpending: Int
        /// Rating you gain if they spend one (0 when they have none).
        let gainFromTheirs: Int
    }

    /// One of your Pokémon against the endgame the opponent could still have.
    struct EndgameEntry: Sendable, Equatable {
        /// Index into `Situation.myNames`.
        let index: Int
        /// Weighted share of likely opponents it beats with no shields (0…1).
        let winShare: Double
    }

    /// What the sims found.
    struct Insight: Sendable, Equatable {
        var swing: ShieldSwing?
        var endgame: [EndgameEntry]
        /// Bait and shield calls for the matchup on the field.
        var bait: BaitCall.Plan?
    }

    struct Plan: Sendable {
        let headline: String
        let tips: [String]
        let endgame: [Row]
        let bait: BaitCall.Plan?
        /// One of your Pokémon in the endgame ranking.
        struct Row: Sendable, Identifiable {
            enum Role: Sendable { case closer, sacrifice, neutral }
            var id: Int { index }
            let index: Int
            let name: String
            let winShare: Double
            let role: Role
        }
    }

    /// Rating swings at or above this decide a matchup; below `negligibleSwing`
    /// the shield barely matters.
    static let decisiveSwing = 120
    static let negligibleSwing = 50
    /// HP below which a Pokémon is on its last legs.
    static let lowHP = 0.3

    // MARK: - Simulating

    /// Runs the sims. `myTeam` / `opponentRevealed` are the living Pokémon;
    /// HP maps are keyed by index into them.
    static func analyze(
        myTeam: [BattlePokemon], myActive: Int, myHP: [Int: Double],
        opponentRevealed: [BattlePokemon], opponentActive: Int, opponentHP: [Int: Double],
        myShields: Int, theirShields: Int, opponentTeamSize: Int,
        pool: [TeamFinder.Candidate], movesById: [String: Move],
        theirSeenMoves: Set<String> = []
    ) -> Insight? {
        guard myTeam.indices.contains(myActive), opponentRevealed.indices.contains(opponentActive) else { return nil }

        func solve(_ mine: BattlePokemon, _ mineHP: Double?, _ theirs: BattlePokemon, _ theirHP: Double?,
                   _ myS: Int, _ theirS: Int) -> Int {
            var a = mine, b = theirs
            a.startingShields = myS
            b.startingShields = theirS
            if let mineHP { a.startHp = max(1, Int((mineHP * Double(a.stats.hp)).rounded())) }
            if let theirHP { b.startHp = max(1, Int((theirHP * Double(b.stats.hp)).rounded())) }
            return ShieldSearch.optimalSolution(a, b).ratingA
        }

        // Shield swing for the matchup on the field.
        let me = myTeam[myActive], them = opponentRevealed[opponentActive]
        let meHP = myHP[myActive], themHP = opponentHP[opponentActive]
        let now = solve(me, meHP, them, themHP, myShields, theirShields)
        let spent = myShields > 0 ? solve(me, meHP, them, themHP, myShields - 1, theirShields) : now
        let forced = theirShields > 0 ? solve(me, meHP, them, themHP, myShields, theirShields - 1) : now
        let swing = ShieldSwing(rating: now, costOfSpending: max(0, now - spent), gainFromTheirs: max(0, forced - now))

        // Everything they could still have, with how sure we are of each: the
        // revealed ones are certain, the guessed back-line picks by likelihood.
        var possibilities: [(pokemon: BattlePokemon, hp: Double?, weight: Double)] = opponentRevealed.enumerated().map {
            ($0.element, opponentHP[$0.offset], 1.0)
        }
        let slots = opponentTeamSize - opponentRevealed.count
        if slots > 0 {
            let guesses = BackLineGuess.predict(
                revealedIds: opponentRevealed.map(\.speciesId), revealedTypes: opponentRevealed.map(\.types),
                slots: slots, pool: pool, limit: 4)
            for guess in guesses {
                guard let candidate = pool.first(where: { $0.member.speciesId == guess.speciesId }),
                      let built = makeBattleTeam([candidate], movesById: movesById)?.first else { continue }
                possibilities.append((built, nil, guess.likelihood))
            }
        }

        // With no shields on either side: who beats the likely endgame.
        let totalWeight = possibilities.reduce(0) { $0 + $1.weight }
        var endgame: [EndgameEntry] = []
        for (index, mine) in myTeam.enumerated() where totalWeight > 0 {
            var share = 0.0
            for possibility in possibilities {
                let rating = solve(mine, myHP[index], possibility.pokemon, possibility.hp, 0, 0)
                let win = rating > 500 ? 1.0 : (rating == 500 ? 0.5 : 0)
                share += win * possibility.weight
            }
            endgame.append(EndgameEntry(index: index, winShare: share / totalWeight))
        }
        let bait = BaitCall.analyze(mine: me, theirs: them, myShields: myShields, theirShields: theirShields,
                                    myHP: meHP, theirHP: themHP,
                                    theirSeenMoves: theirSeenMoves)
        return Insight(swing: swing, endgame: endgame, bait: bait)
    }

    // MARK: - Advising

    /// Turns the situation and sim findings into the tip. Pure.
    static func plan(_ s: Situation, insight: Insight?) -> Plan {
        var tips: [String] = []

        // What the shields on the field are worth.
        if let swing = insight?.swing {
            if s.myShields > 0, swing.costOfSpending >= decisiveSwing {
                tips.append("Your shield is worth about \(swing.costOfSpending) rating points against \(s.theirActiveName) — save it for their biggest hit.")
            }
            if s.theirShields > 0, swing.gainFromTheirs >= decisiveSwing {
                tips.append("Making \(s.theirActiveName) spend a shield is worth about \(swing.gainFromTheirs) points — bait it with your cheaper move first.")
            }
            if s.myShields + s.theirShields > 0,
               swing.costOfSpending < negligibleSwing, swing.gainFromTheirs < negligibleSwing {
                tips.append("Shields barely change \(s.myActiveName) vs \(s.theirActiveName) — don't hold back on throwing.")
            }
        }

        // Rules of thumb for the shield count.
        switch (s.myShields, s.theirShields) {
        case (0, 0):
            tips.append("Nobody has a shield, so every charged move lands. Energy, HP and move count decide it — farm for the move that wins.")
        case (0, _):
            tips.append("You have no shields. Avoid trading charged moves into theirs you can't answer; farm down and let the right Pokémon take their big move.")
        case (_, 0):
            tips.append("They have no shields — your charged moves all land, so throw them as soon as you can.")
        default:
            if s.myShields > s.theirShields {
                tips.append("You're up on shields — apply pressure, and spend one early if it protects your closer.")
            } else if s.myShields < s.theirShields {
                tips.append("You're down on shields — make them spend theirs first and save yours for a move that would hurt.")
            } else {
                tips.append("Shields are even — bait with your cheaper charged move before committing the big one.")
            }
        }

        // Numbers on the board.
        if s.myAlive > s.theirAlive {
            tips.append("You have \(s.myAlive) Pokémon to their \(s.theirAlive) — you can afford to trade a Pokémon for a shield and energy.")
        } else if s.myAlive < s.theirAlive {
            tips.append("You're down \(s.myAlive) to \(s.theirAlive) — you need your Pokémon to win with shields or HP to spare, not trade evenly.")
        }

        // HP on the field.
        if let hp = s.myActiveHP, hp < lowHP, s.myAlive > 1 {
            tips.append("\(s.myActiveName) is nearly down. Throw any energy you have, or swap a teammate in to take their next charged move.")
        }
        if let hp = s.theirActiveHP, hp < lowHP {
            tips.append("\(s.theirActiveName) is nearly down — a few fast moves finish it, so skip shielding small hits.")
        }

        // Endgame.
        let bait = insight?.bait
        let insight = insight ?? Insight(swing: nil, endgame: [])
        var rows: [Plan.Row] = []
        // Drop entries from a stale sim whose team was bigger than the one on screen.
        let ranked = insight.endgame.filter { s.myNames.indices.contains($0.index) }.sorted { $0.winShare > $1.winShare }
        if s.myAlive > 1, let best = ranked.first, let worst = ranked.last, best.index != worst.index {
            let closerName = s.myNames[best.index], spareName = s.myNames[worst.index]
            let percent = Int((best.winShare * 100).rounded())
            tips.append("Save \(closerName) to close — it beats about \(percent)% of the endgames they could have with no shields left.")
            if best.index == s.myActive, (s.myActiveHP ?? 1) < 0.5 {
                tips.append("\(closerName) is your closer but it's hurt — don't take more damage than you have to.")
            }
            if worst.winShare < best.winShare - 0.2 {
                tips.append("\(spareName) is your most expendable — feed it into a bad matchup to burn a shield rather than your closer.")
            }
        }
        for entry in ranked {
            let role: Plan.Row.Role
            if ranked.count > 1, entry.index == ranked.first?.index { role = .closer }
            else if ranked.count > 1, entry.index == ranked.last?.index, entry.winShare < (ranked.first?.winShare ?? 0) - 0.2 { role = .sacrifice }
            else { role = .neutral }
            rows.append(Plan.Row(index: entry.index, name: s.myNames[entry.index], winShare: entry.winShare, role: role))
        }

        return Plan(headline: headline(s), tips: tips, endgame: rows, bait: bait)
    }

    /// The big line: where the shields stand.
    static func headline(_ s: Situation) -> String {
        switch (s.myShields, s.theirShields) {
        case (0, 0): return "Shields are down — play the endgame"
        case (0, _): return "No shields — play around theirs"
        case (_, 0): return "They're out of shields — press"
        default:
            if s.myShields > s.theirShields { return "Up on shields — keep the pressure on" }
            if s.myShields < s.theirShields { return "Down on shields — make them spend first" }
            return "Shields even — bait first"
        }
    }
}
