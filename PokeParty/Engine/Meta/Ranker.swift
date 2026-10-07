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
        let probe = await MovesetSelector.probeSet(pool: pool, cpCap: cpCap)
        var movesets = [MovesetSelector.Result?](repeating: nil, count: n)
        var completedMovesets = 0
        await withTaskGroup(of: (Int, MovesetSelector.Result?).self) { group in
            for i in 0..<n {
                let species = pool[i]
                group.addTask {
                    (i, MovesetSelector.select(
                        species: species, shadow: species.isShadow, cpCap: cpCap,
                        probe: probe, movesById: movesById))
                }
            }
            for await (i, result) in group {
                movesets[i] = result
                completedMovesets += 1
                if completedMovesets % 32 == 0 || completedMovesets == n {
                    onProgress?(0.1 * Double(completedMovesets) / Double(n))
                }
            }
        }

        // --- Combatants + stats (once each; moveset-independent) ---------------
        // Parallelized: `optimalStats` is an O(4096) IV sweep per species,
        // expensive enough at pool sizes in the hundreds that running it
        // serially here (rather than inside a task group) was the other big
        // contributor to blocking whatever thread called `rank`.
        var combatants = [MatchupSimulator.Combatant?](repeating: nil, count: n)
        var stats = [BattlePokemon.Stats?](repeating: nil, count: n)
        await withTaskGroup(of: (Int, MatchupSimulator.Combatant?, BattlePokemon.Stats?).self) { group in
            for i in 0..<n {
                guard let moveset = movesets[i] else { continue }
                let species = pool[i]
                group.addTask {
                    let combatant = MatchupSimulator.Combatant(
                        species: species, shadow: species.isShadow,
                        fastMoveId: moveset.fastMoveId, chargedMoveIds: moveset.chargedMoveIds)
                    return (i, combatant, MatchupSimulator.optimalStats(for: combatant, cpCap: cpCap))
                }
            }
            for await (i, combatant, stat) in group {
                combatants[i] = combatant
                stats[i] = stat
            }
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
        await withTaskGroup(of: (Int, RankingEntry?).self) { group in
            for i in 0..<n {
                guard let moveset = movesets[i], let s = stats[i] else { continue }
                let leads = categoryScores[0][i]
                let closers = categoryScores[1][i]
                let switches = categoryScores[2][i]
                let chargers = categoryScores[3][i]
                let attackers = categoryScores[4][i]
                let species = pool[i]
                group.addTask {
                    let consistency = Consistency.score(
                        fastMoveId: moveset.fastMoveId, chargedMoveIds: moveset.chargedMoveIds,
                        types: species.types, movesById: movesById)

                    let overall = overallScore(
                        leads: leads, closers: closers, switches: switches, chargers: chargers,
                        attackers: attackers, consistency: consistency)

                    let matchups = (0..<n).filter { $0 != i }.map {
                        RankingEntry.Matchup(opponent: pool[$0].speciesId, rating: leadsMatrix[i * n + $0])
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
                }
            }
            for await (i, entry) in group { entries[i] = entry }
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

        await withTaskGroup(of: (Int, [Int]).self) { group in
            for i in 0..<n {
                group.addTask {
                    var row = [Int](repeating: 500, count: n)
                    guard let ci = combatants[i], let si = stats[i],
                          let fastI = movesById[ci.fastMoveId] else { return (i, row) }
                    let energyI = RankerScenario.startEnergy(turnsOfAdvantage: scenario.energy.own, fastMove: fastI)

                    for j in 0..<n where j != i {
                        guard let cj = combatants[j], let sj = stats[j],
                              let fastJ = movesById[cj.fastMoveId] else { continue }
                        let energyJ = RankerScenario.startEnergy(turnsOfAdvantage: scenario.energy.opponent, fastMove: fastJ)
                        if let r = MatchupSimulator.rate(
                            ci, statsA: si, cj, statsB: sj, movesById: movesById,
                            shieldsA: scenario.shields.own, shieldsB: scenario.shields.opponent,
                            startEnergyA: energyI, startEnergyB: energyJ
                        ) {
                            row[j] = r.a
                        }
                    }
                    return (i, row)
                }
            }
            for await (i, row) in group {
                for j in 0..<n { matrix[i * n + j] = row[j] }
                completedRows += 1
                if completedRows % 8 == 0 || completedRows == n {
                    onProgress?(Double(completedRows) / Double(n))
                }
            }
        }
        return matrix
    }
}
