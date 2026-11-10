//
//  RunTimeLogTests.swift
//  PokePartyTests
//
//  The persisted run-time memory behind the Party Finder's time estimate, and
//  sanity checks on the effort presets. Uses a throwaway UserDefaults suite so
//  the real saved settings are never touched.
//

import Foundation
import Testing
@testable import PokeParty

private func scratchDefaults() -> UserDefaults {
    let name = "RunTimeLogTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Suite struct RunTimeLogTests {

    @Test func remembersTheLastRunPerSignature() {
        var log = RunTimeLog(defaults: scratchDefaults())
        #expect(log.lastRun("a") == nil)
        log.record(signature: "a", seconds: 12)
        log.record(signature: "b", seconds: 30)
        log.record(signature: "a", seconds: 9)            // newer run replaces the old one
        #expect(log.lastRun("a") == 9)
        #expect(log.lastRun("b") == 30)
        #expect(log.runs.count == 2)
    }

    @Test func persistsAcrossInstances() {
        let defaults = scratchDefaults()
        var log = RunTimeLog(defaults: defaults)
        log.record(signature: "a", seconds: 7)
        log.recordBattleRate(signature: "ai", battles: 1000, seconds: 5)

        let reloaded = RunTimeLog(defaults: defaults)
        #expect(reloaded.lastRun("a") == 7)
        #expect(reloaded.secondsPerBattle("ai") == 0.005)
    }

    @Test func ignoresNonsenseMeasurements() {
        var log = RunTimeLog(defaults: scratchDefaults())
        log.record(signature: "a", seconds: 0)
        log.record(signature: "a", seconds: .nan)
        log.recordBattleRate(signature: "ai", battles: 0, seconds: 5)
        #expect(log.runs.isEmpty)
        #expect(log.secondsPerBattle("ai") == nil)
    }

    @Test func dropsTheOldestRunsPastTheCap() {
        var log = RunTimeLog(defaults: scratchDefaults())
        for i in 0..<(RunTimeLog.maxRuns + 5) { log.record(signature: "s\(i)", seconds: 1) }
        #expect(log.runs.count == RunTimeLog.maxRuns)
        #expect(log.lastRun("s0") == nil)
        #expect(log.lastRun("s\(RunTimeLog.maxRuns + 4)") == 1)
    }

    @Test func formatsDurationsCoarsely() {
        #expect(RunTimeLog.format(seconds: 0.2) == "1 s")
        #expect(RunTimeLog.format(seconds: 42) == "42 s")
        #expect(RunTimeLog.format(seconds: 90) == "2 min")
        #expect(RunTimeLog.format(seconds: 3600) == "1 h")
        #expect(RunTimeLog.format(seconds: 3900) == "1 h 5 min")
    }

    @MainActor @Test func presetsFitTheirSlidersAndEscalate() {
        for preset in TeamFinderModel.Preset.allCases {
            #expect(TeamFinderModel.poolSizes.contains(preset.poolSize))
            #expect(TeamFinderModel.fieldSizeRange.contains(Double(preset.fieldSize)))
            #expect(Double(preset.fieldSize).truncatingRemainder(dividingBy: TeamFinderModel.fieldSizeStep) == 0)
            #expect(TeamFinderModel.restartRange.contains(Double(preset.restarts)))
            #expect(Double(preset.restarts).truncatingRemainder(dividingBy: TeamFinderModel.restartStep) == 0)
        }
        let p = TeamFinderModel.Preset.self
        #expect(p.quick.poolSize < p.balanced.poolSize && p.balanced.poolSize < p.thorough.poolSize)
        #expect(p.quick.fieldSize < p.balanced.fieldSize && p.balanced.fieldSize < p.thorough.fieldSize)
        #expect(p.quick.restarts < p.balanced.restarts && p.balanced.restarts < p.thorough.restarts)
    }
}
