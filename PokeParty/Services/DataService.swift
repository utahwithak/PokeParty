//
//  DataService.swift
//  PokeParty
//
//  Fetches PvPoke's static JSON data, backed by a persistent SwiftData cache.
//

import Foundation
import SwiftData

/// Loads Pokémon, move and ranking data from pvpoke.com.
///
/// PvPoke's data changes only every few months, so blobs are persisted via
/// `ResourceCache` (SwiftData, in Application Support). A long freshness window
/// avoids the network entirely most launches; when stale, the resource is
/// revalidated cheaply with an HTTP ETag (a 304 just refreshes the timestamp).
/// On any network failure, a stale cache is used so the app works offline.
actor DataService {
    static let shared = DataService()

    /// The combined Pokémon + move data file.
    struct GameMaster: Decodable {
        let pokemon: [Pokemon]
        let moves: [Move]
        /// Currently active formats/cups (e.g. Summer Cup).
        let formats: [RankingFormat]?
    }

    enum DataError: LocalizedError {
        case unavailable
        var errorDescription: String? {
            "Couldn't load data. Check your connection and try again."
        }
    }

    /// How aggressively to bypass the on-disk cache.
    enum LoadPolicy {
        case cache       // serve fresh cache without network (default)
        case revalidate  // skip the freshness window; confirm via ETag (304 is cheap)
        case reload      // ignore cache; force a full download
    }

    private let baseURL = URL(string: "https://pvpoke.com/data/")!
    private let maxCacheAge: TimeInterval = 60 * 60 * 24 * 7 // 7 days
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let cache: ResourceCache?
    private var hasSeeded = false

    /// Bundled fallbacks for a fresh install (or a cleared cache) so the app
    /// has something to show before any network call succeeds — see
    /// `seedBundledDataIfNeeded()`. Cups aren't seeded since they rotate and
    /// a stale one would be actively misleading; only re-fetched via network.
    /// IMPORTANT: refresh these bundled JSON files before each release — see
    /// docs/RELEASE_CHECKLIST.md.
    private static let seedResources: [(path: String, resourceName: String)] = [
        ("gamemaster.json", "seed_gamemaster"),
        ("rankings/all/overall/rankings-1500.json", "seed_rankings_1500"),
        ("rankings/all/overall/rankings-2500.json", "seed_rankings_2500"),
        ("rankings/all/overall/rankings-10000.json", "seed_rankings_10000"),
    ]

    init() {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)

        // Persistent store in Application Support; nil disables caching gracefully.
        if let container = try? ModelContainer(for: CachedResource.self) {
            cache = ResourceCache(modelContainer: container)
        } else {
            cache = nil
        }
    }

    // MARK: - Public API

    func gameMaster(policy: LoadPolicy = .cache) async throws -> GameMaster {
        try await load(path: "gamemaster.json", as: GameMaster.self, policy: policy)
    }

    func rankings(for format: RankingFormat, policy: LoadPolicy = .cache) async throws -> [RankingEntry] {
        try await load(path: "rankings/\(format.cup)/overall/rankings-\(format.cp).json", as: [RankingEntry].self, policy: policy)
    }

    /// Wipe the persistent cache so the next load downloads everything fresh.
    func clearCache() async {
        await cache?.deleteAll()
    }

    // MARK: - Loading & caching

    private func load<T: Decodable>(path: String, as type: T.Type, policy: LoadPolicy = .cache) async throws -> T {
        if !hasSeeded {
            await seedBundledDataIfNeeded()
            hasSeeded = true
        }
        let cached = await cache?.entry(for: path)

        // 1. Fresh cache wins outright — no network (skipped when revalidating/reloading).
        if policy == .cache, let cached, Date().timeIntervalSince(cached.fetchedAt) < maxCacheAge,
           let value = try? decoder.decode(type, from: cached.data) {
            return value
        }

        // 2. Revalidate / fetch. A full reload omits the validator to force a 200.
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        if policy != .reload, let etag = cached?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw DataError.unavailable }

            // 304 Not Modified — upstream unchanged, keep cached blob.
            if http.statusCode == 304, let cached,
               let value = try? decoder.decode(type, from: cached.data) {
                await cache?.touch(path: path)
                return value
            }

            guard (200..<300).contains(http.statusCode) else { throw DataError.unavailable }
            let value = try decoder.decode(type, from: data)
            let etag = http.value(forHTTPHeaderField: "Etag")
            await cache?.save(path: path, data: data, etag: etag)
            return value
        } catch {
            // 3. Offline / failed — fall back to any stale cache.
            if let cached, let value = try? decoder.decode(type, from: cached.data) {
                return value
            }
            throw error
        }
    }

    /// Loads each bundled seed resource into the cache if it isn't already
    /// present, so a fresh install (or a cleared cache) works offline before
    /// any network call succeeds. Runs once per launch, lazily on first load.
    private func seedBundledDataIfNeeded() async {
        guard let cache else { return }
        for (path, resourceName) in Self.seedResources {
            guard let url = Bundle.main.url(forResource: resourceName, withExtension: "json"),
                  let data = try? Data(contentsOf: url) else { continue }
            await cache.seedIfMissing(path: path, data: data)
        }
    }
}
