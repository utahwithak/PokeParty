//
//  TeamFinderSavedRows.swift
//  PokeParty
//
//  Rows for saved tournaments and optimizer runs.
//

import SwiftUI

/// One saved run: configuration summary + when it was fought.
struct SavedTournamentRow: View {
    let run: SavedTournament
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.formatTitle)
                        .font(.subheadline.weight(.medium))
                    Text("\(TeamFinderModel.poolDescription(run.poolSize).capitalized) pool · \(run.fieldSize)-team field · \(run.date.formatted(date: .abbreviated, time: .shortened))\(run.importedAt == nil ? "" : " · shared")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            Spacer()

            ShareLink(item: ResultsShareItem(run: run), preview: SharePreview(run.shareTitle)) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .help("Share this tournament")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this saved tournament")
        }
    }
}

/// One saved AI Optimizer run: configuration summary + when it climbed.
struct SavedOptimizerRunRow: View {
    let run: SavedOptimizerRun
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.formatTitle)
                        .font(.subheadline.weight(.medium))
                    Text("\(TeamFinderModel.poolDescription(run.poolSize).capitalized) pool · \(run.restarts) restarts · \(run.date.formatted(date: .abbreviated, time: .shortened))\(run.importedAt == nil ? "" : " · shared")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            Spacer()

            ShareLink(item: ResultsShareItem(run: run), preview: SharePreview(run.shareTitle)) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .help("Share this run")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this saved run")
        }
    }
}
