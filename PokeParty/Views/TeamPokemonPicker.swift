//
//  TeamPokemonPicker.swift
//  PokeParty
//
//  The popover opened from an empty slot (or the toolbar's Add Pokémon button)
//  in the Team Builder: the player's bench for this league, then every
//  Pokémon eligible for it, with a search field. Picking one adds it to the team.
//

import SwiftUI

struct TeamPokemonPicker: View {
    var store: RankingsStore
    var model: TeamBuilderModel
    var bench: BenchStore
    /// The slot to swap a Pokémon into; nil adds to the end of the team.
    var replacing: Int? = nil
    /// Called after a Pokémon is added, to close the popover.
    var onDone: () -> Void
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    /// A bench entry offered as an addable team member — either its own
    /// species, or (when Megas are in play) one of its Mega Evolutions,
    /// since mega-evolving keeps the same IVs/moves as the owned Pokémon.
    private struct BenchOption: Identifiable {
        let entry: BenchEntry
        let megaForm: Pokemon?
        var speciesId: String { megaForm?.speciesId ?? entry.speciesId }
        var id: String { "\(entry.id)-\(speciesId)" }
    }

    /// Bench entries rated for the team's league (CP cap) and not already on
    /// the team, plus a Mega-form option for each one that can mega evolve,
    /// when the league's cup allows Megas.
    private var benchResults: [BenchOption] {
        let league = League(cpCap: store.format.cp)
        let allowsMega = store.cupAllowsMegas(store.format)
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
    private var searchResults: [Pokemon] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return store.eligiblePokemon(for: store.format).filter { pokemon in
            if model.contains(speciesId: pokemon.speciesId) { return false }
            guard !query.isEmpty else { return true }
            return pokemon.speciesName.localizedCaseInsensitiveContains(query)
        }
    }

    private func pick(_ member: TeamMember) {
        if let replacing { model.replace(at: replacing, with: member) } else { model.add(member) }
        onDone()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Add a Pokémon to \(store.format.title)", text: $searchText)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .focused($searchFocused)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            Divider()
            List {
                let bench = searchText.isEmpty ? benchResults : []
                if !bench.isEmpty {
                    Section("From Your Bench") {
                        ForEach(bench) { option in benchRow(option) }
                    }
                }
                Section("All Pokémon") {
                    ForEach(searchResults) { pokemon in
                        Button {
                            if let member = model.makeMember(speciesId: pokemon.speciesId, store: store) {
                                pick(member)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Text(pokemon.speciesName).font(.body.weight(.medium)).lineLimit(1)
                                Spacer()
                                TypeBadgeRow(types: pokemon.displayTypes)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if searchResults.isEmpty, !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
        #if os(macOS)
        .frame(width: 360, height: 460)
        #else
        // An iPad popover otherwise shrinks to the search field's height; on an
        // iPhone this is presented as a sheet and simply fills it.
        .frame(minWidth: 320, idealWidth: 360, minHeight: 400, idealHeight: 460)
        #endif
        .onAppear { searchFocused = true }
    }

    private func benchRow(_ option: BenchOption) -> some View {
        let entry = option.entry
        return Button {
            pick(entry.asTeamMember(speciesId: option.megaForm?.speciesId))
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(benchDisplayName(option)).font(.body.weight(.medium)).lineLimit(1)
                        if entry.shadow { ShadowBadge() }
                    }
                    Text(entry.ivs.map { "IVs \($0.atk)/\($0.def)/\($0.hp)" } ?? "Optimal IVs")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if let sp = option.megaForm ?? store.pokemonById[entry.speciesId] {
                    TypeBadgeRow(types: sp.displayTypes)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func benchDisplayName(_ option: BenchOption) -> String {
        if let mega = option.megaForm { return mega.speciesName }
        let entry = option.entry
        if !entry.nickname.isEmpty { return entry.nickname }
        return store.pokemonById[entry.speciesId]?.speciesName ?? entry.speciesId
    }
}
