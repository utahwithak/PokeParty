//
//  OpponentDetectionTests.swift
//  PokePartyTests
//
//  Parsing the opponent panel's OCR lines, and resolving the name to species.
//

import Foundation
import Testing
@testable import PokeParty

struct OpponentDetectionTests {

    // MARK: - Parsing

    /// The panel in a real battle screenshot reads "CP 1465 … Sneasel".
    @Test func parsesCPAndNameOnSeparateLines() {
        let reading = OpponentStripReader.parse(["CP 1465", "Sneasel"])
        #expect(reading == OpponentReading(name: "Sneasel", cp: 1465))
    }

    @Test func parsesCPAndNameOnOneLine() {
        let reading = OpponentStripReader.parse(["CP 1465 Sneasel"])
        #expect(reading == OpponentReading(name: "Sneasel", cp: 1465))
    }

    @Test func parsesBareNumberAsCP() {
        let reading = OpponentStripReader.parse(["CP", "1465", "Sneasel"])
        #expect(reading == OpponentReading(name: "Sneasel", cp: 1465))
    }

    /// A stray two-digit number (a battery percentage) isn't a CP.
    @Test func ignoresTwoDigitNumbers() {
        let reading = OpponentStripReader.parse(["89", "Sneasel"])
        #expect(reading == OpponentReading(name: "Sneasel", cp: nil))
    }

    @Test func noLettersMeansNoReading() {
        #expect(OpponentStripReader.parse(["CP 1465", "12"]) == nil)
    }

    // MARK: - Matching

    private func species(_ id: String, _ name: String, types: [String] = ["normal"], tags: [String] = []) throws -> Pokemon {
        let tagJSON = tags.map { "\"\($0)\"" }.joined(separator: ",")
        // Single-type species carry a "none" placeholder in the gamemaster.
        let typeJSON = (types.count == 1 ? types + ["none"] : types).map { "\"\($0)\"" }.joined(separator: ",")
        let json = """
        {"dex":1,"speciesName":"\(name)","speciesId":"\(id)",
         "baseStats":{"atk":100,"def":100,"hp":100},"types":[\(typeJSON)],
         "fastMoves":[],"chargedMoves":[],"tags":[\(tagJSON)]}
        """
        return try JSONDecoder().decode(Pokemon.self, from: Data(json.utf8))
    }

    @Test func uniqueNameResolvesToOneSpecies() throws {
        let pool = [try species("sneasel", "Sneasel"), try species("sneasler", "Sneasler")]
        let matches = OpponentNameMatcher.candidates(for: "Sneasel", in: pool)
        #expect(matches.map(\.speciesId) == ["sneasel"])
    }

    /// Zacian / Kyurem / Necrozma: one on-screen name, several forms to choose from.
    /// An exact name match wins outright; `family(of:)` widens it to the other forms.
    @Test func ambiguousBaseNameReturnsEveryForm() throws {
        let pool = [
            try species("kyurem", "Kyurem"),
            try species("kyurem_black", "Kyurem (Black)"),
            try species("kyurem_white", "Kyurem (White)"),
            try species("sneasel", "Sneasel"),
        ]
        let matches = OpponentNameMatcher.candidates(for: "Kyurem", in: pool)
        #expect(matches.map(\.speciesId) == ["kyurem"])
        let family = OpponentNameMatcher.family(of: matches, in: pool)
        #expect(Set(family.map(\.speciesId)) == ["kyurem", "kyurem_black", "kyurem_white"])
    }

    @Test func wordOrderDoesNotMatter() throws {
        let pool = [try species("vulpix_alolan", "Vulpix (Alolan)"), try species("vulpix", "Vulpix")]
        let matches = OpponentNameMatcher.candidates(for: "Alolan Vulpix", in: pool)
        #expect(matches.map(\.speciesId) == ["vulpix_alolan"])
    }

    @Test func shadowAndMegaFormsAreNotOfferedForBaseName() throws {
        let pool = [
            try species("machamp", "Machamp"),
            try species("machamp_shadow", "Machamp (Shadow)", tags: ["shadow"]),
        ]
        let matches = OpponentNameMatcher.candidates(for: "Machamp", in: pool)
        #expect(matches.map(\.speciesId) == ["machamp"])
    }

    @Test func toleratesOneOCRSlip() throws {
        let pool = [try species("sneasel", "Sneasel"), try species("azumarill", "Azumarill")]
        #expect(OpponentNameMatcher.candidates(for: "Sneasei", in: pool).map(\.speciesId) == ["sneasel"])
    }

    // MARK: - Narrowing by type icons

    /// Icon fill colours sampled from a real battle screenshot.
    private let ice = IconColor(r: 148, g: 211, b: 201)
    private let fairy = IconColor(r: 228, g: 158, b: 224)
    private let dark = IconColor(r: 98, g: 97, b: 113)

    @Test func iconsPickRegionalVariant() throws {
        let forms = [
            try species("ninetales", "Ninetales", types: ["fire"]),
            try species("ninetales_alolan", "Ninetales (Alolan)", types: ["ice", "fairy"]),
        ]
        #expect(OpponentNameMatcher.narrow(forms, byIcons: [ice, fairy]).map(\.speciesId) == ["ninetales_alolan"])
        // Slot order shouldn't matter.
        #expect(OpponentNameMatcher.narrow(forms, byIcons: [fairy, ice]).map(\.speciesId) == ["ninetales_alolan"])
    }

    /// One icon vs. two separates Weezing from its Galarian form.
    @Test func iconCountSeparatesForms() throws {
        let forms = [
            try species("weezing", "Weezing", types: ["poison"]),
            try species("weezing_galarian", "Weezing (Galarian)", types: ["poison", "fairy"]),
        ]
        let poison = try #require(TypeColors.table["poison"])
        #expect(OpponentNameMatcher.narrow(forms, byIcons: [poison]).map(\.speciesId) == ["weezing"])
        #expect(OpponentNameMatcher.narrow(forms, byIcons: [poison, fairy]).map(\.speciesId) == ["weezing_galarian"])
    }

    /// No icons seen, or nothing resembling any candidate: leave the list alone.
    @Test func narrowingNeverDiscardsEverything() throws {
        let forms = [
            try species("ninetales", "Ninetales", types: ["fire"]),
            try species("ninetales_alolan", "Ninetales (Alolan)", types: ["ice", "fairy"]),
        ]
        #expect(OpponentNameMatcher.narrow(forms, byIcons: []).count == 2)
        #expect(OpponentNameMatcher.narrow(forms, byIcons: [dark, dark, dark]).count == 2)
    }

    @Test func unknownNameMatchesNothing() throws {
        let pool = [try species("sneasel", "Sneasel")]
        #expect(OpponentNameMatcher.candidates(for: "Zzzzzz", in: pool).isEmpty)
    }
}
