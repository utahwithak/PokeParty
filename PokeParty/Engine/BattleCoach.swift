//
//  BattleCoach.swift
//  PokeParty
//
//  Live coaching from a blind, matchup-level view of a battle. The coach only
//  knows what the screen shows — each side's active Pokémon and shield count,
//  which of your Pokémon are still alive, and which opponents have been
//  revealed — not HP or energy. So it asks one question: from here, which of
//  your Pokémon is best to have in? Each option (stay, or switch to a bench
//  Pokémon) is played out through the full 3v3 engine, with the same learned
//  shield / switch / farm policies the Party Finder uses, against opponent
//  teams completed by sampling the unrevealed slots from the meta.
//
//  Tip kinds beyond stay / switch (throw-then-swap, shield advice) build on the
//  same candidate-and-rollout loop and are not wired in yet.
//

import Foundation

nonisolated enum BattleCoach {

    /// What the screen currently shows, as battle-ready Pokémon.
    struct State: Sendable {
        /// Your Pokémon that are still alive, in team order.
        var myTeam: [BattlePokemon]
        /// Index into `myTeam` of the Pokémon on the field.
        var myActive: Int
        var myShields: Int
        /// Opponent Pokémon seen so far, in the order they were revealed.
        var opponentRevealed: [BattlePokemon]
        /// Index into `opponentRevealed` of the opponent's Pokémon on the field.
        var opponentActive: Int
        var opponentShields: Int
        /// How many Pokémon the opponent still has, revealed or not. Unrevealed
        /// slots are filled up to this size.
        var opponentTeamSize = 3
        /// HP left (0…1) for Pokémon whose health is known, by index into
        /// `myTeam` / `opponentRevealed`. Unlisted Pokémon are at full HP.
        var myHP: [Int: Double] = [:]
        var opponentHP: [Int: Double] = [:]
    }

    /// One thing you could do, and how the rollouts say it works out.
    struct Option: Sendable, Equatable {
        enum Action: Sendable, Equatable {
            case stay
            case switchTo(Int)      // index into `State.myTeam`
        }
        let action: Action
        /// Index into `State.myTeam` of the Pokémon on the field after the action.
        let pokemonIndex: Int
        let pokemonName: String
        /// Wins plus half of ties, over the sampled opponent teams (0…1).
        let winRate: Double
        /// Mean 3v3 battle rating from your side (0…1000, 500 = even).
        let averageRating: Double

        /// Blend used to rank options. The rating breaks near-ties in win rate
        /// and smooths out sampling noise.
        var score: Double { winRate * 0.75 + (averageRating / 1000) * 0.25 }
    }

    struct Advice: Sendable {
        /// Large, glanceable instruction — "Switch to Azumarill".
        let headline: String
        /// One line of why, with the numbers.
        let detail: String
        /// The recommended option (the `stay` one when no switch is clearly better).
        let recommended: Option
        /// Every option considered, best first.
        let options: [Option]
        /// How many opponent teams the rollouts were averaged over.
        let samples: Int
    }

    /// A switch must beat staying in by at least this much of `Option.score`
    /// to be worth recommending — below that it's within sampling noise, and a
    /// switch burns the switch timer.
    static let switchMargin = 0.06
    /// Staying in below this win rate reads as urgent: "now", not just "switch".
    static let urgentWinRate = 0.35

    // MARK: - Evaluating

    /// Plays every option against `samples` plausible opponent teams and
    /// returns the advice, or nil if the state can't be simulated.
    /// `pool` supplies the unrevealed opponent slots, drawn rank-weighted
    /// (earlier = more likely). Pass `seed` for reproducible sampling.
    static func advise(
        _ state: State,
        pool: [TeamFinder.Candidate],
        movesById: [String: Move],
        samples: Int = 24,
        seed: UInt64? = nil
    ) async -> Advice? {
        guard let options = actions(for: state), samples > 0 else { return nil }

        // Sampled up front so every option faces the same opponent teams.
        var rng = SeededGenerator(seed: seed ?? UInt64.random(in: .min ... .max))
        var opponents: [[BattlePokemon]] = []
        for _ in 0..<samples {
            guard let team = completedOpponentTeam(
                revealed: state.opponentRevealed, teamSize: state.opponentTeamSize,
                pool: pool, movesById: movesById, using: &rng)
            else { return nil }
            opponents.append(team)
        }

        let shieldNet = ShieldPolicyNet.bundled
        let switchNet = SwitchPolicyNet.bundled
        let farmNet = FarmPolicyNet.bundled

        // results[sample][option] = (winner score, rating)
        let results: [[(Double, Double)]] = await withTaskGroup(of: (Int, [(Double, Double)]).self) { group in
            for (i, opponentTeam) in opponents.enumerated() {
                group.addTask {
                    // A superseded run (the screen moved on) shouldn't burn CPU finishing.
                    guard !Task.isCancelled else { return (i, []) }
                    var row: [(Double, Double)] = []
                    for option in options {
                        var battle = ThreeVThreeBattle(
                            teamA: state.myTeam, teamB: opponentTeam,
                            leadA: option.index, leadB: state.opponentActive,
                            shieldsA: state.myShields, shieldsB: state.opponentShields,
                            switchPolicy: .bestMatchup,
                            optimalShields: false,
                            voluntarySwitching: true,
                            learnedShieldNet: shieldNet)
                        battle.startingHpFractionA = state.myHP
                        battle.startingHpFractionB = state.opponentHP
                        if let switchNet { battle.switchDecisionHook = { switchNet.decide($0) } }
                        battle.applyFarmNet(farmNet)
                        let r = battle.run()
                        let win: Double
                        switch r.winner {
                        case .teamA: win = 1
                        case .tie: win = 0.5
                        case .teamB: win = 0
                        }
                        row.append((win, Double(r.ratingA)))
                    }
                    return (i, row)
                }
            }
            var collected = [[(Double, Double)]](repeating: [], count: opponents.count)
            for await (i, row) in group { collected[i] = row }
            return collected
        }
        if Task.isCancelled { return nil }

        var scored: [Option] = []
        for (k, option) in options.enumerated() {
            let wins = results.reduce(0.0) { $0 + $1[k].0 }
            let ratings = results.reduce(0.0) { $0 + $1[k].1 }
            scored.append(Option(
                action: option.action, pokemonIndex: option.index,
                pokemonName: state.myTeam[option.index].speciesName,
                winRate: wins / Double(samples),
                averageRating: ratings / Double(samples)))
        }
        return advice(from: scored, samples: samples, myShields: state.myShields,
                      opponentShields: state.opponentShields)
    }

    /// Turns scored options into the tip. Pure, so the decision rules are testable
    /// without running any battles. `options` must include the `.stay` option.
    static func advice(from options: [Option], samples: Int, myShields: Int, opponentShields: Int) -> Advice? {
        guard let stay = options.first(where: { $0.action == .stay }) else { return nil }
        let ranked = options.sorted { $0.score > $1.score }
        let shields = "\(myShields)–\(opponentShields) shields"

        if let best = ranked.first, best.action != .stay, best.score - stay.score >= switchMargin {
            let urgent = stay.winRate < urgentWinRate
            return Advice(
                headline: urgent ? "Switch to \(best.pokemonName) now" : "Switch to \(best.pokemonName)",
                detail: "\(percent(best.winRate)) win chance with \(best.pokemonName) vs \(percent(stay.winRate)) staying in \(stay.pokemonName) (\(shields)).",
                recommended: best, options: ranked, samples: samples)
        }
        return Advice(
            headline: "Stay in with \(stay.pokemonName)",
            detail: "No switch beats it clearly — \(percent(stay.winRate)) win chance (\(shields)).",
            recommended: stay, options: ranked, samples: samples)
    }

    // MARK: - Helpers

    private struct Plan { let action: Option.Action; let index: Int }

    /// Stay, plus a switch to each other living Pokémon of yours.
    private static func actions(for state: State) -> [Plan]? {
        guard state.myTeam.indices.contains(state.myActive),
              state.opponentRevealed.indices.contains(state.opponentActive)
        else { return nil }
        var result = [Plan(action: .stay, index: state.myActive)]
        for i in state.myTeam.indices where i != state.myActive {
            result.append(Plan(action: .switchTo(i), index: i))
        }
        return result
    }

    /// The revealed opponents plus rank-weighted draws from `pool` to fill the
    /// team to `teamSize`, skipping species already revealed (or sharing a family).
    private static func completedOpponentTeam(
        revealed: [BattlePokemon],
        teamSize: Int,
        pool: [TeamFinder.Candidate],
        movesById: [String: Move],
        using rng: inout SeededGenerator
    ) -> [BattlePokemon]? {
        var team = revealed
        guard team.count < teamSize else { return team }

        let revealedIds = Set(revealed.map(\.speciesId))
        var available = pool.enumerated().filter { !revealedIds.contains($0.element.member.speciesId) }
        var fills: [TeamFinder.Candidate] = []
        while team.count + fills.count < teamSize, !available.isEmpty {
            // Weight 1/(rank + 5): top picks are likelier without drowning the rest.
            let weights = available.map { 1.0 / Double($0.offset + 5) }
            var roll = Double.random(in: 0..<weights.reduce(0, +), using: &rng)
            var chosen = available.count - 1
            for (k, w) in weights.enumerated() {
                if roll < w { chosen = k; break }
                roll -= w
            }
            let pick = available.remove(at: chosen).element
            if fills.allSatisfy({ teamCandidatesDistinct($0, pick) }) { fills.append(pick) }
        }
        guard let filled = makeBattleTeam(fills, movesById: movesById) else {
            return fills.isEmpty ? team : nil
        }
        team.append(contentsOf: filled)
        return team
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

/// SplitMix64: a tiny seedable generator so rollouts can be reproduced.
nonisolated struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
