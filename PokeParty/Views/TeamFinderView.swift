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

            Section("Method") {
                Picker("Method", selection: Bindable(model).method) {
                    ForEach(TeamFinderModel.Method.allCases) { method in
                        Text(method.title).tag(method)
                    }
                }
                .disabled(model.isRunning)

                if model.method == .gradeCheck {
                    Text("Every trio from the pool (\(model.estimatedTrios.formatted()) teams) is graded with the Team Builder's static analysis — Coverage, Bulk, Safety and Consistency — and the teams graded A across the board are listed. Pairwise 1v1 matchups only; no 3v3 battle simulations.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.method == .combined {
                    Text("Every trio from the pool is first graded with the Team Builder's static analysis; only the teams graded A in Coverage, Bulk, Safety and Consistency enter the tournament, where a full 3v3 round robin settles their order.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if model.method != .gradeCheck {
                tournamentFieldSection
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
                                Text(seedingLabel)
                            }
                        }
                        Button("Cancel", role: .cancel) { model.cancel() }
                    }
                } else {
                    Button {
                        model.run(using: store)
                    } label: {
                        Label(runButtonTitle, systemImage: "wand.and.stars")
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

    private var seedingLabel: String {
        switch model.method {
        case .tournament: return "Seeding tournament…"
        case .gradeCheck: return "Grading teams…"
        case .combined: return "Finding AAAA teams…"
        }
    }

    private var runButtonTitle: String {
        switch model.method {
        case .tournament: return "Run Tournament"
        case .gradeCheck: return "Find AAAA Teams"
        case .combined: return "Run AAAA Tournament"
        }
    }

    private var tournamentFieldSection: some View {
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

            Toggle("Simulate counterswaps", isOn: Bindable(model).simulateCounterswaps)
                .disabled(model.isRunning)
            Text("Adds voluntary switching to every battle: safe swaps on a bad lead, counterswaps onto a switch-locked opponent, and escapes from a bad matchup once the switch timer allows. More realistic records, slower tournaments.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Optimal shield timing", isOn: Bindable(model).optimalShields)
                .disabled(model.isRunning)
            Text("Solves the best shield play for every 1v1 segment instead of the fast greedy heuristic. Much slower — best kept for small fields.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
            if let graded = model.gradedTeams {
                GradedTeamsView(
                    teams: graded,
                    format: model.resultsFormat,
                    poolSize: model.resultsPoolSize,
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
    }

    private var emptyDescription: String {
        switch model.phase {
        case .searching where model.method == .gradeCheck:
            "Grading every candidate trio with the Team Builder's static analysis…"
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
        teamBuilder.setTeam(members)
        selection = .teamBuilder
    }
}
