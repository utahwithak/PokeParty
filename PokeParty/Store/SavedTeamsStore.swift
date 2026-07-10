//
//  SavedTeamsStore.swift
//  PokeParty
//
//  Persists the user's named 3v3 teams (see Team.swift, plan Q3) as a JSON file
//  in Application Support, so a team can be built once and reloaded in the
//  Team Builder or as a 3v3 battle opponent without re-picking it.
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class SavedTeamsStore {

    private(set) var teams: [Team] = []

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        teams = Self.load(from: self.fileURL)
    }

    /// Saves the members under `name`, replacing an existing team of the same name.
    func save(name: String, members: [TeamMember]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !members.isEmpty else { return }
        if let index = teams.firstIndex(where: { $0.name == trimmed }) {
            teams[index].members = members
        } else {
            teams.append(Team(name: trimmed, members: members))
        }
        persist()
    }

    func delete(_ team: Team) {
        teams.removeAll { $0.id == team.id }
        persist()
    }

    // MARK: - Disk

    private static var defaultFileURL: URL {
        let directory = URL.applicationSupportDirectory
            .appendingPathComponent("PokeParty", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("SavedTeams.json")
    }

    private static func load(from url: URL) -> [Team] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Team].self, from: data)) ?? []
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(teams) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
