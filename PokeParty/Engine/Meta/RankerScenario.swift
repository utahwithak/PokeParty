//
//  RankerScenario.swift
//  PokeParty
//
//  The 5 fixed battle configurations PvPoke's Ranker scores every mon under
//  (`base.json`'s `rankingScenarios`, ported as constants) — each stresses a
//  different in-game role. Ported from `Ranker.js`'s per-scenario shield/
//  energy setup; the shields-burned rating bonus and the "chargers" fast-
//  move-pressure adjustment are NOT ported (see `Ranker.swift`) — this
//  covers the core mechanic (shield counts + preloaded energy), not every
//  refinement layer PvPoke stacks on top of it.
//

import Foundation

nonisolated struct RankerScenario: Sendable {
    let slug: String
    /// [own, opponent] shield counts.
    let shields: (own: Int, opponent: Int)
    /// [own, opponent] preloaded energy, in "turns of fast-move advantage."
    /// 0 means no preload.
    let energy: (own: Double, opponent: Double)
    /// Index into `RankingEntry.scores` ([leads, closers, switches, chargers, attackers, consistency]).
    let scoreIndex: Int

    static let leads = RankerScenario(slug: "leads", shields: (1, 1), energy: (0, 0), scoreIndex: 0)
    static let closers = RankerScenario(slug: "closers", shields: (0, 0), energy: (0, 0), scoreIndex: 1)
    static let switches = RankerScenario(slug: "switches", shields: (1, 1), energy: (4, 0), scoreIndex: 2)
    static let chargers = RankerScenario(slug: "chargers", shields: (1, 1), energy: (6, 0), scoreIndex: 3)
    static let attackers = RankerScenario(slug: "attackers", shields: (0, 1), energy: (0, 0), scoreIndex: 4)

    /// All 5, in `scoreIndex` order.
    static let all: [RankerScenario] = [leads, closers, switches, chargers, attackers]

    /// PvPoke's "N turns of fast-move advantage" → a starting energy value,
    /// scaled to `fastMove`'s own cooldown/energy gain (`Ranker.js`'s
    /// per-scenario energy setup). At least one fast-move's worth of energy
    /// is granted whenever the scenario calls for any advantage at all.
    static func startEnergy(turnsOfAdvantage: Double, fastMove: Move) -> Int {
        guard turnsOfAdvantage != 0, fastMove.cooldown > 0 else { return 0 }
        var fastMoveCount = Int((turnsOfAdvantage * 500) / Double(fastMove.cooldown))
        if fastMoveCount == 0 { fastMoveCount = 1 }
        return min(fastMove.energyGain * fastMoveCount, 100)
    }
}
