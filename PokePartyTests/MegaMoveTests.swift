//
//  MegaMoveTests.swift
//  PokePartyTests
//
//  Covers a Mega's exclusive third charged move: the mega-level damage
//  bonus, default movesets with the third slot, and the super Mega level cap.
//

import Foundation
import Testing
@testable import PokeParty

private func makeMove(_ id: String, power: Int, isMegaMove: Bool? = nil) -> Move {
    Move(moveId: id, name: id, type: "normal", power: power, energy: 50, energyGain: 0,
         cooldown: 500, turns: nil, buffs: nil, buffTarget: nil, buffApplyChance: nil,
         isMegaMove: isMegaMove)
}

private func makeMega(tags: [String], extra: [String]? = ["BIG_PLUS"]) -> Pokemon {
    Pokemon(dex: 1, speciesName: "mega", speciesId: "mega",
            baseStats: .init(atk: 200, def: 150, hp: 150), types: ["normal"],
            fastMoves: ["F"], chargedMoves: ["A", "B", "C"], extraChargedMoves: extra,
            eliteMoves: nil, legacyMoves: nil, tags: tags, released: true,
            family: nil, formChange: nil)
}

@Suite struct MegaMoveTests {

    @Test() func megaBonusScalesWithMegaLevel() {
        let plus = makeMove("BIG_PLUS", power: 100, isMegaMove: true)
        #expect(BattleMove(from: plus, megaLevel: 3).megaBonus == 1.2000000476837158203125)
        #expect(BattleMove(from: plus, megaLevel: 4).megaBonus == 1.2999999523162841796875)
    }

    @Test() func ordinaryMovesGetNoMegaBonus() {
        let normal = makeMove("A", power: 100)
        #expect(BattleMove(from: normal, megaLevel: 4).megaBonus == 1)
    }

    @Test() func defaultMovesetAddsThirdSlotForMegas() {
        #expect(makeMega(tags: ["mega"]).defaultChargedMoveIds == ["A", "B", "BIG_PLUS"])
        // Without the mega tag the extra move is ignored (e.g. Cramorant's Gulp Missile).
        #expect(makeMega(tags: []).defaultChargedMoveIds == ["A", "B"])
    }

    @Test() func superMegaLevelCapIsFiftyTwoInMasterLeague() {
        let sm = makeMega(tags: ["mega", "supermega"])
        #expect(sm.megaLevel == 4)
        #expect(sm.levelCap(isBestBuddy: false, cpCap: 10000) == 52)
        #expect(sm.levelCap(isBestBuddy: false, cpCap: 1500) == 50)
        #expect(makeMega(tags: ["mega"]).levelCap(isBestBuddy: false, cpCap: 10000) == 50)
    }

    @Test() func playerMegaLevelOverridesSpeciesDefault() {
        let sm = makeMega(tags: ["mega", "supermega"])
        // A level 1 mega still has the move, but at a 1.0× bonus and the normal cap.
        #expect(sm.levelCap(megaLevel: 1, isBestBuddy: false, cpCap: 10000) == 50)
        #expect(sm.levelCap(megaLevel: 4, isBestBuddy: false, cpCap: 10000) == 52)
        let plus = makeMove("BIG_PLUS", power: 100, isMegaMove: true)
        let moves = ["F": makeMove("F", power: 3), "A": makeMove("A", power: 60),
                     "BIG_PLUS": plus]
        let stats = BattlePokemon.Stats(atk: 200, def: 150, hp: 150)
        func bonus(_ level: Int?) -> Double? {
            let c = MatchupSimulator.Combatant(
                species: sm, shadow: false, fastMoveId: "F",
                chargedMoveIds: ["A", "BIG_PLUS"], megaLevel: level)
            return MatchupSimulator.makeBattlePokemon(c, stats: stats, movesById: moves, shields: 1)?
                .chargedMoves.last?.megaBonus
        }
        #expect(bonus(1) == 1)
        #expect(bonus(nil) == 1.2999999523162841796875)
    }

    @Test() func clearingNormalSlotKeepsMegaMove() {
        var member = TeamMember(speciesId: "mega", fastMoveId: "F", chargedMoveIds: ["A", "B", "BIG_PLUS"])
        member.setChargedMove(nil, slot: 1)
        #expect(member.chargedMoveIds == ["A", "B", "BIG_PLUS"])
        member.setChargedMove(nil, slot: 2)
        member.setChargedMove(nil, slot: 1)
        #expect(member.chargedMoveIds == ["A"])
    }
}
