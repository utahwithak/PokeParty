//
//  TeamFinderSimulationView.swift
//  PokeParty
//
//  The Party Finder's live tournament: a header summarizing the run (round,
//  battles fought, field size) above an animated leaderboard. Rows reorder
//  as round-robin records accumulate and teams fade off the bottom as they
//  fall out of the top 100 — the same view doubles as the final results once
//  the tournament completes (or when a saved tournament is reopened).
//

import SwiftUI

struct TeamFinderSimulationView: View {
    let standings: TeamFinder.Standings
    /// The format and pool size the run was started with (for the caption).
    let format: RankingFormat?
    let poolSize: Int
    let openInBuilder: (TeamFinder.RankedTeam) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding()
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(standings.teams.enumerated()), id: \.element.id) { index, team in
                        LeaderboardRow(rank: index + 1, team: team) {
                            openInBuilder(team)
                        }
                        .transition(.asymmetric(
                            insertion: .opacity,
                            removal: .opacity.combined(with: .move(edge: .trailing))))
                    }
                }
                .padding(.vertical, 4)
                .animation(.spring(duration: 0.6), value: standings.teams.map(\.id))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(standings.isComplete
                     ? "Tournament complete"
                     : "Round \(standings.round + 1) of \(standings.totalRounds + 1)")
                    .font(.headline)
                    .contentTransition(.numericText())
                Spacer()
                Text("\(standings.battlesFought.formatted()) battles")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            if !standings.isComplete {
                ProgressView(
                    value: Double(standings.battlesFought),
                    total: Double(max(standings.totalBattles, 1)))
                    .progressViewStyle(.linear)
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var caption: String {
        let league = format.map { "\($0.title) — " } ?? ""
        let field = "a full round robin between the \(standings.totalEntrants) most promising teams from the top \(poolSize) ranked Pokémon"
        if standings.isComplete {
            return "\(league)final standings of \(field): every record is measured against the entire field. The first member is the lead."
        }
        return "\(league)\(field). Every team battles every other team, so records compare fairly at any moment — teams slide off as stronger records emerge."
    }
}

/// One leaderboard entry: rank, the three members (lead first), and the
/// accumulated round-robin record.
private struct LeaderboardRow: View {
    let rank: Int
    let team: TeamFinder.RankedTeam
    let openInBuilder: () -> Void

    var body: some View {
        TeamResultRow(
            rank: rank,
            members: team.members.enumerated().map { index, member in
                TeamResultMember(speciesName: member.speciesName, types: member.types,
                                  shadow: member.shadow, isLead: index == 0)
            },
            onOpenInBuilder: openInBuilder,
            record: { record }
        )
    }

    @ViewBuilder
    private var record: some View {
        if team.gamesPlayed == 0 {
            Text("Seeded — awaiting first battles")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 8) {
                Text(team.winRate, format: .percent.precision(.fractionLength(0)))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText())
                Text("\(team.wins)W · \(team.losses)L\(team.ties > 0 ? " · \(team.ties)T" : "") over \(team.gamesPlayed)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                RatingBar(rating: Int(team.averageRating.rounded()))
                    .frame(maxWidth: 160)
                if let metaScore = team.metaScore {
                    Text("vs meta \(metaScore, format: .percent.precision(.fractionLength(1)))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(metaScore >= 0.5 ? Theme.win : Theme.loss)
                        .help("Expected score against the Nash-equilibrium meta of the top teams — no credit for farming weak teams.")
                }
                if (team.equilibriumWeight ?? 0) >= 0.02 {
                    Text("META CORE")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.15), in: Capsule())
                        .foregroundStyle(.tint)
                        .help("Part of the equilibrium meta: no top team exploits this one under strong play.")
                }
            }
        }
    }

}

// MARK: - AI Optimizer results

/// The optimizer's live results: teams ranked by expected meta score, updating
/// as each hill-climbing restart converges.
struct OptimizerResultsView: View {
    let results: TeamOptimizer.Results
    let format: RankingFormat?
    let poolSize: Int
    let movesById: [String: Move]
    let model: TeamFinderModel
    let openInBuilder: (TeamOptimizer.OptimizedTeam) -> Void

    /// Broad-field win rate re-sorts the list once a validation pass has
    /// produced any results; otherwise the curated meta-field ranking stands.
    private var displayedTeams: [TeamOptimizer.OptimizedTeam] {
        model.broadFieldResults?.teams ?? results.teams
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding()
            Divider()
            if results.isComplete {
                broadFieldBar
                    .padding()
                Divider()
            }
            if results.teams.isEmpty {
                ContentUnavailableView(
                    "Searching…",
                    systemImage: "wand.and.stars",
                    description: Text("Teams appear as climbers converge."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(displayedTeams.enumerated()), id: \.element.id) { index, team in
                            OptimizerTeamRow(rank: index + 1, team: team, movesById: movesById) {
                                openInBuilder(team)
                            }
                            .transition(.asymmetric(
                                insertion: .opacity,
                                removal: .opacity.combined(with: .move(edge: .trailing))))
                        }
                    }
                    .padding(.vertical, 4)
                    .animation(.spring(duration: 0.6), value: displayedTeams.map(\.id))
                }
            }
        }
    }

    @ViewBuilder
    private var broadFieldBar: some View {
        if model.isValidatingBroadField {
            VStack(alignment: .leading, spacing: 6) {
                if let broad = model.broadFieldResults, broad.completedTeams > 0 {
                    ProgressView(
                        value: Double(broad.completedTeams),
                        total: Double(max(broad.totalTeams, 1))
                    ) {
                        Text("Validated \(broad.completedTeams) of \(broad.totalTeams) teams vs \(broad.fieldSize.formatted()) random meta teams")
                    }
                } else {
                    ProgressView("Sampling a random meta field…")
                }
                Button("Cancel", role: .cancel) { model.cancelBroadFieldValidation() }
            }
        } else if let broad = model.broadFieldResults, broad.isComplete {
            HStack {
                Text("Validated against \(broad.fieldSize.formatted()) random meta teams")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Re-validate") { model.validateAgainstBroadField(movesById: movesById) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        } else if model.canValidateAgainstBroadField {
            HStack {
                Text("Curated meta field win rates cluster near 50% by design — validate against a much larger random sample to see which result really holds up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Validate vs Full Meta") { model.validateAgainstBroadField(movesById: movesById) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(results.isComplete
                     ? "Optimization complete"
                     : "\(results.completedClimbers) of \(results.totalClimbers) climbers converged")
                    .font(.headline)
                    .contentTransition(.numericText())
                Spacer()
                Text("\(results.teams.count) team\(results.teams.count == 1 ? "" : "s")")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            if !results.isComplete {
                if results.completedClimbers == 0 {
                    ProgressView()
                        .progressViewStyle(.linear)
                } else {
                    ProgressView(
                        value: Double(results.completedClimbers),
                        total: Double(max(results.totalClimbers, 1)))
                        .progressViewStyle(.linear)
                }
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var caption: String {
        let league = format.map { "\($0.title) — " } ?? ""
        let base = "top \(poolSize) ranked Pokémon including alternate movesets"
        if results.isComplete {
            return "\(league)best teams from \(results.totalClimbers) hill-climbs over the \(base), ranked by expected score vs the meta field. The first member is the lead."
        }
        return "\(league)hill-climbing the \(base); teams appear as each restart converges. The first member is the lead."
    }
}

private struct OptimizerTeamRow: View {
    let rank: Int
    let team: TeamOptimizer.OptimizedTeam
    let movesById: [String: Move]
    let openInBuilder: () -> Void

    var body: some View {
        TeamResultRow(
            rank: rank,
            members: team.members.enumerated().map { index, member in
                TeamResultMember(
                    speciesName: member.speciesName, types: member.types,
                    shadow: member.shadow, isLead: index == 0,
                    flag: member.isAlternateMoveset ? "ALT" : nil,
                    tooltip: movesetText(for: member))
            },
            onOpenInBuilder: openInBuilder,
            record: { scoreRow }
        )
    }

    private func movesetText(for member: TeamOptimizer.OptimizedTeam.Member) -> String {
        let fast = movesById[member.member.fastMoveId]?.name ?? member.member.fastMoveId
        let charged = member.member.chargedMoveIds
            .map { movesById[$0]?.name ?? $0 }
            .joined(separator: " · ")
        return "\(fast) / \(charged)"
    }

    private var scoreRow: some View {
        HStack(spacing: 8) {
            Text(team.metaScore, format: .percent.precision(.fractionLength(0)))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
                .help("Expected score vs the meta field (weighted win rate).")
            Text("\(team.wins)W · \(team.losses)L\(team.ties > 0 ? " · \(team.ties)T" : "") vs meta")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            if let broadWinRate = team.broadWinRate {
                Text("· \(broadWinRate, format: .percent.precision(.fractionLength(0))) vs \(team.broadGamesPlayed ?? 0) random")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(broadWinRate >= 0.5 ? Theme.win : Theme.loss)
                    .contentTransition(.numericText())
                    .help("Win rate against a much larger random sample of meta teams.")
            }
        }
    }
}

// MARK: - AAAA grade-check results

/// The grade-check results: every trio from the pool that the Team Builder's
/// static analysis grades A in Coverage, Bulk, Safety and Consistency.
struct GradedTeamsView: View {
    let teams: [GradeFinder.GradedTeam]
    /// The format and pool size the run was started with (for the caption).
    let format: RankingFormat?
    let poolSize: Int
    let openInBuilder: (GradeFinder.GradedTeam) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding()
            Divider()
            if teams.isEmpty {
                ContentUnavailableView(
                    "No Teams Graded",
                    systemImage: "wand.and.stars.inverse",
                    description: Text("The pool was too small to build any teams."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(displayedTeams.enumerated()), id: \.element.id) { index, team in
                            GradedTeamRow(rank: index + 1, team: team) {
                                openInBuilder(team)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    /// All AAAA teams when any exist; otherwise the best-available fallback.
    private var aaaaTeams: [GradeFinder.GradedTeam] { teams.filter(\.isAAAA) }
    private var displayedTeams: [GradeFinder.GradedTeam] { aaaaTeams.isEmpty ? teams : aaaaTeams }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(aaaaTeams.isEmpty
                     ? "No AAAA teams — best available grades"
                     : "\(aaaaTeams.count) AAAA team\(aaaaTeams.count == 1 ? "" : "s")")
                    .font(.headline)
                Spacer()
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var caption: String {
        let league = format.map { "\($0.title) — " } ?? ""
        let base = "\(league)every trio from the top \(poolSize) ranked Pokémon, graded with the Team Builder's static analysis (no battle simulations)."
        if aaaaTeams.isEmpty {
            return "\(base) No trio grades A in all of Coverage, Bulk, Safety and Consistency, so these are the teams whose worst grade is best. The first member is the lead."
        }
        return "\(base) Only teams graded A across the board are shown, best coverage first. The first member is the lead."
    }
}

/// One graded team: rank, members, its grades and the values behind them.
private struct GradedTeamRow: View {
    let rank: Int
    let team: GradeFinder.GradedTeam
    let openInBuilder: () -> Void

    var body: some View {
        TeamResultRow(
            rank: rank,
            members: team.members.enumerated().map { index, member in
                TeamResultMember(speciesName: member.speciesName, types: member.types,
                                  shadow: member.shadow, isLead: index == 0)
            },
            onOpenInBuilder: openInBuilder,
            record: { gradeLine }
        )
    }

    private var gradeLine: some View {
        HStack(spacing: 8) {
            Text(team.gradeString)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background((team.isAAAA ? Color.green : Color.orange).gradient, in: Capsule())
                .help("Coverage · Bulk · Safety · Consistency")
            Text("Threat score \(team.threatScore) · Bulk \(Int(team.bulkValue.rounded()).formatted()) · Safety \(Int(team.safetyValue.rounded())) · Consistency \(Int(team.consistencyValue.rounded()))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
