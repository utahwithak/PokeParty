//
//  BreakpointAnalyzer.swift
//  PokeParty
//
//  IV breakpoint analysis: fixes a Pokémon at a level, sweeps its IVs across a
//  grid (12–15 per stat), battles every spread against the league's top meta
//  at 0/1/2 shields, and reports where outcomes flip, where fast-move damage
//  steps change, and the minimum IV each stat can drop to without losing
//  anything a 15/15/15 gets.
//

import Foundation

nonisolated enum BreakpointAnalyzer {

    /// IV values examined for each stat.
    static let ivRange: ClosedRange<Int> = 12...15

    /// Symmetric shield scenarios analyzed (same count both sides).
    static let shieldScenarios: [Int] = [0, 1, 2]

    /// Subject levels swept for the power-up analysis (15/15/15 vs the meta),
    /// from a low investment up to the league-legal max level, in ~5-level
    /// steps. For Master League that's the familiar 20–50; a CP-capped league
    /// clamps the top of the sweep to whatever level the cap allows.
    static func sweepLevels(upTo capLevel: Double) -> [Double] {
        var levels: [Double] = []
        var offset = 0.0
        while offset <= 30, capLevel - offset >= 1 {
            levels.insert(capLevel - offset, at: 0)
            offset += 5
        }
        return levels
    }

    enum Outcome: String, Sendable {
        case win = "Win"
        case tie = "Tie"
        case loss = "Loss"

        /// Battle rating where 500 is even (PvPoke's scale).
        init(rating: Int) {
            self = rating > 500 ? .win : (rating < 500 ? .loss : .tie)
        }
    }

    enum Stat: String, CaseIterable, Sendable, Identifiable {
        case atk = "Attack"
        case def = "Defense"
        case hp = "HP"
        var id: String { rawValue }
    }

    /// A meta opponent, battle-ready (stats already IV-optimized for the league).
    struct Opponent: Sendable, Identifiable {
        let speciesId: String
        let name: String
        let combatant: MatchupSimulator.Combatant
        let stats: BattlePokemon.Stats
        var id: String { speciesId }
    }

    /// A matchup whose outcome changes when one stat's IV drops (others at 15).
    struct MatchupChange: Sendable, Identifiable {
        let opponentName: String
        let shields: Int
        /// The IV at which the outcome first differs (it still held at `below + 1`).
        let below: Int
        let from: Outcome
        let to: Outcome
        var id: String { "\(opponentName)|\(shields)|\(below)" }
    }

    /// A fast-move damage number that steps as one stat's IV changes (others at 15).
    struct DamageStep: Sendable, Identifiable {
        let moveName: String
        let opponentName: String
        /// True for the subject's own damage; false for damage taken.
        let dealt: Bool
        /// Damage at each IV in `ivRange`, low to high.
        let values: [Int]
        var id: String { "\(moveName)|\(opponentName)|\(dealt)" }
    }

    /// How one matchup evolves as the subject levels up (15/15/15 vs level 50),
    /// with all shield scenarios grouped under the opponent.
    struct LevelInsight: Sendable, Identifiable {
        struct Scenario: Sendable, Identifiable {
            let shields: Int
            /// Outcome at each level in `sweepLevels`, low to high.
            let outcomes: [Outcome]
            /// Human-readable threshold, e.g. "Wins from level 45".
            let summary: String
            var id: Int { shields }
        }

        let opponentName: String
        /// One entry per shield scenario, in `shieldScenarios` order.
        let scenarios: [Scenario]
        var id: String { opponentName }
    }

    /// Everything that changes when a single stat's IV drops from 15.
    struct StatInsight: Sendable, Identifiable {
        let stat: Stat
        /// Lowest IV (others at 15) that preserves every 15/15/15 outcome.
        let minViable: Int
        /// Effective stat value at each IV in `ivRange`, low to high.
        let statValues: [Double]
        let changes: [MatchupChange]
        let damageSteps: [DamageStep]
        var id: String { stat.rawValue }
    }

    struct Report: Sendable {
        let subjectName: String
        let leagueTitle: String
        let level: Double
        let fastMoveName: String
        let chargedMoveNames: [String]
        let heroCP: Int
        let heroStats: BattlePokemon.Stats
        let opponentNames: [String]

        /// Insights in `Stat.allCases` order (Attack, Defense, HP).
        let insights: [StatInsight]
        /// Per-stat minimums (each measured with the other two stats at 15).
        let minViable: IVs
        /// Whether the three minimums combined still preserve every outcome.
        let combinedHolds: Bool
        /// The lowest-total spread in the grid preserving every outcome.
        let lowestSafeSpread: IVs
        /// Outcomes at the grid floor (12/12/12) differing from 15/15/15.
        let worstCaseChanges: Int
        /// Opponents × shield scenarios simulated per spread.
        let totalMatchups: Int
        /// Opponents whose outcome is identical across the entire IV grid.
        let unaffectedOpponents: [String]

        /// Levels swept for the power-up analysis (`sweepLevels`).
        let levels: [Double]
        /// Matchups whose outcome changes somewhere between level 20 and 50.
        let levelInsights: [LevelInsight]
        /// Opponents beaten at every swept level in every shield scenario.
        let alwaysWins: [String]
        /// Opponents lost to at every swept level in every shield scenario.
        let alwaysLosses: [String]
    }

    // MARK: - Analysis

    /// Runs the full IV-grid analysis. Battles run in parallel across spreads.
    static func analyze(
        subject: MatchupSimulator.Combatant,
        leagueTitle: String,
        level: Double,
        opponents: [Opponent],
        movesById: [String: Move]
    ) async -> Report? {
        guard !opponents.isEmpty, let cpm = IVCalculator.cpm(forLevel: level) else { return nil }
        let base = subject.species.baseStats
        let lo = ivRange.lowerBound
        let n = ivRange.count

        var combos: [IVs] = []
        combos.reserveCapacity(n * n * n)
        for a in ivRange {
            for d in ivRange {
                for h in ivRange {
                    combos.append(IVs(atk: a, def: d, hp: h))
                }
            }
        }
        func index(_ ivs: IVs) -> Int {
            ((ivs.atk - lo) * n + (ivs.def - lo)) * n + (ivs.hp - lo)
        }
        func statsFor(_ ivs: IVs) -> BattlePokemon.Stats {
            let hp = (cpm * Double(base.hp + ivs.hp)).rounded(.down)
            return .init(atk: cpm * Double(base.atk + ivs.atk),
                         def: cpm * Double(base.def + ivs.def),
                         hp: max(Int(hp), 10))
        }
        let spreadStats = combos.map(statsFor)

        // Battle every spread × opponent × shield scenario: ratings[spread][opp][scenario].
        let ratings: [[[Int]]] = await withTaskGroup(of: (Int, [[Int]]).self) { group in
            for i in combos.indices {
                let stats = spreadStats[i]
                group.addTask {
                    (i, opponents.map { opp in
                        shieldScenarios.map { shields in
                            MatchupSimulator.rate(
                                subject, statsA: stats, opp.combatant, statsB: opp.stats,
                                movesById: movesById, shieldsA: shields, shieldsB: shields
                            )?.a ?? 500
                        }
                    })
                }
            }
            var out = Array(repeating: [[Int]](), count: combos.count)
            for await (i, r) in group { out[i] = r }
            return out
        }

        let heroIVs = IVs(atk: 15, def: 15, hp: 15)
        let heroIndex = index(heroIVs)
        func outcomes(_ i: Int) -> [Outcome] {
            ratings[i].flatMap { $0.map(Outcome.init(rating:)) }
        }
        let heroOutcomes = outcomes(heroIndex)
        guard !heroOutcomes.isEmpty else { return nil }

        // One stat's IV varied, the other two held at 15.
        func axisSpread(_ stat: Stat, _ v: Int) -> IVs {
            switch stat {
            case .atk: IVs(atk: v, def: 15, hp: 15)
            case .def: IVs(atk: 15, def: v, hp: 15)
            case .hp: IVs(atk: 15, def: 15, hp: v)
            }
        }

        var insights: [StatInsight] = []
        for stat in Stat.allCases {
            // Matchup flips walking the IV down from 15.
            var changes: [MatchupChange] = []
            for (oi, opp) in opponents.enumerated() {
                for (si, shields) in shieldScenarios.enumerated() {
                    var above = Outcome(rating: ratings[heroIndex][oi][si])
                    for v in stride(from: ivRange.upperBound - 1, through: lo, by: -1) {
                        let outcome = Outcome(rating: ratings[index(axisSpread(stat, v))][oi][si])
                        if outcome != above {
                            changes.append(.init(opponentName: opp.name, shields: shields,
                                                 below: v, from: above, to: outcome))
                            above = outcome
                        }
                    }
                }
            }

            // Lowest contiguous IV whose full outcome vector still matches 15/15/15.
            var minViable = ivRange.upperBound
            for v in stride(from: ivRange.upperBound - 1, through: lo, by: -1) {
                if outcomes(index(axisSpread(stat, v))) == heroOutcomes {
                    minViable = v
                } else {
                    break
                }
            }

            let statValues: [Double] = ivRange.map { v in
                switch stat {
                case .atk: cpm * Double(base.atk + v)
                case .def: cpm * Double(base.def + v)
                case .hp: (cpm * Double(base.hp + v)).rounded(.down)
                }
            }

            // Fast-move damage steps: attack changes damage dealt, defense
            // changes damage taken. (Charged-move deltas show up as flips.)
            var damageSteps: [DamageStep] = []
            if stat != .hp {
                let dealt = stat == .atk
                for opp in opponents {
                    var name = ""
                    var values: [Int] = []
                    for v in ivRange {
                        guard let damage = fastMoveDamage(
                            subject: subject, stats: statsFor(axisSpread(stat, v)),
                            opponent: opp, movesById: movesById
                        ) else { values = []; break }
                        let side = dealt ? damage.dealt : damage.taken
                        name = side.move
                        values.append(side.damage)
                    }
                    if Set(values).count > 1 {
                        damageSteps.append(.init(moveName: name, opponentName: opp.name,
                                                 dealt: dealt, values: values))
                    }
                }
            }

            insights.append(.init(stat: stat, minViable: minViable, statValues: statValues,
                                  changes: changes, damageSteps: damageSteps))
        }

        let minViable = IVs(atk: insights[0].minViable,
                            def: insights[1].minViable,
                            hp: insights[2].minViable)
        let combinedHolds = outcomes(index(minViable)) == heroOutcomes

        func total(_ i: Int) -> Int { combos[i].atk + combos[i].def + combos[i].hp }
        let matching = combos.indices.filter { outcomes($0) == heroOutcomes }
        let lowestSafeSpread = combos[matching.min { total($0) < total($1) } ?? heroIndex]

        let worstOutcomes = outcomes(index(IVs(atk: lo, def: lo, hp: lo)))
        let worstCaseChanges = zip(worstOutcomes, heroOutcomes).filter { $0 != $1 }.count

        var unaffected: [String] = []
        for (oi, opp) in opponents.enumerated() {
            let hero = ratings[heroIndex][oi].map(Outcome.init(rating:))
            let stable = combos.indices.allSatisfy { i in
                ratings[i][oi].map(Outcome.init(rating:)) == hero
            }
            if stable { unaffected.append(opp.name) }
        }

        // Level sweep: the subject at 15/15/15, from a low level up to the
        // league-legal max (`level`), vs the meta at that same cap.
        let levels = sweepLevels(upTo: level)
        let levelStats: [BattlePokemon.Stats] = levels.compactMap { lvl in
            guard let m = IVCalculator.cpm(forLevel: lvl) else { return nil }
            let hp = (m * Double(base.hp + 15)).rounded(.down)
            return .init(atk: m * Double(base.atk + 15),
                         def: m * Double(base.def + 15),
                         hp: max(Int(hp), 10))
        }
        guard levelStats.count == levels.count else { return nil }

        // levelRatings[level][opponent][scenario]
        let levelRatings: [[[Int]]] = await withTaskGroup(of: (Int, [[Int]]).self) { group in
            for li in levels.indices {
                let stats = levelStats[li]
                group.addTask {
                    (li, opponents.map { opp in
                        shieldScenarios.map { shields in
                            MatchupSimulator.rate(
                                subject, statsA: stats, opp.combatant, statsB: opp.stats,
                                movesById: movesById, shieldsA: shields, shieldsB: shields
                            )?.a ?? 500
                        }
                    })
                }
            }
            var out = Array(repeating: [[Int]](), count: levels.count)
            for await (i, r) in group { out[i] = r }
            return out
        }

        var levelInsights: [LevelInsight] = []
        var alwaysWins: [String] = []
        var alwaysLosses: [String] = []
        for (oi, opp) in opponents.enumerated() {
            var scenarios: [LevelInsight.Scenario] = []
            var varies = false
            var allOutcomes: [Outcome] = []
            for (si, shields) in shieldScenarios.enumerated() {
                let outcomes = levels.indices.map { Outcome(rating: levelRatings[$0][oi][si]) }
                allOutcomes.append(contentsOf: outcomes)
                if !outcomes.allSatisfy({ $0 == outcomes[0] }) { varies = true }
                scenarios.append(.init(shields: shields, outcomes: outcomes,
                                       summary: levelSummary(outcomes, levels: levels)))
            }
            if varies {
                levelInsights.append(.init(opponentName: opp.name, scenarios: scenarios))
            }
            if allOutcomes.allSatisfy({ $0 == .win }) { alwaysWins.append(opp.name) }
            if allOutcomes.allSatisfy({ $0 == .loss }) { alwaysLosses.append(opp.name) }
        }

        let subjectName = subject.shadow
            ? "Shadow \(subject.species.speciesName)"
            : subject.species.speciesName
        return Report(
            subjectName: subjectName,
            leagueTitle: leagueTitle,
            level: level,
            fastMoveName: movesById[subject.fastMoveId]?.name ?? subject.fastMoveId,
            chargedMoveNames: subject.chargedMoveIds.map { movesById[$0]?.name ?? $0 },
            heroCP: IVCalculator.cp(baseAtk: base.atk, baseDef: base.def, baseHp: base.hp,
                                    ivs: heroIVs, cpm: cpm),
            heroStats: statsFor(heroIVs),
            opponentNames: opponents.map(\.name),
            insights: insights,
            minViable: minViable,
            combinedHolds: combinedHolds,
            lowestSafeSpread: lowestSafeSpread,
            worstCaseChanges: worstCaseChanges,
            totalMatchups: opponents.count * shieldScenarios.count,
            unaffectedOpponents: unaffected,
            levels: levels,
            levelInsights: levelInsights,
            alwaysWins: alwaysWins,
            alwaysLosses: alwaysLosses
        )
    }

    /// A human-readable threshold for one matchup's outcomes across the sweep.
    private static func levelSummary(_ outcomes: [Outcome], levels: [Double]) -> String {
        // All-same rows are filtered out before this is called, but stay safe.
        guard let first = outcomes.first else { return "" }
        if outcomes.allSatisfy({ $0 == first }) {
            switch first {
            case .win: return "Wins at every level"
            case .tie: return "Ties at every level"
            case .loss: return "Loses at every level"
            }
        }
        if outcomes.last == .win, let lastMiss = outcomes.lastIndex(where: { $0 != .win }) {
            return "Wins from level \(levels[lastMiss + 1].formatted())"
        }
        if outcomes.last == .tie, let lastMiss = outcomes.lastIndex(where: { $0 != .tie }) {
            return "Ties from level \(levels[lastMiss + 1].formatted())"
        }
        if outcomes.contains(.win) {
            return "Only wins at some levels"
        }
        return "Changes with level"
    }

    // MARK: - Damage numbers

    /// Opening fast-move damage in both directions for one subject spread vs
    /// one opponent (fresh battle objects, no buffs).
    private static func fastMoveDamage(
        subject: MatchupSimulator.Combatant,
        stats: BattlePokemon.Stats,
        opponent: Opponent,
        movesById: [String: Move]
    ) -> (dealt: (move: String, damage: Int), taken: (move: String, damage: Int))? {
        guard var me = MatchupSimulator.makeBattlePokemon(subject, stats: stats,
                                                          movesById: movesById, shields: 1),
              var opp = MatchupSimulator.makeBattlePokemon(opponent.combatant, stats: opponent.stats,
                                                           movesById: movesById, shields: 1)
        else { return nil }
        me.reset(opponent: opp)
        opp.reset(opponent: me)
        return ((me.fastMove.name, me.fastMove.damage),
                (opp.fastMove.name, opp.fastMove.damage))
    }
}
