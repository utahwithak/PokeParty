//
//  TeamInsightsTests.swift
//  PokePartyTests
//
//  The Team Builder's weakness and lead/switch/closer helpers, on hand-built
//  teams whose answers follow from the type chart and the role scores.
//

import Foundation
import Testing
@testable import PokeParty

@Suite struct TeamInsightsTests {

    private let team: [TeamWeakness.Member] = [
        .init(name: "Frost", types: ["ice"]),
        .init(name: "Leaf", types: ["grass"]),
        .init(name: "Wave", types: ["water"]),
    ]

    @Test func sharedWeaknessLeadsTheListAndIsFlagged() throws {
        let rows = TeamWeakness.analyze(members: team)
        let top = try #require(rows.first)
        // Fire hurts ice and grass, and water resists it: shared, but answered.
        #expect(top.type == "fire")
        #expect(top.weakMembers == [0, 1])
        #expect(top.resistMembers == [2])
        #expect(top.isShared)
        #expect(!top.isUnanswered)
    }

    @Test func aWeaknessNobodyResistsIsUnanswered() throws {
        let rows = TeamWeakness.analyze(members: team)
        let rock = try #require(rows.first { $0.type == "rock" })     // only ice is weak to rock
        #expect(rock.weakMembers == [0])
        #expect(rock.resistMembers.isEmpty)
        #expect(rock.isUnanswered)
        #expect(!rock.isShared)
    }

    @Test func bannedTypesAreLeftOut() {
        let rows = TeamWeakness.analyze(members: team, banned: ["fire", "dark"])
        #expect(!rows.contains { $0.type == "fire" || $0.type == "dark" })
        #expect(rows.count == TypeChart.allTypes.count - 2)
    }

    @Test func cupTypeExcludesBecomeBannedTypes() {
        let cup = Cup(
            name: "x", title: "X", include: [],
            exclude: [
                .init(filterType: "type", values: [.string("Fire"), .string("dark")]),
                .init(filterType: "id", values: [.string("chansey")]),                 // not a type
                .init(filterType: "type", values: [.string("steel")], leagues: [2500]), // other league
            ])
        #expect(TeamWeakness.bannedTypes(in: cup, cpCap: 1500) == ["fire", "dark"])
        #expect(TeamWeakness.bannedTypes(in: cup, cpCap: 2500) == ["fire", "dark", "steel"])
        #expect(TeamWeakness.bannedTypes(in: nil, cpCap: 1500).isEmpty)
    }

    // MARK: - Roles

    private func scores(lead: Double, closer: Double, switchIn: Double) -> RoleOrder.Scores? {
        RoleOrder.Scores([lead, closer, switchIn, 0, 0, 0])
    }

    @Test func rankingScoresMapToRolesInPvPokeOrder() throws {
        // [leads, closers, switches, …]
        let s = try #require(RoleOrder.Scores([10, 20, 30, 40, 50, 60]))
        #expect(s.lead == 10 && s.closer == 20 && s.switch == 30)
        #expect(RoleOrder.Scores([1, 2]) == nil)
        #expect(RoleOrder.Scores(nil) == nil)
    }

    @Test func bestOrderMaximizesTheSummedRoleScores() {
        // Member 2 is the lead, 0 the switch, 1 the closer.
        let order = RoleOrder.best([
            scores(lead: 20, closer: 30, switchIn: 90),
            scores(lead: 30, closer: 85, switchIn: 40),
            scores(lead: 95, closer: 20, switchIn: 30),
        ])
        #expect(order == [2, 0, 1])
    }

    @Test func noOrderWithoutThreeScoredMembers() {
        let one = scores(lead: 1, closer: 1, switchIn: 1)
        #expect(RoleOrder.best([one, one]) == nil)
        #expect(RoleOrder.best([one, one, nil]) == nil)
    }
}
