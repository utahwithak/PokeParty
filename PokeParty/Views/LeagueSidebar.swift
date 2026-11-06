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
    #if os(macOS)
    /// Live coaching tips — macOS only (runs the simulations; the iPhone just feeds it).
    case battleHUD
    #endif
    case matchup
    case breakpoints
    case bench
    #if os(macOS)
    /// Live capture + IV grid scanning tool — unavailable on iOS since it
    /// captures the iPhone Mirroring window via ScreenCaptureKit.
    case scan
    #endif
    #if os(iOS)
    /// Reads the opponent off the Pokémon GO battle screen (iOS 27 screen capture).
    case screenScan
    #endif
    #if os(macOS) && BETA_SCAN
    /// Scan plus auto-advance swipes (synthetic input) — non-App Store builds only.
    case betaScan
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
        #if os(macOS)
        case .battleHUD: return "battleHUD"
        #endif
        case .matchup: return "matchup"
        case .breakpoints: return "breakpoints"
        case .bench: return "bench"
        #if os(macOS)
        case .scan: return "scan"
        #endif
        #if os(iOS)
        case .screenScan: return "screenScan"
        #endif
        #if os(macOS) && BETA_SCAN
        case .betaScan: return "betaScan"
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
        #if os(macOS)
        case "battleHUD": return .battleHUD
        #endif
        case "matchup": return .matchup
        // "breakpoints" intentionally unresolved: the tab is pulled from
        // this release's sidebar, so a persisted selection from before the
        // update shouldn't restore to a now-unreachable screen.
        case "bench": return .bench
        #if os(macOS)
        case "scan": return .scan
        #endif
        #if os(iOS)
        case "screenScan": return .screenScan
        #endif
        #if os(macOS) && BETA_SCAN
        case "betaScan": return .betaScan
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
    @State private var order = SidebarOrderStore()
    @Environment(EntitlementStore.self) private var entitlements

    private var visibleCupFormats: [RankingFormat] {
        store.cupFormats.filter { !hiddenCups.isHidden($0.id) }
    }

    /// A tool's row in the sidebar.
    private struct Tool: Identifiable {
        let selection: SidebarSelection
        let title: String
        let systemImage: String
        var id: String { selection.persistenceKey }
    }

    /// The tools in their default order.
    private static let tools: [Tool] = [
        Tool(selection: .bench, title: "My Bench", systemImage: "tray.fill"),
        Tool(selection: .rankChecker, title: "Rank Checker", systemImage: "checklist"),
        Tool(selection: .teamBuilder, title: "Team Builder", systemImage: "person.3.sequence.fill"),
        Tool(selection: .matchup, title: "1v1 Simulator", systemImage: "bolt.horizontal.fill"),
    ]

    /// The Pro tools in their default order.
    private static let proTools: [Tool] = {
        var tools = [Tool(selection: .partyFinder, title: "Party Finder", systemImage: "wand.and.stars")]
        #if os(macOS)
        tools.append(Tool(selection: .battleHUD, title: "Battle HUD", systemImage: "speedometer"))
        tools.append(Tool(selection: .scan, title: "Scan", systemImage: "camera.viewfinder"))
        #else
        tools.append(Tool(selection: .screenScan, title: "Screen Scan", systemImage: "viewfinder"))
        #endif
        #if os(macOS) && BETA_SCAN
        tools.append(Tool(selection: .betaScan, title: "Beta Scan", systemImage: "hand.draw"))
        #endif
        return tools
    }()

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
            // Rows within a section can be dragged into the order you like.
            Section("Tools") {
                let tools = order.ordered(Self.tools, in: .tools, key: \.id)
                ForEach(tools) { tool in
                    Label(tool.title, systemImage: tool.systemImage)
                        .tag(tool.selection)
                }
                .onMove { order.move(Self.tools, in: .tools, key: \.id, from: $0, to: $1) }
            }
            .themedRow()

            // Everything behind PokeParty Pro, with a lock while it isn't unlocked.
            Section("Pro") {
                let proTools = order.ordered(Self.proTools, in: .pro, key: \.id)
                ForEach(proTools) { tool in
                    proLabel(tool.title, systemImage: tool.systemImage)
                        .tag(tool.selection)
                }
                .onMove { order.move(Self.proTools, in: .pro, key: \.id, from: $0, to: $1) }
            }
            .themedRow()

            Section("Leagues") {
                let leagues = order.ordered(RankingFormat.coreLeagues, in: .leagues, key: \.id)
                ForEach(leagues) { format in
                    row(for: format)
                }
                .onMove { order.move(RankingFormat.coreLeagues, in: .leagues, key: \.id, from: $0, to: $1) }
            }
            .themedRow()

            if !visibleCupFormats.isEmpty {
                Section("Cups") {
                    let cups = order.ordered(visibleCupFormats, in: .cups, key: \.id)
                    ForEach(cups) { format in
                        row(for: format)
                            .contextMenu {
                                Button("Hide Cup", systemImage: "eye.slash") {
                                    hiddenCups.hide(format.id)
                                }
                            }
                    }
                    .onMove { order.move(visibleCupFormats, in: .cups, key: \.id, from: $0, to: $1) }
                }
                .themedRow()
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
            .themedRow()
        }
        .themedBackground()
        .navigationTitle("PokeParty")
        .contextMenu {
            if order.isCustomized {
                Button("Reset Sidebar Order", systemImage: "arrow.counterclockwise") { order.reset() }
            }
        }
        #if os(iOS)
        // Dragging rows to reorder them needs the list in edit mode on iOS.
        .toolbar { EditButton() }
        #endif
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

    /// A Pro tool's row: a lock on the trailing edge until Pro is unlocked.
    private func proLabel(_ title: String, systemImage: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            if !entitlements.isUnlocked {
                Spacer()
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
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
