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
    /// Matches the JSON written by rl/train_switch.py.
    private struct Weights: Decodable {
        let featureNames: [String]
        let hidden: Int
        let W1: [[Double]]   // [features][hidden]
        let b1: [Double]
        let W2: [[Double]]   // [hidden][hidden]
        let b2: [Double]
        let W3: [[Double]]   // [hidden][3]
        let b3: [Double]     // [3]
    }

    private let w: Weights

    enum LoadError: Error { case featureMismatch }

    init(contentsOf url: URL) throws {
        w = try JSONDecoder().decode(Weights.self, from: Data(contentsOf: url))
        guard w.featureNames == SwitchObservation.featureNames else {
            throw LoadError.featureMismatch
        }
    }

    /// Raw action logits for one observation.
    func logits(_ x: [Double]) -> [Double] {
        let h = w.hidden
        var h1 = [Double](repeating: 0, count: h)
        for i in x.indices {
            let xi = x[i]
            if xi == 0 { continue }
            let row = w.W1[i]
            for j in 0..<h { h1[j] += xi * row[j] }
        }
        for j in 0..<h { h1[j] = max(h1[j] + w.b1[j], 0) }

        var h2 = [Double](repeating: 0, count: h)
        for i in 0..<h {
            let hi = h1[i]
            if hi == 0 { continue }
            let row = w.W2[i]
            for j in 0..<h { h2[j] += hi * row[j] }
        }
        var out = w.b3
        for i in 0..<h {
            let a = max(h2[i] + w.b2[i], 0)
            if a == 0 { continue }
            let row = w.W3[i]
            for j in 0..<3 { out[j] += a * row[j] }
        }
        return out
    }

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
