//
//  TempoTrackerTests.swift
//  PokePartyTests
//

import Testing
@testable import PokeParty

@Suite struct TempoTrackerTests {
    @Test() func aVoluntarySwitchStartsTheTimer() {
        var tracker = TempoTracker()
        tracker.setActive(.mine, index: 0, at: 0)
        #expect(tracker.switchRemaining(.mine, at: 5) == 0)         // the lead isn't a switch
        tracker.setActive(.mine, index: 1, at: 10)
        #expect(tracker.switchRemaining(.mine, at: 10) == TempoTracker.switchTimer)
        #expect(tracker.switchRemaining(.mine, at: 15) == TempoTracker.switchTimer - 5)
        #expect(tracker.switchRemaining(.mine, at: 10 + TempoTracker.switchTimer) == 0)
        #expect(tracker.switchRemaining(.theirs, at: 15) == 0)      // the other side is unaffected
    }

    @Test() func settingTheSameActiveAgainDoesNothing() {
        var tracker = TempoTracker()
        tracker.setActive(.theirs, index: 0, at: 0)
        tracker.setActive(.theirs, index: 0, at: 10)
        #expect(tracker.switchRemaining(.theirs, at: 10) == 0)
    }

    @Test() func aSwitchAfterAFaintDoesNotStartTheTimer() {
        var tracker = TempoTracker()
        tracker.setActive(.theirs, index: 0, at: 0)
        tracker.fainted(.theirs, index: 0)
        tracker.setActive(.theirs, index: 1, at: 20)
        #expect(tracker.switchRemaining(.theirs, at: 20) == 0)
    }
}

@Suite struct ThrowAlertTests {
    @Test() func wordingFollowsTheCall() {
        let lethal = ThrowAlert.Incoming(moveName: "Blast", call: .shield, damageShare: 1.2, lethal: true)
        #expect(lethal.headline == "Shield Blast")
        #expect(lethal.detail.contains("faint"))
        let chip = ThrowAlert.Incoming(moveName: "Poke", call: .takeIt, damageShare: 0.18, lethal: false)
        #expect(chip.headline == "Tank Poke")
        #expect(chip.detail.contains("18%"))
        let bare = ThrowAlert.Incoming(moveName: "Blast", call: .noShields, damageShare: 0.4, lethal: false)
        #expect(bare.detail.contains("No shields"))
    }
}
