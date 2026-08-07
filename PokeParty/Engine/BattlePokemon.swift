//
//  BattlePokemon.swift
//  PokeParty
//
//  Mutable battle state for one Pokémon, ported from PvPoke's Pokemon.js
//  battle methods (stats, buffs, move initialization & selection).
//

import Foundation

nonisolated struct BattlePokemon {
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

    // Moves — var so the engine can update scratch fields (damage, stab, dpe,
    // buffApplyMeter) in-place without allocating new objects.
    var fastMove: BattleMove
    /// All selected charged moves, in moveset order (the canonical index list).
    var chargedMoves: [BattleMove]
    /// Charged moves sorted/reordered for AI use (value copies of chargedMoves).
    private(set) var activeChargedMoves: [BattleMove] = []
    private(set) var fastestChargedMove: BattleMove?
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
    /// Whether the Disguise was already busted in an earlier 3v3 segment — it
    /// blocks only one charged move per MATCH, not per 1v1 segment.
    var startDisguiseConsumed = false
    var cooldown: Int = 0           // ms remaining on fast-move
    var hasActed: Bool = false
    var index: Int = 0
    var priority: Int = 0
    enum FaintSource { case none, fast, charged }
    var faintSource: FaintSource = .none

    // AI behavior flags
    var baitShields: Int = 1        // 0 none, 1 selective, 2 always
    var optimizeMoveTiming: Bool = true
    var farmEnergy: Bool = false

    let shadowAtkMult: Double
    let shadowDefMult: Double

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

    private mutating func precomputeTypeEffectiveness() {
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

    mutating func applyStatBuffs(_ buffs: [Int]) {
        for i in 0..<min(buffs.count, statBuffs.count) {
            statBuffs[i] = min(max(statBuffs[i] + buffs[i], -4), 4)
        }
    }

    private func stab(for move: BattleMove) -> Double {
        typeIndices.contains(move.typeIndex) ? DamageMultiplier.stab : 1
    }

    // MARK: - Move boost helper

    /// A guaranteed self-buffing charged move, used to "force throw" when farming.
    func getBoostMove() -> BattleMove? {
        chargedMoves.first { $0.buffApplyChance >= 0.5 && $0.selfBuffing && !$0.selfDebuffing }
    }

    /// Returns the index in `chargedMoves` that matches `move` by moveId.
    func chargedMoveIndex(_ move: BattleMove) -> Int {
        chargedMoves.firstIndex(where: { $0.moveId == move.moveId }) ?? 0
    }

    // MARK: - Reset & move initialization

    /// Resets battle state from the start* fields and initializes move scratch
    /// values against `opponent`. Call before each 1v1 segment.
    mutating func reset(opponent: BattlePokemon) {
        hp = startHp > 0 ? min(startHp, stats.hp) : stats.hp
        energy = startEnergy
        shields = startingShields
        statBuffs = startStatBuffs
        cooldown = 0
        hasActed = false
        faintSource = .none
        disguiseActive = hasDisguise && !startDisguiseConsumed
        // Reset probabilistic buff meters so ShieldSearch reruns are deterministic.
        for i in chargedMoves.indices
            where chargedMoves[i].buffApplyChance > 0 && chargedMoves[i].buffApplyChance < 1 {
            chargedMoves[i].buffApplyMeter =
                chargedMoves[i].buffApplyChance == 0.5 ? 0 : chargedMoves[i].buffApplyChance
        }
        if fastMove.buffApplyChance > 0 && fastMove.buffApplyChance < 1 {
            fastMove.buffApplyMeter = fastMove.buffApplyChance == 0.5 ? 0 : fastMove.buffApplyChance
        }
        resetMoves(opponent: opponent)
    }

    // Static so callers can pass an immutable snapshot of `self` as `attacker`,
    // avoiding Swift's exclusivity conflict when writing back to self's move arrays.
    private static func initializeMove(_ move: BattleMove, attacker: BattlePokemon, opponent: BattlePokemon) -> BattleMove {
        var m = move
        m.stab = attacker.stab(for: m)
        m.damage = DamageCalculator.damage(attacker, opponent, m)
        guard m.energy > 0 else { return m }
        m.dpe = Double(m.damage) / Double(m.energy)

        // Factor a rough buff value into DPE for move-selection purposes.
        if let buffs = m.buffs {
            var buffEffect = 0.0
            if m.buffTarget == "self", buffs.first ?? 0 > 0 {
                buffEffect = Double(buffs[0]) * (80.0 / Double(m.energy))
            } else if m.buffTarget == "opponent", buffs.count > 1, buffs[1] < 0 {
                buffEffect = Double(abs(buffs[1])) * (80.0 / Double(m.energy))
            }
            if buffEffect > 0 {
                let multiplier = (buffDivisor + buffEffect * m.buffApplyChance) / buffDivisor
                m.dpe *= multiplier
            }
        }
        return m
    }

    private mutating func resetMoves(opponent: BattlePokemon) {
        // Snapshot self so initializeMove reads attacker state without conflicting
        // with the writes back to fastMove and chargedMoves[i].
        let attacker = self
        fastMove = Self.initializeMove(fastMove, attacker: attacker, opponent: opponent)
        for i in chargedMoves.indices {
            chargedMoves[i] = Self.initializeMove(chargedMoves[i], attacker: attacker, opponent: opponent)
        }

        activeChargedMoves = chargedMoves.sorted { $0.energy < $1.energy }
        guard !activeChargedMoves.isEmpty else { bestChargedMove = nil; fastestChargedMove = nil; return }
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
    private mutating func reorderActiveChargedMoves() {
        let a0 = activeChargedMoves[0]
        let a1 = activeChargedMoves[1]

        if a1.energy == a0.energy, !a1.selfDebuffing {
            if a1.buffs != nil || a1.damage > a0.damage {
                activeChargedMoves.append(activeChargedMoves.removeFirst())
                reorderTail()
                return
            }
        }
        reorderTail()
    }

    private mutating func reorderTail() {
        guard activeChargedMoves.count > 1 else { return }
        let a0 = activeChargedMoves[0]
        let a1 = activeChargedMoves[1]

        if a1.energy == a0.energy, a0.buffs != nil, a1.buffs != nil, !a1.selfDebuffing,
           a1.buffApplyChance > a0.buffApplyChance {
            activeChargedMoves.append(activeChargedMoves.removeFirst())
        }

        let b0 = activeChargedMoves[0], b1 = activeChargedMoves[1]
        if b1.energy - b0.energy <= 10, !b1.selfDebuffing,
           b1.selfBuffing, b0.dpe - b1.dpe < 0.3 {
            activeChargedMoves.append(activeChargedMoves.removeFirst())
        }

        let c0 = activeChargedMoves[0], c1 = activeChargedMoves[1]
        if c1.energy - c0.energy <= 10, c0.selfAttackDebuffing, !c1.selfDebuffing {
            activeChargedMoves.append(activeChargedMoves.removeFirst())
        }

        let d0 = activeChargedMoves[0], d1 = activeChargedMoves[1]
        if d1.energy - d0.energy <= 10, d0.selfDebuffing, d0.energy > 50, !d1.selfDebuffing {
            activeChargedMoves.append(activeChargedMoves.removeFirst())
        }

        let e0 = activeChargedMoves[0], e1 = activeChargedMoves[1]
        if e1.energy - e0.energy <= 5, e1.selfBuffing {
            activeChargedMoves.append(activeChargedMoves.removeFirst())
        }
    }
}
