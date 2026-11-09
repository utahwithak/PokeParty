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
    private let mlp: PolicyMLP

    typealias LoadError = PolicyMLP.LoadError

    init(contentsOf url: URL) throws {
        mlp = try PolicyMLP(contentsOf: url, expectedFeatures: FarmObservation.featureNames)
    }

    /// Raw [don't farm, farm] logits for one observation.
    func logits(_ x: [Double]) -> [Double] { mlp.forward(x) }

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
