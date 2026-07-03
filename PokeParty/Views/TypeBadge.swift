//
//  TypeBadge.swift
//  PokeParty
//
//  A small pill showing a Pokémon or move type.
//

import SwiftUI

/// A colored capsule label for a single type, e.g. "Fire".
struct TypeBadge: View {
    let type: String

    var body: some View {
        Text(type.capitalizedFirst)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(PokemonType.gradient(for: type), in: Capsule())
    }
}

/// A small purple flame marking a Shadow Pokémon.
struct ShadowBadge: View {
    var body: some View {
        Image(systemName: "flame.fill")
            .font(.caption2)
            .foregroundStyle(Color(hex: 0x7f4da8))
            .help("Shadow")
            .accessibilityLabel("Shadow")
    }
}

/// A horizontal row of `TypeBadge`s.
struct TypeBadgeRow: View {
    let types: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(types, id: \.self) { TypeBadge(type: $0) }
        }
    }
}

#Preview {
    TypeBadgeRow(types: ["water", "ground"])
        .padding()
}
