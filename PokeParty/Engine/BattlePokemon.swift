//
//  BattlePokemon.swift
//  PokeParty
//
//  Mutable battle state for one Pokémon, ported from PvPoke's Pokemon.js
//  battle methods (stats, buffs, move initialization & selection).
//

import Foundation

nonisolated final class BattlePokemon {
    let speciesId: String
    let speciesName: String
    let types: [String]
    /// Indices of `types` in `TypeChart.allTypes` (excluding "none").
    let typeIndices: [Int]
    let shadow: Bool
    /// Has Mimikyu's Disguise (blocks one charged move).
    let hasDisguise: Bool
    /// Whether the Disguise is still up this battle.
    var disguiseActive: Bool = false

    // Permanent stats (effective at the chosen level/IVs).
    struct Stats: Hashable, Sendable { var atk: Double; var def: Double; var hp: Int }
    let stats: Stats

    // Moves
    let fastMove: BattleMove
    /// All selected charged moves, in moveset order (the canonical index list).
    let chargedMoves: [BattleMove]
    /// Charged moves sorted/reordered for AI use.
    private(set) var activeChargedMoves: [BattleMove] = []
    private(set) var fastestChargedMove: BattleMove!
    private(set) var bestChargedMove: BattleMove?

    // Mutable battle state
    var hp: Int = 0
    var energy: Int = 0
    var shields: Int = 0
    var startingShields: Int = 0
    var startEnergy: Int = 0
    /// Starting HP for the next `reset()`. 0 means "full HP" (the normal 1v1 case);
    /// the 3v3 orchestrator sets this to carry a Pokémon's remaining HP across
    /// battle segments when it stays in after an opponent faints.
    var startHp: Int = 0
    var statBuffs: [Int] = [0, 0]
    var startStatBuffs: [Int] = [0, 0]
    var cooldown: Int = 0           // ms remaining on fast-move
    var hasActed: Bool = false
    var index: Int = 0
    var priority: Int = 0
    var turnsToKO: Int = -1
    enum FaintSource { case none, fast, charged }
    var faintSource: FaintSource = .none

    // AI behavior flags
    var baitShields: Int = 1        // 0 none, 1 selective, 2 always
    var optimizeMoveTiming: Bool = true
    var farmEnergy: Bool = false

    let shadowAtkMult: Double
    let shadowDefMult: Double

    private weak var opponent: BattlePokemon?
    /// Effectiveness of each attacking type against this Pokémon, indexed by
    /// `TypeChart.allTypes` position.
    private var typeEffectivenessCache: [Double] = []

    init(speciesId: String, speciesName: String, types: [String], shadow: Bool,
         hasDisguise: Bool = false,
         stats: Stats, fastMove: BattleMove, chargedMoves: [BattleMove]) {
        self.speciesId = speciesId
        self.speciesName = speciesName
        self.types = types.map { $0.lowercased() }
        self.typeIndices = self.types.map(TypeChart.index(of:)).filter { $0 >= 0 }
        self.shadow = shadow
        self.hasDisguise = hasDisguise
        self.stats = stats
        self.fastMove = fastMove
        self.chargedMoves = chargedMoves
        self.shadowAtkMult = shadow ? DamageMultiplier.shadowAtk : 1
        self.shadowDefMult = shadow ? DamageMultiplier.shadowDef : 1
        precomputeTypeEffectiveness()
    }

    // MARK: - Type effectiveness (as defender)

    private func precomputeTypeEffectiveness() {
        let n = TypeChart.allTypes.count
        var cache = [Double](repeating: 1, count: n)
        for a in 0..<n {
            for d in typeIndices { cache[a] *= TypeChart.matrix[a * n + d] }
        }
        typeEffectivenessCache = cache
    }

    /// Effectiveness of an attacking type (`TypeChart.allTypes` index) against
    /// this Pokémon; -1 (unknown type) is neutral.
    func typeEffectiveness(forTypeIndex index: Int) -> Double {
        index >= 0 ? typeEffectivenessCache[index] : 1
    }

    // MARK: - Stats & buffs

    private static let buffDivisor = 4.0

    func getStatBuffMultiplier(_ index: Int, useStart: Bool = false) -> Double {
        let source = useStart ? startStatBuffs : statBuffs
        let stage = source[index]
        if stage > 0 {
            return (Self.buffDivisor + Double(stage)) / Self.buffDivisor
        } else {
            return Self.buffDivisor / (Self.buffDivisor - Double(stage))
        }
    }

    func getEffectiveStat(_ index: Int, useStart: Bool = false) -> Double {
        var multiplier = getStatBuffMultiplier(index, useStart: useStart)
        if shadow {
            multiplier *= (index == 0) ? shadowAtkMult : shadowDefMult
        }
        return (index == 0 ? stats.atk : stats.def) * multiplier
    }

    func applyStatBuffs(_ buffs: [Int]) {
        for i in 0..<min(buffs.count, statBuffs.count) {
            statBuffs[i] = min(max(statBuffs[i] + buffs[i], -4), 4)
        }
    }

    var stab1: Double { DamageMultiplier.stab }

    private func stab(for move: BattleMove) -> Double {
        typeIndices.contains(move.typeIndex) ? DamageMultiplier.stab : 1
    }

    // MARK: - Move boost helper

    /// A guaranteed self-buffing charged move, used to "force throw" when farming.
    func getBoostMove() -> BattleMove? {
        chargedMoves.first { $0.buffApplyChance >= 0.5 && $0.selfBuffing && !$0.selfDebuffing }
    }

    func chargedMoveIndex(_ move: BattleMove) -> Int {
        chargedMoves.firstIndex { $0 === move } ?? 0
    }

    // MARK: - Reset & move initialization

    func setOpponent(_ opponent: BattlePokemon) { self.opponent = opponent }

    /// A fresh copy with the same config and start-state knobs, safe to mutate in a
    /// throwaway battle without touching the original (used for switch-decision sims).
    func clone() -> BattlePokemon {
        let c = BattlePokemon(
            speciesId: speciesId, speciesName: speciesName, types: types,
            shadow: shadow, hasDisguise: hasDisguise, stats: stats,
            fastMove: fastMove.clone(), chargedMoves: chargedMoves.map { $0.clone() })
        c.startEnergy = startEnergy
        c.startingShields = startingShields
        c.startHp = startHp
        c.startStatBuffs = startStatBuffs
        c.baitShields = baitShields
        c.optimizeMoveTiming = optimizeMoveTiming
        c.farmEnergy = farmEnergy
        return c
    }

    func reset() {
        hp = startHp > 0 ? min(startHp, stats.hp) : stats.hp
        energy = startEnergy
        shields = startingShields
        statBuffs = startStatBuffs
        cooldown = 0
        hasActed = false
        turnsToKO = -1
        faintSource = .none
        disguiseActive = hasDisguise
        for m in chargedMoves where m.buffApplyChance > 0 && m.buffApplyChance < 1 {
            m.buffApplyMeter = m.buffApplyChance == 0.5 ? 0 : m.buffApplyChance
        }
        resetMoves()
    }

    private func initializeMove(_ move: BattleMove) {
        move.stab = stab(for: move)
        if let opponent {
            move.damage = DamageCalculator.damage(self, opponent, move)
        } else {
            move.damage = Int((Double(move.power) * move.stab).rounded(.down))
        }
        guard move.energy > 0 else { return }
        move.dpe = Double(move.damage) / Double(move.energy)

        // Factor a rough buff value into DPE for move-selection purposes.
        if let buffs = move.buffs {
            var buffEffect = 0.0
            if move.buffTarget == "self", buffs.first ?? 0 > 0 {
                buffEffect = Double(buffs[0]) * (80.0 / Double(move.energy))
            } else if move.buffTarget == "opponent", buffs.count > 1, buffs[1] < 0 {
                buffEffect = Double(abs(buffs[1])) * (80.0 / Double(move.energy))
            }
            if buffEffect > 0 {
                let multiplier = (Self.buffDivisor + buffEffect * move.buffApplyChance) / Self.buffDivisor
                move.dpe *= multiplier
            }
        }
    }

    private func resetMoves() {
        initializeMove(fastMove)
        for m in chargedMoves { initializeMove(m) }

        activeChargedMoves = chargedMoves.sorted { $0.energy < $1.energy }
        guard !activeChargedMoves.isEmpty else { bestChargedMove = nil; return }
        fastestChargedMove = activeChargedMoves[0]

        if activeChargedMoves.count > 1 {
            reorderActiveChargedMoves()
        }

        // Best charged move = highest DPE with PvPoke's preference rules.
        var best = activeChargedMoves[0]
        for m in activeChargedMoves {
            if (m.dpe - best.dpe > 0.03 && m.moveId != "SUPER_POWER") || (m.dpe - best.dpe > 0.3) {
                if !best.selfBuffing || (best.selfBuffing && m.dpe - best.dpe > 0.3) {
                    best = m
                }
            }
            if abs(m.dpe - best.dpe) < 0.03, best.buffs != nil, m.buffs != nil,
               m.buffApplyChance > best.buffApplyChance, !m.selfDebuffing {
                best = m
            }
        }
        bestChargedMove = best
    }

    /// Port of Pokemon.js move-ordering heuristics (which move is the "bait").
    private func reorderActiveChargedMoves() {
        func swapFirstToBack() {
            let m = activeChargedMoves.removeFirst()
            activeChargedMoves.append(m)
        }
        let a0 = activeChargedMoves[0]
        let a1 = activeChargedMoves[1]

        if a1.energy == a0.energy, !a1.selfDebuffing {
            if a1.buffs != nil || a1.damage > a0.damage { swapFirstToBack(); return reorderTail() }
        }
        reorderTail()
    }

    private func reorderTail() {
        guard activeChargedMoves.count > 1 else { return }
        let a0 = activeChargedMoves[0]
        let a1 = activeChargedMoves[1]

        if a1.energy == a0.energy, a0.buffs != nil, a1.buffs != nil, !a1.selfDebuffing,
           a1.buffApplyChance > a0.buffApplyChance {
            let m = activeChargedMoves.removeFirst(); activeChargedMoves.append(m)
        }

        let b0 = activeChargedMoves[0], b1 = activeChargedMoves[1]
        if b1.energy - b0.energy <= 10, !b1.selfDebuffing,
           b1.selfBuffing, b0.dpe - b1.dpe < 0.3 {
            let m = activeChargedMoves.removeFirst(); activeChargedMoves.append(m)
        }

        let c0 = activeChargedMoves[0], c1 = activeChargedMoves[1]
        if c1.energy - c0.energy <= 10, c0.selfAttackDebuffing, !c1.selfDebuffing {
            let m = activeChargedMoves.removeFirst(); activeChargedMoves.append(m)
        }

        let d0 = activeChargedMoves[0], d1 = activeChargedMoves[1]
        if d1.energy - d0.energy <= 10, d0.selfDebuffing, d0.energy > 50, !d1.selfDebuffing {
            let m = activeChargedMoves.removeFirst(); activeChargedMoves.append(m)
        }

        let e0 = activeChargedMoves[0], e1 = activeChargedMoves[1]
        if e1.energy - e0.energy <= 5, e1.selfBuffing {
            let m = activeChargedMoves.removeFirst(); activeChargedMoves.append(m)
        }
    }
}
