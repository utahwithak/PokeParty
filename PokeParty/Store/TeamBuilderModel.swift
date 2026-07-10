//
//  TeamBuilderModel.swift
//  PokeParty
//
//  Observable state for the 3v3 Team Builder (plan Milestone 1). Holds the team
//  (an ordered list of up to three members) and runs `TeamAnalyzer` to produce
//  the grades / threats / suggested teammates, using data from the shared
//  `RankingsStore`.
//

import SwiftUI

@MainActor
@Observable
final class TeamBuilderModel {

    enum Phase: Equatable {
        case empty          // no members yet
        case ready          // members present, not yet analyzed
        case analyzing
        case done
    }

    static let maxMembers = 3

    /// The team, in order (lead first). At most `maxMembers`.
    private(set) var members: [TeamMember] = []

    private(set) var analysis: TeamAnalysis?
    private(set) var phase: Phase = .empty

    private var analyzeTask: Task<Void, Never>?

    var hasMembers: Bool { !members.isEmpty }
    var isFull: Bool { members.count >= Self.maxMembers }

    func contains(speciesId: String) -> Bool {
        members.contains { $0.speciesId == speciesId }
    }

    // MARK: - Editing

    /// Appends a member (no-op if the team is full or already contains it).
    func add(_ member: TeamMember) {
        guard !isFull, !contains(speciesId: member.speciesId) else { return }
        members.append(member)
        invalidate()
    }

    func remove(at index: Int) {
        guard members.indices.contains(index) else { return }
        members.remove(at: index)
        invalidate()
    }

    /// Moves a member to a new position (used by the reorder controls).
    func move(from: Int, to: Int) {
        guard members.indices.contains(from), to >= 0, to < members.count, from != to else { return }
        let m = members.remove(at: from)
        members.insert(m, at: to)
        invalidate()
    }

    func setFastMove(_ id: String, at index: Int) {
        guard members.indices.contains(index), members[index].fastMoveId != id else { return }
        members[index].fastMoveId = id
        invalidate()
    }

    /// Sets (or clears, with `nil`) a charged-move slot (0 = first, 1 = second).
    func setChargedMove(_ id: String?, slot: Int, at index: Int) {
        guard members.indices.contains(index) else { return }
        var charged = members[index].chargedMoveIds
        if let id {
            // Don't allow the same move in both charged slots.
            if charged.enumerated().contains(where: { $0.offset != slot && $0.element == id }) { return }
            if slot < charged.count { charged[slot] = id } else { charged.append(id) }
        } else if slot < charged.count {
            charged.remove(at: slot)
        }
        guard !charged.isEmpty, charged != members[index].chargedMoveIds else { return }
        members[index].chargedMoveIds = charged
        invalidate()
    }

    /// Replaces the whole team (used when loading a saved team).
    func setTeam(_ newMembers: [TeamMember]) {
        members = Array(newMembers.prefix(Self.maxMembers))
        invalidate()
    }

    func setShadow(_ shadow: Bool, at index: Int) {
        guard members.indices.contains(index), members[index].shadow != shadow else { return }
        members[index].shadow = shadow
        invalidate()
    }

    private func invalidate() {
        analysis = nil
        analyzeTask?.cancel()
        phase = hasMembers ? .ready : .empty
    }

    // MARK: - Building members from the data

    /// Builds a team member for a species, defaulting to its recommended moveset
    /// (from the current league's rankings) or its first available moves.
    func makeMember(speciesId: String, store: RankingsStore) -> TeamMember? {
        guard let species = store.pokemonById[speciesId] else { return nil }
        if let entry = store.entry(id: speciesId), entry.moveset.count >= 2 {
            return TeamMember(speciesId: speciesId,
                              fastMoveId: entry.moveset[0],
                              chargedMoveIds: Array(entry.moveset[1...].prefix(2)),
                              shadow: species.isShadow)
        }
        guard let fast = species.fastMoves.first else { return nil }
        return TeamMember(speciesId: speciesId,
                          fastMoveId: fast,
                          chargedMoveIds: Array(species.chargedMoves.prefix(2)),
                          shadow: species.isShadow)
    }

    // MARK: - Analysis

    /// Runs the full team analysis against the current league's meta.
    func analyze(using store: RankingsStore) {
        analyzeTask?.cancel()
        guard hasMembers else { phase = .empty; return }

        let cpCap = store.format.cp
        let movesById = store.movesById
        let pokemonById = store.pokemonById

        var team: [MatchupSimulator.Combatant] = []
        var teamStats: [BattlePokemon.Stats] = []
        var switchesScores: [Double?] = []
        for member in members {
            guard let species = pokemonById[member.speciesId] else { continue }
            let combatant = MatchupSimulator.Combatant(
                species: species, shadow: member.shadow,
                fastMoveId: member.fastMoveId, chargedMoveIds: member.chargedMoveIds)
            // Prefer the IV-optimal stats already in the ranking data; only fall
            // back to the (expensive) IV optimizer when the mon isn't ranked.
            let stats = Self.rankedStats(speciesId: member.speciesId, store: store)
                ?? MatchupSimulator.optimalStats(for: combatant, cpCap: cpCap)
            guard let stats else { continue }
            team.append(combatant)
            teamStats.append(stats)
            switchesScores.append(store.entry(id: member.speciesId)?.switchesScore)
        }
        guard !team.isEmpty else { phase = .empty; return }

        let meta = Self.metaCandidates(from: store.entries, pokemonById: pokemonById)

        phase = .analyzing
        analyzeTask = Task {
            let result = await TeamAnalyzer.analyze(
                team: team, teamStats: teamStats, meta: meta,
                cpCap: cpCap, movesById: movesById, switchesScores: switchesScores)
            if Task.isCancelled { return }
            self.analysis = result
            self.phase = .done
        }
    }

    // MARK: - Head-to-head 3v3 battle

    /// Opponent team for the 3v3 battle viewer (species with recommended movesets).
    private(set) var opponentMembers: [TeamMember] = []
    private(set) var battleLog: TeamBattleLog?
    private(set) var isBattling = false
    private var battleTask: Task<Void, Never>?

    var opponentIsFull: Bool { opponentMembers.count >= Self.maxMembers }
    func opponentContains(speciesId: String) -> Bool {
        opponentMembers.contains { $0.speciesId == speciesId }
    }

    func addOpponent(_ member: TeamMember) {
        guard !opponentIsFull, !opponentContains(speciesId: member.speciesId) else { return }
        opponentMembers.append(member)
        battleLog = nil
    }

    /// Replaces the whole opponent team (used when loading a saved team).
    func setOpponentTeam(_ newMembers: [TeamMember]) {
        opponentMembers = Array(newMembers.prefix(Self.maxMembers))
        battleLog = nil
    }

    func removeOpponent(at index: Int) {
        guard opponentMembers.indices.contains(index) else { return }
        opponentMembers.remove(at: index)
        battleLog = nil
    }

    /// Runs a recorded 3v3 between the current team and the opponent team.
    func runTeamBattle(using store: RankingsStore) {
        battleTask?.cancel()
        guard hasMembers, !opponentMembers.isEmpty,
              let mine = Self.buildTeam(members, store: store),
              let opp = Self.buildTeam(opponentMembers, store: store) else { return }
        let movesById = store.movesById
        isBattling = true
        battleLog = nil
        battleTask = Task {
            let log = await Task.detached {
                ThreeVThreeBattle.runRecorded(
                    teamA: mine.combatants, statsA: mine.stats,
                    teamB: opp.combatants, statsB: opp.stats,
                    movesById: movesById, voluntarySwitching: true)
            }.value
            if Task.isCancelled { return }
            self.battleLog = log
            self.isBattling = false
        }
    }

    /// Builds combatants + IV-optimal stats for a set of members.
    private static func buildTeam(
        _ members: [TeamMember], store: RankingsStore
    ) -> (combatants: [MatchupSimulator.Combatant], stats: [BattlePokemon.Stats])? {
        let cap = store.format.cp
        var combatants: [MatchupSimulator.Combatant] = []
        var stats: [BattlePokemon.Stats] = []
        for member in members {
            guard let species = store.pokemonById[member.speciesId] else { continue }
            let c = MatchupSimulator.Combatant(species: species, shadow: member.shadow,
                                               fastMoveId: member.fastMoveId, chargedMoveIds: member.chargedMoveIds)
            let s = rankedStats(speciesId: member.speciesId, store: store)
                ?? MatchupSimulator.optimalStats(for: c, cpCap: cap)
            guard let s else { continue }
            combatants.append(c)
            stats.append(s)
        }
        return combatants.isEmpty ? nil : (combatants, stats)
    }

    /// The IV-optimal stats for a species from the loaded ranking data, if present.
    private static func rankedStats(speciesId: String, store: RankingsStore) -> BattlePokemon.Stats? {
        guard let s = store.entry(id: speciesId)?.stats else { return nil }
        return .init(atk: s.atk, def: s.def, hp: Int(s.hp))
    }

    /// Builds `MetaCandidate`s from the league's ranking entries. The ranking list
    /// is effectively PvPoke's filtered meta pool (plan §2.7). Each candidate
    /// carries the IV-optimal stats already present in the ranking data, so the
    /// analyzer never has to run the IV optimizer for meta Pokémon.
    private static func metaCandidates(
        from entries: [RankingEntry],
        pokemonById: [String: Pokemon]
    ) -> [MetaCandidate] {
        entries.enumerated().compactMap { index, entry in
            guard entry.moveset.count >= 2,
                  let r = resolve(speciesId: entry.speciesId, pokemonById: pokemonById)
            else { return nil }
            let stats = entry.stats.map {
                BattlePokemon.Stats(atk: $0.atk, def: $0.def, hp: Int($0.hp))
            }
            return MetaCandidate(
                species: r.species,
                shadow: r.shadow,
                fastMoveId: entry.moveset[0],
                chargedMoveIds: Array(entry.moveset[1...]),
                familyId: r.species.family?.id,
                // APPROX: treat the top of the ranking list as the "meta group".
                metaRelevant: index < 40,
                precomputedStats: stats)
        }
    }

    /// Resolves a ranking-entry species id to its species + shadow flag.
    /// (Mirrors RankingsStore's private resolver.)
    private static func resolve(
        speciesId: String, pokemonById: [String: Pokemon]
    ) -> (species: Pokemon, shadow: Bool)? {
        var species = pokemonById[speciesId]
        if species == nil, speciesId.hasSuffix("_shadow") {
            species = pokemonById[String(speciesId.dropLast("_shadow".count))]
        }
        guard let species else { return nil }
        return (species, species.isShadow || speciesId.hasSuffix("_shadow"))
    }
}
