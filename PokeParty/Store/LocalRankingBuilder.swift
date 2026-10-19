//
//  LocalRankingBuilder.swift
//  PokeParty
//
//  Owns the locally-computed rankings (Engine/Meta/Ranker) as a per-format
//  disk cache, tagged with a hash of the gamemaster data they were computed
//  from. Keeps the 3 core leagues warm in the background automatically —
//  regardless of which ordering mode the user has selected in Settings —
//  so switching to "PokeParty (Local)" ordering is instant once ready.
//  Cups are built lazily, the first time they're viewed in Local mode.
//

import Foundation
import CryptoKit
import SwiftUI

/// One format's cached local ranking, tagged with the gamemaster hash it was
/// computed from — a mismatch means the underlying data moved on and this
/// entry is stale.
struct LocalRankingCacheEntry: Codable {
    let formatId: String
    let gameMasterHash: String
    let computedAt: Date
    let entries: [RankingEntry]
}

@MainActor
@Observable
final class LocalRankingBuilder {

    enum Phase: Equatable {
        case idle
        case building(formatTitle: String)
        case done
        case failed(String)

        var isFailed: Bool { if case .failed = self { true } else { false } }
    }

    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0
    var isRunning: Bool { if case .building = phase { true } else { false } }

    /// Called whenever a background run finishes (successfully, on failure,
    /// or having skipped a request because one was already in flight) —
    /// lets `RankingsStore` re-check whether the format it's currently
    /// displaying just became available (or is still stale and needs to be
    /// re-queued, since a `buildIfStale` call made while `isRunning` was
    /// true is silently dropped rather than queued).
    var onIdle: (() -> Void)?

    /// Inputs the Ranker needs — bundled up so callers don't have to thread
    /// four separate params through every entry point.
    struct GameMasterContext: Sendable {
        let hash: String
        /// Every released Pokémon, including shadow and mega entries —
        /// `MetaPool`'s own cup filters (not this roster) decide whether a
        /// given cup allows megas/shadows.
        let allPokemon: [Pokemon]
        let greatLeagueIneligible: [String]
        let cups: [Cup]
        let movesById: [String: Move]
    }

    private var cache: [String: LocalRankingCacheEntry] = [:]
    private var runTask: Task<Void, Never>?
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        // Decoding the cached rankings is tens of ms of JSON — kept off the
        // main thread. Anything that reads `cache` awaits `ensureLoaded()`.
        Task { await ensureLoaded() }
    }

    /// Where the per-format cache files live (for the DEBUG "reveal" action).
    var cacheDirectory: URL { directory }

    private var isLoaded = false
    private var loadTask: Task<Void, Never>?

    /// Loads the disk cache (and bundled seeds) once, off the main actor.
    func ensureLoaded() async {
        if isLoaded { return }
        if loadTask == nil {
            let directory = directory
            loadTask = Task {
                let loaded = await Task.detached(priority: .utility) {
                    Self.readCacheFromDisk(directory: directory)
                }.value
                for entry in loaded { cache[entry.formatId] = entry }
                let seeds = await Task.detached(priority: .utility) { [existing = Set(cache.keys)] in
                    Self.readBundledSeeds(excluding: existing)
                }.value
                for entry in seeds where cache[entry.formatId] == nil { cache[entry.formatId] = entry }
                isLoaded = true
            }
        }
        await loadTask?.value
    }

    // MARK: - Reads

    /// The cached entries for `formatId`, only if they match `gameMasterHash`
    /// (i.e. not stale) — callers should fall back to PvPoke's rankings when
    /// this returns `nil`, never block on a rebuild.
    func cachedEntries(formatId: String, gameMasterHash: String) -> [RankingEntry]? {
        guard let cached = cache[formatId], cached.gameMasterHash == gameMasterHash else { return nil }
        return cached.entries
    }

    func isStale(formatId: String, gameMasterHash: String) -> Bool {
        cache[formatId]?.gameMasterHash != gameMasterHash
    }

    static func hash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Background rebuild

    /// Drops every cached local ranking (memory and disk) so the next
    /// `rebuildCoreLeaguesIfStale`/`buildIfStale` recomputes from scratch.
    func clearCache() async {
        cancel()
        await ensureLoaded()
        cache.removeAll()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" { try? FileManager.default.removeItem(at: file) }
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        if isRunning { phase = .idle }
    }

    /// Rebuilds any of the 3 core leagues that are stale, one at a time, in
    /// the background. Safe to call every launch — a no-op once caches are
    /// current for this gamemaster version.
    func rebuildCoreLeaguesIfStale(context: GameMasterContext) {
        guard !isRunning else { return }

        runTask?.cancel()
        runTask = Task {
            await ensureLoaded()
            let staleFormats = RankingFormat.coreLeagues.filter { isStale(formatId: $0.id, gameMasterHash: context.hash) }
            for format in staleFormats {
                if Task.isCancelled { return }
                await build(format: format, context: context)
            }
            if !Task.isCancelled, !phase.isFailed { phase = .done }
            onIdle?()
        }
    }

    /// Builds (or rebuilds) one format on demand — used for cups, which
    /// aren't part of the automatic core-league sweep above. If a build is
    /// already running, this is a no-op now, but `onIdle` fires when that
    /// run finishes so the caller gets a chance to re-request it.
    func buildIfStale(format: RankingFormat, context: GameMasterContext) {
        guard !isRunning else { return }
        runTask?.cancel()
        runTask = Task {
            await ensureLoaded()
            if isStale(formatId: format.id, gameMasterHash: context.hash) {
                await build(format: format, context: context)
            }
            if !Task.isCancelled, !phase.isFailed { phase = .done }
            onIdle?()
        }
    }

    private func build(format: RankingFormat, context: GameMasterContext) async {
        phase = .building(formatTitle: format.title)
        progress = 0

        guard let cup = context.cups.first(where: { $0.name == format.cup }) else {
            phase = .failed("No cup data for \(format.title)")
            return
        }

        // `build` is a method of this @MainActor class, so without an
        // explicit hop off of it, `await`-ing a nonisolated async call
        // (Ranker.rank) does NOT itself move execution to a background
        // thread — it only actually leaves the main actor at the points
        // Ranker's own task groups create child tasks. Everything else
        // (MetaPool's eligibility filter, and anything Ranker does before/
        // between its task groups) would otherwise run inline on the main
        // thread, which is what was beachballing the app. `Task.detached`
        // guarantees the whole pool-build + rank computation runs off-main;
        // only the `onProgress` hop back to `self.progress` below re-enters
        // the main actor, cheaply.
        let cpCap = format.cp
        let allPokemon = context.allPokemon
        let greatLeagueIneligible = context.greatLeagueIneligible
        let movesById = context.movesById

        // `.utility` keeps this background build from competing with the UI
        // (and the rest of the system) for CPU; `Ranker` also caps its own
        // parallelism at half the cores via `BoundedParallel`.
        let result = await Task.detached(priority: .utility) { () -> [RankingEntry] in
            let pool = MetaPool.eligiblePokemon(
                for: cup, cpCap: cpCap, allPokemon: allPokemon,
                greatLeagueIneligible: greatLeagueIneligible)
            return await Ranker.rank(pool: pool, cpCap: cpCap, movesById: movesById) { fraction in
                Task { @MainActor in self.progress = fraction }
            }
        }.value
        if Task.isCancelled { return }

        let entry = LocalRankingCacheEntry(
            formatId: format.id, gameMasterHash: context.hash, computedAt: .now, entries: result)
        cache[format.id] = entry
        persist(entry)
    }

    // MARK: - Disk

    private static var defaultDirectory: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("PokeParty", isDirectory: true)
            .appendingPathComponent("LocalRankings", isDirectory: true)
    }

    private func fileURL(formatId: String) -> URL {
        // formatId is "\(cup)-\(cp)" — already filename-safe.
        directory.appendingPathComponent("\(formatId).json")
    }

    private nonisolated static func readCacheFromDisk(directory: URL) -> [LocalRankingCacheEntry] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? JSONDecoder().decode(LocalRankingCacheEntry.self, from: data)
        }
    }

    private func persist(_ entry: LocalRankingCacheEntry) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: fileURL(formatId: entry.formatId), options: .atomic)
    }

    /// Seeds the 3 core leagues from bundled snapshots (if present) so a
    /// fresh install has *some* local ranking immediately rather than a
    /// "computing…" spinner on first launch — mirrors
    /// `DataService.seedBundledDataIfNeeded`. Never overwrites a real disk
    /// cache entry. There's nothing to seed until a maintainer copies the
    /// built cache files into `Resources/` as `seed_local_ranking_*.json`
    /// (see docs/RELEASE_CHECKLIST.md) — until then this is a no-op and the
    /// background builder computes from scratch on first launch. A seed only
    /// helps while its gamemaster hash matches the data in use.
    private nonisolated static func readBundledSeeds(excluding existing: Set<String>) -> [LocalRankingCacheEntry] {
        [1500, 2500, 10000].compactMap { cp in
            guard !existing.contains("all-\(cp)"),
                  let url = Bundle.main.url(forResource: "seed_local_ranking_\(cp)", withExtension: "json"),
                  let data = try? Data(contentsOf: url)
            else { return nil }
            return try? JSONDecoder().decode(LocalRankingCacheEntry.self, from: data)
        }
    }
}
