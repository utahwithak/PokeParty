//
//  LastUsedTeamTests.swift
//  PokePartyTests
//
//  The Team Builder remembers the team last used in each league.
//

import Foundation
import Testing
@testable import PokeParty

@MainActor
struct LastUsedTeamTests {

    private func member(_ id: String) -> TeamMember {
        TeamMember(speciesId: id, fastMoveId: "FAST", chargedMoveIds: ["CHARGED"])
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LastUsedTeams-\(UUID().uuidString).json")
    }

    @Test func eachLeagueRemembersItsOwnTeam() {
        let model = TeamBuilderModel(lastUsedURL: tempURL())
        let great = RankingFormat.great, ultra = RankingFormat.ultra

        model.activate(format: great)
        model.add(member("azumarill"))
        model.activate(format: ultra)
        #expect(model.members.isEmpty)

        model.add(member("registeel"))
        model.activate(format: great)
        #expect(model.members.map(\.speciesId) == ["azumarill"])
        model.activate(format: ultra)
        #expect(model.members.map(\.speciesId) == ["registeel"])
    }

    @Test func survivesRelaunch() {
        let url = tempURL()
        let first = TeamBuilderModel(lastUsedURL: url)
        first.activate(format: .great)
        first.add(member("azumarill"))
        first.add(member("medicham"))

        let second = TeamBuilderModel(lastUsedURL: url)
        second.activate(format: .great)
        #expect(second.members.map(\.speciesId) == ["azumarill", "medicham"])
    }

    /// "Open in Team Builder" sets the league and the team together; the
    /// league switch that follows must not replace that team.
    @Test func openingATeamForAnotherLeagueKeepsIt() {
        let model = TeamBuilderModel(lastUsedURL: tempURL())
        model.activate(format: .great)
        model.add(member("azumarill"))

        model.setTeam([member("registeel")], for: .ultra)
        model.activate(format: .ultra)
        #expect(model.members.map(\.speciesId) == ["registeel"])

        model.activate(format: .great)
        #expect(model.members.map(\.speciesId) == ["azumarill"])
    }

    @Test func clearingATeamForgetsIt() {
        let url = tempURL()
        let model = TeamBuilderModel(lastUsedURL: url)
        model.activate(format: .great)
        model.add(member("azumarill"))
        model.remove(at: 0)

        let reloaded = TeamBuilderModel(lastUsedURL: url)
        reloaded.activate(format: .great)
        #expect(reloaded.members.isEmpty)
    }
}
