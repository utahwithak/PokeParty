//
//  TeamAnalyzer.swift
//  PokeParty
//
//  Milestone 1 of the 3v3 work (see docs/TeamBuilder-Plan.md §2).
//
//  This is the "Team Builder" as it exists on pvpoke.com: it grades ONE team of
//  three by running each meta Pokémon 1v1 against each team member and
//  aggregating a threat matrix. It reuses the existing 1v1 `Battle` engine via
//  `MatchupSimulator` — there is NO 3v3 switching here (that is Milestone 2+).
//
//  The grade formulas, thresholds and the threat/alternative score transforms are
//  ported from PvPoke (TeamInterface.js / TeamRanker.js / Pokemon.js). Where a
//  piece is an approximation for this first increment it is marked APPROX / TODO.
//

import Foundation

// MARK: - Result types

enum LetterGrade: String, Hashable {
    case a = "A", b = "B", c = "C", d = "D", f = "F"

    /// PvPoke's `calculateLetterGrade(value, goal)`: pure `value / goal`.
    /// A ≥ .9, B ≥ .8, C ≥ .7, D ≥ .6, else F (no +/-).
    static func grade(value: Double, goal: Double) -> LetterGrade {
        guard goal > 0 else { return .f }
        let p = value / goal
        switch p {
        case _ where p >= 0.9: return .a
        case _ where p >= 0.8: return .b
        case _ where p >= 0.7: return .c
        case _ where p >= 0.6: return .d
        default: return .f
        }
    }
}

/// The four independent overview grades PvPoke shows for a team. There is no
/// single aggregate grade; `threatScore` is the one team-level scalar.
struct TeamGrades: Hashable {
    let coverage: LetterGrade
    let bulk: LetterGrade
    let safety: LetterGrade
    let consistency: LetterGrade

    /// Raw values behind each grade (for display / debugging).
    let coverageValue: Double
    let bulkValue: Double
    let safetyValue: Double
    let consistencyValue: Double

    /// Safety is provisional until the switches-category rankings are fetched
    /// (plan §2.9 / M1.8). When true the Safety grade uses placeholder data.
    let safetyProvisional: Bool
}

/// A meta Pokémon that threatens the team, with its per-member results.
struct ThreatEntry: Identifiable, Hashable {
    let speciesId: String
    let speciesName: String
    let types: [String]
    let shadow: Bool
    /// Threat's battle rating vs each team member, in member order (0–1000).
    let ratings: [Int]
    /// Mean raw rating across the members (feeds the coverage/threat score).
    let averageRating: Int
    /// Softened, meta-weighted ranking score used to order threats.
    let score: Double

    var id: String { speciesId }
}

/// A recommended teammate that helps cover the team's top threats.
struct SuggestionEntry: Identifiable, Hashable {
    let speciesId: String
    let speciesName: String
    let types: [String]
    let shadow: Bool
    let score: Double

    var id: String { speciesId }
}

/// The full analysis of one team against a format's meta.
struct TeamAnalysis: Hashable {
    let grades: TeamGrades
    /// avgThreatScore — mean raw rating of the top-6 distinct threats (higher = worse).
    let threatScore: Int
    let threats: [ThreatEntry]
    let suggestions: [SuggestionEntry]
    /// Display names of the members, in the order threat `ratings` are indexed.
    let memberNames: [String]
}

// MARK: - Meta candidate

/// A meta Pokémon considered as a threat / teammate candidate. Sendable so the
/// analysis can fan out across cores.
struct MetaCandidate: Sendable, Hashable {
    let species: Pokemon
    let shadow: Bool
    let fastMoveId: String
    let chargedMoveIds: [String]
    let familyId: String?
    /// Whether this mon is "meta relevant" (drives PvPoke's 0.85 weighting).
    /// APPROX: we treat the top slice of the ranking list as the meta group.
    let metaRelevant: Bool

    var combatant: MatchupSimulator.Combatant {
        .init(species: species, shadow: shadow,
              fastMoveId: fastMoveId, chargedMoveIds: chargedMoveIds)
    }
}

// MARK: - Analyzer

enum TeamAnalyzer {

    /// League bulk goals: mean(effectiveDef × hp). Indexed by CP cap. (plan §2.5)
    private static func bulkGoal(cpCap: Int) -> Double {
        switch cpCap {
        case 1500: return 22000
        case 2500: return 35000     // NOTE: Premier cups use 33000 (not handled here yet)
        case 500:  return 10000
        default:   return 35000     // 10000 (Master) and anything else
        }
    }

    /// PvPoke's threat/alternative score transform + meta weighting (plan §2.3).
    /// `nonisolated` so it can be called from the parallel sim tasks.
    private nonisolated static func softScore(_ rating: Double, metaRelevant: Bool) -> Double {
        var s: Double
        if rating > 500 {
            s = 500 + pow(rating - 500, 0.75)   // compress wins
        } else {
            s = rating / 2                        // halve losses
        }
        if s > 500 {
            if metaRelevant {
                s += (1000 - s) * 0.85
            } else {
                s -= (s - 500) * (1 - 0.85)
            }
        }
        return s
    }

    /// Analyze a team against the given meta. Runs off the main actor and fans
    /// the 1v1 sims out across all cores.
    ///
    /// - Parameters:
    ///   - team: the (≤3) team members as combatants, in display order.
    ///   - teamStats: precomputed optimal stats for each member (same order).
    ///   - meta: the eligible meta pool (ranking list) as candidates.
    ///   - cpCap: the format CP cap.
    ///   - movesById: gamemaster move lookup.
    ///   - shields: shields per side (PvPoke team-builder default is 1). 
    static func analyze(
        team: [MatchupSimulator.Combatant],
        teamStats: [BattlePokemon.Stats],
        meta: [MetaCandidate],
        cpCap: Int,
        movesById: [String: Move],
        shields: Int = 1
    ) async -> TeamAnalysis {
        let memberNames = team.map { $0.species.speciesName }
        let teamSpeciesIds = Set(team.map { $0.species.speciesId })
        let teamFamilyIds = Set(team.compactMap { $0.species.family?.id })

        // --- Pass 1: threats (each candidate as attacker vs each member) -------
        let threats = await withTaskGroup(of: ThreatEntry?.self) { group in
            for cand in meta {
                group.addTask {
                    guard let candStats = MatchupSimulator.optimalStats(
                        for: cand.combatant, cpCap: cpCap) else { return nil }
                    var ratings: [Int] = []
                    ratings.reserveCapacity(team.count)
                    for (i, member) in team.enumerated() {
                        let res = MatchupSimulator.rate(
                            cand.combatant, statsA: candStats,
                            member, statsB: teamStats[i],
                            movesById: movesById,
                            shieldsA: shields, shieldsB: shields)
                        ratings.append(res?.a ?? 500)   // res.a = candidate's rating
                    }
                    guard !ratings.isEmpty else { return nil }
                    let avgRaw = ratings.reduce(0, +) / ratings.count
                    let scores = ratings.map { softScore(Double($0), metaRelevant: cand.metaRelevant) }
                    let matchupScore = scores.reduce(0, +) / Double(scores.count)
                    return ThreatEntry(
                        speciesId: cand.species.speciesId,
                        speciesName: cand.species.speciesName,
                        types: cand.species.types.filter { $0 != "none" },
                        shadow: cand.shadow,
                        ratings: ratings,
                        averageRating: avgRaw,
                        score: matchupScore)
                }
            }
            var out: [ThreatEntry] = []
            for await t in group { if let t { out.append(t) } }
            return out
        }.sorted { $0.score > $1.score }

        // --- avgThreatScore: top-6 distinct (by family) threats (plan §2.4) ----
        var counterTeam: [ThreatEntry] = []
        var usedFamilies = Set<String>()
        for t in threats {
            if teamSpeciesIds.contains(t.speciesId) { continue }
            // Distinctness: skip a second mon from a family already represented.
            if let fam = meta.first(where: { $0.species.speciesId == t.speciesId })?.familyId {
                if usedFamilies.contains(fam) { continue }
                usedFamilies.insert(fam)
            }
            counterTeam.append(t)
            if counterTeam.count == 6 { break }
        }
        let avgThreatScore: Int = counterTeam.isEmpty ? 500
            : Int((Double(counterTeam.map { $0.averageRating }.reduce(0, +)) / Double(counterTeam.count)).rounded())

        // --- Pass 2: suggested teammates (beat the counterTeam) (plan §2.8) ----
        let suggestions = await suggestedTeammates(
            counterTeam: counterTeam,
            meta: meta,
            cpCap: cpCap,
            movesById: movesById,
            shields: shields,
            excludeSpecies: teamSpeciesIds,
            excludeFamilies: teamFamilyIds)

        // --- Grades ------------------------------------------------------------
        let coverageValue = 1200 - Double(avgThreatScore)
        let coverage = LetterGrade.grade(value: coverageValue, goal: 680)

        // Bulk: mean(effectiveDef × hp) over members. effDef includes shadow def mult.
        let bulkValues: [Double] = zip(team, teamStats).map { member, stats in
            let effDef = stats.def * (member.shadow ? DamageMultiplier.shadowDef : 1)
            return effDef * Double(stats.hp)
        }
        let bulkValue = bulkValues.isEmpty ? 0 : bulkValues.reduce(0, +) / Double(bulkValues.count)
        let bulk = LetterGrade.grade(value: bulkValue, goal: bulkGoal(cpCap: cpCap))

        // Consistency: mean of each member's moveset consistency (0–100). APPROX.
        let consistencyValues: [Double] = team.map {
            Consistency.score(fastMoveId: $0.fastMoveId,
                              chargedMoveIds: $0.chargedMoveIds,
                              types: $0.species.types,
                              movesById: movesById)
        }
        let consistencyValue = consistencyValues.isEmpty ? 0
            : consistencyValues.reduce(0, +) / Double(consistencyValues.count)
        let consistency = LetterGrade.grade(value: consistencyValue, goal: 98)

        // Safety: mean of members' "switches" category score. PROVISIONAL (plan
        // §2.9 / M1.8) — we don't yet fetch the switches rankings, so use PvPoke's
        // default of 60 for every member.
        let safetyValue = 60.0
        let safety = LetterGrade.grade(value: safetyValue, goal: 98)

        let grades = TeamGrades(
            coverage: coverage, bulk: bulk, safety: safety, consistency: consistency,
            coverageValue: coverageValue, bulkValue: bulkValue,
            safetyValue: safetyValue, consistencyValue: consistencyValue,
            safetyProvisional: true)

        return TeamAnalysis(
            grades: grades,
            threatScore: avgThreatScore,
            threats: Array(threats.prefix(20)),
            suggestions: suggestions,
            memberNames: memberNames)
    }

    /// Rank the meta as attackers against the team's top threats — "what beats
    /// the things that beat you." (plan §2.8)
    private static func suggestedTeammates(
        counterTeam: [ThreatEntry],
        meta: [MetaCandidate],
        cpCap: Int,
        movesById: [String: Move],
        shields: Int,
        excludeSpecies: Set<String>,
        excludeFamilies: Set<String>
    ) async -> [SuggestionEntry] {
        guard !counterTeam.isEmpty else { return [] }

        // Build the ≤6 threat opponents once (combatant + stats).
        struct Opp: Sendable { let combatant: MatchupSimulator.Combatant; let stats: BattlePokemon.Stats }
        var opponents: [Opp] = []
        for t in counterTeam {
            guard let cand = meta.first(where: { $0.species.speciesId == t.speciesId }),
                  let stats = MatchupSimulator.optimalStats(for: cand.combatant, cpCap: cpCap)
            else { continue }
            opponents.append(Opp(combatant: cand.combatant, stats: stats))
        }
        guard !opponents.isEmpty else { return [] }

        let suggestions = await withTaskGroup(of: SuggestionEntry?.self) { group in
            for cand in meta {
                if excludeSpecies.contains(cand.species.speciesId) { continue }
                if let fam = cand.familyId, excludeFamilies.contains(fam) { continue }
                group.addTask {
                    guard let candStats = MatchupSimulator.optimalStats(
                        for: cand.combatant, cpCap: cpCap) else { return nil }
                    var scores: [Double] = []
                    scores.reserveCapacity(opponents.count)
                    for opp in opponents {
                        let res = MatchupSimulator.rate(
                            cand.combatant, statsA: candStats,
                            opp.combatant, statsB: opp.stats,
                            movesById: movesById,
                            shieldsA: shields, shieldsB: shields)
                        scores.append(softScore(Double(res?.a ?? 500), metaRelevant: cand.metaRelevant))
                    }
                    let avg = scores.reduce(0, +) / Double(scores.count)
                    return SuggestionEntry(
                        speciesId: cand.species.speciesId,
                        speciesName: cand.species.speciesName,
                        types: cand.species.types.filter { $0 != "none" },
                        shadow: cand.shadow,
                        score: avg)
                }
            }
            var out: [SuggestionEntry] = []
            for await s in group { if let s { out.append(s) } }
            return out
        }

        // Distinct by family, best-first.
        var seen = Set<String>()
        var result: [SuggestionEntry] = []
        for s in suggestions.sorted(by: { $0.score > $1.score }) {
            let famKey = meta.first(where: { $0.species.speciesId == s.speciesId })?.familyId ?? s.speciesId
            if seen.contains(famKey) { continue }
            seen.insert(famKey)
            result.append(s)
            if result.count == 12 { break }
        }
        return result
    }
}
