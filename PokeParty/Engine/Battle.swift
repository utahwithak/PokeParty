//
//  Battle.swift
//  PokeParty
//
//  The 1v1 simulation loop, ported from PvPoke's Battle.js (simulate mode only:
//  no players/teams, switching, sandbox, or emulate).
//

import Foundation

nonisolated final class Battle {
    private(set) var pokemon: [BattlePokemon]
    private(set) var turns = 1
    private(set) var time = 0
    private(set) var queuedActions: [TimelineAction] = []

    private let deltaTime = 500
    private let chargedMinigameTime = 10000
    private var lastProcessedTurn = 0
    private var previousTurnActions: [TimelineAction] = []
    private var turnActions: [TimelineAction] = []
    private var roundChargedMoveUsed = 0
    private var roundShieldUsed = false
    private var usePriority = false
    /// Clock offset the battle starts at. The 3v3 orchestrator passes the elapsed
    /// time so consecutive segments share the single 240s battle limit; defaults to
    /// 0 for standalone 1v1 battles.
    private let startTime: Int

    /// When true, a `BattleFrame` is captured at each key event (for the timeline
    /// viewer). Off by default — keep it off in the analyzer/finder hot loops.
    private let record: Bool
    private var frames: [BattleFrame] = []

    /// M8 shield-search hook. Given (defenderIndex, shieldOpportunityIndex) — the
    /// n-th charged move this defender has faced while holding a shield — return
    /// true = shield, false = don't, nil = use the built-in heuristic. Lets a search
    /// drive shield timing instead of the greedy default.
    var shieldOverride: ((Int, Int) -> Bool?)?
    private var shieldOpportunities = [0, 0]

    /// M8.3(b) mid-battle switch hook. Called after each turn while both Pokémon
    /// are alive; return true to stop the simulation at this point (the 3v3
    /// orchestrator then performs a voluntary switch and continues in a new
    /// segment). `interrupted` reports whether the battle ended this way.
    var interruptCheck: ((Battle) -> Bool)?
    private(set) var interrupted = false

    init(_ a: BattlePokemon, _ b: BattlePokemon, startTime: Int = 0, record: Bool = false) {
        a.index = 0
        b.index = 1
        a.setOpponent(b)
        b.setOpponent(a)
        pokemon = [a, b]
        self.startTime = startTime
        self.record = record
    }

    private func opponent(of i: Int) -> BattlePokemon { pokemon[i == 0 ? 1 : 0] }

    // MARK: - Run

    func simulate() {
        start()
        while pokemon[0].hp > 0 && pokemon[1].hp > 0 && time <= 240000 {
            step()
        }
    }

    private func start() {
        for p in pokemon { p.reset() }
        usePriority = pokemon[0].stats.atk != pokemon[1].stats.atk
        time = startTime
        turns = 1
        lastProcessedTurn = 0
        queuedActions = []
        turnActions = []
        previousTurnActions = []
        shieldOpportunities = [0, 0]
        frames = []
        recordFrame(nil)   // initial full-state frame
    }

    // MARK: - Timeline recording

    private func recordFrame(_ event: BattleEvent?) {
        guard record else { return }
        frames.append(BattleFrame(
            turn: turns, timeMs: time,
            hp: [pokemon[0].hp, pokemon[1].hp],
            energy: [pokemon[0].energy, pokemon[1].energy],
            shields: [pokemon[0].shields, pokemon[1].shields],
            buffs: [pokemon[0].statBuffs, pokemon[1].statBuffs],
            event: event))
    }

    /// The recorded timeline + end-state residuals. Call after `simulate()`.
    /// Only meaningful when the battle was created with `record: true`.
    func makeLog() -> BattleLog {
        BattleLog(
            frames: frames,
            ratingA: battleRating(forIndex: 0), ratingB: battleRating(forIndex: 1),
            hpA: pokemon[0].hp, hpB: pokemon[1].hp,
            energyA: pokemon[0].energy, energyB: pokemon[1].energy,
            shieldsA: pokemon[0].shields, shieldsB: pokemon[1].shields)
    }

    // MARK: - Turn step

    private func step() {
        roundChargedMoveUsed = 0
        roundShieldUsed = false

        if turns > lastProcessedTurn { turnActions = [] }

        for p in pokemon {
            p.cooldown = max(0, p.cooldown - deltaTime)
            if turns > lastProcessedTurn { p.hasActed = false }
        }

        var cooldownsToSet = [pokemon[0].cooldown, pokemon[1].cooldown]

        if turns > lastProcessedTurn {
            for i in 0..<2 {
                let poke = pokemon[i]
                let opp = opponent(of: i)
                guard let action = getTurnAction(poke, opp) else { continue }
                if poke.hp > 0 && opp.hp > 0 {
                    if action.type == .fast { cooldownsToSet[i] += poke.fastMove.cooldown }
                    queuedActions.append(action)
                }
            }
        }

        pokemon[0].cooldown = cooldownsToSet[0]
        pokemon[1].cooldown = cooldownsToSet[1]

        let chargedMoveQueuedThisTurn = queuedActions.contains { $0.type == .charged }

        // Move eligible queued actions into this turn's action list.
        var i = 0
        while i < queuedActions.count {
            let action = queuedActions[i]
            var valid = false
            if action.type == .fast {
                let timeSinceActivated = (turns - action.turn) * 500
                let requiredTimeToPass = pokemon[action.actor].fastMove.cooldown - 500
                if timeSinceActivated >= requiredTimeToPass {
                    action.priority += 20
                    valid = true
                } else if chargedMoveQueuedThisTurn {
                    action.priority -= 20
                    valid = true
                }
            } else {
                valid = true // charged / wait
            }
            if valid {
                turnActions.append(action)
                queuedActions.remove(at: i)
            } else {
                i += 1
            }
        }

        turnActions.sort { $0.priority > $1.priority }

        for action in turnActions {
            let poke = pokemon[action.actor]
            let opp = opponent(of: action.actor)
            switch action.type {
            case .fast:
                action.valid = opp.hp >= 1 && !(poke.hp < 1 && poke.faintSource == .charged)
            case .charged:
                let move = poke.chargedMoves[action.value]
                action.valid = poke.energy >= move.energy
                if usePriority && poke.hp <= 0 && poke.faintSource == .charged { action.valid = false }
                // Prevent a charged move on the same turn a lethal fast move lands.
                var lethalFastMove = false
                var opponentChargedMoveThisTurn = false
                for other in turnActions where other.actor != action.actor {
                    if other.type == .fast {
                        if (opp.cooldown == 0 && poke.hp <= pokemon[other.actor].fastMove.damage) || poke.hp < 1 {
                            lethalFastMove = true
                        }
                    } else if other.type == .charged {
                        opponentChargedMoveThisTurn = true
                    }
                }
                if lethalFastMove && !opponentChargedMoveThisTurn { action.valid = false }
            case .wait:
                action.valid = true
            }
            processAction(action, poke: poke, opponent: opp)
        }

        previousTurnActions = turnActions
        turnActions = []

        if roundChargedMoveUsed == 0 {
            time += deltaTime
        } else if roundShieldUsed {
            time += chargedMinigameTime * (roundChargedMoveUsed - 1)
        } else {
            time += chargedMinigameTime
        }

        lastProcessedTurn = turns
        turns += 1

        // After a charged move, both Pokémon's fast-move cooldowns reset.
        for p in pokemon where roundChargedMoveUsed > 0 { p.cooldown = 0 }
    }

    // MARK: - Action selection

    private func getTurnAction(_ poke: BattlePokemon, _ opponent: BattlePokemon) -> TimelineAction? {
        guard poke.cooldown == 0 && !poke.hasActed else { return nil }
        poke.hasActed = true

        var action = ActionLogic.decideAction(self, poke, opponent)
        if action == nil {
            action = TimelineAction(type: .fast, actor: poke.index, turn: turns, value: 0, priority: poke.priority)
        }
        if let action, action.type == .charged {
            action.priority += 10
            if poke.stats.atk > opponent.stats.atk { action.priority += 1 }
        }
        return action
    }

    private func processAction(_ action: TimelineAction, poke: BattlePokemon, opponent: BattlePokemon) {
        guard action.valid && !action.processed else { return }
        action.processed = true

        switch action.type {
        case .fast:
            useMove(poke, opponent, poke.fastMove)
        case .charged:
            let move = poke.chargedMoves[action.value]
            if poke.energy >= move.energy {
                useMove(poke, opponent, move, forceShield: action.shielded, charge: action.charge)
                roundChargedMoveUsed += 1
            }
        case .wait:
            break
        }
    }

    // MARK: - Apply a move

    private func useMove(_ attacker: BattlePokemon, _ defender: BattlePokemon, _ move: BattleMove, forceShield: Bool = false, charge: Double = 1) {
        var damage = DamageCalculator.damage(attacker, defender, move, charge: charge)
        move.damage = damage
        var defenderUsedShield = false

        if move.energy > 0 {
            attacker.energy -= move.energy
            if usePriority && roundChargedMoveUsed > 0 && !roundShieldUsed { time += chargedMinigameTime }

            if defender.shields > 0 {
                var useShield = true
                let shieldDecision = ActionLogic.wouldShield(self, attacker, defender, move)

                // Don't shield early self-buffing / opponent-debuffing moves.
                if move.buffs != nil, move.selfBuffing {
                    if (move.buffTarget == "self" && (move.buffs?.first ?? 0) > 0)
                        || (move.buffTarget == "opponent" && (move.buffs?.count ?? 0) > 1 && (move.buffs?[1] ?? 0) < 0) {
                        useShield = shieldDecision.value
                    }
                }

                // Don't over-shield against a defender with a self-defense-debuffing move.
                if let dBest = defender.bestChargedMove, dBest.selfDefenseDebuffing {
                    if attacker.shields > 0 {
                        useShield = shieldDecision.value
                    } else if let aBest = attacker.bestChargedMove {
                        let fastToNextCharged = Int(ceil(Double(dBest.energy - defender.energy) / Double(defender.fastMove.energyGain)))
                        let turnsToNextCharged = fastToNextCharged * defender.fastMove.turns
                        let cycleDamage = fastToNextCharged * defender.fastMove.damage + dBest.damage
                        var attackerTurnsToNextCharged = Int(ceil(Double(attacker.activeChargedMoves[0].energy - attacker.energy) / Double(attacker.fastMove.energyGain))) * attacker.fastMove.turns
                        if attacker.stats.atk > defender.stats.atk { attackerTurnsToNextCharged -= 1 }
                        if turnsToNextCharged >= attackerTurnsToNextCharged && attacker.hp <= cycleDamage {
                            useShield = shieldDecision.value
                        }
                        _ = aBest
                    }
                }

                // M8: let an external search force the decision for this shield
                // opportunity, overriding the heuristic above.
                let opportunity = shieldOpportunities[defender.index]
                shieldOpportunities[defender.index] += 1
                if let forced = shieldOverride?(defender.index, opportunity) {
                    useShield = forced
                }

                if useShield {
                    damage = 1
                    defender.shields -= 1
                    roundShieldUsed = true
                    defenderUsedShield = true
                    if roundChargedMoveUsed == 0 { time += chargedMinigameTime }
                }
            }

            // Mimikyu's Disguise blocks the first charged move (a free, one-time shield).
            if !defenderUsedShield && defender.disguiseActive {
                damage = 1
                defender.disguiseActive = false
                roundShieldUsed = true
                if roundChargedMoveUsed == 0 { time += chargedMinigameTime }
            }
        } else {
            attacker.energy = min(100, attacker.energy + move.energyGain)
        }

        defender.hp = max(0, defender.hp - damage)
        if defender.hp <= 0 { defender.faintSource = move.energy > 0 ? .charged : .fast }

        applyBuffs(move, attacker: attacker, defender: defender, shielded: defenderUsedShield)

        if record {
            recordFrame(BattleEvent(
                actor: attacker.index,
                kind: move.energy > 0 ? .charged : .fast,
                moveId: move.moveId, damage: damage, shielded: defenderUsedShield))
            if defender.hp <= 0 {
                recordFrame(BattleEvent(
                    actor: defender.index, kind: .faint,
                    moveId: nil, damage: nil, shielded: false))
            }
        }
    }

    /// Deterministic buff application (guaranteed buffs always apply; probabilistic
    /// buffs accumulate via a meter, matching PvPoke's `buffChanceModifier == -1` mode).
    private func applyBuffs(_ move: BattleMove, attacker: BattlePokemon, defender: BattlePokemon, shielded: Bool) {
        guard let buffs = move.buffs else { return }

        var apply = false
        if move.buffApplyChance >= 1 {
            apply = true
        } else if move.buffApplyChance > 0 {
            let startCount = floor(move.buffApplyMeter)
            move.buffApplyMeter += move.buffApplyChance
            if floor(move.buffApplyMeter) > startCount { apply = true }
        }
        guard apply else { return }

        switch move.buffTarget {
        case "self":
            attacker.applyStatBuffs(buffs)
        case "opponent":
            if !shielded { defender.applyStatBuffs(buffs) } // shielding negates opponent debuffs
        case "both":
            attacker.applyStatBuffs(buffs)
        default:
            break
        }
    }

    // MARK: - Result

    /// PvPoke's battle rating for `pokemon[index]` (0–1000, 500 = even).
    func battleRating(forIndex index: Int) -> Int {
        let me = pokemon[index]
        let opp = opponent(of: index)
        let healthRating = Double(me.hp) / Double(me.stats.hp)
        let damageRating = Double(opp.stats.hp - opp.hp) / Double(opp.stats.hp)
        return Int(((healthRating + damageRating) * 500).rounded(.down))
    }
}
