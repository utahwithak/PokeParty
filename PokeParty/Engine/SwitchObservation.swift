//
//  SwitchObservation.swift
//  PokeParty
//
//  RL milestone 2 (switch policy): the decision seam types and observation
//  vector for 3v3 switch decisions — boundary voluntary switches, counterswaps
//  onto a locked opponent, and faint replacements. Captured wherever
//  `ThreeVThreeBattle.switchDecisionHook` is consulted; used to log rollout-
//  teacher training data and to feed the learned policy at inference.
//
//  Revealed-info only: the vector sees our full team state, the opponent's
//  CURRENT mon (species, HP bar, counted energy, shields), and the battle
//  clock. It never consults the opponent's hidden backline.
//

import Foundation

/// What an external policy tells the 3v3 orchestrator to do at a switch
/// decision point.
nonisolated enum SwitchDecision {
    /// Keep the active Pokémon in (invalid for faint replacements).
    case stay
    /// Bring in this team index (must be alive and not the active one).
    case switchTo(Int)
    /// Defer to the built-in heuristics.
    case heuristic
}

/// Everything a switch decision may legitimately look at.
nonisolated struct SwitchContext {
    let side: Int                  // 0 = team A, 1 = team B
    let team: [BattlePokemon]      // start* fields carry current state
    let fainted: Set<Int>
    let active: Int                // the mon on the field (just fainted if mandatory)
    let opponent: BattlePokemon    // the opponent's revealed, current mon
    let teamShields: Int
    let opponentShields: Int
    let time: Int                  // battle clock, ms
    let opponentLocked: Bool       // opponent just switched: on its switch timer
    let mandatory: Bool            // faint replacement: staying is not an option
}

nonisolated enum SwitchObservation {

    /// Canonical action order: 0 = stay, 1 = first alive backup, 2 = second
    /// (alive non-active team indices, ascending). Returns the backup indices.
    static func backups(_ ctx: SwitchContext) -> [Int] {
        (0..<ctx.team.count).filter { !ctx.fainted.contains($0) && $0 != ctx.active }
    }

    /// Valid canonical actions for this context (stay excluded when mandatory).
    static func legalActions(_ ctx: SwitchContext) -> [Int] {
        var result = [Int]()
        result.reserveCapacity(3)
        if !ctx.mandatory { result.append(0) }
        let b = backups(ctx)
        for i in b.indices { result.append(i + 1) }
        return result
    }

    /// Maps a canonical action to a `SwitchDecision`.
    static func decision(for action: Int, _ ctx: SwitchContext) -> SwitchDecision {
        guard action > 0 else { return .stay }
        let b = backups(ctx)
        guard b.indices.contains(action - 1) else { return .heuristic }
        return .switchTo(b[action - 1])
    }

    /// Stable feature order (shared with rl/train_switch.py via metadata).
    /// Slot 0 is the active mon; slots 1–2 the canonical backups (zeroed when
    /// absent). Damage estimates are the largest charged hit each way, normalised
    /// by the target's max HP — a sim-free proxy for matchup quality.
    static let featureNames: [String] = {
        var names: [String] = []
        for s in 0..<3 {
            names += ["s\(s)_alive", "s\(s)_hp_frac", "s\(s)_energy",
                      "s\(s)_dmg_out", "s\(s)_dmg_in"]
        }
        names += ["team_shields", "opp_shields", "opp_hp_frac", "opp_energy",
                  "alive_frac", "time_frac", "opp_locked", "mandatory"]
        return names
    }()

    static var featureCount: Int { featureNames.count }

    static func capture(_ ctx: SwitchContext) -> [Double] {
        // Pre-allocate full zeroed buffer — avoids append/resize overhead and
        // eliminates the [0,0,0,0,0] temporary arrays for absent slots.
        var x = [Double](repeating: 0, count: featureCount)
        var i = 0

        fillSlot(&x, into: &i, ctx.team[ctx.active], ctx, alive: !ctx.fainted.contains(ctx.active))
        let b = backups(ctx)
        for s in 0..<2 {
            if s < b.count {
                fillSlot(&x, into: &i, ctx.team[b[s]], ctx, alive: true)
            } else {
                i += 5  // zeros already in place
            }
        }

        let aliveCount = ctx.team.count - ctx.fainted.count
        x[i] = Double(ctx.teamShields) / 2;                                     i += 1
        x[i] = Double(ctx.opponentShields) / 2;                                 i += 1
        x[i] = Double(carriedHp(ctx.opponent)) / Double(ctx.opponent.stats.hp); i += 1
        x[i] = Double(ctx.opponent.startEnergy) / 100;                          i += 1
        x[i] = Double(aliveCount) / 3;                                          i += 1
        x[i] = min(Double(ctx.time) / 240_000, 1);                              i += 1
        x[i] = ctx.opponentLocked ? 1 : 0;                                      i += 1
        x[i] = ctx.mandatory ? 1 : 0
        return x
    }

    private static func fillSlot(_ x: inout [Double], into i: inout Int,
                                  _ mon: BattlePokemon, _ ctx: SwitchContext, alive: Bool) {
        guard alive else { i += 5; return }  // zeros already in place
        let maxHp = Double(mon.stats.hp)
        let oppMaxHp = Double(ctx.opponent.stats.hp)

        // Biggest charged hit each way (any energy — a "matchup shape" signal).
        var dmgOut = 0.0
        for m in mon.chargedMoves {
            dmgOut = max(dmgOut, Double(DamageCalculator.damage(mon, ctx.opponent, m)))
        }
        var dmgIn = 0.0
        for m in ctx.opponent.chargedMoves {
            dmgIn = max(dmgIn, Double(DamageCalculator.damage(ctx.opponent, mon, m)))
        }

        x[i] = 1;                                                i += 1
        x[i] = Double(carriedHp(mon)) / maxHp;                  i += 1
        x[i] = Double(mon.startEnergy) / 100;                   i += 1
        x[i] = min(dmgOut / oppMaxHp, 2) / 2;                   i += 1
        x[i] = min(dmgIn / Double(carriedHp(mon)), 2) / 2;      i += 1
    }

    /// Carried HP between segments (`startHp == 0` = never entered = full).
    private static func carriedHp(_ p: BattlePokemon) -> Int {
        p.startHp > 0 ? min(p.startHp, p.stats.hp) : p.stats.hp
    }
}
