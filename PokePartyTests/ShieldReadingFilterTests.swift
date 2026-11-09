//
//  ShieldReadingFilterTests.swift
//  PokePartyTests
//

import Foundation
import Testing
@testable import PokeParty

@Suite struct ShieldReadingFilterTests {

    private func reading(_ mine: Int, _ theirs: Int, alive: Int = 3) -> BattleHeaderReading {
        BattleHeaderReading(myShields: mine, opponentShields: theirs, myAlive: alive, opponentAlive: alive)
    }

    /// Feeds `value` every 0.1s from `start` for `seconds`; returns the last answer.
    @discardableResult
    private func feed(_ filter: inout ShieldReadingFilter, _ value: BattleHeaderReading,
                      from start: TimeInterval, for seconds: TimeInterval) -> (mine: Int?, theirs: Int?) {
        var result: (mine: Int?, theirs: Int?) = (nil, nil)
        var t = start
        while t <= start + seconds {
            result = filter.update(value, now: t)
            t += 0.1
        }
        return result
    }

    @Test func theFirstReadingIsTrustedOnceItSettles() {
        var filter = ShieldReadingFilter()

        #expect(filter.update(reading(2, 2), now: 0).mine == nil)
        let settled = feed(&filter, reading(2, 2), from: 0.1, for: 1)

        #expect(settled.mine == 2)
        #expect(settled.theirs == 2)
    }

    @Test func aBriefDropToZeroOnBothSidesIsIgnored() {
        var filter = ShieldReadingFilter()
        feed(&filter, reading(2, 2), from: 0, for: 1)

        // The header dims for a couple of seconds, then comes back.
        feed(&filter, reading(0, 0), from: 1.1, for: 2)
        let after = feed(&filter, reading(2, 2), from: 3.2, for: 1)

        #expect(after.mine == 2)
        #expect(after.theirs == 2)
    }

    @Test func aRealDropOnOneSideIsBelievedOnceItHolds() {
        var filter = ShieldReadingFilter()
        feed(&filter, reading(2, 2), from: 0, for: 1)

        let early = feed(&filter, reading(1, 2), from: 1.1, for: 0.5)
        let held = feed(&filter, reading(1, 2), from: 1.7, for: 1.5)

        #expect(early.mine == 2)
        #expect(held.mine == 1)
        #expect(held.theirs == 2)
    }

    @Test func shieldsDontComeBackMidBattle() {
        var filter = ShieldReadingFilter()
        feed(&filter, reading(2, 2), from: 0, for: 1)
        feed(&filter, reading(1, 2, alive: 3), from: 1.1, for: 2)
        // One Pokémon is down, so this isn't a fresh battle: a rise is a misread.
        feed(&filter, reading(1, 2, alive: 2), from: 3.2, for: 1)

        let after = feed(&filter, reading(2, 2, alive: 2), from: 4.3, for: 3)

        #expect(after.mine == 1)
    }

    @Test func aNewBattleResetsShieldsToTwo() {
        var filter = ShieldReadingFilter()
        feed(&filter, reading(2, 2), from: 0, for: 1)
        feed(&filter, reading(0, 0, alive: 1), from: 1.1, for: 6)

        let fresh = feed(&filter, reading(2, 2), from: 7.2, for: 1.5)

        #expect(fresh.mine == 2)
        #expect(fresh.theirs == 2)
    }
}

@Suite struct BattleResultTextTests {

    @Test func readsTheResultScreen() {
        #expect(BattleResultText.parse(["YOU WIN!"]) == .win)
        #expect(BattleResultText.parse(["Good Effort"]) == .loss)
        #expect(BattleResultText.parse(["GOOD EFFORT!"]) == .loss)
        // On the real screen the two words are separate lines.
        #expect(BattleResultText.parse(["GOOD", "EFFORT!", "NEXT BATTLE"]) == .loss)
        #expect(BattleResultText.parse(["YOU", "WIN!"]) == .win)
        #expect(BattleResultText.parse(["GOOD", "NEXT BATTLE", "EFFORT!"]) == nil)
        #expect(BattleResultText.parse(["Y0U WIN"]) == nil)
        #expect(BattleResultText.parse(["Charge Up", "SUPER EFFECTIVE!"]) == nil)
    }
}

@Suite struct BattleLogGetReadyTests {

    private let team = ["azumarill"], opponents = ["registeel"]
    private let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func aNamelessThrowIsNamedByAMoveReadSoonAfter() {
        var recorder = BattleLogRecorder()
        let state = BattleObservation()
        recorder.observeCharged(moveId: nil, mine: true, now: state, team: team, opponents: opponents, at: t0)
        recorder.observeCharged(moveId: nil, mine: true, now: state, team: team, opponents: opponents, at: t0.addingTimeInterval(1))
        recorder.observeCharged(moveId: "ICE_BEAM", mine: true, now: state, team: team, opponents: opponents, at: t0.addingTimeInterval(2))

        #expect(recorder.events.count == 1)
        #expect(recorder.events.first?.moveId == "ICE_BEAM")
    }

    @Test func aLaterThrowIsALaterEntry() {
        var recorder = BattleLogRecorder()
        let state = BattleObservation()
        recorder.observeCharged(moveId: nil, mine: true, now: state, team: team, opponents: opponents, at: t0)
        recorder.observeCharged(moveId: nil, mine: true, now: state, team: team, opponents: opponents, at: t0.addingTimeInterval(10))

        #expect(recorder.events.count == 2)
    }
}

@MainActor
@Suite struct BattleResultObservationTests {

    private func member(_ id: String) -> TeamMember {
        TeamMember(speciesId: id, fastMoveId: "FAST", chargedMoveIds: ["A", "B"])
    }

    private func makeStore() -> BattleHistoryStore {
        BattleHistoryStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("BattleHistory-\(UUID().uuidString).json"))
    }

    @Test func theResultScreenMarksTheCurrentGameAndAsksForAReview() {
        let store = makeStore()
        store.addGame(format: .great)
        store.observe(BattleObservation(), team: [member("a")], opponents: [member("x")], format: .great)

        let id = store.observeResult(.win)

        #expect(id == store.current?.id)
        #expect(store.current?.outcome == .win)
        #expect(store.current?.outcomeDetected == true)
    }

    @Test func aHandMarkIsNotOverriddenByTheScreen() {
        let store = makeStore()
        store.addGame(format: .great)
        store.observe(BattleObservation(), team: [member("a")], opponents: [member("x")], format: .great)
        store.mark(store.current!.id, as: .loss)

        #expect(store.observeResult(.win) == nil)
        #expect(store.current?.outcome == .loss)
    }
}
