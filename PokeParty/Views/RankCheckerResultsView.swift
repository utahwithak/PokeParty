//
//  RankCheckerResultsView.swift
//  PokeParty
//
//  Detail column for the Rank Checker: shows IV rank & stat-product % for the
//  selected Pokémon's whole evolution family across LL / GL / UL / ML.
//

import SwiftUI

struct RankCheckerResultsView: View {
    var store: RankingsStore
    var model: RankCheckerModel

    private var family: [Pokemon] {
        guard let id = model.selectedSpeciesId else { return [] }
        return store.family(for: id)
    }

    var body: some View {
        if let id = model.selectedSpeciesId, let selected = store.pokemonById[id] {
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 16) {
                    header(for: selected)
                    grid
                    footnote
                }
                .padding()
            }
            .navigationTitle("\(selected.speciesName) · \(model.atk)/\(model.def)/\(model.hp)")
            .inlineNavigationTitle()
        } else {
            ContentUnavailableView(
                "Check Your IVs",
                systemImage: "checklist",
                description: Text("Enter your IVs and pick a Pokémon to see its rank and stat-product % across every league.")
            )
        }
    }

    // MARK: - Header

    private func header(for selected: Pokemon) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("IVs")
                .font(.headline)
            HStack(spacing: 8) {
                ivChip("ATK", model.atk, Theme.attack)
                ivChip("DEF", model.def, Theme.defense)
                ivChip("HP", model.hp, Theme.hp)
            }
            Text("Ranks below are for this IV spread across the whole \(selected.speciesName) family.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func ivChip(_ label: String, _ value: Int, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.85))
            Text("\(value)").font(.callout.weight(.bold).monospacedDigit()).foregroundStyle(.white)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(color, in: Capsule())
    }

    // MARK: - Grid

    private let nameColumnWidth: CGFloat = 150
    private let leagueColumnWidth: CGFloat = 82

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 12) {
            GridRow {
                Text("Pokémon")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: nameColumnWidth, alignment: .leading)
                    .gridColumnAlignment(.leading)
                ForEach(CheckLeague.allCases) { league in
                    Text(league.short)
                        .font(.caption.weight(.bold))
                        .frame(width: leagueColumnWidth)
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
                    .frame(width: nameColumnWidth, alignment: .leading)

                    ForEach(CheckLeague.allCases) { league in
                        cell(for: pokemon, league: league)
                            .frame(width: leagueColumnWidth)
                    }
                }
                if pokemon.id != family.last?.id {
                    Divider()
                }
            }
        }
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func cell(for pokemon: Pokemon, league: CheckLeague) -> some View {
        if let result = IVCalculator.rank(
            baseAtk: pokemon.baseStats.atk,
            baseDef: pokemon.baseStats.def,
            baseHp: pokemon.baseStats.hp,
            cpCap: league.cap,
            ivs: model.ivs,
            levelCap: model.levelCap
        ) {
            VStack(spacing: 2) {
                Text("#" + result.rank.formatted(.number.grouping(.never)))
                    .font(.callout.weight(.bold).monospacedDigit())
                    .lineLimit(1)
                Text(result.percent, format: .number.precision(.fractionLength(1)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(percentColor(result.percent))
                Text("L\(result.combo.level.formatted()) · \(result.combo.cp)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .help(rankTooltip(result, league: league))
        } else {
            Text("—")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .help("Can't reach this league's CP cap with these IVs.")
        }
    }

    private func rankTooltip(_ result: IVCalculator.RankResult, league: CheckLeague) -> String {
        let best = result.best.ivs
        return """
        \(league.title) League
        Rank \(result.rank) of \(result.total) · \(String(format: "%.1f", result.percent))%
        Level \(result.combo.level.formatted()) · \(result.combo.cp) CP
        Best IVs: \(best.atk)/\(best.def)/\(best.hp)
        """
    }

    private func percentColor(_ percent: Double) -> Color {
        switch percent {
        case 99...: Theme.win
        case 97..<99: .teal
        case 95..<97: .orange
        default: .secondary
        }
    }

    private var footnote: some View {
        Text("Rank is by stat product at level \(model.levelCap.formatted()) or below, against all 4096 IV combinations. Each cell shows rank, stat-product %, and the resulting level · CP. In Master League the highest IVs always rank #1.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 460, alignment: .leading)
    }
}
