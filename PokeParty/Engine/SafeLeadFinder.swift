//
//  SafeLeadFinder.swift
//  PokeParty
//
//  The Party Finder's "Safe lead + cover" mode, modelled on a common ladder
//  team-building recipe: put a SAFE Pokémon in the lead (few bad matchups in
//  the meta) and fill the back two so the team covers what the meta throws at
//  it, with a strong closer in the back.
//
//  Two separate lists, both in ranking order:
//    - CANDIDATES: who may be on a team (the candidate pool);
//    - OPPONENTS: what a team has to beat (the opponent field).
//  Opponents are weighted by rank — rank 1 counts far more than rank 200 — so
//  the answer doesn't swing with how many obscure Pokémon the pool happens to
//  include, and a full candidate pool can still be judged against the real meta.
//
//  Like `GradeFinder` this needs only pairwise 1v1 ratings (candidates ×
//  opponents, one simulation per pair serving both directions), so no 3v3
//  battles are fought here:
//    1. Rank every candidate by lead threat — the weighted mean softened rating
//       of the opponents attacking it (lower = safer) — and keep every lead
//       whose threat is within a margin of the best, one per evolutionary family.
//    2. For each lead, score every compatible back pair by the weighted mean of
//       the best answer on the team to each opponent, plus a bonus for a strong
//       closer; keep the best few pairs per lead (no teammate dominating).
//    3. Merge across leads and rank.
//
//  The result is a list of trios (lead first) that `GradeFinder.gradeTrios`
//  grades for display and, optionally, the tournament verifies. Ties break on
//  indices, so a run is reproducible however the parallel work interleaves.
//

import Foundation

nonisolated enum SafeLeadFinder {

    /// A chosen team: candidate indices (lead, then the two back members) and
    /// the heuristic score it was ranked by (higher = better).
    struct SafeTrio: Sendable, Hashable {
        let indices: [Int]
        let score: Double
        /// The lead's weighted mean softened threat (lower = safer).
        let leadThreat: Double
    }

    /// Candidates attacking, and attacked by, the opponent field. Candidate `c`
    /// and opponent `j` index the same ranked list (`all`), so opponent `j` is
    /// also candidate `j` when `j < candidateCount`.
    struct RatingField: Sendable {
        let candidateCount: Int
        let opponentCount: Int
        /// `mine[c * opponentCount + j]`: candidate c's 1v1 rating attacking opponent j.
        let mine: [Int]
        /// `theirs[c * opponentCount + j]`: opponent j's rating attacking candidate c.
        let theirs: [Int]

        /// Wraps a square pool-vs-pool matrix (`raw[a * n + b]` = a's rating
        /// attacking b) — handy for tests and small hand-built pools.
        init(squareRatings raw: [Int], count n: Int) {
            candidateCount = n
            opponentCount = n
            mine = raw
            var t = [Int](repeating: 500, count: n * n)
            for c in 0..<n { for j in 0..<n { t[c * n + j] = raw[j * n + c] } }
            theirs = t
        }

        init(candidateCount: Int, opponentCount: Int, mine: [Int], theirs: [Int]) {
            self.candidateCount = candidateCount
            self.opponentCount = opponentCount
            self.mine = mine
            self.theirs = theirs
        }

        /// The same field restricted to the top `count` opponents.
        func prefix(opponents count: Int) -> RatingField {
            let o = min(max(count, 0), opponentCount)
            guard o < opponentCount else { return self }
            var m = [Int](repeating: 500, count: candidateCount * o)
            var t = m
            for c in 0..<candidateCount {
                for j in 0..<o {
                    m[c * o + j] = mine[c * opponentCount + j]
                    t[c * o + j] = theirs[c * opponentCount + j]
                }
            }
            return RatingField(candidateCount: candidateCount, opponentCount: o, mine: m, theirs: t)
        }

        /// `[t * candidateCount + c]`: opponent t's rating attacking candidate c —
        /// the layout `GradeFinder.gradeTrios` takes for its threats.
        var threatRatings: [Int] {
            var out = [Int](repeating: 500, count: opponentCount * candidateCount)
            for c in 0..<candidateCount {
                for t in 0..<opponentCount { out[t * candidateCount + c] = theirs[c * opponentCount + t] }
            }
            return out
        }
    }

    /// The tunable knobs of the heuristic. Defaults come from replicated sweeps on
    /// the LAIC GBL and Great League lists (heuristic and learned AI), scoring each
    /// setting's top-20 teams by win rate against random teams drawn by rank
    /// weight from the whole list; per-condition noise is ~±1.5 points, so don't
    /// re-tune on a single run. What they showed:
    ///  - the opponent field should be the WHOLE ranked list, weighted `1 / rank`:
    ///    cutting it off at rank 250 or 100 lost 1–4 points (Pokémon below the
    ///    cutoff stop counting at all), steeper decays lost up to 10 on LAIC, and
    ///    flatter ones lost 3–4 on Great League;
    ///  - candidates should stay near the top: the top-20 teams won ~71% with 150
    ///    candidates but ~66% with 300 and ~65% with the whole list (1v1 ratings
    ///    over a huge pool pick flukes), and a rank prior on candidates did not fix it;
    ///  - leads' teams stay ~68–71% through lead rank 20 (threat ≈ 1.4× the best
    ///    lead's) and fade to ~65% by rank 40–60;
    ///  - favoring a strong closer in the back helps (+1.4 points at 240; ~0 by 480);
    ///    a bulk bonus, safe-swap-score leads, and type-weakness leads did not.
    struct Config: Sendable {
        /// Candidates beyond this rank are ignored (see above).
        var maxCandidates = 150
        /// Opponent weight at rank r (0-based) is `1 / (r + 1)^opponentDecay`.
        var opponentDecay = 1.0
        /// Rating points per 100 closer-score points of the better closer among
        /// the two back members (0 when a Pokémon has no ranking data).
        var backCloserWeight = 240.0
        /// A lead stays in while its threat is within this fraction of the best
        /// lead's (so leads are taken only until they stop being good leads).
        var leadMargin = 0.4
        var minLeads = 3
        var maxLeads = 40
        var teamsPerLead = 5

        static let `default` = Config()
    }

    /// A back teammate may appear in at most this many of one lead's teams.
    private static let maxUsesPerMate = 2

    /// `1 / (rank + 1)^decay` for the top `count` opponents — rank 1 is far more
    /// likely to be faced than rank 200.
    static func opponentWeights(count: Int, decay: Double) -> [Double] {
        (0..<max(count, 0)).map { pow(1 / Double($0 + 1), decay) }
    }

    // MARK: - Entry points

    /// Builds the rating field and selects the safe-lead teams, best first.
    /// `all` is the ranked list: the first `candidateCount` Pokémon (at most
    /// `config.maxCandidates`) are the candidates and the first `opponentCount`
    /// the opponents (so `all` holds at least the larger of the two). Returns the
    /// field too — its `candidateCount` is the number actually used — so the
    /// caller can grade the trios without recomputing it. Runs off the main actor.
    static func findTrios(
        all: [TeamFinder.Candidate],
        candidateCount: Int,
        opponentCount: Int,
        movesById: [String: Move],
        config: Config = .default,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async -> (trios: [SafeTrio], field: RatingField) {
        let c = min(candidateCount, all.count, config.maxCandidates), o = min(opponentCount, all.count)
        let empty = RatingField(candidateCount: 0, opponentCount: 0, mine: [], theirs: [])
        guard c >= 3, o > 0 else { return ([], empty) }
        let field = await ratingField(all: all, candidateCount: c, opponentCount: o, movesById: movesById) { fraction in
            onProgress?(fraction * 0.9)
        }
        if Task.isCancelled { return ([], field) }

        let weights = opponentWeights(count: o, decay: config.opponentDecay)
        let threat = leadThreats(all: all, field: field, weights: weights)
        let leads = chooseLeads(all: all, leadThreat: threat, candidateCount: c, config: config)

        var found: [SafeTrio] = []
        var done = 0
        await withTaskGroup(of: [SafeTrio].self) { group in
            for lead in leads {
                group.addTask {
                    bestCovers(lead: lead, leadThreat: threat[lead], all: all, field: field,
                               weights: weights, config: config)
                }
            }
            for await part in group {
                done += 1
                onProgress?(0.9 + 0.1 * Double(done) / Double(max(leads.count, 1)))
                found.append(contentsOf: part)
            }
        }
        return (merge(found), field)
    }

    /// Synchronous selection from a precomputed field — the core of
    /// `findTrios`, exposed so it can be tested and tuned without simulations.
    static func select(
        all: [TeamFinder.Candidate], field: RatingField, config: Config = .default
    ) -> [SafeTrio] {
        guard field.candidateCount >= 3, field.opponentCount > 0 else { return [] }
        let weights = opponentWeights(count: field.opponentCount, decay: config.opponentDecay)
        let threat = leadThreats(all: all, field: field, weights: weights)
        let leads = chooseLeads(all: all, leadThreat: threat, candidateCount: field.candidateCount, config: config)
        return merge(leads.flatMap {
            bestCovers(lead: $0, leadThreat: threat[$0], all: all, field: field, weights: weights, config: config)
        })
    }

    // MARK: - Ratings

    /// One 1v1 per candidate/opponent pair at 1 shield each. A pair that is in
    /// the grid both ways (both Pokémon are candidates and opponents) is
    /// simulated once and fills both directions.
    static func ratingField(
        all: [TeamFinder.Candidate], candidateCount c: Int, opponentCount o: Int,
        movesById: [String: Move],
        progress: (@Sendable (Double) -> Void)? = nil
    ) async -> RatingField {
        var mine = [Int](repeating: 500, count: c * o)
        var theirs = mine
        // Row c simulates (c, j) unless row j already covers the mirror (j, c).
        let totalPairs = (0..<c).reduce(0) { sum, row in
            sum + (0..<o).filter { $0 != row && !(($0 < row) && row < o && $0 < c) }.count
        }
        var completed = 0
        await withTaskGroup(of: (Int, [(j: Int, a: Int, b: Int)]).self) { group in
            for row in 0..<c {
                group.addTask {
                    var out: [(j: Int, a: Int, b: Int)] = []
                    for j in 0..<o where j != row && !((j < row) && row < o && j < c) {
                        if Task.isCancelled { break }
                        guard let r = MatchupSimulator.rate(
                            all[row].combatant, statsA: all[row].stats,
                            all[j].combatant, statsB: all[j].stats,
                            movesById: movesById, shieldsA: 1, shieldsB: 1)
                        else { continue }
                        out.append((j, r.a, r.b))
                    }
                    return (row, out)
                }
            }
            for await (row, results) in group {
                completed += results.count
                progress?(Double(completed) / Double(max(totalPairs, 1)))
                for (j, a, b) in results {
                    mine[row * o + j] = a
                    theirs[row * o + j] = b
                    if j < c && row < o {                       // the mirror direction
                        mine[j * o + row] = b
                        theirs[j * o + row] = a
                    }
                }
            }
        }
        return RatingField(candidateCount: c, opponentCount: o, mine: mine, theirs: theirs)
    }

    // MARK: - Stage 1: safe leads

    /// Weighted mean softened rating of the opponents attacking each candidate
    /// (the Team Builder's threat transform, so a rank-weighted meta pressure).
    /// Lower = safer.
    static func leadThreats(
        all: [TeamFinder.Candidate], field: RatingField, weights: [Double], metaRelevantCount: Int = 40
    ) -> [Double] {
        let o = field.opponentCount
        return (0..<field.candidateCount).map { c in
            var sum = 0.0, weight = 0.0
            for j in 0..<o where j != c && all[j].member.speciesId != all[c].member.speciesId {
                sum += weights[j] * TeamAnalyzer.softScore(Double(field.theirs[c * o + j]), metaRelevant: j < metaRelevantCount)
                weight += weights[j]
            }
            return weight > 0 ? sum / weight : 500
        }
    }

    /// The safest candidates, one per evolutionary family (so a shadow and
    /// regular copy don't eat two lead slots), kept while their threat stays
    /// within `leadMargin` of the best lead's — at least `minLeads`, at most
    /// `maxLeads`. Safest first.
    static func chooseLeads(
        all: [TeamFinder.Candidate], leadThreat: [Double], candidateCount: Int, config: Config
    ) -> [Int] {
        let order = (0..<candidateCount).sorted {
            leadThreat[$0] != leadThreat[$1] ? leadThreat[$0] < leadThreat[$1] : $0 < $1
        }
        var perFamily: [Int] = []
        var families = Set<String>()
        for index in order {
            let key = all[index].familyId ?? all[index].member.speciesId
            if families.insert(key).inserted { perFamily.append(index) }
        }
        guard let best = perFamily.first.map({ leadThreat[$0] }) else { return [] }
        let cutoff = best * (1 + config.leadMargin)
        var leads: [Int] = []
        for index in perFamily {
            if leads.count >= config.maxLeads { break }
            if leads.count >= config.minLeads && leadThreat[index] > cutoff { break }
            leads.append(index)
        }
        return leads
    }

    // MARK: - Stage 2: cover pairs

    /// The best back pairs for one lead, best first (at most `teamsPerLead`).
    static func bestCovers(
        lead: Int, leadThreat: Double,
        all: [TeamFinder.Candidate], field: RatingField, weights: [Double], config: Config
    ) -> [SafeTrio] {
        let c = field.candidateCount, o = field.opponentCount
        let mine = field.mine
        let mates = (0..<c).filter { $0 != lead && TeamFinder.distinct(all[$0], all[lead]) }
        guard mates.count >= 2 else { return [] }

        let leadBase = lead * o
        let totalWeight = weights.reduce(0, +)
        var pairBest = [Double](repeating: 0, count: o)
        var scored: [(back: [Int], score: Double)] = []

        for (x, b) in mates.enumerated() {
            let bBase = b * o
            for j in 0..<o { pairBest[j] = Double(max(mine[leadBase + j], mine[bBase + j])) }
            for d in mates[(x + 1)...] where TeamFinder.distinct(all[b], all[d]) {
                if Task.isCancelled { return [] }
                let dBase = d * o

                // Weighted mean of the best answer on the team to each opponent.
                var sum = 0.0
                for j in 0..<o { sum += weights[j] * max(pairBest[j], Double(mine[dBase + j])) }
                var weight = totalWeight
                for member in [lead, b, d] where member < o {   // a team member isn't its own opponent
                    let best = max(mine[leadBase + member], mine[bBase + member], mine[dBase + member])
                    sum -= weights[member] * Double(best)
                    weight -= weights[member]
                }
                let teamCover = weight > 0 ? sum / weight : 500

                let closerB = all[b].closerScore ?? 0, closerD = all[d].closerScore ?? 0
                let score = teamCover + config.backCloserWeight * max(closerB, closerD) / 100

                // Switch before closer: the stronger closer goes last.
                scored.append((closerB <= closerD ? [b, d] : [d, b], score))
            }
        }
        scored.sort {
            $0.score != $1.score ? $0.score > $1.score : $0.back.lexicographicallyPrecedes($1.back)
        }

        // Greedy pick, keeping any one teammate from dominating the lead's list.
        var uses: [Int: Int] = [:]
        var picked: [SafeTrio] = []
        for entry in scored {
            if entry.back.contains(where: { uses[$0, default: 0] >= maxUsesPerMate }) { continue }
            for member in entry.back { uses[member, default: 0] += 1 }
            picked.append(SafeTrio(indices: [lead] + entry.back, score: entry.score, leadThreat: leadThreat))
            if picked.count == config.teamsPerLead { break }
        }
        return picked
    }

    /// Dedupes the same three Pokémon reached via different leads — keeping the
    /// arrangement with the safer lead, then the lower indices, so the result
    /// doesn't depend on which parallel task finished first — and ranks best first.
    private static func merge(_ trios: [SafeTrio]) -> [SafeTrio] {
        func better(_ a: SafeTrio, than b: SafeTrio) -> Bool {
            if a.score != b.score { return a.score > b.score }
            if a.leadThreat != b.leadThreat { return a.leadThreat < b.leadThreat }
            return a.indices.lexicographicallyPrecedes(b.indices)
        }
        var best: [[Int]: SafeTrio] = [:]
        for trio in trios {
            let key = trio.indices.sorted()
            if let existing = best[key], !better(trio, than: existing) { continue }
            best[key] = trio
        }
        return best.values.sorted { better($0, than: $1) }
    }
}
