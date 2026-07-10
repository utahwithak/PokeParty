//
//  TeamFinderView.swift
//  PokeParty
//
//  The 3v3 Party Finder: pick a format and pool size, run the search, and
//  browse the suggested teams ranked by their simulated 3v3 record.
//  `TeamFinderView` is the content column (configuration + run controls);
//  `TeamFinderResultsView` is the detail column (ranked results).
//

import SwiftUI

/// Content column: choose the format + candidate pool and start the search.
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

                Text("Every 3-Pokémon combination from the pool battles the same sample of opponent teams in full 3v3 simulations (recommended movesets, best-matchup switching). Larger pools find more teams but take longer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if model.isRunning {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.phase == .loadingRankings {
                            ProgressView("Loading rankings…")
                        } else {
                            ProgressView(value: model.progress) {
                                Text("Simulating battles…")
                            }
                        }
                        Button("Cancel", role: .cancel) { model.cancel() }
                    }
                } else {
                    Button {
                        model.run(using: store)
                    } label: {
                        Label("Find Teams", systemImage: "wand.and.stars")
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
        }
        .formStyle(.grouped)
        .navigationTitle("Party Finder")
    }
}

/// Detail column: the suggested teams, best 3v3 record first.
struct TeamFinderResultsView: View {
    var store: RankingsStore
    var model: TeamFinderModel
    var teamBuilder: TeamBuilderModel
    @Binding var selection: SidebarSelection

    var body: some View {
        Group {
            if model.results.isEmpty {
                ContentUnavailableView(
                    "Find Suggested Teams",
                    systemImage: "wand.and.stars",
                    description: Text(emptyDescription)
                )
            } else {
                resultsList
            }
        }
        .navigationTitle("Suggested Teams")
    }

    private var emptyDescription: String {
        switch model.phase {
        case .searching: "Simulating 3v3 battles…"
        case .loadingRankings: "Loading rankings…"
        default: "Pick a format and run the Party Finder to see suggested teams ranked by their simulated 3v3 record."
        }
    }

    private var resultsList: some View {
        List {
            if let format = model.resultsFormat {
                Section {
                    Text("\(format.title) — every team from the top \(model.resultsPoolSize) ranked Pokémon, graded by 3v3 simulations against a shared sample of opponent teams. The first member is the lead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(Array(model.results.enumerated()), id: \.element.id) { index, team in
                    SuggestedTeamRow(rank: index + 1, team: team) {
                        openInTeamBuilder(team)
                    }
                }
            }
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

/// One suggested team: rank, record, the three members (lead first).
private struct SuggestedTeamRow: View {
    let rank: Int
    let team: TeamFinder.RankedTeam
    let openInBuilder: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("#\(rank)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    ForEach(Array(team.members.enumerated()), id: \.offset) { index, member in
                        memberCell(member, isLead: index == 0)
                    }
                }
                HStack(spacing: 8) {
                    Text(team.winRate, format: .percent.precision(.fractionLength(0)))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                    Text("\(team.wins)W · \(team.losses)L\(team.ties > 0 ? " · \(team.ties)T" : "")")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    RatingBar(rating: Int(team.averageRating.rounded()))
                        .frame(maxWidth: 160)
                }
            }

            Spacer()

            Button("Open in Team Builder", action: openInBuilder)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private func memberCell(_ member: TeamFinder.Candidate, isLead: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(member.speciesName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if member.shadow { ShadowBadge() }
                if isLead {
                    Text("LEAD")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            TypeBadgeRow(types: member.types)
        }
        .frame(minWidth: 110, alignment: .leading)
    }
}
