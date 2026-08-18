//
//  TeamResultRow.swift
//  PokeParty
//
//  Rank + team members + a caller-supplied stat line + "Open in Team
//  Builder", shared by every ranked-team results list (tournament
//  leaderboard, AI optimizer, AAAA grade check, bench finder). These lists
//  used to each hand-roll the same HStack-of-fixed-width-cells layout, which
//  had no way to shrink and would overflow the window on narrow widths —
//  `ViewThatFits` here picks between a wide side-by-side member layout and a
//  stacked name+type-dots one, so the same view degrades gracefully on both
//  macOS and iOS instead of needing separate narrow-width handling.
//

import SwiftUI

/// One member shown in a `TeamResultRow`: enough to render name, shadow/lead
/// flags and types, regardless of which concrete "ranked team" type
/// (finder standings, optimizer output, grade-checker, bench finder)
/// produced it.
struct TeamResultMember: Identifiable {
    let id = UUID()
    let speciesName: String
    let types: [String]
    var shadow: Bool = false
    var isLead: Bool = false
    /// Small trailing flag, e.g. "ALT" for a non-recommended moveset.
    var flag: String? = nil
    /// Extra detail (e.g. the moveset) shown as a hover tooltip rather than
    /// laid out inline, so it can't force the row wider than the window.
    var tooltip: String? = nil
}

struct TeamResultRow<Record: View>: View {
    let rank: Int
    let members: [TeamResultMember]
    var onOpenInBuilder: (() -> Void)?
    @ViewBuilder var record: () -> Record

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(stacked: false)
            row(stacked: true)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func row(stacked: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if !stacked { rankLabel }
            VStack(alignment: .leading, spacing: 6) {
                if stacked { rankLabel }
                if stacked {
                    ForEach(members) { narrowCell($0) }
                } else {
                    HStack(spacing: 12) {
                        ForEach(members) { wideCell($0) }
                    }
                }
                record()
            }
            Spacer(minLength: 8)
            if let onOpenInBuilder {
                Button("Open in Team Builder", action: onOpenInBuilder)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
            }
        }
    }

    private var rankLabel: some View {
        Text("#\(rank)")
            .font(.headline.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 32, alignment: .leading)
            .contentTransition(.numericText())
    }

    private func wideCell(_ member: TeamResultMember) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            nameLine(member)
            TypeBadgeRow(types: member.types)
        }
        .frame(minWidth: 110, alignment: .leading)
    }

    private func narrowCell(_ member: TeamResultMember) -> some View {
        HStack(spacing: 6) {
            nameLine(member)
            TypeDotRow(types: member.types)
        }
    }

    private func nameLine(_ member: TeamResultMember) -> some View {
        HStack(spacing: 4) {
            Text(member.speciesName)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            if member.shadow { ShadowBadge() }
            if member.isLead {
                Text("LEAD")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            if let flag = member.flag {
                Text(flag)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(.tint.opacity(0.15), in: Capsule())
            }
        }
        .help(member.tooltip ?? "")
    }
}
