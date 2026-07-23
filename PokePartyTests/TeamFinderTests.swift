//
//  TeamFinderTests.swift
//  PokePartyTests
//
//  Tests for the 3v3 Party Finder engine. Uses synthetic Pokémon so the tests
//  need no network / gamemaster data.
//

import Foundation
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
                          eliteMoves: nil, legacyMoves: nil,
                          tags: nil, released: true, family: nil, formChange: nil)
    let combatant = MatchupSimulator.Combatant(
        species: species, shadow: false,
        fastMoveId: "f_\(type)", chargedMoveIds: ["c_\(type)"])
    return .init(
        member: TeamMember(speciesId: id, fastMoveId: "f_\(type)", chargedMoveIds: ["c_\(type)"]),
        speciesName: id, types: [type], shadow: false, familyId: nil, dex: dex,
        combatant: combatant, stats: .init(atk: atk, def: def, hp: hp))
}

/// Collects `Standings` snapshots from the tournament's @Sendable callback.
private final class SnapshotLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TeamFinder.Standings] = []
    func append(_ snapshot: TeamFinder.Standings) {
        lock.lock(); storage.append(snapshot); lock.unlock()
    }
    var snapshots: [TeamFinder.Standings] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
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

    @Test func tournamentRanksTheStrongestPokemonHighest() async {
        // One clearly overpowered candidate among six; the top team should
        // include it, and results should be sorted best-first.
        let pool = [
            makeCandidate("super", dex: 1, type: "dragon", atk: 175, def: 135, hp: 185),
            makeCandidate("fire", dex: 2, type: "fire"),
            makeCandidate("water", dex: 3, type: "water"),
            makeCandidate("grass", dex: 4, type: "grass"),
            makeCandidate("rock", dex: 5, type: "rock", atk: 140, def: 110, hp: 145),
            makeCandidate("ice", dex: 6, type: "ice", atk: 140, def: 110, hp: 145),
        ]
        let moves = makeMoves(for: ["dragon", "fire", "water", "grass", "rock", "ice"])
        let log = SnapshotLog()

        let final = await TeamFinder.findTeams(
            pool: pool, movesById: moves, fieldSize: 20,
            onStandings: { log.append($0) })
        let results = final.teams

        #expect(final.isComplete)
        #expect(results.count == 20)   // C(6,3), all under the leaderboard cap
        // Sorted best-first.
        let rates = results.map(\.winRate)
        #expect(rates == rates.sorted(by: >))
        // The overpowered mon anchors the best team.
        #expect(results.first?.members.contains { $0.member.speciesId == "super" } == true)
        // A full round robin: every team played every other team.
        #expect(results.allSatisfy { $0.gamesPlayed == 19 })
        #expect(results.allSatisfy { $0.winRate >= 0 && $0.winRate <= 1 })
    }

    // MARK: - AAAA grade check (GradeFinder)

    @Test func gradeFinderRanksAAAATeamsFirst() async {
        // Six same-type mons → near-mirror matchups, so Coverage is an easy A.
        // Five are bulky (def 140 × hp 160 = 22400 ≥ the 19800 A cutoff at CP 1500)
        // with a high switches score; one is squishy, so its teams grade below
        // AAAA and must rank after every AAAA team.
        var pool = (0..<5).map { i in
            var c = makeCandidate("bulky\(i)", dex: i + 1, type: "normal",
                                  atk: 120, def: 140, hp: 160)
            c.switchesScore = 95
            return c
        }
        pool.append(makeCandidate("weak", dex: 6, type: "normal",
                                  atk: 120, def: 90, hp: 120))
        let moves = makeMoves(for: ["normal"])

        let teams = await GradeFinder.findTopGradedTeams(
            pool: pool, cpCap: 1500, movesById: moves)

        #expect(teams.count == 20)   // C(6,3): every trio is returned, ranked
        let aaaa = teams.filter(\.isAAAA)
        #expect(aaaa.count == 10)    // C(5,3) — every bulky trio qualifies
        #expect(aaaa.allSatisfy { team in
            !team.members.contains { $0.member.speciesId == "weak" }
        })
        // AAAA teams rank above everything else (worst-grade-first ordering).
        #expect(teams.prefix(10).allSatisfy { $0.isAAAA })
        #expect(teams.dropFirst(10).allSatisfy { !$0.isAAAA })
        // All AAAA values actually clear the A cutoffs, and letters agree.
        #expect(aaaa.allSatisfy { Double($0.threatScore) <= 1200 - 0.9 * 680 })
        #expect(aaaa.allSatisfy { $0.bulkValue >= 0.9 * 22000 })
        #expect(aaaa.allSatisfy { $0.safetyValue >= 0.9 * 98 })
        #expect(aaaa.allSatisfy { $0.consistencyValue >= 0.9 * 98 })
        #expect(aaaa.allSatisfy { $0.gradeString == "AAAA" })
        // Pool order preserved within a team (lead first).
        #expect(teams.allSatisfy { $0.poolIndices == $0.poolIndices.sorted() })
    }

    @Test func gradeFinderSafetyDefaultCapsGradesWithoutSwitchesData() async {
        // Without ranking switches data, Safety falls back to PvPoke's 60 — a D —
        // so no team can grade AAAA, but the fallback still returns the best
        // available teams with an honest Safety letter.
        let pool = (0..<5).map { i in
            makeCandidate("m\(i)", dex: i + 1, type: "normal",
                          atk: 120, def: 140, hp: 160)
        }
        let teams = await GradeFinder.findTopGradedTeams(
            pool: pool, cpCap: 1500, movesById: makeMoves(for: ["normal"]))
        #expect(!teams.isEmpty)
        #expect(teams.allSatisfy { !$0.isAAAA })
        #expect(teams.allSatisfy { $0.safety != .a })
    }

    @Test func seededFieldBypassesCoverageSeeding() async {
        // A pre-seeded field (the combined AAAA + tournament method) enters the
        // round robin exactly as given.
        let types = ["fire", "water", "grass", "rock", "ice"]
        let pool = types.enumerated().map { i, t in makeCandidate(t, dex: i + 1, type: t) }
        let moves = makeMoves(for: types)
        let seeds = [[0, 1, 2], [0, 1, 3], [2, 3, 4]]

        let final = await TeamFinder.findTeams(
            pool: pool, movesById: moves, fieldSize: 10,
            seededField: seeds)

        #expect(final.isComplete)
        #expect(final.totalEntrants == 3)
        #expect(final.teams.count == 3)
        #expect(final.teams.allSatisfy { $0.gamesPlayed == 2 })
        // Exactly the seeded trios, no coverage shortlist substitutions.
        let expectedIds = Set(seeds.map { trio in trio.map { pool[$0].member.speciesId }.joined(separator: "+") })
        #expect(Set(final.teams.map(\.id)) == expectedIds)
    }

    @Test func standingsStreamMonotonicallyWithinTheFieldCap() async {
        // 8 candidates → C(8,3) = 56 trios; a small fieldSize forces the
        // coverage shortlist, and maxResults caps the visible leaderboard
        // while snapshots stay monotonic.
        let types = ["fire", "water", "grass", "rock", "ice", "electric", "flying", "ground"]
        var pool = types.enumerated().map { i, t in makeCandidate(t, dex: i + 1, type: t) }
        pool[0] = makeCandidate("super", dex: 1, type: "dragon", atk: 175, def: 135, hp: 185)
        let moves = makeMoves(for: types + ["dragon"])
        let log = SnapshotLog()

        let final = await TeamFinder.findTeams(
            pool: pool, movesById: moves,
            fieldSize: 12, maxResults: 4,
            onStandings: { log.append($0) })

        // The leaderboard is capped at maxResults…
        #expect(final.isComplete)
        #expect(final.totalEntrants == 12)
        #expect(final.teams.count == 4)
        // …every finisher played the full round robin…
        #expect(final.teams.allSatisfy { $0.gamesPlayed == 11 })
        // …and the overpowered mon's team still tops the board.
        #expect(final.teams.first?.members.contains { $0.member.speciesId == "super" } == true)

        let snapshots = log.snapshots
        #expect(!snapshots.isEmpty)
        // Round 0 is the seeded field, before any battles.
        #expect(snapshots.first?.round == 0)
        #expect(snapshots.first?.battlesFought == 0)
        #expect(snapshots.first?.totalEntrants == 12)
        // Rounds and battles never regress (emits are wall-clock throttled,
        // so consecutive snapshots may repeat a round but never go back).
        #expect(zip(snapshots, snapshots.dropFirst()).allSatisfy { a, b in
            b.round >= a.round && b.battlesFought >= a.battlesFought
        })
        // The leaderboard never shows more than maxResults teams.
        #expect(snapshots.allSatisfy { $0.teams.count <= 4 })
        // The final snapshot is complete and matches the returned standings.
        #expect(snapshots.last?.isComplete == true)
        #expect(snapshots.last?.teams.map(\.id) == final.teams.map(\.id))
    }
}
