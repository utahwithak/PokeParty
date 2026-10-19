//
//  MovesetSelector.swift
//  PokeParty
//
//  Local moveset auto-selection (M6.3) — for each species, picks the fast +
//  charged move combo that performs best against a small fixed probe set,
//  so the local Ranker has a "recommended moveset" per species without
//  reading PvPoke's `entry.moveset`. Run once per species before the
//  Ranker's expensive N×N matrix (mirrors PvPoke's own two-phase approach:
//  movesets are fixed first, then the matrix uses them as-is).
//

import Foundation

nonisolated enum MovesetSelector {

    struct Result: Sendable {
        let fastMoveId: String
        let chargedMoveIds: [String]
    }

    /// Builds the small opponent field every candidate moveset is scored
    /// against: the top `probeSize` of `pool` by raw stat product, each
    /// using its first-available moves (a naive, consistent — not
    /// necessarily optimal — moveset; good enough as a fixed yardstick since
    /// every candidate for every species is compared against the same
    /// field).
    /// `async` and parallelized because `statProduct` runs a full IV-optimal
    /// search per Pokémon (`IVCalculator.optimalStats`, an O(4096) sweep) —
    /// doing that inside a plain `sorted` comparator serialized it on
    /// whichever thread called this, which for pool sizes in the hundreds
    /// was long enough to visibly block the UI when called from a
    /// MainActor-affine task (see `LocalRankingBuilder`).
    static func probeSet(
        pool: [Pokemon], cpCap: Int, probeSize: Int = 50
    ) async -> [MatchupSimulator.Combatant] {
        let n = pool.count
        var products = [Double](repeating: 0, count: n)
        await BoundedParallel.run(count: n, of: (Int, Double).self) { i in
            (i, MetaPool.statProduct(for: pool[i], cpCap: cpCap))
        } consume: { i, product in
            products[i] = product
        }
        let rankedIndices = pool.indices.sorted { products[$0] > products[$1] }
        return rankedIndices.prefix(probeSize).compactMap { naiveCombatant(for: pool[$0]) }
    }

    /// The probe field as ready-to-battle sides (1 shield each, the Team
    /// Builder's default scenario). Build once per ranking run and share across
    /// every species' `select` — the IV-optimal stat sweep per probe member is
    /// far too expensive to repeat per species.
    static func preparedProbe(
        _ probe: [MatchupSimulator.Combatant], cpCap: Int, movesById: [String: Move]
    ) -> [BattlePokemon] {
        probe.compactMap { opponent in
            guard let stats = MatchupSimulator.optimalStats(for: opponent, cpCap: cpCap) else { return nil }
            return MatchupSimulator.makeBattlePokemon(
                opponent, stats: stats, movesById: movesById, shields: 1)
        }
    }

    /// The best-scoring fast/charged combo for `species` against `probe`
    /// (1 shield each, matching the Team Builder's default scenario), or
    /// `nil` if the species has no usable moves at all.
    static func select(
        species: Pokemon, shadow: Bool, cpCap: Int,
        probe: [MatchupSimulator.Combatant], movesById: [String: Move]
    ) -> Result? {
        select(
            species: species, shadow: shadow, cpCap: cpCap,
            preparedProbe: preparedProbe(probe, cpCap: cpCap, movesById: movesById),
            movesById: movesById)
    }

    static func select(
        species: Pokemon, shadow: Bool, cpCap: Int,
        preparedProbe: [BattlePokemon], movesById: [String: Move]
    ) -> Result? {
        guard let stats = MatchupSimulator.optimalStats(
            for: .init(species: species, shadow: shadow, fastMoveId: "", chargedMoveIds: []),
            cpCap: cpCap
        ) else { return nil }

        let candidates = candidateMovesets(for: species)
        guard !candidates.isEmpty else { return nil }

        var best: Result?
        var bestScore = -Double.infinity

        for candidate in candidates {
            let combatant = MatchupSimulator.Combatant(
                species: species, shadow: shadow,
                fastMoveId: candidate.fastMoveId, chargedMoveIds: candidate.chargedMoveIds)
            guard let me = MatchupSimulator.makeBattlePokemon(
                combatant, stats: stats, movesById: movesById, shields: 1)
            else { continue }

            var total = 0.0
            for opponent in preparedProbe {
                total += Double(MatchupSimulator.rate(prepared: me, opponent).a)
            }
            guard !preparedProbe.isEmpty else { continue }
            let score = total / Double(preparedProbe.count)
            if score > bestScore {
                bestScore = score
                best = candidate
            }
        }
        return best
    }

    // MARK: - Candidate generation

    /// Every fast move × (single charged move, or unordered pair of charged
    /// moves) combo a species can legally run. Elite/legacy moves are
    /// already included in `fastMoves`/`chargedMoves` (they're annotations
    /// on an already-listed move, not a separate pool — see
    /// `Pokemon.moveDesignation`), so no extra move sources are needed.
    private static func candidateMovesets(for species: Pokemon) -> [Result] {
        guard !species.fastMoves.isEmpty else { return [] }
        var chargedCombos: [[String]] = []
        let charged = species.chargedMoves
        if charged.count <= 1 {
            chargedCombos = charged.map { [$0] }
        } else {
            for i in 0..<charged.count {
                for j in (i + 1)..<charged.count {
                    chargedCombos.append([charged[i], charged[j]])
                }
            }
        }
        guard !chargedCombos.isEmpty else { return [] }

        var results: [Result] = []
        for fast in species.fastMoves {
            for combo in chargedCombos {
                results.append(Result(fastMoveId: fast, chargedMoveIds: combo))
            }
        }
        return results
    }

    /// First-available moveset — used only to populate the probe set's
    /// opponents, never as the selector's own output.
    private static func naiveCombatant(for species: Pokemon) -> MatchupSimulator.Combatant? {
        guard let fast = species.fastMoves.first, !species.chargedMoves.isEmpty else { return nil }
        let (resolved, shadow) = (species, species.isShadow)
        return .init(species: resolved, shadow: shadow, fastMoveId: fast,
                     chargedMoveIds: Array(species.chargedMoves.prefix(2)))
    }
}
