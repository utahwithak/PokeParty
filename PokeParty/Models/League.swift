//
//  League.swift
//  PokeParty
//
//  The three core Pokémon GO PvP leagues, defined by their CP cap.
//

import SwiftUI

/// A Pokémon GO PvP league. The CP cap is also the value PvPoke uses in its
/// ranking file names (e.g. `rankings-1500.json` for Great League).
nonisolated enum League: Int, CaseIterable, Identifiable, Codable {
    case great = 1500
    case ultra = 2500
    case master = 10000

    var id: Int { rawValue }

    /// CP cap for the league.
    var cp: Int { rawValue }

    var title: String {
        switch self {
        case .great: "Great"
        case .ultra: "Ultra"
        case .master: "Master"
        }
    }

    /// A short label including the CP cap, e.g. "Great · 1500".
    var subtitle: String {
        self == .master ? "No CP limit" : "Up to \(cp) CP"
    }

    var tint: Color {
        switch self {
        case .great: .blue
        case .ultra: .yellow
        case .master: .purple
        }
    }
}

/// A rankings format: a core league or a limited cup (e.g. Summer Cup), as
/// listed in gamemaster's `formats`. Rankings live at
/// `rankings/{cup}/overall/rankings-{cp}.json`; core leagues use cup "all".
nonisolated struct RankingFormat: Decodable, Hashable, Identifiable {
    let title: String
    let cup: String
    let cp: Int
    /// PvPoke marks formats whose rankings aren't published.
    let hideRankings: Bool?
    /// Whether PvPoke lists it as a selectable format.
    let showFormat: Bool?

    var id: String { "\(cup)-\(cp)" }

    var isCoreLeague: Bool { cup == "all" }

    /// True when this cup's rankings are published and worth listing.
    var hasRankings: Bool { hideRankings != true }

    var subtitle: String {
        cp >= 10000 ? "No CP limit" : "Up to \(cp) CP"
    }

    var tint: Color {
        switch cp {
        case ..<1500: .mint
        case 1500: .blue
        case 2500: .yellow
        default: .purple
        }
    }

    static let great = RankingFormat(title: "Great League", cup: "all", cp: 1500, hideRankings: false, showFormat: true)
    static let ultra = RankingFormat(title: "Ultra League", cup: "all", cp: 2500, hideRankings: false, showFormat: true)
    static let master = RankingFormat(title: "Master League", cup: "all", cp: 10000, hideRankings: false, showFormat: true)
    static let coreLeagues: [RankingFormat] = [.great, .ultra, .master]
}

nonisolated extension League {
    /// Maps any CP cap to the nearest core league (cups at 1500 → GL, etc.).
    init(cpCap: Int) {
        switch cpCap {
        case ..<2500: self = .great
        case 2500: self = .ultra
        default: self = .master
        }
    }

    /// The core-league `RankingFormat` for this league.
    var format: RankingFormat {
        switch self {
        case .great: return .great
        case .ultra: return .ultra
        case .master: return .master
        }
    }
}
