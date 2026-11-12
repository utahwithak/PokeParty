//
//  BattleRecord.swift
//  PokeParty
//
//  A battle played in Pokémon GO as the Battle HUD saw it: both teams, a log of
//  what could be read off the screen, and — if the player marks it — whether
//  they won. Battles are grouped into sets of five games (usually against different opponents).
//

import Foundation

/// One thing the HUD saw happen. Charged moves are never named on screen, so
/// they appear only through their effect: a shield breaking, or a big drop in HP.
nonisolated struct BattleLogEvent: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// A Pokémon came onto the field (`voluntary` tells a swap from a faint replacement).
        case enter
        /// A charged move named by its on-screen banner (`moveId`). `mine` is the thrower.
        case charged
        case faint
        /// A shield was spent — which means a charged move was thrown into it.
        case shield
        /// No longer logged (an HP drop between two readings can't tell a charged
        /// move from a few fast ones); kept so old history still loads.
        case bigHit
        /// The "super effective" / "not very effective" label flashed on a hit.
        case effective
        /// What the coach would do from here, in plain words (`note`).
        case coach
    }

    var id = UUID()
    /// Seconds since the battle's first log entry.
    var elapsed: TimeInterval
    /// Whose Pokémon this is about: yours (true) or the opponent's. For a
    /// shield it's the side whose shield broke; for a hit, the side that took it.
    var mine: Bool
    var kind: Kind
    var speciesId: String?
    /// The Pokémon on the other side of the field at the time.
    var otherSpeciesId: String?
    /// `charged` only: the move thrown.
    var moveId: String?
    /// Shield: shields that side has left. Big hit: HP fraction left.
    /// Effective: +1 super effective, −1 not very effective.
    var value: Double?
    /// `enter` only: a swap by choice rather than a replacement after a faint.
    var voluntary = false
    /// Shields (yours, theirs) when this happened.
    var myShields = 2
    var opponentShields = 2
    /// `coach` only: the advice as plain text.
    var note: String?
    /// `coach` only: the same advice as separate lines, each with what it's about. Entries
    /// from before this existed have only `note`.
    var coachLines: [CoachNarrator.Line]?

    func text(name: (String) -> String, move: (String) -> String = { $0 }) -> String {
        let me = speciesId.map(name) ?? "?"
        let other = otherSpeciesId.map(name) ?? "the opponent"
        switch kind {
        case .charged:
            let moveName = moveId.map(move) ?? "a charged move"
            return mine ? "Your \(me) used \(moveName)" : "Their \(me) used \(moveName)"
        case .enter:
            if mine { return voluntary ? "You swapped in \(me)" : "You sent out \(me)" }
            return voluntary ? "They swapped in \(me)" : "They sent out \(me)"
        case .faint:
            return mine ? "Your \(me) fainted" : "Their \(me) fainted"
        case .shield:
            let left = Int(value ?? 0)
            return mine
                ? "You shielded \(other)'s charged move with \(me) (\(left) shield\(left == 1 ? "" : "s") left)"
                : "They shielded \(other)'s charged move with \(me) (\(left) shield\(left == 1 ? "" : "s") left)"
        case .bigHit:
            let hp = Int(((value ?? 0) * 100).rounded())
            return mine
                ? "\(me) took a big hit from \(other) — \(hp)% left (likely a charged move)"
                : "\(me) took a big hit from \(other) — \(hp)% left (likely your charged move)"
        case .effective:
            let owner = mine ? "Your" : "Their"
            return (value ?? 0) > 0
                ? "\(owner) \(me) was hit super effectively"
                : "\(owner) \(me) resisted a hit"
        case .coach:
            return note ?? ""
        }
    }
}

/// A line of text the phone read off the battle screen, kept as it was read.
nonisolated struct ScreenTextEntry: Codable, Hashable, Sendable {
    var elapsed: TimeInterval
    var text: String
    /// How far down the screen it was (0 top … 1 bottom), when known.
    var y: Double?
}

nonisolated enum BattleOutcome: String, Codable, Sendable {
    case win, loss
}

/// Why the sim thinks a game went the way it did. Stored so the history can
/// show, across many games, whether losses come from play, leads or the team.
nonisolated enum BattleDiagnosis: String, Codable, Sendable {
    /// Won, and the sim agrees.
    case asExpected
    /// Won although the sim favoured the opponent.
    case outplayedSim
    /// Lost although the sim wins the same leads in the same order — a play difference.
    case execution
    /// Lost, and the sim loses it too — the matchup itself.
    case teamMatchup

    /// A diagnosis from before leads were no longer compared ("a different lead
    /// wins") now reads as a matchup loss, so old history still loads.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BattleDiagnosis(rawValue: raw) ?? .teamMatchup
    }
}

nonisolated struct RecordedBattle: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var setId: UUID
    var date = Date()
    var cup: String
    var cp: Int
    var team: [TeamMember] = []
    var opponents: [TeamMember] = []
    var events: [BattleLogEvent] = []
    /// Everything the phone's OCR read (labels, banners, noise), oldest first.
    var screenText: [ScreenTextEntry] = []
    var outcome: BattleOutcome?
    /// True when the outcome was read off the screen rather than marked by hand.
    var outcomeDetected = false
    /// The sim's call for the actual leads (true = you win), once reviewed.
    var simPredictsWin: Bool?
    var diagnosis: BattleDiagnosis?

    fileprivate enum CodingKeys: String, CodingKey {
        case id, setId, date, cup, cp, team, opponents, events, screenText
        case outcome, outcomeDetected, simPredictsWin, diagnosis
    }

    /// Anything worth keeping: the HUD saw an opponent or something happen.
    var hasContent: Bool { !events.isEmpty || outcome != nil }

    /// Species ids in the order they came onto the field for one side, leads
    /// first, with each entrance counted once even if it swapped back in.
    func entranceOrder(mine: Bool) -> [String] {
        var order: [String] = []
        for event in events where event.kind == .enter && event.mine == mine {
            if let id = event.speciesId, !order.contains(id) { order.append(id) }
        }
        return order
    }

    /// Charged moves actually thrown by each opponent species, in the order seen.
    var observedOpponentMoves: [String: [String]] {
        var seen: [String: [String]] = [:]
        for event in events where event.kind == .charged && !event.mine {
            guard let species = event.speciesId, let move = event.moveId, !(seen[species]?.contains(move) ?? false) else { continue }
            seen[species, default: []].append(move)
        }
        return seen
    }
}

nonisolated extension RecordedBattle {
    /// Fields added after the first release decode as empty from older files,
    /// so saved history survives an update.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id              = try c.decode(UUID.self, forKey: .id)
        setId           = try c.decode(UUID.self, forKey: .setId)
        date            = try c.decode(Date.self, forKey: .date)
        cup             = try c.decode(String.self, forKey: .cup)
        cp              = try c.decode(Int.self, forKey: .cp)
        team            = try c.decodeIfPresent([TeamMember].self, forKey: .team) ?? []
        opponents       = try c.decodeIfPresent([TeamMember].self, forKey: .opponents) ?? []
        events          = try c.decodeIfPresent([BattleLogEvent].self, forKey: .events) ?? []
        screenText      = try c.decodeIfPresent([ScreenTextEntry].self, forKey: .screenText) ?? []
        outcome         = try c.decodeIfPresent(BattleOutcome.self, forKey: .outcome)
        outcomeDetected = try c.decodeIfPresent(Bool.self, forKey: .outcomeDetected) ?? false
        simPredictsWin  = try c.decodeIfPresent(Bool.self, forKey: .simPredictsWin)
        diagnosis       = try c.decodeIfPresent(BattleDiagnosis.self, forKey: .diagnosis)
    }
}
