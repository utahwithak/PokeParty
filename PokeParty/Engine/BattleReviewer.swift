//
//  BattleReviewer.swift
//  PokeParty
//
//  After a game: replays it through the 3v3 engine as it was played — the leads
//  both sides opened with and the order each side's replacements came in, taken
//  from the battle log — with the same learned shield / switch / farm policies
//  the Party Finder uses. The sim's verdict on the game is only stored for the
//  history's win/loss breakdown; the opponent rarely plays the way the sim
//  assumes, so it isn't presented as a prediction. What the review shows is
//  hindsight: specific decisions (a swap, a charged move) where replaying the
//  game with a different choice comes out clearly better.
//  The sim can't see the opponent's IVs, and any move it didn't see thrown is
//  the ranked guess, so a gap between sim and reality can also be the sim's fault.
//

import Foundation

nonisolated enum BattleReviewer {

    struct Review: Sendable {
        /// The sim's playthrough of the recorded leads and order.
        let simLog: TeamBattleLog
        /// "Your Azumarill beat their Skarmory" per 1v1 stretch.
        let simLine: [String]
        let simPredictsWin: Bool
        /// Your margin in the sim, 0…1000 (500 = even).
        let rating: Int
        /// Nil until the game's result is known.
        let diagnosis: BattleDiagnosis?
        let findings: [String]
    }

    /// Replays the game with the recorded leads, and replacements in the
    /// recorded order. Voluntary swaps are left to the AI.
    static func simulate(team: [BattlePokemon], opponents: [BattlePokemon],
                         myLead: Int, theirLead: Int,
                         myReplacements: [Int], theirReplacements: [Int]) -> ThreeVThreeBattle {
        var battle = ThreeVThreeBattle(
            teamA: team, teamB: opponents, leadA: myLead, leadB: theirLead,
            shieldsA: 2, shieldsB: 2,
            optimalShields: false, voluntarySwitching: true,
            learnedShieldNet: ShieldPolicyNet.bundled)
        let switchNet = SwitchPolicyNet.bundled
        battle.switchDecisionHook = { context in
            // After a faint, bring in whoever really came in next.
            if context.mandatory {
                let order = context.side == 0 ? myReplacements : theirReplacements
                if let next = order.first(where: { $0 != context.active && !context.fainted.contains($0) }) {
                    return .switchTo(next)
                }
                return .heuristic
            }
            return switchNet?.decide(context) ?? .heuristic
        }
        battle.applyFarmNet(FarmPolicyNet.bundled)
        return battle
    }

    /// Reviews `battle`. `team` / `opponents` must line up with `battle.team` /
    /// `battle.opponents` (same order, same count); `names` are display names
    /// for the same indices. `opponents` should already carry the charged moves
    /// seen thrown (`RecordedBattle.observedOpponentMoves`) in place of the guess.
    static func review(battle: RecordedBattle, team: [BattlePokemon], opponents: [BattlePokemon],
                       teamNames: [String], opponentNames: [String],
                       moveName: (String) -> String = { $0 }) -> Review? {
        guard !team.isEmpty, team.count == battle.team.count,
              !opponents.isEmpty, opponents.count == battle.opponents.count,
              teamNames.count == team.count, opponentNames.count == opponents.count else { return nil }

        // Who came out first and in what order, from the log.
        func indices(_ order: [String], in members: [TeamMember]) -> [Int] {
            order.compactMap { id in members.firstIndex { $0.speciesId == id } }
        }
        let myOrder = indices(battle.entranceOrder(mine: true), in: battle.team)
        let theirOrder = indices(battle.entranceOrder(mine: false), in: battle.opponents)
        let leadsKnown = !myOrder.isEmpty && !theirOrder.isEmpty
        let forcedMine = indices(
            battle.events.filter { $0.kind == .enter && $0.mine && !$0.voluntary }.compactMap(\.speciesId), in: battle.team)
            .filter { $0 != myOrder.first }
        let forcedTheirs = indices(
            battle.events.filter { $0.kind == .enter && !$0.mine && !$0.voluntary }.compactMap(\.speciesId), in: battle.opponents)
            .filter { $0 != theirOrder.first }

        let simLog = simulate(
            team: team, opponents: opponents,
            myLead: myOrder.first ?? 0, theirLead: theirOrder.first ?? 0,
            myReplacements: forcedMine, theirReplacements: forcedTheirs).runRecorded()
        let simLine = line(of: simLog, teamNames: teamNames, opponentNames: opponentNames)
        let simWins = simLog.result.winner == .teamA
        let rating = simLog.result.ratingA

        var diagnosis: BattleDiagnosis?
        var findings: [String] = []

        // Specific things that could have gone differently, checked by replay.
        let hindsight = swapFindings(battle: battle, team: team, opponents: opponents,
                                     teamNames: teamNames, opponentNames: opponentNames)
            + moveFindings(battle: battle, team: team, opponents: opponents, teamNames: teamNames,
                           myOrder: myOrder, theirOrder: theirOrder,
                           forcedMine: forcedMine, forcedTheirs: forcedTheirs,
                           baseline: simLog.result, moveName: moveName)
        findings += hindsight

        switch battle.outcome {
        case .win?:
            diagnosis = simWins ? .asExpected : .outplayedSim
        case .loss?:
            if simWins {
                diagnosis = .execution
                findings += playDifferences(battle: battle, simLog: simLog, teamNames: teamNames, moveName: moveName)
            } else {
                diagnosis = .teamMatchup
                findings += matchupProblems(simLog: simLog, simLine: simLine)
            }
        case nil:
            break
        }
        if hindsight.isEmpty {
            findings.insert("No swap or charged-move change replays clearly better than what you did.", at: 0)
        } else {
            findings.append("Replayed from full health — the log doesn't record HP or energy, so treat these as pointers.")
        }

        if opponents.count < 3 {
            findings.append("Only \(opponents.count) of their 3 Pokémon were seen, so the sim is missing the rest of their team.")
        }
        if !leadsKnown {
            findings.append("The leads weren't captured in the log, so the sim used the first Pokémon on each team.")
        }
        let seenMoves = battle.observedOpponentMoves
        if seenMoves.isEmpty {
            findings.append("No opponent charged moves were read off the screen, so their moves in the sim are the ranked guess.")
        }

        return Review(
            simLog: simLog, simLine: simLine, simPredictsWin: simWins, rating: rating,
            diagnosis: diagnosis, findings: findings)
    }

    // MARK: - Hindsight

    /// Blend used to compare two playouts — the same one the live coach ranks by.
    private static func score(_ result: TeamBattleResult) -> Double {
        let win: Double
        switch result.winner {
        case .teamA: win = 1
        case .tie: win = 0.5
        case .teamB: win = 0
        }
        return win * 0.75 + Double(result.ratingA) / 1000 * 0.25
    }

    /// Every voluntary swap you made, replayed from that moment with the other
    /// choices (stay in, or swap to someone else). Flags swaps that were clearly worse.
    private static func swapFindings(battle: RecordedBattle, team: [BattlePokemon], opponents: [BattlePokemon],
                                     teamNames: [String], opponentNames: [String]) -> [String] {
        var out: [String] = []
        var myFainted = Set<String>(), theirFainted = Set<String>()
        var myActive: String?

        for event in battle.events {
            switch event.kind {
            case .faint:
                if let id = event.speciesId { if event.mine { myFainted.insert(id) } else { theirFainted.insert(id) } }
            case .enter where event.mine:
                defer { myActive = event.speciesId }
                guard event.voluntary, let previous = myActive, let newcomer = event.speciesId,
                      let opponentId = event.otherSpeciesId,
                      !myFainted.contains(previous),
                      let from = battle.team.firstIndex(where: { $0.speciesId == previous }),
                      let to = battle.team.firstIndex(where: { $0.speciesId == newcomer }),
                      let them = battle.opponents.firstIndex(where: { $0.speciesId == opponentId })
                else { continue }

                // Only Pokémon still alive at this point are in play.
                let mine = battle.team.indices.filter { !myFainted.contains(battle.team[$0].speciesId) || $0 == from }
                let theirs = battle.opponents.indices.filter { !theirFainted.contains(battle.opponents[$0].speciesId) || $0 == them }
                guard let themLocal = theirs.firstIndex(of: them) else { continue }
                let myTeam = mine.map { team[$0] }, theirTeam = theirs.map { opponents[$0] }

                func play(_ lead: Int) -> Double? {
                    guard let local = mine.firstIndex(of: lead) else { return nil }
                    return score(rollout(team: myTeam, opponents: theirTeam, lead: local, theirLead: themLocal,
                                         shields: (event.myShields, event.opponentShields)))
                }
                guard let stay = play(from), let swapped = play(to) else { continue }
                let alternatives = mine.filter { $0 != from && $0 != to }.compactMap { index in
                    play(index).map { (index, $0) }
                }

                if stay - swapped >= BattleCoach.switchMargin {
                    out.append("Don't swap out of \(teamNames[from]) against \(opponentNames[them]) — staying in replays \(Int((stay * 100).rounded()))% as good against \(Int((swapped * 100).rounded()))% after swapping to \(teamNames[to]).")
                } else if let better = alternatives.max(by: { $0.1 < $1.1 }), better.1 - swapped >= BattleCoach.switchMargin,
                          better.1 >= stay {
                    out.append("Swapping out of \(teamNames[from]) was fine, but \(teamNames[better.0]) was the better pick than \(teamNames[to]) against \(opponentNames[them]).")
                }
            default: break
            }
        }
        return out
    }

    /// For each of your Pokémon that threw two different charged moves, replays
    /// the game with it limited to one of them. Flags a move that was better left out.
    private static func moveFindings(battle: RecordedBattle, team: [BattlePokemon], opponents: [BattlePokemon],
                                     teamNames: [String], myOrder: [Int], theirOrder: [Int],
                                     forcedMine: [Int], forcedTheirs: [Int],
                                     baseline: TeamBattleResult, moveName: (String) -> String) -> [String] {
        var out: [String] = []
        let baseScore = score(baseline)
        let throwsBySpecies = Dictionary(grouping: battle.events.filter { $0.kind == .charged && $0.mine }, by: { $0.speciesId ?? "" })

        for (index, member) in battle.team.enumerated() where team.indices.contains(index) {
            let thrown = throwsBySpecies[member.speciesId]?.compactMap(\.moveId) ?? []
            guard Set(thrown).count >= 2, team[index].chargedMoves.count >= 2 else { continue }
            let counts = Dictionary(grouping: thrown, by: { $0 }).mapValues(\.count)

            // The single best move to keep, and what it replays at.
            var best: (move: BattleMove, score: Double)?
            for keep in team[index].chargedMoves {
                var variant = team
                variant[index].chargedMoves = [keep]
                let result = simulate(team: variant, opponents: opponents,
                                      myLead: myOrder.first ?? 0, theirLead: theirOrder.first ?? 0,
                                      myReplacements: forcedMine, theirReplacements: forcedTheirs).run()
                let s = score(result)
                if s > (best?.score ?? -.infinity) { best = (keep, s) }
            }
            guard let best, best.score - baseScore >= BattleCoach.switchMargin else { continue }
            let skipped = team[index].chargedMoves.filter { $0.moveId != best.move.moveId }
                .map { "\(moveName($0.moveId)) ×\(counts[$0.moveId] ?? 0)" }.joined(separator: ", ")
            out.append("\(teamNames[index]) did better leaning on \(moveName(best.move.moveId)) (you threw \(counts[best.move.moveId] ?? 0)) than throwing \(skipped) — replaying it with only \(moveName(best.move.moveId)) is clearly stronger.")
        }
        return out
    }

    /// One 3v3 playout from a given moment, with the learned policies on.
    private static func rollout(team: [BattlePokemon], opponents: [BattlePokemon], lead: Int, theirLead: Int,
                                shields: (mine: Int, theirs: Int)) -> TeamBattleResult {
        var battle = ThreeVThreeBattle(
            teamA: team, teamB: opponents, leadA: lead, leadB: theirLead,
            shieldsA: shields.mine, shieldsB: shields.theirs,
            switchPolicy: .bestMatchup, optimalShields: false, voluntarySwitching: true,
            learnedShieldNet: ShieldPolicyNet.bundled)
        if let switchNet = SwitchPolicyNet.bundled { battle.switchDecisionHook = { switchNet.decide($0) } }
        battle.applyFarmNet(FarmPolicyNet.bundled)
        return battle.run()
    }

    // MARK: - Comparing with the real game

    /// Where your real game differs from the sim's: shields, charged moves,
    /// swaps, who went down first.
    private static func playDifferences(battle: RecordedBattle, simLog: TeamBattleLog, teamNames: [String],
                                        moveName: (String) -> String) -> [String] {
        var out: [String] = []

        // Distinct shields-left values, so duplicate events from older recordings (a flickering read) don't count twice.
        let myShieldsUsed = Set(battle.events.filter { $0.kind == .shield && $0.mine }.map { $0.value ?? -1 }).count
        let simShieldsUsed = max(0, 2 - simLog.result.shieldsA)
        if myShieldsUsed > simShieldsUsed {
            out.append("You spent \(myShieldsUsed) shield\(myShieldsUsed == 1 ? "" : "s"); the sim used \(simShieldsUsed). It held shields for the moves that mattered.")
        } else if myShieldsUsed < simShieldsUsed {
            out.append("You spent \(myShieldsUsed) shield\(myShieldsUsed == 1 ? "" : "s"); the sim used \(simShieldsUsed). It shielded where you took the hit.")
        }

        // Charged moves: how many, and how many the opponent absorbed with shields.
        let myThrows = battle.events.filter { $0.kind == .charged && $0.mine }
        if !myThrows.isEmpty {
            let simThrows = simLog.segments.flatMap { $0.log.frames }
                .filter { $0.event?.kind == .charged && $0.event?.actor == 0 }
            let theirShields = battle.events.filter { $0.kind == .shield && !$0.mine }.count
            let simShielded = simThrows.filter { $0.event?.shielded == true }.count
            let counts = Dictionary(grouping: myThrows.compactMap(\.moveId), by: { $0 })
                .sorted { $0.key < $1.key }
                .map { "\(moveName($0.key)) ×\($0.value.count)" }.joined(separator: ", ")
            out.append("You threw \(myThrows.count) charged move\(myThrows.count == 1 ? "" : "s") (\(counts)); the sim threw \(simThrows.count), \(simShielded) into shields (you saw \(theirShields)).")
        }

        let mySwaps = battle.events.filter { $0.kind == .enter && $0.mine && $0.voluntary }.count
        let simSwaps = simLog.segments.filter { $0.voluntarySwitchSide == 0 }.count
        if mySwaps != simSwaps {
            out.append("You swapped \(mySwaps) time\(mySwaps == 1 ? "" : "s") on purpose; the sim swapped \(simSwaps).")
        }

        let theirShieldsUsed = battle.events.filter { $0.kind == .shield && !$0.mine }.count
        let simTheirShields = max(0, 2 - simLog.result.shieldsB)
        if theirShieldsUsed < simTheirShields {
            out.append("The sim made the opponent spend \(simTheirShields) shield\(simTheirShields == 1 ? "" : "s"); you got \(theirShieldsUsed) out of them. Baiting or throwing the cheaper move first may have cost you.")
        }

        // Order of your faints, real versus sim.
        let realFaints = battle.events.filter { $0.kind == .faint && $0.mine }.compactMap(\.speciesId)
        var simFaints: [String] = []
        for segment in simLog.segments where segment.log.hpA <= 0 && teamNames.indices.contains(segment.indexA) {
            simFaints.append(teamNames[segment.indexA])
        }
        if let first = realFaints.first, let simFirst = simFaints.first,
           let real = battle.team.firstIndex(where: { $0.speciesId == first }),
           teamNames.indices.contains(real), teamNames[real] != simFirst {
            out.append("Your \(teamNames[real]) went down first; in the sim it's \(simFirst).")
        } else if simFaints.isEmpty, !realFaints.isEmpty {
            out.append("The sim loses none of your Pokémon, while you lost \(realFaints.count).")
        }

        let theirThrows = battle.events.filter { $0.kind == .charged && !$0.mine }.count
        if theirThrows >= 3, myShieldsUsed < 2 {
            out.append("They threw \(theirThrows) charged moves and you used \(myShieldsUsed) shield\(myShieldsUsed == 1 ? "" : "s") — check where shielding could have saved HP.")
        }
        return out
    }

    /// What decided a game the sim loses too.
    private static func matchupProblems(simLog: TeamBattleLog, simLine: [String]) -> [String] {
        var out: [String] = []
        if let first = simLine.first(where: { $0.hasPrefix("Their") }) {
            out.append("First Pokémon lost in the sim: \(first.lowercased()).")
        }
        let result = simLog.result
        if result.survivorsB > 0 {
            out.append("The sim ends with \(result.survivorsB) of their Pokémon standing against your \(result.survivorsA).")
        }
        return out
    }

    /// One line per 1v1 stretch: who beat whom.
    private static func line(of log: TeamBattleLog, teamNames: [String], opponentNames: [String]) -> [String] {
        log.segments.compactMap { segment in
            guard teamNames.indices.contains(segment.indexA), opponentNames.indices.contains(segment.indexB) else { return nil }
            let a = teamNames[segment.indexA], b = opponentNames[segment.indexB]
            if segment.log.hpA <= 0 { return "Their \(b) beat your \(a)" }
            if segment.log.hpB <= 0 { return "Your \(a) beat their \(b)" }
            return "\(a) vs \(b) — time ran out"
        }
    }
}
