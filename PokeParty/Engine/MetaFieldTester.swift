//
//  MetaFieldTester.swift
//  PokeParty
//
//  Battles a fixed, user-built team against a randomly generated field of
//  meta-team opponents using the full 3v3 engine (`ThreeVThreeBattle`) — the
//  "Test Against Meta" action in the Team Builder. Unlike
//  `TeamOptimizer.evaluateBroadField` (which validates the optimizer's own
//  hill-climbed teams against a broad field), the team under test here comes
//  from the Team Builder as-is; only the opponent field is generated.
//

import Foundation

nonisolated enum MetaFieldTester {

    /// One generated opponent and how the user's team fared against it, once
    /// per possible lead of the user's team.
    struct OpponentResult: Identifiable, Sendable {
        let poolIndices: [Int]
        let members: [TeamFinder.RankedTeam.Member]
        /// Outcome from the user's team's perspective, indexed by which of
        /// the user's members led.
        let outcomesByLead: [TeamBattleResult.Winner]
        let ratingByLead: [Int]

        var id: String { poolIndices.map(String.init).joined(separator: "+") }
    }

    struct Results: Sendable {
        var opponents: [OpponentResult]
        var fieldSize: Int
        var completed: Int
        var total: Int
        var isComplete: Bool

        /// Win rate for the given lead slot across every opponent tested so far.
        func winRate(forLead lead: Int) -> Double {
            var wins = 0.0
            var games = 0
            for opp in opponents where opp.outcomesByLead.indices.contains(lead) {
                games += 1
                switch opp.outcomesByLead[lead] {
                case .teamA: wins += 1
                case .tie: wins += 0.5
                case .teamB: break
                }
            }
            return games > 0 ? wins / Double(games) : 0
        }

        /// The lead slot with the best win rate so far, or nil before any
        /// opponent has finished.
        var bestLead: Int? {
            guard let leadCount = opponents.first?.outcomesByLead.count, leadCount > 0 else { return nil }
            return (0..<leadCount).max { winRate(forLead: $0) < winRate(forLead: $1) }
        }
    }

    /// Battles `yourTeam` (fixed, in lead order) against a randomly generated
    /// field of up to `fieldSize` opponent trios drawn from `pool`, once per
    /// possible lead of `yourTeam` (the opponent always leads with its first
    /// member). `onResults` streams progressively, one call per completed
    /// opponent, so the UI can render results as they arrive.
    static func run(
        yourTeam: [BattlePokemon],
        pool: [TeamFinder.Candidate],
        fieldSize: Int,
        movesById: [String: Move],
        learnedShields: Bool = true,
        learnedSwitches: Bool = true,
        learnedFarming: Bool = true,
        onProgress: (@Sendable (Double) -> Void)? = nil,
        onResults: (@Sendable (Results) -> Void)? = nil
    ) async -> Results {
        let empty = Results(opponents: [], fieldSize: 0, completed: 0, total: 0, isComplete: true)
        guard !yourTeam.isEmpty else { return empty }

        let field = TeamFinder.randomField(pool: pool, size: fieldSize)
        guard !field.isEmpty else { return empty }

        let shieldNet = learnedShields ? ShieldPolicyNet.bundled : nil
        let switchNet = learnedSwitches ? SwitchPolicyNet.bundled : nil
        let farmNet = learnedFarming ? FarmPolicyNet.bundled : nil

        var results: [OpponentResult] = []
        var completed = 0
        let total = field.count

        onResults?(Results(opponents: [], fieldSize: field.count, completed: 0, total: total, isComplete: false))

        await withTaskGroup(of: OpponentResult?.self) { group in
            for trio in field {
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    let oppMembers = trio.map { pool[$0] }
                    guard let oppTeam = makeBattleTeam(oppMembers, movesById: movesById) else { return nil }

                    var outcomes: [TeamBattleResult.Winner] = []
                    var ratings: [Int] = []
                    outcomes.reserveCapacity(yourTeam.count)
                    ratings.reserveCapacity(yourTeam.count)
                    for lead in 0..<yourTeam.count {
                        if Task.isCancelled { break }
                        var battle = ThreeVThreeBattle(
                            teamA: yourTeam, teamB: oppTeam,
                            leadA: lead, leadB: 0,
                            switchPolicy: .bestMatchup,
                            optimalShields: false,
                            voluntarySwitching: true,
                            learnedShieldNet: shieldNet)
                        if let switchNet { battle.switchDecisionHook = { switchNet.decide($0) } }
                        battle.applyFarmNet(farmNet)
                        let result = battle.run()
                        outcomes.append(result.winner)
                        ratings.append(result.ratingA)
                    }
                    guard outcomes.count == yourTeam.count else { return nil }
                    return OpponentResult(
                        poolIndices: trio,
                        members: oppMembers.map {
                            TeamFinder.RankedTeam.Member(
                                member: $0.member, speciesName: $0.speciesName,
                                types: $0.types, shadow: $0.shadow)
                        },
                        outcomesByLead: outcomes,
                        ratingByLead: ratings)
                }
            }
            for await result in group {
                completed += 1
                if let result { results.append(result) }
                onProgress?(Double(completed) / Double(max(total, 1)))
                onResults?(Results(
                    opponents: results, fieldSize: field.count,
                    completed: completed, total: total,
                    isComplete: completed == total))
            }
        }

        return Results(
            opponents: results, fieldSize: field.count,
            completed: completed, total: total, isComplete: true)
    }
}
