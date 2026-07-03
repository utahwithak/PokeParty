//
//  ContentView.swift
//  PokeParty
//
//  Created by Carl Wieland on 6/29/26.
//

import SwiftUI

struct ContentView: View {
    @State private var store = RankingsStore()
    @State private var rankChecker = RankCheckerModel()
    @State private var selection: SidebarSelection = .format(.great)
    @State private var selectedEntryID: RankingEntry.ID?

    var body: some View {
        NavigationSplitView {
            LeagueSidebar(store: store, selection: $selection)
                .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 240)
        } content: {
            content
                .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        } detail: {
            detail
                .frame(minWidth: 584)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1040, minHeight: 600)
        .task { await store.load() }
        .onChange(of: selection) { _, new in
            if case .format(let format) = new {
                store.format = format
                selectedEntryID = nil
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .format:
            RankingsListView(store: store, selection: $selectedEntryID)
        case .rankChecker:
            RankCheckerInputView(store: store, model: rankChecker)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .format:
            if let id = selectedEntryID, let entry = store.entry(id: id) {
                PokemonDetailView(entry: entry, store: store)
                    .id(entry.id)
            } else {
                ContentUnavailableView(
                    "Select a Pokémon",
                    systemImage: "sparkles",
                    description: Text("Choose a Pokémon from the rankings to see its stats, moveset and matchups.")
                )
            }
        case .rankChecker:
            RankCheckerResultsView(store: store, model: rankChecker)
        }
    }
}

#Preview {
    ContentView()
}
