//
//  PolicyMLP.swift
//  PokeParty
//
//  Shared inference core for the learned policies (ShieldPolicyNet,
//  SwitchPolicyNet, FarmPolicyNet): features → hidden → hidden → outputs, ReLU
//  between layers, weights exported by rl/train_*.py as raw JSON. Weights are
//  stored flat (row-major) so a forward pass touches contiguous memory with no
//  per-row array retain/release; the summation order matches the original
//  nested-array loops, so outputs are bit-identical.
//

import Foundation

nonisolated struct PolicyMLP {
    /// Matches the JSON written by rl/train_*.py. The output layer is a single
    /// vector / scalar for one-output nets (shield) and a matrix / vector for
    /// multi-output nets (switch, farm).
    private struct Weights: Decodable {
        let featureNames: [String]
        let hidden: Int
        let W1: [[Double]]   // [features][hidden]
        let b1: [Double]
        let W2: [[Double]]   // [hidden][hidden]
        let b2: [Double]
        let W3: OneOrMany<[Double]>   // [hidden] or [hidden][outputs]
        let b3: OneOrMany<Double>     // scalar or [outputs]
    }

    /// Decodes either a single `T` or an array of `T`.
    private struct OneOrMany<T: Decodable>: Decodable {
        let values: [T]
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let many = try? c.decode([T].self) {
                values = many
            } else {
                values = [try c.decode(T.self)]
            }
        }
    }

    enum LoadError: Error { case featureMismatch, malformed }

    let featureNames: [String]
    private let inputs: Int
    private let hidden: Int
    private let outputs: Int
    private let w1: [Double], b1: [Double]
    private let w2: [Double], b2: [Double]
    private let w3: [Double], b3: [Double]

    init(contentsOf url: URL, expectedFeatures: [String]) throws {
        let raw = try JSONDecoder().decode(Weights.self, from: Data(contentsOf: url))
        // The Swift feature extractor and the trained net must agree exactly.
        guard raw.featureNames == expectedFeatures else { throw LoadError.featureMismatch }

        let h = raw.hidden
        // Normalise both output layouts to [hidden][outputs].
        let rows3: [[Double]]
        if let first = raw.W3.values.first, first.count == h, raw.b3.values.count == 1,
           raw.W3.values.count == 1 {
            // Shield layout: W3 is a bare [hidden] vector, decoded as one row.
            rows3 = first.map { [$0] }
        } else {
            rows3 = raw.W3.values
        }
        let outs = raw.b3.values.count
        guard rows3.count == h, rows3.allSatisfy({ $0.count == outs }),
              raw.W1.allSatisfy({ $0.count == h }), raw.W1.count == expectedFeatures.count,
              raw.W2.count == h, raw.W2.allSatisfy({ $0.count == h }),
              raw.b1.count == h, raw.b2.count == h
        else { throw LoadError.malformed }

        featureNames = raw.featureNames
        inputs = raw.W1.count
        hidden = h
        outputs = outs
        w1 = raw.W1.flatMap { $0 }
        b1 = raw.b1
        w2 = raw.W2.flatMap { $0 }
        b2 = raw.b2
        w3 = rows3.flatMap { $0 }
        b3 = raw.b3.values
    }

    /// Raw output-layer values for one observation.
    func forward(_ x: [Double]) -> [Double] {
        let h = hidden, n = outputs
        var h1 = [Double](repeating: 0, count: h)
        var h2 = [Double](repeating: 0, count: h)
        var out = b3

        w1.withUnsafeBufferPointer { w1 in
        w2.withUnsafeBufferPointer { w2 in
        w3.withUnsafeBufferPointer { w3 in
            for i in 0..<min(x.count, inputs) {
                let xi = x[i]
                if xi == 0 { continue }
                let row = i * h
                for j in 0..<h { h1[j] += xi * w1[row + j] }
            }
            for j in 0..<h { h1[j] = max(h1[j] + b1[j], 0) }

            for i in 0..<h {
                let hi = h1[i]
                if hi == 0 { continue }
                let row = i * h
                for j in 0..<h { h2[j] += hi * w2[row + j] }
            }
            for i in 0..<h {
                let a = max(h2[i] + b2[i], 0)
                if a == 0 { continue }
                let row = i * n
                for j in 0..<n { out[j] += a * w3[row + j] }
            }
        }}}
        return out
    }
}
