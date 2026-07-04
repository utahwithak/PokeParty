//
//  ThreeVThreeBattleTests.swift
//  PokePartyTests
//
//  Tests for the Milestone 2 3v3 orchestrator. Uses synthetic Pokémon so the
//  tests need no network / gamemaster data.
//

import Testing
@testable import PokeParty

private func makeMove(_ id: String, type: String, power: Int, energy: Int, gain: Int) -> BattleMove {
    BattleMove(from: Move(moveId: id, name: id, type: type, power: power, energy: energy,
                          energyGain: gain, cooldown: 500, turns: 1,
                          buffs: nil, buffTarget: nil, buffApplyChance: nil))
}

private func makePoke(_ id: String, type: String, atk: Double, def: Double, hp: Int) -> BattlePokemon {
    BattlePokemon(speciesId: id, speciesName: id, types: [type], shadow: false,
                  stats: .init(atk: atk, def: def, hp: hp),
                  fastMove: makeMove("fast_" + id, type: type, power: 3, energy: 0, gain: 4),
                  chargedMoves: [makeMove("cm_" + id, type: type, power: 60, energy: 35, gain: 0)])
}

private func team(_ prefix: String, atk: Double, def: Double, hp: Int) -> [BattlePokemon] {
    ["fire", "water", "grass"].enumerated().map { i, t in
        makePoke("\(prefix)\(i)", type: t, atk: atk, def: def, hp: hp)
    }
}

@Suite struct ThreeVThreeBattleTests {

    @Test func strongerTeamWins() {
        let a = team("A", atk: 150, def: 115, hp: 160)
        let b = team("B", atk: 128, def: 100, hp: 135)
        let r = ThreeVThreeBattle(teamA: a, teamB: b).run()

        #expect(r.winner == .teamA)
        #expect(r.survivorsB == 0)
        #expect(r.survivorsA > 0)
        #expect(r.ratingA > 500)
        #expect(!r.timedOut)
    }

    @Test func mirrorMatchIsEven() {
        let a = team("X", atk: 140, def: 110, hp: 150)
        let b = team("Y", atk: 140, def: 110, hp: 150)
        let r = ThreeVThreeBattle(teamA: a, teamB: b).run()

        #expect(r.winner == .tie)
        #expect(r.ratingA == 500)
        #expect(!r.timedOut)
    }

    @Test func battleTerminatesAndBringsInReplacements() {
        // A clearly stronger team should faint several of B's Pokémon, forcing
        // B to bring in replacements (more than one entrance).
        let a = team("A", atk: 160, def: 120, hp: 170)
        let b = team("B", atk: 120, def: 95, hp: 130)
        let r = ThreeVThreeBattle(teamA: a, teamB: b).run()

        #expect(r.entrancesB.count > 1)          // B switched after faints
        #expect(r.entrancesA.first == 0)         // lead A entered first
        #expect(r.survivorsA + r.entrancesA.count <= a.count + 3) // sanity bound
    }

    @Test func shieldsArePerTeamPool() {
        // With only 2 shields per team, a team can never end with more than it started.
        let a = team("A", atk: 150, def: 115, hp: 160)
        let b = team("B", atk: 140, def: 110, hp: 150)
        let r = ThreeVThreeBattle(teamA: a, teamB: b, shieldsA: 2, shieldsB: 2).run()

        #expect(r.shieldsA >= 0 && r.shieldsA <= 2)
        #expect(r.shieldsB >= 0 && r.shieldsB <= 2)
    }

    @Test func bestMatchupBringsInTheCounter() {
        // Team A is all Fire. Team B's lead is Grass (loses to Fire); its bench has a
        // neutral Normal (#1) and a Water counter (#2). Best-matchup switching should
        // bring in the Water counter over the Normal after the Grass lead faints;
        // team-order would bring in the Normal (#1).
        let a = [makePoke("A0", type: "fire", atk: 155, def: 115, hp: 165),
                 makePoke("A1", type: "fire", atk: 150, def: 115, hp: 160),
                 makePoke("A2", type: "fire", atk: 150, def: 115, hp: 160)]
        let b = [makePoke("B0", type: "grass", atk: 120, def: 100, hp: 130),
                 makePoke("B1", type: "normal", atk: 130, def: 110, hp: 150),
                 makePoke("B2", type: "water", atk: 145, def: 115, hp: 160)]

        let best = ThreeVThreeBattle(teamA: a, teamB: b, switchPolicy: .bestMatchup).run()
        #expect(best.entrancesB.count >= 2)
        #expect(best.entrancesB[1] == 2)   // Water counter chosen over Normal

        let ordered = ThreeVThreeBattle(
            teamA: a.map { $0.clone() }, teamB: b.map { $0.clone() },
            switchPolicy: .teamOrder).run()
        #expect(ordered.entrancesB.count >= 2)
        #expect(ordered.entrancesB[1] == 1)   // team order brings in the Normal
    }

    @Test func battleRecordsTimeline() {
        let a = makePoke("A", type: "fire", atk: 155, def: 115, hp: 160)
        let b = makePoke("B", type: "grass", atk: 115, def: 100, hp: 130)
        let battle = Battle(a, b, record: true)
        battle.simulate()
        let log = battle.makeLog()

        #expect(!log.frames.isEmpty)
        #expect(log.frames.first?.event == nil)                        // initial frame
        #expect(log.frames.contains { $0.event?.kind == .fast })        // fast moves logged
        #expect(log.frames.contains { $0.event?.kind == .charged })     // charged move logged
        #expect(log.frames.contains { $0.event?.kind == .faint })       // grass faints to fire
        #expect(log.hpA >= 0 && log.hpB == 0)                           // A wins, B fainted
        // Frames are time-ordered.
        let times = log.frames.map(\.timeMs)
        #expect(times == times.sorted())
    }

    @Test func recordingIsOffByDefault() {
        let a = makePoke("A", type: "fire", atk: 150, def: 110, hp: 150)
        let b = makePoke("B", type: "water", atk: 150, def: 110, hp: 150)
        let battle = Battle(a, b)   // no record flag
        battle.simulate()
        #expect(battle.makeLog().frames.isEmpty)
    }
}
