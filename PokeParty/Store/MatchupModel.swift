//
//  MatchupModel.swift
//  PokeParty
//
//  Observable state for the 1v1 Simulator: two user-chosen combatants, and the
//  matchup solved for every shield scenario (0–2 shields per side). Each scenario
//  uses `ShieldSearch`, so both sides shield with game-optimal timing, and the
//  battle is recorded so the timeline viewer can scrub through it.
//

import SwiftUI

@MainActor
@Observable
final class MatchupModel {

    enum Side: Hashable {
        case a, b
        var other: Side { self == .a ? .b : .a }
    }

    private(set) var memberA: TeamMember?
    private(set) var memberB: TeamMember?

    /// The shield scenario currently shown (shields available to each side).
    var shieldsA = 1 { didSet { if oldValue != shieldsA { clearSubScenario() } } }
    var shieldsB = 1 { didSet { if oldValue != shieldsB { clearSubScenario() } } }

    /// One solved battle per shield scenario, indexed [shieldsA][shieldsB].
    struct Results: Sendable {
        let solutions: [[ShieldSearch.Solution]]
        let logs: [[BattleLog]]
    }

    private(set) var results: Results?
    private(set) var isSimulating = false
    private var simTask: Task<Void, Never>?

    // Sub-scenario state: a non-optimal timing choice replayed on demand.
    private(set) var selectedSubScenario: ShieldSearch.ScenarioItem?
    private(set) var selectedSubLog: BattleLog?
    private var replayTask: Task<Void, Never>?

    // Retained so sub-scenario replays can skip re-preparing.
    private typealias PreparedSide = (combatant: MatchupSimulator.Combatant, stats: BattlePokemon.Stats)
    private var preparedA: PreparedSide?
    private var preparedB: PreparedSide?

    var hasBothSides: Bool { memberA != nil && memberB != nil }

    func member(for side: Side) -> TeamMember? {
        side == .a ? memberA : memberB
    }

    /// The solution + recorded log for the currently shown battle.
    /// Uses the sub-scenario log when one is selected.
    var current: (solution: ShieldSearch.Solution, log: BattleLog)? {
        guard let results,
              results.solutions.indices.contains(shieldsA),
              results.solutions[shieldsA].indices.contains(shieldsB) else { return nil }
        let sol = results.solutions[shieldsA][shieldsB]
        let log = selectedSubLog ?? results.logs[shieldsA][shieldsB]
        return (sol, log)
    }

    // MARK: - Sub-scenario replay

    func selectSubScenario(_ item: ShieldSearch.ScenarioItem, using store: RankingsStore) {
        guard let a = preparedA, let b = preparedB else { return }
        replayTask?.cancel()
        let movesById = store.movesById
        let sA = shieldsA, sB = shieldsB
        let pA = item.policyA, pB = item.policyB
        selectedSubScenario = item
        selectedSubLog = nil
        replayTask = Task {
            let log = await Task.detached {
                ShieldSearch.play(a.combatant, statsA: a.stats, b.combatant, statsB: b.stats,
                                  movesById: movesById, shieldsA: sA, shieldsB: sB,
                                  policyA: pA, policyB: pB, record: true)?.log
            }.value
            guard !Task.isCancelled else { return }
            self.selectedSubLog = log
        }
    }

    func clearSubScenario() {
        replayTask?.cancel()
        selectedSubScenario = nil
        selectedSubLog = nil
    }

    // MARK: - Editing

    /// Sets (or clears, with `nil`) a side's combatant.
    func set(_ member: TeamMember?, side: Side) {
        switch side {
        case .a: memberA = member
        case .b: memberB = member
        }
        invalidate()
    }

    func setFastMove(_ id: String, side: Side) {
        update(side) { $0.fastMoveId = id }
    }

    /// Sets (or clears, with `nil`) a charged-move slot (0 = first, 1 = second).
    func setChargedMove(_ id: String?, slot: Int, side: Side) {
        update(side) { member in
            var charged = member.chargedMoveIds
            if let id {
                // Don't allow the same move in both charged slots.
                if charged.enumerated().contains(where: { $0.offset != slot && $0.element == id }) { return }
                if slot < charged.count { charged[slot] = id } else { charged.append(id) }
            } else if slot < charged.count {
                charged.remove(at: slot)
            }
            guard !charged.isEmpty else { return }
            member.chargedMoveIds = charged
        }
    }

    func setShadow(_ shadow: Bool, side: Side) {
        update(side) { $0.shadow = shadow }
    }

    /// Sets (or clears, with `nil`) a side's IVs. nil uses PvP-optimal stats
    /// for the current league's CP cap.
    func setIVs(_ ivs: IVs?, side: Side) {
        update(side) { $0.ivs = ivs }
    }

    private func update(_ side: Side, _ change: (inout TeamMember) -> Void) {
        guard var member = member(for: side) else { return }
        let before = member
        change(&member)
        guard member != before else { return }
        set(member, side: side)
    }

    private func invalidate() {
        simTask?.cancel()
        replayTask?.cancel()
        results = nil
        isSimulating = false
        selectedSubScenario = nil
        selectedSubLog = nil
        preparedA = nil
        preparedB = nil
    }

    // MARK: - Building members from the data

    /// Builds a combatant for a species, defaulting to its recommended moveset
    /// (mirrors `TeamBuilderModel.makeMember`).
    func makeMember(speciesId: String, store: RankingsStore) -> TeamMember? {
        guard let species = store.pokemonById[speciesId] else { return nil }
        if let entry = store.entry(id: speciesId), entry.moveset.count >= 2 {
            return TeamMember(speciesId: speciesId,
                              fastMoveId: entry.moveset[0],
                              chargedMoveIds: Array(entry.moveset[1...].prefix(2)),
                              shadow: species.isShadow)
        }
        guard let fast = species.fastMoves.first else { return nil }
        return TeamMember(speciesId: speciesId,
                          fastMoveId: fast,
                          chargedMoveIds: Array(species.chargedMoves.prefix(2)),
                          shadow: species.isShadow)
    }

    // MARK: - Simulation

    /// Solves the matchup for every shield scenario at the current league's CP cap.
    func simulate(using store: RankingsStore) {
        simTask?.cancel()
        guard let a = memberA, let b = memberB,
              let sideA = Self.prepare(a, store: store),
              let sideB = Self.prepare(b, store: store) else {
            results = nil
            isSimulating = false
            return
        }
        let movesById = store.movesById
        isSimulating = true
        results = nil
        selectedSubScenario = nil
        selectedSubLog = nil
        preparedA = sideA
        preparedB = sideB
        simTask = Task {
            let result = await Task.detached {
                Self.solveAllScenarios(a: sideA, b: sideB, movesById: movesById)
            }.value
            if Task.isCancelled { return }
            self.results = result
            self.isSimulating = false
        }
    }

    /// Builds the combatant + stats for a member. A member with explicit IVs
    /// uses those (at the CP cap's best level); otherwise prefers the stats
    /// already in the ranking data, falling back to the (expensive) IV optimizer.
    private static func prepare(
        _ member: TeamMember, store: RankingsStore
    ) -> (combatant: MatchupSimulator.Combatant, stats: BattlePokemon.Stats)? {
        guard let species = store.pokemonById[member.speciesId] else { return nil }
        let combatant = MatchupSimulator.Combatant(
            species: species, shadow: member.shadow,
            fastMoveId: member.fastMoveId, chargedMoveIds: member.chargedMoveIds)
        let stats: BattlePokemon.Stats?
        if let ivs = member.ivs {
            let levelCap: Double = member.isBestBuddy ? 51 : 50
            stats = IVCalculator.stats(
                baseAtk: species.baseStats.atk, baseDef: species.baseStats.def, baseHp: species.baseStats.hp,
                ivs: ivs, cpCap: store.format.cp, levelCap: levelCap
            ).map { BattlePokemon.Stats(atk: $0.atk, def: $0.def, hp: $0.hp) }
        } else if let s = store.entry(id: member.speciesId)?.stats {
            stats = .init(atk: s.atk, def: s.def, hp: Int(s.hp))
        } else {
            stats = MatchupSimulator.optimalStats(for: combatant, cpCap: store.format.cp)
        }
        guard let stats else { return nil }
        return (combatant, stats)
    }

    /// Solves all 3×3 shield scenarios: each one gets optimal shield timing for
    /// both sides plus a recorded battle under those policies.
    private nonisolated static func solveAllScenarios(
        a: (combatant: MatchupSimulator.Combatant, stats: BattlePokemon.Stats),
        b: (combatant: MatchupSimulator.Combatant, stats: BattlePokemon.Stats),
        movesById: [String: Move]
    ) -> Results? {
        var solutions: [[ShieldSearch.Solution]] = []
        var logs: [[BattleLog]] = []
        for shieldsA in 0...2 {
            var solutionRow: [ShieldSearch.Solution] = []
            var logRow: [BattleLog] = []
            for shieldsB in 0...2 {
                guard let solution = ShieldSearch.optimal(
                        a.combatant, statsA: a.stats, b.combatant, statsB: b.stats,
                        movesById: movesById, shieldsA: shieldsA, shieldsB: shieldsB),
                      let log = ShieldSearch.play(
                        a.combatant, statsA: a.stats, b.combatant, statsB: b.stats,
                        movesById: movesById, shieldsA: shieldsA, shieldsB: shieldsB,
                        policyA: solution.policyA, policyB: solution.policyB, record: true)?.log
                else { return nil }
                solutionRow.append(solution)
                logRow.append(log)
            }
            solutions.append(solutionRow)
            logs.append(logRow)
        }
        return Results(solutions: solutions, logs: logs)
    }
}
