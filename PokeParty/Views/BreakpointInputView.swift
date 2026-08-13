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
        guard !query.isEmpty else { return store.allPokemon }
        return store.allPokemon.filter { $0.speciesName.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            Section("Tap a Pokémon to analyze") {
                ForEach(searchResults) { pokemon in
                    Button {
                        Task { await model.select(speciesId: pokemon.speciesId, store: store) }
                    } label: {
                        HStack(spacing: 10) {
                            Text(pokemon.speciesName)
                                .font(.body.weight(.medium))
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
        }
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
