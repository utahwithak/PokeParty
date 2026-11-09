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

    private(set) var entries: [BenchEntry] = []

    private let persistence: CloudBackedArray<BenchEntry>

    init(fileURL: URL? = nil, cloud: NSUbiquitousKeyValueStore = .default) {
        persistence = CloudBackedArray(
            cloudKey: "Bench",
            fileURL: fileURL ?? JSONFileStore.defaultFileURL(filename: "Bench.json"),
            cloud: cloud
        )
        entries = persistence.load()
        persistence.observeExternalChanges { [weak self] items in self?.entries = items }
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
            moveset = Array(ranking.moveset.prefix(4))
        } else if let species = store.pokemonById[speciesId] {
            moveset = (species.fastMoves.first.map { [$0] } ?? [])
                + species.defaultChargedMoveIds
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

    /// Creates and adds a bench entry from a scan result: known IVs, the
    /// date it was caught, and whether the scan was marked Shadow, for a
    /// specific league (or unclassified if nil).
    @discardableResult
    func addFromScan(
        speciesId: String, ivs: IVs, capturedDate: Date, shadow: Bool, league: League?, store: RankingsStore
    ) -> BenchEntry {
        var entry = addFromRankings(speciesId: speciesId, store: store, league: league)
        entry.ivs = ivs
        entry.capturedDate = capturedDate
        entry.shadow = shadow
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

    private func persist() {
        persistence.save(entries)
    }
}
