//
//  CoachNarratorTests.swift
//  PokePartyTests
//
//  The coach's wording: plain instructions, no percentages.
//

import Testing
@testable import PokeParty

struct CoachNarratorTests {

    private func context(action: BattleCoach.Option.Action = .stay) -> CoachNarrator.Context {
        var c = CoachNarrator.Context(myName: "Stunfisk", theirName: "Azumarill", myShields: 2, theirShields: 2)
        c.action = action
        return c
    }

    @Test func stayNamesTheBackupForAFaint() {
        var c = context()
        c.backup = "Medicham"
        let text = CoachNarrator.entry(c)
        #expect(text.contains("Stay in with Stunfisk."))
        #expect(text.contains("If Stunfisk faints, bring in Medicham."))
    }

    @Test func switchNamesWhoToBringIn() {
        var c = context(action: .switchTo(1))
        c.switchName = "Medicham"
        c.backup = "Skarmory"
        let text = CoachNarrator.entry(c)
        #expect(text.contains("Switch to Medicham."))
        // The backup is for a Pokémon that stays in.
        #expect(!text.contains("faints"))
    }

    @Test func leadReadsThePlanInPlaceOfAStayLine() {
        var c = context()
        c.lead = LeadCoach.Plan(
            myName: "Stunfisk", opponentName: "Azumarill", verdict: .favored,
            headline: "You win the lead", steps: ["Throw Mud Bomb."], shieldLines: [],
            bait: nil, share: 0.8, samples: 32)
        let text = CoachNarrator.entry(c)
        #expect(text.hasPrefix("You win the lead."))
        #expect(text.contains("Throw Mud Bomb."))
        #expect(!text.contains("Stay in with"))
    }

    @Test func throwPointsAreCumulativeFromTheStart() {
        let timing = CoachNarrator.Timing(move: "Foul Play", counts: [3, 2, 2, 2, 2], timingMatters: false, cmp: .mine)
        #expect(CoachNarrator.timingLine(timing, fromStart: true) == "Throw Foul Play on fast move 3, 5, 7.")
    }

    @Test func midGameTimingGivesTheGapsBetweenThrows() {
        let straight = CoachNarrator.Timing(move: "Surf", counts: [4, 4, 4, 4, 4], timingMatters: false, cmp: .mine)
        #expect(CoachNarrator.timingLine(straight, fromStart: false) == "Throw Surf every 4 fast moves.")
        let uneven = CoachNarrator.Timing(move: "Surf", counts: [5, 4, 4, 4, 4], timingMatters: false, cmp: .mine)
        #expect(CoachNarrator.timingLine(uneven, fromStart: false) == "Throw Surf after 5 fast moves, then 4, 4.")
    }

    @Test func tiesAreOnlyMentionedWhenTimingMatters() {
        let quiet = CoachNarrator.Timing(move: "Surf", counts: [4, 4, 4, 4, 4], timingMatters: false, cmp: .theirs)
        #expect(!(CoachNarrator.timingLine(quiet, fromStart: false) ?? "").contains("tie"))
        let loud = CoachNarrator.Timing(move: "Surf", counts: [4, 4, 4, 4, 4], timingMatters: true, cmp: .theirs)
        #expect((CoachNarrator.timingLine(loud, fromStart: false) ?? "").contains("They win a tie"))
    }

    @Test func higherAttackWinsTheTie() {
        #expect(CoachNarrator.cmp(mine: 150, theirs: 140) == .mine)
        #expect(CoachNarrator.cmp(mine: 140, theirs: 150) == .theirs)
        #expect(CoachNarrator.cmp(mine: 140, theirs: 140) == .even)
    }

    @Test func midGameLinesAreOrderedCallThrowTimingShieldFallback() {
        var c = context()
        c.backup = "Medicham"
        c.timing = .init(move: "Swift", counts: [5, 5, 5, 5, 5], timingMatters: false, cmp: .mine)
        c.bait = BaitCall.Plan(mine: [], theirs: [], lines: [
            "They have no shields — nothing to bait. Throw Swift when you can; it hits hardest.",
            "Shield Wild Charge or Flame Charge when thrown — Azumarill's unseen moves are a guess until they're thrown."
        ])
        let lines = CoachNarrator.lines(c)
        #expect(lines.map(\.kind) == [.call, .throwMove, .timing, .shield, .backup])
        // The hedge says nothing to act on, so it doesn't take up a line's width.
        #expect(lines[3].text == "Shield Wild Charge or Flame Charge when thrown.")
    }

    @Test func leadStepsKeepTheOrderTheyHappenIn() {
        var c = context()
        c.lead = LeadCoach.Plan(
            myName: "Stunfisk", opponentName: "Azumarill", verdict: .favored,
            headline: "You win the lead",
            steps: ["Farm down first — fast moves only, bank the energy.", "Shield their first Play Rough.", "Throw Mud Bomb."],
            shieldLines: [], bait: nil, share: 0.8, samples: 32)
        #expect(CoachNarrator.lines(c).map(\.kind) == [.call, .plan, .shield, .throwMove])
    }

    @Test func entriesCarryNoPercentages() {
        var c = context()
        c.backup = "Medicham"
        c.closer = "Skarmory"
        c.timing = .init(move: "Rock Slide", counts: [3, 2, 2, 2, 2], timingMatters: true, cmp: .even)
        #expect(!CoachNarrator.entry(c).contains("%"))
    }
}
