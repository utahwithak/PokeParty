//
//  SwitchPolicyNet.swift
//  PokeParty
//
//  RL milestone 2: inference for the learned 3v3 switch policy. A tiny MLP
//  (features → 64 → 64 → 3 action logits) trained by rl/train_switch.py against
//  rollout-search labels, exported as raw weights JSON (same hand-rolled
//  forward-pass approach as ShieldPolicyNet).
//
//  Actions are canonical: 0 = stay, 1 = first alive backup, 2 = second.
//  Illegal actions (per SwitchObservation.legalActions) are masked out.
//
//  Attach via `ThreeVThreeBattle.switchDecisionHook`:
//
//      battle.switchDecisionHook = { ctx in net.decide(ctx) }
//

import Foundation

nonisolated struct SwitchPolicyNet {
    private let mlp: PolicyMLP

    typealias LoadError = PolicyMLP.LoadError

    init(contentsOf url: URL) throws {
        mlp = try PolicyMLP(contentsOf: url, expectedFeatures: SwitchObservation.featureNames)
    }

    /// Raw action logits for one observation.
    func logits(_ x: [Double]) -> [Double] { mlp.forward(x) }

    /// The policy's decision: highest-logit legal action for this context.
    func decide(_ ctx: SwitchContext) -> SwitchDecision {
        let legal = SwitchObservation.legalActions(ctx)
        guard legal.count > 1 else {
            return legal.first.map { SwitchObservation.decision(for: $0, ctx) } ?? .heuristic
        }
        let z = logits(SwitchObservation.capture(ctx))
        var best = legal[0]
        for a in legal where z[a] > z[best] { best = a }
        return SwitchObservation.decision(for: best, ctx)
    }
}

nonisolated extension SwitchPolicyNet {
    /// The policy weights shipped with the app (nil when the resource is absent,
    /// e.g. in the bench/rl CLI builds, or if the file fails validation).
    static let bundled: SwitchPolicyNet? = {
        guard let url = Bundle.main.url(forResource: "switch_policy", withExtension: "json")
        else { return nil }
        return try? SwitchPolicyNet(contentsOf: url)
    }()
}
