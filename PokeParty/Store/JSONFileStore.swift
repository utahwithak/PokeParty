//
//  JSONFileStore.swift
//  PokeParty
//
//  Shared disk I/O for the app's JSON-array stores (SavedTeamsStore,
//  BenchStore) — each keeps its own in-memory array and higher-level
//  CRUD/cloud-sync behavior, but all persist the same way: one JSON array
//  file in Application Support. (Saved tournaments and optimizer runs moved
//  to one file per run in `SyncedRunsStore`, which still uses `load` to
//  migrate their old array files.)
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

    /// Coders are created per call: `JSONEncoder`/`JSONDecoder` aren't
    /// `Sendable`, and these helpers are called from background tasks too.
    static func decode<T: Decodable>(_ type: T.Type = T.self, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }

    static func encode<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }

    static func load<T: Decodable>(from url: URL) -> [T] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return decode([T].self, from: data) ?? []
    }

    /// Reads a single (non-array) value, nil when the file is absent or invalid.
    static func loadValue<T: Decodable>(_ type: T.Type = T.self, from url: URL) -> T? {
        (try? Data(contentsOf: url)).flatMap { decode(type, from: $0) }
    }

    static func write(_ data: Data, to url: URL) {
        try? data.write(to: url, options: .atomic)
    }
}

/// iCloud-first persistence for a JSON array (BenchStore, SavedTeamsStore):
/// `NSUbiquitousKeyValueStore` is the primary copy so the array syncs across
/// devices, with the Application Support file kept as an offline fallback.
@MainActor
final class CloudBackedArray<Item: Codable> {
    private let cloudKey: String
    private let fileURL: URL
    private let cloud: NSUbiquitousKeyValueStore

    init(cloudKey: String, fileURL: URL, cloud: NSUbiquitousKeyValueStore) {
        self.cloudKey = cloudKey
        self.fileURL = fileURL
        self.cloud = cloud
    }

    /// Calls `handler` with the new array when another device changes the
    /// iCloud copy. Call once, after the owner is fully initialised.
    func observeExternalChanges(_ handler: @escaping @MainActor ([Item]) -> Void) {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud, queue: .main
        ) { [weak self] _ in
            // Delivered on `.main`, so we're already on the main actor.
            MainActor.assumeIsolated {
                guard let items = self?.cloudItems() else { return }
                handler(items)
            }
        }
    }

    /// Cloud-first: prefers whatever iCloud already has, otherwise loads the
    /// local file and migrates it up to iCloud.
    func load() -> [Item] {
        defer { cloud.synchronize() }
        if let items = cloudItems() { return items }
        let local: [Item] = JSONFileStore.load(from: fileURL)
        if !local.isEmpty, let data = JSONFileStore.encode(local) {
            cloud.set(data, forKey: cloudKey)
        }
        return local
    }

    func save(_ items: [Item]) {
        guard let data = JSONFileStore.encode(items) else { return }
        cloud.set(data, forKey: cloudKey)
        cloud.synchronize()
        JSONFileStore.write(data, to: fileURL)
    }

    private func cloudItems() -> [Item]? {
        cloud.data(forKey: cloudKey).flatMap { JSONFileStore.decode([Item].self, from: $0) }
    }
}
