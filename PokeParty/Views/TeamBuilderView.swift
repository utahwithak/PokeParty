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

    /// A bench entry offered as an addable team member — either its own
    /// species, or (when Megas are in play) one of its Mega Evolutions,
    /// since mega-evolving keeps the same IVs/moves as the owned Pokémon.
    private struct BenchOption: Identifiable {
        let entry: BenchEntry
        let megaForm: Pokemon?
        var speciesId: String { megaForm?.speciesId ?? entry.speciesId }
        var id: String { "\(entry.id)-\(speciesId)" }
    }

    /// Bench entries rated for the team's current league (CP cap) and not
    /// already on the team, plus a Mega-form option for each bench entry
    /// whose species can mega evolve, when the current format allows Megas
    /// (its own cup, or the "Show Mega Evolutions" setting).
    private var benchResults: [BenchOption] {
        let league = League(cpCap: store.format.cp)
        let allowsMega = store.format.allowsMegaEvolution || store.showMegaEvolutions
        return bench.entries
            .filter { $0.league == league }
            .flatMap { entry -> [BenchOption] in
                var options: [BenchOption] = []
                if !model.contains(speciesId: entry.speciesId) {
                    options.append(BenchOption(entry: entry, megaForm: nil))
                }
                if allowsMega {
                    for mega in store.megaEvolutions(for: entry.speciesId)
                    where !model.contains(speciesId: mega.speciesId) {
                        options.append(BenchOption(entry: entry, megaForm: mega))
                    }
                }
                return options
            }
    }

    /// Released Pokémon matching the search, excluding those already on the team.
    /// Includes Mega Evolutions when the current format allows them.
    private var searchResults: [Pokemon] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return store.eligiblePokemon(for: store.format).filter { pokemon in
            if model.contains(speciesId: pokemon.speciesId) { return false }
            guard !query.isEmpty else { return true }
            return pokemon.speciesName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            if !benchResults.isEmpty && searchText.isEmpty {
                Section("From Your Bench") {
                    ForEach(benchResults) { option in
                        let entry = option.entry
                        Button {
                            model.add(entry.asTeamMember(speciesId: option.megaForm?.speciesId))
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text(benchDisplayName(option))
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
                                if let sp = option.megaForm ?? store.pokemonById[entry.speciesId] {
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

    private func benchDisplayName(_ option: BenchOption) -> String {
        if let mega = option.megaForm { return mega.speciesName }
        let entry = option.entry
        if !entry.nickname.isEmpty { return entry.nickname }
        return store.pokemonById[entry.speciesId]?.speciesName ?? entry.speciesId
    }
}
