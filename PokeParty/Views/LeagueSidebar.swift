//
//  LeagueSidebar.swift
//  PokeParty
//
//  The macOS sidebar: tools, core leagues, and any active limited cups.
//

import SwiftUI

/// What the sidebar can select: a rankings format, or a tool.
enum SidebarSelection: Hashable {
    case format(RankingFormat)
    case rankChecker
    case teamBuilder
    case partyFinder
    case matchup
    case breakpoints
    case bench
    #if os(macOS)
    /// Live capture + IV grid scanning tool — unavailable on iOS since it
    /// captures the iPhone Mirroring window via ScreenCaptureKit.
    case scan
    #endif

    /// Stable string key for persisting the selected tab across launches.
    /// A cup format's `RankingFormat` isn't itself storable (it's decoded
    /// fresh from the gamemaster each launch), so formats persist by their
    /// `id` and are re-resolved against the loaded cup list on restore.
    var persistenceKey: String {
        switch self {
        case .format(let format): return "format:\(format.id)"
        case .rankChecker: return "rankChecker"
        case .teamBuilder: return "teamBuilder"
        case .partyFinder: return "partyFinder"
        case .matchup: return "matchup"
        case .breakpoints: return "breakpoints"
        case .bench: return "bench"
        #if os(macOS)
        case .scan: return "scan"
        #endif
        }
    }

    /// Reconstructs a selection from a persisted `persistenceKey`. `cupFormats`
    /// should be the store's currently loaded cups — needed to resolve a
    /// saved cup selection; core leagues resolve without it. Returns `nil`
    /// if the key is unrecognized or names a cup that's no longer active.
    static func restored(from key: String, cupFormats: [RankingFormat]) -> SidebarSelection? {
        if let id = key.dropFirstIfPresent("format:") {
            return (RankingFormat.coreLeagues + cupFormats).first { $0.id == id }.map { .format($0) }
        }
        switch key {
        case "rankChecker": return .rankChecker
        case "teamBuilder": return .teamBuilder
        case "partyFinder": return .partyFinder
        case "matchup": return .matchup
        // "breakpoints" intentionally unresolved: the tab is pulled from
        // this release's sidebar, so a persisted selection from before the
        // update shouldn't restore to a now-unreachable screen.
        case "bench": return .bench
        #if os(macOS)
        case "scan": return .scan
        #endif
        default: return nil
        }
    }
}

private extension String {
    /// Returns everything after `prefix` if present, else `nil`.
    func dropFirstIfPresent(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}

/// Sidebar listing tools, the core PvP leagues, and active cups (e.g. Summer Cup).
struct LeagueSidebar: View {
    var store: RankingsStore
    var hiddenCups: HiddenCupsStore
    @Binding var selection: SidebarSelection?
    @State private var showingSettings = false

    private var visibleCupFormats: [RankingFormat] {
        store.cupFormats.filter { !hiddenCups.isHidden($0.id) }
    }

    var body: some View {
        // On macOS: prevent deselection so something is always highlighted.
        // On iOS: allow nil so going back clears the selection, enabling
        // re-navigation to the same item without requiring a different tap.
        List(selection: Binding(
            get: { selection },
            set: {
                #if os(macOS)
                if let new = $0 { selection = new }
                #else
                selection = $0
                #endif
            }
        )) {
            Section("Tools") {
                Label("My Bench", systemImage: "tray.fill")
                    .tag(SidebarSelection.bench)
                Label("Rank Checker", systemImage: "checklist")
                    .tag(SidebarSelection.rankChecker)
                Label("Team Builder", systemImage: "person.3.sequence.fill")
                    .tag(SidebarSelection.teamBuilder)
                Label("Party Finder", systemImage: "wand.and.stars")
                    .tag(SidebarSelection.partyFinder)
                Label("1v1 Simulator", systemImage: "bolt.horizontal.fill")
                    .tag(SidebarSelection.matchup)
                #if os(macOS)
                Label("Scan", systemImage: "camera.viewfinder")
                    .tag(SidebarSelection.scan)
                #endif
            }

            Section("Leagues") {
                ForEach(RankingFormat.coreLeagues) { format in
                    row(for: format)
                }
            }

            if !visibleCupFormats.isEmpty {
                Section("Cups") {
                    ForEach(visibleCupFormats) { format in
                        row(for: format)
                            .contextMenu {
                                Button("Hide Cup", systemImage: "eye.slash") {
                                    hiddenCups.hide(format.id)
                                }
                            }
                    }
                }
            }

            Section {
                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                LocalBuildProgressRow(builder: store.localRankingBuilder)
            }
        }
        .navigationTitle("PokeParty")
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView(store: store, hiddenCups: hiddenCups)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingSettings = false }
                        }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 420)
            #endif
        }
    }

    private func row(for format: RankingFormat) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(format.title)
                Text(format.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: format.isCoreLeague ? "shield.lefthalf.filled" : "trophy.fill")
                .foregroundStyle(format.tint)
        }
        .tag(SidebarSelection.format(format))
    }
}

/// The "Updating local rankings…" row. Its own view so the frequent
/// `progress` ticks only re-evaluate this row, not the whole sidebar `List`
/// (which re-diffed every row on each tick during the startup build).
private struct LocalBuildProgressRow: View {
    let builder: LocalRankingBuilder

    var body: some View {
        if case .failed(let message) = builder.phase {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if case .building(let formatTitle) = builder.phase {
            VStack(alignment: .leading, spacing: 2) {
                Text("Updating local rankings…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProgressView(value: builder.progress)
                    .labelsHidden()
                Text(formatTitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
