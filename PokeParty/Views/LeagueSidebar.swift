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
}

/// Sidebar listing tools, the core PvP leagues, and active cups (e.g. Summer Cup).
struct LeagueSidebar: View {
    var store: RankingsStore
    @Binding var selection: SidebarSelection

    var body: some View {
        List(selection: $selection) {
            Section("Tools") {
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

            if !store.cupFormats.isEmpty {
                Section("Cups") {
                    ForEach(store.cupFormats) { format in
                        row(for: format)
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
