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
                        memberCell(member, isLead: index == 0)
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

    private func memberCell(_ member: TeamFinder.RankedTeam.Member, isLead: Bool) -> some View {
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
