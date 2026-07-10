//
//  TeamFinderTests.swift
//  PokePartyTests
//
//  Tests for the 3v3 Party Finder engine. Uses synthetic Pokémon so the tests
//  need no network / gamemaster data.
//

import Testing
@testable import PokeParty

private func makeMoves(for types: [String]) -> [String: Move] {
    var moves: [String: Move] = [:]
    for t in Set(types) {
        moves["f_\(t)"] = Move(moveId: "f_\(t)", name: "Fast \(t)", type: t, power: 3, energy: 0,
                               energyGain: 4, cooldown: 500, turns: 1,
                               buffs: nil, buffTarget: nil, buffApplyChance: nil)
        moves["c_\(t)"] = Move(moveId: "c_\(t)", name: "Charged \(t)", type: t, power: 60, energy: 35,
                               energyGain: 0, cooldown: 0, turns: 0,
                               buffs: nil, buffTarget: nil, buffApplyChance: nil)
    }
    return moves
}

private func makeCandidate(
    _ id: String, dex: Int, type: String,
    atk: Double = 150, def: Double = 115, hp: Int = 155
) -> TeamFinder.Candidate {
    let species = Pokemon(dex: dex, speciesName: id, speciesId: id,
                          baseStats: .init(atk: Int(atk), def: Int(def), hp: hp),
                          types: [type], fastMoves: ["f_\(type)"], chargedMoves: ["c_\(type)"],
                          tags: nil, released: true, family: nil, formChange: nil)
    let combatant = MatchupSimulator.Combatant(
        species: species, shadow: false,
        fastMoveId: "f_\(type)", chargedMoveIds: ["c_\(type)"])
    return .init(
        member: TeamMember(speciesId: id, fastMoveId: "f_\(type)", chargedMoveIds: ["c_\(type)"]),
        speciesName: id, types: [type], shadow: false, familyId: nil, dex: dex,
        combatant: combatant, stats: .init(atk: atk, def: def, hp: hp))
}

@Suite struct TeamFinderTests {

    @Test func candidateTeamsAreAllDistinctCombinations() {
        let pool = [
            makeCandidate("a", dex: 1, type: "fire"),
            makeCandidate("b", dex: 2, type: "water"),
            makeCandidate("c", dex: 3, type: "grass"),
            makeCandidate("d", dex: 4, type: "rock"),
            makeCandidate("e", dex: 5, type: "ice"),
        ]
        let teams = TeamFinder.candidateTeams(from: pool)
        #expect(teams.count == 10)                       // C(5,3)
        #expect(Set(teams.map { Set($0) }).count == 10)  // all unique sets
        #expect(teams.allSatisfy { $0 == $0.sorted() })  // pool order preserved (lead first)
    }

    @Test func candidateTeamsSkipSameSpeciesVariants() {
        // "a" and "a_shadow" share a dex — no team may contain both.
        let pool = [
            makeCandidate("a", dex: 1, type: "fire"),
            makeCandidate("a_shadow", dex: 1, type: "fire"),
            makeCandidate("b", dex: 2, type: "water"),
            makeCandidate("c", dex: 3, type: "grass"),
        ]
        let teams = TeamFinder.candidateTeams(from: pool)
        #expect(!teams.isEmpty)
        #expect(teams.allSatisfy { team in
            Set(team.map { pool[$0].dex }).count == team.count
        })
    }

    @Test func findTeamsRanksTheStrongestPokemonHighest() async {
        // One clearly overpowered candidate among six; the top suggested team
        // should include it, and results should be sorted best-first.
        let pool = [
            makeCandidate("super", dex: 1, type: "dragon", atk: 175, def: 135, hp: 185),
            makeCandidate("fire", dex: 2, type: "fire"),
            makeCandidate("water", dex: 3, type: "water"),
            makeCandidate("grass", dex: 4, type: "grass"),
            makeCandidate("rock", dex: 5, type: "rock", atk: 140, def: 110, hp: 145),
            makeCandidate("ice", dex: 6, type: "ice", atk: 140, def: 110, hp: 145),
        ]
        let moves = makeMoves(for: ["dragon", "fire", "water", "grass", "rock", "ice"])

        let results = await TeamFinder.findTeams(pool: pool, movesById: moves, opponentSampleCount: 10)

        #expect(results.count == 20)   // C(6,3), all scored
        // Sorted best-first.
        let rates = results.map(\.winRate)
        #expect(rates == rates.sorted(by: >))
        // The overpowered mon anchors the best team.
        #expect(results.first?.members.contains { $0.member.speciesId == "super" } == true)
        // Records are self-consistent and within the opponent sample size.
        #expect(results.allSatisfy { $0.wins + $0.losses + $0.ties <= 10 && $0.winRate >= 0 && $0.winRate <= 1 })
    }
}
