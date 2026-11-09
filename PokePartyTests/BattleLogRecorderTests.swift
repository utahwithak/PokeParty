//
//  BattleLogRecorderTests.swift
//  PokePartyTests
//

import Foundation
import Testing
@testable import PokeParty

@Suite struct BattleLogRecorderTests {

    private let team = ["azumarill", "medicham", "skarmory"]
    private let opponents = ["registeel", "altaria", "swampert"]
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func record(_ states: [BattleObservation]) -> [BattleLogEvent] {
        var recorder = BattleLogRecorder()
        for (i, state) in states.enumerated() {
            recorder.observe(state, team: team, opponents: opponents, at: t0.addingTimeInterval(Double(i) * 5))
        }
        return recorder.events
    }

    @Test func logsBothLeadsOnFirstSight() {
        let events = record([BattleObservation()])

        #expect(events.map(\.kind) == [.enter, .enter])
        #expect(events.map(\.speciesId) == ["azumarill", "registeel"])
    }

    @Test func aSwapByChoiceIsVoluntaryAndAReplacementIsNot() {
        var swapped = BattleObservation(); swapped.myActive = 1
        var fainted = swapped; fainted.myFainted = [1]
        var replaced = fainted; replaced.myActive = 2

        let enters = record([BattleObservation(), swapped, fainted, replaced]).filter { $0.kind == .enter && $0.mine }

        #expect(enters.map(\.speciesId) == ["azumarill", "medicham", "skarmory"])
        #expect(enters.map(\.voluntary) == [false, true, false])
    }

    @Test func aDroppedShieldIsLoggedForTheSideThatLostIt() {
        var spent = BattleObservation(); spent.opponentShields = 1

        let shields = record([BattleObservation(), spent]).filter { $0.kind == .shield }

        #expect(shields.count == 1)
        #expect(shields[0].mine == false)
        #expect(shields[0].value == 1)
    }

    @Test func anHPDropAloneIsNotCalledAChargedMove() {
        // A few fast moves between two readings look like a big drop; they aren't news.
        var before = BattleObservation(); before.myHP = [0: 1.0]
        var after = before; after.myHP = [0: 0.5]

        let events = record([before, after])

        #expect(events.allSatisfy { $0.kind == .enter })
    }

    @Test func repeatedFlashesCloseTogetherAreOneHit() {
        var recorder = BattleLogRecorder()
        let state = BattleObservation()
        recorder.observeFlash(superEffective: true, targetMine: true, now: state, team: team, opponents: opponents, at: t0)
        recorder.observeFlash(superEffective: true, targetMine: true, now: state, team: team, opponents: opponents, at: t0.addingTimeInterval(0.5))
        recorder.observeFlash(superEffective: true, targetMine: true, now: state, team: team, opponents: opponents, at: t0.addingTimeInterval(5))

        #expect(recorder.events.count == 2)
    }

    @Test func aLabelOverTheOpponentIsAHitOnThem() {
        var recorder = BattleLogRecorder()
        recorder.observeFlash(superEffective: true, targetMine: false, now: BattleObservation(),
                              team: team, opponents: opponents, at: t0)

        #expect(recorder.events.first?.mine == false)
        #expect(recorder.events.first?.speciesId == "registeel")
        #expect(recorder.events.first?.otherSpeciesId == "azumarill")
    }
}

@MainActor
@Suite struct BattleHistoryStoreTests {

    private let format = RankingFormat.great

    private func makeStore() -> BattleHistoryStore {
        BattleHistoryStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("BattleHistory-\(UUID().uuidString).json"))
    }

    private func member(_ id: String) -> TeamMember {
        TeamMember(speciesId: id, fastMoveId: "FAST", chargedMoveIds: ["A", "B"])
    }

    @Test func aBattleAppearsOnceAnOpponentIsSeen() {
        let store = makeStore()
        store.addGame(format: format)
        store.observe(BattleObservation(), team: [member("azumarill")], opponents: [member("registeel")], format: format)

        #expect(store.battles.count == 1)
        #expect(store.current?.events.isEmpty == false)
    }

    @Test func threeOpponentFaintsAreDetectedAsAWin() {
        let store = makeStore()
        store.addGame(format: format)
        var state = BattleObservation(); state.opponentFainted = [0, 1, 2]
        store.observe(state, team: [member("a"), member("b"), member("c")],
                      opponents: [member("x"), member("y"), member("z")], format: format)

        #expect(store.current?.outcome == .win)
        #expect(store.current?.outcomeDetected == true)
    }

    @Test func aManualMarkOverridesTheDetectedResult() {
        let store = makeStore()
        store.addGame(format: format)
        var state = BattleObservation(); state.opponentFainted = [0, 1, 2]
        let team = [member("a"), member("b"), member("c")], opponents = [member("x"), member("y"), member("z")]
        store.observe(state, team: team, opponents: opponents, format: format)
        let id = store.current!.id

        store.mark(id, as: .loss)
        store.observe(state, team: team, opponents: opponents, format: format)

        #expect(store.battles.first?.outcome == .loss)
    }

    @Test func aFullSetRollsOverToANewOne() {
        let store = makeStore()
        for _ in 0..<BattleHistoryStore.setSize {
            store.addGame(format: format)
            store.observe(BattleObservation(), team: [member("a")], opponents: [member("x")], format: format)
            store.mark(store.current!.id, as: .win)
        }
        store.addGame(format: format)
        store.observe(BattleObservation(), team: [member("a")], opponents: [member("x")], format: format)

        #expect(store.sets.count == 2)
        #expect(store.currentSet.battles.count == 1)
    }

    @Test func resettingASetClearsItButKeepsEarlierSets() {
        let store = makeStore()
        for _ in 0..<2 {
            store.addGame(format: format)
            store.observe(BattleObservation(), team: [member("a")], opponents: [member("x")], format: format)
            store.mark(store.current!.id, as: .win)
        }
        store.addGame(format: format, newSet: true)
        store.observe(BattleObservation(), team: [member("a")], opponents: [member("x")], format: format)
        store.mark(store.current!.id, as: .loss)

        store.resetSet()

        #expect(store.currentSet.battles.isEmpty)
        #expect(store.current == nil)
        #expect(store.sets.count == 1)
        #expect(store.sets.first?.wins == 2)
    }

    @Test func afterANewBattleTheOldGameIsStillInTheSetButNotShown() {
        let store = makeStore()
        store.addGame(format: format)
        store.observe(BattleObservation(), team: [member("a")], opponents: [member("x")], format: format)
        let first = store.current!.id
        #expect(store.displayed(selectedId: nil)?.id == first)

        store.startNewBattle()

        #expect(store.displayed(selectedId: nil) == nil)
        #expect(store.currentSet.battles.map(\.id) == [first])
        // It can still be picked from the set.
        #expect(store.displayed(selectedId: first)?.id == first)
    }

    @Test func deletingTheCurrentBattleRemovesIt() {
        let store = makeStore()
        store.addGame(format: format)
        store.observe(BattleObservation(), team: [member("a")], opponents: [member("x")], format: format)
        store.delete(store.current!.id)

        #expect(store.battles.isEmpty)
    }
}
