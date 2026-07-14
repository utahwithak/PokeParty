//
//  ThreeVThreeBattle.swift
//  PokeParty
//
//  Milestone 2 of the 3v3 work (see docs/TeamBuilder-Plan.md §4). A true team
//  battle between two full teams, built on top of the existing 1v1 `Battle`
//  engine: it runs consecutive 1v1 segments and carries each Pokémon's HP,
//  energy, shields and stat buffs across faints, sharing one 240s clock.
//
//  Scope for this first version (documented in the plan, M2):
//   - Leads are specified by the caller (the finder will enumerate lead combos).
//   - Shields are a per-team pool (default 2) shared across a team's Pokémon.
//   - Switching happens ONLY on faint (no mid-battle voluntary switching yet);
//     the replacement is the next non-fainted Pokémon in team order.
//   - Each segment plays out as an optimal 1v1 via the existing `ActionLogic` AI.
//  Voluntary switching, the switch timer, and best-matchup switch selection are
//  future refinements.
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
    /// (turn-0 safe-swap + counter-switch when the opponent reveals a new mon). The
    /// switch timer prevents thrashing. Off by default (M8.3).
    var voluntarySwitching: Bool

    private let battleTimeLimit = 240_000
    /// GBL switch cooldown: after a voluntary switch a side can't switch again for
    /// this long (battle-ms). (Live-game value is often cited as 60s; set to 30s per
    /// project spec — one constant to change.)
    private static let switchTimerMs = 30_000
    /// A backup must beat the current active by at least this rating to be worth a
    /// voluntary switch (hysteresis to avoid marginal flip-flopping).
    private static let switchHysteresis = 75
    /// Tempo cost of switching: the side that stays gets this many free fast moves of
    /// energy while the other spends its turn switching.
    private static let switchTempoFastMoves = 3

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

        // Safety bound: at most (all Pokémon faint) + 1 segments.
        let maxSegments = teamA.count + teamB.count + 1
        var segment = 0

        while segment < maxSegments {
            segment += 1

            // Voluntary switching at the boundary (turn-0 safe-swap + counter-switch
            // vs the revealed opponent). Both sides decide simultaneously from the
            // current on-field mons; the switch timer prevents thrashing.
            if voluntarySwitching {
                let aCanSwitch = globalTime - lastSwitchA >= Self.switchTimerMs
                let bCanSwitch = globalTime - lastSwitchB >= Self.switchTimerMs
                let aTarget = aCanSwitch ? voluntarySwitchTarget(
                    team: teamA, fainted: faintedA, active: activeA,
                    opponent: teamB[activeB], teamShields: teamAShields, opponentShields: teamBShields) : nil
                let bTarget = bCanSwitch ? voluntarySwitchTarget(
                    team: teamB, fainted: faintedB, active: activeB,
                    opponent: teamA[activeA], teamShields: teamBShields, opponentShields: teamAShields) : nil
                if let aTarget { activeA = aTarget; lastSwitchA = globalTime; entrancesA.append(aTarget) }
                if let bTarget { activeB = bTarget; lastSwitchB = globalTime; entrancesB.append(bTarget) }
                // Tempo cost: if exactly one side switched, the other gets free energy.
                if (aTarget != nil) != (bTarget != nil) {
                    let stayer = aTarget != nil ? teamB[activeB] : teamA[activeA]
                    stayer.startEnergy = min(100, stayer.startEnergy + stayer.fastMove.energyGain * Self.switchTempoFastMoves)
                }
            }

            let a = teamA[activeA]
            let b = teamB[activeB]
            a.startingShields = teamAShields
            b.startingShields = teamBShields

            let battle = Battle(a, b, startTime: globalTime, record: record)
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
            teamAShields = a.shields
            teamBShields = b.shields

            let aFainted = a.hp <= 0
            let bFainted = b.hp <= 0

            // Neither fainted → the shared clock ran out.
            if !aFainted && !bFainted {
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
