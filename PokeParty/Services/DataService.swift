//
//  DataService.swift
//  PokeParty
//
//  Fetches PvPoke's static JSON data, backed by a persistent SwiftData cache.
//

import Foundation
import SwiftData

/// Loads Pokémon, move and ranking data from PvPoke's data files.
///
/// Sourced from PvPoke's own GitHub repo (`raw.githubusercontent.com`) rather
/// than the live `pvpoke.com` site — same schema (the repo is what the site
/// deploys from), but backed by GitHub's CDN instead of a single web server,
/// and pinned to a ref we control instead of "whatever's live right now."
///
/// PvPoke's data changes only every few months, so blobs are persisted via
/// `ResourceCache` (SwiftData, in Application Support). Any decodable cached
/// or seeded blob — fresh or stale — is returned immediately; a stale one
/// also kicks off a background revalidation via HTTP ETag (a 304 just
/// refreshes the timestamp) so next launch is current. This means a slow or
/// stalled connection (common on cellular) can never leave the UI hanging on
/// a spinner as long as *any* cached/seeded copy exists — only a genuinely
/// first-ever load with no seed data blocks on the network.
actor DataService {
    static let shared = DataService()

    /// The combined Pokémon + move data file.
    struct GameMaster: Decodable {
        let pokemon: [Pokemon]
        let moves: [Move]
        /// Currently active formats/cups (e.g. Summer Cup).
        let formats: [RankingFormat]?
        /// Every cup's eligibility rules (include/exclude filters) — the
        /// local `MetaPool` eligibility filter, not just the active formats.
        let cups: [Cup]?
        /// Species banned from Great/Ultra League regardless of cup filters.
        let greatLeagueIneligible: [String]?

        private enum CodingKeys: String, CodingKey {
            case pokemon, moves, formats, cups, greatLeagueIneligible
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let decoded = try c.decode([Pokemon].self, forKey: .pokemon)
            // Link form-changing species (Minior) to their other form's stats.
            let byId = Dictionary(decoded.map { ($0.speciesId, $0) }, uniquingKeysWith: { first, _ in first })
            pokemon = decoded.map { $0.formChange == nil ? $0 : $0.resolvingFormShift(pokemonById: byId) }
            moves = try c.decode([Move].self, forKey: .moves)
            formats = try c.decodeIfPresent([RankingFormat].self, forKey: .formats)
            cups = try c.decodeIfPresent([Cup].self, forKey: .cups)
            greatLeagueIneligible = try c.decodeIfPresent([String].self, forKey: .greatLeagueIneligible)
        }
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

    private let baseURL = URL(string: "https://raw.githubusercontent.com/pvpoke/pvpoke/master/src/data/")!
    private let maxCacheAge: TimeInterval = 60 * 60 * 24 * 7 // 7 days
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let cache: ResourceCache?
    private var hasSeeded = false

    /// Emits a resource path whenever a background revalidation downloads
    /// data that differs from what was already cached/shown, so the UI can
    /// reload it instead of waiting for the next launch.
    nonisolated let updates: AsyncStream<String>
    private let updatesContinuation: AsyncStream<String>.Continuation

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
        (updates, updatesContinuation) = AsyncStream.makeStream(of: String.self)
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)

        // This is a local blob cache only — never sync it via CloudKit.
        // Without an explicit `.none`, SwiftData's automatic container
        // discovery can key off the app's other iCloud entitlements (used by
        // SavedTeamsStore/BenchStore's NSUbiquitousKeyValueStore sync) and
        // attempt CloudKit setup for this store too, which can hang
        // indefinitely waiting on account resolution when no iCloud account
        // is signed in (a fresh simulator, or a signed-out device) — the
        // actual cause of rankings never loading on a cold iOS install.
        let modelConfig = ModelConfiguration(cloudKitDatabase: .none)
        // Persistent store in Application Support; nil disables caching gracefully.
        if let container = try? ModelContainer(for: CachedResource.self, configurations: modelConfig) {
            cache = ResourceCache(modelContainer: container)
        } else {
            cache = nil
        }
    }

    // MARK: - Public API

    func gameMaster(policy: LoadPolicy = .cache) async throws -> GameMaster {
        try await load(path: "gamemaster.json", as: GameMaster.self, policy: policy).value
    }

    /// Same as `gameMaster(policy:)`, plus the raw bytes it was decoded
    /// from — used to derive `LocalRankingBuilder`'s staleness hash, which
    /// needs to be a stable function of the underlying data, not of
    /// whichever `Codable` fields this app happens to read from it today.
    func gameMasterWithRawData(policy: LoadPolicy = .cache) async throws -> (gameMaster: GameMaster, data: Data) {
        let (value, data) = try await load(path: "gamemaster.json", as: GameMaster.self, policy: policy)
        return (value, data)
    }

    func rankings(for format: RankingFormat, policy: LoadPolicy = .cache) async throws -> [RankingEntry] {
        try await load(path: format.rankingsPath, as: [RankingEntry].self, policy: policy).value
    }

    /// Wipe the persistent cache so the next load downloads everything fresh.
    func clearCache() async {
        await cache?.deleteAll()
        // Re-seed on the next load so a failed re-download still has the
        // bundled snapshot to fall back on instead of nothing.
        hasSeeded = false
    }

    // MARK: - Loading & caching

    private func load<T: Decodable>(path: String, as type: T.Type, policy: LoadPolicy = .cache) async throws -> (value: T, data: Data) {
        if !hasSeeded {
            await seedBundledDataIfNeeded()
            hasSeeded = true
        }
        let cached = await cache?.entry(for: path)

        // 1. Any usable cache/seed wins outright, regardless of freshness —
        // the UI must never block on the network when there's already
        // something to show. A stale copy also kicks off a background
        // revalidation so the cache is current by the next load.
        if policy == .cache, let cached, let value = try? decoder.decode(type, from: cached.data) {
            if Date().timeIntervalSince(cached.fetchedAt) >= maxCacheAge {
                revalidateInBackground(path: path, as: type, cached: cached)
            }
            return (value, cached.data)
        }

        // 2. No usable cache yet (first-ever load with no seed data, or an
        // explicit revalidate/reload) — the caller is waiting, so fetch now.
        return try await fetch(path: path, as: type, policy: policy, cached: cached)
    }

    /// Refreshes `path` without blocking the caller, who already has
    /// `cached` on screen. Errors are swallowed — a failed background
    /// revalidation just means the next load tries again.
    private func revalidateInBackground<T: Decodable>(path: String, as type: T.Type, cached: CachedEntry) {
        Task {
            guard let result = try? await fetch(path: path, as: type, policy: .revalidate, cached: cached),
                  result.data != cached.data else { return }
            updatesContinuation.yield(path)
        }
    }

    /// The actual network round trip (ETag-conditional GET), falling back to
    /// any stale cache on failure so the app still works offline.
    private func fetch<T: Decodable>(
        path: String, as type: T.Type, policy: LoadPolicy, cached: CachedEntry?
    ) async throws -> (value: T, data: Data) {
        // A full reload omits the validator to force a 200.
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
                return (value, cached.data)
            }

            guard (200..<300).contains(http.statusCode) else { throw DataError.unavailable }
            let value = try decoder.decode(type, from: data)
            let etag = http.value(forHTTPHeaderField: "Etag")
            await cache?.save(path: path, data: data, etag: etag)
            return (value, data)
        } catch {
            // Offline / failed — fall back to any stale cache.
            if let cached, let value = try? decoder.decode(type, from: cached.data) {
                return (value, cached.data)
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
