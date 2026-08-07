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
    /// How many shield opportunities each side has faced (readable after
    /// `simulate()` — ShieldSearch uses it to dedupe equivalent policies).
    private(set) var shieldOpportunities = [0, 0]

    /// RL/data-collection hook: called at every shield opportunity, after the
    /// decision is final, with (defenderIndex, opportunityIndex, incoming move,
    /// decision). Note: the attacker's energy has already been debited for the
    /// move when this fires (observers should add `move.energy` back to see the
    /// pre-throw value).
    var shieldDecisionObserver: ((Int, Int, BattleMove, Bool) -> Void)?

    /// Learned shield policy hook (RL milestone 1): like `shieldOverride` but also
    /// receives the incoming move so the policy can build its observation.
    /// Consulted only when `shieldOverride` doesn't force the decision;
    /// nil = fall through to the built-in heuristic.
    var shieldPolicy: ((Int, Int, BattleMove) -> Bool?)?

    /// M8.3(b) mid-battle switch hook. Called after each turn while both Pokémon
    /// are alive; return true to stop the simulation at this point (the 3v3
    /// orchestrator then performs a voluntary switch and continues in a new
    /// segment). `interrupted` reports whether the battle ended this way.
    var interruptCheck: ((Battle) -> Bool)?
    private(set) var interrupted = false

    init(_ a: BattlePokemon, _ b: BattlePokemon, startTime: Int = 0, record: Bool = false) {
        var a = a
        var b = b
        a.index = 0
        b.index = 1
        pokemon = [a, b]
        self.startTime = startTime
        self.record = record
    }

    // MARK: - Run

    func simulate() {
        start()
        while pokemon[0].hp > 0 && pokemon[1].hp > 0 && time <= 240000 {
            step()
            if let interruptCheck, pokemon[0].hp > 0, pokemon[1].hp > 0, interruptCheck(self) {
                interrupted = true
                break
            }
        }
    }

    private func start() {
        interrupted = false
        pokemon[0].reset(opponent: pokemon[1])
        pokemon[1].reset(opponent: pokemon[0])
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

        for i in pokemon.indices {
            pokemon[i].cooldown = max(0, pokemon[i].cooldown - deltaTime)
            if turns > lastProcessedTurn { pokemon[i].hasActed = false }
        }

        var cooldownsToSet = [pokemon[0].cooldown, pokemon[1].cooldown]

        if turns > lastProcessedTurn {
            for i in 0..<2 {
                guard let action = getTurnAction(i) else { continue }
                let di = i == 0 ? 1 : 0
                if pokemon[i].hp > 0 && pokemon[di].hp > 0 {
                    if action.type == .fast { cooldownsToSet[i] += pokemon[i].fastMove.cooldown }
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
            let ai = action.actor
            let di = ai == 0 ? 1 : 0
            switch action.type {
            case .fast:
                action.valid = pokemon[di].hp >= 1 && !(pokemon[ai].hp < 1 && pokemon[ai].faintSource == .charged)
            case .charged:
                let move = pokemon[ai].chargedMoves[action.value]
                action.valid = pokemon[ai].energy >= move.energy
                if usePriority && pokemon[ai].hp <= 0 && pokemon[ai].faintSource == .charged { action.valid = false }
                // Prevent a charged move on the same turn a lethal fast move lands.
                var lethalFastMove = false
                var opponentChargedMoveThisTurn = false
                for other in turnActions where other.actor != action.actor {
                    if other.type == .fast {
                        if (pokemon[di].cooldown == 0 && pokemon[ai].hp <= pokemon[di].fastMove.damage) || pokemon[ai].hp < 1 {
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
            processAction(action)
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
        if roundChargedMoveUsed > 0 {
            pokemon[0].cooldown = 0
            pokemon[1].cooldown = 0
        }
    }

    // MARK: - Action selection

    private func getTurnAction(_ i: Int) -> TimelineAction? {
        guard pokemon[i].cooldown == 0 && !pokemon[i].hasActed else { return nil }
        pokemon[i].hasActed = true

        let di = i == 0 ? 1 : 0
        var action = ActionLogic.decideAction(self, pokemon[i], pokemon[di])
        if action == nil {
            action = TimelineAction(type: .fast, actor: i, turn: turns, value: 0, priority: pokemon[i].priority)
        }
        if let action, action.type == .charged {
            action.priority += 10
            if pokemon[i].stats.atk > pokemon[di].stats.atk { action.priority += 1 }
        }
        return action
    }

    private func processAction(_ action: TimelineAction) {
        guard action.valid && !action.processed else { return }
        action.processed = true

        let ai = action.actor
        let di = ai == 0 ? 1 : 0

        switch action.type {
        case .fast:
            useMove(ai: ai, di: di, move: pokemon[ai].fastMove, chargedIdx: nil)
        case .charged:
            let move = pokemon[ai].chargedMoves[action.value]
            if pokemon[ai].energy >= move.energy {
                useMove(ai: ai, di: di, move: move, chargedIdx: action.value)
                roundChargedMoveUsed += 1
            }
        case .wait:
            break
        }
    }

    // MARK: - Apply a move

    private func useMove(ai: Int, di: Int, move: BattleMove, chargedIdx: Int?) {
        var damage = DamageCalculator.damage(pokemon[ai], pokemon[di], move)
        // Write the computed damage back to the move's scratch field.
        if let chargedIdx {
            pokemon[ai].chargedMoves[chargedIdx].damage = damage
        } else {
            pokemon[ai].fastMove.damage = damage
        }
        var defenderUsedShield = false

        if move.energy > 0 {
            pokemon[ai].energy -= move.energy
            if usePriority && roundChargedMoveUsed > 0 && !roundShieldUsed { time += chargedMinigameTime }

            if pokemon[di].shields > 0 {
                var useShield = true
                let shieldDecision = ActionLogic.wouldShield(self, pokemon[ai], pokemon[di], move)

                // Don't shield early self-buffing / opponent-debuffing moves.
                if move.buffs != nil, move.selfBuffing {
                    if (move.buffTarget == "self" && (move.buffs?.first ?? 0) > 0)
                        || (move.buffTarget == "opponent" && (move.buffs?.count ?? 0) > 1 && (move.buffs?[1] ?? 0) < 0) {
                        useShield = shieldDecision.value
                    }
                }

                // Don't over-shield against a defender with a self-defense-debuffing move.
                if let dBest = pokemon[di].bestChargedMove, dBest.selfDefenseDebuffing {
                    if pokemon[ai].shields > 0 {
                        useShield = shieldDecision.value
                    } else if pokemon[ai].bestChargedMove != nil {
                        let fastToNextCharged = Int(ceil(Double(dBest.energy - pokemon[di].energy) / Double(pokemon[di].fastMove.energyGain)))
                        let turnsToNextCharged = fastToNextCharged * pokemon[di].fastMove.turns
                        let cycleDamage = fastToNextCharged * pokemon[di].fastMove.damage + dBest.damage
                        var attackerTurnsToNextCharged = Int(ceil(Double(pokemon[ai].activeChargedMoves[0].energy - pokemon[ai].energy) / Double(pokemon[ai].fastMove.energyGain))) * pokemon[ai].fastMove.turns
                        if pokemon[ai].stats.atk > pokemon[di].stats.atk { attackerTurnsToNextCharged -= 1 }
                        if turnsToNextCharged >= attackerTurnsToNextCharged && pokemon[di].hp <= cycleDamage {
                            useShield = shieldDecision.value
                        }
                    }
                }

                // M8: let an external search force the decision for this shield
                // opportunity, overriding the heuristic above.
                let opportunity = shieldOpportunities[di]
                shieldOpportunities[di] += 1
                if let forced = shieldOverride?(di, opportunity) {
                    useShield = forced
                } else if let learned = shieldPolicy?(di, opportunity, move) {
                    useShield = learned
                }

                shieldDecisionObserver?(di, opportunity, move, useShield)

                if useShield {
                    damage = 1
                    pokemon[di].shields -= 1
                    roundShieldUsed = true
                    defenderUsedShield = true
                    if roundChargedMoveUsed == 0 { time += chargedMinigameTime }
                }
            }

            // Mimikyu's Disguise blocks the first charged move (a free, one-time
            // shield), but busting it drops Mimikyu's Defense one stage for the
            // rest of the match (PvPoke's "Busted" form; carries across switches).
            if !defenderUsedShield && pokemon[di].disguiseActive {
                damage = 1
                pokemon[di].disguiseActive = false
                pokemon[di].statBuffs[1] = max(pokemon[di].statBuffs[1] - 1, -4)
                roundShieldUsed = true
                if roundChargedMoveUsed == 0 { time += chargedMinigameTime }
            }
        } else {
            pokemon[ai].energy = min(100, pokemon[ai].energy + move.energyGain)
        }

        pokemon[di].hp = max(0, pokemon[di].hp - damage)
        if pokemon[di].hp <= 0 { pokemon[di].faintSource = move.energy > 0 ? .charged : .fast }

        applyBuffs(move, ai: ai, di: di, shielded: defenderUsedShield, chargedIdx: chargedIdx)

        if record {
            recordFrame(BattleEvent(
                actor: ai,
                kind: move.energy > 0 ? .charged : .fast,
                moveId: move.moveId, damage: damage, shielded: defenderUsedShield))
            if pokemon[di].hp <= 0 {
                recordFrame(BattleEvent(
                    actor: di, kind: .faint,
                    moveId: nil, damage: nil, shielded: false))
            }
        }
    }

    /// Deterministic buff application (guaranteed buffs always apply; probabilistic
    /// buffs accumulate via a meter, matching PvPoke's `buffChanceModifier == -1` mode).
    private func applyBuffs(_ move: BattleMove, ai: Int, di: Int, shielded: Bool, chargedIdx: Int?) {
        guard let buffs = move.buffs else { return }

        var apply = false
        if move.buffApplyChance >= 1 {
            apply = true
        } else if move.buffApplyChance > 0 {
            // Write buffApplyMeter back through the owning array so it persists.
            if let chargedIdx {
                let startCount = floor(pokemon[ai].chargedMoves[chargedIdx].buffApplyMeter)
                pokemon[ai].chargedMoves[chargedIdx].buffApplyMeter += move.buffApplyChance
                if floor(pokemon[ai].chargedMoves[chargedIdx].buffApplyMeter) > startCount { apply = true }
            } else {
                let startCount = floor(pokemon[ai].fastMove.buffApplyMeter)
                pokemon[ai].fastMove.buffApplyMeter += move.buffApplyChance
                if floor(pokemon[ai].fastMove.buffApplyMeter) > startCount { apply = true }
            }
        }
        guard apply else { return }

        switch move.buffTarget {
        case "self":
            pokemon[ai].applyStatBuffs(buffs)
        case "opponent":
            if !shielded { pokemon[di].applyStatBuffs(buffs) } // shielding negates opponent debuffs
        case "both":
            pokemon[ai].applyStatBuffs(buffs)
        default:
            break
        }
    }

    // MARK: - Result

    /// PvPoke's battle rating for `pokemon[index]` (0–1000, 500 = even).
    func battleRating(forIndex index: Int) -> Int {
        let me = pokemon[index]
        let opp = pokemon[index == 0 ? 1 : 0]
        let healthRating = Double(me.hp) / Double(me.stats.hp)
        let damageRating = Double(opp.stats.hp - opp.hp) / Double(opp.stats.hp)
        return Int(((healthRating + damageRating) * 500).rounded(.down))
    }
}
