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

        /// A stable hash of the situation (FNV-1a), used to seed the opponent-team
        /// sampling. The same situation then always draws the same teams, so the
        /// advice can't flip just because the dice were re-rolled. HP is bucketed
        /// to tenths so bar-reading jitter doesn't count as a new situation.
        var fingerprint: UInt64 {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            func mix(_ value: UInt64) {
                hash = (hash ^ value) &* 0x0000_0100_0000_01B3
            }
            func mix(_ text: String) {
                for byte in text.utf8 { mix(UInt64(byte)) }
                mix(0xFF)
            }
            func mix(_ hp: [Int: Double]) {
                for key in hp.keys.sorted() { mix(UInt64(key)); mix(UInt64((hp[key] ?? 1) * 10 + 0.5)) }
                mix(0xFE)
            }
            for p in myTeam { mix(p.speciesId) }
            for p in opponentRevealed { mix(p.speciesId) }
            for value in [myActive, myShields, opponentActive, opponentShields, opponentTeamSize] { mix(UInt64(value)) }
            mix(myHP)
            mix(opponentHP)
            return hash
        }
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

    /// To change the recommendation (stay → switch, or switch → stay / another
    /// switch) the challenger must beat the standing one by at least this much of
    /// `Option.score` — below that it's within sampling noise, and a switch burns
    /// the switch timer. Applying it in both directions is what stops the tip
    /// flickering when the two options sit close together.
    static let switchMargin = 0.06
    /// Opponent teams sampled per run. Enough that, with the margin above, the
    /// gap between two options is mostly signal.
    static let defaultSamples = 48
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
        samples: Int = BattleCoach.defaultSamples,
        seed: UInt64? = nil,
        incumbent: Option.Action? = nil
    ) async -> Advice? {
        guard let options = actions(for: state), samples > 0 else { return nil }

        // Sampled up front so every option faces the same opponent teams — and
        // seeded from the situation, so the same situation gives the same advice.
        var rng = SeededGenerator(seed: seed ?? state.fingerprint)
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
                      opponentShields: state.opponentShields, incumbent: incumbent)
    }

    /// Turns scored options into the tip. Pure, so the decision rules are testable
    /// without running any battles. `options` must include the `.stay` option.
    ///
    /// `incumbent` is what the last tip for this same matchup recommended. It keeps
    /// the recommendation unless another option beats it by `switchMargin`; with
    /// no incumbent, staying in is the default to beat.
    static func advice(from options: [Option], samples: Int, myShields: Int, opponentShields: Int,
                       incumbent: Option.Action? = nil) -> Advice? {
        guard let stay = options.first(where: { $0.action == .stay }) else { return nil }
        let ranked = options.sorted { $0.score > $1.score }
        let shields = "\(myShields)–\(opponentShields) shields"

        let standing = incumbent.flatMap { action in options.first { $0.action == action } } ?? stay
        var chosen = standing
        if let best = ranked.first, best.action != standing.action, best.score - standing.score >= switchMargin {
            chosen = best
        }

        if chosen.action != .stay {
            let urgent = stay.winRate < urgentWinRate
            return Advice(
                headline: urgent ? "Switch to \(chosen.pokemonName) now" : "Switch to \(chosen.pokemonName)",
                detail: "\(percent(chosen.winRate)) win chance with \(chosen.pokemonName) vs \(percent(stay.winRate)) staying in \(stay.pokemonName) (\(shields)).",
                recommended: chosen, options: ranked, samples: samples)
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

    /// The revealed opponents plus draws from `pool` to fill the team to
    /// `teamSize` — popularity-weighted, favouring partners that cover the
    /// revealed Pokémon's weaknesses (see `BackLineGuess`).
    static func completedOpponentTeam(
        revealed: [BattlePokemon],
        teamSize: Int,
        pool: [TeamFinder.Candidate],
        movesById: [String: Move],
        using rng: inout SeededGenerator
    ) -> [BattlePokemon]? {
        var team = revealed
        guard team.count < teamSize else { return team }

        let fills = BackLineGuess.fills(
            revealedIds: revealed.map(\.speciesId), revealedTypes: revealed.map(\.types),
            teamSize: teamSize, pool: pool, using: &rng)
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
