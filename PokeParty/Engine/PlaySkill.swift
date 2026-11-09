//
//  PlaySkill.swift
//  PokeParty
//
//  The sims play both sides without mistakes, so a team that only wins when every
//  swap is perfect looks as good as one that wins even when you slip. `PlaySkill`
//  models a fallible player: at each switch decision (voluntary swaps and which
//  Pokémon replaces a faint) the player takes a random legal action instead of
//  their normal choice with probability `mistakeRate`. Measured on random teams:
//  win rate falls smoothly as the rate grows (0.50 → 0.38 at 50%), and teams
//  differ a lot in how much they lose.
//
//  Only the player's side (team A) is degraded; the opposing field keeps playing
//  normally. Shield play is left alone — it barely moves outcomes.
//

import Foundation

/// How well the player is assumed to play when scoring teams.
nonisolated enum PlaySkill: Int, CaseIterable, Codable, Sendable {
    case perfect, good, casual, beginner

    /// Chance that any one switch decision is replaced by a random legal action.
    var mistakeRate: Double {
        switch self {
        case .perfect: 0
        case .good: 0.1
        case .casual: 0.25
        case .beginner: 0.5
        }
    }

    var title: String {
        switch self {
        case .perfect: "Perfect"
        case .good: "Good"
        case .casual: "Casual"
        case .beginner: "Beginner"
        }
    }

    var detail: String {
        switch self {
        case .perfect:
            "Never makes a mistake — the classic result. Favors teams that need perfect swaps and timing."
        case .good:
            "Slips on about 1 in 10 switch decisions."
        case .casual:
            "Slips on about 1 in 4 switch decisions. Favors teams that stay strong when you play them imperfectly."
        case .beginner:
            "Slips on about half of switch decisions. Strongly favors forgiving, easy-to-pilot teams."
        }
    }

    /// Noisy rollouts averaged into one matchup outcome when mistakes are on, so a
    /// single unlucky slip doesn't decide a matchup.
    static let rolloutsPerMatchup = 3

    /// Wraps `base` (the player's normal switch brain) so each decision is replaced,
    /// with probability `mistakeRate`, by a random legal action. Deterministic for a
    /// given `seed`, so memoized results stay exact. Use one wrapper per battle.
    static func fallible(
        base: @escaping (SwitchContext) -> SwitchDecision,
        mistakeRate: Double,
        seed: UInt64
    ) -> (SwitchContext) -> SwitchDecision {
        guard mistakeRate > 0 else { return base }
        let rng = SkillRNG(seed: seed)
        return { ctx in
            // Always draw both values so the stream doesn't depend on which branch ran.
            let roll = rng.nextUnit()
            let pick = rng.next()
            guard roll < mistakeRate else { return base(ctx) }
            let legal = SwitchObservation.legalActions(ctx)
            guard !legal.isEmpty else { return .heuristic }
            return SwitchObservation.decision(for: legal[Int(pick % UInt64(legal.count))], ctx)
        }
    }

    /// Mixes small integers into one well-spread seed (SplitMix64 finalizer).
    static func seed(_ parts: Int...) -> UInt64 {
        var z: UInt64 = 0x9E37_79B9_7F4A_7C15
        for part in parts {
            z = (z ^ UInt64(truncatingIfNeeded: part)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
        }
        return z
    }
}

/// Tiny seeded generator (SplitMix64) — reference type so the decision closure can
/// advance it.
nonisolated private final class SkillRNG {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
