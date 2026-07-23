//
//  TeamFinder.swift
//  PokeParty
//
//  The 3v3 Party Finder engine: a streaming, full round-robin tournament
//  (plan Milestones 3/4).
//
//  Seeding: a pairwise 1v1 rating matrix over the whole pool ranks every
//  distinct trio by "meta coverage" (for each other pool mon, the best
//  member's rating against it). The top `fieldSize` trios form the FIELD.
//
//  Tournament: a full round robin — every team battles every other team in
//  the field in true 3v3 simulations, scheduled with the circle method so
//  each virtual round gives every team exactly one more game and records
//  stay comparable all the way down. Nothing is graded against a heuristic
//  subset: a team's record is its record against the entire field, so a
//  team that folds to the meta's heavyweights sinks no matter how well it
//  covers the long tail. `Standings` snapshots stream out as battles
//  resolve, so the UI can animate the leaderboard live; teams "drop off"
//  simply by falling out of the visible top `maxResults`.
//
//  Per plan Q7, battles default to the engine's fast heuristics — greedy
//  shields and best-matchup switching. `voluntarySwitching` optionally adds
//  safe swaps, counterswaps, switch-timer escapes, catch swaps and sac swaps
//  (M8.3); `optimalShields` optionally runs the game-theoretic shield search
//  per segment. Both cost extra sims per battle — the shield search
//  dramatically so.
//
//  Trios are enumerated streaming (never materialized all at once): a top-200
//  pool has C(200,3) ≈ 1.3M combinations, kept only as a bounded best-`limit`
//  selection of packed indices. Results are Codable so a finished tournament
//  can be persisted and reviewed later (the meta rarely changes).
//

import Foundation

nonisolated enum TeamFinder {

    /// A meta Pokémon eligible for suggested teams, prepared for battle once so
    /// every 3v3 can reuse its stats without touching the IV optimizer.
    struct Candidate: Sendable {
        /// Ready to load into the Team Builder.
        let member: TeamMember
        let speciesName: String
        let types: [String]
        let shadow: Bool
        let familyId: String?
        let dex: Int
        let combatant: MatchupSimulator.Combatant
        let stats: BattlePokemon.Stats
        /// PvPoke "switches" category score from the ranking data (feeds the
        /// Safety grade in `GradeFinder`); nil falls back to PvPoke's default.
        var switchesScore: Double? = nil
    }

    /// One entrant with its accumulated round-robin record. Members are in
    /// team order (index 0 = lead), which follows the ranking order of the
    /// pool. Codable so finished tournaments can be saved and reviewed.
    struct RankedTeam: Identifiable, Sendable, Codable {
        /// The displayable slice of a candidate (everything the leaderboard
        /// and Team Builder handoff need — battle payloads stay engine-side).
        struct Member: Sendable, Codable, Hashable {
            let member: TeamMember
            let speciesName: String
            let types: [String]
            let shadow: Bool
        }

        let members: [Member]
        let wins: Int
        let losses: Int
        let ties: Int
        /// 0…1 across the games played so far; a tie counts as half a win.
        let winRate: Double
        /// Mean team battle rating (0–1000, 500 = even) across games played.
        let averageRating: Double

        var id: String {
            members.map { m in
                m.shadow && !m.member.speciesId.hasSuffix("_shadow")
                    ? m.member.speciesId + "_shadow"
                    : m.member.speciesId
            }.joined(separator: "+")
        }
        /// Round-robin games played so far (grows as rounds complete).
        var gamesPlayed: Int { wins + losses + ties }
    }

    /// A live snapshot of the tournament, emitted after seeding and then
    /// periodically as battles resolve, so the UI can animate the leaderboard.
    struct Standings: Sendable {
        /// The current best teams, ranked, capped at `maxResults`.
        var teams: [RankedTeam]
        /// The size of the round-robin field.
        var totalEntrants: Int
        /// Cumulative 3v3 battles fought / the full round-robin total.
        var battlesFought: Int
        var totalBattles: Int
        /// Completed virtual rounds (≈ games every team has played). 0 = seeded.
        var round: Int
        var totalRounds: Int
        var isComplete: Bool
    }

    /// Runs the round-robin tournament and returns the final `Standings`
    /// (`isComplete` is true only if every battle was fought — a cancelled
    /// run returns whatever accumulated). `onSeedingProgress` (0…1) covers
    /// the pairwise matrix + field shortlist; `onStandings` fires after
    /// seeding (round 0) and periodically while battles resolve. Both are
    /// called from off the main actor.
    ///
    /// `seededField` bypasses the coverage seeding entirely: the given trios
    /// (pool indices, lead first) enter the round robin as-is, capped at
    /// `fieldSize`. Used by the combined AAAA-grades + tournament method.
    static func findTeams(
        pool: [Candidate],
        movesById: [String: Move],
        fieldSize: Int = 500,
        maxResults: Int = 100,
        voluntarySwitching: Bool = false,
        optimalShields: Bool = false,
        seededField: [[Int]]? = nil,
        onSeedingProgress: (@Sendable (Double) -> Void)? = nil,
        onStandings: (@Sendable (Standings) -> Void)? = nil
    ) async -> Standings {
        let empty = Standings(teams: [], totalEntrants: 0, battlesFought: 0,
                              totalBattles: 0, round: 0, totalRounds: 0, isComplete: false)
        guard pool.count >= 3 else { return empty }

        let field: [[Int]]
        if let seededField {
            field = Array(seededField.prefix(fieldSize))
            onSeedingProgress?(1)
        } else {
            // Seed: pairwise 1v1 matrix → the coverage-ranked field.
            let matrix = await ratingMatrix(pool: pool, movesById: movesById) { fraction in
                onSeedingProgress?(fraction * 0.85)
            }
            if Task.isCancelled { return empty }
            field = await seedEntrants(pool: pool, matrix: matrix, limit: fieldSize) { fraction in
                onSeedingProgress?(0.85 + fraction * 0.15)
            }
        }
        if Task.isCancelled || field.isEmpty { return empty }

        // Round-robin schedule (circle method): pad odd fields with a bye,
        // fix seat 0 and rotate the rest; each virtual round pairs seat k
        // with seat m-1-k, giving every team exactly one game per round.
        let n = field.count
        struct Record { var wins = 0; var losses = 0; var ties = 0; var ratingSum = 0; var battles = 0 }
        var records = [Record](repeating: Record(), count: n)
        let m = n.isMultiple(of: 2) ? n : n + 1   // seat m-1 is the bye when padded
        let totalRounds = max(m - 1, 0)
        let totalBattles = n * (n - 1) / 2
        var circle = Array(0..<m)
        var battlesFought = 0

        func winRate(_ r: Record) -> Double {
            r.battles > 0 ? (Double(r.wins) + Double(r.ties) * 0.5) / Double(r.battles) : 0
        }
        func averageRating(_ r: Record) -> Double {
            r.battles > 0 ? Double(r.ratingSum) / Double(r.battles) : 500
        }
        /// Field indices ranked best-first: win rate, then rating, then seed.
        func ranked() -> [Int] {
            (0..<n).sorted { a, b in
                let ra = records[a], rb = records[b]
                let wa = winRate(ra), wb = winRate(rb)
                if wa != wb { return wa > wb }
                let ga = averageRating(ra), gb = averageRating(rb)
                if ga != gb { return ga > gb }
                return a < b
            }
        }
        func rankedTeams(_ order: [Int]) -> [RankedTeam] {
            order.prefix(maxResults).map { index in
                let r = records[index]
                return RankedTeam(
                    members: field[index].map { i in
                        let c = pool[i]
                        return RankedTeam.Member(
                            member: c.member, speciesName: c.speciesName,
                            types: c.types, shadow: c.shadow)
                    },
                    wins: r.wins, losses: r.losses, ties: r.ties,
                    winRate: winRate(r), averageRating: averageRating(r))
            }
        }
        // Every round fights the same number of battles (the bye seat sits out
        // when the field is padded), so the live round number can be derived
        // from `battlesFought` — it advances smoothly even mid-batch.
        let battlesPerRound = m / 2 - (m > n ? 1 : 0)
        var completedRounds = 0
        func snapshot() -> Standings {
            let round = battlesPerRound > 0
                ? min(battlesFought / battlesPerRound, totalRounds)
                : completedRounds
            return Standings(
                teams: rankedTeams(ranked()),
                totalEntrants: n,
                battlesFought: battlesFought, totalBattles: totalBattles,
                round: round, totalRounds: totalRounds,
                isComplete: round == totalRounds && battlesFought == totalBattles)
        }

        // Round 0: the seeded field, before any battles.
        onStandings?(snapshot())

        // Throttle snapshots by wall clock: long runs stream updates steadily
        // while short runs only emit a handful of times.
        let emitInterval: Duration = .milliseconds(250)
        var lastEmit = ContinuousClock.now
        // Rounds per parallel batch: enough work to saturate cores without
        // hoarding pairings (each round is n/2 battles).
        let batchRounds = max(1, totalRounds / 32)

        while completedRounds < totalRounds {
            if Task.isCancelled { break }
            let roundsThisBatch = min(batchRounds, totalRounds - completedRounds)

            // Collect the batch's pairings, rotating the circle per round.
            var pairings: [(a: Int, b: Int)] = []
            pairings.reserveCapacity(roundsThisBatch * m / 2)
            for _ in 0..<roundsThisBatch {
                for k in 0..<(m / 2) {
                    let a = circle[k], b = circle[m - 1 - k]
                    if a < n && b < n { pairings.append((a, b)) }
                }
                circle = [circle[0], circle[m - 1]] + circle[1..<(m - 1)]
            }

            // Fight the batch in parallel, chunked to keep task overhead low;
            // apply deltas (both perspectives) as chunks stream back.
            let chunkSize = 32
            await withTaskGroup(
                of: [(a: Int, b: Int, winner: TeamBattleResult.Winner, ratingA: Int)].self
            ) { group in
                var start = 0
                while start < pairings.count {
                    let chunk = Array(pairings[start..<min(start + chunkSize, pairings.count)])
                    start += chunkSize
                    group.addTask {
                        var outcomes: [(a: Int, b: Int, winner: TeamBattleResult.Winner, ratingA: Int)] = []
                        outcomes.reserveCapacity(chunk.count)
                        for pair in chunk {
                            if Task.isCancelled { break }
                            guard let a = makeTeam(field[pair.a].map { pool[$0] }, movesById: movesById),
                                  let b = makeTeam(field[pair.b].map { pool[$0] }, movesById: movesById)
                            else { continue }
                            let result = ThreeVThreeBattle(
                                teamA: a, teamB: b,
                                switchPolicy: .bestMatchup,
                                optimalShields: optimalShields,
                                voluntarySwitching: voluntarySwitching).run()
                            outcomes.append((pair.a, pair.b, result.winner, result.ratingA))
                        }
                        return outcomes
                    }
                }
                for await outcomes in group {
                    for o in outcomes {
                        switch o.winner {
                        case .teamA: records[o.a].wins += 1; records[o.b].losses += 1
                        case .teamB: records[o.a].losses += 1; records[o.b].wins += 1
                        case .tie: records[o.a].ties += 1; records[o.b].ties += 1
                        }
                        records[o.a].ratingSum += o.ratingA
                        records[o.b].ratingSum += 1000 - o.ratingA
                        records[o.a].battles += 1
                        records[o.b].battles += 1
                        battlesFought += 1
                    }
                    let now = ContinuousClock.now
                    if now - lastEmit >= emitInterval {
                        lastEmit = now
                        onStandings?(snapshot())
                    }
                }
            }
            if Task.isCancelled { break }
            completedRounds += roundsThisBatch
            onStandings?(snapshot())
        }

        return snapshot()
    }

    /// All 3-member combinations of the pool (as pool indices, ascending — so
    /// the better-ranked member leads), skipping teams that double up on a
    /// species or evolutionary family (e.g. a shadow + regular pair).
    /// Materializes every trio — fine for small pools and tests; the finder
    /// itself streams via `seedEntrants`.
    static func candidateTeams(from pool: [Candidate]) -> [[Int]] {
        var teams: [[Int]] = []
        for i in 0..<pool.count {
            for j in (i + 1)..<pool.count where distinct(pool[i], pool[j]) {
                for k in (j + 1)..<pool.count
                where distinct(pool[i], pool[k]) && distinct(pool[j], pool[k]) {
                    teams.append([i, j, k])
                }
            }
        }
        return teams
    }

    /// Whether two candidates may share a team (no same species or family).
    /// Internal so `GradeFinder` enumerates the same trios.
    static func distinct(_ a: Candidate, _ b: Candidate) -> Bool {
        if a.dex == b.dex { return false }
        if let fa = a.familyId, let fb = b.familyId, fa == fb { return false }
        return true
    }

    // MARK: - Seeding

    /// Pairwise 1v1 ratings for the whole pool: `matrix[i][j]` = pool[i]'s
    /// battle rating vs pool[j] (0…1000), fresh mons at 1 shield each. One
    /// battle per unordered pair yields both perspectives, so a 200-mon pool
    /// costs ~20k fast 1v1s. Heuristic input only — never shown to the user.
    private static func ratingMatrix(
        pool: [Candidate], movesById: [String: Move],
        progress: (@Sendable (Double) -> Void)? = nil
    ) async -> [[Int]] {
        let n = pool.count
        var matrix = Array(repeating: Array(repeating: 500, count: n), count: n)
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
                    matrix[pair.i][pair.j] = pair.a
                    matrix[pair.j][pair.i] = pair.b
                }
            }
        }
        return matrix
    }

    /// Streams every distinct trio and keeps the `limit` best by meta
    /// coverage, best-first. Coverage = for every other pool mon, the best
    /// member's 1v1 rating against it, summed (all trios divide by the same
    /// count, so the sum orders identically to the average). Trios are packed
    /// into a UInt32 (10 bits per index) so a 1.3M-combination sweep never
    /// allocates per trio; work fans out across cores by lead index.
    private static func seedEntrants(
        pool: [Candidate], matrix: [[Int]], limit: Int,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async -> [[Int]] {
        let n = pool.count
        precondition(n < 1024, "trio packing supports pools up to 1023")

        // Pairwise compatibility (no shared species/family), computed once.
        var compatible = Array(repeating: Array(repeating: false, count: n), count: n)
        for i in 0..<n {
            for j in (i + 1)..<n where distinct(pool[i], pool[j]) {
                compatible[i][j] = true
                compatible[j][i] = true
            }
        }

        var all: [(score: Int, packed: UInt32)] = []
        var completed = 0
        await withTaskGroup(of: [(score: Int, packed: UInt32)].self) { [compatible] group in
            for i in 0..<n {
                group.addTask {
                    var local: [(score: Int, packed: UInt32)] = []
                    let rowI = matrix[i]
                    for j in (i + 1)..<n where compatible[i][j] {
                        if Task.isCancelled { return [] }
                        let rowJ = matrix[j]
                        // Best-of-pair rating vs every pool mon, reused for all k.
                        var pairRow = rowI
                        for m in 0..<n where rowJ[m] > pairRow[m] { pairRow[m] = rowJ[m] }
                        for k in (j + 1)..<n where compatible[i][k] && compatible[j][k] {
                            let rowK = matrix[k]
                            var sum = 0
                            for m in 0..<n where m != i && m != j && m != k {
                                sum += max(pairRow[m], rowK[m])
                            }
                            local.append((sum, UInt32(i) << 20 | UInt32(j) << 10 | UInt32(k)))
                        }
                    }
                    // Bound memory before handing back to the collector.
                    if local.count > limit {
                        local.sort { $0.score > $1.score }
                        local.removeLast(local.count - limit)
                    }
                    return local
                }
            }
            for await part in group {
                completed += 1
                progress?(Double(completed) / Double(n))
                all.append(contentsOf: part)
            }
        }

        // Deterministic order: score, then packed indices (reproducible runs).
        all.sort { $0.score != $1.score ? $0.score > $1.score : $0.packed < $1.packed }

        // Diversity cap: raw coverage is maximized by anchoring every trio on the
        // single best-coverage mon, which degenerates the field into "the top mon
        // plus filler" and makes the round robin an in-bred mirror match. Cap each
        // species/family to a share of the field (best trios keep priority), then
        // fill any remaining seats with the skipped best so the field stays full.
        let cap = max(1, Int((Double(limit) * maxFieldSharePerFamily).rounded(.up)))
        func unpack(_ packed: UInt32) -> [Int] {
            [Int(packed >> 20), Int((packed >> 10) & 0x3FF), Int(packed & 0x3FF)]
        }
        var counts: [String: Int] = [:]
        var selected: [[Int]] = []
        var skipped: [[Int]] = []
        for entry in all {
            if selected.count == limit { break }
            let trio = unpack(entry.packed)
            let keys = trio.map { pool[$0].familyId ?? pool[$0].member.speciesId }
            if keys.allSatisfy({ counts[$0, default: 0] < cap }) {
                for key in keys { counts[key, default: 0] += 1 }
                selected.append(trio)
            } else {
                skipped.append(trio)
            }
        }
        if selected.count < limit {
            selected.append(contentsOf: skipped.prefix(limit - selected.count))
        }
        return selected
    }

    /// No species/family may appear in more than this share of the seeded field.
    private static let maxFieldSharePerFamily = 0.2

    /// Fresh `BattlePokemon`s per battle — the 3v3 engine mutates its teams.
    private static func makeTeam(_ members: [Candidate], movesById: [String: Move]) -> [BattlePokemon]? {
        ThreeVThreeBattle.makeTeam(
            members.map(\.combatant), stats: members.map(\.stats), movesById: movesById)
    }
}
