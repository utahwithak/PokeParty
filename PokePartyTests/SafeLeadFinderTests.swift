//
//  SafeLeadFinderTests.swift
//  PokePartyTests
//
//  Tests for the "Safe lead + cover" selection. The rating matrix is built by
//  hand so the expected lead and cover are known without running any battles.
//

import Foundation
import Testing
@testable import PokeParty

private let types = ["fire", "water", "grass", "rock", "ice", "ghost"]

private func makeMoves() -> [String: Move] {
    var moves: [String: Move] = [:]
    for t in types {
        moves["f_\(t)"] = Move(moveId: "f_\(t)", name: "Fast \(t)", type: t, power: 3, energy: 0,
                               energyGain: 4, cooldown: 500, turns: 1,
                               buffs: nil, buffTarget: nil, buffApplyChance: nil)
        moves["c_\(t)"] = Move(moveId: "c_\(t)", name: "Charged \(t)", type: t, power: 60, energy: 35,
                               energyGain: 0, cooldown: 0, turns: 0,
                               buffs: nil, buffTarget: nil, buffApplyChance: nil)
    }
    return moves
}

private func makePool() -> [TeamFinder.Candidate] {
    types.enumerated().map { index, type in
        let id = "mon\(index)"
        let species = Pokemon(dex: index + 1, speciesName: id, speciesId: id,
                              baseStats: .init(atk: 150, def: 115, hp: 155),
                              types: [type], fastMoves: ["f_\(type)"], chargedMoves: ["c_\(type)"],
                              eliteMoves: nil, legacyMoves: nil,
                              tags: nil, released: true, family: nil, formChange: nil)
        return TeamFinder.Candidate(
            member: TeamMember(speciesId: id, fastMoveId: "f_\(type)", chargedMoveIds: ["c_\(type)"]),
            speciesName: id, types: [type], shadow: false, familyId: nil, dex: index + 1,
            combatant: .init(species: species, shadow: false,
                             fastMoveId: "f_\(type)", chargedMoveIds: ["c_\(type)"]),
            stats: .init(atk: 150, def: 115, hp: 155))
    }
}

/// A 6-mon matrix (`raw[a * 6 + b]` = a's rating vs b):
/// - mon0 is the safe lead: everything rates ≤ 400 against it except mon3 (700).
/// - mon4 beats mon3 (800) and mon3 loses to it; mon1/mon2/mon5 all lose to mon3's
///   hole-card, so mon4 is the only real cover for mon0's hole.
private func makeRatings() -> [Int] {
    let n = 6
    var raw = [Int](repeating: 600, count: n * n)
    for t in 0..<n where t != 0 { raw[t * n + 0] = 400 }   // nothing threatens mon0…
    raw[3 * n + 0] = 700                                   // …except mon3
    raw[4 * n + 3] = 800                                   // mon4 answers mon3
    raw[3 * n + 4] = 200
    raw[1 * n + 3] = 300
    raw[2 * n + 3] = 300
    raw[5 * n + 3] = 300
    return raw
}

@Suite struct SafeLeadFinderTests {

    @Test func safestMonIsTheFirstLead() {
        let pool = makePool()
        let threat = SafeLeadFinder.leadThreats(pool: pool, ratings: makeRatings(), metaRelevantCount: 40)
        let leads = SafeLeadFinder.chooseLeads(pool: pool, leadThreat: threat, count: 3)
        #expect(leads.first == 0)
        #expect(leads.count == 3)
        #expect(threat[0] < threat[1])
    }

    @Test func backPairCoversTheLeadsHole() {
        let pool = makePool()
        let trios = SafeLeadFinder.select(pool: pool, ratings: makeRatings(), leadCount: 1, teamsPerLead: 3)
        let top = try! #require(trios.first)
        #expect(top.indices.first == 0)       // the safe lead leads
        #expect(top.indices.contains(4))      // and the only answer to mon3 comes along
        #expect(Set(top.indices).count == 3)
    }

    @Test func resultsAreRankedAndDeduplicated() {
        let pool = makePool()
        let trios = SafeLeadFinder.select(pool: pool, ratings: makeRatings())
        #expect(!trios.isEmpty)
        #expect(zip(trios, trios.dropFirst()).allSatisfy { $0.score >= $1.score })
        #expect(Set(trios.map { $0.indices.sorted() }).count == trios.count)
    }

    @Test func gradingKeepsTheChosenOrder() {
        let pool = makePool()
        // Lead index 4 is deliberately not the lowest in the trio.
        let graded = GradeFinder.gradeTrios(
            [[4, 0, 2]], pool: pool, ratings: makeRatings(), cpCap: 1500, movesById: makeMoves())
        let team = try! #require(graded.first)
        #expect(team.poolIndices == [4, 0, 2])
        #expect(team.members.map(\.member.speciesId) == ["mon4", "mon0", "mon2"])
    }

    @Test func tooSmallAPoolYieldsNothing() {
        let pool = Array(makePool().prefix(2))
        #expect(SafeLeadFinder.select(pool: pool, ratings: [500, 500, 500, 500]).isEmpty)
    }
}
