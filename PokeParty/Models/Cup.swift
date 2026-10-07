//
//  Cup.swift
//  PokeParty
//
//  A cup's eligibility rules from PvPoke's gamemaster data — the `include`/
//  `exclude` filter lists that decide which Pokémon may be used in a given
//  cup, ported from `GameMaster.js`'s `generateFilteredPokemonList`.
//

import Foundation

/// One cup's eligibility rules (`gamemaster.json`'s `cups` array).
nonisolated struct Cup: Decodable, Hashable {
    let name: String
    let title: String
    let include: [Filter]
    let exclude: [Filter]
    /// Some cups (e.g. Little Cup) cap the level Pokémon may reach.
    let levelCap: Double?
    /// Draft-style cups restrict the field to a fixed roster size; not a
    /// stat-product/filter concept, just carried through for completeness.
    let partySize: Int?
    /// Bypasses the minimum stat-product floor entirely (rare).
    let includeLowStatProduct: Bool?

    /// Explicit memberwise init (with defaults for the rare optional fields)
    /// — `Filter`'s custom `init(from:)` doesn't suppress this one since
    /// it's a nested type, but writing it out keeps test/call-site
    /// construction convenient without every cup needing to state its rare
    /// fields.
    init(
        name: String, title: String, include: [Filter], exclude: [Filter],
        levelCap: Double? = nil, partySize: Int? = nil, includeLowStatProduct: Bool? = nil
    ) {
        self.name = name
        self.title = title
        self.include = include
        self.exclude = exclude
        self.levelCap = levelCap
        self.partySize = partySize
        self.includeLowStatProduct = includeLowStatProduct
    }

    /// One include/exclude criterion. `values` holds either species ids/tags/
    /// types (strings) or evolution-stage/dex numbers (ints) depending on
    /// `filterType`, hence `FilterValue`'s dual decoding.
    struct Filter: Decodable, Hashable {
        let filterType: String
        let values: [FilterValue]
        /// Restricts this filter to specific CP caps (rare).
        let leagues: [Int]?
        /// An `id` filter that should still match a Pokémon's shadow/XL
        /// variant (normally shadows/XLs are stripped to their base id
        /// before matching an `id` filter on the exclude side only).
        let includeShadows: Bool?

        enum CodingKeys: String, CodingKey {
            case filterType, values, leagues, includeShadows
        }

        /// Explicit memberwise init — defining the lenient `init(from:)`
        /// below suppresses Swift's automatic one, but tests (and any other
        /// non-JSON caller) still want to build a `Filter` directly.
        init(filterType: String, values: [FilterValue], leagues: [Int]? = nil, includeShadows: Bool? = nil) {
            self.filterType = filterType
            self.values = values
            self.leagues = leagues
            self.includeShadows = includeShadows
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            filterType = try c.decode(String.self, forKey: .filterType)
            values = try c.decodeIfPresent([FilterValue].self, forKey: .values) ?? []
            leagues = try c.decodeIfPresent([Int].self, forKey: .leagues)
            includeShadows = try c.decodeIfPresent(Bool.self, forKey: .includeShadows)
        }
    }

    /// A filter value that may be a species id/tag/type (string) or an
    /// evolution stage/dex number (int) — decoded leniently either way.
    enum FilterValue: Decodable, Hashable {
        case string(String)
        case int(Int)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int.self) {
                self = .int(i)
            } else {
                self = .string(try c.decode(String.self))
            }
        }

        var stringValue: String {
            switch self {
            case .string(let s): return s
            case .int(let i): return String(i)
            }
        }

        var intValue: Int? {
            switch self {
            case .int(let i): return i
            case .string(let s): return Int(s)
            }
        }
    }
}
