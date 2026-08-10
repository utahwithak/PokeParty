//
//  GradeFinder.swift
//  PokeParty
//
//  The Party Finder's static-analysis mode: enumerate every distinct trio from
//  the candidate pool and rank them by the Team Builder's grades (Coverage,
//  Bulk, Safety and Consistency) — no 3v3 battle simulations at all. Teams are
//  ordered by their WORST category (the value/goal fraction), so AAAA teams
//  (every fraction ≥ 0.9) always rank above everything else and the list
//  degrades gracefully to "best available grades" in metas with no AAAA trio.
//
//  The trick that makes ~2.6M trios (a top-250 pool) tractable: the Team
//  Builder's only expensive input is the meta-vs-member 1v1 ratings, and those
//  are PAIRWISE. One n×n rating matrix (one fast 1v1 per unordered pair, at the
//  Team Builder's 1-shield default) is computed up front, and every trio is then
//  graded with pure array arithmetic using the exact same formulas as
//  `TeamAnalyzer` (softScore ordering, top-6 distinct-family counter team, the
//  PvPoke grade goals).
//

import Foundation

nonisolated enum GradeFinder {

    /// A graded trio: the four Team Builder grades and the raw values behind
    /// them, ranked by the worst category.
    struct GradedTeam: Identifiable, Sendable, Hashable, Codable {
        let members: [TeamFinder.RankedTeam.Member]
        /// The members as pool indices (lead first) — lets the combined finder
        /// method hand AAAA teams straight to the tournament as its field.
        let poolIndices: [Int]

        let coverage: LetterGrade
        let bulk: LetterGrade
        let safety: LetterGrade
        let consistency: LetterGrade

        /// avgThreatScore: mean rating of the top-6 distinct threats (lower = better).
        let threatScore: Int
        let coverageValue: Double
        let bulkValue: Double
        let safetyValue: Double
        let consistencyValue: Double
        /// The worst category's value/goal fraction — the ranking key. ≥ 0.9
        /// exactly when the team is AAAA.
        let minGradeFraction: Double

        var isAAAA: Bool { minGradeFraction >= 0.9 }
        /// e.g. "AAAA" or "ABAB", in Coverage/Bulk/Safety/Consistency order.
        var gradeString: String {
            [coverage, bulk, safety, consistency].map(\.rawValue).joined()
        }

        var id: String {
            members.map { m in
                m.shadow && !m.member.speciesId.hasSuffix("_shadow")
                    ? m.member.speciesId + "_shadow"
                    : m.member.speciesId
            }.joined(separator: "+")
        }
    }

    /// Coverage/consistency/safety goals, from `TeamAnalyzer.analyze`.
    private static let coverageGoal = 680.0
    private static let consistencyGoal = 98.0
    private static let safetyGoal = 98.0

    /// Grades every distinct trio in the pool and returns the best `maxResults`,
    /// ranked by worst category (AAAA teams first, then best-available grades).
    /// `onProgress` (0…1) spans the pairwise matrix and the trio sweep; both run
    /// off the main actor.
    static func findTopGradedTeams(
        pool: [TeamFinder.Candidate],
        cpCap: Int,
        movesById: [String: Move],
        metaRelevantCount: Int = 40,
        maxResults: Int = 100,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async -> [GradedTeam] {
        let n = pool.count
        guard n >= 3, maxResults > 0 else { return [] }

        // --- Pairwise rating matrix (the only battles fought) ------------------
        // raw[i*n + j] = pool[i]'s 1v1 rating attacking pool[j], 1 shield each
        // (the Team Builder default). The diagonal stays at 500 and is never read.
        let raw = await ratingMatrix(pool: pool, movesById: movesById) { fraction in
            onProgress?(fraction * 0.7)
        }
        if Task.isCancelled { return [] }

        // Softened threat scores order the counter team exactly as the Team
        // Builder does; meta weighting follows the attacker's ranking position.
        var soft = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            let metaRelevant = i < metaRelevantCount
            for j in 0..<n where i != j {
                soft[i * n + j] = TeamAnalyzer.softScore(Double(raw[i * n + j]), metaRelevant: metaRelevant)
            }
        }

        // --- Per-member grade inputs -------------------------------------------
        let bulk: [Double] = pool.map { c in
            c.stats.def * (c.shadow ? DamageMultiplier.shadowDef : 1) * Double(c.stats.hp)
        }
        let consistency: [Double] = pool.map {
            Consistency.score(fastMoveId: $0.combatant.fastMoveId,
                              chargedMoveIds: $0.combatant.chargedMoveIds,
                              types: $0.combatant.species.types,
                              movesById: movesById)
        }
        let safety: [Double] = pool.map { $0.switchesScore ?? 60 }   // PvPoke default
        let famKey: [String?] = pool.map(\.familyId)
        let speciesIds: [String] = pool.map(\.member.speciesId)
        let bulkGoal = TeamAnalyzer.bulkGoal(cpCap: cpCap)

        // Pairwise team compatibility (no shared species/family), computed once.
        var compatible = [Bool](repeating: false, count: n * n)
        for i in 0..<n {
            for j in (i + 1)..<n where TeamFinder.distinct(pool[i], pool[j]) {
                compatible[i * n + j] = true
                compatible[j * n + i] = true
            }
        }

        // --- Sweep every trio, fanned out by lead index -------------------------
        var all: [GradedTeam] = []
        var completedLeads = 0
        await withTaskGroup(of: [GradedTeam].self) { [raw, soft, compatible] group in
            for i in 0..<n {
                group.addTask {
                    gradeTrios(lead: i, n: n, pool: pool,
                               raw: raw, soft: soft, compatible: compatible,
                               bulk: bulk, consistency: consistency, safety: safety,
                               famKey: famKey, speciesIds: speciesIds,
                               bulkGoal: bulkGoal, maxResults: maxResults)
                }
            }
            for await part in group {
                completedLeads += 1
                onProgress?(0.7 + 0.3 * Double(completedLeads) / Double(n))
                all.append(contentsOf: part)
            }
        }

        all.sort(by: orderedBefore)
        return Array(all.prefix(maxResults))
    }

    /// Worst grade first is best: highest min fraction, then best coverage,
    /// then id for deterministic runs.
    private static func orderedBefore(_ a: GradedTeam, _ b: GradedTeam) -> Bool {
        if a.minGradeFraction != b.minGradeFraction { return a.minGradeFraction > b.minGradeFraction }
        if a.threatScore != b.threatScore { return a.threatScore < b.threatScore }
        return a.id < b.id
    }

    /// Grades every trio led by pool index `i` (j, k > i), returning its local
    /// best-`maxResults` (a bounded selection so the sweep never materializes
    /// millions of teams).
    private static func gradeTrios(
        lead i: Int, n: Int, pool: [TeamFinder.Candidate],
        raw: [Int], soft: [Double], compatible: [Bool],
        bulk: [Double], consistency: [Double], safety: [Double],
        famKey: [String?], speciesIds: [String],
        bulkGoal: Double, maxResults: Int
    ) -> [GradedTeam] {
        var local: [GradedTeam] = []
        // Once the local selection is full, trios whose CHEAP categories already
        // rank below the kept worst can skip the coverage pass entirely (the
        // overall min fraction can only be lower still).
        var cutoff = -Double.infinity
        func trimLocal() {
            local.sort(by: orderedBefore)
            local.removeLast(local.count - maxResults)
            cutoff = local[maxResults - 1].minGradeFraction
        }

        // Counter-team selection buffers, reused across trios: the ≤6 best-scoring
        // threats, at most one per family (per-family best is equivalent to the
        // Team Builder's greedy walk down the sorted threat list).
        var selScore = [Double](repeating: 0, count: 6)
        var selRaw = [Int](repeating: 0, count: 6)
        var selFam = [String?](repeating: nil, count: 6)

        for j in (i + 1)..<n where compatible[i * n + j] {
            if Task.isCancelled { return [] }
            for k in (j + 1)..<n where compatible[i * n + k] && compatible[j * n + k] {
                let bulkValue = (bulk[i] + bulk[j] + bulk[k]) / 3
                let consistencyValue = (consistency[i] + consistency[j] + consistency[k]) / 3
                let safetyValue = (safety[i] + safety[j] + safety[k]) / 3
                let cheapMin = min(bulkValue / bulkGoal,
                                   consistencyValue / consistencyGoal,
                                   safetyValue / safetyGoal)
                if cheapMin <= cutoff { continue }

                // Coverage: top-6 distinct-family threats by softened score.
                var selCount = 0
                var minIndex = 0
                for t in 0..<n where t != i && t != j && t != k {
                    let s = soft[t * n + i] + soft[t * n + j] + soft[t * n + k]
                    if selCount == 6 && s <= selScore[minIndex] { continue }
                    let sid = speciesIds[t]
                    if sid == speciesIds[i] || sid == speciesIds[j] || sid == speciesIds[k] { continue }
                    // Matches TeamAnalyzer: integer mean of the raw per-member ratings.
                    let avgRaw = (raw[t * n + i] + raw[t * n + j] + raw[t * n + k]) / 3

                    if let fam = famKey[t],
                       let existing = (0..<selCount).first(where: { selFam[$0] == fam }) {
                        if s > selScore[existing] {
                            selScore[existing] = s
                            selRaw[existing] = avgRaw
                        }
                    } else if selCount < 6 {
                        selScore[selCount] = s
                        selRaw[selCount] = avgRaw
                        selFam[selCount] = famKey[t]
                        selCount += 1
                    } else {
                        selScore[minIndex] = s
                        selRaw[minIndex] = avgRaw
                        selFam[minIndex] = famKey[t]
                    }
                    if selCount == 6 {
                        minIndex = 0
                        for m in 1..<6 where selScore[m] < selScore[minIndex] { minIndex = m }
                    }
                }

                let threatScore: Int
                if selCount == 0 {
                    threatScore = 500
                } else {
                    var sum = 0
                    for m in 0..<selCount { sum += selRaw[m] }
                    threatScore = Int((Double(sum) / Double(selCount)).rounded())
                }
                let coverageValue = 1200 - Double(threatScore)
                let minFraction = min(cheapMin, coverageValue / coverageGoal)
                if minFraction <= cutoff { continue }

                local.append(GradedTeam(
                    members: [i, j, k].map { idx in
                        let c = pool[idx]
                        return TeamFinder.RankedTeam.Member(
                            member: c.member, speciesName: c.speciesName,
                            types: c.types, shadow: c.shadow)
                    },
                    poolIndices: [i, j, k],
                    coverage: LetterGrade.grade(value: coverageValue, goal: coverageGoal),
                    bulk: LetterGrade.grade(value: bulkValue, goal: bulkGoal),
                    safety: LetterGrade.grade(value: safetyValue, goal: safetyGoal),
                    consistency: LetterGrade.grade(value: consistencyValue, goal: consistencyGoal),
                    threatScore: threatScore,
                    coverageValue: coverageValue,
                    bulkValue: bulkValue,
                    safetyValue: safetyValue,
                    consistencyValue: consistencyValue,
                    minGradeFraction: minFraction))
                if local.count >= maxResults * 2 { trimLocal() }
            }
        }
        if local.count > maxResults { trimLocal() }
        return local
    }

    // MARK: - Bench team finder

    /// Grades every distinct bench trio against the full meta field and returns
    /// the best `maxResults` ordered the same way as `findTopGradedTeams`.
    ///
    /// The key difference from the meta-pool grade check: coverage is measured
    /// by how well the bench trio handles the META's top threats, not bench-vs-bench.
    /// Uses a rectangular `metaCount × benchCount` rating matrix:
    ///   `rawMB[t * b + bi]` = meta[t]'s 1v1 rating vs bench[bi].
    static func findBenchTeams(
        bench: [TeamFinder.Candidate],
        meta: [TeamFinder.Candidate],
        cpCap: Int,
        movesById: [String: Move],
        metaRelevantCount: Int = 40,
        maxResults: Int = 100,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async -> [GradedTeam] {
        let b = bench.count
        let m = meta.count
        guard b >= 3, m > 0, maxResults > 0 else { return [] }

        // --- Rectangular meta×bench rating matrix ---
        let rawMB = await benchVsMetaMatrix(meta: meta, bench: bench, movesById: movesById) { fraction in
            onProgress?(fraction * 0.7)
        }
        if Task.isCancelled { return [] }

        var softMB = [Double](repeating: 0, count: m * b)
        for t in 0..<m {
            let metaRelevant = t < metaRelevantCount
            for bi in 0..<b {
                softMB[t * b + bi] = TeamAnalyzer.softScore(Double(rawMB[t * b + bi]), metaRelevant: metaRelevant)
            }
        }

        let bulkValues: [Double] = bench.map { c in
            c.stats.def * (c.shadow ? DamageMultiplier.shadowDef : 1) * Double(c.stats.hp)
        }
        let consistencyValues: [Double] = bench.map {
            Consistency.score(fastMoveId: $0.combatant.fastMoveId,
                              chargedMoveIds: $0.combatant.chargedMoveIds,
                              types: $0.combatant.species.types,
                              movesById: movesById)
        }
        let safetyValues: [Double] = bench.map { $0.switchesScore ?? 60 }
        let benchFamKey: [String?] = bench.map(\.familyId)
        let benchSpeciesIds: [String] = bench.map(\.member.speciesId)
        let metaFamKey: [String?] = meta.map(\.familyId)
        let metaSpeciesIds: [String] = meta.map(\.member.speciesId)
        let bulkGoal = TeamAnalyzer.bulkGoal(cpCap: cpCap)

        var compatible = [Bool](repeating: false, count: b * b)
        for bi in 0..<b {
            for bj in (bi + 1)..<b where TeamFinder.distinct(bench[bi], bench[bj]) {
                compatible[bi * b + bj] = true
                compatible[bj * b + bi] = true
            }
        }

        var all: [GradedTeam] = []
        var completedLeads = 0
        await withTaskGroup(of: [GradedTeam].self) { [rawMB, softMB, compatible] group in
            for lead in 0..<b {
                group.addTask {
                    gradeBenchTrios(
                        lead: lead, b: b, metaCount: m, bench: bench,
                        rawMB: rawMB, softMB: softMB, compatible: compatible,
                        bulkValues: bulkValues, consistencyValues: consistencyValues,
                        safetyValues: safetyValues,
                        benchFamKey: benchFamKey, benchSpeciesIds: benchSpeciesIds,
                        metaFamKey: metaFamKey, metaSpeciesIds: metaSpeciesIds,
                        bulkGoal: bulkGoal, maxResults: maxResults)
                }
            }
            for await part in group {
                completedLeads += 1
                onProgress?(0.7 + 0.3 * Double(completedLeads) / Double(b))
                all.append(contentsOf: part)
            }
        }

        all.sort(by: orderedBefore)
        return Array(all.prefix(maxResults))
    }

    /// `rawMB[t * b + bi]` = meta[t]'s 1v1 rating vs bench[bi] (meta's perspective).
    private static func benchVsMetaMatrix(
        meta: [TeamFinder.Candidate], bench: [TeamFinder.Candidate],
        movesById: [String: Move],
        progress: (@Sendable (Double) -> Void)? = nil
    ) async -> [Int] {
        let m = meta.count
        let b = bench.count
        var matrix = [Int](repeating: 500, count: m * b)
        let totalPairs = m * b
        guard totalPairs > 0 else { return matrix }

        var completedPairs = 0
        await withTaskGroup(of: (t: Int, bi: Int, rating: Int)?.self) { group in
            for t in 0..<m {
                for bi in 0..<b {
                    group.addTask {
                        guard !Task.isCancelled,
                              let r = MatchupSimulator.rate(
                                meta[t].combatant, statsA: meta[t].stats,
                                bench[bi].combatant, statsB: bench[bi].stats,
                                movesById: movesById, shieldsA: 1, shieldsB: 1)
                        else { return nil }
                        return (t, bi, r.a)
                    }
                }
            }
            for await pair in group {
                completedPairs += 1
                if completedPairs % 256 == 0 || completedPairs == totalPairs {
                    progress?(Double(completedPairs) / Double(totalPairs))
                }
                if let pair {
                    matrix[pair.t * b + pair.bi] = pair.rating
                }
            }
        }
        return matrix
    }

    /// Grades all bench trios led by bench index `lead` against the meta field.
    private static func gradeBenchTrios(
        lead: Int, b: Int, metaCount: Int, bench: [TeamFinder.Candidate],
        rawMB: [Int], softMB: [Double], compatible: [Bool],
        bulkValues: [Double], consistencyValues: [Double], safetyValues: [Double],
        benchFamKey: [String?], benchSpeciesIds: [String],
        metaFamKey: [String?], metaSpeciesIds: [String],
        bulkGoal: Double, maxResults: Int
    ) -> [GradedTeam] {
        var local: [GradedTeam] = []
        var cutoff = -Double.infinity
        func trimLocal() {
            local.sort(by: orderedBefore)
            local.removeLast(local.count - maxResults)
            cutoff = local[maxResults - 1].minGradeFraction
        }

        var selScore = [Double](repeating: 0, count: 6)
        var selRaw = [Int](repeating: 0, count: 6)
        var selFam = [String?](repeating: nil, count: 6)

        let bi = lead
        for bj in (bi + 1)..<b where compatible[bi * b + bj] {
            if Task.isCancelled { return [] }
            for bk in (bj + 1)..<b where compatible[bi * b + bk] && compatible[bj * b + bk] {
                let bulkValue = (bulkValues[bi] + bulkValues[bj] + bulkValues[bk]) / 3
                let consistencyValue = (consistencyValues[bi] + consistencyValues[bj] + consistencyValues[bk]) / 3
                let safetyValue = (safetyValues[bi] + safetyValues[bj] + safetyValues[bk]) / 3
                let cheapMin = min(bulkValue / bulkGoal,
                                   consistencyValue / consistencyGoal,
                                   safetyValue / safetyGoal)
                if cheapMin <= cutoff { continue }

                var selCount = 0
                var minIndex = 0
                for t in 0..<metaCount {
                    let s = softMB[t * b + bi] + softMB[t * b + bj] + softMB[t * b + bk]
                    if selCount == 6 && s <= selScore[minIndex] { continue }
                    let sid = metaSpeciesIds[t]
                    if sid == benchSpeciesIds[bi] || sid == benchSpeciesIds[bj] || sid == benchSpeciesIds[bk] { continue }
                    let avgRaw = (rawMB[t * b + bi] + rawMB[t * b + bj] + rawMB[t * b + bk]) / 3

                    if let fam = metaFamKey[t],
                       let existing = (0..<selCount).first(where: { selFam[$0] == fam }) {
                        if s > selScore[existing] {
                            selScore[existing] = s
                            selRaw[existing] = avgRaw
                        }
                    } else if selCount < 6 {
                        selScore[selCount] = s
                        selRaw[selCount] = avgRaw
                        selFam[selCount] = metaFamKey[t]
                        selCount += 1
                    } else {
                        selScore[minIndex] = s
                        selRaw[minIndex] = avgRaw
                        selFam[minIndex] = metaFamKey[t]
                    }
                    if selCount == 6 {
                        minIndex = 0
                        for si in 1..<6 where selScore[si] < selScore[minIndex] { minIndex = si }
                    }
                }

                let threatScore: Int
                if selCount == 0 {
                    threatScore = 500
                } else {
                    var sum = 0
                    for si in 0..<selCount { sum += selRaw[si] }
                    threatScore = Int((Double(sum) / Double(selCount)).rounded())
                }
                let coverageValue = 1200 - Double(threatScore)
                let minFraction = min(cheapMin, coverageValue / coverageGoal)
                if minFraction <= cutoff { continue }

                local.append(GradedTeam(
                    members: [bi, bj, bk].map { idx in
                        let c = bench[idx]
                        return TeamFinder.RankedTeam.Member(
                            member: c.member, speciesName: c.speciesName,
                            types: c.types, shadow: c.shadow)
                    },
                    poolIndices: [bi, bj, bk],
                    coverage: LetterGrade.grade(value: coverageValue, goal: coverageGoal),
                    bulk: LetterGrade.grade(value: bulkValue, goal: bulkGoal),
                    safety: LetterGrade.grade(value: safetyValue, goal: safetyGoal),
                    consistency: LetterGrade.grade(value: consistencyValue, goal: consistencyGoal),
                    threatScore: threatScore,
                    coverageValue: coverageValue,
                    bulkValue: bulkValue,
                    safetyValue: safetyValue,
                    consistencyValue: consistencyValue,
                    minGradeFraction: minFraction))
                if local.count >= maxResults * 2 { trimLocal() }
            }
        }
        if local.count > maxResults { trimLocal() }
        return local
    }

    /// One fast 1v1 per unordered pair at 1 shield each fills both directions.
    private static func ratingMatrix(
        pool: [TeamFinder.Candidate], movesById: [String: Move],
        progress: (@Sendable (Double) -> Void)? = nil
    ) async -> [Int] {
        let n = pool.count
        var matrix = [Int](repeating: 500, count: n * n)
        let totalPairs = n * (n - 1) / 2
        guard totalPairs > 0 else { return matrix }

        var completedPairs = 0
        await withTaskGroup(of: (i: Int, j: Int, a: Int, b: Int)?.self) { group in
            for i in 0..<n {
                for j in (i + 1)..<n {
                    group.addTask {
                        guard !Task.isCancelled,
                              let r = MatchupSimulator.rate(
                                pool[i].combatant, statsA: pool[i].stats,
                                pool[j].combatant, statsB: pool[j].stats,
                                movesById: movesById, shieldsA: 1, shieldsB: 1)
                        else { return nil }
                        return (i, j, r.a, r.b)
                    }
                }
            }
            for await pair in group {
                completedPairs += 1
                if completedPairs % 256 == 0 || completedPairs == totalPairs {
                    progress?(Double(completedPairs) / Double(totalPairs))
                }
                if let pair {
                    matrix[pair.i * n + pair.j] = pair.a
                    matrix[pair.j * n + pair.i] = pair.b
                }
            }
        }
        return matrix
    }
}
