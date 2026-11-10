//
//  ThreatEntryTests.swift
//  PokePartyTests
//
//  `TeamAnalyzer.threatEntry` is shared by the full team analysis and the Team
//  Builder's "check a Pokémon"; it must rate a candidate exactly as the
//  analysis does.
//

import Foundation
import Testing
@testable import PokeParty

private let types = ["fire", "water", "grass"]

private func moves() -> [String: Move] {
    var out: [String: Move] = [:]
    for t in types {
        out["f_\(t)"] = Move(moveId: "f_\(t)", name: "Fast \(t)", type: t, power: 3, energy: 0,
                             energyGain: 4, cooldown: 500, turns: 1,
                             buffs: nil, buffTarget: nil, buffApplyChance: nil)
        out["c_\(t)"] = Move(moveId: "c_\(t)", name: "Charged \(t)", type: t, power: 60, energy: 35,
                             energyGain: 0, cooldown: 0, turns: 0,
                             buffs: nil, buffTarget: nil, buffApplyChance: nil)
    }
    return out
}

private func combatant(_ id: String, dex: Int, type: String, atk: Int = 150) -> MatchupSimulator.Combatant {
    let species = Pokemon(dex: dex, speciesName: id, speciesId: id,
                          baseStats: .init(atk: atk, def: 115, hp: 155),
                          types: [type], fastMoves: ["f_\(type)"], chargedMoves: ["c_\(type)"],
                          eliteMoves: nil, legacyMoves: nil,
                          tags: nil, released: true, family: nil, formChange: nil)
    return .init(species: species, shadow: false, fastMoveId: "f_\(type)", chargedMoveIds: ["c_\(type)"])
}

private func candidate(_ c: MatchupSimulator.Combatant, metaRelevant: Bool) -> MetaCandidate {
    MetaCandidate(species: c.species, shadow: c.shadow, fastMoveId: c.fastMoveId,
                  chargedMoveIds: c.chargedMoveIds, familyId: nil, metaRelevant: metaRelevant,
                  precomputedStats: .init(atk: Double(c.species.baseStats.atk), def: 115, hp: 155))
}

@MainActor @Suite struct ThreatEntryTests {

    private let movesById = moves()
    private let team = [combatant("a", dex: 1, type: "fire"), combatant("b", dex: 2, type: "water")]
    private let teamStats: [BattlePokemon.Stats] = [.init(atk: 150, def: 115, hp: 155), .init(atk: 150, def: 115, hp: 155)]

    @Test func ratesTheCandidateAgainstEveryMemberInOrder() throws {
        let cand = candidate(combatant("grass-mon", dex: 3, type: "grass"), metaRelevant: false)
        let entry = try #require(TeamAnalyzer.threatEntry(
            for: cand, team: team, teamStats: teamStats, cpCap: 1500, movesById: movesById))
        #expect(entry.ratings.count == team.count)
        #expect(entry.speciesId == "grass-mon")
        #expect(entry.averageRating == entry.ratings.reduce(0, +) / entry.ratings.count)
        // Grass beats water, loses to fire: the ratings must differ in that direction.
        #expect(entry.ratings[1] > entry.ratings[0])
    }

    @Test func matchesWhatTheFullAnalysisReportsForTheSameCandidate() async throws {
        let cand = candidate(combatant("grass-mon", dex: 3, type: "grass"), metaRelevant: true)
        let direct = try #require(TeamAnalyzer.threatEntry(
            for: cand, team: team, teamStats: teamStats, cpCap: 1500, movesById: movesById))
        let analysis = await TeamAnalyzer.analyze(
            team: team, teamStats: teamStats, meta: [cand], cpCap: 1500, movesById: movesById)
        let fromAnalysis = try #require(analysis.threats.first { $0.speciesId == "grass-mon" })
        #expect(fromAnalysis.ratings == direct.ratings)
        #expect(fromAnalysis.averageRating == direct.averageRating)
        #expect(fromAnalysis.score == direct.score)
    }
}
