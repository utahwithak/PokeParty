//
//  OpponentShadowMatchingTests.swift
//  PokePartyTests
//
//  A species ranked only as a Shadow (Great League Palkia: the regular one is
//  over the cap) is shown on the battle screen as plain "Palkia".
//

import Foundation
import Testing
@testable import PokeParty

private func species(_ id: String, _ name: String, types: [String], tags: [String] = []) throws -> Pokemon {
    let tagJSON = tags.map { "\"\($0)\"" }.joined(separator: ",")
    let json = """
    {"dex":1,"speciesName":"\(name)","speciesId":"\(id)",
     "baseStats":{"atk":100,"def":100,"hp":100},"types":[\(types.map { "\"\($0)\"" }.joined(separator: ","))],
     "fastMoves":[],"chargedMoves":[],"tags":[\(tagJSON)]}
    """
    return try JSONDecoder().decode(Pokemon.self, from: Data(json.utf8))
}

@Suite struct OpponentShadowMatchingTests {

    @Test func plainNameFindsAShadowOnlyRankedSpecies() throws {
        let ranked = [try species("palkia_shadow", "Palkia (Shadow)", types: ["water", "dragon"], tags: ["shadow"]),
                      try species("azumarill", "Azumarill", types: ["water", "fairy"])]

        let matches = OpponentNameMatcher.candidates(for: "Palkia", in: ranked)

        #expect(matches.map(\.speciesId) == ["palkia_shadow"])
    }

    @Test func aRankedRegularFormStillWinsOverItsShadow() throws {
        let ranked = [try species("palkia", "Palkia", types: ["water", "dragon"], tags: ["shadoweligible"]),
                      try species("palkia_shadow", "Palkia (Shadow)", types: ["water", "dragon"], tags: ["shadow"])]

        let matches = OpponentNameMatcher.candidates(for: "Palkia", in: ranked)

        #expect(matches.map(\.speciesId) == ["palkia"])
    }

    @Test func aShadowMatchStaysInItsOwnFamily() throws {
        let ranked = [try species("palkia_shadow", "Palkia (Shadow)", types: ["water", "dragon"], tags: ["shadow"])]
        let matches = OpponentNameMatcher.candidates(for: "Palkia", in: ranked)

        let family = OpponentNameMatcher.family(of: matches, in: ranked)

        #expect(family.map(\.speciesId) == ["palkia_shadow"])
    }
}
