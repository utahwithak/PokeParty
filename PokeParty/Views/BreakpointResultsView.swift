//
//  BreakpointResultsView.swift
//  PokeParty
//
//  Detail panel of the Breakpoints tool: runs the IV-grid analysis for the
//  chosen Pokémon and presents minimum viable IVs, per-stat breakpoints and
//  matchup flips against the Master League meta.
//

import SwiftUI

struct BreakpointResultsView: View {
    var store: RankingsStore
    var model: BreakpointModel

    var body: some View {
        Group {
            if model.member != nil {
                resultsList
            } else {
                ContentUnavailableView(
                    "Select a Pokémon",
                    systemImage: "stairs",
                    description: Text("Choose a Pokémon to see where its IVs change Master League matchups.")
                )
            }
        }
        .navigationTitle("Breakpoints")
        .inlineNavigationTitle()
    }

    /// Re-runs the analysis whenever the subject or its moveset changes.
    private var analysisKey: String {
        guard let m = model.member else { return "" }
        return "\(m.speciesId)|\(m.fastMoveId)|\(m.chargedMoveIds.joined(separator: ","))"
    }

    private var resultsList: some View {
        List {
            if let member = model.member,
               let species = store.pokemonById[member.speciesId] {
                movesetSection(member: member, species: species)
            }
            if let report = model.report {
                headerSection(report)
                minimumSection(report)
                levelSection(report)
                ForEach(report.insights) { insight in
                    statSection(insight)
                }
                stableSection(report)
            } else if let error = model.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Simulating the IV grid against the top \(BreakpointModel.opponentCount) Master League Pokémon…")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .task(id: analysisKey) { model.analyze(using: store) }
    }

    // MARK: - Sections

    private func movesetSection(member: TeamMember, species: Pokemon) -> some View {
        Section("Moveset") {
            TeamMovePicker(
                label: "Fast",
                currentId: member.fastMoveId,
                optionIds: species.fastMoves,
                recommendedId: model.recommendedMoveset.first,
                includesNone: false,
                species: species,
                store: store,
                onSelect: { if let id = $0 { model.setFastMove(id) } })
            TeamMovePicker(
                label: "Charged 1",
                currentId: member.chargedMoveIds.first ?? "",
                optionIds: species.chargedMoves,
                recommendedId: model.recommendedMoveset.count > 1 ? model.recommendedMoveset[1] : nil,
                includesNone: false,
                species: species,
                store: store,
                onSelect: { if let id = $0 { model.setChargedMove(id, slot: 0) } })
            TeamMovePicker(
                label: "Charged 2",
                currentId: member.chargedMoveIds.count > 1 ? member.chargedMoveIds[1] : "",
                optionIds: species.chargedMoves,
                recommendedId: model.recommendedMoveset.count > 2 ? model.recommendedMoveset[2] : nil,
                includesNone: true,
                species: species,
                store: store,
                onSelect: { model.setChargedMove($0, slot: 1) })
        }
    }

    private func headerSection(_ report: BreakpointAnalyzer.Report) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(report.subjectName)
                    .font(.title2.bold())
                Text("Level \(report.level.formatted()) · CP \(report.heroCP) at 15/15/15 · \(report.fastMoveName) + \(report.chargedMoveNames.joined(separator: " / "))")
                    .foregroundStyle(.secondary)
                Text("IVs 12–15 per stat, simulated against the top \(report.opponentNames.count) Master League Pokémon at 0, 1 and 2 shields each (\(report.totalMatchups) matchups per spread).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private func minimumSection(_ report: BreakpointAnalyzer.Report) -> some View {
        Section("Minimum viable IVs") {
            HStack(spacing: 24) {
                statPill("Attack", minimum: report.minViable.atk)
                statPill("Defense", minimum: report.minViable.def)
                statPill("HP", minimum: report.minViable.hp)
            }
            .padding(.vertical, 4)

            if report.combinedHolds {
                Text("A \(spreadText(report.minViable)) (or better) performs identically to a 15/15/15 in every simulated matchup.")
            } else {
                Text("These minimums interact — combined, the lowest spread that matches a 15/15/15 everywhere is \(spreadText(report.lowestSafeSpread)).")
            }

            Text(report.worstCaseChanges == 0
                 ? "Even a 12/12/12 changes nothing against this meta."
                 : "A 12/12/12 changes \(report.worstCaseChanges) of \(report.totalMatchups) outcomes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func levelSection(_ report: BreakpointAnalyzer.Report) -> some View {
        Section("Power-up levels — 15/15/15 vs the level-50 meta") {
            if report.levelInsights.isEmpty {
                Text("No matchup changes between level 20 and 50 — leveling past 20 doesn't flip anything against this meta.")
                    .foregroundStyle(.secondary)
            } else {
                levelLegend(report.levels)
                ForEach(report.levelInsights) { insight in
                    levelRow(insight)
                }
            }
            if !report.alwaysWins.isEmpty {
                Text("Wins even at level 20: \(report.alwaysWins.joined(separator: ", ")).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !report.alwaysLosses.isEmpty {
                Text("Loses even at level 50: \(report.alwaysLosses.joined(separator: ", ")).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func levelLegend(_ levels: [Double]) -> some View {
        HStack {
            Text("Outcome by level")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 0) {
                ForEach(levels, id: \.self) { level in
                    Text(level.formatted())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 22)
                }
            }
        }
    }

    private func levelRow(_ insight: BreakpointAnalyzer.LevelInsight) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("vs \(insight.opponentName)")
            ForEach(insight.scenarios) { scenario in
                HStack {
                    Label("\(scenario.shields)", systemImage: "shield.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .leading)
                        .help("\(scenario.shields) shield\(scenario.shields == 1 ? "" : "s") each")
                    Text(scenario.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 0) {
                        ForEach(scenario.outcomes.indices, id: \.self) { i in
                            Circle()
                                .fill(color(for: scenario.outcomes[i]))
                                .frame(width: 8, height: 8)
                                .frame(width: 22)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func statSection(_ insight: BreakpointAnalyzer.StatInsight) -> some View {
        Section("\(insight.stat.rawValue) IV") {
            LabeledContent(insight.stat == .hp ? "HP at IV 12–15" : "Effective \(insight.stat.rawValue.lowercased()) at IV 12–15") {
                Text(insight.statValues
                    .map { insight.stat == .hp ? String(Int($0)) : String(format: "%.1f", $0) }
                    .joined(separator: " · "))
                    .monospacedDigit()
            }

            if insight.changes.isEmpty && insight.damageSteps.isEmpty {
                Text("Doesn't matter here — IV 12–15 changes no matchup or fast-move damage against this meta.")
                    .foregroundStyle(.secondary)
            }

            ForEach(insight.changes) { change in
                changeRow(change)
            }
            ForEach(insight.damageSteps) { step in
                damageRow(step)
            }
        }
    }

    private func stableSection(_ report: BreakpointAnalyzer.Report) -> some View {
        Section("Unaffected matchups") {
            if report.unaffectedOpponents.isEmpty {
                Text("Every one of the top \(report.opponentNames.count) matchups shifts somewhere in the IV grid.")
                    .foregroundStyle(.secondary)
            } else {
                Text("IVs never change the result against: \(report.unaffectedOpponents.joined(separator: ", ")).")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Rows

    private func statPill(_ label: String, minimum: Int) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(minimum == 15 ? "15 only" : "≥ \(minimum)")
                .font(.title3.bold())
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    private func changeRow(_ change: BreakpointAnalyzer.MatchupChange) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("vs \(change.opponentName)")
                Text("\(change.shields) shield\(change.shields == 1 ? "" : "s") each")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(change.from.rawValue) → \(change.to.rawValue) at IV \(change.below)")
                .font(.callout.weight(.medium))
                .foregroundStyle(color(for: change.to))
        }
    }

    private func damageRow(_ step: BreakpointAnalyzer.DamageStep) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(step.dealt
                     ? "\(step.moveName) vs \(step.opponentName)"
                     : "\(step.opponentName)'s \(step.moveName)")
                Text(step.dealt ? "Damage dealt at IV 12–15" : "Damage taken at IV 12–15")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(step.values.map(String.init).joined(separator: " · "))
                .font(.callout.weight(.medium))
                .monospacedDigit()
        }
    }

    // MARK: - Formatting

    private func spreadText(_ ivs: IVs) -> String {
        "\(ivs.atk)/\(ivs.def)/\(ivs.hp)"
    }

    private func color(for outcome: BreakpointAnalyzer.Outcome) -> Color {
        switch outcome {
        case .win: .green
        case .tie: .orange
        case .loss: .red
        }
    }
}
