//
//  LocalRankingTests.swift
//  PokePartyTests
//
//  Covers the local-ranking pipeline (M6): MetaPool eligibility filtering,
//  MovesetSelector's local search, and the Ranker's end-to-end output.
//

import Foundation
import Testing
@testable import PokeParty

private func makeMove(
    _ id: String, type: String = "normal", power: Int, energy: Int, energyGain: Int, cooldown: Int
) -> Move {
    Move(moveId: id, name: id, type: type, power: power, energy: energy, energyGain: energyGain,
         cooldown: cooldown, turns: nil, buffs: nil, buffTarget: nil, buffApplyChance: nil)
}

private func makePokemon(
    id: String, dex: Int = 1, atk: Int = 150, def: Int = 130, hp: Int = 150,
    types: [String] = ["normal"], fastMoves: [String], chargedMoves: [String],
    tags: [String]? = nil, released: Bool? = true, family: Pokemon.Family? = nil
) -> Pokemon {
    Pokemon(dex: dex, speciesName: id, speciesId: id,
            baseStats: .init(atk: atk, def: def, hp: hp), types: types,
            fastMoves: fastMoves, chargedMoves: chargedMoves,
            eliteMoves: nil, legacyMoves: nil, tags: tags, released: released,
            family: family, formChange: nil)
}

// MARK: - MetaPool

@Suite struct MetaPoolTests {

    private let allCup = Cup(
        name: "all", title: "All Pokemon", include: [],
        exclude: [.init(filterType: "tag", values: [.string("mega")])])

    private var movesById: [String: Move] {
        ["fast": makeMove("fast", power: 4, energy: 0, energyGain: 5, cooldown: 1000),
         "c1": makeMove("c1", power: 60, energy: 35, energyGain: 0, cooldown: 0),
         "c2": makeMove("c2", power: 100, energy: 55, energyGain: 0, cooldown: 0)]
    }

    @Test func minStatProductFloorExcludesWeakSpecies() {
        let strong = makePokemon(id: "strong", fastMoves: ["fast"], chargedMoves: ["c1", "c2"])
        // Extremely low base stats fail the Great League 1370 stat-product floor.
        let weak = makePokemon(id: "weak", atk: 30, def: 20, hp: 30, fastMoves: ["fast"], chargedMoves: ["c1", "c2"])

        let eligible = MetaPool.eligiblePokemon(
            for: allCup, cpCap: 1500, allPokemon: [strong, weak], greatLeagueIneligible: [])

        #expect(eligible.contains { $0.speciesId == "strong" })
        #expect(!eligible.contains { $0.speciesId == "weak" })
    }

    @Test func greatLeagueIneligibleAppliesBelow2500Only() {
        // Strong enough to clear the stat-product floor at both caps (1370 at
        // 1500, 2800 at 2500), so the ban list is the only thing that can
        // exclude it — weaker stats get dropped by the floor instead.
        let banned = makePokemon(
            id: "banned", atk: 250, def: 200, hp: 200, fastMoves: ["fast"], chargedMoves: ["c1", "c2"])

        let unbanned1500 = MetaPool.eligiblePokemon(
            for: allCup, cpCap: 1500, allPokemon: [banned], greatLeagueIneligible: [])
        let at1500 = MetaPool.eligiblePokemon(
            for: allCup, cpCap: 1500, allPokemon: [banned], greatLeagueIneligible: ["banned"])
        let at2500 = MetaPool.eligiblePokemon(
            for: allCup, cpCap: 2500, allPokemon: [banned], greatLeagueIneligible: ["banned"])

        // Without the ban it's eligible at 1500, so the empty result below is
        // the ban's doing and not the stat floor's.
        #expect(unbanned1500.contains { $0.speciesId == "banned" })
        #expect(at1500.isEmpty)
        #expect(at2500.contains { $0.speciesId == "banned" })
    }

    @Test func typeIncludeFilterKeepsOnlyMatchingTypes() {
        let waterCup = Cup(name: "waterOnly", title: "Water Only",
                            include: [.init(filterType: "type", values: [.string("water")])],
                            exclude: [])
        let waterMon = makePokemon(id: "water_mon", types: ["water"], fastMoves: ["fast"], chargedMoves: ["c1", "c2"])
        let fireMon = makePokemon(id: "fire_mon", types: ["fire"], fastMoves: ["fast"], chargedMoves: ["c1", "c2"])

        let eligible = MetaPool.eligiblePokemon(
            for: waterCup, cpCap: 1500, allPokemon: [waterMon, fireMon], greatLeagueIneligible: [])

        #expect(eligible.contains { $0.speciesId == "water_mon" })
        #expect(!eligible.contains { $0.speciesId == "fire_mon" })
    }

    /// An explicit `id` include overrides an otherwise-matching `exclude`
    /// filter for that one Pokémon, but not for anyone else who matches the
    /// same exclude criterion — the `includeIDFilter` short-circuit in
    /// `GameMaster.js`'s filter engine.
    @Test func idIncludeOverridesTypeExclude() {
        let cup = Cup(name: "special", title: "Special",
                      include: [.init(filterType: "id", values: [.string("special_id")])],
                      exclude: [.init(filterType: "type", values: [.string("fire")])])
        let special = makePokemon(id: "special_id", types: ["fire"], fastMoves: ["fast"], chargedMoves: ["c1", "c2"])
        let ordinaryFire = makePokemon(id: "ordinary_fire", types: ["fire"], fastMoves: ["fast"], chargedMoves: ["c1", "c2"])

        let eligible = MetaPool.eligiblePokemon(
            for: cup, cpCap: 1500, allPokemon: [special, ordinaryFire], greatLeagueIneligible: [])

        #expect(eligible.contains { $0.speciesId == "special_id" })
        #expect(!eligible.contains { $0.speciesId == "ordinary_fire" })
    }

    @Test func evolutionStageFilterMatchesLittleCupSemantics() {
        let littleCup = Cup(name: "little", title: "Little Cup",
                             include: [.init(filterType: "evolution", values: [.int(1)])],
                             exclude: [])
        let baseOfLine = makePokemon(
            id: "base", fastMoves: ["fast"], chargedMoves: ["c1", "c2"],
            family: .init(id: nil, parent: nil, evolutions: ["mid"]))
        let finalStage = makePokemon(
            id: "final", fastMoves: ["fast"], chargedMoves: ["c1", "c2"],
            family: .init(id: nil, parent: "mid", evolutions: nil))
        let singleStage = makePokemon(id: "single", fastMoves: ["fast"], chargedMoves: ["c1", "c2"], family: nil)

        let eligible = MetaPool.eligiblePokemon(
            for: littleCup, cpCap: 1500, allPokemon: [baseOfLine, finalStage, singleStage],
            greatLeagueIneligible: [])

        #expect(eligible.contains { $0.speciesId == "base" })
        #expect(!eligible.contains { $0.speciesId == "final" })
        #expect(!eligible.contains { $0.speciesId == "single" })
    }
}

// MARK: - MovesetSelector

@Suite struct MovesetSelectorTests {

    @Test func picksTheStrongerChargedMovePair() {
        let movesById: [String: Move] = [
            "fast": makeMove("fast", power: 4, energy: 0, energyGain: 8, cooldown: 500),
            // Costly and nearly powerless. A cheap weak move would be a good
            // shield bait (it can win the matchup by drawing the opponent's
            // one shield), so this one is priced out of ever being useful.
            "weak": makeMove("weak", power: 5, energy: 60, energyGain: 0, cooldown: 0),
            "medium": makeMove("medium", power: 55, energy: 45, energyGain: 0, cooldown: 0),
            "strong": makeMove("strong", power: 110, energy: 55, energyGain: 0, cooldown: 0),
        ]
        let species = makePokemon(id: "candidate", fastMoves: ["fast"], chargedMoves: ["weak", "medium", "strong"])
        let opponent = makePokemon(id: "opponent", fastMoves: ["fast"], chargedMoves: ["medium", "strong"])
        let probe: [MatchupSimulator.Combatant] = [
            .init(species: opponent, shadow: false, fastMoveId: "fast", chargedMoveIds: ["medium", "strong"])
        ]

        let result = MovesetSelector.select(
            species: species, shadow: false, cpCap: 1500, probe: probe, movesById: movesById)

        #expect(result != nil)
        #expect(result?.chargedMoveIds.contains("strong") == true)
        #expect(result?.chargedMoveIds.contains("weak") == false)
    }

    @Test func probeSetOrdersByStatProduct() async {
        let strong = makePokemon(id: "strong", atk: 250, def: 200, hp: 200, fastMoves: ["fast"], chargedMoves: ["c1", "c2"])
        let weak = makePokemon(id: "weak", atk: 60, def: 50, hp: 60, fastMoves: ["fast"], chargedMoves: ["c1", "c2"])

        let probe = await MovesetSelector.probeSet(pool: [weak, strong], cpCap: 1500, probeSize: 1)

        #expect(probe.count == 1)
        #expect(probe.first?.species.speciesId == "strong")
    }
}

// MARK: - Ranker

@Suite struct RankerTests {

    @Test func dominantSpeciesRanksFirstWithValidScores() async {
        // All species share one type so super-effective matchups can't decide
        // the ranking; only stats differ.
        let names = ["fire", "water", "grass", "rock"]
        var pokemonById: [String: Pokemon] = [:]
        var movesById: [String: Move] = [:]
        var pool: [Pokemon] = []

        for (i, name) in names.enumerated() {
            let id = "p_\(name)"
            let fastId = "f_\(name)", c1Id = "c1_\(name)", c2Id = "c2_\(name)"
            // The first species is much bulkier at the same attack. Under a CP
            // cap that is what makes it dominant: raising base attack (or every
            // base stat) lowers the level it can reach and its stat product, so
            // a high-attack species would rank last rather than first.
            let isDominant = i == 0
            let pokemon = makePokemon(id: id, dex: i + 1, atk: 120,
                                       def: isDominant ? 200 : 150, hp: isDominant ? 200 : 160,
                                       fastMoves: [fastId], chargedMoves: [c1Id, c2Id])
            pokemonById[id] = pokemon
            pool.append(pokemon)
            movesById[fastId] = makeMove(fastId, power: 4, energy: 0, energyGain: 8, cooldown: 500)
            movesById[c1Id] = makeMove(c1Id, power: 60, energy: 35, energyGain: 0, cooldown: 0)
            movesById[c2Id] = makeMove(c2Id, power: 100, energy: 55, energyGain: 0, cooldown: 0)
        }

        let entries = await Ranker.rank(pool: pool, cpCap: 1500, movesById: movesById)

        #expect(entries.count == pool.count)
        #expect(entries.first?.speciesId == "p_fire")
        for entry in entries {
            #expect((entry.score ?? -1) >= 0)
            #expect((entry.score ?? 101) <= 100)
            #expect(entry.scores?.count == 6)
        }
    }
}
