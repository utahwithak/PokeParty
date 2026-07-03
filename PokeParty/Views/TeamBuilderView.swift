//
//  TeamBuilderView.swift
//  PokeParty
//
//  Middle column of the 3v3 Team Builder: shows the three team slots and lets the
//  user add Pokémon from the current league. Analysis (grades / threats /
//  suggestions) is shown in the detail column by `TeamAnalysisView`.
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
            Section("Team (\(model.members.count)/3)") {
                if model.members.isEmpty {
                    Text("Add up to three Pokémon below.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.slots.enumerated()), id: \.offset) { index, slot in
                        if let member = slot, let pokemon = store.pokemonById[member.speciesId] {
                            memberRow(pokemon: pokemon, member: member, index: index)
                        }
                    }
                }
            }

            Section("Add Pokémon") {
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
                    }
                    .buttonStyle(.plain)
                    .disabled(model.members.count >= 3)
                }
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
        .onAppear { analyzeIfNeeded() }
        .onChange(of: model.members) { analyzeIfNeeded() }
        .onChange(of: store.format) { analyzeIfNeeded() }
    }

    private func memberRow(pokemon: Pokemon, member: TeamMember, index: Int) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(pokemon.speciesName)
                        .font(.body.weight(.semibold))
                    if member.shadow { ShadowBadge() }
                }
                TypeBadgeRow(types: pokemon.displayTypes)
            }
            Spacer()
            Button {
                model.removeMember(at: index)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Remove from team")
        }
    }

    private func analyzeIfNeeded() {
        guard model.hasMembers else { return }
        model.analyze(using: store)
    }
}
