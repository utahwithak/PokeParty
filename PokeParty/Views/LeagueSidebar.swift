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
                Label("Breakpoints", systemImage: "stairs")
                    .tag(SidebarSelection.breakpoints)
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
                }
                .buttonStyle(.plain)
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
