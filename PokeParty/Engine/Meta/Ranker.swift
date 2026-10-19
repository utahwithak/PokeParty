//
//  Ranker.swift
//  PokeParty
//
//  The local "overall rankings" computation (M6.2) — PvPoke's own Ranker,
//  ported from `Ranker.js`/`RankerOverall.js`. For a `MetaPool`-eligible
//  pool, runs all 5 `RankerScenario`s as an N×(N-1) asymmetric battle matrix
//  (self vs every other pool member; asymmetric because scenarios like
//  "switches"/"chargers" preload energy on one side only, so `i` attacking
//  `j` and `j` attacking `i` are different battles), normalizes each
//  category to 0–100 relative to the field's best performer (`Ranker.js`'s
//  own normalization: `score / highestScore * 100`), then combines them
//  into an overall score with `RankerOverall.js`'s exact specialization-
//  weighted formula.
//
//  Deliberately NOT ported (documented simplifications, not oversights):
//  the shields-burned/remaining rating bonus (`adjRating` in `Ranker.js`),
//  the "chargers" category's extra fast-move-pressure factor, PvPoke's
//  multi-pass moveset refinement (we run `MovesetSelector` once up front —
//  see that file), and per-cup editor overrides. All of these are
//  refinements on top of the core mechanic implemented here, not it.
//

import Foundation

nonisolated enum Ranker {

    /// Ranks every Pokémon in `pool` (already `MetaPool`-filtered) for one
    /// league/cup. `onProgress` spans moveset selection + the 5 scenario
    /// matrices; runs off the main actor, parallelized per attacker row.
    static func rank(
        pool: [Pokemon], cpCap: Int, movesById: [String: Move],
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async -> [RankingEntry] {
        let n = pool.count
        guard n >= 2 else { return [] }

        // --- Moveset selection (once per species, before the matrix) -----------
        let probe = MovesetSelector.preparedProbe(
            await MovesetSelector.probeSet(pool: pool, cpCap: cpCap), cpCap: cpCap, movesById: movesById)
        var movesets = [MovesetSelector.Result?](repeating: nil, count: n)
        var completedMovesets = 0
        await BoundedParallel.run(count: n, of: (Int, MovesetSelector.Result?).self) { i in
            let species = pool[i]
            return (i, MovesetSelector.select(
                species: species, shadow: species.isShadow, cpCap: cpCap,
                preparedProbe: probe, movesById: movesById))
        } consume: { i, result in
            movesets[i] = result
            completedMovesets += 1
            if completedMovesets % 32 == 0 || completedMovesets == n {
                onProgress?(0.1 * Double(completedMovesets) / Double(n))
            }
        }

        // --- Combatants + stats (once each; moveset-independent) ---------------
        // Parallelized: `optimalStats` is an O(4096) IV sweep per species,
        // expensive enough at pool sizes in the hundreds that running it
        // serially here (rather than inside a task group) was the other big
        // contributor to blocking whatever thread called `rank`.
        var combatants = [MatchupSimulator.Combatant?](repeating: nil, count: n)
        var stats = [BattlePokemon.Stats?](repeating: nil, count: n)
        let finalMovesets = movesets
        await BoundedParallel.run(
            count: n, of: (Int, MatchupSimulator.Combatant?, BattlePokemon.Stats?).self
        ) { i in
            guard let moveset = finalMovesets[i] else { return (i, nil, nil) }
            let species = pool[i]
            let combatant = MatchupSimulator.Combatant(
                species: species, shadow: species.isShadow,
                fastMoveId: moveset.fastMoveId, chargedMoveIds: moveset.chargedMoveIds)
            return (i, combatant, MatchupSimulator.optimalStats(for: combatant, cpCap: cpCap))
        } consume: { i, combatant, stat in
            combatants[i] = combatant
            stats[i] = stat
        }

        // --- The 5 scenario matrices --------------------------------------------
        var categoryScores = [[Double]](repeating: [Double](repeating: 0, count: n), count: RankerScenario.all.count)
        var leadsMatrix = [Int](repeating: 500, count: n * n)

        for (scenarioIndex, scenario) in RankerScenario.all.enumerated() {
            let matrix = await buildScenarioMatrix(
                scenario: scenario, combatants: combatants, stats: stats, movesById: movesById
            ) { fraction in
                onProgress?(0.1 + 0.9 * (Double(scenarioIndex) + fraction) / Double(RankerScenario.all.count))
            }
            if scenario.slug == "leads" { leadsMatrix = matrix }

            var meanRating = [Double](repeating: 0, count: n)
            for i in 0..<n {
                var sum = 0.0, count = 0
                for j in 0..<n where j != i {
                    sum += Double(matrix[i * n + j]); count += 1
                }
                meanRating[i] = count > 0 ? sum / Double(count) : 500
            }
            let best = meanRating.max() ?? 1
            categoryScores[scenarioIndex] = meanRating.map { best > 0 ? min(($0 / best) * 100, 100) : 0 }
        }

        // --- Combine into RankingEntry -----------------------------------------
        // Parallelized: the per-species matchup sort is O(n log n), which
        // adds up to O(n² log n) done serially across all n species.
        var entries = [RankingEntry?](repeating: nil, count: n)
        let finalStats = stats
        let finalScores = categoryScores
        let finalLeads = leadsMatrix
        await BoundedParallel.run(count: n, of: (Int, RankingEntry?).self) { i in
            guard let moveset = finalMovesets[i], let s = finalStats[i] else { return (i, nil) }
            let leads = finalScores[0][i]
            let closers = finalScores[1][i]
            let switches = finalScores[2][i]
            let chargers = finalScores[3][i]
            let attackers = finalScores[4][i]
            let species = pool[i]

            let consistency = Consistency.score(
                fastMoveId: moveset.fastMoveId, chargedMoveIds: moveset.chargedMoveIds,
                types: species.types, movesById: movesById)

            let overall = overallScore(
                leads: leads, closers: closers, switches: switches, chargers: chargers,
                attackers: attackers, consistency: consistency)

            let matchups = (0..<n).filter { $0 != i }.map {
                RankingEntry.Matchup(opponent: pool[$0].speciesId, rating: finalLeads[i * n + $0])
            }.sorted { $0.rating > $1.rating }

            let entry = RankingEntry(
                speciesId: species.speciesId, speciesName: species.speciesName,
                rating: overall * 10, score: overall,
                scores: [leads, closers, switches, chargers, attackers, consistency],
                moveset: [moveset.fastMoveId] + moveset.chargedMoveIds,
                matchups: Array(matchups.prefix(10)), counters: Array(matchups.suffix(10)),
                moves: nil,
                stats: .init(product: Double(s.hp) * s.atk * s.def / 1000, atk: s.atk, def: s.def, hp: Double(s.hp)))
            return (i, entry)
        } consume: { i, entry in
            entries[i] = entry
        }

        return entries.compactMap { $0 }.sorted { $0.displayScore > $1.displayScore }
    }

    /// `RankerOverall.js`'s exact specialization-weighted combination: the 4
    /// category scores (switches/chargers collapsed to their max, since both
    /// stress "coming in mid-battle") are sorted descending and weighted
    /// `[12, 6, 4, 2]` alongside consistency²; a mon that's weak on both
    /// attackers and consistency gets a second pass that pulls the score
    /// toward those two directly.
    private static func overallScore(
        leads: Double, closers: Double, switches: Double, chargers: Double,
        attackers: Double, consistency: Double
    ) -> Double {
        let sorted = [leads, closers, max(switches, chargers), attackers].sorted(by: >)
        let weights = [12.0, 6.0, 4.0, 2.0]
        var product = 1.0
        for (value, weight) in zip(sorted, weights) {
            product *= pow(max(value, 0.001), weight)
        }
        product *= pow(max(consistency, 0.001), 2)
        var score = pow(product, 1.0 / 26.0)

        if attackers <= 75, consistency <= 75 {
            let refined = pow(score, 14) * pow(max(attackers, 0.001), 1) * pow(max(consistency, 0.001), 1)
            score = pow(refined, 1.0 / 16.0)
        }
        return score
    }

    /// One scenario's N×(N-1) asymmetric rating matrix — `matrix[i*n+j]` is
    /// `pool[i]`'s battle rating as "self" (scenario's shields/energy)
    /// against `pool[j]` as "opponent". Fanned out one task per attacker row
    /// (matches `GradeFinder`'s lead-indexed fan-out), since spawning a task
    /// per individual pair would be excessive at pool sizes in the hundreds.
    private static func buildScenarioMatrix(
        scenario: RankerScenario,
        combatants: [MatchupSimulator.Combatant?], stats: [BattlePokemon.Stats?],
        movesById: [String: Move],
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async -> [Int] {
        let n = combatants.count
        var matrix = [Int](repeating: 500, count: n * n)
        var completedRows = 0

        // Build each side's BattlePokemon once per scenario instead of once per
        // pair — the matrix runs n² battles but only needs 2n distinct sides.
        func prepare(_ i: Int, shields: Int, turnsOfAdvantage: Double) -> BattlePokemon? {
            guard let c = combatants[i], let s = stats[i], let fast = movesById[c.fastMoveId] else { return nil }
            return MatchupSimulator.makeBattlePokemon(
                c, stats: s, movesById: movesById, shields: shields,
                startEnergy: RankerScenario.startEnergy(turnsOfAdvantage: turnsOfAdvantage, fastMove: fast))
        }
        let ownSide = (0..<n).map { prepare($0, shields: scenario.shields.own, turnsOfAdvantage: scenario.energy.own) }
        let opponentSide = (0..<n).map { prepare($0, shields: scenario.shields.opponent, turnsOfAdvantage: scenario.energy.opponent) }

        await BoundedParallel.run(count: n, of: (Int, [Int]).self) { i in
            var row = [Int](repeating: 500, count: n)
            guard let own = ownSide[i] else { return (i, row) }
            for j in 0..<n where j != i {
                guard let opponent = opponentSide[j] else { continue }
                row[j] = MatchupSimulator.rate(prepared: own, opponent).a
            }
            return (i, row)
        } consume: { i, row in
            for j in 0..<n { matrix[i * n + j] = row[j] }
            completedRows += 1
            if completedRows % 8 == 0 || completedRows == n {
                onProgress?(Double(completedRows) / Double(n))
            }
        }
        return matrix
    }
}
