//
//  MatchupSimulator.swift
//  PokeParty
//
//  Bridges the app's data model to the battle engine: builds BattlePokemon from
//  a species + moveset and runs 1v1 matchups for a shield scenario.
//
//  Stat computation (the expensive IV optimization) is separated from battle
//  setup so callers can compute a Pokémon's stats once and reuse them across
//  many battles.
//

import Foundation

nonisolated enum MatchupSimulator {

    /// A combatant specification drawn from the app's data.
    struct Combatant {
        let species: Pokemon
        let shadow: Bool
        let fastMoveId: String
        let chargedMoveIds: [String]
    }

    /// The IV-optimal battle stats for a combatant at a CP cap (compute once).
    static func optimalStats(for c: Combatant, cpCap: Int, levelCap: Double = 50) -> BattlePokemon.Stats? {
        let base = c.species.baseStats
        guard let s = IVCalculator.optimalStats(
            baseAtk: base.atk, baseDef: base.def, baseHp: base.hp,
            cpCap: cpCap, levelCap: levelCap
        ) else { return nil }
        return .init(atk: s.atk, def: s.def, hp: s.hp)
    }

    /// Builds a battle-ready Pokémon from precomputed stats (cheap — no IV work).
    /// Each call makes fresh move/state objects, so it's safe to reuse stats.
    static func makeBattlePokemon(
        _ c: Combatant,
        stats: BattlePokemon.Stats,
        movesById: [String: Move],
        shields: Int,
        startEnergy: Int = 0
    ) -> BattlePokemon? {
        guard let fastMoveData = movesById[c.fastMoveId] else { return nil }
        let chargedData = c.chargedMoveIds.compactMap { movesById[$0] }
        guard !chargedData.isEmpty else { return nil }

        let bp = BattlePokemon(
            speciesId: c.species.speciesId,
            speciesName: c.species.speciesName,
            types: c.species.types,
            shadow: c.shadow,
            hasDisguise: c.species.hasDisguise,
            stats: stats,
            fastMove: BattleMove(from: fastMoveData),
            chargedMoves: chargedData.map(BattleMove.init)
        )
        bp.startingShields = shields
        bp.startEnergy = startEnergy
        return bp
    }

    /// Runs a 1v1 between two prepared sides and returns each side's rating.
    static func rate(
        _ a: Combatant, statsA: BattlePokemon.Stats,
        _ b: Combatant, statsB: BattlePokemon.Stats,
        movesById: [String: Move],
        shieldsA: Int, shieldsB: Int
    ) -> (a: Int, b: Int)? {
        guard let pa = makeBattlePokemon(a, stats: statsA, movesById: movesById, shields: shieldsA),
              let pb = makeBattlePokemon(b, stats: statsB, movesById: movesById, shields: shieldsB)
        else { return nil }
        let battle = Battle(pa, pb)
        battle.simulate()
        return (battle.battleRating(forIndex: 0), battle.battleRating(forIndex: 1))
    }

    /// Convenience: computes stats then rates (used in one-off simulations).
    static func rate(
        _ a: Combatant, _ b: Combatant,
        cpCap: Int, movesById: [String: Move],
        shieldsA: Int, shieldsB: Int, levelCap: Double = 50
    ) -> (a: Int, b: Int)? {
        guard let sa = optimalStats(for: a, cpCap: cpCap, levelCap: levelCap),
              let sb = optimalStats(for: b, cpCap: cpCap, levelCap: levelCap)
        else { return nil }
        return rate(a, statsA: sa, b, statsB: sb, movesById: movesById, shieldsA: shieldsA, shieldsB: shieldsB)
    }
}
