//
//  TeamAnalysisView.swift
//  PokeParty
//
//  Detail column of the 3v3 Team Builder: the four PvPoke-style grades
//  (Coverage / Bulk / Safety / Consistency), the team's threat score, the top
//  threats matrix, and suggested teammates. Mirrors pvpoke.com's Team Builder
//  output (plan Milestone 1).
//

import SwiftUI

struct TeamAnalysisView: View {
    var store: RankingsStore
    var model: TeamBuilderModel

    var body: some View {
        Group {
            if let analysis = model.analysis {
                results(analysis)
            } else if model.phase == .analyzing {
                ProgressView("Analyzing team…")
            } else {
                ContentUnavailableView(
                    "Build a Team",
                    systemImage: "person.3.sequence.fill",
                    description: Text("Add up to three Pokémon to see coverage, bulk, threats and suggested teammates for \(store.format.title)."))
            }
        }
        .navigationTitle("Team Analysis")
    }

    private func results(_ analysis: TeamAnalysis) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                gradesSection(analysis)
                threatsSection(analysis)
                suggestionsSection(analysis)
                AttributionFooter()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .top) {
            if model.phase == .analyzing {
                ProgressView().padding(6)
            }
        }
    }

    // MARK: - Grades

    private func gradesSection(_ analysis: TeamAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Team Grades")
                    .font(.title3.weight(.semibold))
                Spacer()
                threatScoreBadge(analysis.threatScore)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                GradeCard(title: "Coverage", grade: analysis.grades.coverage,
                          detail: "Threat \(analysis.threatScore)")
                GradeCard(title: "Bulk", grade: analysis.grades.bulk,
                          detail: bulkDetail(analysis.grades.bulkValue))
                GradeCard(title: "Safety", grade: analysis.grades.safety,
                          detail: analysis.grades.safetyProvisional ? "Provisional" : nil)
                GradeCard(title: "Consistency", grade: analysis.grades.consistency,
                          detail: String(format: "%.0f", analysis.grades.consistencyValue))
            }
            if analysis.grades.safetyProvisional {
                Text("Safety uses placeholder data until the switches-category rankings are fetched (see plan M1.8).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func bulkDetail(_ value: Double) -> String {
        value >= 1000 ? String(format: "%.0fk", value / 1000) : String(format: "%.0f", value)
    }

    private func threatScoreBadge(_ score: Int) -> some View {
        HStack(spacing: 6) {
            Text("Threat Score")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(score)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(score >= 600 ? Theme.loss : (score <= 500 ? Theme.win : .primary))
        }
        .help("Average battle rating of the team's six biggest threats (higher = more threatened).")
    }

    // MARK: - Threats

    private func threatsSection(_ analysis: TeamAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Top Threats")
                .font(.title3.weight(.semibold))

            // Column headers: the team members.
            HStack(spacing: 8) {
                Text("Threat").frame(maxWidth: .infinity, alignment: .leading)
                ForEach(Array(analysis.memberNames.enumerated()), id: \.offset) { _, name in
                    Text(name)
                        .frame(width: 56)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)

            ForEach(analysis.threats) { threat in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(threat.speciesName)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            if threat.shadow { ShadowBadge() }
                        }
                        TypeBadgeRow(types: threat.types)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    ForEach(Array(threat.ratings.enumerated()), id: \.offset) { _, rating in
                        ratingChip(rating)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// A compact colored cell for a single battle rating, from the threat's
    /// perspective (so high = bad for your team → red).
    private func ratingChip(_ rating: Int) -> some View {
        Text("\(rating)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white)
            .frame(width: 56, height: 22)
            .background(chipColor(rating), in: RoundedRectangle(cornerRadius: 5))
    }

    private func chipColor(_ rating: Int) -> Color {
        // Threat rating: >500 means the threat wins (bad for you).
        if rating >= 750 { return Theme.loss }
        if rating > 500 { return Theme.loss.opacity(0.6) }
        if rating <= 250 { return Theme.win }
        return Theme.win.opacity(0.6)
    }

    // MARK: - Suggestions

    private func suggestionsSection(_ analysis: TeamAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Suggested Teammates")
                .font(.title3.weight(.semibold))
            Text("Meta Pokémon that beat your biggest threats.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
                ForEach(analysis.suggestions) { suggestion in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(suggestion.speciesName)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                if suggestion.shadow { ShadowBadge() }
                            }
                            TypeBadgeRow(types: suggestion.types)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

/// A single grade card: big letter + label + optional detail line.
private struct GradeCard: View {
    let title: String
    let grade: LetterGrade
    var detail: String?

    var body: some View {
        VStack(spacing: 4) {
            Text(grade.rawValue)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(title)
                .font(.caption.weight(.medium))
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var color: Color {
        switch grade {
        case .a: return .green
        case .b: return .mint
        case .c: return .yellow
        case .d: return .orange
        case .f: return .red
        }
    }
}
