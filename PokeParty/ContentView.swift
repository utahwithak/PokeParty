//
//  ContentView.swift
//  PokeParty
//
//  Created by Carl Wieland on 6/29/26.
//

import SwiftUI

struct ContentView: View {
    @State private var store = RankingsStore()
    @State private var hiddenCups = HiddenCupsStore()
    @State private var rankChecker = RankCheckerModel()
    @State private var teamBuilder = TeamBuilderModel()
    @State private var teamFinder = TeamFinderModel()
    @State private var matchup = MatchupModel()
    @State private var breakpoints = BreakpointModel()
    @State private var savedTeams = SavedTeamsStore()
    @State private var bench = BenchStore()
    @State private var selection: SidebarSelection? = .format(.great)
    @State private var selectedEntryID: RankingEntry.ID?
    @State private var selectedBenchID: BenchEntry.ID?
    #if os(macOS)
    @State private var showingCaughtScan = false
    #endif

    var body: some View {
        NavigationSplitView {
            LeagueSidebar(store: store, hiddenCups: hiddenCups, selection: $selection)
                .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 240)
        } content: {
            content
                .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        } detail: {
            detail
                #if os(macOS)
                .frame(minWidth: 584)
                #endif
        }
        .navigationSplitViewStyle(.balanced)
        #if os(macOS)
        // Keeps the 3-pane layout usable on macOS; on iOS these columns
        // collapse to a single full-width screen, so a forced minimum here
        // would push most row content off the left edge of the phone screen.
        .frame(minWidth: 1040, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingCaughtScan = true
                } label: {
                    Label("Scan Caught", systemImage: "camera.badge.ellipsis")
                }
                .help("Scan a caught Pokémon's appraisal screen to see IVs and league ranks")
            }
        }
        .sheet(isPresented: $showingCaughtScan) {
            CaughtScanSheet(store: store)
        }
        #endif
        .task { await store.load() }
        .onChange(of: selection) { _, new in
            if let new, case .format(let format) = new {
                store.format = format
                selectedEntryID = nil
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selection ?? .format(.great) {
        case .format:
            RankingsListView(store: store, selection: $selectedEntryID)
        case .rankChecker:
            RankCheckerInputView(store: store, model: rankChecker)
        case .teamBuilder:
            TeamBuilderView(store: store, model: teamBuilder, savedTeams: savedTeams, bench: bench, hiddenCups: hiddenCups)
        case .partyFinder:
            TeamFinderView(store: store, model: teamFinder, teamBuilder: teamBuilder, hiddenCups: hiddenCups, selection: $selection)
        case .matchup:
            MatchupSimulatorView(store: store, model: matchup, hiddenCups: hiddenCups)
        case .breakpoints:
            BreakpointInputView(store: store, model: breakpoints)
        case .bench:
            BenchView(bench: bench, store: store, selectedID: $selectedBenchID,
                      openTeamInBuilder: { league, members in
                          store.format = league.format
                          teamBuilder.setTeam(members)
                          selection = .teamBuilder
                      })
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .format(.great) {
        case .format:
            if let id = selectedEntryID, let entry = store.entry(id: id) {
                PokemonDetailView(entry: entry, store: store, bench: bench, hiddenCups: hiddenCups,
                                  onAddToBench: { benchID in
                    selectedBenchID = benchID
                    selection = .bench
                })
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
        case .teamBuilder:
            TeamBuilderDetailView(store: store, model: teamBuilder, savedTeams: savedTeams, bench: bench, hiddenCups: hiddenCups)
        case .partyFinder:
            TeamFinderResultsView(store: store, model: teamFinder,
                                  teamBuilder: teamBuilder, selection: $selection)
        case .matchup:
            MatchupDetailView(store: store, model: matchup, hiddenCups: hiddenCups)
        case .breakpoints:
            BreakpointResultsView(store: store, model: breakpoints)
        case .bench:
            if let id = selectedBenchID, let entry = bench.entry(id: id) {
                BenchDetailView(bench: bench, store: store, entryID: entry.id)
                    .id(id)
            } else {
                ContentUnavailableView(
                    "Select a Pokémon",
                    systemImage: "tray",
                    description: Text("Choose a Pokémon from your bench to edit its IVs and moves.")
                )
            }
        }
    }
}

#Preview {
    ContentView()
}
