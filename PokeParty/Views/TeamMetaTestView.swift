//
//  TeamMetaTestView.swift
//  PokeParty
//
//  "Test Against Meta": battles the Team Builder's current team against a
//  randomly generated field of meta-team opponents using the full 3v3 engine
//  (real switching and shielding AI, not a static grade check), reporting
//  which lead performs best and which opponents it beats/loses to.
//  Switch/stay guidance reuses the Team Builder's existing 1v1 threat grid,
//  filtered to the opposing leads this run actually generated.
//

import SwiftUI

struct TeamMetaTestView: View {
    var store: RankingsStore
    var teamBuilder: TeamBuilderModel
    @Bindable var model: TeamMetaTestModel
    @Environment(\.dismiss) private var dismiss
    @State private var resultFilter: ResultFilter = .all

    private enum ResultFilter: String, CaseIterable, Identifiable {
        case all = "All", wins = "Wins", losses = "Losses"
        var id: Self { self }
    }

    /// Opponent rows are capped for render performance — win-rate stats above
    /// still reflect every battled opponent, not just the ones shown.
    private static let maxDisplayedOpponents = 200

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    controls
                    resultsContent
                }
                .padding(20)
            }
            .navigationTitle("Test Against Meta")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 640)
        #endif
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Opponent pool")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("Top ranked Pokémon", selection: $model.poolSize) {
                    ForEach(TeamMetaTestModel.poolSizes, id: \.self) { size in
                        Text("Top \(size)").tag(size)
                    }
                }
                .labelsHidden()
                .disabled(model.isRunning)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                Slider(
                    value: Binding(
                        get: { Double(model.fieldSize) },
                        set: { model.fieldSize = Int($0) }),
                    in: TeamMetaTestModel.fieldSizeRange,
                    step: TeamMetaTestModel.fieldSizeStep
                ) {
                    Text("Field size")
                }
                .disabled(model.isRunning)
                Text("\(model.fieldSize) randomly generated opponent teams, battled against each of your leads with realistic switching/shielding AI")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.isRunning {
                VStack(alignment: .leading, spacing: 8) {
                    if model.phase == .loadingRankings {
                        ProgressView("Loading rankings…")
                    } else if let results = model.results, results.total > 0 {
                        ProgressView(value: Double(results.completed), total: Double(results.total)) {
                            Text("\(results.completed) of \(results.total) opponents battled")
                        }
                    } else {
                        ProgressView(value: model.progress) {
                            Text("Building opponent field…")
                        }
                    }
                    Button("Cancel", role: .cancel) { model.cancel() }
                }
            } else {
                Button {
                    model.run(team: teamBuilder.members, using: store)
                } label: {
                    Label("Run Test", systemImage: "bolt.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!teamBuilder.hasMembers)
            }

            if case .failed(let message) = model.phase {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsContent: some View {
        if let results = model.results, !results.opponents.isEmpty {
            Divider()
            summarySection(results)
            if !encounteredThreats.isEmpty {
                Divider()
                switchStaySection
            }
            Divider()
            opponentListSection(results)
        } else if !model.isRunning {
            ContentUnavailableView(
                "Test Against Meta",
                systemImage: "bolt.fill",
                description: Text("Battles your current team against a randomly generated field of meta teams — with real switching and shielding, not a static grade check — and shows which lead wins, which opponents you beat, and which you lose to.")
            )
            .frame(maxWidth: .infinity, minHeight: 160)
        }
    }

    // MARK: - Best lead summary

    private func summarySection(_ results: MetaFieldTester.Results) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Best Lead")
                .font(.title3.weight(.semibold))
            HStack(spacing: 12) {
                ForEach(Array(teamBuilder.members.enumerated()), id: \.offset) { index, member in
                    leadCard(index: index, member: member, results: results)
                }
            }
        }
    }

    private func leadCard(index: Int, member: TeamMember, results: MetaFieldTester.Results) -> some View {
        let winRate = results.winRate(forLead: index)
        let isBest = results.bestLead == index
        return VStack(spacing: 4) {
            Text(store.pokemonById[member.speciesId]?.speciesName ?? member.speciesId)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("\(Int((winRate * 100).rounded()))%")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(winRate >= 0.5 ? Theme.win : Theme.loss)
            Text("win rate")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            (isBest ? Color.accentColor : Color.primary).opacity(isBest ? 0.15 : 0.05),
            in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isBest ? Color.accentColor : .clear, lineWidth: 2)
        )
    }

    // MARK: - Switch / stay

    /// The Team Builder's existing 1v1 threat grid, filtered to species that
    /// actually showed up as an opposing lead in this run's generated field.
    private var encounteredThreats: [ThreatEntry] {
        guard let analysis = teamBuilder.analysis else { return [] }
        let seen = model.encounteredLeadSpeciesIds
        return analysis.threats.filter { seen.contains($0.speciesId) }
    }

    private var switchStaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Switch / Stay")
                .font(.title3.weight(.semibold))
            Text("1v1 ratings against the opposing leads this run actually generated — a bad rating means switch out, a good one means stay in.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text("Opposing Lead").frame(maxWidth: .infinity, alignment: .leading)
                ForEach(Array((teamBuilder.analysis?.memberNames ?? []).enumerated()), id: \.offset) { _, name in
                    Text(name)
                        .frame(width: 56)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)

            ForEach(encounteredThreats) { threat in
                ThreatRow(threat: threat)
            }
        }
    }

    // MARK: - Opponent list

    private func opponentListSection(_ results: MetaFieldTester.Results) -> some View {
        let lead = results.bestLead ?? 0
        let opponents = filteredOpponents(results, lead: lead)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Opponents (\(results.opponents.count) battled)")
                    .font(.title3.weight(.semibold))
                Spacer()
                Picker("Filter", selection: $resultFilter) {
                    ForEach(ResultFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }

            if opponents.isEmpty {
                Text("No opponents match this filter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(opponents.prefix(Self.maxDisplayedOpponents).enumerated()), id: \.element.id) { index, opponent in
                TeamResultRow(
                    rank: index + 1,
                    members: opponent.members.enumerated().map { i, m in
                        TeamResultMember(speciesName: m.speciesName, types: m.types, shadow: m.shadow, isLead: i == 0)
                    }
                ) {
                    HStack(spacing: 6) {
                        outcomeBadge(opponent.outcomesByLead[lead])
                        Text("Rating \(opponent.ratingByLead[lead])")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if opponents.count > Self.maxDisplayedOpponents {
                Text("Showing the first \(Self.maxDisplayedOpponents) of \(opponents.count).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func filteredOpponents(_ results: MetaFieldTester.Results, lead: Int) -> [MetaFieldTester.OpponentResult] {
        switch resultFilter {
        case .all:
            return results.opponents
        case .wins:
            return results.opponents.filter { $0.outcomesByLead.indices.contains(lead) && $0.outcomesByLead[lead] == .teamA }
        case .losses:
            return results.opponents.filter { $0.outcomesByLead.indices.contains(lead) && $0.outcomesByLead[lead] == .teamB }
        }
    }

    private func outcomeBadge(_ winner: TeamBattleResult.Winner) -> some View {
        let label: String
        let color: Color
        switch winner {
        case .teamA: label = "WIN"; color = Theme.win
        case .teamB: label = "LOSS"; color = Theme.loss
        case .tie: label = "TIE"; color = .secondary
        }
        return Text(label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color, in: Capsule())
    }
}
