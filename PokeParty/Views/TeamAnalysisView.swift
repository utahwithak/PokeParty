//
//  TeamAnalysisView.swift
//  PokeParty
//
//  The PvPoke-style analysis sections for a team: the four grades
//  (Coverage / Bulk / Safety / Consistency), the threat score, the top-threats
//  matrix, and suggested teammates. Rendered inside the Team Builder's main panel
//  (`TeamBuilderDetailView`); it is a plain content view (no ScrollView / nav) so
//  it can be composed above/below the team editor.
//

import SwiftUI

struct TeamAnalysisSections: View {
    let analysis: TeamAnalysis
    /// Called when a suggested teammate is tapped (nil disables tapping, e.g. when
    /// the team is already full).
    var onAddSuggestion: ((String) -> Void)?
    /// When provided, suggestions that appear in the bench for `league` are highlighted.
    var bench: BenchStore? = nil
    var league: League? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            gradesSection
            threatsSection
            suggestionsSection
        }
    }

    // MARK: - Grades

    private var gradesSection: some View {
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
                          detail: analysis.grades.safetyProvisional
                            ? "Provisional"
                            : String(format: "%.0f", analysis.grades.safetyValue))
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

    private var threatsSection: some View {
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
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.3), radius: 0.5, y: 0.5)
            .frame(width: 56, height: 22)
            .background(chipColor(rating), in: RoundedRectangle(cornerRadius: 5))
    }

    /// Threat rating → cell color (threat's perspective, so high = bad for you →
    /// red). Uses four saturated bands so white text stays legible on every cell.
    private func chipColor(_ rating: Int) -> Color {
        switch rating {
        case 750...:     return Color(red: 0.75, green: 0.22, blue: 0.17)  // strong loss
        case 501..<750:  return Color(red: 0.84, green: 0.37, blue: 0.31)  // close loss
        case 251...500:  return Color(red: 0.30, green: 0.69, blue: 0.35)  // close win
        default:         return Color(red: 0.18, green: 0.60, blue: 0.27)  // strong win
        }
    }

    // MARK: - Suggestions

    private func isInBench(_ speciesId: String) -> Bool {
        guard let bench, let league else { return false }
        return bench.contains(speciesId: speciesId, league: league)
    }

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Suggested Teammates")
                .font(.title3.weight(.semibold))
            Text(onAddSuggestion == nil
                 ? "Meta Pokémon that beat your biggest threats."
                 : "Meta Pokémon that beat your biggest threats — tap to add.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
                ForEach(analysis.suggestions) { suggestion in
                    let inBench = isInBench(suggestion.speciesId)
                    Button {
                        onAddSuggestion?(suggestion.speciesId)
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(suggestion.speciesName)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                    if suggestion.shadow { ShadowBadge() }
                                    if inBench {
                                        Image(systemName: "tray.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.tint)
                                            .help("In your bench")
                                    }
                                }
                                TypeBadgeRow(types: suggestion.types)
                            }
                            Spacer(minLength: 0)
                            if onAddSuggestion != nil {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(
                            inBench ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(onAddSuggestion == nil)
                }
            }
        }
    }
}

/// A single grade card: big letter + label + optional detail line.
struct GradeCard: View {
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
