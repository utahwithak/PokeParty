//
//  BattleCoachTests.swift
//  PokePartyTests
//
//  Decision rules are tested on hand-built scores; the simulation path uses
//  fully revealed opponents with synthetic Pokémon so no data files are needed.
//

import Testing
@testable import PokeParty

private func option(_ action: BattleCoach.Option.Action, index: Int, name: String,
                    win: Double, rating: Double) -> BattleCoach.Option {
    BattleCoach.Option(action: action, pokemonIndex: index, pokemonName: name,
                       winRate: win, averageRating: rating)
}

private func makeMove(_ id: String, type: String, power: Int, energy: Int, gain: Int) -> BattleMove {
    BattleMove(from: Move(moveId: id, name: id, type: type, power: power, energy: energy,
                          energyGain: gain, cooldown: 500, turns: 1,
                          buffs: nil, buffTarget: nil, buffApplyChance: nil))
}

private func makePoke(_ id: String, type: String, atk: Double, def: Double, hp: Int) -> BattlePokemon {
    BattlePokemon(speciesId: id, speciesName: id, types: [type], shadow: false,
                  stats: .init(atk: atk, def: def, hp: hp),
                  fastMove: makeMove("fast_" + id, type: type, power: 3, energy: 0, gain: 4),
                  chargedMoves: [makeMove("cm_" + id, type: type, power: 60, energy: 35, gain: 0)])
}

@Suite struct BattleCoachTests {

    @Test func recommendsClearlyBetterSwitch() {
        let advice = BattleCoach.advice(from: [
            option(.stay, index: 0, name: "Stunfisk", win: 0.40, rating: 420),
            option(.switchTo(1), index: 1, name: "Azumarill", win: 0.70, rating: 640),
            option(.switchTo(2), index: 2, name: "Medicham", win: 0.45, rating: 480),
        ], samples: 24, myShields: 2, opponentShields: 2)

        #expect(advice?.recommended.action == .switchTo(1))
        #expect(advice?.headline == "Switch to Azumarill")
    }

    @Test func staysWhenSwitchIsWithinNoise() {
        let advice = BattleCoach.advice(from: [
            option(.stay, index: 0, name: "Stunfisk", win: 0.52, rating: 510),
            option(.switchTo(1), index: 1, name: "Azumarill", win: 0.54, rating: 515),
        ], samples: 24, myShields: 1, opponentShields: 1)

        #expect(advice?.recommended.action == .stay)
        #expect(advice?.headline == "Stay in with Stunfisk")
    }

    @Test func losingMatchupMakesTheSwitchUrgent() {
        let advice = BattleCoach.advice(from: [
            option(.stay, index: 0, name: "Stunfisk", win: 0.10, rating: 250),
            option(.switchTo(1), index: 1, name: "Azumarill", win: 0.65, rating: 600),
        ], samples: 24, myShields: 0, opponentShields: 2)

        #expect(advice?.headline == "Switch to Azumarill now")
    }

    @Test func adviceNeedsTheStayOption() {
        let advice = BattleCoach.advice(from: [
            option(.switchTo(1), index: 1, name: "Azumarill", win: 0.65, rating: 600),
        ], samples: 24, myShields: 2, opponentShields: 2)

        #expect(advice == nil)
    }

    @Test func switchesOutOfAnOutclassedMatchup() async {
        // The lead is a weak grass type facing fire opponents; the bench is water
        // (resists fire, hits it super-effectively) and much sturdier.
        let mine = [
            makePoke("weak", type: "grass", atk: 100, def: 80, hp: 90),
            makePoke("strong", type: "water", atk: 145, def: 112, hp: 155),
            makePoke("strong2", type: "water", atk: 145, def: 112, hp: 155),
        ]
        let theirs = [
            makePoke("o0", type: "fire", atk: 160, def: 125, hp: 170),
            makePoke("o1", type: "fire", atk: 160, def: 125, hp: 170),
            makePoke("o2", type: "fire", atk: 160, def: 125, hp: 170),
        ]
        let state = BattleCoach.State(
            myTeam: mine, myActive: 0, myShields: 2,
            opponentRevealed: theirs, opponentActive: 0, opponentShields: 2)

        let advice = await BattleCoach.advise(state, pool: [], movesById: [:], samples: 2, seed: 1)

        #expect(advice != nil)
        if case .switchTo? = advice?.recommended.action {} else {
            Issue.record("Expected a switch, got \(String(describing: advice?.headline))")
        }
    }

    @Test func aWinThatKeepsMoreOfTheTeamRatesHigher() async {
        // Every line wins here, so only the HP margin can tell the options apart:
        // staying in with the weak lead burns it, switching straight out keeps it.
        let mine = [
            makePoke("weak", type: "grass", atk: 100, def: 80, hp: 90),
            makePoke("strong", type: "water", atk: 175, def: 135, hp: 185),
            makePoke("strong2", type: "water", atk: 175, def: 135, hp: 185),
        ]
        let theirs = (0..<3).map { makePoke("o\($0)", type: "fire", atk: 140, def: 110, hp: 150) }
        let state = BattleCoach.State(
            myTeam: mine, myActive: 0, myShields: 2,
            opponentRevealed: theirs, opponentActive: 0, opponentShields: 2)

        let advice = await BattleCoach.advise(state, pool: [], movesById: [:], samples: 2, seed: 1)
        let stay = advice?.options.first { $0.action == .stay }
        let best = advice?.options.filter { $0.action != .stay }.map(\.averageRating).max()

        #expect(stay?.winRate == 1)
        #expect((best ?? 0) > (stay?.averageRating ?? .infinity))
        #expect((stay?.averageRating ?? 1000) < 1000)
    }
}

@Suite struct BattleCoachStabilityTests {

    /// Two options a hair apart: whichever the tip currently says must stay put,
    /// in both directions, instead of flipping with each re-roll.
    @Test func closeCallKeepsTheStandingRecommendation() {
        let stayAhead = [
            option(.stay, index: 0, name: "Stunfisk", win: 0.52, rating: 510),
            option(.switchTo(1), index: 1, name: "Azumarill", win: 0.55, rating: 520),
        ]
        let switchAhead = [
            option(.stay, index: 0, name: "Stunfisk", win: 0.50, rating: 500),
            option(.switchTo(1), index: 1, name: "Azumarill", win: 0.49, rating: 495),
        ]
        // Already saying switch: a near-tie in favour of staying doesn't flip it back.
        #expect(BattleCoach.advice(from: switchAhead, samples: 48, myShields: 2, opponentShields: 2,
                                   incumbent: .switchTo(1))?.recommended.action == .switchTo(1))
        // Already saying stay: a near-tie in favour of switching doesn't flip it.
        #expect(BattleCoach.advice(from: stayAhead, samples: 48, myShields: 2, opponentShields: 2,
                                   incumbent: .stay)?.recommended.action == .stay)
    }

    @Test func clearlyBetterOptionStillOvertakesTheIncumbent() {
        let advice = BattleCoach.advice(from: [
            option(.stay, index: 0, name: "Stunfisk", win: 0.80, rating: 700),
            option(.switchTo(1), index: 1, name: "Azumarill", win: 0.30, rating: 350),
        ], samples: 48, myShields: 2, opponentShields: 2, incumbent: .switchTo(1))

        #expect(advice?.recommended.action == .stay)
    }

    @Test func situationFingerprintIgnoresHPJitterButNotRealChanges() {
        let mine = [makePoke("m0", type: "water", atk: 120, def: 120, hp: 140)]
        let theirs = [makePoke("o0", type: "fire", atk: 120, def: 120, hp: 140)]
        var a = BattleCoach.State(myTeam: mine, myActive: 0, myShields: 2,
                                  opponentRevealed: theirs, opponentActive: 0, opponentShields: 2)
        var b = a
        a.myHP = [0: 0.61]
        b.myHP = [0: 0.63]
        #expect(a.fingerprint == b.fingerprint)
        b.myHP = [0: 0.40]
        #expect(a.fingerprint != b.fingerprint)
        b = a
        b.myShields = 1
        #expect(a.fingerprint != b.fingerprint)
    }
}

@Suite struct LeadCoachTests {

    private func line(_ end: LeadCoach.Line.End, mine: [(String, Bool)] = [], theirs: [(String, Bool)] = [],
                      farmed: Bool = false) -> LeadCoach.Line {
        .init(mine: mine.map { .init(move: $0.0, shielded: $0.1) },
              theirs: theirs.map { .init(move: $0.0, shielded: $0.1) }, end: end, farmed: farmed)
    }

    @Test func verdictThresholds() {
        #expect(LeadCoach.Verdict(rating: 700) == .dominant)
        #expect(LeadCoach.Verdict(rating: 600) == .favored)
        #expect(LeadCoach.Verdict(rating: 500) == .close)
        #expect(LeadCoach.Verdict(rating: 400) == .unfavored)
        #expect(LeadCoach.Verdict(rating: 200) == .hopeless)
    }

    @Test func throwAndSwapHeadlineNamesTheMoves() {
        let l = line(.swapOut, mine: [("Surf", false), ("Surf", false)])
        #expect(LeadCoach.headline(for: l, verdict: .close) == "Throw Surf and swap out")
        #expect(LeadCoach.steps(for: l, opponent: "Talonflame").last == "Then swap out.")
    }

    @Test func shieldAndFarmStepsReadInOrder() {
        let l = line(.win, mine: [("Surf", false)], theirs: [("Brave Bird", true), ("Fly", false)], farmed: true)
        let steps = LeadCoach.steps(for: l, opponent: "Talonflame")
        #expect(steps.first == "Farm down first — fast moves only, bank the energy.")
        #expect(steps.contains("Shield their first Brave Bird, take the second Fly."))
        #expect(steps.contains("Throw Surf."))
        #expect(steps.last == "That wins the matchup.")
    }

    @Test func typicalLineFollowsTheCommonEnding() {
        let swap = line(.swapOut, mine: [("Surf", false)])
        let lines = [swap, swap, line(.win), line(.loss)]
        let typical = LeadCoach.typicalLine(of: lines)
        #expect(typical?.line == swap)
        #expect(typical?.share == 0.5)
    }
}

@Suite struct BackLineGuessTests {

    private func candidate(_ id: String, _ type: String, dex: Int) -> TeamFinder.Candidate {
        let species = Pokemon(dex: dex, speciesName: id, speciesId: id,
                              baseStats: .init(atk: 150, def: 115, hp: 155),
                              types: [type], fastMoves: ["f"], chargedMoves: ["c"],
                              eliteMoves: nil, legacyMoves: nil,
                              tags: nil, released: true, family: nil, formChange: nil)
        return .init(
            member: TeamMember(speciesId: id, fastMoveId: "f", chargedMoveIds: ["c"]),
            speciesName: id, types: [type], shadow: false, familyId: nil, dex: dex,
            combatant: .init(species: species, shadow: false, fastMoveId: "f", chargedMoveIds: ["c"]),
            stats: .init(atk: 150, def: 115, hp: 155))
    }

    /// A grass lead is weak to fire (among others). With equal popularity, a fire
    /// type — which resists grass but, more to the point, a partner that doesn't
    /// stack the same weakness — should be preferred over another grass type.
    @Test func predictionsFavourPartnersThatCoverTheLeadsWeaknesses() {
        // Water resists fire; a second grass type shares the lead's fire weakness.
        let pool = [candidate("grass2", "grass", dex: 1), candidate("water1", "water", dex: 2)]
        let guesses = BackLineGuess.predict(revealedIds: ["lead"], revealedTypes: [["grass"]],
                                            slots: 1, pool: pool, samples: 400, limit: 2)
        let likelihood = Dictionary(uniqueKeysWithValues: guesses.map { ($0.speciesId, $0.likelihood) })
        #expect((likelihood["water1"] ?? 0) > (likelihood["grass2"] ?? 0))
        #expect(guesses.first { $0.speciesId == "water1" }?.covers.contains("fire") == true)
    }

    @Test func nothingToGuessWhenTheTeamIsFullyRevealed() {
        let pool = [candidate("water1", "water", dex: 2)]
        #expect(BackLineGuess.predict(revealedIds: ["a", "b", "c"], revealedTypes: [["grass"], ["fire"], ["water"]],
                                      slots: 0, pool: pool).isEmpty)
    }
}

@Suite struct MidGameCoachTests {

    private func situation(my: Int, their: Int, myAlive: Int = 3, theirAlive: Int = 3,
                           myHP: Double? = nil, theirHP: Double? = nil) -> MidGameCoach.Situation {
        .init(myShields: my, theirShields: their, myAlive: myAlive, theirAlive: theirAlive,
              myActiveName: "Azumarill", theirActiveName: "Talonflame",
              myActiveHP: myHP, theirActiveHP: theirHP,
              myNames: ["Azumarill", "Medicham", "Stunfisk"], myActive: 0)
    }

    @Test func headlineFollowsTheShieldCount() {
        #expect(MidGameCoach.headline(situation(my: 0, their: 0)) == "Shields are down — play the endgame")
        #expect(MidGameCoach.headline(situation(my: 2, their: 1)) == "Up on shields — keep the pressure on")
        #expect(MidGameCoach.headline(situation(my: 1, their: 2)) == "Down on shields — make them spend first")
        #expect(MidGameCoach.headline(situation(my: 0, their: 2)) == "No shields — play around theirs")
        #expect(MidGameCoach.headline(situation(my: 1, their: 0)) == "They're out of shields — press")
    }

    @Test func decisiveShieldSwingsBecomeTips() {
        let insight = MidGameCoach.Insight(
            swing: .init(rating: 520, costOfSpending: 200, gainFromTheirs: 180), endgame: [])
        let tips = MidGameCoach.plan(situation(my: 1, their: 1), insight: insight).tips
        #expect(tips.contains { $0.contains("Your shield is worth about 200") })
        #expect(tips.contains { $0.contains("spend a shield is worth about 180") })
    }

    @Test func negligibleSwingsSayToSpendFreely() {
        let insight = MidGameCoach.Insight(swing: .init(rating: 700, costOfSpending: 10, gainFromTheirs: 0), endgame: [])
        let tips = MidGameCoach.plan(situation(my: 2, their: 2), insight: insight).tips
        #expect(tips.contains { $0.contains("barely change") })
    }

    @Test func endgameNamesACloserAndASpare() {
        let insight = MidGameCoach.Insight(swing: nil, endgame: [
            .init(index: 0, winShare: 0.4), .init(index: 1, winShare: 0.9), .init(index: 2, winShare: 0.2),
        ])
        let plan = MidGameCoach.plan(situation(my: 0, their: 0), insight: insight)
        #expect(plan.tips.contains { $0.hasPrefix("Save Medicham to close") })
        #expect(plan.tips.contains { $0.hasPrefix("Stunfisk is your most expendable") })
        #expect(plan.endgame.first { $0.name == "Medicham" }?.role == .closer)
        #expect(plan.endgame.first { $0.name == "Stunfisk" }?.role == .sacrifice)
    }

    @Test func lowHPTipsNeedABackup() {
        let withBackup = MidGameCoach.plan(situation(my: 1, their: 1, myHP: 0.15), insight: nil).tips
        #expect(withBackup.contains { $0.contains("nearly down") })
        let alone = MidGameCoach.plan(situation(my: 1, their: 1, myAlive: 1, myHP: 0.15), insight: nil).tips
        #expect(!alone.contains { $0.contains("swap a teammate") })
    }
}

@Suite struct BaitCallTests {

    private func mine(_ name: String, energy: Int, shield: Bool) -> BaitCall.MyMove {
        .init(name: name, energy: energy, damageShare: 0.3, theyShield: shield)
    }
    private func theirs(_ name: String, shield: Bool) -> BaitCall.TheirMove {
        .init(name: name, energy: 40, damageShare: 0.3, youShield: shield)
    }

    @Test func baitsWithTheCheapMoveTheyWouldShield() {
        let lines = BaitCall.lines(mine: [mine("Bubble Beam", energy: 35, shield: true), mine("Play Rough", energy: 60, shield: false)],
                                   theirs: [], myShields: 2, theirShields: 2, theirName: "Talonflame")
        #expect(lines.first == "Bait with Bubble Beam — they'll probably shield it — then Play Rough lands.")
    }

    @Test func cheapMoveThatWontBaitIsJustDamage() {
        let lines = BaitCall.lines(mine: [mine("Bubble Beam", energy: 35, shield: false), mine("Play Rough", energy: 60, shield: true)],
                                   theirs: [], myShields: 2, theirShields: 1, theirName: "Talonflame")
        #expect(lines.first?.hasPrefix("Bubble Beam won't draw their shield") == true)
    }

    @Test func noBaitWithoutTheirShields() {
        let lines = BaitCall.lines(mine: [mine("A", energy: 35, shield: false), mine("B", energy: 60, shield: false)],
                                   theirs: [], myShields: 2, theirShields: 0, theirName: "Talonflame")
        #expect(lines.first?.hasPrefix("They have no shields") == true)
    }

    @Test func shieldCallSplitsTheirMoves() {
        let lines = BaitCall.lines(mine: [], theirs: [theirs("Brave Bird", shield: true), theirs("Incinerate", shield: false)],
                                   myShields: 1, theirShields: 0, theirName: "Talonflame")
        #expect(lines.contains { $0.hasPrefix("Shield Brave Bird; take Incinerate") })
        // With no shield of your own there's no call to make.
        let none = BaitCall.lines(mine: [], theirs: [theirs("Brave Bird", shield: true)],
                                  myShields: 0, theirShields: 0, theirName: "Talonflame")
        #expect(none.isEmpty)
    }

    @Test func analysesARealMatchupWithBothMoves() {
        func poke(_ id: String, type: String) -> BattlePokemon {
            func move(_ id: String, power: Int, energy: Int, gain: Int) -> BattleMove {
                BattleMove(from: Move(moveId: id, name: id, type: type, power: power, energy: energy,
                                      energyGain: gain, cooldown: 500, turns: 1,
                                      buffs: nil, buffTarget: nil, buffApplyChance: nil))
            }
            return BattlePokemon(speciesId: id, speciesName: id, types: [type], shadow: false,
                                 stats: .init(atk: 150, def: 115, hp: 155),
                                 fastMove: move("fast", power: 3, energy: 0, gain: 4),
                                 chargedMoves: [move("cheap", power: 45, energy: 35, gain: 0),
                                                move("big", power: 100, energy: 60, gain: 0)])
        }
        let plan = BaitCall.analyze(mine: poke("a", type: "water"), theirs: poke("b", type: "fire"),
                                    myShields: 2, theirShields: 2)
        #expect(plan?.mine.map(\.name) == ["cheap", "big"])
        #expect(plan?.theirs.count == 2)
        #expect(plan?.lines.isEmpty == false)
    }
}

@Suite struct SeenMovesTests {

    @Test func shieldCallDropsTheGuessCaveatOnceEveryMoveIsSeen() {
        let seen = [BaitCall.TheirMove(name: "Brave Bird", energy: 55, damageShare: 0.5, youShield: true, seen: true)]
        let guessed = [BaitCall.TheirMove(name: "Brave Bird", energy: 55, damageShare: 0.5, youShield: true)]
        let known = BaitCall.lines(mine: [], theirs: seen, myShields: 1, theirShields: 0, theirName: "Talonflame")
        let unknown = BaitCall.lines(mine: [], theirs: guessed, myShields: 1, theirShields: 0, theirName: "Talonflame")
        #expect(known.first?.contains("moves seen thrown") == true)
        #expect(unknown.first?.contains("a guess until they're thrown") == true)
    }

    #if os(macOS)
    @MainActor @Test func seenMovesComeFirstAndTopUpFromTheGuess() {
        let guessed = TeamMember(speciesId: "talonflame", fastMoveId: "incinerate",
                                 chargedMoveIds: ["brave_bird", "flame_charge"])
        let other = TeamMember(speciesId: "azumarill", fastMoveId: "bubble",
                               chargedMoveIds: ["play_rough", "ice_beam"])
        let result = BattleCoachModel.applying(seen: ["talonflame": ["fly"]], to: [guessed, other])

        // One sighting replaces the second guess; the first guess fills the other slot.
        #expect(result[0].chargedMoveIds == ["fly", "brave_bird"])
        // Pokémon never seen throwing anything keep the guess.
        #expect(result[1].chargedMoveIds == ["play_rough", "ice_beam"])
    }

    @MainActor @Test func seeingBothMovesReplacesTheGuessEntirely() {
        let guessed = TeamMember(speciesId: "talonflame", fastMoveId: "incinerate",
                                 chargedMoveIds: ["brave_bird", "flame_charge"])
        let result = BattleCoachModel.applying(seen: ["talonflame": ["fly", "brave_bird"]], to: [guessed])
        #expect(result[0].chargedMoveIds == ["fly", "brave_bird"])
    }
    #endif
}
