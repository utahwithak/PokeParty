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
    /// Matches the JSON written by rl/train_shield.py.
    private struct Weights: Decodable {
        let featureNames: [String]
        let hidden: Int
        let W1: [[Double]]   // [features][hidden]
        let b1: [Double]
        let W2: [[Double]]   // [hidden][hidden]
        let b2: [Double]
        let W3: [Double]     // [hidden]
        let b3: Double
    }

    private let w: Weights

    enum LoadError: Error { case featureMismatch }

    init(contentsOf url: URL) throws {
        w = try JSONDecoder().decode(Weights.self, from: Data(contentsOf: url))
        // The Swift feature extractor and the trained net must agree exactly.
        guard w.featureNames == ShieldObservation.featureNames else {
            throw LoadError.featureMismatch
        }
    }

    /// Raw score; > 0 means shield.
    func logit(_ x: [Double]) -> Double {
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
        for j in 0..<h { out += max(h2[j] + w.b2[j], 0) * w.W3[j] }
        return out
    }

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
