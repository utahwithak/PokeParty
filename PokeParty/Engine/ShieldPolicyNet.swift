//
//  ShieldPolicyNet.swift
//  PokeParty
//
//  RL milestone 1: inference for the learned shield policy. A tiny MLP
//  (features → 64 → 64 → 1) trained by rl/train_shield.py against the
//  ShieldSearch oracle and exported as raw weights JSON — small enough that a
//  hand-rolled forward pass beats dragging in Core ML.
//
//  Attach to a battle via the `Battle.shieldPolicy` hook:
//
//      let net = try ShieldPolicyNet(contentsOf: url)
//      battle.shieldPolicy = { [unowned battle] d, o, move in
//          net.decide(ShieldObservation.capture(battle: battle, defenderIndex: d,
//                                               opportunity: o, move: move))
//      }
//

import Foundation

nonisolated struct ShieldPolicyNet {
    private let mlp: PolicyMLP

    typealias LoadError = PolicyMLP.LoadError

    init(contentsOf url: URL) throws {
        mlp = try PolicyMLP(contentsOf: url, expectedFeatures: ShieldObservation.featureNames)
    }

    /// Raw score; > 0 means shield.
    func logit(_ x: [Double]) -> Double { mlp.forward(x)[0] }

    /// The policy's shield decision for one observation.
    func decide(_ x: [Double]) -> Bool { logit(x) > 0 }
}

nonisolated extension ShieldPolicyNet {
    /// The policy weights shipped with the app (nil when the resource is absent,
    /// e.g. in the bench/rl CLI builds, or if the file fails validation).
    static let bundled: ShieldPolicyNet? = {
        guard let url = Bundle.main.url(forResource: "shield_policy", withExtension: "json")
        else { return nil }
        return try? ShieldPolicyNet(contentsOf: url)
    }()
}

nonisolated extension Battle {
    /// Drives both sides' shield decisions with the learned policy (a middle
    /// quality tier: near-ShieldSearch play at near-heuristic cost). Any
    /// `shieldOverride` still takes precedence.
    func useLearnedShieldPolicy(_ net: ShieldPolicyNet) {
        shieldPolicy = { [unowned self] d, o, move in
            net.decide(ShieldObservation.capture(
                battle: self, defenderIndex: d, opportunity: o, move: move))
        }
    }
}
