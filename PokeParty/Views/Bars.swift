//
//  Bars.swift
//  PokeParty
//
//  PvPoke-style horizontal bars for stats and battle ratings.
//
//  The colored fill is sized with `scaleEffect` rather than `GeometryReader`:
//  many GeometryReaders inside a List can trigger AttributeGraph layout cycles.
//

import SwiftUI

/// A proportional capsule fill (0…1) that doesn't read back layout geometry.
private struct BarFill: View {
    let fraction: Double
    let color: Color

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.08))
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(color)
                    .scaleEffect(x: min(max(fraction, 0), 1), y: 1, anchor: .leading)
            }
            .frame(height: 10)
    }
}

/// A labeled, colored stat bar (e.g. Attack in red), mirroring PvPoke's
/// `.bar-back` / `.bar` stat display.
struct StatBar: View {
    let label: String
    let value: Double
    let color: Color

    /// Shared upper bound so the three stats are visually comparable.
    private let maxValue: Double = 300

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.subheadline)
                .frame(width: 64, alignment: .leading)

            BarFill(fraction: value / maxValue, color: color)

            Text(value, format: .number.precision(.fractionLength(1)))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }
}

/// A battle-rating bar (0–1000, 500 is even). Green for favorable, red for not.
struct RatingBar: View {
    let rating: Int

    var body: some View {
        BarFill(fraction: Double(rating) / 1000, color: rating > 500 ? Theme.win : Theme.loss)
    }
}

#Preview {
    VStack(spacing: 12) {
        StatBar(label: "Attack", value: 121.5, color: Theme.attack)
        StatBar(label: "Defense", value: 141.6, color: Theme.defense)
        StatBar(label: "HP", value: 107, color: Theme.hp)
        HStack {
            RatingBar(rating: 859)
            RatingBar(rating: 309)
        }
    }
    .padding()
    .frame(width: 360)
}
