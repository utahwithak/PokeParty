//
//  BattleHistoryStore.swift
//  PokeParty
//
//  The Battle HUD's record of games played: the battle in progress (logged as
//  the screen changes) and every earlier one, grouped into sets. Persisted as
//  one JSON file in Application Support.
//

import Foundation
import Observation

/// One set of five games and how it's going.
struct BattleSetSummary: Identifiable {
    let id: UUID
    let battles: [RecordedBattle]

    var wins: Int { battles.filter { $0.outcome == .win }.count }
    var losses: Int { battles.filter { $0.outcome == .loss }.count }
    var decided: Int { wins + losses }
    var date: Date { battles.first?.date ?? .distantPast }
}

/// How the sim's calls compare with what happened, over many games.
struct BattleInsights: Equatable {
    var games = 0
    var wins = 0
    /// Games where the sim called the actual leads a win.
    var simPredictedWins = 0
    var diagnoses: [BattleDiagnosis: Int] = [:]

    var realWinRate: Double { games == 0 ? 0 : Double(wins) / Double(games) }
    var simWinRate: Double { games == 0 ? 0 : Double(simPredictedWins) / Double(games) }
}

@MainActor
@Observable
final class BattleHistoryStore {

    /// Games in a Pokémon GO set, unless the player starts a new one sooner.
    static let setSize = 5

    /// Oldest first. The battle in progress, if any, is the one with `currentId`.
    private(set) var battles: [RecordedBattle]
    private(set) var currentId: UUID?
    private var currentSetId: UUID
    private var recorder = BattleLogRecorder()
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        let url = fileURL ?? JSONFileStore.defaultFileURL(filename: "BattleHistory.json")
        self.fileURL = url
        let loaded: [RecordedBattle] = JSONFileStore.load(from: url)
        battles = loaded
        currentSetId = loaded.last?.setId ?? UUID()
    }

    // MARK: - Reading

    var current: RecordedBattle? { battles.first { $0.id == currentId } }

    /// The game the HUD shows: the one picked (`selectedId`), else the one in
    /// progress. Between games (after "New battle") that's nothing, so the old
    /// game's log doesn't linger; it's still in the set to pick.
    func displayed(selectedId: UUID?) -> RecordedBattle? {
        if let selectedId, let picked = battles.first(where: { $0.id == selectedId }) { return picked }
        return current
    }

    /// The set the next (or current) game belongs to.
    var currentSet: BattleSetSummary {
        BattleSetSummary(id: currentSetId, battles: battles.filter { $0.setId == currentSetId })
    }

    /// Every set, newest first.
    var sets: [BattleSetSummary] {
        Dictionary(grouping: battles, by: \.setId)
            .map { BattleSetSummary(id: $0.key, battles: $0.value) }
            .sorted { $0.date > $1.date }
    }

    /// Sim-vs-reality numbers over the decided games that match `filter`.
    func insights(where filter: (RecordedBattle) -> Bool = { _ in true }) -> BattleInsights {
        var result = BattleInsights()
        for battle in battles where battle.outcome != nil && filter(battle) {
            result.games += 1
            if battle.outcome == .win { result.wins += 1 }
            if battle.simPredictsWin == true { result.simPredictedWins += 1 }
            if let diagnosis = battle.diagnosis { result.diagnoses[diagnosis, default: 0] += 1 }
        }
        return result
    }

    // MARK: - Recording

    /// Feeds the battle in progress the HUD's latest view of it, creating the
    /// battle the first time there's a team and an opponent to log.
    func observe(_ observation: BattleObservation, team: [TeamMember], opponents: [TeamMember],
                 format: RankingFormat, at time: Date = Date()) {
        guard !team.isEmpty, !opponents.isEmpty else { return }
        ensureCurrent(format: format)
        guard let index = battles.firstIndex(where: { $0.id == currentId }) else { return }

        recorder.observe(observation, team: team.map(\.speciesId), opponents: opponents.map(\.speciesId), at: time)

        var battle = battles[index]
        battle.team = team
        battle.opponents = opponents
        battle.events = recorder.events
        // Three of a side down is the end of the game.
        if battle.outcome == nil || battle.outcomeDetected {
            if team.count == 3, observation.myFainted.count >= 3 {
                battle.outcome = .loss; battle.outcomeDetected = true
            } else if observation.opponentFainted.count >= 3 {
                battle.outcome = .win; battle.outcomeDetected = true
            }
        }
        if battle != battles[index] {
            battles[index] = battle
            save()
        }
    }

    /// An effectiveness label flashed on a hit to your Pokémon.
    func observeFlash(superEffective: Bool, targetMine: Bool, _ observation: BattleObservation, team: [TeamMember],
                      opponents: [TeamMember], at time: Date = Date()) {
        guard let index = battles.firstIndex(where: { $0.id == currentId }) else { return }
        recorder.observeFlash(superEffective: superEffective, targetMine: targetMine, now: observation,
                              team: team.map(\.speciesId), opponents: opponents.map(\.speciesId), at: time)
        battles[index].events = recorder.events
    }

    /// A charged move's banner was read for one side's active Pokémon.
    func observeCharged(moveId: String?, mine: Bool, _ observation: BattleObservation, team: [TeamMember],
                        opponents: [TeamMember], at time: Date = Date()) {
        guard let index = battles.firstIndex(where: { $0.id == currentId }) else { return }
        recorder.observeCharged(moveId: moveId, mine: mine, now: observation,
                                team: team.map(\.speciesId), opponents: opponents.map(\.speciesId), at: time)
        battles[index].events = recorder.events
        save()
    }

    /// The result screen said who won. Counts unless the player already marked
    /// the game by hand. Returns the game's id when this is news worth a review
    /// (a changed result, or one not yet reviewed).
    func observeResult(_ outcome: BattleOutcome) -> UUID? {
        guard let index = battles.firstIndex(where: { $0.id == currentId }),
              battles[index].outcome == nil || battles[index].outcomeDetected else { return nil }
        let changed = battles[index].outcome != outcome
        battles[index].outcome = outcome
        battles[index].outcomeDetected = true
        save()
        return changed || battles[index].simPredictsWin == nil ? battles[index].id : nil
    }

    /// Lines the phone read off the screen, kept with the game. A line still on
    /// screen is sent again now and then, so repeats close together are dropped.
    func observeScreenText(_ lines: [ScreenLine], at time: Date = Date()) {
        guard let index = battles.firstIndex(where: { $0.id == currentId }) else { return }
        let elapsed = recorder.elapsed(at: time)
        var changed = false
        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.filter(\.isLetter).count >= 3 else { continue }
            let key = text.lowercased()
            let repeated = battles[index].screenText.suffix(40).contains {
                $0.text.lowercased() == key && elapsed - $0.elapsed < Self.screenTextRepeat
            }
            if repeated { continue }
            battles[index].screenText.append(ScreenTextEntry(elapsed: elapsed, text: text, y: line.y))
            changed = true
        }
        // A long game of noisy OCR shouldn't grow the file without bound.
        if battles[index].screenText.count > Self.screenTextLimit {
            battles[index].screenText.removeFirst(battles[index].screenText.count - Self.screenTextLimit)
        }
        if changed { save() }
    }

    private static let screenTextRepeat: TimeInterval = 5
    private static let screenTextLimit = 600

    /// Whose charged move was logged in the last few seconds (true: yours), if any.
    func recentChargedThrower(at time: Date = Date()) -> Bool? {
        recorder.recentChargedThrower(at: time)
    }

    /// The charged move logged in the last few seconds, if any.
    func recentCharged(at time: Date = Date()) -> BattleLogEvent? {
        recorder.recentCharged(at: time)
    }

    /// Whether the battle in progress has got far enough that a fresh-looking
    /// screen (everyone at full strength) must be a different battle.
    var currentIsFinished: Bool {
        recorder.hasFaint || current?.outcome != nil
    }

    /// Closes the battle in progress (dropping it if nothing was logged) so the
    /// next observation starts a new one.
    func startNewBattle() {
        if let index = battles.firstIndex(where: { $0.id == currentId }), !battles[index].hasContent {
            battles.remove(at: index)
        }
        currentId = nil
        recorder.reset()
        save()
    }

    /// Starts a fresh set; the next battle is game one of it.
    func startNewSet() {
        startNewBattle()
        currentSetId = UUID()
    }

    /// Throws away every game in the current set, including the one in
    /// progress, and starts it again from 0–0. (Unlike `startNewSet`, which
    /// keeps the old set in the history.)
    func resetSet() {
        let setId = currentSetId
        battles.removeAll { $0.setId == setId }
        currentId = nil
        recorder.reset()
        save()
    }

    private func ensureCurrent(format: RankingFormat) {
        if let currentId, battles.contains(where: { $0.id == currentId }) { return }
        // A set is five games, however they went (or were marked); the next game starts a new one.
        if currentSet.battles.count >= Self.setSize { currentSetId = UUID() }
        let battle = RecordedBattle(setId: currentSetId, cup: format.cup, cp: format.cp)
        battles.append(battle)
        currentId = battle.id
        recorder.reset()
    }

    // MARK: - Marking

    /// Marks a game won or lost; nil clears it. A mark by hand always wins over
    /// what the screen suggested.
    func mark(_ id: UUID, as outcome: BattleOutcome?) {
        guard let index = battles.firstIndex(where: { $0.id == id }) else { return }
        battles[index].outcome = outcome
        battles[index].outcomeDetected = false
        if outcome == nil { battles[index].simPredictsWin = nil; battles[index].diagnosis = nil }
        save()
    }

    func setReview(_ id: UUID, simPredictsWin: Bool?, diagnosis: BattleDiagnosis?) {
        guard let index = battles.firstIndex(where: { $0.id == id }) else { return }
        battles[index].simPredictsWin = simPredictsWin
        battles[index].diagnosis = diagnosis
        save()
    }

    func delete(_ id: UUID) {
        battles.removeAll { $0.id == id }
        if currentId == id { currentId = nil; recorder.reset() }
        save()
    }

    private func save() {
        guard let data = JSONFileStore.encode(battles) else { return }
        JSONFileStore.write(data, to: fileURL)
    }
}
