//
//  SavedTeamEditingTests.swift
//  PokePartyTests
//
//  The Team Builder edits a saved team in place (autosave), and a team opened
//  from elsewhere is a draft until it's saved.
//

import Foundation
import Testing
@testable import PokeParty

/// Keeps the tests off the real iCloud key-value store.
private final class FakeCloud: NSUbiquitousKeyValueStore {
    private var storage: [String: Data] = [:]
    override func data(forKey aKey: String) -> Data? { storage[aKey] }
    override func set(_ anObject: Any?, forKey aKey: String) { storage[aKey] = anObject as? Data }
    override func synchronize() -> Bool { true }
}

@MainActor
struct SavedTeamEditingTests {

    private func member(_ id: String) -> TeamMember {
        TeamMember(speciesId: id, fastMoveId: "FAST", chargedMoveIds: ["CHARGED"])
    }

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).json")
    }

    private func makeStore() -> SavedTeamsStore {
        SavedTeamsStore(fileURL: tempURL("SavedTeams"), cloud: FakeCloud())
    }

    private func makeModel(_ saved: SavedTeamsStore, url: URL? = nil) -> TeamBuilderModel {
        let model = TeamBuilderModel(lastUsedURL: url ?? tempURL("LastUsed"))
        model.attach(saved)
        model.activate(format: .great)
        return model
    }

    @Test func editsSaveToTheOpenTeam() {
        let saved = makeStore()
        let model = makeModel(saved)
        let team = saved.add(name: "Mine", members: [], cup: "all", cp: 1500)
        model.select(team, for: .great)

        model.add(member("azumarill"))
        model.add(member("medicham"))
        #expect(saved.team(id: team.id)?.members.map(\.speciesId) == ["azumarill", "medicham"])

        model.remove(at: 0)
        #expect(saved.team(id: team.id)?.members.map(\.speciesId) == ["medicham"])
    }

    @Test func aDraftIsNotSavedUntilAdopted() {
        let saved = makeStore()
        let model = makeModel(saved)

        model.setTeam([member("azumarill")], for: .great)
        #expect(model.isDraft)
        #expect(saved.teams.isEmpty)

        let team = saved.add(name: "Kept", members: model.members, cup: "all", cp: 1500)
        model.adopt(team)
        #expect(!model.isDraft)
        model.add(member("registeel"))
        #expect(saved.team(id: team.id)?.members.count == 2)
    }

    @Test func discardingADraftEmptiesTheBuilder() {
        let saved = makeStore()
        let model = makeModel(saved)
        model.setTeam([member("azumarill")], for: .great)

        model.discardDraft()
        #expect(model.members.isEmpty)
        #expect(!model.isDraft)
    }

    @Test func deletingTheOpenTeamEmptiesTheBuilder() {
        let saved = makeStore()
        let model = makeModel(saved)
        let team = saved.add(name: "Gone", members: [member("azumarill")], cup: "all", cp: 1500)
        model.select(team, for: .great)

        model.deleteTeam(team)
        #expect(saved.teams.isEmpty)
        #expect(model.members.isEmpty)
        #expect(model.currentTeamId == nil)
    }

    @Test func eachLeagueReopensItsSelectedTeamAfterRelaunch() {
        let saved = makeStore()
        let url = tempURL("LastUsed")
        let first = makeModel(saved, url: url)
        let team = saved.add(name: "Mine", members: [member("azumarill")], cup: "all", cp: 1500)
        first.select(team, for: .great)

        // Edited elsewhere while closed: the saved team is the truth.
        saved.update(id: team.id, members: [member("azumarill"), member("medicham")])

        let second = makeModel(saved, url: url)
        #expect(second.currentTeamId == team.id)
        #expect(second.members.map(\.speciesId) == ["azumarill", "medicham"])
    }

    @Test func replacingASlotKeepsOtherMembersAndRefusesDuplicates() {
        let model = makeModel(makeStore())
        model.add(member("azumarill"))
        model.add(member("medicham"))

        model.replace(at: 1, with: member("registeel"))
        #expect(model.members.map(\.speciesId) == ["azumarill", "registeel"])

        model.replace(at: 1, with: member("azumarill"))
        #expect(model.members.map(\.speciesId) == ["azumarill", "registeel"])
    }

    @Test func openingADraftOverAnUnsavedOneAsksFirst() {
        let model = makeModel(makeStore())
        model.setTeam([member("azumarill")], for: .great)

        model.openDraft([member("registeel")], for: .great)
        #expect(model.members.map(\.speciesId) == ["azumarill"])
        #expect(model.pendingDraft != nil)

        model.resolvePendingDraft(replace: false)
        #expect(model.members.map(\.speciesId) == ["azumarill"])

        model.openDraft([member("registeel")], for: .great)
        model.resolvePendingDraft(replace: true)
        #expect(model.members.map(\.speciesId) == ["registeel"])
    }

    @Test func openingADraftInAnotherLeagueDoesNotAsk() {
        let model = makeModel(makeStore())
        model.setTeam([member("azumarill")], for: .great)

        model.openDraft([member("registeel")], for: .ultra)
        #expect(model.pendingDraft == nil)
        #expect(model.members.map(\.speciesId) == ["registeel"])
    }

    @Test func outsideChangesToTheOpenTeamReachTheBuilder() {
        let saved = makeStore()
        let model = makeModel(saved)
        let team = saved.add(name: "Mine", members: [member("azumarill")], cup: "all", cp: 1500)
        model.select(team, for: .great)

        saved.save(name: "Mine", members: [member("medicham")], cup: "all", cp: 1500)
        model.syncFromSaved()
        #expect(model.members.map(\.speciesId) == ["medicham"])
    }

    @Test func duplicatingATeamGivesAnIndependentCopy() {
        let saved = makeStore()
        let team = saved.add(name: "Mine", members: [member("azumarill")], cup: "all", cp: 1500)
        let copy = saved.duplicate(team)

        #expect(copy.name == "Mine Copy")
        #expect(copy.id != team.id)
        #expect(copy.members.first?.id != team.members.first?.id)
        #expect(saved.teams.map(\.id) == [team.id, copy.id])
    }
}
