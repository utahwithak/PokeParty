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
                     : "Round \(standings.round) of \(standings.totalRounds)")
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
        HStack(alignment: .center, spacing: 12) {
            Text("#\(rank)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
                .contentTransition(.numericText())

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    ForEach(Array(team.members.enumerated()), id: \.offset) { index, member in
                        TeamMemberCell(member: member, isLead: index == 0)
                    }
                }
                record
            }

            Spacer()

            Button("Open in Team Builder", action: openInBuilder)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
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
            }
        }
    }

}

/// A member of a suggested team: name, shadow flame, lead marker and types.
/// Shared by the tournament leaderboard and the AAAA grade-check list.
private struct TeamMemberCell: View {
    let member: TeamFinder.RankedTeam.Member
    let isLead: Bool

    var body: some View {
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
        HStack(alignment: .center, spacing: 12) {
            Text("#\(rank)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    ForEach(Array(team.members.enumerated()), id: \.offset) { index, member in
                        TeamMemberCell(member: member, isLead: index == 0)
                    }
                }
                gradeLine
            }

            Spacer()

            Button("Open in Team Builder", action: openInBuilder)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
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
