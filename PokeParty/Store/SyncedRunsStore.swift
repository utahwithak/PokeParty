//
//  SyncedRunsStore.swift
//  PokeParty
//
//  Persists completed Party Finder runs (tournaments, AI Optimizer runs) as
//  one `<uuid>.pokeparty` file each — the format in `ResultsFile` — in the
//  app's iCloud container, so a run computed on a Mac shows up on a phone.
//  One immutable file per run means two devices can never conflict: a save
//  only ever adds a file, a replace or delete only removes one.
//
//  Falls back to a folder in Application Support when iCloud is unavailable
//  (signed out, or iCloud Drive off for the app); local files are moved into
//  the container once it becomes available. The pre-sync single-array JSON
//  files are migrated on first launch.
//
//  Runs are deduplicated by configuration (see `SyncedRun.sameConfiguration`):
//  re-running the same setup replaces the older result, including when the
//  two results came from different devices.
//

import Foundation
import Observation

/// A saved run that can live in a `SyncedRunsStore`.
nonisolated protocol SyncedRun: Identifiable, Codable, Sendable where ID == UUID {
    static var kind: ResultsKind { get }
    /// Subfolder of the iCloud/local results directory.
    static var folderName: String { get }
    /// The single-array JSON file this run type was stored in before
    /// per-run files (Application Support), migrated on first launch.
    static var legacyFilename: String { get }

    var date: Date { get }
    /// Set when the run came from somebody else's shared file. Imported runs
    /// are deduplicated only against other imports, so a friend's results
    /// never replace one of your own.
    var importedAt: Date? { get }
    var shareTitle: String { get }

    /// True when `other` was run with the same configuration (and so should
    /// replace this run rather than sit beside it).
    func sameConfiguration(as other: Self) -> Bool
}

/// Where a store reads and writes: the iCloud folder when available.
nonisolated struct RunFolder: Sendable {
    let url: URL
    let isICloud: Bool
}

@MainActor
@Observable
final class SyncedRunsStore<Run: SyncedRun> {

    /// Newest first.
    private(set) var runs: [Run] = []
    /// True once the store is using the iCloud container rather than a
    /// local-only folder.
    private(set) var isUsingICloud = false

    @ObservationIgnored private let folderTask: Task<RunFolder, Never>
    /// File operations run one after another so a save followed by a delete
    /// of the same run can't land out of order.
    @ObservationIgnored private var ioChain: Task<Void, Never> = Task {}
    /// The resolved folder, once `folderTask` has finished.
    @ObservationIgnored private var directory: URL?
    @ObservationIgnored private var query: NSMetadataQuery?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    /// Ids seen in the last iCloud query — a known id that disappears from
    /// the results was deleted on another device.
    @ObservationIgnored private var knownRemoteIDs: Set<UUID> = []
    /// Ids this device removed whose files may still show up in the iCloud
    /// results for a moment; they must not be reloaded.
    @ObservationIgnored private var tombstones: Set<UUID> = []
    @ObservationIgnored private var loadingIDs: Set<UUID> = []
    @ObservationIgnored private var unreadableIDs: Set<UUID> = []

    /// - Parameter directory: a fixed folder (used by tests) instead of the
    ///   iCloud/Application Support location; skips legacy migration.
    init(directory: URL? = nil) {
        let legacyFile = directory == nil ? JSONFileStore.defaultFileURL(filename: Run.legacyFilename) : nil
        folderTask = Task.detached(priority: .utility) {
            Self.prepareFolder(explicitDirectory: directory, legacyFile: legacyFile)
        }
        Task { await start() }
    }

    // MARK: - Public

    func contains(id: UUID) -> Bool {
        runs.contains { $0.id == id }
    }

    /// Saves a run, replacing any earlier run of the same configuration.
    func save(_ run: Run) {
        let replaced = runs.filter { $0.id != run.id && Self.supersedes(run, $0) }
        runs.removeAll { $0.id == run.id || Self.supersedes(run, $0) }
        runs.append(run)
        runs.sort { $0.date > $1.date }

        tombstones.remove(run.id)
        tombstones.formUnion(replaced.map(\.id))
        let replacedIDs = replaced.map(\.id)
        enqueue { directory in
            RunFiles.write(run, to: directory)
            for id in replacedIDs { RunFiles.remove(id: id, in: directory) }
        }
    }

    func delete(_ run: Run) {
        runs.removeAll { $0.id == run.id }
        tombstones.insert(run.id)
        let id = run.id
        enqueue { directory in RunFiles.remove(id: id, in: directory) }
    }

    // MARK: - Loading

    private func start() async {
        let folder = await folderTask.value
        isUsingICloud = folder.isICloud
        let directory = folder.url
        self.directory = directory
        // Files already on this device show up immediately, offline.
        let local: [Run] = await Task.detached(priority: .utility) {
            RunFiles.readAll(Run.self, in: directory)
        }.value
        knownRemoteIDs.formUnion(local.map(\.id))
        merge(local)
        if folder.isICloud { startQuery() }
    }

    nonisolated private static func prepareFolder(explicitDirectory: URL?, legacyFile: URL?) -> RunFolder {
        if let explicitDirectory {
            try? FileManager.default.createDirectory(at: explicitDirectory, withIntermediateDirectories: true)
            return RunFolder(url: explicitDirectory, isICloud: false)
        }
        let local = RunFiles.localDirectory(folderName: Run.folderName)
        if let legacyFile { RunFiles.migrateLegacy(Run.self, from: legacyFile, into: local) }
        guard let cloud = RunFiles.ubiquityDirectory(folderName: Run.folderName) else {
            return RunFolder(url: local, isICloud: false)
        }
        RunFiles.moveFiles(from: local, to: cloud)
        return RunFolder(url: cloud, isICloud: true)
    }

    /// Watches the iCloud container so runs saved on another device appear
    /// (and runs deleted there disappear) while the app is open.
    private func startQuery() {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(
            format: "%K LIKE %@", NSMetadataItemFSNameKey, "*.\(ResultsFile.fileExtension)")
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: query, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.queryDidChange() }
            })
        }
        self.query = query
        query.start()
    }

    private func queryDidChange() {
        guard let query else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }

        var present: Set<UUID> = []
        var readable: [UUID: URL] = [:]
        for case let item as NSMetadataItem in query.results {
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
                  url.deletingLastPathComponent().lastPathComponent == Run.folderName,
                  let id = RunFiles.id(of: url) else { continue }
            present.insert(id)
            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            if status == NSMetadataUbiquitousItemDownloadingStatusCurrent
                || status == NSMetadataUbiquitousItemDownloadingStatusDownloaded {
                readable[id] = url
            } else {
                // Not on this device yet; the query reports it again once downloaded.
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            }
        }

        // Deleted on another device. The file-exists check guards against the
        // query briefly reporting nothing while iCloud is still gathering.
        tombstones.formIntersection(present)
        let gone = knownRemoteIDs.subtracting(present)
        if !gone.isEmpty {
            runs.removeAll { run in
                gone.contains(run.id) && !hasLocalFile(for: run.id)
            }
        }
        knownRemoteIDs = present

        let loaded = Set(runs.map(\.id))
        let fresh = readable.filter {
            !loaded.contains($0.key) && !tombstones.contains($0.key)
                && !loadingIDs.contains($0.key) && !unreadableIDs.contains($0.key)
        }
        guard !fresh.isEmpty else { return }
        loadingIDs.formUnion(fresh.keys)
        let urls = Array(fresh.values)
        let ids = Set(fresh.keys)
        Task {
            let loadedRuns: [Run] = await Task.detached(priority: .utility) {
                urls.compactMap { RunFiles.read(Run.self, at: $0) }
            }.value
            loadingIDs.subtract(ids)
            unreadableIDs.formUnion(ids.subtracting(loadedRuns.map(\.id)))
            merge(loadedRuns)
        }
    }

    private func hasLocalFile(for id: UUID) -> Bool {
        guard let directory else { return false }
        return FileManager.default.fileExists(atPath: RunFiles.fileURL(for: id, in: directory).path)
    }

    // MARK: - Merging

    /// True when `new` should replace `old`: same configuration and the same
    /// provenance (yours vs. imported).
    private static func supersedes(_ new: Run, _ old: Run) -> Bool {
        new.sameConfiguration(as: old) && (new.importedAt == nil) == (old.importedAt == nil)
    }

    private func merge(_ incoming: [Run]) {
        let existing = Set(runs.map(\.id))
        runs += incoming.filter { !existing.contains($0.id) && !tombstones.contains($0.id) }
        runs.sort { $0.date > $1.date }
        dropSupersededRuns()
    }

    /// Two devices that ran the same configuration each wrote a file; keep
    /// the newest and delete the rest, as a same-device re-run would have.
    private func dropSupersededRuns() {
        var kept: [Run] = []
        var superseded: [UUID] = []
        for run in runs {
            if kept.contains(where: { Self.supersedes($0, run) }) {
                superseded.append(run.id)
            } else {
                kept.append(run)
            }
        }
        guard !superseded.isEmpty else { return }
        runs = kept
        tombstones.formUnion(superseded)
        let supersededIDs = superseded
        enqueue { directory in
            for id in supersededIDs { RunFiles.remove(id: id, in: directory) }
        }
    }

    // MARK: - Disk

    private func enqueue(_ work: @escaping @Sendable (URL) -> Void) {
        let folderTask = folderTask
        let previous = ioChain
        ioChain = Task.detached(priority: .utility) {
            await previous.value
            work(await folderTask.value.url)
        }
    }
}

/// Synchronous file helpers for `SyncedRunsStore`; call off the main thread.
/// Reads and writes go through `NSFileCoordinator`, as required for files
/// in an iCloud container.
nonisolated enum RunFiles {

    static func localDirectory(folderName: String) -> URL {
        let directory = JSONFileStore.defaultFileURL(filename: folderName)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// `Documents/<folderName>` in the app's iCloud container, or nil when
    /// iCloud isn't available. Blocks, so never call from the main thread.
    static func ubiquityDirectory(folderName: String) -> URL? {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return nil }
        let directory = container
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return directory
    }

    static func fileURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension(ResultsFile.fileExtension)
    }

    /// The run id a file is named for; nil for anything that isn't a results
    /// file (including iCloud's `.icloud` placeholders).
    static func id(of url: URL) -> UUID? {
        guard url.pathExtension == ResultsFile.fileExtension else { return nil }
        return UUID(uuidString: url.deletingPathExtension().lastPathComponent)
    }

    static func write<Run: SyncedRun>(_ run: Run, to directory: URL) {
        guard let data = try? ResultsFile.encode(run, kind: Run.kind) else { return }
        let url = fileURL(for: run.id, in: directory)
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            try? data.write(to: target, options: .atomic)
        }
    }

    static func remove(id: UUID, in directory: URL) {
        let url = fileURL(for: id, in: directory)
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { target in
            try? FileManager.default.removeItem(at: target)
        }
    }

    /// The file's contents, read through file coordination (which also
    /// downloads an iCloud file that isn't on this device yet).
    static func coordinatedData(at url: URL) -> Data? {
        var data: Data?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { source in
            data = try? Data(contentsOf: source)
        }
        return data
    }

    static func read<Run: SyncedRun>(_ type: Run.Type, at url: URL) -> Run? {
        coordinatedData(at: url).flatMap { ResultsFile.decode(type, from: $0) }
    }

    static func readAll<Run: SyncedRun>(_ type: Run.Type, in directory: URL) -> [Run] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { id(of: $0) != nil }.compactMap { read(type, at: $0) }
    }

    /// Converts the old single-array JSON file into one file per run. The
    /// old file is kept alongside as `.migrated` in case anything went wrong.
    static func migrateLegacy<Run: SyncedRun>(_ type: Run.Type, from legacyFile: URL, into directory: URL) {
        guard FileManager.default.fileExists(atPath: legacyFile.path) else { return }
        let runs: [Run] = JSONFileStore.load(from: legacyFile)
        for run in runs where !FileManager.default.fileExists(atPath: fileURL(for: run.id, in: directory).path) {
            write(run, to: directory)
        }
        let backup = legacyFile.appendingPathExtension("migrated")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: legacyFile, to: backup)
    }

    /// Moves results files saved locally (while iCloud was unavailable) into
    /// the iCloud folder.
    static func moveFiles(from local: URL, to cloud: URL) {
        let urls = (try? FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil)) ?? []
        for source in urls where id(of: source) != nil {
            let destination = cloud.appendingPathComponent(source.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: source)
            } else {
                try? FileManager.default.setUbiquitous(true, itemAt: source, destinationURL: destination)
            }
        }
    }
}
