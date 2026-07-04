//
//  TeamBuilderView.swift
//  PokeParty
//
//  Middle column of the 3v3 Team Builder: the "Add Pokémon" palette. Tapping a
//  Pokémon adds it to the team, which is shown and edited in the main panel
//  (`TeamBuilderDetailView`).
//

import SwiftUI

struct TeamBuilderView: View {
    var store: RankingsStore
    @Bindable var model: TeamBuilderModel
    @State private var searchText = ""

    /// Released Pokémon matching the search, excluding those already on the team.
    private var searchResults: [Pokemon] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return store.allPokemon.filter { pokemon in
            if model.contains(speciesId: pokemon.speciesId) { return false }
            guard !query.isEmpty else { return true }
            return pokemon.speciesName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(searchResults) { pokemon in
                    Button {
                        if let member = model.makeMember(speciesId: pokemon.speciesId, store: store) {
                            model.add(member)
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Text(pokemon.speciesName)
                                .font(.body.weight(.medium))
                            Spacer()
                            TypeBadgeRow(types: pokemon.displayTypes)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isFull)
                }
            } header: {
                Text(model.isFull ? "Team full — remove one to add another" : "Add Pokémon")
            }
        }
        .navigationTitle("Team Builder")
        .inlineNavigationTitle()
        .searchable(text: $searchText, prompt: "Add a Pokémon")
        .overlay {
            if searchResults.isEmpty, !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }
}
