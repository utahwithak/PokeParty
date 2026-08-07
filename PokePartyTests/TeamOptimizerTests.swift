//
//  TeamOptimizerTests.swift
//  PokePartyTests
//
//  Verifies that the 1v1 pre-filter optimization does not degrade the quality
//  of teams found by the hill-climbing optimizer. Both runs use the same
//  deterministic starting points; the pre-filtered run is expected to converge
//  to the same (or comparably good) local optimum because the validation sweep
//  confirms each result is a true local optimum before accepting it.
//

import Foundation
import Testing
@testable import PokeParty

private func makeOptimizerInput() -> (entries: [RankingEntry], pokemonById: [String: Pokemon], movesById: [String: Move]) {
    let types = ["fire", "water", "grass", "rock", "ice",
                 "electric", "flying", "ground", "normal", "dragon"]

    var pokemonById: [String: Pokemon] = [:]
    var movesById: [String: Move] = [:]
    var entries: [RankingEntry] = []

    for (i, type) in types.enumerated() {
        let id      = "p_\(type)"
        let fastId  = "f_\(type)"
        let c1Id    = "c1_\(type)"
        let c2Id    = "c2_\(type)"

        pokemonById[id] = Pokemon(
            dex: i + 1, speciesName: id, speciesId: id,
            baseStats: .init(atk: 130 + i * 2, def: 115, hp: 140),
            types: [type],
            fastMoves: [fastId], chargedMoves: [c1Id, c2Id],
            eliteMoves: nil, legacyMoves: nil,
            tags: nil, released: true, family: nil, formChange: nil)

        movesById[fastId] = Move(
            moveId: fastId, name: fastId, type: type,
            power: 4, energy: 0, energyGain: 5,
            cooldown: 1000, turns: 2,
            buffs: nil, buffTarget: nil, buffApplyChance: nil)
        movesById[c1Id] = Move(
            moveId: c1Id, name: c1Id, type: type,
            power: 65, energy: 35, energyGain: 0,
            cooldown: 0, turns: 0,
            buffs: nil, buffTarget: nil, buffApplyChance: nil)
        movesById[c2Id] = Move(
            moveId: c2Id, name: c2Id, type: type,
            power: 110, energy: 65, energyGain: 0,
            cooldown: 0, turns: 0,
            buffs: nil, buffTarget: nil, buffApplyChance: nil)

        entries.append(RankingEntry(
            speciesId: id, speciesName: id,
            rating: Double(100 - i), score: Double(100 - i),
            scores: nil,
            moveset: [fastId, c1Id, c2Id],
            matchups: [], counters: [],
            moves: .init(
                fastMoves:    [.init(moveId: fastId, uses: 1.0)],
                chargedMoves: [.init(moveId: c1Id, uses: 0.8),
                               .init(moveId: c2Id, uses: 0.6)]),
            stats: .init(product: nil, atk: 100.5, def: 90.8, hp: 119)))
    }

    return (entries, pokemonById, movesById)
}

@Suite struct TeamOptimizerTests {

    @Test func prefilterMatchesFullSweepQuality() async {
        let (entries, pokemonById, movesById) = makeOptimizerInput()

        let baseline = await TeamOptimizer.findTeams(
            entries: entries, poolSize: 10, cpCap: 1500,
            pokemonById: pokemonById, movesById: movesById,
            metaSize: 5, restarts: 5, maxResults: 10,
            learnedShields: false, learnedSwitches: false,
            prefilterTopK: 0)   // full sweep every step

        let filtered = await TeamOptimizer.findTeams(
            entries: entries, poolSize: 10, cpCap: 1500,
            pokemonById: pokemonById, movesById: movesById,
            metaSize: 5, restarts: 5, maxResults: 10,
            learnedShields: false, learnedSwitches: false,
            prefilterTopK: 5)   // evaluate only the top 5 swaps per step

        #expect(baseline.isComplete)
        #expect(filtered.isComplete)

        guard let baseTop = baseline.teams.first,
              let filtTop = filtered.teams.first
        else {
            Issue.record("Optimizer returned no teams")
            return
        }

        // The pre-filtered result must find a local optimum within 5% of the
        // full-sweep baseline. In practice the validation sweep means they are
        // usually identical; the tolerance handles rare cases where different
        // restarts converge to distinct but comparable local optima.
        #expect(filtTop.metaScore >= baseTop.metaScore - 0.05,
                "Pre-filter degraded quality: \(filtTop.metaScore) vs baseline \(baseTop.metaScore)")
    }
}
