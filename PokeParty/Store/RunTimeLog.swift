//
//  RunTimeLog.swift
//  PokeParty
//
//  Remembers how long finished Party Finder runs took, so the run button can
//  say what to expect. Speeds differ wildly between machines and debug/release
//  builds, so nothing is hardcoded: estimates come only from runs measured on
//  this device.
//
//  Two kinds of memory:
//   - the duration of a whole run, keyed by a signature of every setting that
//     drives its cost ("last run with these settings");
//   - for tournaments, seconds per 3v3 battle keyed by the battle-AI settings,
//     which extrapolates to field sizes that haven't been run yet.
//

import Foundation

nonisolated struct RunTimeLog {

    private struct Stored: Codable {
        var runs: [Entry] = []
        var battleSeconds: [String: Double] = [:]
    }

    struct Entry: Codable, Equatable {
        var signature: String
        var seconds: Double
    }

    /// Most-recent-last; older signatures are dropped past this many.
    static let maxRuns = 60
    private static let key = "teamFinderRunTimes"

    private(set) var runs: [Entry] = []
    private(set) var battleSeconds: [String: Double] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let stored = JSONFileStore.decode(Stored.self, from: data) {
            runs = stored.runs
            battleSeconds = stored.battleSeconds
        }
    }

    /// How long the last finished run with this signature took.
    func lastRun(_ signature: String) -> Double? {
        runs.last { $0.signature == signature }?.seconds
    }

    /// Seconds per 3v3 battle measured for these battle-AI settings.
    func secondsPerBattle(_ signature: String) -> Double? { battleSeconds[signature] }

    mutating func record(signature: String, seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        runs.removeAll { $0.signature == signature }
        runs.append(Entry(signature: signature, seconds: seconds))
        if runs.count > Self.maxRuns { runs.removeFirst(runs.count - Self.maxRuns) }
        save()
    }

    mutating func recordBattleRate(signature: String, battles: Int, seconds: Double) {
        guard battles > 0, seconds.isFinite, seconds > 0 else { return }
        battleSeconds[signature] = seconds / Double(battles)
        save()
    }

    private func save() {
        if let data = JSONFileStore.encode(Stored(runs: runs, battleSeconds: battleSeconds)) {
            defaults.set(data, forKey: Self.key)
        }
    }

    /// "8 s", "42 s", "3 min", "1 h 5 min" — coarse on purpose, it's an estimate.
    static func format(seconds: Double) -> String {
        let total = max(1, Int(seconds.rounded()))
        if total < 60 { return "\(total) s" }
        let minutes = Int((Double(total) / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
    }
}
