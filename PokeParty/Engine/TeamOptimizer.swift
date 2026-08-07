//
//  TeamOptimizer.swift
//  PokeParty
//
//  Hill-climbing team builder: searches (Pokémon × moveset) space for teams
//  with the highest expected score against a weighted meta field, evaluated
//  by the same AI battle engine used by the Party Finder tournament.
//
//  Algorithm:
//  1. Expand the ranked meta pool into candidates: one per viable (fast, c1, c2)
//     moveset combination, using per-move usage weights from the ranking data.
//     The recommended moveset is always included; alternates are added when
//     their simulated usage meets the threshold (default 5 %).
//  2. Build a meta field: the top `metaSize` ranked Pokémon (recommended
//     movesets), each paired with its two best coverage partners, weighted
//     equally. These are the opponent teams candidates are evaluated against.
//  3. Hill-climb from `restarts` diverse starting teams. Each step evaluates
//     every valid single-swap neighbor (different species or different moveset
//     of the same species, at any of the three positions) in parallel chunks
//     and accepts the best improvement. Climbers run in parallel; converged
//     local optima are pooled, deduplicated, and ranked by meta score.
//

import Foundation

nonisolated enum TeamOptimizer {

    // MARK: - Public types

    struct Candidate: Sendable {
        let member: TeamMember
        let speciesName: String
        let types: [String]
        let shadow: Bool
        let familyId: String?
        let dex: Int
        let combatant: MatchupSimulator.Combatant
        let stats: BattlePokemon.Stats
        /// True when this moveset differs from the entry's recommended moveset.
        let isAlternateMoveset: Bool
    }

    struct OptimizedTeam: Identifiable, Sendable {
        struct Member: Sendable {
            let member: TeamMember
            let speciesName: String
            let types: [String]
            let shadow: Bool
            let isAlternateMoveset: Bool
        }
        let members: [Member]
        /// Weighted expected score vs the meta field (0 = always loses, 1 = always wins).
        let metaScore: Double
        let wins: Int
        let losses: Int
        let ties: Int

        /// Order-independent identity: same 3 species + movesets = same team.
        var id: String {
            members.map { m in
                let charged = m.member.chargedMoveIds.sorted().joined(separator: ",")
                return "\(m.member.speciesId)+\(m.member.fastMoveId)+\(charged)"
            }.sorted().joined(separator: "|")
        }
        var gamesPlayed: Int { wins + losses + ties }
    }

    struct Results: Sendable {
        var teams: [OptimizedTeam]
        var completedClimbers: Int
        var totalClimbers: Int
        var isComplete: Bool
    }

    // MARK: - Entry point

    /// Runs the multi-start hill-climb and returns the best teams found.
    /// `onProgress` (0…1) fires as the meta field is built and climbers converge;
    /// `onResults` fires after each climber converges with the current best list.
    static func findTeams(
        entries: [RankingEntry],
        poolSize: Int,
        cpCap: Int,
        pokemonById: [String: Pokemon],
        movesById: [String: Move],
        metaSize: Int = 15,
        restarts: Int = 20,
        maxResults: Int = 50,
        learnedShields: Bool = true,
        learnedSwitches: Bool = true,
        voluntarySwitching: Bool = false,
        optimalShields: Bool = false,
        prefilterTopK: Int = 30,
        onProgress: (@Sendable (Double) -> Void)? = nil,
        onResults: (@Sendable (Results) -> Void)? = nil
    ) async -> Results {
        let empty = Results(teams: [], completedClimbers: 0, totalClimbers: restarts, isComplete: false)
        let pool = buildCandidates(
            entries: entries, poolSize: poolSize, cpCap: cpCap, pokemonById: pokemonById)
        guard pool.count >= 3 else {
            return Results(teams: [], completedClimbers: 0, totalClimbers: restarts, isComplete: true)
        }

        let shieldNet = learnedShields ? ShieldPolicyNet.bundled : nil
        let switchNet = learnedSwitches ? SwitchPolicyNet.bundled : nil

        onProgress?(0.0)
        let metaField = await buildMetaField(
            pool: pool, metaSize: metaSize, movesById: movesById, shieldNet: shieldNet)
        guard !metaField.isEmpty else {
            return Results(teams: [], completedClimbers: 0, totalClimbers: restarts, isComplete: true)
        }
        if Task.isCancelled { return empty }
        onProgress?(0.1)

        let prefilterData = prefilterTopK > 0
            ? await buildPrefilterData(
                pool: pool, metaField: metaField, movesById: movesById,
                shieldNet: shieldNet, topK: prefilterTopK)
            : nil
        if Task.isCancelled { return empty }

        let starts = generateStarts(pool: pool, count: restarts)
        let total = starts.count

        // Signal that climbing has begun (0 done) so the UI can switch from
        // "Building meta field…" to the climber count display immediately.
        onResults?(Results(teams: [], completedClimbers: 0, totalClimbers: total, isComplete: false))

        var best: [OptimizedTeam] = []
        var completed = 0

        await withTaskGroup(of: OptimizedTeam?.self) { group in
            for start in starts {
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    return await climb(
                        start: start, pool: pool, metaField: metaField,
                        movesById: movesById, shieldNet: shieldNet, switchNet: switchNet,
                        voluntarySwitching: voluntarySwitching, optimalShields: optimalShields,
                        prefilter: prefilterData)
                }
            }
            for await result in group {
                completed += 1
                if let team = result, !best.contains(where: { $0.id == team.id }) {
                    best.append(team)
                    best.sort { $0.metaScore > $1.metaScore }
                    if best.count > maxResults { best.removeLast() }
                }
                let fraction = 0.1 + 0.9 * Double(completed) / Double(max(total, 1))
                onProgress?(fraction)
                onResults?(Results(
                    teams: best,
                    completedClimbers: completed,
                    totalClimbers: total,
                    isComplete: completed == total))
            }
        }

        return Results(teams: best, completedClimbers: completed, totalClimbers: total, isComplete: true)
    }

    // MARK: - Candidate pool construction

    /// Expands the top `poolSize` ranking entries into (Pokémon × moveset) candidates.
    /// The recommended moveset is always first; alternates with simulated usage ≥
    /// `usageThreshold` are appended. Species with fewer than 2 viable charged
    /// moves fall back to just the recommended moveset.
    static func buildCandidates(
        entries: [RankingEntry],
        poolSize: Int,
        cpCap: Int,
        pokemonById: [String: Pokemon],
        usageThreshold: Double = 0.05
    ) -> [Candidate] {
        var result: [Candidate] = []
        var speciesCount = 0

        for entry in entries {
            guard speciesCount < poolSize else { break }
            guard entry.moveset.count >= 2,
                  let r = resolve(speciesId: entry.speciesId, pokemonById: pokemonById)
            else { continue }
            speciesCount += 1

            let recFast = entry.moveset[0]
            let recCharged = Array(entry.moveset[1...].prefix(2))

            // Collect viable fast moves; always include recommended.
            var viableFast: [String] = entry.moves?.fastMoves
                .filter { ($0.uses ?? 0) >= usageThreshold }
                .map(\.moveId) ?? []
            if !viableFast.contains(recFast) { viableFast.insert(recFast, at: 0) }

            // Collect viable charged moves; always include both recommended.
            var viableCharged: [String] = entry.moves?.chargedMoves
                .filter { ($0.uses ?? 0) >= usageThreshold }
                .map(\.moveId) ?? []
            for c in recCharged where !viableCharged.contains(c) { viableCharged.append(c) }

            // Must have at least 2 charged moves to build a valid moveset.
            if viableCharged.count < 2 {
                addCandidate(entry: entry, r: r, fast: recFast, charged: recCharged,
                             cpCap: cpCap, isAlternate: false, to: &result)
                continue
            }

            // Recommended moveset first, then all distinct alternates.
            var seen = Set<String>()
            let recKey = movesetKey(recFast, recCharged[0], recCharged[1])
            seen.insert(recKey)
            addCandidate(entry: entry, r: r, fast: recFast, charged: recCharged,
                         cpCap: cpCap, isAlternate: false, to: &result)

            for fast in viableFast {
                for i in 0..<viableCharged.count {
                    for j in (i + 1)..<viableCharged.count {
                        let c1 = viableCharged[i], c2 = viableCharged[j]
                        let k = movesetKey(fast, c1, c2)
                        guard !seen.contains(k) else { continue }
                        seen.insert(k)
                        addCandidate(entry: entry, r: r, fast: fast, charged: [c1, c2],
                                     cpCap: cpCap, isAlternate: true, to: &result)
                    }
                }
            }
        }
        return result
    }

    // MARK: - Meta field construction

    private struct MetaTeam: Sendable {
        let members: [Candidate]
        let weight: Double
    }

    // MARK: - Pre-filter support

    /// Pre-computed 1v1 ratings for every (pool candidate × unique meta mon) pair.
    /// Drives the per-step swap pre-filter: expensive 3v3 evals are reserved for
    /// the topK candidates ranked by this fast coverage estimate.
    private struct PrefilterData: Sendable {
        let poolScores: [[Int]]   // [poolIdx][metaMonIdx] = 1v1 rating 0…1000
        let teamLookup: [[Int]]   // [metaTeamIdx] = indices into poolScores columns
        let weights: [Double]     // [metaTeamIdx]
        let topK: Int

        /// Estimates the meta score of a candidate team: for each meta mon,
        /// take the team's best 1v1 counter, then average across teams.
        func estimate(_ team: [Int]) -> Double {
            var total = 0.0
            for (t, monIndices) in teamLookup.enumerated() {
                var coverage = 0.0
                for monIdx in monIndices {
                    let best = team.reduce(0) { max($0, poolScores[$1][monIdx]) }
                    coverage += Double(best)
                }
                coverage /= Double(monIndices.count * 1000)
                total += weights[t] * coverage
            }
            return total
        }
    }

    /// Builds representative opponent teams: the top `metaSize` unique species
    /// (recommended movesets), each paired with its two best coverage partners
    /// via the 1v1 rating matrix. All teams are weighted equally.
    private static func buildMetaField(
        pool: [Candidate],
        metaSize: Int,
        movesById: [String: Move],
        shieldNet: ShieldPolicyNet?
    ) async -> [MetaTeam] {
        // One recommended-moveset candidate per unique species, up to metaSize.
        var metaCandidates: [Candidate] = []
        var seenDex = Set<Int>()
        for c in pool where !c.isAlternateMoveset {
            guard seenDex.insert(c.dex).inserted else { continue }
            metaCandidates.append(c)
            if metaCandidates.count >= metaSize { break }
        }
        guard metaCandidates.count >= 3 else { return [] }

        // Pairwise 1v1 rating matrix for the meta candidates.
        let n = metaCandidates.count
        var matrix = Array(repeating: Array(repeating: 500, count: n), count: n)
        await withTaskGroup(of: (Int, Int, Int, Int)?.self) { group in
            for i in 0..<n {
                for j in (i + 1)..<n {
                    group.addTask {
                        guard !Task.isCancelled,
                              let r = MatchupSimulator.rate(
                                metaCandidates[i].combatant, statsA: metaCandidates[i].stats,
                                metaCandidates[j].combatant, statsB: metaCandidates[j].stats,
                                movesById: movesById, shieldsA: 1, shieldsB: 1,
                                shieldNet: shieldNet)
                        else { return nil }
                        return (i, j, r.a, r.b)
                    }
                }
            }
            for await r in group where r != nil {
                let r = r!
                matrix[r.0][r.1] = r.2; matrix[r.1][r.0] = r.3
            }
        }
        if Task.isCancelled { return [] }

        // For each meta candidate i, greedily find the 2 best coverage partners.
        var teams: [MetaTeam] = []
        for i in 0..<n {
            var bestJ = -1, bestJCov = -1
            for j in 0..<n where j != i && distinct(metaCandidates[i], metaCandidates[j]) {
                let cov = (0..<n).filter { $0 != i && $0 != j }
                    .reduce(0) { $0 + max(matrix[i][$1], matrix[j][$1]) }
                if cov > bestJCov { bestJCov = cov; bestJ = j }
            }
            guard bestJ >= 0 else { continue }
            var bestK = -1, bestKCov = -1
            for k in 0..<n where k != i && k != bestJ
                    && distinct(metaCandidates[i], metaCandidates[k])
                    && distinct(metaCandidates[bestJ], metaCandidates[k]) {
                let cov = (0..<n).filter { $0 != i && $0 != bestJ && $0 != k }
                    .reduce(0) { $0 + max(max(matrix[i][$1], matrix[bestJ][$1]), matrix[k][$1]) }
                if cov > bestKCov { bestKCov = cov; bestK = k }
            }
            guard bestK >= 0 else { continue }
            teams.append(MetaTeam(
                members: [metaCandidates[i], metaCandidates[bestJ], metaCandidates[bestK]],
                weight: 1.0))
        }
        guard !teams.isEmpty else { return [] }
        let w = 1.0 / Double(teams.count)
        return teams.map { MetaTeam(members: $0.members, weight: w) }
    }

    /// Builds the pre-filter matrix: 1v1 ratings for all (pool candidate × unique
    /// meta mon) pairs, computed in parallel. Called once before hill-climbing starts.
    private static func buildPrefilterData(
        pool: [Candidate],
        metaField: [MetaTeam],
        movesById: [String: Move],
        shieldNet: ShieldPolicyNet?,
        topK: Int
    ) async -> PrefilterData {
        // Deduplicate meta mons that appear across multiple teams.
        var metaMonsList: [Candidate] = []
        var metaMonKeyToIdx: [String: Int] = [:]
        var teamLookup: [[Int]] = []

        for meta in metaField {
            var indices: [Int] = []
            for member in meta.members {
                let key = "\(member.member.speciesId)|\(member.member.fastMoveId)|\(member.member.chargedMoveIds.sorted().joined(separator: ","))"
                if let idx = metaMonKeyToIdx[key] {
                    indices.append(idx)
                } else {
                    let idx = metaMonsList.count
                    metaMonKeyToIdx[key] = idx
                    metaMonsList.append(member)
                    indices.append(idx)
                }
            }
            teamLookup.append(indices)
        }

        let N = pool.count, M = metaMonsList.count
        var poolScores = Array(repeating: Array(repeating: 500, count: M), count: N)

        await withTaskGroup(of: (Int, Int, Int)?.self) { group in
            for i in 0..<N {
                for j in 0..<M {
                    let pi = pool[i], mj = metaMonsList[j]
                    group.addTask {
                        guard !Task.isCancelled,
                              let r = MatchupSimulator.rate(
                                pi.combatant, statsA: pi.stats,
                                mj.combatant, statsB: mj.stats,
                                movesById: movesById, shieldsA: 1, shieldsB: 1,
                                shieldNet: shieldNet)
                        else { return nil }
                        return (i, j, r.a)
                    }
                }
            }
            for await r in group where r != nil {
                let (i, j, score) = r!
                poolScores[i][j] = score
            }
        }

        return PrefilterData(
            poolScores: poolScores,
            teamLookup: teamLookup,
            weights: metaField.map(\.weight),
            topK: topK)
    }

    // MARK: - Diverse starting teams

    /// Generates up to `count` starting trios by cycling through unique lead
    /// species and rotating companion offsets for diversity.
    private static func generateStarts(pool: [Candidate], count: Int) -> [[Int]] {
        var firstByDex: [Int: Int] = [:]
        for (i, c) in pool.enumerated() where !c.isAlternateMoveset {
            if firstByDex[c.dex] == nil { firstByDex[c.dex] = i }
        }
        let unique = firstByDex.values.sorted()  // pool indices of recommended candidates
        let n = unique.count
        guard n >= 3 else { return [] }

        var starts: [[Int]] = []
        var used = Set<String>()

        for r in 0..<max(count * 4, n * n) {
            if starts.count >= count { break }
            let leadSlot = r % n
            let leadIdx = unique[leadSlot]
            let lead = pool[leadIdx]

            let offset = (r / n + 1) % n
            var companions: [Int] = []
            for d in 0..<n {
                if companions.count == 2 { break }
                let slot = (leadSlot + offset + d) % n
                guard slot != leadSlot else { continue }
                let cidx = unique[slot]
                let c = pool[cidx]
                guard distinct(c, lead) else { continue }
                if companions.isEmpty || distinct(c, pool[companions[0]]) {
                    companions.append(cidx)
                }
            }
            guard companions.count == 2 else { continue }

            let key = ([leadIdx] + companions).sorted().map(String.init).joined(separator: "+")
            if used.insert(key).inserted {
                starts.append([leadIdx] + companions)
            }
        }
        return starts
    }

    // MARK: - Hill climbing

    private static func climb(
        start: [Int],
        pool: [Candidate],
        metaField: [MetaTeam],
        movesById: [String: Move],
        shieldNet: ShieldPolicyNet?,
        switchNet: SwitchPolicyNet?,
        voluntarySwitching: Bool,
        optimalShields: Bool,
        prefilter: PrefilterData?
    ) async -> OptimizedTeam {
        var current = start
        var currentScore = evalSync(
            team: current, pool: pool, metaField: metaField, movesById: movesById,
            shieldNet: shieldNet, switchNet: switchNet,
            voluntarySwitching: voluntarySwitching, optimalShields: optimalShields)

        // When pre-filtering: evaluate only the topK most-promising swaps per step,
        // then validate with a full sweep once the filtered climb stalls. If the
        // full sweep finds an improvement the filter missed, accept and resume
        // filtered climbing; repeat until the full sweep confirms a true local optimum.
        var useFilter = prefilter != nil

        while !Task.isCancelled {
            // All valid single-swap neighbors (different species or different moveset).
            var swaps: [[Int]] = []
            for position in 0..<3 {
                let others = (0..<3).filter { $0 != position }.map { pool[current[$0]] }
                for ci in 0..<pool.count {
                    if current.contains(ci) { continue }
                    guard others.allSatisfy({ distinct(pool[ci], $0) }) else { continue }
                    var neighbor = current
                    neighbor[position] = ci
                    swaps.append(neighbor)
                }
            }
            guard !swaps.isEmpty else { break }

            // Pre-filter: rank by 1v1 estimate and keep only the topK most-promising.
            // Disabled during validation sweeps (useFilter == false).
            let candidates: [[Int]]
            if useFilter, let pf = prefilter, swaps.count > pf.topK {
                candidates = swaps.sorted { pf.estimate($0) > pf.estimate($1) }
                                 .prefix(pf.topK).map { $0 }
            } else {
                candidates = swaps
            }

            // Evaluate in parallel chunks; keep the best improvement found.
            let chunkSize = 16
            var bestScore = currentScore
            var bestSwap: [Int]? = nil

            await withTaskGroup(of: (score: Double, team: [Int])?.self) { group in
                var s = 0
                while s < candidates.count {
                    let chunk = Array(candidates[s..<min(s + chunkSize, candidates.count)])
                    s += chunkSize
                    group.addTask {
                        if Task.isCancelled { return nil }
                        var localBest: (Double, [Int])? = nil
                        for neighbor in chunk {
                            let sc = evalSync(
                                team: neighbor, pool: pool, metaField: metaField,
                                movesById: movesById, shieldNet: shieldNet, switchNet: switchNet,
                                voluntarySwitching: voluntarySwitching,
                                optimalShields: optimalShields)
                            if localBest == nil || sc > localBest!.0 {
                                localBest = (sc, neighbor)
                            }
                        }
                        return localBest
                    }
                }
                for await result in group {
                    if let (sc, team) = result, sc > bestScore {
                        bestScore = sc; bestSwap = team
                    }
                }
            }

            if let best = bestSwap {
                // Improvement found: accept. Keep useFilter unchanged — don't reset
                // it to true after a full-sweep step, or every step ping-pongs between
                // a useless filtered attempt and an expensive full sweep.
                current = best
                currentScore = bestScore
            } else if useFilter {
                // Filtered step found nothing — switch to full sweep permanently.
                // Quality guarantee: we now run the same algorithm as the unfiltered
                // baseline until convergence.
                useFilter = false
            } else {
                // Full sweep found no improvement — true local optimum.
                break
            }
        }

        // Win/loss/tie breakdown vs meta field for display.
        var wins = 0, losses = 0, ties = 0
        let members = current.map { pool[$0] }
        if let battleTeam = makeTeam(members, movesById: movesById) {
            for meta in metaField {
                if Task.isCancelled { break }
                guard let oppTeam = makeTeam(meta.members, movesById: movesById) else { continue }
                var battle = ThreeVThreeBattle(
                    teamA: battleTeam, teamB: oppTeam,
                    switchPolicy: .bestMatchup,
                    optimalShields: optimalShields,
                    voluntarySwitching: voluntarySwitching,
                    learnedShieldNet: shieldNet)
                if let switchNet { battle.switchDecisionHook = { switchNet.decide($0) } }
                switch battle.run().winner {
                case .teamA: wins += 1
                case .teamB: losses += 1
                case .tie: ties += 1
                }
            }
        }

        return OptimizedTeam(
            members: current.map { i in
                let c = pool[i]
                return OptimizedTeam.Member(
                    member: c.member, speciesName: c.speciesName,
                    types: c.types, shadow: c.shadow,
                    isAlternateMoveset: c.isAlternateMoveset)
            },
            metaScore: currentScore,
            wins: wins, losses: losses, ties: ties)
    }

    // MARK: - Score evaluation

    /// Synchronous weighted win rate of `team` vs the meta field (0…1).
    /// Called from within TaskGroup task closures — CPU-bound, no awaits.
    private static func evalSync(
        team: [Int],
        pool: [Candidate],
        metaField: [MetaTeam],
        movesById: [String: Move],
        shieldNet: ShieldPolicyNet?,
        switchNet: SwitchPolicyNet?,
        voluntarySwitching: Bool,
        optimalShields: Bool
    ) -> Double {
        let members = team.map { pool[$0] }
        guard let battleTeam = makeTeam(members, movesById: movesById) else { return 0 }
        var total = 0.0
        for meta in metaField {
            if Task.isCancelled { break }
            guard let oppTeam = makeTeam(meta.members, movesById: movesById) else { continue }
            var battle = ThreeVThreeBattle(
                teamA: battleTeam, teamB: oppTeam,
                switchPolicy: .bestMatchup,
                optimalShields: optimalShields,
                voluntarySwitching: voluntarySwitching,
                learnedShieldNet: shieldNet)
            if let switchNet { battle.switchDecisionHook = { switchNet.decide($0) } }
            switch battle.run().winner {
            case .teamA: total += meta.weight
            case .teamB: break
            case .tie: total += meta.weight * 0.5
            }
        }
        return total
    }

    // MARK: - Helpers

    static func distinct(_ a: Candidate, _ b: Candidate) -> Bool {
        if a.dex == b.dex { return false }
        if let fa = a.familyId, let fb = b.familyId, fa == fb { return false }
        return true
    }

    private static func movesetKey(_ fast: String, _ c1: String, _ c2: String) -> String {
        fast + "|" + [c1, c2].sorted().joined(separator: ",")
    }

    private static func addCandidate(
        entry: RankingEntry,
        r: (species: Pokemon, shadow: Bool),
        fast: String,
        charged: [String],
        cpCap: Int,
        isAlternate: Bool,
        to result: inout [Candidate]
    ) {
        let combatant = MatchupSimulator.Combatant(
            species: r.species, shadow: r.shadow,
            fastMoveId: fast, chargedMoveIds: charged)
        let stats = entry.stats.map {
            BattlePokemon.Stats(atk: $0.atk, def: $0.def, hp: Int($0.hp))
        } ?? MatchupSimulator.optimalStats(for: combatant, cpCap: cpCap)
        guard let stats else { return }
        result.append(Candidate(
            member: TeamMember(
                speciesId: r.species.speciesId,
                fastMoveId: fast, chargedMoveIds: charged,
                shadow: r.shadow),
            speciesName: r.species.speciesName,
            types: r.species.types.filter { $0 != "none" },
            shadow: r.shadow,
            familyId: r.species.family?.id,
            dex: r.species.dex,
            combatant: combatant, stats: stats,
            isAlternateMoveset: isAlternate))
    }

    private static func makeTeam(
        _ members: [Candidate], movesById: [String: Move]
    ) -> [BattlePokemon]? {
        ThreeVThreeBattle.makeTeam(
            members.map(\.combatant), stats: members.map(\.stats), movesById: movesById)
    }

    private static func resolve(
        speciesId: String, pokemonById: [String: Pokemon]
    ) -> (species: Pokemon, shadow: Bool)? {
        var species = pokemonById[speciesId]
        if species == nil, speciesId.hasSuffix("_shadow") {
            species = pokemonById[String(speciesId.dropLast("_shadow".count))]
        }
        guard let species else { return nil }
        return (species, species.isShadow || speciesId.hasSuffix("_shadow"))
    }
}
