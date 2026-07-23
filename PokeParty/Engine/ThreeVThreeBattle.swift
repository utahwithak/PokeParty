//
//  ThreeVThreeBattle.swift
//  PokeParty
//
//  Milestone 2 of the 3v3 work (see docs/TeamBuilder-Plan.md §4). A true team
//  battle between two full teams, built on top of the existing 1v1 `Battle`
//  engine: it runs consecutive 1v1 segments and carries each Pokémon's HP,
//  energy, shields and stat buffs across faints, sharing one 240s clock.
//
//  Scope (M2 base + M8.3 switching refinements):
//   - Leads are specified by the caller (the finder will enumerate lead combos).
//   - Shields are a per-team pool (default 2) shared across a team's Pokémon.
//   - Switching on faint picks the next in team order or the best matchup.
//   - With `voluntarySwitching`: turn-0 safe swaps, counterswaps punishing a
//     switch-locked opponent, mid-segment escapes from a losing matchup the
//     moment the switch timer allows (via `Battle.interruptCheck`), catch swaps
//     that answer an expected super-effective charged move with a resist, and
//     sac swaps that spend a nearly-fainted mon as one more shield.
//   - Each segment plays out as an optimal 1v1 via the existing `ActionLogic` AI.
//

import Foundation

/// The outcome of a 3v3 team battle, from Team A's perspective where noted.
nonisolated struct TeamBattleResult: Hashable {
    enum Winner: Hashable { case teamA, teamB, tie }

    let winner: Winner
    /// Pokémon still standing on each team at the end.
    let survivorsA: Int
    let survivorsB: Int
    /// Total remaining HP as a fraction of max, summed over surviving Pokémon
    /// (0…teamSize). A rough "how much did the winner have left" measure.
    let hpRemainingA: Double
    let hpRemainingB: Double
    /// Shields left in each team's pool.
    let shieldsA: Int
    let shieldsB: Int
    /// Resource margin from A's perspective, 0…1000 (500 = even).
    let ratingA: Int
    /// True if the battle hit the 240s limit with both teams still alive.
    let timedOut: Bool
    /// The order Pokémon entered the field (team indices), for a simple timeline.
    let entrancesA: [Int]
    let entrancesB: [Int]
}

/// A recorded 3v3 battle: one `BattleLog` per 1v1 segment (with the team indices
/// that were active) plus the overall result (plan M7.4).
nonisolated struct TeamBattleLog: Sendable, Hashable {
    struct Segment: Sendable, Hashable {
        let indexA: Int          // team A Pokémon active this segment
        let indexB: Int          // team B Pokémon active this segment
        let log: BattleLog
        /// Shield-scenario distribution for this segment (when optimal shields were used).
        let shieldScenario: ShieldSearch.Solution?
    }
    let segments: [Segment]
    let result: TeamBattleResult
}

nonisolated struct ThreeVThreeBattle {
    /// How a team picks its next Pokémon after one faints.
    enum SwitchPolicy: Sendable {
        /// Next non-fainted Pokémon in team order (cheap, deterministic).
        case teamOrder
        /// The alive teammate that scores best in a quick 1v1 against the
        /// opponent's current state (more realistic; runs throwaway sims).
        case bestMatchup
    }

    let teamA: [BattlePokemon]
    let teamB: [BattlePokemon]
    var leadA: Int
    var leadB: Int
    var shieldsA: Int
    var shieldsB: Int
    var switchPolicy: SwitchPolicy
    /// Search the optimal shield play for each 1v1 segment (both sides) instead of
    /// the engine's greedy default. Information-legitimate — shields are decided for
    /// the currently-revealed matchup only.
    var optimalShields: Bool
    /// Allow reactive, revealed-info-only voluntary switching at segment boundaries
    /// (turn-0 safe-swap, counter-switch when the opponent reveals a new mon, a
    /// counterswap punishing an opponent locked by its own voluntary switch, catch
    /// swaps onto a resist when the opponent has banked energy for a super-effective
    /// charged move, and sac swaps that use a nearly-fainted mon as an extra shield).
    /// The switch timer prevents thrashing. Off by default (M8.3).
    var voluntarySwitching: Bool

    private let battleTimeLimit = 240_000
    /// GBL switch cooldown: after a voluntary switch a side can't switch again for
    /// this long (battle-ms). (Live-game value is often cited as 60s; set to 30s per
    /// project spec — one constant to change.)
    private static let switchTimerMs = 30_000
    /// A backup must beat the current active by at least this rating to be worth a
    /// voluntary switch (hysteresis to avoid marginal flip-flopping).
    private static let switchHysteresis = 75
    /// A counter-switch (into an opponent that just switched and is now locked) must
    /// reach at least this rating: it spends our own switch clock even though the
    /// target can't escape, so only a dominant answer is worth it.
    private static let counterSwitchDominance = 650
    /// Tempo cost of switching: the side that stays gets this many free fast moves of
    /// energy while the other spends its turn switching.
    private static let switchTempoFastMoves = 3
    /// A catch swap must bring in a backup that beats this rating — dodging one
    /// super-effective move isn't worth 30s locked into a losing matchup.
    private static let catchMinRating = 475
    /// A backup at or below this fraction of its max HP counts as sac material
    /// (worth spending as a pseudo-shield).
    private static let sacMaxHpFraction = 0.25
    /// A sac swap needs the expected charged move to threaten at least this fraction
    /// of the active mon's remaining HP — smaller hits aren't worth a switch clock.
    private static let sacDangerFraction = 0.5

    init(teamA: [BattlePokemon], teamB: [BattlePokemon],
         leadA: Int = 0, leadB: Int = 0, shieldsA: Int = 2, shieldsB: Int = 2,
         switchPolicy: SwitchPolicy = .bestMatchup, optimalShields: Bool = true,
         voluntarySwitching: Bool = false) {
        self.teamA = teamA
        self.teamB = teamB
        self.leadA = leadA
        self.leadB = leadB
        self.shieldsA = shieldsA
        self.shieldsB = shieldsB
        self.switchPolicy = switchPolicy
        self.optimalShields = optimalShields
        self.voluntarySwitching = voluntarySwitching
    }

    /// Runs the full team battle. Mutates the passed `BattlePokemon` objects, so
    /// pass freshly-built teams (see `makeTeam`).
    func run() -> TeamBattleResult { simulateCore(record: false).result }

    /// Runs and records each 1v1 segment for the timeline viewer (M7.4/M7.5).
    func runRecorded() -> TeamBattleLog {
        let out = simulateCore(record: true)
        return TeamBattleLog(segments: out.segments, result: out.result)
    }

    private func simulateCore(record: Bool) -> (result: TeamBattleResult, segments: [TeamBattleLog.Segment]) {
        var segments: [TeamBattleLog.Segment] = []
        // Every Pokémon starts fresh; the loop updates start* to carry state.
        for p in teamA + teamB {
            p.startHp = 0
            p.startEnergy = 0
            p.startStatBuffs = [0, 0]
            p.startDisguiseConsumed = false
        }

        var teamAShields = shieldsA
        var teamBShields = shieldsB
        var faintedA = Set<Int>()
        var faintedB = Set<Int>()
        var activeA = min(max(leadA, 0), teamA.count - 1)
        var activeB = min(max(leadB, 0), teamB.count - 1)
        var entrancesA = [activeA]
        var entrancesB = [activeB]
        var globalTime = 0
        var timedOut = false
        // Time of each side's last voluntary switch (for the switch timer). Start
        // off-cooldown so a turn-0 safe-swap is allowed.
        var lastSwitchA = -Self.switchTimerMs
        var lastSwitchB = -Self.switchTimerMs

        // Safety bound: at most (all Pokémon faint) + 1 faint-ended segments, plus —
        // with voluntary switching — one interrupt-ended segment per switch-timer
        // window per side, plus the energy-triggered (catch/sac) interrupts. Each of
        // those needs the opponent to re-bank a charged move's cost, so they're
        // bounded by total energy income over the clock; the /1500 term covers it.
        let maxSegments = teamA.count + teamB.count + 1
            + (voluntarySwitching ? 2 * (battleTimeLimit / Self.switchTimerMs) + battleTimeLimit / 1500 : 0)
        var segment = 0

        while segment < maxSegments {
            segment += 1

            // Voluntary switching at the boundary (turn-0 safe-swap + counter-switch
            // vs the revealed opponent). Both sides decide simultaneously from the
            // current on-field mons; the switch timer prevents thrashing.
            if voluntarySwitching {
                let aCanSwitch = globalTime - lastSwitchA >= Self.switchTimerMs
                let bCanSwitch = globalTime - lastSwitchB >= Self.switchTimerMs
                let aTarget = aCanSwitch ? boundarySwitchTarget(
                    team: teamA, fainted: faintedA, active: activeA,
                    opponent: teamB[activeB], teamShields: teamAShields, opponentShields: teamBShields) : nil
                let bTarget = bCanSwitch ? boundarySwitchTarget(
                    team: teamB, fainted: faintedB, active: activeB,
                    opponent: teamA[activeA], teamShields: teamBShields, opponentShields: teamAShields) : nil
                if let aTarget { activeA = aTarget; lastSwitchA = globalTime; entrancesA.append(aTarget) }
                if let bTarget { activeB = bTarget; lastSwitchB = globalTime; entrancesB.append(bTarget) }
                var aSwitched = aTarget != nil
                var bSwitched = bTarget != nil
                // Counterswap: a side that just switched is locked for the switch
                // timer, so the other side (if off cooldown) re-evaluates against the
                // newly revealed mon and may punish with a dominant answer the locked
                // mon can't escape. (Approximates deciding a turn or two in.)
                if aSwitched != bSwitched {
                    if aSwitched, bCanSwitch, let c = counterSwitchTarget(
                        team: teamB, fainted: faintedB, active: activeB,
                        opponent: teamA[activeA], teamShields: teamBShields, opponentShields: teamAShields) {
                        activeB = c; lastSwitchB = globalTime; entrancesB.append(c); bSwitched = true
                    } else if bSwitched, aCanSwitch, let c = counterSwitchTarget(
                        team: teamA, fainted: faintedA, active: activeA,
                        opponent: teamB[activeB], teamShields: teamAShields, opponentShields: teamBShields) {
                        activeA = c; lastSwitchA = globalTime; entrancesA.append(c); aSwitched = true
                    }
                }
                // Tempo cost: if exactly one side switched, the other gets free energy.
                if aSwitched != bSwitched {
                    let stayer = aSwitched ? teamB[activeB] : teamA[activeA]
                    stayer.startEnergy = min(100, stayer.startEnergy + stayer.fastMove.energyGain * Self.switchTempoFastMoves)
                }
            }

            let a = teamA[activeA]
            let b = teamB[activeB]
            a.startingShields = teamAShields
            b.startingShields = teamBShields

            let battle = Battle(a, b, startTime: globalTime, record: record)
            // Mid-segment escape (M8.3b): a side that enters this segment stuck in a
            // losing matchup because its switch timer is still running gets the
            // segment stopped the moment the timer expires, so the boundary logic
            // above can offer it a voluntary switch. A side already off cooldown
            // never arms this — it just declined a switch at this boundary.
            if voluntarySwitching {
                var interruptAt = Int.max
                let aUnlock = lastSwitchA + Self.switchTimerMs
                if aUnlock > globalTime, Self.hasBackup(count: teamA.count, fainted: faintedA, active: activeA),
                   rate(a, vs: b, myShields: teamAShields, oppShields: teamBShields, fresh: false) < 500 {
                    interruptAt = min(interruptAt, aUnlock)
                }
                let bUnlock = lastSwitchB + Self.switchTimerMs
                if bUnlock > globalTime, Self.hasBackup(count: teamB.count, fainted: faintedB, active: activeB),
                   rate(b, vs: a, myShields: teamBShields, oppShields: teamAShields, fresh: false) < 500 {
                    interruptAt = min(interruptAt, bUnlock)
                }
                // Catch/sac triggers: stop the segment when the opponent's banked
                // energy first affords a charged move this side's bench could catch
                // on a resist or absorb with a sac, once the switch timer allows.
                // Armed only while currently false, so a boundary that just declined
                // the offer can't immediately re-interrupt — it re-arms only after
                // the opponent's energy dips (it threw the move).
                var aEnergyAt = Int.max
                if let t = energyInterruptThreshold(team: teamA, fainted: faintedA, active: activeA,
                                                    opponent: b, teamShields: teamAShields),
                   !(globalTime >= aUnlock && b.startEnergy >= t) {
                    aEnergyAt = t
                }
                var bEnergyAt = Int.max
                if let t = energyInterruptThreshold(team: teamB, fainted: faintedB, active: activeB,
                                                    opponent: a, teamShields: teamBShields),
                   !(globalTime >= bUnlock && a.startEnergy >= t) {
                    bEnergyAt = t
                }
                if interruptAt < Int.max || aEnergyAt < Int.max || bEnergyAt < Int.max {
                    battle.interruptCheck = {
                        $0.time >= interruptAt
                            || ($0.time >= aUnlock && $0.pokemon[1].energy >= aEnergyAt)
                            || ($0.time >= bUnlock && $0.pokemon[0].energy >= bEnergyAt)
                    }
                }
            }
            var shieldSolution: ShieldSearch.Solution?
            if optimalShields {
                let sol = ShieldSearch.optimalSolution(a, b)
                shieldSolution = sol
                battle.shieldOverride = { defenderIndex, opportunity in
                    defenderIndex == 0 ? sol.policyA.contains(opportunity) : sol.policyB.contains(opportunity)
                }
            }
            battle.simulate()
            globalTime = battle.time
            if record {
                segments.append(.init(indexA: activeA, indexB: activeB,
                                      log: battle.makeLog(), shieldScenario: shieldSolution))
            }

            // Carry each combatant's state forward (the survivor stays in).
            a.startHp = max(0, a.hp); a.startEnergy = a.energy; a.startStatBuffs = a.statBuffs
            b.startHp = max(0, b.hp); b.startEnergy = b.energy; b.startStatBuffs = b.statBuffs
            a.startDisguiseConsumed = a.hasDisguise && !a.disguiseActive
            b.startDisguiseConsumed = b.hasDisguise && !b.disguiseActive
            teamAShields = a.shields
            teamBShields = b.shields

            let aFainted = a.hp <= 0
            let bFainted = b.hp <= 0

            // Neither fainted → either a mid-segment interrupt (back to the boundary
            // so the freed side can voluntarily switch) or the shared clock ran out.
            if !aFainted && !bFainted {
                if battle.interrupted && globalTime <= battleTimeLimit { continue }
                timedOut = true
                break
            }
            if aFainted { faintedA.insert(activeA) }
            if bFainted { faintedB.insert(activeB) }

            // Bring in a replacement for whichever team lost one. If both fell this
            // segment there's no clean "current opponent" to counter, so fall back
            // to team order for both.
            if aFainted && bFainted {
                if let n = Self.nextAlive(count: teamA.count, fainted: faintedA) { activeA = n; entrancesA.append(n) }
                if let n = Self.nextAlive(count: teamB.count, fainted: faintedB) { activeB = n; entrancesB.append(n) }
            } else if aFainted {
                if let n = chooseNext(team: teamA, fainted: faintedA, teamShields: teamAShields,
                                      opponent: teamB[activeB], opponentShields: teamBShields) {
                    activeA = n; entrancesA.append(n)
                }
            } else if bFainted {
                if let n = chooseNext(team: teamB, fainted: faintedB, teamShields: teamBShields,
                                      opponent: teamA[activeA], opponentShields: teamAShields) {
                    activeB = n; entrancesB.append(n)
                }
            }

            if faintedA.count >= teamA.count || faintedB.count >= teamB.count { break }
            if globalTime > battleTimeLimit { timedOut = true; break }
        }

        let result = Self.tally(
            teamA: teamA, teamB: teamB,
            faintedA: faintedA, faintedB: faintedB,
            entrancesA: entrancesA, entrancesB: entrancesB,
            shieldsA: teamAShields, shieldsB: teamBShields,
            timedOut: timedOut)
        return (result, segments)
    }

    // MARK: - Voluntary switching (information-aware, revealed-only)

    /// Whether to voluntarily switch the active mon, and to whom, given only the
    /// currently-revealed opponent. Returns a backup index that beats the opponent by
    /// the hysteresis margin when the current active is losing; otherwise nil. Never
    /// consults the opponent's hidden backline.
    private func voluntarySwitchTarget(
        team: [BattlePokemon], fainted: Set<Int>, active: Int,
        opponent: BattlePokemon, teamShields: Int, opponentShields: Int
    ) -> Int? {
        let backups = (0..<team.count).filter { !fainted.contains($0) && $0 != active }
        guard !backups.isEmpty else { return nil }

        // Only switch out of a losing matchup.
        let currentRating = rate(team[active], vs: opponent,
                                 myShields: teamShields, oppShields: opponentShields, fresh: false)
        guard currentRating < 500 else { return nil }

        var bestIndex: Int?
        var bestRating = currentRating + Self.switchHysteresis
        for i in backups {
            let r = rate(team[i], vs: opponent, myShields: teamShields, oppShields: opponentShields, fresh: true)
            if r > bestRating && r > 500 { bestRating = r; bestIndex = i }
        }
        return bestIndex
    }

    /// Counterswap check against an opponent that just voluntarily switched in and is
    /// therefore switch-locked. Because the locked mon can't escape for the timer,
    /// this considers switching even out of an even or winning matchup — but only for
    /// a backup with a dominant matchup (`counterSwitchDominance`), not merely a
    /// better one, since it spends this side's own switch clock.
    private func counterSwitchTarget(
        team: [BattlePokemon], fainted: Set<Int>, active: Int,
        opponent: BattlePokemon, teamShields: Int, opponentShields: Int
    ) -> Int? {
        let backups = (0..<team.count).filter { !fainted.contains($0) && $0 != active }
        guard !backups.isEmpty else { return nil }

        let currentRating = rate(team[active], vs: opponent,
                                 myShields: teamShields, oppShields: opponentShields, fresh: false)
        var bestIndex: Int?
        var bestRating = max(currentRating + Self.switchHysteresis, Self.counterSwitchDominance)
        for i in backups {
            let r = rate(team[i], vs: opponent, myShields: teamShields, oppShields: opponentShields, fresh: true)
            if r > bestRating { bestRating = r; bestIndex = i }
        }
        return bestIndex
    }

    /// Full voluntary-switch decision at a segment boundary, in priority order:
    /// escape a losing matchup, catch an expected super-effective charged move on
    /// a resist, or sac-shield a winning mon. Internal (not private) so tests can
    /// drive boundary decisions directly.
    func boundarySwitchTarget(
        team: [BattlePokemon], fainted: Set<Int>, active: Int,
        opponent: BattlePokemon, teamShields: Int, opponentShields: Int
    ) -> Int? {
        if let t = voluntarySwitchTarget(team: team, fainted: fainted, active: active,
                                         opponent: opponent, teamShields: teamShields,
                                         opponentShields: opponentShields) { return t }
        if let t = catchSwitchTarget(team: team, fainted: fainted, active: active,
                                     opponent: opponent, teamShields: teamShields,
                                     opponentShields: opponentShields) { return t }
        return sacSwitchTarget(team: team, fainted: fainted, active: active,
                               opponent: opponent, teamShields: teamShields,
                               opponentShields: opponentShields)
    }

    /// Catch swap: the revealed opponent has banked energy for a charged move that
    /// is super-effective against our active, so swap into a backup that resists it
    /// and survives the throw ("catching" the move). Energy counts are revealed
    /// information — players track them by counting fast moves. Once the resist is
    /// on the field the opponent may hold the move instead; deterring it is the
    /// same win. Only a backup beating `catchMinRating` is worth the switch clock.
    private func catchSwitchTarget(
        team: [BattlePokemon], fainted: Set<Int>, active: Int,
        opponent: BattlePokemon, teamShields: Int, opponentShields: Int
    ) -> Int? {
        guard let threat = expectedChargedMove(from: opponent, against: team[active]),
              team[active].typeEffectiveness(forTypeIndex: threat.typeIndex) > 1 else { return nil }

        var bestIndex: Int?
        var bestRating = Self.catchMinRating
        for i in 0..<team.count where !fainted.contains(i) && i != active {
            let backup = team[i]
            guard backup.typeEffectiveness(forTypeIndex: threat.typeIndex) < 1,
                  Self.carriedHp(backup) > DamageCalculator.damage(opponent, backup, threat)
            else { continue }
            let r = rate(backup, vs: opponent, myShields: teamShields, oppShields: opponentShields, fresh: true)
            if r > bestRating { bestRating = r; bestIndex = i }
        }
        return bestIndex
    }

    /// Sac swap: out of shields with the active mon winning but about to eat a heavy
    /// charged move, throw a nearly-fainted backup in front of it as one more shield.
    /// The faint replacement afterwards is free (no switch clock), so the protected
    /// mon returns once the sac has soaked the throw — or the opponent burns time
    /// fast-moving the sac down while holding it, which also buys the winner turns.
    private func sacSwitchTarget(
        team: [BattlePokemon], fainted: Set<Int>, active: Int,
        opponent: BattlePokemon, teamShields: Int, opponentShields: Int
    ) -> Int? {
        guard teamShields == 0,
              let threat = expectedChargedMove(from: opponent, against: team[active]),
              Double(DamageCalculator.damage(opponent, team[active], threat))
                >= Self.sacDangerFraction * Double(Self.carriedHp(team[active])),
              rate(team[active], vs: opponent, myShields: teamShields,
                   oppShields: opponentShields, fresh: false) >= 500
        else { return nil }

        var sacIndex: Int?
        var sacFraction = Self.sacMaxHpFraction
        for i in 0..<team.count where !fainted.contains(i) && i != active {
            let fraction = Double(Self.carriedHp(team[i])) / Double(team[i].stats.hp)
            if fraction <= sacFraction { sacFraction = fraction; sacIndex = i }
        }
        return sacIndex
    }

    /// The charged move the revealed opponent would most plausibly throw right now:
    /// its most damaging move against `target` among those its carried energy affords.
    private func expectedChargedMove(from opponent: BattlePokemon, against target: BattlePokemon) -> BattleMove? {
        var best: BattleMove?
        var bestDamage = 0
        for move in opponent.chargedMoves where move.energy <= opponent.startEnergy {
            let d = DamageCalculator.damage(opponent, target, move)
            if d > bestDamage { bestDamage = d; best = move }
        }
        return best
    }

    /// The opponent-energy level that should interrupt this side's segment: the
    /// cheapest revealed charged move its bench could catch (super-effective vs the
    /// active, resisted by a living backup) or — out of shields with sac material
    /// benched — absorb with a sac. Nil when the bench offers neither. Type math
    /// only; the boundary decision does the sim-based validation.
    private func energyInterruptThreshold(
        team: [BattlePokemon], fainted: Set<Int>, active: Int,
        opponent: BattlePokemon, teamShields: Int
    ) -> Int? {
        let backups = (0..<team.count).filter { !fainted.contains($0) && $0 != active }
        guard !backups.isEmpty else { return nil }

        var threshold = Int.max
        for move in opponent.chargedMoves where move.energy < threshold {
            if team[active].typeEffectiveness(forTypeIndex: move.typeIndex) > 1,
               backups.contains(where: { team[$0].typeEffectiveness(forTypeIndex: move.typeIndex) < 1 }) {
                threshold = move.energy
            }
        }
        if teamShields == 0,
           backups.contains(where: { Double(Self.carriedHp(team[$0])) / Double(team[$0].stats.hp) <= Self.sacMaxHpFraction }) {
            for move in opponent.chargedMoves { threshold = min(threshold, move.energy) }
        }
        return threshold == Int.max ? nil : threshold
    }

    /// Rating of `mon` vs `opponent` from a throwaway 1v1 on clones (no mutation).
    /// `fresh` = the mon enters at full HP/energy (a switch-in); otherwise it uses its
    /// carried state (the mon currently on the field).
    private func rate(_ mon: BattlePokemon, vs opponent: BattlePokemon,
                      myShields: Int, oppShields: Int, fresh: Bool) -> Int {
        let m = mon.clone()
        if fresh { m.startHp = 0; m.startEnergy = 0; m.startStatBuffs = [0, 0] }
        m.startingShields = myShields
        let o = opponent.clone()
        o.startingShields = oppShields
        let battle = Battle(m, o)
        battle.simulate()
        return battle.battleRating(forIndex: 0)
    }

    // MARK: - Helpers

    /// First team-order index that hasn't fainted, or nil if the team is wiped.
    private static func nextAlive(count: Int, fainted: Set<Int>) -> Int? {
        (0..<count).first { !fainted.contains($0) }
    }

    /// Whether the team has a living Pokémon besides the active one.
    private static func hasBackup(count: Int, fainted: Set<Int>, active: Int) -> Bool {
        (0..<count).contains { !fainted.contains($0) && $0 != active }
    }

    /// A mon's carried HP between segments (`startHp == 0` means it never fought → full).
    private static func carriedHp(_ p: BattlePokemon) -> Int {
        p.startHp > 0 ? min(p.startHp, p.stats.hp) : p.stats.hp
    }

    /// Chooses which Pokémon a team brings in next. For `.bestMatchup`, each alive
    /// teammate is simulated (fresh) against a clone of the opponent's current state
    /// and the highest-rated one is picked (ties → earliest in team order).
    private func chooseNext(team: [BattlePokemon], fainted: Set<Int>, teamShields: Int,
                            opponent: BattlePokemon, opponentShields: Int) -> Int? {
        let alive = (0..<team.count).filter { !fainted.contains($0) }
        guard let first = alive.first else { return nil }
        guard switchPolicy == .bestMatchup, alive.count > 1 else { return first }

        var bestIndex = first
        var bestRating = Int.min
        for i in alive {
            let cand = team[i].clone()
            cand.startHp = 0; cand.startEnergy = 0
            cand.startingShields = teamShields; cand.startStatBuffs = [0, 0]
            let opp = opponent.clone()                 // carries the opponent's current state
            opp.startingShields = opponentShields
            let battle = Battle(cand, opp)
            battle.simulate()
            let rating = battle.battleRating(forIndex: 0)   // candidate's perspective
            if rating > bestRating { bestRating = rating; bestIndex = i }
        }
        return bestIndex
    }

    private static func tally(
        teamA: [BattlePokemon], teamB: [BattlePokemon],
        faintedA: Set<Int>, faintedB: Set<Int>,
        entrancesA: [Int], entrancesB: [Int],
        shieldsA: Int, shieldsB: Int,
        timedOut: Bool
    ) -> TeamBattleResult {
        let survivorsA = teamA.count - faintedA.count
        let survivorsB = teamB.count - faintedB.count

        func hpRemaining(_ team: [BattlePokemon], fainted: Set<Int>, entered: [Int]) -> Double {
            var sum = 0.0
            for i in 0..<team.count where !fainted.contains(i) {
                let p = team[i]
                // Entered-and-alive Pokémon carry their remaining HP; Pokémon that
                // never entered are at full HP.
                sum += entered.contains(i) ? Double(max(0, p.hp)) / Double(p.stats.hp) : 1.0
            }
            return sum
        }

        let hpA = hpRemaining(teamA, fainted: faintedA, entered: entrancesA)
        let hpB = hpRemaining(teamB, fainted: faintedB, entered: entrancesB)

        let winner: TeamBattleResult.Winner
        if survivorsA > 0 && survivorsB == 0 {
            winner = .teamA
        } else if survivorsB > 0 && survivorsA == 0 {
            winner = .teamB
        } else if survivorsA == 0 && survivorsB == 0 {
            winner = .tie
        } else if survivorsA != survivorsB {
            winner = survivorsA > survivorsB ? .teamA : .teamB
        } else if abs(hpA - hpB) > 0.0001 {
            winner = hpA > hpB ? .teamA : .teamB
        } else {
            winner = .tie
        }

        let totalHP = hpA + hpB
        let ratingA = totalHP > 0 ? Int((hpA / totalHP * 1000).rounded()) : 500

        return TeamBattleResult(
            winner: winner,
            survivorsA: survivorsA, survivorsB: survivorsB,
            hpRemainingA: hpA, hpRemainingB: hpB,
            shieldsA: shieldsA, shieldsB: shieldsB,
            ratingA: ratingA, timedOut: timedOut,
            entrancesA: entrancesA, entrancesB: entrancesB)
    }

    // MARK: - Team construction

    /// Builds a team of battle-ready Pokémon from combatants + precomputed stats.
    /// Returns nil if any member can't be built (missing moves, etc.).
    static func makeTeam(
        _ combatants: [MatchupSimulator.Combatant],
        stats: [BattlePokemon.Stats],
        movesById: [String: Move]
    ) -> [BattlePokemon]? {
        guard combatants.count == stats.count, !combatants.isEmpty else { return nil }
        var team: [BattlePokemon] = []
        team.reserveCapacity(combatants.count)
        for (c, s) in zip(combatants, stats) {
            guard let bp = MatchupSimulator.makeBattlePokemon(
                c, stats: s, movesById: movesById, shields: 2) else { return nil }
            team.append(bp)
        }
        return team
    }

    /// Convenience: build both teams and run a single 3v3 with the given leads.
    static func run(
        teamA: [MatchupSimulator.Combatant], statsA: [BattlePokemon.Stats],
        teamB: [MatchupSimulator.Combatant], statsB: [BattlePokemon.Stats],
        movesById: [String: Move],
        leadA: Int = 0, leadB: Int = 0,
        shieldsA: Int = 2, shieldsB: Int = 2,
        switchPolicy: SwitchPolicy = .bestMatchup
    ) -> TeamBattleResult? {
        guard let a = makeTeam(teamA, stats: statsA, movesById: movesById),
              let b = makeTeam(teamB, stats: statsB, movesById: movesById) else { return nil }
        return ThreeVThreeBattle(
            teamA: a, teamB: b,
            leadA: leadA, leadB: leadB,
            shieldsA: shieldsA, shieldsB: shieldsB,
            switchPolicy: switchPolicy).run()
    }

    /// Convenience: build both teams and run a recorded 3v3 (for the timeline).
    /// `baitShieldsA`/`baitShieldsB` control each side's AI (`BattlePokemon.baitShields`):
    /// true = selective baiting (the pvpoke default), false = always throw the best move.
    static func runRecorded(
        teamA: [MatchupSimulator.Combatant], statsA: [BattlePokemon.Stats],
        teamB: [MatchupSimulator.Combatant], statsB: [BattlePokemon.Stats],
        movesById: [String: Move],
        leadA: Int = 0, leadB: Int = 0,
        shieldsA: Int = 2, shieldsB: Int = 2,
        switchPolicy: SwitchPolicy = .bestMatchup,
        voluntarySwitching: Bool = false,
        baitShieldsA: Bool = true, baitShieldsB: Bool = true
    ) -> TeamBattleLog? {
        guard let a = makeTeam(teamA, stats: statsA, movesById: movesById),
              let b = makeTeam(teamB, stats: statsB, movesById: movesById) else { return nil }
        for p in a { p.baitShields = baitShieldsA ? 1 : 0 }
        for p in b { p.baitShields = baitShieldsB ? 1 : 0 }
        return ThreeVThreeBattle(
            teamA: a, teamB: b,
            leadA: leadA, leadB: leadB,
            shieldsA: shieldsA, shieldsB: shieldsB,
            switchPolicy: switchPolicy, voluntarySwitching: voluntarySwitching).runRecorded()
    }
}
