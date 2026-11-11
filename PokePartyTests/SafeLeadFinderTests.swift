//
//  SafeLeadFinderTests.swift
//  PokePartyTests
//
//  Tests for the "Safe lead + cover" selection. Ratings are built by hand so the
//  expected leads and covers are known without running any battles (except the
//  rating-field test, which checks the simulated grid's bookkeeping).
//

import Foundation
import Testing
@testable import PokeParty

private let types = ["fire", "water", "grass", "rock", "ice", "ghost"]

private func makeMoves() -> [String: Move] {
    var moves: [String: Move] = [:]
    for t in types {
        moves["f_\(t)"] = Move(moveId: "f_\(t)", name: "Fast \(t)", type: t, power: 3, energy: 0,
                               energyGain: 4, cooldown: 500, turns: 1,
                               buffs: nil, buffTarget: nil, buffApplyChance: nil)
        moves["c_\(t)"] = Move(moveId: "c_\(t)", name: "Charged \(t)", type: t, power: 60, energy: 35,
                               energyGain: 0, cooldown: 0, turns: 0,
                               buffs: nil, buffTarget: nil, buffApplyChance: nil)
    }
    return moves
}

private func makePool() -> [TeamFinder.Candidate] {
    types.enumerated().map { index, type in
        let id = "mon\(index)"
        let species = Pokemon(dex: index + 1, speciesName: id, speciesId: id,
                              baseStats: .init(atk: 150, def: 115, hp: 155),
                              types: [type], fastMoves: ["f_\(type)"], chargedMoves: ["c_\(type)"],
                              eliteMoves: nil, legacyMoves: nil,
                              tags: nil, released: true, family: nil, formChange: nil)
        return TeamFinder.Candidate(
            member: TeamMember(speciesId: id, fastMoveId: "f_\(type)", chargedMoveIds: ["c_\(type)"]),
            speciesName: id, types: [type], shadow: false, familyId: nil, dex: index + 1,
            combatant: .init(species: species, shadow: false,
                             fastMoveId: "f_\(type)", chargedMoveIds: ["c_\(type)"]),
            stats: .init(atk: 150, def: 115, hp: 155))
    }
}

/// The same candidate with a family, so two of them can't share a team.
private func withFamily(_ c: TeamFinder.Candidate, _ family: String) -> TeamFinder.Candidate {
    TeamFinder.Candidate(
        member: c.member, speciesName: c.speciesName, types: c.types, shadow: c.shadow,
        familyId: family, dex: c.dex, combatant: c.combatant, stats: c.stats)
}

/// A 6-mon matrix (`raw[a * 6 + b]` = a's rating vs b):
/// - mon0 is the safe lead: everything rates ≤ 400 against it except mon3 (700).
/// - mon4 beats mon3 (800) and mon3 loses to it; mon1/mon2/mon5 all lose to mon3,
///   so mon4 is the only real cover for mon0's hole.
private func makeRatings() -> [Int] {
    let n = 6
    var raw = [Int](repeating: 600, count: n * n)
    for t in 0..<n where t != 0 { raw[t * n + 0] = 400 }   // nothing threatens mon0…
    raw[3 * n + 0] = 700                                   // …except mon3
    raw[4 * n + 3] = 800                                   // mon4 answers mon3
    raw[3 * n + 4] = 200
    raw[1 * n + 3] = 300
    raw[2 * n + 3] = 300
    raw[5 * n + 3] = 300
    return raw
}

private func makeField(_ raw: [Int] = makeRatings()) -> SafeLeadFinder.RatingField {
    SafeLeadFinder.RatingField(squareRatings: raw, count: 6)
}

/// One lead (mon0), so the back pair is the only thing under test.
private func oneLead(_ base: SafeLeadFinder.Config = .default) -> SafeLeadFinder.Config {
    var cfg = base
    cfg.minLeads = 1; cfg.maxLeads = 1; cfg.leadMargin = 0; cfg.teamsPerLead = 3
    return cfg
}

@Suite struct SafeLeadFinderTests {

    // MARK: - Opponent weights

    @Test func opponentWeightsFallWithRank() {
        let w = SafeLeadFinder.opponentWeights(count: 200, decay: 1)
        #expect(w[0] == 1)
        #expect(zip(w, w.dropFirst()).allSatisfy { $0 > $1 })
        #expect(w[0] / w[199] > 150)                     // rank 1 is far likelier than rank 200
        #expect(SafeLeadFinder.opponentWeights(count: 4, decay: 0) == [1, 1, 1, 1])
    }

    @Test func rank1OutweighsTheTailWhenChoosingTheBack() throws {
        // mon4 beats the LAST opponent hard (+500); mon5 beats the FIRST opponent
        // less (+200). mon4 and mon5 share a family, so a team has one or the other.
        var raw = [Int](repeating: 500, count: 36)
        raw[4 * 6 + 5] = 1000
        raw[5 * 6 + 1] = 700
        var pool = makePool()
        pool[4] = withFamily(pool[4], "shared")
        pool[5] = withFamily(pool[5], "shared")

        var rankWeighted = oneLead()
        rankWeighted.backCloserWeight = 0
        let byRank = try #require(SafeLeadFinder.select(all: pool, field: makeField(raw), config: rankWeighted).first)
        #expect(byRank.indices.contains(5) && !byRank.indices.contains(4))   // the head of the meta wins out

        var uniform = rankWeighted
        uniform.opponentDecay = 0
        let flat = try #require(SafeLeadFinder.select(all: pool, field: makeField(raw), config: uniform).first)
        #expect(flat.indices.contains(4) && !flat.indices.contains(5))       // equal weights favor the bigger margin
    }

    // MARK: - Leads

    @Test func safestMonIsTheFirstLead() {
        let pool = makePool()
        let field = makeField()
        let weights = SafeLeadFinder.opponentWeights(count: 6, decay: 1)
        let threat = SafeLeadFinder.leadThreats(all: pool, field: field, weights: weights)
        var cfg = SafeLeadFinder.Config.default
        cfg.minLeads = 3; cfg.maxLeads = 3
        let leads = SafeLeadFinder.chooseLeads(all: pool, leadThreat: threat, candidateCount: 6, config: cfg)
        #expect(leads.first == 0)
        #expect(leads.count == 3)
        #expect(threat[0] < threat[1])
    }

    @Test func leadsAreKeptOnlyWhileTheyStayGood() {
        let pool = makePool()
        // Threats: mon0 best, mon1 and mon2 close behind, the rest far worse.
        let threat: [Double] = [300, 310, 330, 600, 700, 800]
        var cfg = SafeLeadFinder.Config.default
        cfg.minLeads = 1; cfg.maxLeads = 40
        cfg.leadMargin = 0.15                                           // cutoff 345
        #expect(SafeLeadFinder.chooseLeads(all: pool, leadThreat: threat, candidateCount: 6, config: cfg) == [0, 1, 2])
        cfg.leadMargin = 0
        #expect(SafeLeadFinder.chooseLeads(all: pool, leadThreat: threat, candidateCount: 6, config: cfg) == [0])
        cfg.minLeads = 2                                                // never fewer than the minimum…
        #expect(SafeLeadFinder.chooseLeads(all: pool, leadThreat: threat, candidateCount: 6, config: cfg) == [0, 1])
        cfg.leadMargin = 5; cfg.minLeads = 1; cfg.maxLeads = 4          // …nor more than the maximum
        #expect(SafeLeadFinder.chooseLeads(all: pool, leadThreat: threat, candidateCount: 6, config: cfg).count == 4)
    }

    @Test func oneLeadPerFamily() {
        var pool = makePool()
        pool[1] = withFamily(pool[1], "same")
        pool[2] = withFamily(pool[2], "same")
        var cfg = SafeLeadFinder.Config.default
        cfg.minLeads = 6; cfg.maxLeads = 6
        let leads = SafeLeadFinder.chooseLeads(
            all: pool, leadThreat: [300, 310, 320, 330, 340, 350], candidateCount: 6, config: cfg)
        #expect(!(leads.contains(1) && leads.contains(2)))
    }

    // MARK: - Back pair

    @Test func backPairCoversTheLeadsHole() throws {
        let top = try #require(SafeLeadFinder.select(all: makePool(), field: makeField(), config: oneLead()).first)
        #expect(top.indices.first == 0)       // the safe lead leads
        #expect(top.indices.contains(4))      // and the only answer to mon3 comes along
        #expect(Set(top.indices).count == 3)
    }

    @Test func theBackPairFavorsStrongClosers() throws {
        // Every matchup is even, so all back pairs cover the meta equally and only
        // the closer bonus can separate them. The bonus rewards the better closer
        // of the two backs, so the best closer (mon4) must be on the team.
        var pool = makePool()
        let closers: [Double] = [50, 50, 50, 90, 95, 10]
        for i in pool.indices { pool[i].closerScore = closers[i] }
        // Everyone rates 500 against everyone, except that nothing threatens mon0
        // (so it leads). The coverage of every back pair is still a flat 500.
        var raw = [Int](repeating: 500, count: 36)
        for t in 1..<6 { raw[t * 6 + 0] = 400 }
        let even = makeField(raw)

        let top = try #require(SafeLeadFinder.select(all: pool, field: even, config: oneLead()).first)
        #expect(top.indices.first == 0)
        #expect(top.indices.contains(4))
        // 240 rating points per 100 closer points, on top of the (tied) coverage.
        #expect(abs(top.score - (500 + 240 * 0.95)) < 1e-9)

        // With the bonus off every pair ties, so closers can't decide the team.
        var cfg = oneLead()
        cfg.backCloserWeight = 0
        let flat = SafeLeadFinder.select(all: pool, field: even, config: cfg)
        let spread = (flat.map(\.score).max() ?? 0) - (flat.map(\.score).min() ?? 0)
        #expect(spread < 1e-9)                       // equal up to floating-point order
        #expect(flat.first!.score < top.score)
    }

    @Test func missingCloserScoresCountAsZero() {
        // No ranking data: the bonus is simply absent, never a crash or a NaN.
        let trios = SafeLeadFinder.select(all: makePool(), field: makeField())
        #expect(!trios.isEmpty)
        #expect(trios.allSatisfy { $0.score.isFinite })
    }

    // MARK: - Results

    @Test func resultsAreRankedDeduplicatedAndReproducible() {
        let pool = makePool()
        var cfg = SafeLeadFinder.Config.default
        cfg.minLeads = 6; cfg.maxLeads = 6; cfg.leadMargin = 10   // every candidate leads
        let trios = SafeLeadFinder.select(all: pool, field: makeField(), config: cfg)
        #expect(!trios.isEmpty)
        #expect(zip(trios, trios.dropFirst()).allSatisfy { $0.score >= $1.score })
        #expect(Set(trios.map { $0.indices.sorted() }).count == trios.count)
        // Same input, same output — including who leads when two leads reach the
        // same trio with the same score.
        #expect(SafeLeadFinder.select(all: pool, field: makeField(), config: cfg) == trios)
    }

    @Test func tooSmallAPoolYieldsNothing() {
        let pool = Array(makePool().prefix(2))
        let field = SafeLeadFinder.RatingField(squareRatings: [500, 500, 500, 500], count: 2)
        #expect(SafeLeadFinder.select(all: pool, field: field).isEmpty)
    }

    // MARK: - Rating field

    @Test func fieldPrefixKeepsTheTopOpponents() {
        let field = makeField(makeRatings())
        let top3 = field.prefix(opponents: 3)
        #expect(top3.opponentCount == 3 && top3.candidateCount == 6)
        for c in 0..<6 { for j in 0..<3 {
            #expect(top3.mine[c * 3 + j] == field.mine[c * 6 + j])
            #expect(top3.theirs[c * 3 + j] == field.theirs[c * 6 + j])
        } }
        #expect(field.prefix(opponents: 99).opponentCount == 6)
    }

    @Test func findTriosKeepsOnlyTheTopCandidates() async {
        // Six Pokémon, but the finder may only use the top four as candidates; all
        // six still count as opponents.
        var cfg = SafeLeadFinder.Config.default
        cfg.maxCandidates = 4
        let found = await SafeLeadFinder.findTrios(
            all: makePool(), candidateCount: 6, opponentCount: 6, movesById: makeMoves(), config: cfg)
        #expect(found.field.candidateCount == 4)
        #expect(found.field.opponentCount == 6)
        #expect(!found.trios.isEmpty)
        #expect(found.trios.allSatisfy { $0.indices.allSatisfy { $0 < 4 } })
    }

    @Test func defaultsFollowTheTunedValues() {
        let cfg = SafeLeadFinder.Config.default
        #expect(cfg.opponentDecay == 1.0)        // weight 1 / rank, over the whole list
        #expect(cfg.maxCandidates == 150)
        #expect(cfg.backCloserWeight == 240)
        #expect(cfg.leadMargin == 0.4)
    }

    @Test func simulatedFieldFillsBothDirectionsConsistently() async {
        // 4 candidates against 6 opponents: every pair inside the 4×4 block was
        // simulated once and must read the same from either side.
        let pool = makePool()
        let field = await SafeLeadFinder.ratingField(
            all: pool, candidateCount: 4, opponentCount: 6, movesById: makeMoves())
        #expect(field.candidateCount == 4 && field.opponentCount == 6)
        for c in 0..<4 { for j in 0..<4 where j != c {
            #expect(field.mine[c * 6 + j] == field.theirs[j * 6 + c])
            #expect(field.theirs[c * 6 + j] == field.mine[j * 6 + c])
        } }
        // Candidate 2 (grass) against the tail opponent 4 (ice) was simulated too:
        // ice is super effective against grass, so the two sides can't tie.
        #expect(field.mine[2 * 6 + 4] != field.theirs[2 * 6 + 4])
    }

    // MARK: - Grading

    @Test func gradingKeepsTheChosenOrder() {
        let pool = makePool()
        // Lead index 4 is deliberately not the lowest in the trio.
        let graded = GradeFinder.gradeTrios(
            [[4, 0, 2]], members: pool, threats: pool, threatRatings: makeField().threatRatings,
            cpCap: 1500, movesById: makeMoves())
        let team = try! #require(graded.first)
        #expect(team.poolIndices == [4, 0, 2])
        #expect(team.members.map(\.member.speciesId) == ["mon4", "mon0", "mon2"])
    }

    @Test func gradingAgainstASeparateOpponentField() {
        // Four candidates graded against six opponents (the field's rectangle).
        let raw = makeRatings()
        var mine = [Int](), theirs = [Int]()
        for c in 0..<4 { for j in 0..<6 { mine.append(raw[c * 6 + j]); theirs.append(raw[j * 6 + c]) } }
        let field = SafeLeadFinder.RatingField(candidateCount: 4, opponentCount: 6, mine: mine, theirs: theirs)
        let pool = makePool()
        let graded = GradeFinder.gradeTrios(
            [[3, 1, 0]], members: Array(pool.prefix(4)), threats: pool, threatRatings: field.threatRatings,
            cpCap: 1500, movesById: makeMoves())
        #expect(graded.first?.poolIndices == [3, 1, 0])
        // The wrong shape yields nothing rather than reading out of bounds.
        #expect(GradeFinder.gradeTrios(
            [[3, 1, 0]], members: Array(pool.prefix(4)), threats: pool, threatRatings: [1, 2, 3],
            cpCap: 1500, movesById: makeMoves()).isEmpty)
    }
}
