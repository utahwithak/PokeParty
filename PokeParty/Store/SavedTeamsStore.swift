//
//  SavedTeamsStore.swift
//  PokeParty
//
//  Persists the user's named 3v3 teams as a JSON file in Application Support,
//  so a team can be built once and reloaded in the Team Builder or as a 3v3
//  battle opponent without re-picking it. Primary storage is
//  NSUbiquitousKeyValueStore so teams sync across the user's devices via
//  iCloud; the local file is kept as an offline fallback.
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class SavedTeamsStore {

    private static let cloudKey = "SavedTeams"

    private(set) var teams: [Team] = []

    private let fileURL: URL
    private let cloud: NSUbiquitousKeyValueStore

    init(fileURL: URL? = nil, cloud: NSUbiquitousKeyValueStore = .default) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        self.cloud = cloud

        if let data = cloud.data(forKey: Self.cloudKey),
           let saved = try? JSONDecoder().decode([Team].self, from: data) {
            teams = saved
        } else {
            let local = Self.load(from: self.fileURL)
            teams = local
            if !local.isEmpty {
                if let data = try? JSONEncoder().encode(local) {
                    cloud.set(data, forKey: Self.cloudKey)
                    cloud.synchronize()
                }
            }
        }

        cloud.synchronize()

        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyCloudChange()
            }
        }
    }

    private func applyCloudChange() {
        guard let data = cloud.data(forKey: Self.cloudKey),
              let saved = try? JSONDecoder().decode([Team].self, from: data) else { return }
        teams = saved
    }

    /// Saves the members under `name` for the given format, replacing an
    /// existing team of the same name saved for that same format.
    func save(name: String, members: [TeamMember], cup: String, cp: Int) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !members.isEmpty else { return }
        if let index = teams.firstIndex(where: { $0.name == trimmed && $0.cup == cup && $0.cp == cp }) {
            teams[index].members = members
        } else {
            teams.append(Team(name: trimmed, members: members, cup: cup, cp: cp))
        }
        persist()
    }

    func delete(_ team: Team) {
        teams.removeAll { $0.id == team.id }
        persist()
    }

    /// Saved teams for the given format only.
    func teams(for format: RankingFormat) -> [Team] {
        teams.filter { $0.matches(format) }
    }

    // MARK: - Disk

    private static var defaultFileURL: URL {
        JSONFileStore.defaultFileURL(filename: "SavedTeams.json")
    }

    private static func load(from url: URL) -> [Team] {
        JSONFileStore.load(from: url)
    }

    private func persist() {
        guard let data = JSONFileStore.encode(teams) else { return }
        cloud.set(data, forKey: Self.cloudKey)
        cloud.synchronize()
        JSONFileStore.write(data, to: fileURL)
    }
}
