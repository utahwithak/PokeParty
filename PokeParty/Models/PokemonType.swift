//
//  PokemonType.swift
//  PokeParty
//
//  Display palette ported from PvPoke's style.scss (type colors, stat/move
//  colors, win/loss and score-badge styling).
//

import SwiftUI

/// Presentation helpers keyed by PvPoke's lowercase type strings (e.g. "fire").
enum PokemonType {
    /// PvPoke's dark→light color pair for each type. The dark value is the
    /// primary color used for flat badges; the pair forms the gradient.
    private static let pairs: [String: (dark: Color, light: Color)] = [
        "bug":      (Color(hex: 0x9bc231), Color(hex: 0xaec92c)),
        "dark":     (Color(hex: 0x52505e), Color(hex: 0x6e7681)),
        "dragon":   (Color(hex: 0x1065b6), Color(hex: 0x067fc4)),
        "electric": (Color(hex: 0xf3d43e), Color(hex: 0xfedf6b)),
        "fairy":    (Color(hex: 0xeb8de1), Color(hex: 0xf6a7e8)),
        "fighting": (Color(hex: 0xce3d64), Color(hex: 0xe34448)),
        "fire":     (Color(hex: 0xfe9d59), Color(hex: 0xfeb04b)),
        "flying":   (Color(hex: 0x91a8de), Color(hex: 0xa7c1f2)),
        "ghost":    (Color(hex: 0x5069ac), Color(hex: 0x7571d0)),
        "grass":    (Color(hex: 0x5fbb50), Color(hex: 0x59c079)),
        "ground":   (Color(hex: 0xd87b40), Color(hex: 0xd2976b)),
        "ice":      (Color(hex: 0x74d3bd), Color(hex: 0x94ddd6)),
        "normal":   (Color(hex: 0x909aa3), Color(hex: 0xa3a49e)),
        "poison":   (Color(hex: 0xc662d6), Color(hex: 0xa662c7)),
        "psychic":  (Color(hex: 0xf2726f), Color(hex: 0xfda194)),
        "rock":     (Color(hex: 0xc7b98c), Color(hex: 0xd7cd90)),
        "steel":    (Color(hex: 0x50879c), Color(hex: 0x5aafb4)),
        "water":    (Color(hex: 0x4f91db), Color(hex: 0x6ac7e9)),
    ]

    /// The primary (dark) color for a type. Unknown types fall back to gray.
    static func color(for type: String) -> Color {
        pairs[type.lowercased()]?.dark ?? .gray
    }

    /// PvPoke's top-to-bottom dark→light gradient for a type.
    static func gradient(for type: String) -> LinearGradient {
        let pair = pairs[type.lowercased()] ?? (.gray, Color.gray.opacity(0.6))
        return LinearGradient(
            colors: [pair.dark, pair.light],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// Non-type colors from PvPoke's palette.
enum Theme {
    // Stats
    static let attack = Color(hex: 0xed6774)
    static let defense = Color(hex: 0x6696ed)
    static let hp = Color(hex: 0x0eb084)

    // Moves
    static let movePower = Color(hex: 0xa60087)
    static let moveEnergy = Color(hex: 0x0087a6)
    static let moveDuration = Color(hex: 0x87a600)

    // Battle outcomes
    static let win = Color(hex: 0x17de4b)
    static let loss = Color(hex: 0xff5858)
    static let shield = Color(hex: 0xdf46e5)

    // Score badge
    static let scoreText = Color(hex: 0xfff6d4)
    static let scoreBackground = Color.black.opacity(0.6)
}

extension Color {
    /// Creates a color from a 24-bit RGB hex literal, e.g. `0xfe9d59`.
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255
        )
    }
}

extension String {
    /// Capitalizes the first letter only, leaving the rest as-is.
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
