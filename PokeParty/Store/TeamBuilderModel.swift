//
//  TeamBuilderModel.swift
//  PokeParty
//
//  Observable state for the 3v3 Team Builder (plan Milestone 1). Holds the three
//  team slots and runs `TeamAnalyzer` to produce the grades / threats / suggested
//  teammates, using data from the shared `RankingsStore`.
//

import SwiftUI

@MainActor
@Observable
final class TeamBuilderModel {

    enum Phase: Equatable {
        case empty          // no members yet
        case ready          // members present, not analyzed
        case analyzing
        case done
    }

    /// Three team slots; `nil` is an empty slot.
    var slots: [TeamMember?] = [nil, nil, nil]

    private(set) var analysis: TeamAnalysis?
    private(set) var phase: Phase = .empty

    private var analyzeTask: Task<Void, Never>?

    var members: [TeamMember] { slots.compactMap { $0 } }
    var hasMembers: Bool { !members.isEmpty }

    // MARK: - Editing

    /// Adds a member to the first empty slot (no-op if the team is full).
    func add(_ member: TeamMember) {
        guard let idx = slots.firstIndex(where: { $0 == nil }) else { return }
        slots[idx] = member
        invalidate()
    }

    func setMember(_ member: TeamMember?, at index: Int) {
        guard slots.indices.contains(index) else { return }
        slots[index] = member
        invalidate()
    }

    func removeMember(at index: Int) {
        guard slots.indices.contains(index) else { return }
        slots[index] = nil
        invalidate()
    }

    /// Whether a species is already on the team.
    func contains(speciesId: String) -> Bool {
        members.contains { $0.speciesId == speciesId }
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
        // Prefer the ranked recommended moveset.
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

        // Resolve the team members into combatants + optimal stats (on main; only 3).
        var team: [MatchupSimulator.Combatant] = []
        var teamStats: [BattlePokemon.Stats] = []
        for member in members {
            guard let species = pokemonById[member.speciesId] else { continue }
            let combatant = MatchupSimulator.Combatant(
                species: species, shadow: member.shadow,
                fastMoveId: member.fastMoveId, chargedMoveIds: member.chargedMoveIds)
            guard let stats = MatchupSimulator.optimalStats(for: combatant, cpCap: cpCap) else { continue }
            team.append(combatant)
            teamStats.append(stats)
        }
        guard !team.isEmpty else { phase = .empty; return }

        // Build the meta candidate pool from the loaded ranking list.
        let meta = Self.metaCandidates(from: store.entries, pokemonById: pokemonById)

        phase = .analyzing
        analyzeTask = Task {
            let result = await TeamAnalyzer.analyze(
                team: team, teamStats: teamStats, meta: meta,
                cpCap: cpCap, movesById: movesById)
            if Task.isCancelled { return }
            self.analysis = result
            self.phase = .done
        }
    }

    /// Builds `MetaCandidate`s from the league's ranking entries. The ranking list
    /// is effectively PvPoke's filtered meta pool (plan §2.7).
    private static func metaCandidates(
        from entries: [RankingEntry],
        pokemonById: [String: Pokemon]
    ) -> [MetaCandidate] {
        entries.enumerated().compactMap { index, entry in
            guard entry.moveset.count >= 2,
                  let r = resolve(speciesId: entry.speciesId, pokemonById: pokemonById)
            else { return nil }
            return MetaCandidate(
                species: r.species,
                shadow: r.shadow,
                fastMoveId: entry.moveset[0],
                chargedMoveIds: Array(entry.moveset[1...]),
                familyId: r.species.family?.id,
                // APPROX: treat the top of the ranking list as the "meta group".
                metaRelevant: index < 40)
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
