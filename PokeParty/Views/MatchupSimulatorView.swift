//
//  MatchupSimulatorView.swift
//  PokeParty
//
//  Middle column of the 1v1 Simulator: the Pokémon palette. A segmented control
//  picks which side you're setting; tapping a Pokémon assigns it to that side
//  (and flips to the other side if it's still empty, so two taps set up a
//  matchup). The combatants are edited and simulated in the main panel
//  (`MatchupDetailView`).
//

import SwiftUI

struct MatchupSimulatorView: View {
    var store: RankingsStore
    @Bindable var model: MatchupModel
    @State private var searchText = ""
    @State private var side: MatchupModel.Side = .a

    /// Released Pokémon matching the search. Both sides may pick the same
    /// species (mirror matchups are legitimate).
    private var searchResults: [Pokemon] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.allPokemon }
        return store.allPokemon.filter { $0.speciesName.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            Section {
                Picker("Assign to", selection: $side) {
                    Text(sideLabel(.a)).tag(MatchupModel.Side.a)
                    Text(sideLabel(.b)).tag(MatchupModel.Side.b)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Section("Tap a Pokémon to set \(side == .a ? "Side A" : "Side B")") {
                ForEach(searchResults) { pokemon in
                    Button {
                        assign(pokemon)
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
                }
            }
        }
        .navigationTitle("1v1 Simulator")
        .inlineNavigationTitle()
        .searchable(text: $searchText, prompt: "Search Pokémon")
        .overlay {
            if searchResults.isEmpty, !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    private func sideLabel(_ s: MatchupModel.Side) -> String {
        let base = s == .a ? "A" : "B"
        guard let member = model.member(for: s),
              let name = store.pokemonById[member.speciesId]?.speciesName else { return "\(base): —" }
        return "\(base): \(name)"
    }

    private func assign(_ pokemon: Pokemon) {
        guard let member = model.makeMember(speciesId: pokemon.speciesId, store: store) else { return }
        model.set(member, side: side)
        if model.member(for: side.other) == nil { side = side.other }
    }
}
