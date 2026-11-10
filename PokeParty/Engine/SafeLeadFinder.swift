//
//  SafeLeadFinder.swift
//  PokeParty
//
//  The Party Finder's "Safe lead + cover" mode, modelled on a common ladder
//  team-building recipe: put a SAFE Pokémon in the lead (few bad matchups in
//  the meta) and fill the back two so they cover what beats the lead —
//  complementary rock-paper-scissors, not two copies of the same answer.
//
//  Like `GradeFinder` this needs only the pool's pairwise 1v1 rating matrix, so
//  no 3v3 battles are fought here:
//    1. Rank every pool member by lead threat — the mean softened rating of the
//       meta attacking it (lower = safer) — and keep the safest few, one per
//       evolutionary family.
//    2. For each lead, score every compatible back pair by how well the whole
//       team covers the meta — for each other pool member, the best answer on
//       the team. That is what "cover what beats the lead and each other"
//       reduces to; `Config` can also weight the lead's own holes and penalize
//       back members that share them, but measurement found neither helps.
//    3. Keep the best few pairs per lead (no teammate dominating a lead's list),
//       merge across leads, and rank.
//
//  The result is a short list of trios (lead first) that `GradeFinder
//  .gradeTrios` grades for display and, optionally, the tournament verifies.
//

import Foundation

nonisolated enum SafeLeadFinder {

    /// A chosen team: pool indices (lead, then the two back members) and the
    /// heuristic score it was ranked by (higher = better).
    struct SafeTrio: Sendable, Hashable {
        let indices: [Int]
        let score: Double
        /// The lead's mean softened meta threat (lower = safer).
        let leadThreat: Double
    }

    static let defaultLeadCount = 10
    static let defaultTeamsPerLead = 5

    /// How the safest leads are picked.
    enum LeadRule: String, Sendable, CaseIterable {
        /// Lowest mean softened rating of the meta attacking it.
        case matchupPressure
        /// Fewest type weaknesses among the cup's legal attacking types (ties
        /// broken by matchup pressure) — "only weak to two types".
        case typeWeakness
    }

    /// The tunable knobs of the heuristic. Defaults come from sweeping 72 configs
    /// over 10 conditions (LAIC GBL + Great League; heuristic, learned and full
    /// AI stacks; pools of 100 and 200), scoring each config's top-20 by win
    /// rate against an independent random field:
    ///  - team-wide coverage carries the signal; weighting the lead's own holes
    ///    got monotonically worse (the lead's holes are already part of team
    ///    coverage), and the shared-hole penalty and lead weight were flat;
    ///  - lead safety matters: safe leads beat random leads by ~2 points, beat
    ///    the least-safe leads by ~8, and top-ranked leads by <1;
    ///  - the type-weakness lead rule is worse than matchup pressure.
    /// Per-condition noise is ~±1.5 points, so don't re-tune on a single run.
    struct Config: Sendable {
        /// Blend of the two coverage terms: how well the back pair answers the
        /// lead's own holes vs how well the whole team covers the meta.
        var holeCoverWeight = 0.0
        var teamCoverWeight = 1.0
        /// Rating points subtracted when both back members are beaten by the same
        /// threats that beat the lead (scaled by the shared-hole fraction, 0…1).
        var sharedHolePenalty = 0.0
        /// Rating points per point of lead threat — a safer lead ranks higher.
        var leadSafetyWeight = 0.0
        var leadRule: LeadRule = .matchupPressure

        static let `default` = Config()
    }

    /// A back teammate may appear in at most this many of one lead's teams.
    private static let maxUsesPerMate = 2

    /// Builds the pool's rating matrix and selects the safe-lead teams, best
    /// first. Returns the matrix too so the caller can grade the trios without
    /// recomputing it. Runs off the main actor.
    static func findTrios(
        pool: [TeamFinder.Candidate],
        movesById: [String: Move],
        metaRelevantCount: Int = 40,
        leadCount: Int = defaultLeadCount,
        teamsPerLead: Int = defaultTeamsPerLead,
        config: Config = .default,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async -> (trios: [SafeTrio], ratings: [Int]) {
        guard pool.count >= 3 else { return ([], []) }
        let raw = await GradeFinder.ratingMatrix(pool: pool, movesById: movesById) { fraction in
            onProgress?(fraction * 0.9)
        }
        if Task.isCancelled { return ([], raw) }

        let threat = leadThreats(pool: pool, ratings: raw, metaRelevantCount: metaRelevantCount)
        let leads = chooseLeads(pool: pool, leadThreat: threat, count: leadCount, rule: config.leadRule)

        var all: [SafeTrio] = []
        var done = 0
        await withTaskGroup(of: [SafeTrio].self) { group in
            for lead in leads {
                group.addTask {
                    bestCovers(lead: lead, leadThreat: threat[lead], pool: pool, ratings: raw,
                               teamsPerLead: teamsPerLead, config: config)
                }
            }
            for await part in group {
                done += 1
                onProgress?(0.9 + 0.1 * Double(done) / Double(max(leads.count, 1)))
                all.append(contentsOf: part)
            }
        }
        return (merge(all), raw)
    }

    /// Synchronous selection from a precomputed rating matrix
    /// (`raw[a * n + b]` = pool[a]'s 1v1 rating attacking pool[b]). The core of
    /// `findTrios`, exposed so it can be tested on a small hand-built pool.
    static func select(
        pool: [TeamFinder.Candidate],
        ratings raw: [Int],
        metaRelevantCount: Int = 40,
        leadCount: Int = defaultLeadCount,
        teamsPerLead: Int = defaultTeamsPerLead,
        config: Config = .default
    ) -> [SafeTrio] {
        let n = pool.count
        guard n >= 3, raw.count == n * n, leadCount > 0, teamsPerLead > 0 else { return [] }
        let threat = leadThreats(pool: pool, ratings: raw, metaRelevantCount: metaRelevantCount)
        let leads = chooseLeads(pool: pool, leadThreat: threat, count: leadCount, rule: config.leadRule)
        let all = leads.flatMap {
            bestCovers(lead: $0, leadThreat: threat[$0], pool: pool, ratings: raw,
                       teamsPerLead: teamsPerLead, config: config)
        }
        return merge(all)
    }

    // MARK: - Stage 1: safe leads

    /// Mean softened rating of the meta attacking each pool member — the same
    /// transform the Team Builder uses for threats, so a rank-weighted meta
    /// pressure. Lower = safer.
    static func leadThreats(pool: [TeamFinder.Candidate], ratings raw: [Int], metaRelevantCount: Int) -> [Double] {
        let n = pool.count
        return (0..<n).map { lead in
            var sum = 0.0
            var count = 0
            for t in 0..<n where t != lead && pool[t].member.speciesId != pool[lead].member.speciesId {
                sum += TeamAnalyzer.softScore(Double(raw[t * n + lead]), metaRelevant: t < metaRelevantCount)
                count += 1
            }
            return count > 0 ? sum / Double(count) : 500
        }
    }

    /// Type weakness of each pool member against the cup's legal attacking types
    /// (the union of the pool's own types): the summed excess over neutral, so a
    /// double weakness counts more than a single one. Lower = safer.
    static func typeWeaknesses(pool: [TeamFinder.Candidate]) -> [Double] {
        let attackTypes = Set(pool.flatMap(\.types)).subtracting(["none"])
        return pool.map { c in
            attackTypes.reduce(0.0) { sum, type in
                sum + max(0, TypeChart.effectiveness(moveType: type, targetTypes: c.types) - 1)
            }
        }
    }

    /// The `count` safest members under `rule`, one per evolutionary family (so
    /// a shadow and regular copy don't eat two lead slots), safest first.
    static func chooseLeads(
        pool: [TeamFinder.Candidate], leadThreat: [Double], count: Int,
        rule: LeadRule = .matchupPressure
    ) -> [Int] {
        let weakness = rule == .typeWeakness ? typeWeaknesses(pool: pool) : []
        let order = pool.indices.sorted { a, b in
            if rule == .typeWeakness, abs(weakness[a] - weakness[b]) > 1e-9 {
                return weakness[a] < weakness[b]
            }
            return leadThreat[a] != leadThreat[b] ? leadThreat[a] < leadThreat[b] : a < b
        }
        var leads: [Int] = []
        var families = Set<String>()
        for index in order {
            let key = pool[index].familyId ?? pool[index].member.speciesId
            guard families.insert(key).inserted else { continue }
            leads.append(index)
            if leads.count == count { break }
        }
        return leads
    }

    // MARK: - Stage 2: cover pairs

    /// The best back pairs for one lead, best first (at most `teamsPerLead`).
    static func bestCovers(
        lead: Int, leadThreat: Double,
        pool: [TeamFinder.Candidate], ratings raw: [Int], teamsPerLead: Int,
        config: Config = .default
    ) -> [SafeTrio] {
        let n = pool.count

        // Holes: meta members that beat the lead, weighted by how badly.
        var holes: [(threat: Int, weight: Double)] = []
        for t in 0..<n where t != lead && pool[t].member.speciesId != pool[lead].member.speciesId {
            let rating = raw[t * n + lead]
            if rating > 500 { holes.append((t, Double(rating - 500))) }
        }
        let holeWeight = holes.reduce(0) { $0 + $1.weight }

        let mates = (0..<n).filter { $0 != lead && TeamFinder.distinct(pool[$0], pool[lead]) }
        guard mates.count >= 2 else { return [] }

        var scored: [(back: [Int], score: Double)] = []
        for (x, b) in mates.enumerated() {
            for c in mates[(x + 1)...] where TeamFinder.distinct(pool[b], pool[c]) {
                if Task.isCancelled { return [] }

                // How well the best of the pair answers the lead's holes.
                var holeCover = 500.0
                var shared = 0.0
                if holeWeight > 0, config.holeCoverWeight > 0 || config.sharedHolePenalty > 0 {
                    var cover = 0.0
                    for h in holes {
                        cover += h.weight * Double(max(raw[b * n + h.threat], raw[c * n + h.threat]))
                        if raw[h.threat * n + b] > 500 { shared += h.weight }
                        if raw[h.threat * n + c] > 500 { shared += h.weight }
                    }
                    holeCover = cover / holeWeight
                    shared /= 2 * holeWeight
                }

                // How well the whole team covers every other pool member.
                var wide = 0.0
                var count = 0
                for t in 0..<n where t != lead && t != b && t != c {
                    wide += Double(max(raw[lead * n + t], raw[b * n + t], raw[c * n + t]))
                    count += 1
                }
                let teamCover = count > 0 ? wide / Double(count) : 500

                let score = config.holeCoverWeight * holeCover + config.teamCoverWeight * teamCover
                    - config.sharedHolePenalty * shared - config.leadSafetyWeight * leadThreat

                // Switch before closer: the back member that answers the holes better.
                let bCover = holes.reduce(0.0) { $0 + $1.weight * Double(raw[b * n + $1.threat]) }
                let cCover = holes.reduce(0.0) { $0 + $1.weight * Double(raw[c * n + $1.threat]) }
                scored.append((bCover >= cCover ? [b, c] : [c, b], score))
            }
        }
        scored.sort { $0.score > $1.score }

        // Greedy pick, keeping any one teammate from dominating the lead's list.
        var uses: [Int: Int] = [:]
        var picked: [SafeTrio] = []
        for entry in scored {
            if entry.back.contains(where: { uses[$0, default: 0] >= maxUsesPerMate }) { continue }
            for member in entry.back { uses[member, default: 0] += 1 }
            picked.append(SafeTrio(indices: [lead] + entry.back, score: entry.score, leadThreat: leadThreat))
            if picked.count == teamsPerLead { break }
        }
        return picked
    }

    /// Dedupes the same three Pokémon reached via different leads (keeping the
    /// better-scored arrangement) and ranks best first.
    private static func merge(_ trios: [SafeTrio]) -> [SafeTrio] {
        var best: [[Int]: SafeTrio] = [:]
        for trio in trios {
            let key = trio.indices.sorted()
            if let existing = best[key], existing.score >= trio.score { continue }
            best[key] = trio
        }
        return best.values.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.indices.lexicographicallyPrecedes($1.indices)
        }
    }
}
