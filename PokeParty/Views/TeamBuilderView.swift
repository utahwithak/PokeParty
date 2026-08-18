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
    var hiddenCups: HiddenCupsStore
    @State private var searchText = ""

    /// Bench entries rated for the team's current league (CP cap) and not
    /// already on the team.
    private var benchResults: [BenchEntry] {
        let league = League(cpCap: store.format.cp)
        return bench.entries.filter { $0.league == league && !model.contains(speciesId: $0.speciesId) }
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
                            model.add(entry.asTeamMember())
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text(benchDisplayName(entry))
                                            .font(.body.weight(.medium))
                                            .lineLimit(1)
                                        if entry.shadow { ShadowBadge() }
                                    }
                                    HStack(spacing: 6) {
                                        Text(entry.league?.title ?? "")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(entry.league?.tint ?? .secondary)
                                            .lineLimit(1)
                                        if let ivs = entry.ivs {
                                            Text("· IVs \(ivs.atk)/\(ivs.def)/\(ivs.hp)")
                                                .font(.caption2).foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        } else {
                                            Text("· Optimal IVs")
                                                .font(.caption2).foregroundStyle(.secondary)
                                                .lineLimit(1)
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
                                .lineLimit(1)
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
                    TeamBuilderDetailView(store: store, model: model, savedTeams: savedTeams, bench: bench, hiddenCups: hiddenCups)
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
