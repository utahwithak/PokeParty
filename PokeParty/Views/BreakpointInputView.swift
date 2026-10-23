//
//  BreakpointInputView.swift
//  PokeParty
//
//  Middle column of the Breakpoints tool: choose the subject Pokémon and its
//  level. The analysis runs and renders in `BreakpointResultsView`.
//

import SwiftUI

struct BreakpointInputView: View {
    var store: RankingsStore
    @Bindable var model: BreakpointModel
    @State private var searchText = ""

    private var searchResults: [Pokemon] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.pokemonForPicker }
        return store.pokemonForPicker.filter { $0.speciesName.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            Section("League") {
                // Menu style, not segmented: segmented pickers inside a macOS
                // List emit AttributeGraph cycles on re-layout.
                Picker("League", selection: Binding(
                    get: { model.format },
                    set: { newValue in Task { await model.setFormat(newValue, store: store) } }
                )) {
                    ForEach(RankingFormat.coreLeagues) { format in
                        Text(format.title).tag(format)
                    }
                }
                .labelsHidden()
            }
            .themedRow()
            Section("Compare as Rank") {
                Picker("Compare as Rank", selection: Binding(
                    get: { model.targetRank },
                    set: { model.setTargetRank($0) }
                )) {
                    ForEach(BreakpointModel.rankTiers, id: \.self) { rank in
                        Text("Rank \(rank)").tag(rank)
                    }
                }
                .labelsHidden()
                Text("Uses that rank's actual IV combination (its own optimal level under the CP cap) instead of assuming 15/15/15.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .themedRow()
            Section("Tap a Pokémon to analyze") {
                ForEach(searchResults) { pokemon in
                    Button {
                        Task { await model.select(speciesId: pokemon.speciesId, store: store) }
                    } label: {
                        HStack(spacing: 10) {
                            Text(pokemon.speciesName)
                                .font(.body.weight(.medium))
                                .lineLimit(1)
                            if pokemon.speciesId == model.member?.speciesId {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                            Spacer()
                            TypeBadgeRow(types: pokemon.displayTypes)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .themedRow()
        }
        .themedBackground()
        .navigationTitle("Breakpoints")
        .inlineNavigationTitle()
        .searchable(text: $searchText, prompt: "Search Pokémon")
        .overlay {
            if searchResults.isEmpty, !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .task(id: store.phase) {
            // Default subject once the data is in: the classic Groudon example.
            if store.phase == .loaded, model.member == nil {
                await model.select(speciesId: "groudon", store: store)
            }
        }
        #if os(iOS)
        // See MatchupSimulatorView: on iOS the detail column (here,
        // BreakpointResultsView) has no other way to become reachable.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    BreakpointResultsView(store: store, model: model)
                } label: {
                    Label("View Breakpoints", systemImage: "stairs")
                }
                .disabled(model.member == nil)
            }
        }
        #endif
    }
}
