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
/// Uses parent-pointer path tracking instead of copying a moves array per state.
private nonisolated struct BattleState {
    var energy: Int
    var oppHealth: Int
    var turn: Int
    var oppShields: Int
    var parentIdx: Int  // index into allStates; -1 at root
    var moveIdx: Int    // index into activeChargedMoves; -1 = no charged move (root/farm)
    var buffs: Int
    init(_ energy: Int, _ oppHealth: Int, _ turn: Int, _ oppShields: Int,
         _ parentIdx: Int, _ moveIdx: Int, _ buffs: Int) {
        self.energy = energy; self.oppHealth = oppHealth; self.turn = turn
        self.oppShields = oppShields; self.parentIdx = parentIdx; self.moveIdx = moveIdx; self.buffs = buffs
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
        guard let fastestChargedMove = poke.fastestChargedMove else { return nil }
        if poke.energy < fastestChargedMove.energy || poke.farmEnergy { return nil }

        var chargedMoveReady: [Int] = []
        for m in poke.activeChargedMoves {
            if poke.energy >= m.energy {
                chargedMoveReady.append(0)
            } else {
                chargedMoveReady.append(Int(ceil(Double(m.energy - poke.energy) / Double(poke.fastMove.energyGain))) * poke.fastMove.turns)
            }
        }

        // MARK: Survival lookahead — how many turns until the opponent can KO us.
        var turnsToLive = infinity
        struct SurvState { var hp: Int; var opEnergy: Int; var turn: Int; var shields: Int }
        let opponentFastest = opponent.fastestChargedMove
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
                if let opFastest = opponentFastest, curr.opEnergy >= opFastest.energy {
                    stack.append(SurvState(hp: curr.hp - 1, opEnergy: curr.opEnergy - opFastest.energy, turn: curr.turn + 1, shields: curr.shields - 1))
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
                for n in stride(from: poke.activeChargedMoves.count - 1, through: 0, by: -1)
                where chargedMoveReady[n] == 0 {
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
            if poke.energy >= fastestChargedMove.energy && !fastestChargedMove.selfDebuffing {
                return TimelineAction(type: .charged, actor: poke.index, turn: turns,
                                      value: poke.chargedMoveIndex(fastestChargedMove), priority: poke.priority)
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
                        let dmg = DamageCalculator.damage(poke, opponent, m)
                        if poke.energy >= m.energy && dmg >= opponent.hp { optimizeTiming = false; break }
                    }
                }

                for m in opponent.activeChargedMoves {
                    let fastMovesFromCharged = Int(ceil(Double(m.energy - opponent.energy) / Double(opponent.fastMove.energyGain)))
                    let fastMovesInFastMove = poke.fastMove.cooldown / opponent.fastMove.cooldown
                    let turnsFromMove = fastMovesFromCharged * opponent.fastMove.turns + 1
                    let mDamage = DamageCalculator.damage(opponent, poke, m)
                    var moveDamage = mDamage + opponent.fastMove.damage * fastMovesInFastMove
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
        if bestMove.selfDebuffing && bestMove.energy > fastestChargedMove.energy && bestMove.dpe / fastestChargedMove.dpe < 2 {
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
        guard var plan = optimalPlan(battle, poke, opponent) else { return nil }
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
        if poke.baitShields == 0 || (opponent.shields == 0 && !debuffingMove) {
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

        // The DP assumes the opponent shields every charged move, so it often
        // picks the cheapest move first to cycle faster. But a bait only works
        // when the opponent actually shields the bait move. If the opponent
        // wouldn't shield plan[0] and a better move is available, lead with the
        // best move instead so the opponent is forced to spend their shield on it.
        if opponent.shields > 0, poke.activeChargedMoves.count > 1,
           let bestMove = poke.bestChargedMove,
           plan[0].moveId != bestMove.moveId,
           !wouldShield(battle, poke, opponent, plan[0]).value {
            plan[0] = bestMove
        }

        if poke.energy >= plan[0].energy {
            return TimelineAction(type: .charged, actor: poke.index, turn: turns, value: poke.chargedMoveIndex(plan[0]), priority: poke.priority)
        }
        return nil
    }

    // MARK: - Optimal plan (DP)

    /// The optimal charged-move sequence, or nil if no KO plan was found.
    private static func optimalPlan(_ battle: Battle, _ poke: BattlePokemon, _ opponent: BattlePokemon) -> [BattleMove]? {
        var stateCount = 0
        // Flat pool of all states ever created; queue holds indices into this array.
        // Parent-pointer path tracking eliminates per-state array copies.
        var allStates: [BattleState] = [BattleState(poke.energy, opponent.hp, 0, opponent.shields, -1, -1, 0)]
        var queue: [Int] = [0]
        var finalIdx = -1

        while !queue.isEmpty {
            if stateCount >= 500 { return nil }
            stateCount += 1
            let currIdx = queue.removeFirst()
            var curr = allStates[currIdx]
            curr.buffs = min(4, max(-4, curr.buffs))
            allStates[currIdx] = curr

            if curr.oppHealth <= 0 {
                finalIdx = currIdx
                break // chance is always 1 in our deterministic port
            }

            var ready: [Int] = []
            for m in poke.activeChargedMoves {
                if curr.energy >= m.energy { ready.append(0) }
                else { ready.append(Int(ceil(Double(m.energy - curr.energy) / Double(poke.fastMove.energyGain))) * poke.fastMove.turns) }
            }

            for (n, move) in poke.activeChargedMoves.enumerated() {
                // Damage with this state's attack buffs applied — no BattlePokemon copy needed.
                let moveDamage = DamageCalculator.damage(poke, opponent, move, atkBuff: curr.buffs)
                let fastSimulatedDamage = DamageCalculator.damage(poke, opponent, poke.fastMove, atkBuff: curr.buffs)

                // Farm-down terminal state (only fast moves to finish).
                let movesToFarmDown = Int(ceil(Double(curr.oppHealth) / Double(fastSimulatedDamage)))
                let farmTurn = curr.turn + movesToFarmDown * poke.fastMove.turns
                let farmState = BattleState(curr.energy + poke.fastMove.energyGain * movesToFarmDown, 0, farmTurn, curr.oppShields, currIdx, -1, curr.buffs)
                insertState(farmState, into: &queue, allStates: &allStates, upToTurn: farmTurn)

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
                    if !shouldSkip(queue: queue, allStates: allStates, atTurn: curr.turn + 1, oppHealth: newOppHealth, buffs: attackMult, energy: newEnergy) {
                        let s = BattleState(newEnergy, newOppHealth, curr.turn + 1, newShields, currIdx, n, attackMult)
                        insertState(s, into: &queue, allStates: &allStates, beforeTurn: curr.turn + 1)
                    }

                    // Stacking self-attack-debuffing moves.
                    if move.selfDebuffing, (move.buffs?.first ?? 0) < 0, move.energy * 2 <= 100 {
                        var newTurn = Int(ceil(Double(move.energy * 2 - curr.energy) / Double(poke.fastMove.energyGain))) * poke.fastMove.turns
                        let stackEnergy = (newTurn / poke.fastMove.turns) * poke.fastMove.energyGain + curr.energy - move.energy
                        if newTurn != 0 {
                            var h = curr.oppHealth - fastSimulatedDamage * (newTurn / poke.fastMove.turns)
                            h = curr.oppShields > 0 ? h - 1 : h - moveDamage
                            newTurn += curr.turn + 1
                            let s = BattleState(stackEnergy, h, newTurn, newShields, currIdx, n, attackMult)
                            insertState(s, into: &queue, allStates: &allStates, upToTurn: newTurn)
                        }
                    }
                } else {
                    let newEnergy = curr.energy - move.energy + poke.fastMove.energyGain * (ready[n] / poke.fastMove.turns)
                    var newOppHealth = curr.oppHealth - moveDamage - fastSimulatedDamage * (ready[n] / poke.fastMove.turns)
                    if curr.oppShields > 0 { newOppHealth = curr.oppHealth - fastSimulatedDamage * (ready[n] / poke.fastMove.turns) - 1 }
                    let newTurn = curr.turn + ready[n] + 1
                    var newShields = curr.oppShields
                    if newShields > 0 { newShields -= 1 }
                    let s = BattleState(newEnergy, newOppHealth, newTurn, newShields, currIdx, n, attackMult)
                    insertState(s, into: &queue, allStates: &allStates, beforeTurn: newTurn)

                    if move.selfDebuffing, (move.buffs?.first ?? 0) < 0, move.energy * 2 <= 100 {
                        var nt = Int(ceil(Double(move.energy * 2 - curr.energy) / Double(poke.fastMove.energyGain))) * poke.fastMove.turns
                        let stackEnergy = (nt / poke.fastMove.turns) * poke.fastMove.energyGain + curr.energy - move.energy
                        var h = curr.oppHealth - fastSimulatedDamage * (nt / poke.fastMove.turns)
                        h = curr.oppShields > 0 ? h - 1 : h - moveDamage
                        nt += curr.turn + 1
                        let s2 = BattleState(stackEnergy, h, nt, newShields, currIdx, n, attackMult)
                        insertState(s2, into: &queue, allStates: &allStates, upToTurn: nt)
                    }
                }
            }
        }

        guard finalIdx >= 0 else { return nil }
        // Reconstruct the move sequence by walking parent pointers — O(depth), no copies.
        var moves: [BattleMove] = []
        var idx = finalIdx
        while idx >= 0 {
            let mi = allStates[idx].moveIdx
            if mi >= 0 { moves.append(poke.activeChargedMoves[mi]) }
            idx = allStates[idx].parentIdx
        }
        moves.reverse()
        return moves
    }

    /// Appends state to allStates and inserts its index into the turn-ordered queue (≤ limit).
    private static func insertState(_ state: BattleState, into queue: inout [Int], allStates: inout [BattleState], upToTurn limit: Int) {
        let newIdx = allStates.count
        allStates.append(state)
        var i = 0
        while i < queue.count && allStates[queue[i]].turn <= limit { i += 1 }
        queue.insert(newIdx, at: i)
    }

    private static func insertState(_ state: BattleState, into queue: inout [Int], allStates: inout [BattleState], beforeTurn limit: Int) {
        let newIdx = allStates.count
        allStates.append(state)
        var i = 0
        while i < queue.count && allStates[queue[i]].turn < limit { i += 1 }
        queue.insert(newIdx, at: i)
    }

    /// Dedup states at the same turn with equal health, buffs, and energy.
    private static func shouldSkip(queue: [Int], allStates: [BattleState], atTurn turn: Int, oppHealth: Int, buffs: Int, energy: Int) -> Bool {
        var i = 0
        while i < queue.count && allStates[queue[i]].turn == turn {
            let s = allStates[queue[i]]
            if s.oppHealth == oppHealth && s.buffs == buffs {
                if s.energy == energy {
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
        var attacker = attacker
        var defender = defender
        var move = move
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
