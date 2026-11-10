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
    /// Pokémon the player has checked against the team, newest first (ratings
    /// follow team order, like the threats table).
    var checked: [ThreatEntry] = []
    /// Searches the roster / bench for a Pokémon to check; nil hides the control.
    var checkPicker: CheckPicker? = nil
    var onCheck: ((TeamMember) -> Void)? = nil
    var onRemoveChecked: ((ThreatEntry) -> Void)? = nil
    @State private var showingCheckPicker = false
    @State private var showAllThreats = false
    /// Threats listed before "Show all" — keeps the table about as tall as the
    /// grades and insight panels beside it.
    private static let collapsedThreatCount = 12
    /// The team as the weakness / lead panels need it (empty hides them).
    var members: [TeamInsightMember] = []
    /// Attacking types the format forbids, left out of the weakness panel.
    var bannedTypes: Set<String> = []

    /// Measured width of the available space, to pick the layout.
    @State private var width: CGFloat = 0
    /// Wide enough for two columns: grades and insights beside the threats table.
    private var isWide: Bool { width >= 860 }
    /// The threats table stops growing here — past it the Pokémon names and
    /// their rating chips drift apart across a big empty gap.
    private static let threatsWidth: CGFloat = 480
    /// How far the "Your checks" tint extends past the table's edges (cosmetic).
    private static let checkedBleed: CGFloat = 8

    var body: some View {
        Group {
            if isWide {
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 24) {
                        gradesSection
                        insightPanels
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    threatsSection
                }
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    gradesSection
                    insightPanels
                    threatsSection
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    // MARK: - Weaknesses & leads

    /// Only when every team member resolved, so threat ratings line up with members.
    @ViewBuilder
    private var insightPanels: some View {
        if !members.isEmpty, members.count == analysis.memberNames.count {
            TeamWeaknessPanel(members: members, banned: bannedTypes)
            TeamLeadsPanel(members: members, threats: analysis.threats)
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
            HStack {
                Text("Top Threats")
                    .font(.title3.weight(.semibold))
                Spacer()
                if let checkPicker, let onCheck {
                    Button {
                        showingCheckPicker = true
                    } label: {
                        Label("Check a Pokémon", systemImage: "magnifyingglass")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("See how any Pokémon stacks up against this team, even if it isn't a top threat")
                    .popover(isPresented: $showingCheckPicker) {
                        LockedPokemonPickerView(
                            store: checkPicker.store, bench: checkPicker.bench, format: checkPicker.store.format,
                            excludingSpeciesIds: [],
                            onSelect: { member in
                                showingCheckPicker = false
                                onCheck(member)
                            })
                        #if os(iOS)
                        .presentationCompactAdaptation(.sheet)
                        #endif
                    }
                }
            }

            // Column headers: the team members (two lines so a long name like
            // "Gyarados (Mega)" stays readable instead of shrinking).
            HStack(spacing: 8) {
                Color.clear.frame(width: ThreatRow.removeSlotWidth, height: 1)
                Text("Threat").frame(maxWidth: .infinity, alignment: .leading)
                ForEach(Array(analysis.memberNames.enumerated()), id: \.offset) { _, name in
                    Text(name)
                        .frame(width: 56)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.8)
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)

            if !checked.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your checks")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(checked) { threat in
                        ThreatRow(threat: threat, reservesRemoveSlot: true,
                                  onRemove: onRemoveChecked.map { remove in { remove(threat) } })
                    }
                }
                // The tint extends slightly past the table by exactly its inner
                // padding, so the rows inside keep the table's columns.
                .padding(.vertical, 8)
                .padding(.horizontal, Self.checkedBleed)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, -Self.checkedBleed)
            }

            ForEach(showAllThreats ? analysis.threats : Array(analysis.threats.prefix(Self.collapsedThreatCount))) { threat in
                ThreatRow(threat: threat, reservesRemoveSlot: true)
            }

            if analysis.threats.count > Self.collapsedThreatCount {
                Button(showAllThreats ? "Show fewer" : "Show all \(analysis.threats.count) threats") {
                    withAnimation { showAllThreats.toggle() }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .frame(maxWidth: Self.threatsWidth, alignment: .topLeading)
    }
}

/// What the "Check a Pokémon" search needs to list the roster and the bench.
struct CheckPicker {
    let store: RankingsStore
    let bench: BenchStore
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

/// One threat's name/types + a rating chip per team member. Shared by the
/// Team Builder's Top Threats table and "Test Against Meta"'s switch/stay
/// section (filtered there to opposing leads actually encountered in that run).
struct ThreatRow: View {
    let threat: ThreatEntry
    /// Reserves a fixed slot before the name for a remove button (filled for
    /// checked Pokémon, empty otherwise), so a table that mixes rows with and
    /// without one stays aligned. Pass `true` on every row of such a table,
    /// plus `Self.removeSlotWidth` of space in its header.
    var reservesRemoveSlot = false
    /// Shows the remove button in the reserved slot.
    var onRemove: (() -> Void)? = nil

    static let removeSlotWidth: CGFloat = 20

    var body: some View {
        HStack(spacing: 8) {
            if reservesRemoveSlot {
                ZStack {
                    if let onRemove {
                        Button(action: onRemove) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove this check")
                    }
                }
                .frame(width: Self.removeSlotWidth)
            }
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
                ThreatRatingChip(rating: rating)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A compact colored cell for a single battle rating, from the threat's
/// perspective (so high = bad for your team → red).
struct ThreatRatingChip: View {
    let rating: Int

    var body: some View {
        Text("\(rating)")
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.3), radius: 0.5, y: 0.5)
            .frame(width: 56, height: 22)
            .background(color, in: RoundedRectangle(cornerRadius: 5))
    }

    /// Threat rating → cell color (threat's perspective, so high = bad for you →
    /// red). Uses four saturated bands so white text stays legible on every cell.
    private var color: Color {
        switch rating {
        case 750...:     return Color(red: 0.75, green: 0.22, blue: 0.17)  // strong loss
        case 501..<750:  return Color(red: 0.84, green: 0.37, blue: 0.31)  // close loss
        case 251...500:  return Color(red: 0.30, green: 0.69, blue: 0.35)  // close win
        default:         return Color(red: 0.18, green: 0.60, blue: 0.27)  // strong win
        }
    }
}
