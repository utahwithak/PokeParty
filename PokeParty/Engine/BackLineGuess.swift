//
//  BackLineGuess.swift
//  PokeParty
//
//  Guesses what the opponent is hiding in the back from what they've shown.
//  Players build teams to cover their weaknesses, so a fire lead likely has
//  something that resists water and ground behind it. Unrevealed slots are
//  drawn from the meta pool, weighted by how popular a Pokémon is (its rank)
//  and by how well it covers the weaknesses of the Pokémon already on the
//  team. `BattleCoach` plays its rollouts against the same draws, and the HUD
//  shows the likeliest ones.
//

import Foundation

nonisolated enum BackLineGuess {

    /// One Pokémon the opponent is likely to be holding back.
    struct Prediction: Sendable, Identifiable {
        var id: String { speciesId }
        let speciesId: String
        let name: String
        /// Share of the sampled teams it appeared in (0…1).
        let likelihood: Double
        /// Types of the revealed Pokémon's weaknesses that it resists, if any
        /// (the reason it's a likely partner), e.g. ["water", "ground"].
        let covers: [String]
    }

    /// How strongly coverage steers the draw: each weakness covered multiplies a
    /// candidate's weight by e^`coverageStrength`.
    private static let coverageStrength = 0.35
    /// Weight multiplier bounds, so a perfect (or awful) fit sways the draw
    /// without overriding popularity entirely.
    private static let weightRange = 0.4...3.0

    // MARK: - Weighting

    /// Types that `team` (a list of each member's types) is weak to, with how many
    /// members are weak to each.
    private static func weaknesses(of team: [[String]]) -> [String: Int] {
        var result: [String: Int] = [:]
        for attack in TypeChart.allTypes {
            let count = team.filter { TypeChart.effectiveness(moveType: attack, targetTypes: $0) > 1.01 }.count
            if count > 0 { result[attack] = count }
        }
        return result
    }

    /// Attack types from `weak` that a Pokémon of `types` resists.
    private static func covered(by types: [String], weak: [String: Int]) -> [String] {
        weak.keys.sorted().filter { TypeChart.effectiveness(moveType: $0, targetTypes: types) < 0.99 }
    }

    /// Multiplier for adding a Pokémon of `types` to a team whose weaknesses are
    /// `weak`: up for each weakness it resists, down (half as much) for each
    /// it shares.
    private static func synergy(of types: [String], weak: [String: Int]) -> Double {
        var score = 0.0
        for (attack, count) in weak {
            let multiplier = TypeChart.effectiveness(moveType: attack, targetTypes: types)
            if multiplier < 0.99 { score += Double(count) } else if multiplier > 1.01 { score -= 0.5 * Double(count) }
        }
        let weight = exp(coverageStrength * score)
        return min(max(weight, weightRange.lowerBound), weightRange.upperBound)
    }

    // MARK: - Sampling

    /// Draws Pokémon from `pool` to fill a team that already holds `revealed`
    /// up to `teamSize`. Earlier-ranked Pokémon are likelier (weight
    /// 1/(rank + 5)), scaled by how well each covers the team's weaknesses as it
    /// stands. Species already revealed — or sharing a family — are skipped.
    static func fills(
        revealedIds: [String],
        revealedTypes: [[String]],
        teamSize: Int,
        pool: [TeamFinder.Candidate],
        using rng: inout SeededGenerator
    ) -> [TeamFinder.Candidate] {
        let revealedSet = Set(revealedIds)
        var available = pool.enumerated().filter { !revealedSet.contains($0.element.member.speciesId) }
        var fills: [TeamFinder.Candidate] = []
        var teamTypes = revealedTypes

        while revealedIds.count + fills.count < teamSize, !available.isEmpty {
            let weak = weaknesses(of: teamTypes)
            let weights = available.map { entry in
                (1.0 / Double(entry.offset + 5)) * synergy(of: entry.element.types, weak: weak)
            }
            var roll = Double.random(in: 0..<weights.reduce(0, +), using: &rng)
            var chosen = available.count - 1
            for (k, w) in weights.enumerated() {
                if roll < w { chosen = k; break }
                roll -= w
            }
            let pick = available.remove(at: chosen).element
            if fills.allSatisfy({ teamCandidatesDistinct($0, pick) }) {
                fills.append(pick)
                teamTypes.append(pick.types)
            }
        }
        return fills
    }

    // MARK: - Prediction

    /// The likeliest Pokémon in the back, given the (living) revealed ones.
    /// `slots` is how many unrevealed Pokémon the opponent still has.
    static func predict(
        revealedIds: [String],
        revealedTypes: [[String]],
        slots: Int,
        pool: [TeamFinder.Candidate],
        samples: Int = 300,
        limit: Int = 4,
        seed: UInt64 = 1
    ) -> [Prediction] {
        guard slots > 0, !pool.isEmpty, samples > 0 else { return [] }
        var rng = SeededGenerator(seed: seed)
        var counts: [String: Int] = [:]
        var byId: [String: TeamFinder.Candidate] = [:]
        for _ in 0..<samples {
            let drawn = fills(revealedIds: revealedIds, revealedTypes: revealedTypes,
                              teamSize: revealedIds.count + slots, pool: pool, using: &rng)
            for candidate in drawn {
                counts[candidate.member.speciesId, default: 0] += 1
                byId[candidate.member.speciesId] = candidate
            }
        }

        let weak = weaknesses(of: revealedTypes)
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .compactMap { id, count in
                guard let candidate = byId[id] else { return nil }
                return Prediction(speciesId: id, name: candidate.speciesName,
                                  likelihood: Double(count) / Double(samples),
                                  covers: covered(by: candidate.types, weak: weak))
            }
    }
}
