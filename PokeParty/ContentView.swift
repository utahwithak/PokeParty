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
    @State private var entitlements = EntitlementStore()
    @State private var rankChecker = RankCheckerModel()
    @State private var teamBuilder = TeamBuilderModel()
    @State private var teamFinder = TeamFinderModel()
    @State private var matchup = MatchupModel()
    @State private var breakpoints = BreakpointModel()
    @State private var savedTeams = SavedTeamsStore()
    @State private var bench = BenchStore()
    @State private var shareImport = ShareImportModel()
    #if os(iOS)
    @AppStorage(AppTheme.defaultsKey) private var selectedTheme = AppTheme.standard
    #endif
    @State private var selection: SidebarSelection? = .format(.great)
    @State private var selectedEntryID: RankingEntry.ID?
    @State private var selectedBenchID: BenchEntry.ID?
    #if os(macOS)
    @State private var scanModel = ScanModel()
    #endif
    #if os(macOS) && BETA_SCAN
    @State private var autoAdvance = AutoAdvanceModel()
    #endif

    private static let selectionDefaultsKey = "PokeParty.selectedTab"

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
        #if os(iOS)
        .appTheme(selectedTheme.available(unlocked: entitlements.isUnlocked))
        #endif
        .environment(entitlements)
        .environment(shareImport)
        .fileImporter(
            isPresented: Bindable(shareImport).isImporterPresented,
            allowedContentTypes: [.pokePartyResults],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { importResults(urls) }
        }
        // Opening a .pokeparty file (Finder, Files, AirDrop, Messages).
        .onOpenURL { importResults([$0]) }
        .alert("Import", isPresented: Binding(
            get: { shareImport.message != nil },
            set: { if !$0 { shareImport.message = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(shareImport.message ?? "")
        }
        #if os(macOS)
        // Keeps the 3-pane layout usable on macOS; on iOS these columns
        // collapse to a single full-width screen, so a forced minimum here
        // would push most row content off the left edge of the phone screen.
        .frame(minWidth: 1040, minHeight: 600)
        #endif
        .task {
            await store.load()
            restoreSavedSelection()
        }
        .task { await store.observeDataUpdates() }
        .task { await entitlements.load() }
        .onChange(of: selection) { _, new in
            if let new, case .format(let format) = new {
                store.format = format
                selectedEntryID = nil
            }
            if let new {
                UserDefaults.standard.set(new.persistenceKey, forKey: Self.selectionDefaultsKey)
            }
        }
    }

    /// Imports shared `.pokeparty` files into the matching stores and reports
    /// what happened in one alert.
    private func importResults(_ urls: [URL]) {
        Task {
            var messages: [String] = []
            for url in urls {
                messages.append(await ResultsImporter.importFile(
                    at: url,
                    tournaments: teamFinder.savedTournaments,
                    optimizerRuns: teamFinder.savedOptimizerRuns,
                    savedTeams: savedTeams))
            }
            shareImport.message = messages.joined(separator: "\n")
        }
    }

    /// Restores the tab selected at the end of the previous launch, once the
    /// gamemaster (and any active cups) have loaded — a saved cup selection
    /// can't resolve until then. No-ops if nothing was saved or it no longer
    /// resolves (e.g. a cup that's since ended).
    private func restoreSavedSelection() {
        guard let key = UserDefaults.standard.string(forKey: Self.selectionDefaultsKey),
              let restored = SidebarSelection.restored(from: key, cupFormats: store.cupFormats)
        else { return }
        selection = restored
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
            if entitlements.isUnlocked {
                TeamFinderView(store: store, model: teamFinder, teamBuilder: teamBuilder, bench: bench, hiddenCups: hiddenCups, selection: $selection)
            } else {
                PaywallView()
            }
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
        #if os(macOS)
        case .scan:
            if entitlements.isUnlocked {
                ScanLiveView(store: store, model: scanModel)
            } else {
                PaywallView()
            }
        #endif
        #if os(macOS) && BETA_SCAN
        case .betaScan:
            if entitlements.isUnlocked {
                BetaScanLiveView(store: store, model: scanModel, autoAdvance: autoAdvance)
            } else {
                PaywallView()
            }
        #endif
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
            if entitlements.isUnlocked {
                TeamFinderResultsView(store: store, model: teamFinder,
                                      teamBuilder: teamBuilder, selection: $selection)
            } else {
                ContentUnavailableView("", systemImage: "wand.and.stars")
            }
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
        #if os(macOS)
        case .scan:
            if entitlements.isUnlocked {
                ScanGridView(store: store, bench: bench, model: scanModel, onAdded: { benchID in
                    selectedBenchID = benchID
                })
            } else {
                ContentUnavailableView("", systemImage: "camera.viewfinder")
            }
        #endif
        #if os(macOS) && BETA_SCAN
        case .betaScan:
            if entitlements.isUnlocked {
                ScanGridView(store: store, bench: bench, model: scanModel, onAdded: { benchID in
                    selectedBenchID = benchID
                })
            } else {
                ContentUnavailableView("", systemImage: "camera.viewfinder")
            }
        #endif
        }
    }
}

#Preview {
    ContentView()
}
