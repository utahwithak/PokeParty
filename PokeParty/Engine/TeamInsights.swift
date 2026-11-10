//
//  TeamInsights.swift
//  PokeParty
//
//  Two small, pure analyses the Team Builder shows beside the grades:
//   - `TeamWeakness`: which attacking types the team is weak to / resists, so
//     shared weaknesses and unanswered types stand out;
//   - `RoleOrder`: the best lead / switch / closer arrangement of the three
//     members from PvPoke's per-role ranking scores.
//

import Foundation

// MARK: - Type weaknesses

nonisolated enum TeamWeakness {

    struct Member: Sendable, Hashable {
        let name: String
        let types: [String]
    }

    /// How the team fares against one attacking type.
    struct TypeRow: Sendable, Identifiable, Hashable {
        let type: String
        /// Damage multiplier against each member, in member order.
        let multipliers: [Double]

        var id: String { type }
        var weakMembers: [Int] { multipliers.indices.filter { multipliers[$0] > 1.0001 } }
        var resistMembers: [Int] { multipliers.indices.filter { multipliers[$0] < 0.9999 } }
        /// Two or more members are hurt by it.
        var isShared: Bool { weakMembers.count >= 2 }
        /// At least one member is weak and none can take it well.
        var isUnanswered: Bool { !weakMembers.isEmpty && resistMembers.isEmpty }
    }

    /// Every attacking type except `banned`, ordered worst first: more weak
    /// members, then fewer resisting members, then the harder hit.
    static func analyze(members: [Member], banned: Set<String> = []) -> [TypeRow] {
        TypeChart.allTypes
            .filter { !banned.contains($0) }
            .map { type in
                TypeRow(type: type, multipliers: members.map {
                    TypeChart.effectiveness(moveType: type, targetTypes: $0.types)
                })
            }
            .sorted { a, b in
                if a.weakMembers.count != b.weakMembers.count { return a.weakMembers.count > b.weakMembers.count }
                if a.resistMembers.count != b.resistMembers.count { return a.resistMembers.count < b.resistMembers.count }
                let worstA = a.multipliers.max() ?? 1, worstB = b.multipliers.max() ?? 1
                if worstA != worstB { return worstA > worstB }
                return a.type < b.type
            }
    }

    /// Attacking types the cup forbids (its `type` exclude filters that apply at
    /// this CP cap), whose threat doesn't exist in that format.
    static func bannedTypes(in cup: Cup?, cpCap: Int) -> Set<String> {
        guard let cup else { return [] }
        var banned = Set<String>()
        for filter in cup.exclude where filter.filterType == "type" {
            if let leagues = filter.leagues, !leagues.contains(cpCap) { continue }
            banned.formUnion(filter.values.map { $0.stringValue.lowercased() })
        }
        return banned
    }
}

// MARK: - Lead / switch / closer

nonisolated enum RoleOrder {

    /// PvPoke's 0–100 per-role ranking scores for one Pokémon.
    struct Scores: Sendable, Hashable {
        let lead: Double
        let closer: Double
        let `switch`: Double

        /// From a ranking entry's `scores` array, ordered
        /// [leads, closers, switches, chargers, attackers, consistency].
        init?(_ scores: [Double]?) {
            guard let scores, scores.count > 2 else { return nil }
            lead = scores[0]
            closer = scores[1]
            `switch` = scores[2]
        }
    }

    /// The members' indices as (lead, switch, closer) maximizing the summed
    /// role scores, or nil unless there are exactly three members with scores.
    static func best(_ scores: [Scores?]) -> [Int]? {
        guard scores.count == 3 else { return nil }
        let known = scores.compactMap { $0 }
        guard known.count == 3 else { return nil }
        var best: (order: [Int], total: Double)?
        for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
            let total = known[order[0]].lead + known[order[1]].switch + known[order[2]].closer
            if best == nil || total > best!.total { best = (order, total) }
        }
        return best?.order
    }
}
