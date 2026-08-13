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
    var savedTeams: SavedTeamsStore
    var bench: BenchStore
    @State private var searchText = ""

    /// Bench entries not already on the team.
    private var benchResults: [BenchEntry] {
        bench.entries.filter { !model.contains(speciesId: $0.speciesId) }
    }

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
            if !benchResults.isEmpty && searchText.isEmpty {
                Section("From Your Bench") {
                    ForEach(benchResults) { entry in
                        Button {
                            store.format = entry.league.format
                            model.add(entry.asTeamMember())
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text(benchDisplayName(entry))
                                            .font(.body.weight(.medium))
                                        if entry.shadow { ShadowBadge() }
                                    }
                                    HStack(spacing: 6) {
                                        Text(entry.league.title)
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(entry.league.tint)
                                        if let ivs = entry.ivs {
                                            Text("· IVs \(ivs.atk)/\(ivs.def)/\(ivs.hp)")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        } else {
                                            Text("· Optimal IVs")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                Spacer()
                                if let sp = store.pokemonById[entry.speciesId] {
                                    TypeBadgeRow(types: sp.displayTypes)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isFull)
                    }
                }
            }
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
                Text(model.isFull ? "Team full — remove one to add another" : "All Pokémon")
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
        #if os(iOS)
        // See MatchupSimulatorView: on iOS the detail column (here,
        // TeamBuilderDetailView) has no other way to become reachable.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    TeamBuilderDetailView(store: store, model: model, savedTeams: savedTeams, bench: bench)
                } label: {
                    Label("View Team", systemImage: "person.3.sequence.fill")
                }
                .disabled(!model.hasMembers)
            }
        }
        #endif
    }

    private func benchDisplayName(_ entry: BenchEntry) -> String {
        if !entry.nickname.isEmpty { return entry.nickname }
        return store.pokemonById[entry.speciesId]?.speciesName ?? entry.speciesId
    }
}
