//
//  BenchStore.swift
//  PokeParty
//
//  Persists the player's personal bench of Pokémon (each with their actual IVs
//  and chosen moveset). Primary storage is NSUbiquitousKeyValueStore so the
//  bench syncs across the user's devices via iCloud. The local Application
//  Support file is kept as an offline fallback and migrated to iCloud on first
//  launch.
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class BenchStore {

    private static let cloudKey = "Bench"

    private(set) var entries: [BenchEntry] = []

    private let fileURL: URL
    private let cloud: NSUbiquitousKeyValueStore

    init(fileURL: URL? = nil, cloud: NSUbiquitousKeyValueStore = .default) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        self.cloud = cloud

        // Cloud-first: prefer whatever iCloud already has.
        if let data = cloud.data(forKey: Self.cloudKey),
           let saved = try? JSONDecoder().decode([BenchEntry].self, from: data) {
            entries = saved
        } else {
            // Fall back to local file and migrate it up to iCloud.
            let local = Self.load(from: self.fileURL)
            entries = local
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
              let saved = try? JSONDecoder().decode([BenchEntry].self, from: data) else { return }
        entries = saved
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
    /// recommended moveset for the current league (or the first available
    /// moves). `league` nil leaves the entry unclassified.
    @discardableResult
    func addFromRankings(speciesId: String, store: RankingsStore, league: League? = .great) -> BenchEntry {
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

    /// Creates and adds a bench entry from a scan result: known IVs and the
    /// date it was caught, for a specific league (or unclassified if nil).
    @discardableResult
    func addFromScan(
        speciesId: String, ivs: IVs, capturedDate: Date, league: League?, store: RankingsStore
    ) -> BenchEntry {
        var entry = addFromRankings(speciesId: speciesId, store: store, league: league)
        entry.ivs = ivs
        entry.capturedDate = capturedDate
        update(entry)
        return entry
    }

    /// Returns true if the species already has a bench entry for the given
    /// league (nil checks the unclassified bucket).
    func contains(speciesId: String, league: League?) -> Bool {
        entries.contains { $0.speciesId == speciesId && $0.league == league }
    }

    /// Finds an existing bench entry that likely represents the same physical
    /// catch: same evolution family, same IVs, same captured day. Pokémon can
    /// evolve between scans, so identity is tracked by family rather than
    /// species — re-scanning the same mon after it evolves same-day still
    /// matches instead of creating a second entry.
    func duplicate(speciesId: String, ivs: IVs, capturedDate: Date, store: RankingsStore) -> BenchEntry? {
        guard let familyId = store.pokemonById[speciesId]?.family?.id else { return nil }
        return entries.first { entry in
            guard entry.ivs == ivs,
                  let entryDate = entry.capturedDate,
                  Calendar.current.isDate(entryDate, inSameDayAs: capturedDate)
            else { return false }
            return store.pokemonById[entry.speciesId]?.family?.id == familyId
        }
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
        cloud.set(data, forKey: Self.cloudKey)
        cloud.synchronize()
        try? data.write(to: fileURL, options: .atomic)
    }
}
