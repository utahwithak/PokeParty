//
//  BenchStore.swift
//  PokeParty
//
//  Persists the player's personal bench of Pokémon (each with their actual IVs
//  and chosen moveset) as a JSON file in Application Support.
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class BenchStore {

    private(set) var entries: [BenchEntry] = []

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        entries = Self.load(from: self.fileURL)
    }

    func entry(id: BenchEntry.ID) -> BenchEntry? {
        entries.first { $0.id == id }
    }

    func add(_ entry: BenchEntry) {
        entries.append(entry)
        persist()
    }

    func update(_ entry: BenchEntry) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[i] = entry
        persist()
    }

    func delete(_ entry: BenchEntry) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    /// Creates and adds a bench entry for a species, defaulting to the
    /// recommended moveset for the current league (or the first available moves).
    @discardableResult
    func addFromRankings(speciesId: String, store: RankingsStore, league: League = .great) -> BenchEntry {
        let moveset: [String]
        if let ranking = store.entry(id: speciesId), ranking.moveset.count >= 2 {
            moveset = Array(ranking.moveset.prefix(3))
        } else if let species = store.pokemonById[speciesId] {
            moveset = (species.fastMoves.first.map { [$0] } ?? [])
                + Array(species.chargedMoves.prefix(2))
        } else {
            moveset = []
        }

        let fast = moveset.first ?? ""
        let charged = moveset.count > 1 ? Array(moveset[1...]) : []
        let shadow = store.pokemonById[speciesId]?.isShadow ?? false

        let entry = BenchEntry(
            speciesId: speciesId,
            fastMoveId: fast,
            chargedMoveIds: charged,
            shadow: shadow,
            league: league
        )
        add(entry)
        return entry
    }

    /// Returns true if the species already has a bench entry for the given league.
    func contains(speciesId: String, league: League) -> Bool {
        entries.contains { $0.speciesId == speciesId && $0.league == league }
    }

    // MARK: - Disk

    private static var defaultFileURL: URL {
        let dir = URL.applicationSupportDirectory
            .appendingPathComponent("PokeParty", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Bench.json")
    }

    private static func load(from url: URL) -> [BenchEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([BenchEntry].self, from: data)) ?? []
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
