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

    private let battleTimeLimit = 240_000

    init(teamA: [BattlePokemon], teamB: [BattlePokemon],
         leadA: Int = 0, leadB: Int = 0, shieldsA: Int = 2, shieldsB: Int = 2,
         switchPolicy: SwitchPolicy = .bestMatchup) {
        self.teamA = teamA
        self.teamB = teamB
        self.leadA = leadA
        self.leadB = leadB
        self.shieldsA = shieldsA
        self.shieldsB = shieldsB
        self.switchPolicy = switchPolicy
    }

    /// Runs the full team battle. Mutates the passed `BattlePokemon` objects, so
    /// pass freshly-built teams (see `makeTeam`).
    func run() -> TeamBattleResult {
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

        // Safety bound: at most (all Pokémon faint) + 1 segments.
        let maxSegments = teamA.count + teamB.count + 1
        var segment = 0

        while segment < maxSegments {
            segment += 1
            let a = teamA[activeA]
            let b = teamB[activeB]
            a.startingShields = teamAShields
            b.startingShields = teamBShields

            let battle = Battle(a, b, startTime: globalTime)
            battle.simulate()
            globalTime = battle.time

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

        return Self.tally(
            teamA: teamA, teamB: teamB,
            faintedA: faintedA, faintedB: faintedB,
            entrancesA: entrancesA, entrancesB: entrancesB,
            shieldsA: teamAShields, shieldsB: teamBShields,
            timedOut: timedOut)
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
}
