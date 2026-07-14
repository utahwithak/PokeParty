//
//  TeamFinderView.swift
//  PokeParty
//
//  The 3v3 Party Finder: pick a format, pool and tournament field, run the
//  round robin, and watch the leaderboard settle. `TeamFinderView` is the
//  content column (configuration + run controls + saved results);
//  `TeamFinderResultsView` is the detail column, which hands the live
//  standings to `TeamFinderSimulationView`.
//

import SwiftUI

/// Content column: configure and start the tournament, or reopen a saved one.
struct TeamFinderView: View {
    var store: RankingsStore
    var model: TeamFinderModel

    var body: some View {
        Form {
            Section("Format") {
                Picker("Format", selection: Bindable(model).format) {
                    ForEach(RankingFormat.coreLeagues) { format in
                        Text(format.title).tag(format)
                    }
                    if !store.cupFormats.isEmpty {
                        Divider()
                        ForEach(store.cupFormats) { format in
                            Text(format.title).tag(format)
                        }
                    }
                }
                .disabled(model.isRunning)
            }

            Section("Candidate pool") {
                Picker("Top ranked Pokémon", selection: Bindable(model).poolSize) {
                    ForEach(TeamFinderModel.poolSizes, id: \.self) { size in
                        Text("Top \(size)").tag(size)
                    }
                }
                .disabled(model.isRunning)
            }

            Section("Tournament field") {
                VStack(alignment: .leading, spacing: 4) {
                    Slider(
                        value: Binding(
                            get: { Double(model.fieldSize) },
                            set: { model.fieldSize = Int($0) }),
                        in: TeamFinderModel.fieldSizeRange,
                        step: TeamFinderModel.fieldSizeStep
                    ) {
                        Text("Field size")
                    }
                    .disabled(model.isRunning)

                    Text("\(model.fieldSize) teams — \(model.estimatedBattles.formatted()) battles")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text("The most promising teams from the pool fight a full round robin — every team battles every other team in true 3v3 simulations (recommended movesets, best-matchup switching), so a record is measured against the entire field. Bigger fields take longer, but standings stream live and finished tournaments are saved below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if model.isRunning {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.phase == .loadingRankings {
                            ProgressView("Loading rankings…")
                        } else if let standings = model.standings {
                            ProgressView(
                                value: Double(standings.battlesFought),
                                total: Double(max(standings.totalBattles, 1))
                            ) {
                                Text("Round \(standings.round) of \(standings.totalRounds) — \(standings.battlesFought.formatted()) of \(standings.totalBattles.formatted()) battles")
                            }
                        } else {
                            ProgressView(value: model.progress) {
                                Text("Seeding tournament…")
                            }
                        }
                        Button("Cancel", role: .cancel) { model.cancel() }
                    }
                } else {
                    Button {
                        model.run(using: store)
                    } label: {
                        Label("Run Tournament", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.pokemonById.isEmpty)
                }

                if case .failed(let message) = model.phase {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if !model.savedTournaments.runs.isEmpty {
                Section("Saved tournaments") {
                    ForEach(model.savedTournaments.runs) { run in
                        SavedTournamentRow(run: run) {
                            model.load(run)
                        } onDelete: {
                            model.savedTournaments.delete(run)
                        }
                        .disabled(model.isRunning)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Party Finder")
    }
}

/// One saved run: configuration summary + when it was fought.
private struct SavedTournamentRow: View {
    let run: SavedTournament
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.formatTitle)
                        .font(.subheadline.weight(.medium))
                    Text("Top \(run.poolSize) pool · \(run.fieldSize)-team field · \(run.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            Spacer()

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this saved tournament")
        }
    }
}

/// Detail column: the live tournament leaderboard (which doubles as the
/// final results once the run completes).
struct TeamFinderResultsView: View {
    var store: RankingsStore
    var model: TeamFinderModel
    var teamBuilder: TeamBuilderModel
    @Binding var selection: SidebarSelection

    var body: some View {
        Group {
            if let standings = model.standings {
                TeamFinderSimulationView(
                    standings: standings,
                    format: model.resultsFormat,
                    poolSize: model.resultsPoolSize,
                    openInBuilder: openInTeamBuilder)
            } else {
                ContentUnavailableView(
                    "Find Suggested Teams",
                    systemImage: "wand.and.stars",
                    description: Text(emptyDescription)
                )
            }
        }
        .navigationTitle("Suggested Teams")
    }

    private var emptyDescription: String {
        switch model.phase {
        case .searching: "Seeding the tournament — ranking every candidate trio by meta coverage…"
        case .loadingRankings: "Loading rankings…"
        default: "Pick a format and run the Party Finder to watch teams battle for the top of the leaderboard."
        }
    }

    /// Loads the team into the Team Builder (and points it at the finder's
    /// format so the analysis grades match the cup the team was found for).
    private func openInTeamBuilder(_ team: TeamFinder.RankedTeam) {
        if let format = model.resultsFormat {
            store.format = format
        }
        teamBuilder.setTeam(team.members.map(\.member))
        selection = .teamBuilder
    }
}
