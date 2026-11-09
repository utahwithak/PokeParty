//
//  LeadCoach.swift
//  PokeParty
//
//  Coaching for the lead matchup — the one fight where nothing is hidden: both
//  Pokémon are at full health with no energy. Two things come out of the sims:
//
//  • A verdict per shield count. The 1v1 is solved with optimal shield play on
//    both sides at 2–2, 1–1 and 0–0, so "you win the double-shield easily" and
//    "it's even once the shields are gone" are read straight off the ratings.
//
//  • A script. The lead is played through the full 3v3 engine (same learned
//    shield / switch / farm policies as the rest of the coach) against sampled
//    opponent teams, and the opening stretch of each recorded battle is read
//    off: which of their charged moves got shielded, which of yours were
//    thrown and in what order, whether it farmed first, and how the stretch
//    ended — a win, a loss, or you swapping out. The most common line becomes
//    the steps ("Shield their first X, throw Y, then swap out").
//

import Foundation

nonisolated enum LeadCoach {

    /// How good a matchup is for you, from a 0…1000 battle rating (500 = even).
    enum Verdict: Sendable, Equatable {
        case dominant, favored, close, unfavored, hopeless

        init(rating: Int) {
            switch rating {
            case 650...: self = .dominant
            case 550..<650: self = .favored
            case 450..<550: self = .close
            case 350..<450: self = .unfavored
            default: self = .hopeless
            }
        }

        /// "you win easily", for use after a shield count.
        var phrase: String {
            switch self {
            case .dominant: return "you win easily"
            case .favored: return "you win"
            case .close: return "even — a coin flip"
            case .unfavored: return "you lose"
            case .hopeless: return "you lose badly"
            }
        }
    }

    /// The 1v1 solved with optimal shield play when both sides hold `shields`.
    struct ShieldLine: Sendable, Equatable {
        let shields: Int
        let rating: Int
        var verdict: Verdict { Verdict(rating: rating) }
    }

    /// The opening stretch of one sampled battle: your lead against theirs.
    struct Line: Sendable, Equatable {
        struct Throw: Sendable, Equatable {
            let move: String
            /// Blocked by a shield — theirs for your throws, yours for theirs.
            let shielded: Bool
        }
        enum End: Sendable, Hashable { case win, loss, swapOut, theySwap, timeout }

        /// Charged moves you threw, in order (first few only).
        var mine: [Throw]
        /// Charged moves they threw at you, in order (first few only).
        var theirs: [Throw]
        var end: End
        /// You held your charged moves for a stretch before anything else happened.
        var farmed: Bool
    }

    struct Plan: Sendable {
        let myName: String
        let opponentName: String
        /// The 1v1 verdict at full shields.
        let verdict: Verdict
        /// Large, glanceable instruction.
        let headline: String
        /// The line, one instruction each.
        let steps: [String]
        /// 2–2, 1–1 and 0–0, in that order.
        let shieldLines: [ShieldLine]
        /// Which move to bait with and which of theirs to shield, at full shields.
        let bait: BaitCall.Plan?
        /// Share of the sampled battles that followed this kind of ending (0…1).
        let share: Double
        let samples: Int
    }

    /// Longest run of charged moves read off each side.
    private static let maxThrows = 3
    static let defaultSamples = 32

    // MARK: - Planning

    /// Plans the lead for `myTeam[lead]` against `opponentRevealed[opponentLead]`,
    /// or nil if it can't be simulated. Seeded from the situation, so the same
    /// lead matchup always gets the same plan.
    static func plan(
        myTeam: [BattlePokemon], lead: Int,
        opponentRevealed: [BattlePokemon], opponentLead: Int,
        opponentTeamSize: Int,
        pool: [TeamFinder.Candidate],
        movesById: [String: Move],
        samples: Int = LeadCoach.defaultSamples
    ) async -> Plan? {
        guard myTeam.indices.contains(lead), opponentRevealed.indices.contains(opponentLead), samples > 0 else { return nil }

        let state = BattleCoach.State(
            myTeam: myTeam, myActive: lead, myShields: 2,
            opponentRevealed: opponentRevealed, opponentActive: opponentLead,
            opponentShields: 2, opponentTeamSize: opponentTeamSize)
        var rng = SeededGenerator(seed: state.fingerprint)
        var opponents: [[BattlePokemon]] = []
        for _ in 0..<samples {
            guard let team = BattleCoach.completedOpponentTeam(
                revealed: opponentRevealed, teamSize: opponentTeamSize,
                pool: pool, movesById: movesById, using: &rng)
            else { return nil }
            opponents.append(team)
        }

        let shieldNet = ShieldPolicyNet.bundled
        let switchNet = SwitchPolicyNet.bundled
        let farmNet = FarmPolicyNet.bundled
        let names = movesById.mapValues(\.name)

        let lines: [Line?] = await withTaskGroup(of: (Int, Line?).self) { group in
            for (i, opponentTeam) in opponents.enumerated() {
                group.addTask {
                    guard !Task.isCancelled else { return (i, nil) }
                    var battle = ThreeVThreeBattle(
                        teamA: myTeam, teamB: opponentTeam,
                        leadA: lead, leadB: opponentLead,
                        shieldsA: 2, shieldsB: 2,
                        switchPolicy: .bestMatchup,
                        optimalShields: false,
                        voluntarySwitching: true,
                        learnedShieldNet: shieldNet)
                    if let switchNet { battle.switchDecisionHook = { switchNet.decide($0) } }
                    battle.applyFarmNet(farmNet)
                    let log = battle.runRecorded()
                    return (i, line(from: log, lead: lead, opponentLead: opponentLead) { names[$0] ?? $0 })
                }
            }
            var collected = [Line?](repeating: nil, count: opponents.count)
            for await (i, line) in group { collected[i] = line }
            return collected
        }
        if Task.isCancelled { return nil }

        guard let (chosen, share) = typicalLine(of: lines.compactMap { $0 }) else { return nil }
        let shieldLines = shieldLines(myTeam[lead], opponentRevealed[opponentLead])
        let verdict = shieldLines.first?.verdict ?? .close
        let me = myTeam[lead].speciesName, them = opponentRevealed[opponentLead].speciesName

        return Plan(
            myName: me, opponentName: them, verdict: verdict,
            headline: headline(for: chosen, verdict: verdict),
            steps: steps(for: chosen, opponent: them),
            shieldLines: shieldLines,
            bait: BaitCall.analyze(mine: myTeam[lead], theirs: opponentRevealed[opponentLead], myShields: 2, theirShields: 2),
            share: share, samples: samples)
    }

    /// The 1v1 at 2–2, 1–1 and 0–0 shields, each solved with optimal shield play.
    static func shieldLines(_ mine: BattlePokemon, _ theirs: BattlePokemon) -> [ShieldLine] {
        [2, 1, 0].map { shields in
            var a = mine, b = theirs
            a.startingShields = shields
            b.startingShields = shields
            return ShieldLine(shields: shields, rating: ShieldSearch.optimalSolution(a, b).ratingA)
        }
    }

    // MARK: - Reading a battle

    /// The opening stretch of a recorded battle: the segments in which the leads
    /// face each other, up to the first faint or swap.
    static func line(from log: TeamBattleLog, lead: Int, opponentLead: Int, moveName: (String) -> String) -> Line? {
        guard let first = log.segments.first else { return nil }
        // A swap on turn zero means the stretch is over before it starts.
        if first.indexA != lead { return Line(mine: [], theirs: [], end: .swapOut, farmed: false) }
        if first.indexB != opponentLead { return Line(mine: [], theirs: [], end: .theySwap, farmed: false) }

        var stretch: [TeamBattleLog.Segment] = []
        for segment in log.segments {
            guard segment.indexA == lead, segment.indexB == opponentLead else { break }
            stretch.append(segment)
        }

        var mine: [Line.Throw] = [], theirs: [Line.Throw] = []
        for event in stretch.flatMap({ $0.log.frames.compactMap(\.event) }) where event.kind == .charged {
            guard let id = event.moveId else { continue }
            let thrown = Line.Throw(move: moveName(id), shielded: event.shielded)
            if event.actor == 0 { mine.append(thrown) } else { theirs.append(thrown) }
        }
        let firstSegmentThrows = stretch[0].log.frames.contains { $0.event?.kind == .charged && $0.event?.actor == 0 }
        let farmed = stretch.count > 1 && !firstSegmentThrows

        let end: Line.End
        let last = stretch[stretch.count - 1]
        let next = log.segments.dropFirst(stretch.count).first
        if last.log.hpA <= 0 {
            end = .loss
        } else if last.log.hpB <= 0 {
            end = .win
        } else if let next, next.indexA != lead {
            end = .swapOut
        } else if let next, next.indexB != opponentLead {
            end = .theySwap
        } else {
            end = .timeout
        }
        return Line(mine: Array(mine.prefix(maxThrows)), theirs: Array(theirs.prefix(maxThrows)),
                    end: end, farmed: farmed)
    }

    /// The line to coach and how often its ending came up. First the most common
    /// ending among the sampled battles, then the most common way of playing to
    /// it — so one odd line can't outvote the real story.
    static func typicalLine(of lines: [Line]) -> (line: Line, share: Double)? {
        guard !lines.isEmpty else { return nil }
        var endCounts: [Line.End: Int] = [:]
        for line in lines { endCounts[line.end, default: 0] += 1 }
        // Ties go to the order of the cases, which is win-first.
        let order: [Line.End] = [.win, .loss, .swapOut, .theySwap, .timeout]
        guard let end = order.max(by: { (endCounts[$0] ?? 0) < (endCounts[$1] ?? 0) }),
              (endCounts[end] ?? 0) > 0 else { return nil }

        let sameEnd = lines.filter { $0.end == end }
        // Group by what you'd do: shield choices and your throws, not whether they shielded.
        func key(_ line: Line) -> String {
            "\(line.farmed)|\(line.mine.map(\.move))|\(line.theirs.map(\.shielded))"
        }
        var groups: [String: [Line]] = [:]
        for line in sameEnd { groups[key(line), default: []].append(line) }
        guard let best = groups.values.max(by: { $0.count != $1.count ? $0.count < $1.count : key($0[0]) > key($1[0]) })
        else { return nil }
        return (best[0], Double(sameEnd.count) / Double(lines.count))
    }

    // MARK: - Wording

    private static let ordinals = ["first", "second", "third"]

    /// The big line: the single thing to do.
    static func headline(for line: Line, verdict: Verdict) -> String {
        switch line.end {
        case .swapOut:
            if line.mine.isEmpty { return "Swap out right away" }
            var moves: [String] = []
            for thrown in line.mine where !moves.contains(thrown.move) { moves.append(thrown.move) }
            return "Throw \(list(moves)) and swap out"
        case .theySwap:
            return "They swap out — hold your energy"
        case .win, .loss, .timeout:
            switch verdict {
            case .dominant: return "Win the lead — shield and out-trade them"
            case .favored: return "You win the lead"
            case .close: return "Even lead — shields decide it"
            case .unfavored: return "Losing lead — get value, then swap"
            case .hopeless: return "Bad lead — don't sink shields here"
            }
        }
    }

    /// The line as separate instructions, in the order they happen.
    static func steps(for line: Line, opponent: String) -> [String] {
        var steps: [String] = []
        if line.farmed { steps.append("Farm down first — fast moves only, bank the energy.") }

        if !line.theirs.isEmpty {
            if line.theirs.allSatisfy({ !$0.shielded }) {
                let moves = list(line.theirs.map(\.move))
                steps.append("Save your shields — take \(opponent)'s \(moves).")
            } else {
                let parts = line.theirs.enumerated().map { index, thrown in
                    let verb = thrown.shielded ? "shield" : "take"
                    return index == 0
                        ? "\(verb) their first \(thrown.move)"
                        : "\(verb) the \(ordinals[min(index, ordinals.count - 1)]) \(thrown.move)"
                }
                let sentence = parts.joined(separator: ", ")
                steps.append(sentence.prefix(1).uppercased() + sentence.dropFirst() + ".")
            }
        }

        if !line.mine.isEmpty {
            let parts = line.mine.map { $0.shielded ? "\($0.move) (they shield it)" : $0.move }
            steps.append("Throw \(parts.joined(separator: ", then ")).")
        }

        switch line.end {
        case .win: steps.append("That wins the matchup.")
        case .loss: steps.append("It still loses — get what you can, then swap rather than faint.")
        case .swapOut: steps.append(line.mine.isEmpty ? "Swap out now." : "Then swap out.")
        case .theySwap: steps.append("Expect them to swap to their back line.")
        case .timeout: steps.append("Neither side closes it out — keep farming.")
        }
        return steps
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}
