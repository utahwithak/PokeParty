//
//  BaitCall.swift
//  PokeParty
//
//  Which charged move to throw first, and which of theirs to shield. It asks the
//  engine's own shield decision (`ActionLogic.wouldShield`, the one the sim's
//  opponent uses) about each charged move on both sides, so the call matches how
//  the sims play out. Nothing here needs energy, which isn't on screen: it's the
//  standing plan for the matchup, not a "throw now" prompt.
//
//  A bait is a move they'll spend a shield on that you'd rather lose a shield to
//  than your big one. So the useful cases are:
//    • they'd shield the cheap move  → throw it first; the big move then lands
//    • they'd shield both            → cheap first, to strip the shield
//    • they'd shield only the big one → the cheap move won't bait; it just chips
//    • they'd shield neither         → no bait; throw the efficient one
//
//  Their moves are only as good as the moveset we have for them (a guess until
//  the throws have been seen), and the decision assumes full energy-neutral
//  state, so the wording says "probably".
//

import Foundation

nonisolated enum BaitCall {

    /// One of your charged moves, and whether their AI would shield it.
    struct MyMove: Sendable, Equatable {
        let name: String
        let energy: Int
        /// Damage as a share of their current HP (0…1+).
        let damageShare: Double
        let theyShield: Bool
    }

    /// One of their charged moves, and whether to shield it.
    struct TheirMove: Sendable, Equatable {
        let name: String
        let energy: Int
        /// Damage as a share of your current HP (0…1+).
        let damageShare: Double
        let youShield: Bool
        /// Seen thrown this game, as opposed to a guess from the ranked moveset.
        var seen = false
    }

    struct Plan: Sendable, Equatable {
        /// Your charged moves, cheapest energy first.
        let mine: [MyMove]
        /// Their charged moves, cheapest energy first.
        let theirs: [TheirMove]
        /// Ready-to-show lines: the throw call, then the shield call.
        let lines: [String]
    }

    // MARK: - Analysing

    /// The call for `mine` against `theirs` with the shields and HP as given
    /// (HP as a 0…1 fraction, nil = full). Nil if either has no charged moves.
    static func analyze(
        mine: BattlePokemon, theirs: BattlePokemon,
        myShields: Int, theirShields: Int,
        myHP: Double? = nil, theirHP: Double? = nil,
        theirSeenMoves: Set<String> = []
    ) -> Plan? {
        guard !mine.chargedMoves.isEmpty, !theirs.chargedMoves.isEmpty else { return nil }

        var a = mine, b = theirs
        a.startingShields = myShields
        b.startingShields = theirShields
        a.startHp = hp(myHP, of: a)
        b.startHp = hp(theirHP, of: b)
        // Sets HP, shields and per-move damage the way a battle start does.
        a.reset(opponent: b)
        b.reset(opponent: a)
        // The throw has already spent the energy by the time the shield is chosen.
        a.energy = 0
        b.energy = 0
        let battle = Battle(a, b)

        let mineMoves = a.chargedMoves.map { move in
            MyMove(name: move.name, energy: move.energy,
                   damageShare: Double(DamageCalculator.damage(a, b, move)) / Double(max(1, b.hp)),
                   theyShield: theirShields > 0 && ActionLogic.wouldShield(battle, a, b, move).value)
        }.sorted(by: cheaperFirst)
        let theirMoves = b.chargedMoves.map { move in
            TheirMove(name: move.name, energy: move.energy,
                      damageShare: Double(DamageCalculator.damage(b, a, move)) / Double(max(1, a.hp)),
                      youShield: myShields > 0 && ActionLogic.wouldShield(battle, b, a, move).value,
                      seen: theirSeenMoves.contains(move.moveId))
        }.sorted { $0.energy != $1.energy ? $0.energy < $1.energy : $0.damageShare < $1.damageShare }

        return Plan(mine: mineMoves, theirs: theirMoves,
                    lines: lines(mine: mineMoves, theirs: theirMoves, myShields: myShields, theirShields: theirShields,
                                 theirName: b.speciesName))
    }

    private static func hp(_ fraction: Double?, of pokemon: BattlePokemon) -> Int {
        guard let fraction else { return 0 }   // 0 = full
        return max(1, Int((min(max(fraction, 0), 1) * Double(pokemon.stats.hp)).rounded()))
    }

    private static func cheaperFirst(_ x: MyMove, _ y: MyMove) -> Bool {
        x.energy != y.energy ? x.energy < y.energy : x.damageShare < y.damageShare
    }

    // MARK: - Wording

    /// The throw call, then the shield call. Pure, so the cases are testable.
    static func lines(mine: [MyMove], theirs: [TheirMove], myShields: Int, theirShields: Int, theirName: String) -> [String] {
        var lines: [String] = []

        if theirShields == 0 {
            if let best = mine.max(by: { $0.damageShare < $1.damageShare }) {
                lines.append("They have no shields — nothing to bait. Throw \(best.name) when you can; it hits hardest.")
            }
        } else if mine.count == 1, let only = mine.first {
            lines.append(only.theyShield
                ? "They'll probably shield \(only.name) — it's your only charged move, so throw it to strip the shield."
                : "They probably won't shield \(only.name) — throw it for the damage.")
        } else if let cheap = mine.first, let big = mine.last {
            switch (cheap.theyShield, big.theyShield) {
            case (true, false):
                lines.append("Bait with \(cheap.name) — they'll probably shield it — then \(big.name) lands.")
            case (true, true):
                lines.append("They'll probably shield both. Throw \(cheap.name) first to strip the shield, then \(big.name) lands.")
            case (false, true):
                lines.append("\(cheap.name) won't draw their shield, so it's just damage. They'll probably shield \(big.name) — throw it when you're ready to burn the shield.")
            case (false, false):
                lines.append("They probably won't shield either — no bait needed. Throw whichever is ready.")
            }
        }

        if myShields > 0 {
            let shield = theirs.filter(\.youShield), take = theirs.filter { !$0.youShield }
            // Moves seen thrown are known; the rest are the ranked guess.
            let caveat = theirs.allSatisfy(\.seen)
                ? " (moves seen thrown)"
                : " — \(theirName)'s unseen moves are a guess until they're thrown"
            switch (shield.isEmpty, take.isEmpty) {
            case (false, false):
                lines.append("Shield \(joined(shield.map(\.name))); take \(joined(take.map(\.name)))\(caveat).")
            case (false, true):
                lines.append("Shield \(joined(shield.map(\.name))) when thrown\(caveat).")
            case (true, false):
                lines.append("Don't spend a shield on \(joined(take.map(\.name))) — it's too weak to be worth one.")
            case (true, true):
                break
            }
        }
        return lines
    }

    private static func joined(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " or " + items[items.count - 1]
        }
    }
}
