//
//  TeamMovePicker.swift
//  PokeParty
//
//  Team Builder move picker and charge-bank bars.
//

import SwiftUI

/// A compact menu to pick a move for a team slot, showing the current move's
/// name + type. Mirrors `PokemonDetailView`'s picker but sized for the cards.
/// Also used by the 1v1 Simulator's combatant cards (`MatchupDetailView`).
struct TeamMovePicker: View {
    let label: String
    let currentId: String            // "" == none
    let optionIds: [String]
    let recommendedId: String?
    let includesNone: Bool
    /// Species providing the move pool, for Elite TM / Legacy designations.
    let species: Pokemon
    let store: RankingsStore
    /// nil argument means "None" was chosen (second charged slot only).
    let onSelect: (String?) -> Void
    /// When set, a caption under the picker shows the move's turns / energy
    /// / fast-move counts. For a charged move, pass the fast move's energy gain.
    var showsDetail = false
    var fastEnergyGain: Int? = nil
    /// A move that's only a guess (an opponent's unconfirmed set) shows in lighter text.
    var isGuess = false

    /// "Fast" → "F", "Charged 2" → "2": the slot is clear from the order, and
    /// the narrower column lets three cards sit side by side.
    private var shortLabel: String {
        if label == "Fast" { return "F" }
        return label.split(separator: " ").last.map(String.init) ?? label
    }
    private static let labelWidth: CGFloat = 16

    private var move: Move? { store.move(id: currentId) }
    private var designation: Pokemon.MoveDesignation? {
        species.moveDesignation(for: currentId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            pickerRow
            if showsDetail, let move {
                Text(move.detailText(fastEnergyGain: fastEnergyGain))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help(move.isFast ? "Duration in turns and energy gained per use"
                          : "Energy cost, then the fast moves needed before each of the next 5 throws, carrying leftover energy. \"Straight 5\" means every throw takes 5 fast moves.")
                    .padding(.leading, Self.labelWidth + 6)   // label width + spacing
            }
        }
    }

    private var pickerRow: some View {
        HStack(spacing: 6) {
            Text(shortLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: Self.labelWidth, alignment: .leading)
                .help(label)
                .accessibilityLabel(label)
            Menu {
                if includesNone {
                    button(id: nil, label: "None")
                }
                ForEach(optionIds, id: \.self) { id in
                    button(id: id, label: optionLabel(id))
                }
            } label: {
                HStack(spacing: 5) {
                    Text(currentName)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(isGuess ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .help(designation?.help ?? (isGuess ? "A guess: not seen in this battle yet" : ""))
                    if let move {
                        TypeBadge(type: move.type)
                        if showsDetail { ChargeBankBars(count: move.bankSize) }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func button(id: String?, label: String) -> some View {
        Button {
            onSelect(id)
        } label: {
            if (id ?? "") == currentId {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    /// Collapsed label: PvPoke's `*` convention flags Elite TM / Legacy moves.
    private var currentName: String {
        guard let move else { return "None" }
        return designation == nil ? move.name : move.name + "*"
    }

    private func optionLabel(_ id: String) -> String {
        guard let m = store.move(id: id) else { return id }
        var name = m.name
        if let designation = species.moveDesignation(for: id) {
            name += " (\(designation.label))"
        }
        if id == recommendedId { name += " (Recommended)" }
        return name
    }
}

/// One slanted segment per charge that fits in a full energy bar, like the
/// bars Pokémon GO draws beside a charged move.
struct ChargeBankBars: View {
    let count: Int

    var body: some View {
        if count > 0 {
            HStack(spacing: 2) {
                ForEach(0..<count, id: \.self) { _ in
                    Slant()
                        .fill(Color.secondary.opacity(0.6))
                        .frame(width: 14, height: 7)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Can bank \(count)")
            .help("A full energy bar holds \(count) of this move")
        }
    }

    /// A trapezoid leaning right, wider along the bottom.
    private nonisolated struct Slant: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let inset = rect.height * 0.5
            path.move(to: CGPoint(x: rect.minX + inset, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
            return path
        }
    }
}
