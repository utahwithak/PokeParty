//
//  IVLeagueGridView.swift
//  PokeParty
//
//  Multi-league IV rank grid for an evolution family: for each member, shows
//  its rank/percentile/level+CP under each league's cap for a given IV
//  spread. Shared by the Scan tool (staging a bench pick from a live scan)
//  and the Bench detail view (assigning a league to an unclassified entry).
//

import SwiftUI

struct IVLeagueGridView: View {
    let family: [Pokemon]
    let ivs: IVs
    /// The Pokémon's actual current level (from a scan), used to compute
    /// "now" CP/eligibility badges. nil hides those badges.
    var currentLevel: Double? = nil
    /// Highlights one (species, league) cell, e.g. the currently staged pick.
    var selected: (speciesId: String, league: CheckLeague)? = nil
    /// Called when a cell is tapped; nil makes the grid read-only.
    var onSelect: ((Pokemon, CheckLeague) -> Void)? = nil

    private let leagues: [CheckLeague] = [.great, .ultra, .master]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 12) {
            GridRow {
                Text("Pokémon")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 160, alignment: .leading)
                    .gridColumnAlignment(.leading)
                ForEach(leagues, id: \.self) { league in
                    Text(league.short)
                        .font(.caption.weight(.bold))
                        .frame(width: 90)
                        .gridColumnAlignment(.center)
                }
            }
            Divider()
            ForEach(family) { pokemon in
                GridRow {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(pokemon.speciesName)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        TypeBadgeRow(types: pokemon.displayTypes)
                    }
                    .frame(width: 160, alignment: .leading)

                    ForEach(leagues, id: \.self) { league in
                        cell(for: pokemon, league: league)
                            .frame(width: 90)
                    }
                }
                if pokemon.id != family.last?.id { Divider() }
            }
        }
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func cell(for pokemon: Pokemon, league: CheckLeague) -> some View {
        let isSelected = selected?.speciesId == pokemon.speciesId && selected?.league == league
        Group {
            if let onSelect {
                Button { onSelect(pokemon, league) } label: { rankCell(for: pokemon, league: league) }
                    .buttonStyle(.plain)
            } else {
                rankCell(for: pokemon, league: league)
            }
        }
        .background(isSelected ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func rankCell(for pokemon: Pokemon, league: CheckLeague) -> some View {
        let nowCP = currentLevel.flatMap { cp(for: pokemon, at: $0) }
        let nowFits = nowCP.map { $0 <= league.cap }
        let result = IVCalculator.rank(
            baseAtk: pokemon.baseStats.atk,
            baseDef: pokemon.baseStats.def,
            baseHp: pokemon.baseStats.hp,
            cpCap: league.cap,
            ivs: ivs
        )
        let badge = result.flatMap { badge(rank: $0.rank, percent: $0.percent) }

        // If we know the Pokémon's actual current level and it's already over
        // this league's cap, the rank/%/level numbers below describe a build
        // that can't be reached (you can't power a Pokémon down), so showing
        // them next to a red "over cap" marker is misleading. Show just the
        // over-cap marker and the real current CP instead.
        if let cp = nowCP, nowFits == false {
            VStack(spacing: 2) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.red)
                Text("\(cp)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color.red)
            }
            .padding(6)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
            .help("Over \(league.title) League cap now (CP \(cp) > \(league.cap))")
        } else {
            VStack(spacing: 2) {
                if let result {
                    HStack(spacing: 3) {
                        Text("#" + result.rank.formatted(.number.grouping(.never)))
                            .font(.callout.weight(.bold).monospacedDigit())
                            .lineLimit(1)
                        if let badge {
                            Image(systemName: badge.icon)
                                .font(.system(size: 9))
                                .foregroundStyle(badge.color)
                        }
                    }
                    Text(String(format: "%.1f%%", result.percent))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(percentColor(result.percent))
                    Text("L\(result.combo.level.formatted()) · \(result.combo.cp)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else {
                    Text("—")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }

                // Current-level eligibility badge — shows this form already
                // fits under the cap right now without any powering up.
                if let cp = nowCP {
                    HStack(spacing: 2) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.green)
                        Text("now \(cp)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Color.gray)
                    }
                    .help("Eligible for \(league.title) League now (CP \(cp) ≤ \(league.cap))")
                }
            }
            .padding(6)
            .background(badgeBackground(badge), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
    }

    /// A quick-glance marker for standout IV ranks: a gold crown for the
    /// #1 spot (100%), hearts in decreasing warmth for the next tiers.
    private struct RankBadge {
        let icon: String
        let color: Color
    }

    private func badge(rank: Int, percent: Double) -> RankBadge? {
        if rank == 1 { return RankBadge(icon: "crown.fill", color: .yellow) }
        switch percent {
        case 99..<100: return RankBadge(icon: "heart.fill", color: .pink)
        case 97..<99: return RankBadge(icon: "heart.fill", color: .teal)
        case 95..<97: return RankBadge(icon: "heart.fill", color: .orange)
        default: return nil
        }
    }

    private func badgeBackground(_ badge: RankBadge?) -> Color {
        guard let badge else { return .clear }
        return badge.color.opacity(badge.icon == "crown.fill" ? 0.22 : 0.12)
    }

    private func cp(for pokemon: Pokemon, at level: Double) -> Int? {
        guard let cpm = IVCalculator.cpm(forLevel: level) else { return nil }
        return IVCalculator.cp(
            baseAtk: pokemon.baseStats.atk, baseDef: pokemon.baseStats.def, baseHp: pokemon.baseStats.hp,
            ivs: ivs, cpm: cpm)
    }

    private func percentColor(_ percent: Double) -> Color {
        switch percent {
        case 99...: Theme.win
        case 97..<99: .teal
        case 95..<97: .orange
        default: .secondary
        }
    }
}
