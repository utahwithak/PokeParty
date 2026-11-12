//
//  BattleLogRecorder.swift
//  PokeParty
//
//  Turns the HUD's changing view of a battle into a log: it's shown each new
//  state and writes down what changed — a Pokémon entering or fainting, a shield
//  breaking, a big chunk of HP lost, an effectiveness label.
//

import Foundation

/// What the HUD currently believes about the battle. Indices point into the
/// team and the revealed opponents.
nonisolated struct BattleObservation: Equatable, Sendable {
    var myActive = 0
    var opponentActive = 0
    var myFainted: Set<Int> = []
    var opponentFainted: Set<Int> = []
    var myShields = 2
    var opponentShields = 2
    var myHP: [Int: Double] = [:]
    var opponentHP: [Int: Double] = [:]
}

nonisolated struct BattleLogRecorder: Sendable {
    private(set) var events: [BattleLogEvent] = []

    /// The first observation's time; `elapsed` counts from here.
    private var start: Date?
    private var last: BattleObservation?
    /// The Pokémon last logged as entering, so a repeat isn't logged twice.
    private var loggedMine: Int?
    private var loggedTheirs: Int?
    private var lastFlash: [Bool: (flash: Int, at: Date)] = [:]
    private var lastCharged: [Bool: (moveId: String?, at: Date)] = [:]
    /// The fewest shields each side has been logged with. Shields only ever go
    /// down, so a reading that flickers back up and down again isn't a new break.
    private var lowestShields: [Bool: Int] = [:]

    var isEmpty: Bool { events.isEmpty }

    /// Whether anyone has fainted — the battle is underway, not just set up.
    var hasFaint: Bool { events.contains { $0.kind == .faint } }

    /// Writes down what's different in `now` compared with the last observation.
    /// `team` and `opponents` are species ids, by index.
    mutating func observe(_ now: BattleObservation, team: [String], opponents: [String], at time: Date = Date()) {
        defer { last = now }

        func append(_ kind: BattleLogEvent.Kind, mine: Bool, species: String?, other: String?,
                    value: Double? = nil, voluntary: Bool = false) {
            if start == nil { start = time }
            events.append(BattleLogEvent(
                elapsed: time.timeIntervalSince(start ?? time), mine: mine, kind: kind,
                speciesId: species, otherSpeciesId: other, value: value, voluntary: voluntary,
                myShields: now.myShields, opponentShields: now.opponentShields))
        }
        func mySpecies(_ index: Int?) -> String? { index.flatMap { team.indices.contains($0) ? team[$0] : nil } }
        func theirSpecies(_ index: Int?) -> String? { index.flatMap { opponents.indices.contains($0) ? opponents[$0] : nil } }

        // A faint taken back (marked alive by hand, because it was read late or against the
        // wrong Pokémon) comes out of the log, so the correction doesn't leave the mistake behind.
        if let last {
            for index in last.myFainted.subtracting(now.myFainted) {
                if let species = mySpecies(index),
                   let at = events.lastIndex(where: { $0.kind == .faint && $0.mine && $0.speciesId == species }) {
                    events.remove(at: at)
                }
            }
            for index in last.opponentFainted.subtracting(now.opponentFainted) {
                if let species = theirSpecies(index),
                   let at = events.lastIndex(where: { $0.kind == .faint && !$0.mine && $0.speciesId == species }) {
                    events.remove(at: at)
                }
            }
        }

        // Faints first, so a replacement entering in the same update reads as forced.
        if let last {
            for index in now.myFainted.subtracting(last.myFainted).sorted() {
                append(.faint, mine: true, species: mySpecies(index), other: theirSpecies(now.opponentActive))
            }
            for index in now.opponentFainted.subtracting(last.opponentFainted).sorted() {
                append(.faint, mine: false, species: theirSpecies(index), other: mySpecies(now.myActive))
            }
        } else {
            // First sight of a battle already under way (some are already down).
            for index in now.myFainted.sorted() {
                append(.faint, mine: true, species: mySpecies(index), other: nil)
            }
            for index in now.opponentFainted.sorted() {
                append(.faint, mine: false, species: theirSpecies(index), other: nil)
            }
        }

        // Entrances.
        if !now.myFainted.contains(now.myActive), team.indices.contains(now.myActive), loggedMine != now.myActive {
            let voluntary = loggedMine.map { !now.myFainted.contains($0) } ?? false
            append(.enter, mine: true, species: team[now.myActive], other: theirSpecies(loggedTheirs ?? now.opponentActive),
                   voluntary: voluntary)
            loggedMine = now.myActive
        }
        if !now.opponentFainted.contains(now.opponentActive), opponents.indices.contains(now.opponentActive),
           loggedTheirs != now.opponentActive {
            let voluntary = loggedTheirs.map { !now.opponentFainted.contains($0) } ?? false
            append(.enter, mine: false, species: opponents[now.opponentActive], other: mySpecies(loggedMine ?? now.myActive),
                   voluntary: voluntary)
            loggedTheirs = now.opponentActive
        }

        guard let last else { return }

        // A shield breaking means a charged move was thrown at it. Compared with
        // the lowest count already logged, so a misread that bounces back up
        // can't log the same break again.
        if now.myShields < min(last.myShields, lowestShields[true] ?? 2) {
            lowestShields[true] = now.myShields
            append(.shield, mine: true, species: mySpecies(now.myActive), other: theirSpecies(now.opponentActive),
                   value: Double(now.myShields))
        }
        if now.opponentShields < min(last.opponentShields, lowestShields[false] ?? 2) {
            lowestShields[false] = now.opponentShields
            append(.shield, mine: false, species: theirSpecies(now.opponentActive), other: mySpecies(now.myActive),
                   value: Double(now.opponentShields))
        }
    }

    /// A charged move's banner was read for `mine`'s active Pokémon. A banner
    /// stays up for a moment across many readings, so the same move twice in a
    /// row, close together, is one throw.
    ///
    /// `moveId` is nil when only the fact of a throw is known (the rating shown
    /// after your charge-up swipe). A name read soon after fills in such an
    /// entry rather than logging the throw twice.
    mutating func observeCharged(moveId: String?, mine: Bool, now: BattleObservation, team: [String], opponents: [String],
                                 at time: Date = Date()) {
        if let last = lastCharged[mine], time.timeIntervalSince(last.at) < 3 {
            if let moveId {
                if last.moveId == moveId { return }
                // The throw was already logged without a name: name it.
                if last.moveId == nil, let index = events.lastIndex(where: { $0.kind == .charged && $0.mine == mine }) {
                    events[index].moveId = moveId
                    lastCharged[mine] = (moveId, last.at)
                    return
                }
            } else {
                return
            }
        }
        lastCharged[mine] = (moveId, time)
        if start == nil { start = time }
        let me = mine ? team : opponents, them = mine ? opponents : team
        let myIndex = mine ? now.myActive : now.opponentActive, theirIndex = mine ? now.opponentActive : now.myActive
        events.append(BattleLogEvent(
            elapsed: time.timeIntervalSince(start ?? time), mine: mine, kind: .charged,
            speciesId: me.indices.contains(myIndex) ? me[myIndex] : nil,
            otherSpeciesId: them.indices.contains(theirIndex) ? them[theirIndex] : nil,
            moveId: moveId, myShields: now.myShields, opponentShields: now.opponentShields))
    }

    /// An effectiveness label showed over a Pokémon that was hit: yours
    /// (`targetMine`) or the opponent's. The label stays up for a moment across
    /// many readings, so repeats close together are one hit.
    mutating func observeFlash(superEffective: Bool, targetMine: Bool, now: BattleObservation, team: [String],
                               opponents: [String], at time: Date = Date()) {
        let code = superEffective ? 1 : -1
        if let last = lastFlash[targetMine], last.flash == code, time.timeIntervalSince(last.at) < 2 { return }
        lastFlash[targetMine] = (code, time)
        if start == nil { start = time }
        let target = targetMine ? team : opponents, attacker = targetMine ? opponents : team
        let targetIndex = targetMine ? now.myActive : now.opponentActive
        let attackerIndex = targetMine ? now.opponentActive : now.myActive
        events.append(BattleLogEvent(
            elapsed: time.timeIntervalSince(start ?? time), mine: targetMine, kind: .effective,
            speciesId: target.indices.contains(targetIndex) ? target[targetIndex] : nil,
            otherSpeciesId: attacker.indices.contains(attackerIndex) ? attacker[attackerIndex] : nil,
            value: Double(code), myShields: now.myShields, opponentShields: now.opponentShields))
    }

    /// The coach's advice for the matchup on the field, as a log entry. The same
    /// advice twice running isn't logged again.
    mutating func observeCoach(_ lines: [CoachNarrator.Line], now: BattleObservation, team: [String],
                               opponents: [String], at time: Date = Date()) {
        let text = lines.map(\.text).joined(separator: " ")
        if events.last(where: { $0.kind == .coach })?.note == text { return }
        if start == nil { start = time }
        events.append(BattleLogEvent(
            elapsed: time.timeIntervalSince(start ?? time), mine: true, kind: .coach,
            speciesId: team.indices.contains(now.myActive) ? team[now.myActive] : nil,
            otherSpeciesId: opponents.indices.contains(now.opponentActive) ? opponents[now.opponentActive] : nil,
            myShields: now.myShields, opponentShields: now.opponentShields, note: text, coachLines: lines))
    }

    /// Whose charged move was logged most recently, if one was within `window`
    /// seconds of `time`: true for yours, false for theirs.
    func recentChargedThrower(at time: Date, within window: TimeInterval = 3) -> Bool? {
        recentCharged(at: time, within: window)?.mine
    }

    /// The charged move logged most recently, if it was within `window` seconds
    /// of `time`. Its `moveId` is nil when only the throw was seen.
    func recentCharged(at time: Date, within window: TimeInterval = 3) -> BattleLogEvent? {
        let now = elapsed(at: time)
        guard let last = events.last(where: { $0.kind == .charged }), now - last.elapsed <= window else { return nil }
        return last
    }

    /// Seconds since the battle's first log entry (0 before there is one).
    func elapsed(at time: Date) -> TimeInterval {
        start.map { max(0, time.timeIntervalSince($0)) } ?? 0
    }

    /// Starts over for a new battle.
    mutating func reset() { self = BattleLogRecorder() }
}
