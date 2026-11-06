//
//  BattleActiveMatcherTests.swift
//  PokePartyTests
//

import Foundation
import Testing
@testable import PokeParty

private func species(_ id: String, _ name: String, types: [String]) throws -> Pokemon {
    let typeJSON = (types.count == 1 ? types + ["none"] : types).map { "\"\($0)\"" }.joined(separator: ",")
    let json = """
    {"dex":1,"speciesName":"\(name)","speciesId":"\(id)",
     "baseStats":{"atk":100,"def":100,"hp":100},"types":[\(typeJSON)],
     "fastMoves":[],"chargedMoves":[],"tags":[]}
    """
    return try JSONDecoder().decode(Pokemon.self, from: Data(json.utf8))
}

@Suite struct BattleActiveMatcherTests {

    private func team() throws -> [Pokemon] {
        [try species("ampharos", "Ampharos", types: ["electric"]),
         try species("greninja", "Greninja", types: ["water", "dark"]),
         try species("clodsire", "Clodsire", types: ["poison", "ground"])]
    }

    @Test func nameWithTrailingDigitsMatches() throws {
        #expect(BattleActiveMatcher.activeIndex(name: "Greninja158", icons: [], team: try team()) == 1)
        #expect(BattleActiveMatcher.activeIndex(name: "Clodsire21", icons: [], team: try team()) == 2)
    }

    @Test func nicknameFallsBackToTypeIcons() throws {
        let water = TypeColors.table["water"]!, dark = TypeColors.table["dark"]!
        let index = BattleActiveMatcher.activeIndex(name: "Froggy", icons: [water, dark], team: try team())
        #expect(index == 1)
    }

    @Test func nothingMatchingIsNil() throws {
        #expect(BattleActiveMatcher.activeIndex(name: "Xyzzy", icons: [], team: try team()) == nil)
    }
}
