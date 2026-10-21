//
//  ResultsFile.swift
//  PokeParty
//
//  The file format for saved Party Finder results and shared teams: a small
//  JSON envelope (`schemaVersion` + `kind` + payload) in a `.pokeparty` file.
//  The same file is both a run's record in the iCloud folder (see
//  `SyncedRunsStore`) and what `ShareLink` hands to Messages/AirDrop, so
//  anything that syncs between your devices can also be shared as-is.
//
//  Every payload is self-describing (species, moves, IVs, records) — nothing
//  in a file depends on the receiving device's rankings data, except an
//  optimizer run's `poolIndices`, which `TeamFinderModel` checks before
//  using them.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Declared in Info.plist (`UTExportedTypeDeclarations`).
    nonisolated static let pokePartyResults = UTType(exportedAs: "com.freebits.PokeParty.results")
}

nonisolated enum ResultsKind: String, Codable, Sendable {
    case tournament, optimizerRun, team
}

/// A team shared on its own (from a results row or the Team Builder's saved
/// teams). Plain data, so it doesn't lean on `Team`'s main-actor Codable
/// conformance.
nonisolated struct SharedTeam: Codable, Sendable {
    var name: String
    var members: [TeamMember]
    var cup: String
    var cp: Int
}

nonisolated struct ResultsEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    var schemaVersion: Int
    var kind: ResultsKind
    var exportedAt: Date
    var payload: Payload
}

/// Just the envelope's identifying fields, so a file can be checked (kind,
/// version) before its payload is decoded.
private nonisolated struct ResultsHeader: Decodable {
    var schemaVersion: Int
    var kind: ResultsKind
}

nonisolated enum ResultsFile {
    static let schemaVersion = 1
    static let fileExtension = "pokeparty"

    enum Imported: Sendable {
        case tournament(SavedTournament)
        case optimizerRun(SavedOptimizerRun)
        case team(SharedTeam)
    }

    enum ReadError: LocalizedError {
        case notAResultsFile
        case newerVersion

        var errorDescription: String? {
            switch self {
            case .notAResultsFile: "isn't a PokeParty results file (or was made by a newer version of the app)."
            case .newerVersion: "was made by a newer version of PokeParty — update the app to open it."
            }
        }
    }

    static func encode<Payload: Codable & Sendable>(_ payload: Payload, kind: ResultsKind) throws -> Data {
        try JSONEncoder().encode(ResultsEnvelope(
            schemaVersion: schemaVersion, kind: kind, exportedAt: .now, payload: payload))
    }

    /// Decodes any results file, whatever it holds.
    static func decode(_ data: Data) throws -> Imported {
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(ResultsHeader.self, from: data) else {
            throw ReadError.notAResultsFile
        }
        guard header.schemaVersion <= schemaVersion else { throw ReadError.newerVersion }
        switch header.kind {
        case .tournament:
            return .tournament(try decoder.decode(ResultsEnvelope<SavedTournament>.self, from: data).payload)
        case .optimizerRun:
            return .optimizerRun(try decoder.decode(ResultsEnvelope<SavedOptimizerRun>.self, from: data).payload)
        case .team:
            return .team(try decoder.decode(ResultsEnvelope<SharedTeam>.self, from: data).payload)
        }
    }

    /// Decodes a file that must hold a `Run` — nil for anything else
    /// (another kind, a newer schema, or a damaged file).
    static func decode<Run: SyncedRun>(_ type: Run.Type, from data: Data) -> Run? {
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(ResultsHeader.self, from: data),
              header.kind == Run.kind, header.schemaVersion <= schemaVersion
        else { return nil }
        return try? decoder.decode(ResultsEnvelope<Run>.self, from: data).payload
    }

    /// A filesystem-safe `.pokeparty` filename for a human-readable title.
    static func filename(for title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?*\"<>|").union(.controlCharacters)
        let cleaned = title.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return (cleaned.isEmpty ? "PokeParty" : cleaned) + "." + fileExtension
    }
}

// MARK: - Sharing

/// What `ShareLink` exports: a `.pokeparty` file, encoded only when the
/// share actually happens (a tournament can be several MB).
nonisolated struct ResultsShareItem: Transferable {
    let title: String
    let filename: String
    let makeData: @Sendable () throws -> Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .pokePartyResults) { item in
            // A fresh folder per export so two shares of the same title can't collide.
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(item.filename)
            try item.makeData().write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }

    private init(title: String, filename: String, makeData: @escaping @Sendable () throws -> Data) {
        self.title = title
        self.filename = filename
        self.makeData = makeData
    }

    /// A saved tournament or optimizer run.
    init<Run: SyncedRun>(run: Run) {
        let title = "\(run.shareTitle) — \(run.date.formatted(date: .abbreviated, time: .omitted))"
        self.init(title: title, filename: ResultsFile.filename(for: title),
                  makeData: { try ResultsFile.encode(run, kind: Run.kind) })
    }

    /// One team, for the given format.
    init(teamNamed name: String, members: [TeamMember], cup: String, cp: Int) {
        let shared = SharedTeam(name: name, members: members, cup: cup, cp: cp)
        self.init(title: name, filename: ResultsFile.filename(for: name),
                  makeData: { try ResultsFile.encode(shared, kind: .team) })
    }
}

// MARK: - Importing

/// UI state for importing: the root view owns the file importer and the
/// result alert, and any view can ask for the importer by setting
/// `isImporterPresented`.
@MainActor
@Observable
final class ShareImportModel {
    var isImporterPresented = false
    var message: String?
}

@MainActor
enum ResultsImporter {
    /// Imports one `.pokeparty` file into the matching store and returns a
    /// message for the user describing what happened.
    static func importFile(
        at url: URL,
        tournaments: SavedTournamentsStore,
        optimizerRuns: SavedOptimizerRunsStore,
        savedTeams: SavedTeamsStore
    ) async -> String {
        let name = url.lastPathComponent
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let imported: ResultsFile.Imported
        do {
            // Files open in place (Info.plist), so this can be the original
            // in iCloud Drive or another app's folder: read it coordinated.
            imported = try await Task.detached(priority: .userInitiated) {
                guard let data = RunFiles.coordinatedData(at: url) else { throw ResultsFile.ReadError.notAResultsFile }
                return try ResultsFile.decode(data)
            }.value
        } catch let error as ResultsFile.ReadError {
            return "“\(name)” \(error.localizedDescription)"
        } catch {
            return "Couldn’t read “\(name)”: \(error.localizedDescription)"
        }

        switch imported {
        case .tournament(var run):
            // Same id = a file that came from this account's own iCloud folder.
            guard !tournaments.contains(id: run.id) else { return "“\(run.formatTitle)” tournament is already saved." }
            run.importedAt = .now
            tournaments.save(run)
            return "Imported the \(run.formatTitle) tournament. Find it under Saved tournaments in the Party Finder."
        case .optimizerRun(var run):
            guard !optimizerRuns.contains(id: run.id) else { return "“\(run.formatTitle)” AI Optimizer run is already saved." }
            run.importedAt = .now
            optimizerRuns.save(run)
            return "Imported the \(run.formatTitle) AI Optimizer run. Find it under Saved AI Optimizer runs in the Party Finder."
        case .team(let shared):
            // Don't overwrite one of your own teams that happens to share the name.
            let taken = savedTeams.teams.contains {
                $0.name == shared.name && $0.cup == shared.cup && $0.cp == shared.cp
            }
            let teamName = taken ? "\(shared.name) (shared)" : shared.name
            savedTeams.save(name: teamName, members: shared.members, cup: shared.cup, cp: shared.cp)
            return "Imported the team “\(teamName)”. Find it under Teams in the Team Builder."
        }
    }
}
