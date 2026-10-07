//
//  JSONFileStore.swift
//  PokeParty
//
//  Shared disk I/O for the app's JSON-array stores (SavedTeamsStore,
//  BenchStore, SavedTournamentsStore, SavedOptimizerRunsStore) — each keeps
//  its own in-memory array and higher-level CRUD/cloud-sync behavior, but
//  all persist the same way: one JSON array file in Application Support.
//

import Foundation

nonisolated enum JSONFileStore {
    /// `PokeParty/<filename>` in Application Support, creating the directory
    /// if needed.
    static func defaultFileURL(filename: String) -> URL {
        let directory = URL.applicationSupportDirectory
            .appendingPathComponent("PokeParty", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(filename)
    }

    static func load<T: Decodable>(from url: URL) -> [T] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }

    static func encode<T: Encodable>(_ items: [T]) -> Data? {
        try? JSONEncoder().encode(items)
    }

    static func write(_ data: Data, to url: URL) {
        try? data.write(to: url, options: .atomic)
    }
}
