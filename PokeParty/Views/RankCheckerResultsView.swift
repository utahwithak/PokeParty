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
    @Bindable var model: RankCheckerModel

    private var family: [Pokemon] {
        guard let id = model.selectedSpeciesId else { return [] }
        return store.familyIncludingMegas(for: id)
    }

    var body: some View {
        if let id = model.selectedSpeciesId, let selected = store.pokemonById[id] {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(for: selected)
                    // The wide table is ~550pt; narrower panes (iPhone) get stacked cards instead.
                    ViewThatFits(in: .horizontal) {
                        grid
                        compactGrid
                    }
                    footnote
                }
                .padding(20)
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
        VStack(alignment: .leading, spacing: 12) {
            // Three fields side by side where they fit; two rows on a phone.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    IVField(label: "ATK", value: $model.atk, color: Theme.attack)
                    IVField(label: "DEF", value: $model.def, color: Theme.defense)
                    IVField(label: "HP", value: $model.hp, color: Theme.hp)
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 16) {
                        IVField(label: "ATK", value: $model.atk, color: Theme.attack)
                        IVField(label: "DEF", value: $model.def, color: Theme.defense)
                    }
                    IVField(label: "HP", value: $model.hp, color: Theme.hp)
                }
            }

            HStack(spacing: 8) {
                Text("Level Cap")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("Level Cap", selection: $model.levelCap) {
                    Text("40").tag(40.0)
                    Text("41").tag(41.0)
                    Text("50").tag(50.0)
                    Text("51").tag(51.0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 220)
            }

            levelControls(for: selected)

            Text("Ranks below are for this IV spread across the whole \(selected.speciesName) family.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Level and CP are two views of the same value for the selected Pokémon at
    /// the entered IVs: editing either one updates the other. This is a calculator only; it doesn't change the ranks.
    private func levelControls(for selected: Pokemon) -> some View {
        let base = selected.baseStats
        let cp: (Double) -> Int = { level in
            IVCalculator.cpm(forLevel: level).map {
                IVCalculator.cp(baseAtk: base.atk, baseDef: base.def, baseHp: base.hp, ivs: model.ivs, cpm: $0)
            } ?? 10
        }
        let levelBinding = Binding<Double>(
            get: { model.effectiveManualLevel },
            set: { model.manualLevel = $0 })
        let cpBinding = Binding<Int>(
            get: { cp(model.effectiveManualLevel) },
            set: { target in
                if let level = IVCalculator.level(
                    baseAtk: base.atk, baseDef: base.def, baseHp: base.hp,
                    ivs: model.ivs, targetCP: target, levelCap: model.levelCap) {
                    model.manualLevel = level
                }
            })

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                labeledField("Level", width: 56) {
                    TextField("Level", value: levelBinding, format: .number.precision(.fractionLength(0...1)))
                }
                labeledField("CP", width: 64) {
                    TextField("CP", value: cpBinding, format: .number.grouping(.never))
                }
            }
        }
    }

    private func labeledField<Field: View>(_ label: String, width: CGFloat, @ViewBuilder field: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            field()
                .labelsHidden()
                .frame(width: width)
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
        }
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

    /// Phone layout: league labels once on top, then one card row per family
    /// member with its four league cells sharing the width equally.
    private var compactGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(CheckLeague.allCases) { league in
                    Text(league.short)
                        .font(.caption.weight(.bold))
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(family) { pokemon in
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(pokemon.speciesName)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        TypeBadgeRow(types: pokemon.displayTypes)
                    }
                    HStack(spacing: 4) {
                        ForEach(CheckLeague.allCases) { league in
                            cell(for: pokemon, league: league)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func cell(for pokemon: Pokemon, league: CheckLeague) -> some View {
        if let result = IVRankCache.rank(
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
                Text("SP " + (result.combo.statProduct / 1000).formatted(.number.precision(.fractionLength(0)).grouping(.never)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("L\(result.combo.level.formatted()) · \(result.combo.cp)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .help(rankTooltip(result, league: league))
            .contentShape(Rectangle())
            .contextMenu {
                let best = result.best.ivs
                Button("Maximize IVs for \(league.title) (\(best.atk)/\(best.def)/\(best.hp))") {
                    model.atk = best.atk
                    model.def = best.def
                    model.hp = best.hp
                }
                .disabled(best == model.ivs)
            }
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
        Stat product \(Int(result.combo.statProduct).formatted()) (best \(Int(result.best.statProduct).formatted()))
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
        Text("Rank is by stat product at level \(model.levelCap.formatted()) or below, against all 4096 IV combinations. Each cell shows rank, stat-product %, stat product (in thousands), and the resulting level · CP. In Master League the highest IVs always rank #1.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 460, alignment: .leading)
    }
}

/// A labeled IV entry with a text field and +/- buttons, clamped to 0–15.
private struct IVField: View {
    let label: String
    @Binding var value: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(color)
            HStack(spacing: 4) {
                TextField(label, value: $value, format: .number)
                    .labelsHidden()
                    .frame(width: 40)
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                Stepper(label, value: $value, in: 0...15)
                    .labelsHidden()
            }
        }
    }
}
