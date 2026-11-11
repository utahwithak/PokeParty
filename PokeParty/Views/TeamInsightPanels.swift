//
//  TeamInsightPanels.swift
//  PokeParty
//
//  The Team Builder's two panels beside the grades: type weaknesses (shared
//  weaknesses and unanswered types at a glance) and leads (the suggested
//  lead / switch / closer order and what beats the lead). Both are driven by
//  the pure helpers in `TeamInsights.swift`.
//

import SwiftUI

/// One team member as the insight panels need it.
struct TeamInsightMember: Hashable {
    let name: String
    let types: [String]
    let roles: RoleOrder.Scores?
}

// MARK: - Weaknesses

struct TeamWeaknessPanel: View {
    let members: [TeamInsightMember]
    /// Attacking types the format forbids, left out of the analysis.
    var banned: Set<String> = []

    private var rows: [TeamWeakness.TypeRow] {
        TeamWeakness.analyze(members: members.map { .init(name: $0.name, types: $0.types) }, banned: banned)
    }

    var body: some View {
        let rows = rows
        let hurtBy = rows.filter { !$0.weakMembers.isEmpty }
        VStack(alignment: .leading, spacing: 10) {
            Text("Type Weaknesses")
                .font(.title3.weight(.semibold))

            summaryLine(
                rows.filter(\.isShared).map(\.type),
                title: "Shared weakness", none: "No shared weaknesses", tint: Theme.loss)
            summaryLine(
                rows.filter(\.isUnanswered).map(\.type),
                title: "Nobody resists", none: "Every weakness has a resist on the team", tint: .orange)

            if hurtBy.isEmpty {
                Text("No member is weak to any attacking type in this format.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(hurtBy) { row in cell(row) }
                }
                legend
            }
        }
    }

    /// "Shared weakness: Ice, Rock" in the warning color, or a calm all-clear.
    @ViewBuilder
    private func summaryLine(_ types: [String], title: String, none: String, tint: Color) -> some View {
        if types.isEmpty {
            Label(none, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Theme.win)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Label(title, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                TypeBadgeRow(types: types)
            }
        }
    }

    /// One attacking type with a dot per member: weak (orange), double weak
    /// (red), resists (green), neutral (outlined gray). The box is tinted and
    /// outlined by how bad the type is for the team — a shared weakness is the
    /// strongest — so it stands out against the page instead of fading into it.
    private func cell(_ row: TeamWeakness.TypeRow) -> some View {
        let tint = severityColor(row)
        return HStack(spacing: 10) {
            TypeBadge(type: row.type)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                ForEach(Array(row.multipliers.enumerated()), id: \.offset) { index, multiplier in
                    dot(multiplier)
                        .help("\(members.indices.contains(index) ? members[index].name : "Member"): ×\(multiplier.formatted(.number.precision(.fractionLength(0...2))))")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tint.opacity(row.isShared ? 0.22 : 0.14), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(row.isShared ? 0.85 : 0.5), lineWidth: 1.5))
    }

    /// Red when two or more members are hurt or one is double weak, else orange.
    private func severityColor(_ row: TeamWeakness.TypeRow) -> Color {
        row.isShared || row.multipliers.contains { $0 >= 2 } ? Theme.loss : Color.orange
    }

    /// A member's dot, big enough to read; neutral gets an outline so it never
    /// disappears into the tinted box.
    private func dot(_ multiplier: Double) -> some View {
        Circle()
            .fill(color(for: multiplier))
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 1))
            .frame(width: 16, height: 16)
    }

    private func color(for multiplier: Double) -> Color {
        switch multiplier {
        case 2...: return Theme.loss                        // double weakness
        case 1.0001...: return Color.orange                 // weak
        case ..<0.9999: return Theme.win                    // resists
        default: return Color(white: 0.82)                  // neutral
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                legendDot(Theme.loss, "double weak")
                legendDot(.orange, "weak")
                legendDot(Theme.win, "resists")
                legendDot(Color(white: 0.82), "neutral")
            }
            Text("Dots follow team order: " + members.map(\.name).joined(separator: " · "))
                .lineLimit(2)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 1))
                .frame(width: 10, height: 10)
            Text(label)
        }
    }
}

// MARK: - Leads

struct TeamLeadsPanel: View {
    let members: [TeamInsightMember]
    /// The threats table's rows; ratings follow `members` order.
    let threats: [ThreatEntry]

    private var order: [Int]? { RoleOrder.best(members.map(\.roles)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Leads")
                .font(.title3.weight(.semibold))

            if members.contains(where: { $0.roles != nil }) {
                roleTable
            } else {
                Text("Role scores aren't available for this format's rankings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Your lead is whoever is first in the team order, not whoever the role
            // scores would suggest — so the threats listed are the ones that beat
            // the Pokémon actually in the lead slot.
            if !members.isEmpty {
                leadMatchups(leadIndex: 0)
            }
            if members.count < 3 {
                Text("Add three Pokémon for a suggested lead, switch and closer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Role table

    private let roles: [(title: String, keyPath: KeyPath<RoleOrder.Scores, Double>)] = [
        ("Lead", \.lead), ("Switch", \.switch), ("Closer", \.closer),
    ]

    private var roleTable: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text("").frame(maxWidth: .infinity, alignment: .leading)
                ForEach(roles, id: \.title) { role in
                    Text(role.title).frame(width: 52)
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)

            // Assigned role index per member (0 lead, 1 switch, 2 closer) from the best order.
            let assigned: [Int: Int] = order.map { order in
                Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            } ?? [:]

            ForEach(Array(members.enumerated()), id: \.offset) { index, member in
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.name)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        TypeBadgeRow(types: member.types)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    ForEach(Array(roles.enumerated()), id: \.offset) { roleIndex, role in
                        scoreCell(member.roles.map { $0[keyPath: role.keyPath] },
                                  highlighted: assigned[index] == roleIndex)
                    }
                }
            }

            if let order {
                Text("Suggested: " + zip(["Lead", "Switch", "Closer"], order)
                    .map { "\($0) \(members[$1].name)" }.joined(separator: " → "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
            }
        }
    }

    private func scoreCell(_ score: Double?, highlighted: Bool) -> some View {
        Text(score.map { String(Int($0.rounded())) } ?? "–")
            .font(.caption.weight(highlighted ? .bold : .regular).monospacedDigit())
            .foregroundStyle(highlighted ? Color.white : Color.primary)
            .frame(width: 52, height: 24)
            .background(highlighted ? Color.accentColor : Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Lead matchups

    /// The opposing Pokémon that beat the suggested lead hardest, from the
    /// threats table (rating is from the threat's side, so > 500 beats the lead).
    @ViewBuilder
    private func leadMatchups(leadIndex: Int) -> some View {
        let worst = threats
            .filter { $0.ratings.indices.contains(leadIndex) && $0.ratings[leadIndex] > 500 }
            .sorted { $0.ratings[leadIndex] > $1.ratings[leadIndex] }
            .prefix(5)
        VStack(alignment: .leading, spacing: 6) {
            Text("Beats your lead (\(members[leadIndex].name))")
                .font(.subheadline.weight(.semibold))
            if worst.isEmpty {
                Text("Nothing in the top threats beats it — a safe opener.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(Array(worst)) { threat in
                        HStack(spacing: 6) {
                            Text(threat.speciesName)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text("\(threat.ratings[leadIndex])")
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(Theme.loss)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Theme.loss.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
        .padding(.top, 4)
    }
}
