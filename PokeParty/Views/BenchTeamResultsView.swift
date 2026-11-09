//
//  BenchTeamResultsView.swift
//  PokeParty
//
//  Results list for a bench team search.
//

import SwiftUI

/// Two-phase sheet: static grade analysis finds bench trios, then a full
/// round-robin tournament measures how those trios actually perform against
/// a competitive meta field. Only bench teams' records are shown.
struct BenchTeamResultsView: View {
    var model: BenchFinderModel
    var onOpenInBuilder: ((League, [TeamMember]) -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            content
        }
        #if os(macOS)
        .frame(minWidth: 760, minHeight: 520)
        #endif
    }

    private var titleBar: some View {
        HStack {
            if let league = model.resultsLeague {
                Text("\(league.title) League · \(model.benchCount) bench Pokémon")
                    .font(.headline)
            } else {
                Text("Bench Team Finder")
                    .font(.headline)
            }
            Spacer()
            if model.isRunning {
                Button("Cancel") { model.cancel() }
            } else {
                Button("Done") { dismiss() }
            }
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            EmptyView()

        case .loadingRankings:
            ProgressView("Loading rankings…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .gradingBench:
            VStack(spacing: 10) {
                ProgressView(value: model.progress / 0.45) {
                    Text("Phase 1 — Grading bench teams against the meta…")
                }
                .padding(.horizontal)
                Text("Finding the best bench trios using static grade analysis.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .searching:
            tournamentView

        case .done:
            tournamentView

        case .failed(let message):
            ContentUnavailableView(
                "Could Not Find Teams",
                systemImage: "exclamationmark.triangle",
                description: Text(message))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Tournament leaderboard (phases 2 + done)

    private var tournamentView: some View {
        VStack(spacing: 0) {
            tournamentHeader.padding()
            Divider()
            if model.benchStandings.isEmpty {
                ContentUnavailableView(
                    "Seeding tournament…",
                    systemImage: "wand.and.stars",
                    description: Text("Bench teams enter the leaderboard as battles resolve."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.benchStandings.enumerated()), id: \.element.id) { index, team in
                            benchTournamentRow(rank: index + 1, team: team)
                                .transition(.asymmetric(insertion: .opacity, removal: .opacity))
                        }
                    }
                    .padding(.vertical, 4)
                    .animation(.spring(duration: 0.6), value: model.benchStandings.map(\.id))
                }
            }
        }
    }

    private var tournamentHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                if let standings = model.standings {
                    Text(standings.isComplete
                         ? "Tournament complete"
                         : "Round \(standings.round + 1) of \(standings.totalRounds + 1)")
                        .font(.headline)
                        .contentTransition(.numericText())
                } else {
                    Text("Tournament starting…").font(.headline)
                }
                Spacer()
                Text("\(model.benchStandings.count) bench team\(model.benchStandings.count == 1 ? "" : "s")")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if model.phase == .searching, let standings = model.standings {
                ProgressView(
                    value: Double(standings.battlesFought),
                    total: Double(max(standings.totalBattles, 1)))
                    .progressViewStyle(.linear)
            } else if model.phase == .searching {
                ProgressView(value: (model.progress - 0.45) / 0.55)
                    .progressViewStyle(.linear)
            }
            Text(tournamentCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var tournamentCaption: String {
        let league = model.resultsLeague.map { "\($0.title) League — " } ?? ""
        let benched = model.gradedBenchTeams.count
        let field = model.tournamentFieldSize
        if model.phase == .done {
            return "\(league)\(benched) bench trio\(benched == 1 ? "" : "s") in a \(field)-team round robin alongside top-\(BenchFinderModel.metaPoolSize) meta teams. Bench records below, best win rate first. The first member is the lead."
        }
        return "\(league)Phase 2 — \(benched) bench trio\(benched == 1 ? "" : "s") battling in a \(field)-team round robin with top-\(BenchFinderModel.metaPoolSize) meta teams. Bench results update live."
    }

    // MARK: - Tournament row (bench team)

    private func benchTournamentRow(rank: Int, team: TeamFinder.RankedTeam) -> some View {
        let graded = model.gradedBenchTeams.first(where: { $0.id == team.id })
        let openInBuilder: (() -> Void)? = (onOpenInBuilder != nil && model.resultsLeague != nil) ? {
            onOpenInBuilder?(model.resultsLeague!, team.members.map(\.member))
            dismiss()
        } : nil
        return TeamResultRow(
            rank: rank,
            members: team.members.enumerated().map { index, member in
                TeamResultMember(speciesName: member.speciesName, types: member.types,
                                  shadow: member.shadow, isLead: index == 0)
            },
            onOpenInBuilder: openInBuilder,
            record: { benchRecordLine(team: team, graded: graded) }
        )
    }

    @ViewBuilder
    private func benchRecordLine(team: TeamFinder.RankedTeam, graded: GradeFinder.GradedTeam?) -> some View {
        if team.gamesPlayed == 0 {
            Text("Seeded — awaiting first battles")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 8) {
                Text(team.winRate, format: .percent.precision(.fractionLength(0)))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText())
                Text("\(team.wins)W · \(team.losses)L\(team.ties > 0 ? " · \(team.ties)T" : "") vs field")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                RatingBar(rating: Int(team.averageRating.rounded()))
                    .frame(maxWidth: 120)
                if let graded {
                    Text(graded.gradeString)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background((graded.isAAAA ? Color.green : Color.orange).gradient, in: Capsule())
                        .help("Static grades (Coverage · Bulk · Safety · Consistency)")
                }
            }
        }
    }

}

// MARK: - IV text field row
