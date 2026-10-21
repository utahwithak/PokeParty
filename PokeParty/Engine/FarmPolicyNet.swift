//
//  FarmPolicyNet.swift
//  PokeParty
//
//  Learned "farm vs switch now" policy. Farming (see `ThreeVThreeBattle.farming`)
//  is only offered when the engine's safety gate passes — the opponent can't
//  afford a charged move yet and can't chip us much — so this net only answers
//  the strategic question: bank energy for a window, or take the switch now?
//
//  A tiny MLP (switch features + window → 64 → 64 → 2 logits: 0 = don't farm,
//  1 = farm) trained by rl/train_farm.py against rollout-search labels, exported
//  as raw weights JSON (same hand-rolled forward pass as SwitchPolicyNet).
//
//  Attach via `ThreeVThreeBattle.farmDecisionHook`:
//
//      battle.farmDecisionHook = { ctx, window in net.shouldFarm(ctx, window: window) }
//

import Foundation

nonisolated enum FarmObservation {
    /// The switch observation plus the proposed farm window (shared with
    /// rl/train_farm.py via metadata).
    static let featureNames: [String] = SwitchObservation.featureNames + ["farm_window_frac"]

    /// Longest window the engine proposes (`ThreeVThreeBattle.maxFarmMs`).
    private static let maxWindowMs = 10_000.0

    static func capture(_ ctx: SwitchContext, window: Int) -> [Double] {
        var x = SwitchObservation.capture(ctx)
        x.append(min(Double(window) / maxWindowMs, 1))
        return x
    }
}

nonisolated struct FarmPolicyNet {
    /// Matches the JSON written by rl/train_farm.py.
    private struct Weights: Decodable {
        let featureNames: [String]
        let hidden: Int
        let W1: [[Double]]   // [features][hidden]
        let b1: [Double]
        let W2: [[Double]]   // [hidden][hidden]
        let b2: [Double]
        let W3: [[Double]]   // [hidden][2]
        let b3: [Double]     // [2]
    }

    private let w: Weights

    enum LoadError: Error { case featureMismatch }

    init(contentsOf url: URL) throws {
        w = try JSONDecoder().decode(Weights.self, from: Data(contentsOf: url))
        guard w.featureNames == FarmObservation.featureNames else {
            throw LoadError.featureMismatch
        }
    }

    /// Raw [don't farm, farm] logits for one observation.
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
            for j in 0..<2 { out[j] += a * row[j] }
        }
        return out
    }

    /// True when the policy prefers farming this window over switching now.
    func shouldFarm(_ ctx: SwitchContext, window: Int) -> Bool {
        let z = logits(FarmObservation.capture(ctx, window: window))
        return z[1] > z[0]
    }
}

nonisolated extension FarmPolicyNet {
    /// The farm policy shipped with the app (nil when the resource is absent —
    /// the engine's safety gate alone then decides — or fails validation).
    static let bundled: FarmPolicyNet? = {
        guard let url = Bundle.main.url(forResource: "farm_policy", withExtension: "json")
        else { return nil }
        return try? FarmPolicyNet(contentsOf: url)
    }()
}
