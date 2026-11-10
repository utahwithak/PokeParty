//
//  OpponentSampleTests.swift
//  PokePartyTests
//
//  Confidence in the logged-opponent data behind "My Meta", and how it scales
//  the optimizer's field.
//

import Foundation
import Testing
@testable import PokeParty

@Suite struct OpponentSampleTests {

    @Test func verdictFollowsTheBattleCount() {
        #expect(OpponentSample(battles: 0).verdict == .none)
        #expect(OpponentSample(battles: 1).verdict == .thin)
        #expect(OpponentSample(battles: OpponentSample.limitedBattles - 1).verdict == .thin)
        #expect(OpponentSample(battles: OpponentSample.limitedBattles).verdict == .limited)
        #expect(OpponentSample(battles: OpponentSample.fullConfidenceBattles - 1).verdict == .limited)
        #expect(OpponentSample(battles: OpponentSample.fullConfidenceBattles).verdict == .good)
    }

    @Test func confidenceGrowsThenCaps() {
        #expect(OpponentSample(battles: 0).confidence == 0)
        #expect(OpponentSample(battles: 15).confidence == 0.5)
        #expect(OpponentSample(battles: OpponentSample.fullConfidenceBattles).confidence == 1)
        #expect(OpponentSample(battles: 500).confidence == 1)
    }

    @Test func battlesAreEstimatedFromLeadsOrSightings() {
        // Sightings ÷ 3 (rounded up) when it's larger than the leads logged…
        #expect(OpponentSample(leadsLogged: 2, sightings: 10).battles == 4)
        // …and the leads when more battles had a lead recorded.
        #expect(OpponentSample(leadsLogged: 9, sightings: 12).battles == 9)
        #expect(OpponentSample(leadsLogged: 0, sightings: 0).battles == 0)
        #expect(OpponentSample(battles: -4).battles == 0)
    }

    @Test func noConfidenceMeansAPlainOptimizerRun() {
        for focus in [false, true] {
            let s = TeamOptimizer.observedScales(confidence: 0, focus: focus)
            #expect(s.observedWeight == 0)
            #expect(s.autoScale == 1)
        }
    }

    @Test func fullConfidenceKeepsTodaysBehavior() {
        let focus = TeamOptimizer.observedScales(confidence: 1, focus: true)
        #expect(focus.observedWeight == 1)
        #expect(focus.autoScale == TeamOptimizer.observedFocusAutoScale)
        // Outside My Meta the ranked meta is never scaled down.
        let toggle = TeamOptimizer.observedScales(confidence: 1, focus: false)
        #expect(toggle.observedWeight == 1)
        #expect(toggle.autoScale == 1)
    }

    @Test func halfwayConfidenceBlendsAndClamps() {
        let half = TeamOptimizer.observedScales(confidence: 0.5, focus: true)
        #expect(half.observedWeight == 0.5)
        #expect(abs(half.autoScale - (1 - 0.75 * 0.5)) < 1e-12)
        let over = TeamOptimizer.observedScales(confidence: 3, focus: true)
        #expect(over.observedWeight == 1)
        let under = TeamOptimizer.observedScales(confidence: -1, focus: true)
        #expect(under.observedWeight == 0)
    }
}
