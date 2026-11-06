//
//  ChargedMoveMatcherTests.swift
//  PokePartyTests
//

import Foundation
import Testing
@testable import PokeParty

@Suite struct ChargedMoveMatcherTests {

    // Lines below are what the phone really read in a game.
    private let mine = ChargedMoveMatcher.Mover(name: "Ampharos", moves: [
        (id: "TRAILBLAZE", name: "Trailblaze"), (id: "BRUTAL_SWING", name: "Brutal Swing")])
    private let theirs = ChargedMoveMatcher.Mover(name: "Vaporeon", moves: [
        (id: "HYDRO_PUMP", name: "Hydro Pump"), (id: "AQUA_TAIL", name: "Aqua Tail"), (id: "TRAILBLAZE", name: "Trailblaze")])

    private func match(_ lines: [String]) -> [ChargedMoveMatcher.Match] {
        ChargedMoveMatcher.matchBanners(lines, mine: mine, theirs: theirs)
    }

    @Test func aUsedBannerNamesTheMoveAndWhoseItIs() {
        #expect(match(["Ampharos 1 used Trailblaze!"]) == [.init(moveId: "TRAILBLAZE", mine: true)])
        #expect(match(["Vaporeon used Hydro Pump!"]) == [.init(moveId: "HYDRO_PUMP", mine: false)])
    }

    @Test func yourMoveButtonsAreNotThrows() {
        // The capitals on your charged-move buttons are on screen all the time.
        #expect(match(["TRAILBLAZE", "BRUTAL SWING"]).isEmpty)
    }

    @Test func aMoveBothCanThrowIsToldApartByTheName() {
        #expect(match(["Vaporeon used Trailblaze!"]) == [.init(moveId: "TRAILBLAZE", mine: false)])
        #expect(match(["Ampharos 1 used Trailblaze!"]) == [.init(moveId: "TRAILBLAZE", mine: true)])
    }

    @Test func toleratesAnOCRSlip() {
        #expect(match(["Ampharos 1 usecl Traillaze!"]).map(\.moveId) == ["TRAILBLAZE"])
    }

    @Test func aBannerForAnotherPokemonIsIgnored() {
        #expect(match(["Sealeo used Hydro Pump!"]).isEmpty)
    }

    @Test func noiseAndLabelsMatchNothing() {
        #expect(match(["SUPER EFFECTIVE!", "Get Ready!", "C CP 1481", "Vaporeon", "Ampharos 1", "NICE!"]).isEmpty)
    }

    @Test func recognisesTheChargeUpRatings() {
        #expect(ChargedMoveMatcher.isThrowRating("NICE!"))
        #expect(ChargedMoveMatcher.isThrowRating("GREAT!"))
        #expect(ChargedMoveMatcher.isThrowRating("EXCELLENT!"))
        #expect(!ChargedMoveMatcher.isThrowRating("Great Ball"))
    }
}

@Suite struct RecordedBattleDecodingTests {

    @Test func aGameSavedBeforeScreenTextWasKeptStillLoads() throws {
        let json = """
        {"id":"\(UUID().uuidString)","setId":"\(UUID().uuidString)","date":0,"cup":"all","cp":1500,
         "team":[],"opponents":[],"events":[],"outcome":"win","outcomeDetected":false,"diagnosis":"leadChoice"}
        """
        let battle = try JSONDecoder().decode(RecordedBattle.self, from: Data(json.utf8))

        #expect(battle.screenText.isEmpty)
        #expect(battle.outcome == .win)
        #expect(battle.diagnosis == .teamMatchup)
    }
}

@Suite struct BattleLogChargedMoveTests {

    private let team = ["azumarill", "medicham", "skarmory"]
    private let opponents = ["registeel", "altaria", "swampert"]
    private let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func aRepeatedBannerIsOneThrowButAnotherMoveIsNot() {
        var recorder = BattleLogRecorder()
        let state = BattleObservation()
        recorder.observeCharged(moveId: "ICE_BEAM", mine: true, now: state, team: team, opponents: opponents, at: t0)
        recorder.observeCharged(moveId: "ICE_BEAM", mine: true, now: state, team: team, opponents: opponents, at: t0.addingTimeInterval(1))
        recorder.observeCharged(moveId: "PLAY_ROUGH", mine: true, now: state, team: team, opponents: opponents, at: t0.addingTimeInterval(1.5))

        #expect(recorder.events.map(\.moveId) == ["ICE_BEAM", "PLAY_ROUGH"])
        #expect(recorder.events.allSatisfy { $0.speciesId == "azumarill" && $0.otherSpeciesId == "registeel" })
    }

    @Test func theLatestChargedThrowerIsKnownForAFewSeconds() {
        var recorder = BattleLogRecorder()
        let state = BattleObservation()
        #expect(recorder.recentChargedThrower(at: t0) == nil)

        recorder.observeCharged(moveId: "ICE_BEAM", mine: true, now: state, team: team, opponents: opponents, at: t0)
        #expect(recorder.recentChargedThrower(at: t0.addingTimeInterval(2)) == true)
        #expect(recorder.recentChargedThrower(at: t0.addingTimeInterval(8)) == nil)

        recorder.observeCharged(moveId: "HYDRO_PUMP", mine: false, now: state, team: team, opponents: opponents,
                                at: t0.addingTimeInterval(10))
        #expect(recorder.recentChargedThrower(at: t0.addingTimeInterval(11)) == false)
    }

    @Test func entranceOrderAndObservedMovesComeFromTheLog() {
        var recorder = BattleLogRecorder()
        var state = BattleObservation()
        recorder.observe(state, team: team, opponents: opponents, at: t0)
        recorder.observeCharged(moveId: "HYDRO_PUMP", mine: false, now: state, team: team, opponents: opponents, at: t0.addingTimeInterval(1))
        state.opponentFainted = [0]; state.opponentActive = 2
        recorder.observe(state, team: team, opponents: opponents, at: t0.addingTimeInterval(9))

        var battle = RecordedBattle(setId: UUID(), cup: "all", cp: 1500)
        battle.events = recorder.events

        #expect(battle.entranceOrder(mine: false) == ["registeel", "swampert"])
        #expect(battle.observedOpponentMoves == ["registeel": ["HYDRO_PUMP"]])
    }
}
