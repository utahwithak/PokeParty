//
//  RankCheckerInputView.swift
//  PokeParty
//
//  Middle column for the Rank Checker: Pokémon search/selection. IVs and level
//  controls live in the detail column.
//

import SwiftUI

struct RankCheckerInputView: View {
    var store: RankingsStore
    @Bindable var model: RankCheckerModel

    private var results: [Pokemon] {
        let query = model.searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.pokemonForPicker }
        return store.pokemonForPicker.filter { $0.speciesName.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List(selection: $model.selectedSpeciesId) {
            Section("Pokémon") {
                ForEach(results) { pokemon in
                    HStack(spacing: 10) {
                        Text(pokemon.speciesName)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        Spacer()
                        TypeBadgeRow(types: pokemon.displayTypes)
                    }
                    .tag(pokemon.speciesId)
                }
            }
            .themedPlainRow()
        }
        .themedBackground()
        .navigationTitle("Rank Checker")
        .inlineNavigationTitle()
        .searchable(text: $model.searchText, prompt: "Search Pokémon")
        .overlay {
            if results.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            }
        }
    }
}
