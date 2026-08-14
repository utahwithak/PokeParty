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
}

/// Sidebar listing tools, the core PvP leagues, and active cups (e.g. Summer Cup).
struct LeagueSidebar: View {
    var store: RankingsStore
    var hiddenCups: HiddenCupsStore
    @Binding var selection: SidebarSelection

    private var visibleCupFormats: [RankingFormat] {
        store.cupFormats.filter { !hiddenCups.isHidden($0.id) }
    }

    private var hiddenCupFormats: [RankingFormat] {
        store.cupFormats.filter { hiddenCups.isHidden($0.id) }
    }

    var body: some View {
        // The plain, non-optional `List(selection:)` overload ("a single row
        // that cannot be deselected") is macOS-only; bridge through an
        // Optional binding for the cross-platform overload, ignoring
        // deselection (nil) so the always-selected behavior is preserved.
        List(selection: Binding(
            get: { Optional(selection) },
            set: { if let new = $0 { selection = new } }
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

            if !hiddenCupFormats.isEmpty {
                Section("Hidden Cups") {
                    ForEach(hiddenCupFormats) { format in
                        row(for: format)
                            .foregroundStyle(.secondary)
                            .contextMenu {
                                Button("Unhide Cup", systemImage: "eye") {
                                    hiddenCups.unhide(format.id)
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("PokeParty")
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
