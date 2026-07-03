//
//  ResourceCache.swift
//  PokeParty
//
//  A persistent SwiftData-backed blob cache for PvPoke's static JSON. Because
//  the data changes only every few months, blobs live in Application Support
//  (not Caches, which the OS can purge) and are revalidated via HTTP ETag.
//

import Foundation
import SwiftData

/// One cached HTTP resource, keyed by its relative path.
@Model
final class CachedResource {
    @Attribute(.unique) var path: String
    var data: Data
    var etag: String?
    var fetchedAt: Date

    init(path: String, data: Data, etag: String?, fetchedAt: Date = .now) {
        self.path = path
        self.data = data
        self.etag = etag
        self.fetchedAt = fetchedAt
    }
}

/// Snapshot of a cached entry, safe to pass across actors.
struct CachedEntry: Sendable {
    let data: Data
    let etag: String?
    let fetchedAt: Date
}

/// Background-isolated store for `CachedResource` rows.
@ModelActor
actor ResourceCache {
    func entry(for path: String) -> CachedEntry? {
        let descriptor = FetchDescriptor<CachedResource>(predicate: #Predicate { $0.path == path })
        guard let row = try? modelContext.fetch(descriptor).first else { return nil }
        return CachedEntry(data: row.data, etag: row.etag, fetchedAt: row.fetchedAt)
    }

    /// Insert or update the blob for `path`.
    func save(path: String, data: Data, etag: String?) {
        let descriptor = FetchDescriptor<CachedResource>(predicate: #Predicate { $0.path == path })
        if let row = try? modelContext.fetch(descriptor).first {
            row.data = data
            row.etag = etag
            row.fetchedAt = .now
        } else {
            modelContext.insert(CachedResource(path: path, data: data, etag: etag))
        }
        try? modelContext.save()
    }

    /// Remove every cached resource (used by a manual cache rebuild).
    func deleteAll() {
        try? modelContext.delete(model: CachedResource.self)
        try? modelContext.save()
    }

    /// Mark an unchanged (HTTP 304) resource as freshly revalidated.
    func touch(path: String) {
        let descriptor = FetchDescriptor<CachedResource>(predicate: #Predicate { $0.path == path })
        if let row = try? modelContext.fetch(descriptor).first {
            row.fetchedAt = .now
            try? modelContext.save()
        }
    }
}
