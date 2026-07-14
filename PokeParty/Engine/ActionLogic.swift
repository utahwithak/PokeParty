//
//  ActionLogic.swift
//  PokeParty
//
//  The deterministic battle AI, ported from PvPoke's ActionLogic.js
//  (decideAction + wouldShield). Form-change / Aegislash / Melmetal-Cresselia
//  special cases and the force-disabled probabilistic-buff TTK system are omitted.
//

import Foundation

/// A state in the optimal move-sequence search.
private nonisolated struct BattleState {
    var energy: Int
    var oppHealth: Int
    var turn: Int
    var oppShields: Int
    var moves: [BattleMove]
    var buffs: Int
    var chance: Double
    init(_ energy: Int, _ oppHealth: Int, _ turn: Int, _ oppShields: Int, _ moves: [BattleMove], _ buffs: Int, _ chance: Double) {
        self.energy = energy; self.oppHealth = oppHealth; self.turn = turn
        self.oppShields = oppShields; self.moves = moves; self.buffs = buffs; self.chance = chance
    }
}

nonisolated enum ActionLogic {

    struct ShieldDecision { var value: Bool; var shieldWeight: Int; var noShieldWeight: Int }

    private static let infinity = Int.max

    /// Returns the action this Pokémon should take this turn, or nil to throw a fast move.
    static func decideAction(_ battle: Battle, _ poke: BattlePokemon, _ opponent: BattlePokemon) -> TimelineAction? {
        let turns = battle.turns
        let winsCMP = poke.stats.atk >= opponent.stats.atk
        let oppFastDamage = DamageCalculator.damage(opponent, poke, opponent.fastMove)
        let fastDamage = DamageCalculator.damage(poke, opponent, poke.fastMove)

        if poke.activeChargedMoves.isEmpty { return nil }
        if poke.energy < poke.fastestChargedMove.energy || poke.farmEnergy { return nil }

        var hasNonDebuff = false
        var chargedMoveReady: [Int] = []
        for m in poke.activeChargedMoves {
            if !m.selfDebuffing { hasNonDebuff = true }
            if poke.energy >= m.energy {
                chargedMoveReady.append(0)
            } else {
                chargedMoveReady.append(Int(ceil(Double(m.energy - poke.energy) / Double(poke.fastMove.energyGain))) * poke.fastMove.turns)
            }
        }
        _ = hasNonDebuff

        // MARK: Survival lookahead — how many turns until the opponent can KO us.
        var turnsToLive = infinity
        struct SurvState { var hp: Int; var opEnergy: Int; var turn: Int; var shields: Int }
        var stack: [SurvState] = []
        if opponent.cooldown != 0 {
            stack.append(SurvState(hp: poke.hp - oppFastDamage, opEnergy: opponent.energy + opponent.fastMove.energyGain, turn: opponent.cooldown / 500, shields: poke.shields))
        } else {
            stack.append(SurvState(hp: poke.hp, opEnergy: opponent.energy, turn: 0, shields: poke.shields))
        }

        while !stack.isEmpty {
            let curr = stack.removeLast()

            if curr.hp > oppFastDamage {
                if winsCMP {
                    if curr.turn > poke.fastMove.turns { continue }
                } else {
                    if curr.turn > poke.fastMove.turns + 1 { continue }
                }
            }

            if curr.shields != 0 {
                if curr.opEnergy >= opponent.fastestChargedMove.energy {
                    stack.append(SurvState(hp: curr.hp - 1, opEnergy: curr.opEnergy - opponent.fastestChargedMove.energy, turn: curr.turn + 1, shields: curr.shields - 1))
                }
            } else {
                var koed = false
                for m in opponent.activeChargedMoves where curr.opEnergy >= m.energy {
                    let moveDamage = DamageCalculator.damage(opponent, poke, m)
                    if moveDamage >= curr.hp {
                        turnsToLive = min(curr.turn, turnsToLive)
                        if poke.stats.atk > opponent.stats.atk && opponent.fastMove.cooldown % poke.fastMove.cooldown == 0 {
                            if turnsToLive != infinity { turnsToLive += 1 }
                        }
                        koed = true
                        break
                    }
                    stack.append(SurvState(hp: curr.hp - moveDamage, opEnergy: curr.opEnergy - m.energy, turn: curr.turn + 1, shields: curr.shields))
                }
                if koed { /* matches JS break out of for, continue while */ }
            }

            if curr.hp - oppFastDamage <= 0 {
                turnsToLive = min(curr.turn + opponent.fastMove.turns, turnsToLive)
                break
            } else {
                stack.append(SurvState(hp: curr.hp - oppFastDamage, opEnergy: curr.opEnergy + opponent.fastMove.energyGain, turn: curr.turn + opponent.fastMove.turns, shields: curr.shields))
            }
        }

        // MARK: If we'll be KO'd very soon, throw the biggest move we can.
        if turnsToLive != infinity {
            var ttl = turnsToLive
            if poke.hp <= opponent.fastMove.damage * 2 && opponent.fastMove.cooldown == 500 { ttl -= 1 }
            if poke.hp <= opponent.fastMove.damage && opponent.cooldown > 0 && opponent.fastMove.cooldown > 500 {
                ttl = opponent.cooldown / 500
                if opponent.hp > poke.fastMove.damage { ttl -= 1 }
            }
            if poke.hp <= opponent.fastMove.damage && opponent.cooldown == 0 && opponent.fastMove.cooldown <= poke.fastMove.cooldown + 500 {
                if opponent.hp > poke.fastMove.damage { ttl -= 1 }
            }

            if ttl * 500 < poke.fastMove.cooldown
                || (ttl * 500 == poke.fastMove.cooldown && !winsCMP)
                || (ttl * 500 == poke.fastMove.cooldown && poke.hp <= opponent.fastMove.damage) {
                var maxDamageMoveIndex = 0
                var prevMoveDamage = -1
                var n = poke.activeChargedMoves.count
                while n >= 0 {
                    defer { n -= 1 }
                    guard n < poke.activeChargedMoves.count, chargedMoveReady[n] == 0 else { continue }
                    let move = poke.activeChargedMoves[n]
                    let moveDamage = DamageCalculator.damage(poke, opponent, move)
                    if moveDamage > prevMoveDamage {
                        maxDamageMoveIndex = poke.chargedMoveIndex(move)
                        prevMoveDamage = moveDamage
                    }
                    if poke.energy >= move.energy * 2 && poke.stats.atk > opponent.stats.atk && moveDamage * 2 > prevMoveDamage {
                        maxDamageMoveIndex = poke.chargedMoveIndex(move)
                        prevMoveDamage = moveDamage * 2
                    }
                }
                if prevMoveDamage == -1 {
                    return nil
                } else {
                    return TimelineAction(type: .charged, actor: poke.index, turn: turns, value: maxDamageMoveIndex, priority: poke.priority)
                }
            }
        }

        // MARK: Throw a lethal move if it KOs now (shields down).
        if !poke.farmEnergy && opponent.shields == 0 {
            for (n, move) in poke.activeChargedMoves.enumerated() where poke.energy >= move.energy {
                let moveDamage = DamageCalculator.damage(poke, opponent, move)
                if opponent.hp <= moveDamage && !move.selfDebuffing
                    && (n == 0 || (n == 1 && poke.baitShields == 0))
                    && opponent.hp > poke.fastMove.damage {
                    return TimelineAction(type: .charged, actor: poke.index, turn: turns, value: poke.chargedMoveIndex(move), priority: poke.priority)
                }
            }
        }

        // MARK: Pop an opponent's Disguise (Mimikyu) ASAP with the cheapest move.
        if opponent.disguiseActive && opponent.shields == 0 {
            if poke.energy >= poke.fastestChargedMove.energy && !poke.fastestChargedMove.selfDebuffing {
                return TimelineAction(type: .charged, actor: poke.index, turn: turns,
                                      value: poke.chargedMoveIndex(poke.fastestChargedMove), priority: poke.priority)
            }
        }

        // MARK: Optimize move timing to deny the opponent free turns.
        if poke.optimizeMoveTiming {
            var targetCooldown = 500
            if poke.fastMove.cooldown >= 2000 { targetCooldown = 1000 }
            if poke.fastMove.cooldown >= 1500 && opponent.fastMove.cooldown == 2500 { targetCooldown = 1000 }
            if poke.fastMove.cooldown == 1000 && opponent.fastMove.cooldown == 2000 { targetCooldown = 1000 }
            if poke.fastMove.cooldown == opponent.fastMove.cooldown { targetCooldown = 0 }
            if poke.fastMove.cooldown % opponent.fastMove.cooldown == 0 && poke.fastMove.cooldown > opponent.fastMove.cooldown { targetCooldown = 0 }

            if (opponent.cooldown == 0 || opponent.cooldown > targetCooldown) && targetCooldown > 0 {
                var optimizeTiming = true
                if poke.hp <= opponent.fastMove.damage { optimizeTiming = false }

                var queuedFastMoves = 0
                for a in battle.queuedActions where a.actor == poke.index && a.type == .fast { queuedFastMoves += 1 }
                queuedFastMoves += 1
                if poke.energy + poke.fastMove.energyGain * queuedFastMoves > 100 { optimizeTiming = false }

                var turnsPlanned = poke.fastMove.turns + (poke.energy / poke.activeChargedMoves[0].energy)
                if poke.stats.atk < opponent.stats.atk { turnsPlanned += 1 }
                if turnsToLive != infinity && turnsPlanned > turnsToLive { optimizeTiming = false }

                if opponent.shields == 0 {
                    for m in poke.activeChargedMoves {
                        m.damage = DamageCalculator.damage(poke, opponent, m)
                        if poke.energy >= m.energy && m.damage >= opponent.hp { optimizeTiming = false; break }
                    }
                }

                for m in opponent.activeChargedMoves {
                    let fastMovesFromCharged = Int(ceil(Double(m.energy - opponent.energy) / Double(opponent.fastMove.energyGain)))
                    let fastMovesInFastMove = poke.fastMove.cooldown / opponent.fastMove.cooldown
                    let turnsFromMove = fastMovesFromCharged * opponent.fastMove.turns + 1
                    m.damage = DamageCalculator.damage(opponent, poke, m)
                    var moveDamage = m.damage + opponent.fastMove.damage * fastMovesInFastMove
                    if poke.shields > 0 { moveDamage = 1 + opponent.fastMove.damage * fastMovesInFastMove }
                    if turnsFromMove <= poke.fastMove.turns && moveDamage >= poke.hp { optimizeTiming = false; break }
                }

                let fastMovesInFastMove2 = (poke.fastMove.cooldown + 500) / opponent.fastMove.cooldown
                if poke.hp <= opponent.fastMove.damage * fastMovesInFastMove2 { optimizeTiming = false }

                if optimizeTiming { return nil }
            }
        }

        // MARK: If KO will take many cycles, just throw the best (or bait) move.
        let bestChargedDamage = DamageCalculator.damage(poke, opponent, poke.bestChargedMove ?? poke.activeChargedMoves[0])
        let bestMove = poke.bestChargedMove ?? poke.activeChargedMoves[0]
        let bestCycleDamage = bestChargedDamage + fastDamage * Int(ceil(Double(bestMove.energy) / Double(poke.fastMove.energyGain)))
        var minimumCycleThreshold = 2.0
        if bestMove.selfDebuffing && bestMove.energy > poke.fastestChargedMove.energy && bestMove.dpe / poke.fastestChargedMove.dpe < 2 {
            minimumCycleThreshold = 1.1
        }
        if Double(opponent.hp) / Double(bestCycleDamage) > minimumCycleThreshold {
            var selectedMove = bestMove
            if poke.activeChargedMoves.count > 1 {
                if poke.baitShields != 0 && opponent.shields > 0 && !poke.activeChargedMoves[0].selfDebuffing
                    && wouldShield(battle, poke, opponent, poke.activeChargedMoves[1]).value {
                    selectedMove = poke.activeChargedMoves[0]
                }
                if bestMove.selfDebuffing {
                    for m in poke.activeChargedMoves where !m.selfDebuffing && selectedMove.dpe / m.dpe < 2 {
                        selectedMove = m
                    }
                }
            }
            if poke.energy < selectedMove.energy { return nil }
            if selectedMove.selfDebuffing {
                let energyToReach = poke.energy + ((100 - poke.energy) / poke.fastMove.energyGain) * poke.fastMove.energyGain
                if poke.energy < energyToReach { return nil }
            }
            return TimelineAction(type: .charged, actor: poke.index, turn: turns, value: poke.chargedMoveIndex(selectedMove), priority: poke.priority)
        }

        // MARK: Optimal move-sequence search (DP).
        guard let finalState = optimalPlan(battle, poke, opponent) else { return nil }
        poke.turnsToKO = turns + (finalState.lastTurn)

        var plan = finalState.moves
        if plan.isEmpty {
            if let boost = poke.getBoostMove() { plan.append(boost) } else { return nil }
        }

        var debuffingMove = false
        for m in plan where m.selfDebuffing { debuffingMove = true }

        // Baiting / move-ordering heuristics.
        if poke.baitShields != 0 && opponent.shields > 0 && poke.activeChargedMoves.count > 1 {
            if poke.energy < poke.activeChargedMoves[1].energy && poke.activeChargedMoves[1].dpe > plan[0].dpe {
                var bait = true
                if poke.activeChargedMoves[1].dpe / poke.activeChargedMoves[0].dpe <= 1.5 && poke.activeChargedMoves[0].selfBuffing { bait = false }
                if bait { return nil }
            }
        }
        if poke.baitShields != 0 && opponent.shields > 0 && poke.activeChargedMoves.count > 1 {
            let dpeRatio = (Double(poke.activeChargedMoves[1].damage) / Double(poke.activeChargedMoves[1].energy)) / (Double(plan[0].damage) / Double(plan[0].energy))
            if poke.energy >= poke.activeChargedMoves[1].energy && dpeRatio > 1.5 {
                if !wouldShield(battle, poke, opponent, poke.activeChargedMoves[1]).value { plan[0] = poke.activeChargedMoves[1] }
            }
        }
        if !poke.baitShields.isNonZero || (opponent.shields == 0 && !debuffingMove) {
            plan.sort { DamageCalculator.damage(poke, opponent, $0) > DamageCalculator.damage(poke, opponent, $1) }
        }
        if opponent.shields > 0 && poke.activeChargedMoves.count > 1 && poke.activeChargedMoves[0].energy <= plan[0].energy
            && poke.activeChargedMoves[0].dpe > plan[0].dpe && !poke.activeChargedMoves[0].selfDebuffing {
            plan[0] = poke.activeChargedMoves[0]
        }
        if opponent.shields == 0 && poke.activeChargedMoves.count > 1 && plan[0].selfDebuffing && plan[0].energy > 50
            && Double(poke.hp) / Double(poke.stats.hp) > 0.5 && Double(plan[0].damage) / Double(opponent.hp) < 0.8 {
            plan[0] = poke.activeChargedMoves[0]
        }
        if poke.activeChargedMoves.count > 1 && poke.activeChargedMoves[0].energy == plan[0].energy
            && poke.activeChargedMoves[0].dpe > plan[0].dpe && !poke.activeChargedMoves[0].selfDebuffing {
            plan[0] = poke.activeChargedMoves[0]
        }
        if poke.activeChargedMoves.count > 1 && poke.activeChargedMoves[0].energy - 10 <= plan[0].energy
            && poke.activeChargedMoves[0].dpe > plan[0].dpe && plan[0].selfDebuffing && !poke.activeChargedMoves[0].selfDebuffing {
            plan[0] = poke.activeChargedMoves[0]
        }
        if poke.activeChargedMoves.count > 1 && poke.activeChargedMoves[0].energy - plan[0].energy <= 5
            && poke.activeChargedMoves[0].dpe > plan[0].dpe && poke.activeChargedMoves[0].selfBuffing {
            plan[0] = poke.activeChargedMoves[0]
        }
        if poke.baitShields != 0 && opponent.shields > 0 && poke.activeChargedMoves.count > 1 {
            if poke.energy >= poke.activeChargedMoves[1].energy && poke.activeChargedMoves[1].dpe > plan[0].dpe {
                if plan[0].selfDebuffing && !poke.activeChargedMoves[1].selfDebuffing { plan[0] = poke.activeChargedMoves[1] }
            }
        }
        if opponent.shields > 0 && poke.activeChargedMoves.count > 1 {
            if poke.activeChargedMoves[0].selfDebuffing && !poke.activeChargedMoves[1].selfBuffing {
                if poke.baitShields != 0 || (opponent.hp - poke.activeChargedMoves[0].damage > 10) {
                    if poke.activeChargedMoves[1].energy - poke.activeChargedMoves[0].energy <= 10
                        && poke.activeChargedMoves[1].dpe / poke.activeChargedMoves[0].dpe > 0.7 {
                        plan[0] = poke.activeChargedMoves[1]
                    }
                }
            }
        }
        if plan[0].selfDebuffing && poke.shields == 0 && poke.energy < 100, let oppBest = opponent.bestChargedMove {
            if opponent.energy >= oppBest.energy && !wouldShield(battle, opponent, poke, oppBest).value && !poke.activeChargedMoves[0].selfBuffing {
                return nil
            }
        }
        if plan[0].selfDebuffing {
            let targetEnergy = (100 / plan[0].energy) * plan[0].energy
            if poke.energy < targetEnergy {
                let moveDamage = DamageCalculator.damage(poke, opponent, plan[0])
                if (opponent.hp > moveDamage || opponent.shields != 0)
                    && (poke.hp > opponent.fastMove.damage * 2 || opponent.fastMove.cooldown - poke.fastMove.cooldown > 500) {
                    return nil
                }
            } else if poke.baitShields != 0 && opponent.shields > 0 && poke.activeChargedMoves[0].energy - plan[0].energy <= 10 && !poke.activeChargedMoves[0].selfDebuffing {
                if poke.activeChargedMoves[0].selfBuffing || wouldShield(battle, poke, opponent, plan[0]).value {
                    plan[0] = poke.activeChargedMoves[0]
                }
            }
        }

        if poke.energy >= plan[0].energy {
            return TimelineAction(type: .charged, actor: poke.index, turn: turns, value: poke.chargedMoveIndex(plan[0]), priority: poke.priority)
        }
        return nil
    }

    // MARK: - Optimal plan (DP)

    private struct Plan { var moves: [BattleMove]; var lastTurn: Int }

    private static func optimalPlan(_ battle: Battle, _ poke: BattlePokemon, _ opponent: BattlePokemon) -> Plan? {
        var stateCount = 0
        var queue: [BattleState] = [BattleState(poke.energy, opponent.hp, 0, opponent.shields, [], 0, 1)]
        var finalStates: [BattleState] = []

        while !queue.isEmpty {
            if stateCount >= 500 { return nil }
            stateCount += 1
            var curr = queue.removeFirst()
            curr.buffs = min(4, max(-4, curr.buffs))

            if curr.oppHealth <= 0 {
                finalStates.append(curr)
                break // chance is always 1 in our deterministic port
            }

            var ready: [Int] = []
            for m in poke.activeChargedMoves {
                if curr.energy >= m.energy { ready.append(0) }
                else { ready.append(Int(ceil(Double(m.energy - curr.energy) / Double(poke.fastMove.energyGain))) * poke.fastMove.turns) }
            }

            for (n, move) in poke.activeChargedMoves.enumerated() {
                // Damage with this state's attack buffs applied.
                let savedBuffs = poke.statBuffs
                poke.applyStatBuffs([curr.buffs, 0])
                let moveDamage = DamageCalculator.damage(poke, opponent, move)
                let fastSimulatedDamage = DamageCalculator.damage(poke, opponent, poke.fastMove)
                poke.statBuffs = savedBuffs

                // Farm-down terminal state (only fast moves to finish).
                let movesToFarmDown = Int(ceil(Double(curr.oppHealth) / Double(fastSimulatedDamage)))
                let farmTurn = curr.turn + movesToFarmDown * poke.fastMove.turns
                let farmState = BattleState(curr.energy + poke.fastMove.energyGain * movesToFarmDown, 0, farmTurn, curr.oppShields, curr.moves, curr.buffs, curr.chance)
                insert(farmState, into: &queue, upToTurn: farmTurn)

                // Attack-buff after move.
                var attackMult = curr.buffs
                if move.buffApplyChance > 0, move.buffTarget == "self", move.buffApplyChance == 1 {
                    attackMult += (move.buffs?.first ?? 0)
                }
                if move.buffApplyChance > 0, move.buffTarget == "opponent", move.buffApplyChance == 1 {
                    attackMult -= (move.buffs?.count ?? 0) > 1 ? (move.buffs?[1] ?? 0) : 0
                }

                if ready[n] == 0 {
                    var newOppHealth = curr.oppHealth - moveDamage
                    if curr.oppShields > 0 { newOppHealth = curr.oppHealth - 1 }
                    var newShields = curr.oppShields
                    if newShields > 0 { newShields -= 1 }
                    let newEnergy = curr.energy - move.energy

                    // Active dedup at the same turn (oppHealth + buffs + energy).
                    if !shouldSkip(queue: queue, atTurn: curr.turn + 1, oppHealth: newOppHealth, buffs: attackMult, energy: newEnergy, currMoves: curr.moves, move: move) {
                        let s = BattleState(newEnergy, newOppHealth, curr.turn + 1, newShields, curr.moves + [move], attackMult, curr.chance)
                        insert(s, into: &queue, beforeTurn: curr.turn + 1)
                    }

                    // Stacking self-attack-debuffing moves.
                    if move.selfDebuffing, (move.buffs?.first ?? 0) < 0, move.energy * 2 <= 100 {
                        var newTurn = Int(ceil(Double(move.energy * 2 - curr.energy) / Double(poke.fastMove.energyGain))) * poke.fastMove.turns
                        let stackEnergy = (newTurn / poke.fastMove.turns) * poke.fastMove.energyGain + curr.energy - move.energy
                        if newTurn != 0 {
                            var h = curr.oppHealth - fastSimulatedDamage * (newTurn / poke.fastMove.turns)
                            h = curr.oppShields > 0 ? h - 1 : h - moveDamage
                            newTurn += curr.turn + 1
                            let s = BattleState(stackEnergy, h, newTurn, newShields, curr.moves + [move], attackMult, curr.chance)
                            insert(s, into: &queue, upToTurn: newTurn)
                        }
                    }
                } else {
                    let newEnergy = curr.energy - move.energy + poke.fastMove.energyGain * (ready[n] / poke.fastMove.turns)
                    var newOppHealth = curr.oppHealth - moveDamage - fastSimulatedDamage * (ready[n] / poke.fastMove.turns)
                    if curr.oppShields > 0 { newOppHealth = curr.oppHealth - fastSimulatedDamage * (ready[n] / poke.fastMove.turns) - 1 }
                    let newTurn = curr.turn + ready[n] + 1
                    var newShields = curr.oppShields
                    if newShields > 0 { newShields -= 1 }
                    let s = BattleState(newEnergy, newOppHealth, newTurn, newShields, curr.moves + [move], attackMult, curr.chance)
                    insert(s, into: &queue, beforeTurn: newTurn)

                    if move.selfDebuffing, (move.buffs?.first ?? 0) < 0, move.energy * 2 <= 100 {
                        var nt = Int(ceil(Double(move.energy * 2 - curr.energy) / Double(poke.fastMove.energyGain))) * poke.fastMove.turns
                        let stackEnergy = (nt / poke.fastMove.turns) * poke.fastMove.energyGain + curr.energy - move.energy
                        var h = curr.oppHealth - fastSimulatedDamage * (nt / poke.fastMove.turns)
                        h = curr.oppShields > 0 ? h - 1 : h - moveDamage
                        nt += curr.turn + 1
                        let s2 = BattleState(stackEnergy, h, nt, newShields, curr.moves + [move], attackMult, curr.chance)
                        insert(s2, into: &queue, upToTurn: nt)
                    }
                }
            }
        }

        guard let final = finalStates.last else { return nil }
        return Plan(moves: final.moves, lastTurn: final.turn)
    }

    /// Insert keeping the queue ordered by turn (insert before the first element with turn > limit).
    private static func insert(_ state: BattleState, into queue: inout [BattleState], upToTurn limit: Int) {
        var i = 0
        while i < queue.count && queue[i].turn <= limit { i += 1 }
        queue.insert(state, at: i)
    }

    private static func insert(_ state: BattleState, into queue: inout [BattleState], beforeTurn limit: Int) {
        var i = 0
        while i < queue.count && queue[i].turn < limit { i += 1 }
        queue.insert(state, at: i)
    }

    /// The one live dominance check: dedup states at the same turn with equal health & buffs.
    private static func shouldSkip(queue: [BattleState], atTurn turn: Int, oppHealth: Int, buffs: Int, energy: Int, currMoves: [BattleMove], move: BattleMove) -> Bool {
        var i = 0
        while i < queue.count && queue[i].turn == turn {
            if queue[i].oppHealth == oppHealth && queue[i].buffs == buffs {
                if queue[i].energy == energy {
                    // Keep the path with fewer net debuffs (Perrserker/Giratina rule); approximate by skipping.
                    return false
                } else {
                    return true
                }
            }
            i += 1
        }
        return false
    }

    // MARK: - Shielding decision

    static func wouldShield(_ battle: Battle, _ attacker: BattlePokemon, _ defender: BattlePokemon, _ move: BattleMove) -> ShieldDecision {
        var useShield = false
        var shieldWeight = 1
        let noShieldWeight = 2
        let damage = DamageCalculator.damage(attacker, defender, move)
        move.damage = damage

        let postMoveHP = defender.hp - damage
        var moveBuffs = [0, 0]
        if let b = move.buffs, b.count >= 2 { moveBuffs = b }

        let savedBuffs: [Int]
        if moveBuffs[0] > 0 {
            savedBuffs = attacker.statBuffs
            attacker.applyStatBuffs(moveBuffs)
        } else {
            savedBuffs = defender.statBuffs
            defender.applyStatBuffs(moveBuffs)
        }

        let fastDamage = DamageCalculator.damage(attacker, defender, attacker.fastMove)
        let fastAttacks = Int(ceil(Double(move.energy - max(attacker.energy - move.energy, 0)) / Double(attacker.fastMove.energyGain))) + 1
        let fastAttackDamage = fastAttacks * fastDamage
        let cycleDamage = (fastAttackDamage + 1) * defender.shields

        if postMoveHP <= cycleDamage { useShield = true; shieldWeight = 2 }

        if moveBuffs[0] > 0 { attacker.statBuffs = savedBuffs } else { defender.statBuffs = savedBuffs }

        let fastDPT = Double(fastDamage) / Double(attacker.fastMove.turns)
        for chargedMove in attacker.chargedMoves {
            let chargedDamage = DamageCalculator.damage(attacker, defender, chargedMove)
            if Double(chargedDamage) >= Double(defender.hp) / 1.4 && fastDPT > 1.5 { useShield = true; shieldWeight = 4 }
            if chargedDamage >= defender.hp - cycleDamage { useShield = true; shieldWeight = 4 }
            if Double(chargedDamage) >= Double(defender.hp) / 2 && fastDPT > 2 { shieldWeight = 12 }
        }

        if move.selfAttackDebuffing && Double(move.damage) / Double(defender.hp) > 0.55 { useShield = true; shieldWeight = 4 }
        if attacker.baitShields == 2 { useShield = true }

        return ShieldDecision(value: useShield, shieldWeight: shieldWeight, noShieldWeight: noShieldWeight)
    }
}

private extension Int {
    nonisolated var isNonZero: Bool { self != 0 }
}
