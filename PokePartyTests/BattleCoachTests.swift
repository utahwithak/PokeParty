//
//  BattleCoachTests.swift
//  PokePartyTests
//
//  Decision rules are tested on hand-built scores; the simulation path uses
//  fully revealed opponents with synthetic Pokémon so no data files are needed.
//

import Testing
@testable import PokeParty

private func option(_ action: BattleCoach.Option.Action, index: Int, name: String,
                    win: Double, rating: Double) -> BattleCoach.Option {
    BattleCoach.Option(action: action, pokemonIndex: index, pokemonName: name,
                       winRate: win, averageRating: rating)
}

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

@Suite struct BattleCoachTests {

    @Test func recommendsClearlyBetterSwitch() {
        let advice = BattleCoach.advice(from: [
            option(.stay, index: 0, name: "Stunfisk", win: 0.40, rating: 420),
            option(.switchTo(1), index: 1, name: "Azumarill", win: 0.70, rating: 640),
            option(.switchTo(2), index: 2, name: "Medicham", win: 0.45, rating: 480),
        ], samples: 24, myShields: 2, opponentShields: 2)

        #expect(advice?.recommended.action == .switchTo(1))
        #expect(advice?.headline == "Switch to Azumarill")
    }

    @Test func staysWhenSwitchIsWithinNoise() {
        let advice = BattleCoach.advice(from: [
            option(.stay, index: 0, name: "Stunfisk", win: 0.52, rating: 510),
            option(.switchTo(1), index: 1, name: "Azumarill", win: 0.54, rating: 515),
        ], samples: 24, myShields: 1, opponentShields: 1)

        #expect(advice?.recommended.action == .stay)
        #expect(advice?.headline == "Stay in with Stunfisk")
    }

    @Test func losingMatchupMakesTheSwitchUrgent() {
        let advice = BattleCoach.advice(from: [
            option(.stay, index: 0, name: "Stunfisk", win: 0.10, rating: 250),
            option(.switchTo(1), index: 1, name: "Azumarill", win: 0.65, rating: 600),
        ], samples: 24, myShields: 0, opponentShields: 2)

        #expect(advice?.headline == "Switch to Azumarill now")
    }

    @Test func adviceNeedsTheStayOption() {
        let advice = BattleCoach.advice(from: [
            option(.switchTo(1), index: 1, name: "Azumarill", win: 0.65, rating: 600),
        ], samples: 24, myShields: 2, opponentShields: 2)

        #expect(advice == nil)
    }

    @Test func switchesOutOfAnOutclassedMatchup() async {
        // Lead is far weaker than the opposing team; the bench Pokémon are far stronger.
        let mine = [
            makePoke("weak", type: "normal", atk: 100, def: 80, hp: 90),
            makePoke("strong", type: "fire", atk: 175, def: 135, hp: 185),
            makePoke("strong2", type: "water", atk: 175, def: 135, hp: 185),
        ]
        let theirs = [
            makePoke("o0", type: "grass", atk: 140, def: 110, hp: 150),
            makePoke("o1", type: "grass", atk: 140, def: 110, hp: 150),
            makePoke("o2", type: "grass", atk: 140, def: 110, hp: 150),
        ]
        let state = BattleCoach.State(
            myTeam: mine, myActive: 0, myShields: 2,
            opponentRevealed: theirs, opponentActive: 0, opponentShields: 2)

        let advice = await BattleCoach.advise(state, pool: [], movesById: [:], samples: 2, seed: 1)

        #expect(advice != nil)
        if case .switchTo? = advice?.recommended.action {} else {
            Issue.record("Expected a switch, got \(String(describing: advice?.headline))")
        }
    }
}
