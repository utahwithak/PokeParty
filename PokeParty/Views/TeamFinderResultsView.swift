//
//  TeamFinderResultsView.swift
//  PokeParty
//
//  Team Finder results list and the locked-Pokémon picker.
//

import SwiftUI

/// Detail column: the live tournament leaderboard (which doubles as the
/// final results once the run completes).
struct TeamFinderResultsView: View {
    var store: RankingsStore
    var model: TeamFinderModel
    var teamBuilder: TeamBuilderModel
    @Binding var selection: SidebarSelection?
    /// Called after the team is loaded so a collapsed (iPhone) layout can
    /// navigate to the Team Builder column.
    var onOpenedTeamBuilder: () -> Void = {}
    /// Set when the results are pushed on top of the finder (iOS); pops them
    /// before navigating away so the pushed screen doesn't linger.
    var dismissResults: (() -> Void)?

    var body: some View {
        Group {
            if let graded = model.gradedTeams {
                GradedTeamsView(
                    teams: graded,
                    format: model.resultsFormat,
                    poolSize: model.resultsPoolSize,
                    openInBuilder: { openInTeamBuilder($0.members.map(\.member)) })
            } else if let results = model.optimizerResults {
                OptimizerResultsView(
                    results: results,
                    format: model.resultsFormat,
                    poolSize: model.resultsPoolSize,
                    movesById: store.movesById,
                    store: store,
                    model: model,
                    openInBuilder: { openInTeamBuilder($0.members.map(\.member)) })
            } else if let standings = model.standings {
                TeamFinderSimulationView(
                    standings: standings,
                    format: model.resultsFormat,
                    poolSize: model.resultsPoolSize,
                    openInBuilder: { openInTeamBuilder($0.members.map(\.member)) })
            } else {
                ContentUnavailableView(
                    "Find Suggested Teams",
                    systemImage: "wand.and.stars",
                    description: Text(emptyDescription)
                )
            }
        }
        .navigationTitle("Suggested Teams")
        .inlineNavigationTitle()
    }

    private var emptyDescription: String {
        switch model.phase {
        case .searching where model.method == .gradeCheck:
            "Grading every candidate trio with the Team Builder's static analysis…"
        case .searching where model.method.isOptimizer:
            "Building the meta field and starting hill-climbs…"
        case .searching: "Seeding the tournament — ranking every candidate trio by meta coverage…"
        case .loadingRankings: "Loading rankings…"
        default: "Pick a format and run the Party Finder to watch teams battle for the top of the leaderboard."
        }
    }

    /// Loads the team into the Team Builder (and points it at the finder's
    /// format so the analysis grades match the cup the team was found for).
    private func openInTeamBuilder(_ members: [TeamMember]) {
        if let format = model.resultsFormat {
            store.format = format
        }
        teamBuilder.openDraft(members, for: model.resultsFormat)
        guard let dismissResults else {
            selection = .teamBuilder
            onOpenedTeamBuilder()
            return
        }
        // Pop the pushed results first, then switch tabs once the pop has
        // finished; doing both at once leaves the results screen on top.
        dismissResults()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            selection = .teamBuilder
            onOpenedTeamBuilder()
        }
    }
}

/// Popover content for locking a Pokémon into every AI Optimizer team: a
/// search field filters both the bench (for the finder's league) and the
/// full roster, so the user can lock either an owned Pokémon (with its real
/// IVs/moves) or any meta pick. A plain `TextField` is used instead of
/// `.searchable` since this view has no navigation container to host a
/// search field in on macOS.
struct LockedPokemonPickerView: View {
    var store: RankingsStore
    var bench: BenchStore
    var format: RankingFormat
    var excludingSpeciesIds: Set<String>
    var onSelect: (TeamMember) -> Void

    @State private var searchText = ""

    private var league: League { League(cpCap: format.cp) }

    private var benchResults: [BenchEntry] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return bench.entries.filter { entry in
            guard entry.league == league, !excludingSpeciesIds.contains(entry.speciesId) else { return false }
            guard !query.isEmpty else { return true }
            let name = store.pokemonById[entry.speciesId]?.speciesName ?? entry.speciesId
            return name.localizedCaseInsensitiveContains(query)
                || (!entry.nickname.isEmpty && entry.nickname.localizedCaseInsensitiveContains(query))
        }
    }

    private var allResults: [Pokemon] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return store.eligiblePokemon(for: format).filter { pokemon in
            guard !excludingSpeciesIds.contains(pokemon.speciesId) else { return false }
            guard !query.isEmpty else { return true }
            return pokemon.speciesName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search Pokémon", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            Divider()
            List {
                if !benchResults.isEmpty {
                    Section("From Your Bench") {
                        ForEach(benchResults) { entry in
                            benchRow(entry)
                        }
                    }
                    .themedRow()
                }
                Section("All Pokémon") {
                    ForEach(Array(allResults.prefix(50))) { pokemon in
                        allRow(pokemon)
                    }
                }
                .themedRow()
            }
            .overlay {
                if benchResults.isEmpty && allResults.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
        .frame(minWidth: 300, idealWidth: 320, minHeight: 360, idealHeight: 440)
    }

    private func benchRow(_ entry: BenchEntry) -> some View {
        Button {
            onSelect(entry.asTeamMember())
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(entry.nickname.isEmpty
                             ? (store.pokemonById[entry.speciesId]?.speciesName ?? entry.speciesId)
                             : entry.nickname)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        if entry.shadow { ShadowBadge() }
                    }
                    Text(entry.ivs.map { "IVs \($0.atk)/\($0.def)/\($0.hp)" } ?? "Optimal IVs")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let sp = store.pokemonById[entry.speciesId] {
                    TypeBadgeRow(types: sp.displayTypes)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func allRow(_ pokemon: Pokemon) -> some View {
        Button {
            if let member = store.makeMember(speciesId: pokemon.speciesId) {
                onSelect(member)
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
    }
}
