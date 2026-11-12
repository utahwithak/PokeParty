//
//  CoachNarrator.swift
//  PokeParty
//
//  Puts the sim's findings the way an expert watching you play would say them:
//  what to do with the Pokémon that's out, how to treat shields, which move to
//  throw first, and when. No percentages — those stay in the sims. The result is
//  one short entry per matchup, written into the battle log as the game moves on.
//
//  Pure: everything it needs is passed in, so the wording is testable.
//

import Foundation

nonisolated enum CoachNarrator {

    /// Who wins a charged-move tie (both thrown on the same tick): the higher Attack.
    enum CMP: Sendable, Equatable { case mine, theirs, even }

    /// When to throw, from the two fast moves' rhythm.
    struct Timing: Sendable, Equatable {
        /// The charged move to throw first (your cheapest).
        let move: String
        /// Fast moves between throws, starting from nothing.
        let counts: [Int]
        /// The two fast-move cycles are misaligned, so a throw has to be timed
        /// against theirs, not just made when it's ready.
        let timingMatters: Bool
        let cmp: CMP
    }

    struct Context: Sendable {
        let myName: String
        let theirName: String
        let myShields: Int
        let theirShields: Int
        /// The lead script, while it's still the lead matchup.
        var lead: LeadCoach.Plan?
        /// What the rollouts say to do with the Pokémon on the field.
        var action: BattleCoach.Option.Action = .stay
        /// Who to switch to, when `action` is a switch.
        var switchName: String?
        /// Who to bring in if the one on the field faints (the best other option).
        var backup: String?
        /// Bait and shield calls for the matchup (mid-game).
        var bait: BaitCall.Plan?
        /// Your endgame closer, when it isn't the one on the field.
        var closer: String?
        var timing: Timing?
    }

    // MARK: - The entry

    /// What a line of the entry is about, so the log can give each its own icon and
    /// the eye can jump straight to the one it needs mid-battle.
    enum LineKind: String, Codable, Sendable {
        /// The call itself: stay, switch, or the lead's headline.
        case call
        /// Which charged move to throw, and when it's worth throwing.
        case throwMove
        /// When to throw, by fast-move count.
        case timing
        /// Which of their moves to shield or tank.
        case shield
        /// The lead script's other steps, in the order they happen.
        case plan
        /// Who comes in if this one faints.
        case backup
        /// Who to keep healthy for the endgame.
        case closer
    }

    /// One short line of an entry.
    struct Line: Codable, Hashable, Sendable {
        let kind: LineKind
        let text: String
    }

    /// The matchup's lines, each short enough to take in at a glance: the call first,
    /// then what to throw and when, then shields, then the fallbacks. Lead scripts
    /// keep their own order, since that's the order the steps happen in.
    static func lines(_ c: Context) -> [Line] {
        var lines: [Line] = []

        if let lead = c.lead {
            lines.append(Line(kind: .call, text: lead.headline + "."))
            lines.append(contentsOf: lead.steps.map { Line(kind: leadStepKind($0), text: $0) })
            if let timing = c.timing, let text = timingLine(timing, fromStart: true) {
                lines.append(Line(kind: .timing, text: text))
            }
        } else {
            switch c.action {
            case .switchTo:
                lines.append(Line(kind: .call, text: "Switch to \(c.switchName ?? "your next Pokémon")."))
            case .stay:
                lines.append(Line(kind: .call, text: "Stay in with \(c.myName)."))
            }
            let bait = (c.bait?.lines ?? []).map { trimmed($0, theirName: c.theirName) }
            lines.append(contentsOf: bait.filter { !isShieldLine($0) }.map { Line(kind: .throwMove, text: $0) })
            if let timing = c.timing, let text = timingLine(timing, fromStart: false) {
                lines.append(Line(kind: .timing, text: text))
            }
            lines.append(contentsOf: bait.filter(isShieldLine).map { Line(kind: .shield, text: $0) })
        }

        if case .stay = c.action, let backup = c.backup {
            lines.append(Line(kind: .backup, text: "If \(c.myName) faints, bring in \(backup)."))
        }
        if let closer = c.closer {
            lines.append(Line(kind: .closer, text: "Keep \(closer) healthy — it's your closer."))
        }
        return lines
    }

    /// The entry as plain text.
    static func entry(_ c: Context) -> String {
        lines(c).map(\.text).joined(separator: " ")
    }

    /// A lead step's kind: what to shield, what to throw, or just the order of play.
    private static func leadStepKind(_ step: String) -> LineKind {
        if step.hasPrefix("Throw") { return .throwMove }
        if step.lowercased().contains("shield") { return .shield }
        return .plan
    }

    private static func isShieldLine(_ line: String) -> Bool {
        line.hasPrefix("Shield") || line.hasPrefix("Don't spend")
    }

    /// A bait line without its hedge. The log is read at a glance; the hedge ("their moves
    /// are a guess until they're thrown") is true of every line and says nothing to act on.
    private static func trimmed(_ line: String, theirName: String) -> String {
        var text = line
        for hedge in [" (moves seen thrown)", " — \(theirName)'s unseen moves are a guess until they're thrown"] {
            text = text.replacingOccurrences(of: hedge, with: "")
        }
        return text
    }

    // MARK: - Timing

    /// "Throw Foul Play on fast move 3, 5, 7" — or, mid-game when the count has
    /// moved on, the gaps between throws. Ends with who wins a tie.
    static func timingLine(_ timing: Timing, fromStart: Bool) -> String? {
        guard !timing.counts.isEmpty else { return nil }
        var parts: [String] = []

        if fromStart {
            var total = 0
            let points = timing.counts.prefix(3).map { gap -> String in total += gap; return String(total) }
            parts.append("Throw \(timing.move) on fast move \(points.joined(separator: ", ")).")
        } else if let first = timing.counts.first, timing.counts.allSatisfy({ $0 == first }) {
            parts.append("Throw \(timing.move) every \(first) fast moves.")
        } else {
            let gaps = timing.counts.prefix(3).map(String.init)
            parts.append("Throw \(timing.move) after \(gaps[0]) fast moves, then \(gaps.dropFirst().joined(separator: ", ")).")
        }

        // Only worth saying when a tie can happen.
        if timing.timingMatters {
            switch timing.cmp {
            case .mine: parts.append("You win a tie, so throw as soon as it's ready.")
            case .theirs: parts.append("They win a tie — don't throw on the tick their fast move lands; go a tick before it.")
            case .even: parts.append("Ties are a coin flip — throw just before their fast move lands to avoid one.")
            }
        }
        return parts.joined(separator: " ")
    }

    /// The Attack comparison that decides a charged-move tie.
    static func cmp(mine: Double, theirs: Double) -> CMP {
        if abs(mine - theirs) < 0.0001 { return .even }
        return mine > theirs ? .mine : .theirs
    }

    /// Timing for your cheapest charged move against their fast move, or nil
    /// when the moves can't be timed (no energy gain, no charged move).
    static func timing(
        myFast: Move, myCharged: [Move], theirFast: Move, myAttack: Double, theirAttack: Double
    ) -> Timing? {
        guard let first = myCharged.min(by: { $0.energy != $1.energy ? $0.energy < $1.energy : $0.power < $1.power }),
              let result = ChargeTiming.throwCounts(cost: first.energy, pokeFast: myFast, opponentFast: theirFast)
        else { return nil }
        return Timing(move: first.name, counts: result.timed, timingMatters: result.timingMatters,
                      cmp: cmp(mine: myAttack, theirs: theirAttack))
    }
}
