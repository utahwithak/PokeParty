//
//  TeamBuilderModel.swift
//  PokeParty
//
//  Observable state for the 3v3 Team Builder (plan Milestone 1). Holds the team
//  (an ordered list of up to three members) and runs `TeamAnalyzer` to produce
//  the grades / threats / suggested teammates, using data from the shared
//  `RankingsStore`.
//
//  Each league (format) remembers where the user left off — the saved team
//  they had open, or an unsaved draft — and restores it when they come back,
//  including after a relaunch. Edits to an open saved team autosave to it.
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

    // MARK: - Last used team per league

    /// The last-used team for each format, keyed by `RankingFormat.id`.
    private var lastUsed: [String: [TeamMember]]
    /// The format `members` currently belongs to; nil until `activate` runs.
    private var activeFormatId: String?
    private let lastUsedURL: URL

    // MARK: - Saved team being edited

    /// The saved team `members` is the live copy of; edits are written back to
    /// it as they happen. nil means a draft (members that aren't saved yet,
    /// e.g. opened from the Party Finder) or an empty builder.
    private(set) var currentTeamId: UUID?
    /// The saved team last selected in each league, by `RankingFormat.id`.
    /// A league with no entry is showing a draft (or nothing).
    private var selectedIds: [String: UUID]
    private let selectedURL: URL
    @ObservationIgnored private var savedTeams: SavedTeamsStore?

    /// Members that aren't a saved team yet.
    var isDraft: Bool { currentTeamId == nil && hasMembers }

    init(lastUsedURL: URL? = nil) {
        self.lastUsedURL = lastUsedURL ?? JSONFileStore.defaultFileURL(filename: "LastUsedTeams.json")
        selectedURL = self.lastUsedURL.deletingLastPathComponent().appendingPathComponent("SelectedTeams.json")
        lastUsed = JSONFileStore.loadValue([String: [TeamMember]].self, from: self.lastUsedURL) ?? [:]
        selectedIds = JSONFileStore.loadValue([String: UUID].self, from: selectedURL) ?? [:]
    }

    /// Connects the saved teams, so edits autosave and the last-selected team
    /// per league can be restored. Call before `activate` at launch.
    func attach(_ savedTeams: SavedTeamsStore) {
        self.savedTeams = savedTeams
        guard activeFormatId != nil else { return }
        resolveSelection()
        invalidate()
    }

    /// Points the builder at `format`, swapping in that league's last-used
    /// team (empty if there isn't one). Call whenever the selected league
    /// changes, and once at launch. A no-op if already on that format.
    func activate(format: RankingFormat) {
        guard format.id != activeFormatId else { return }
        let first = activeFormatId == nil
        activeFormatId = format.id
        if first, !members.isEmpty {
            // Members were added before the format was known — keep them.
            lastUsed[format.id] = members
        } else {
            members = lastUsed[format.id] ?? []
        }
        currentTeamId = nil
        resolveSelection()
        invalidate()
    }

    /// Makes the league's remembered saved team the one being edited, using
    /// its members (the saved copy is the truth). Leaves a draft alone when
    /// the league has no remembered team or it was since deleted.
    private func resolveSelection() {
        guard let activeFormatId, let id = selectedIds[activeFormatId],
              let team = savedTeams?.team(id: id) else { currentTeamId = nil; return }
        currentTeamId = id
        members = Array(team.members.prefix(Self.maxMembers))
    }

    private func persistSelected() {
        if let data = JSONFileStore.encode(selectedIds) {
            JSONFileStore.write(data, to: selectedURL)
        }
    }

    /// Opens a saved team for editing in its league.
    func select(_ team: Team, for format: RankingFormat) {
        activeFormatId = format.id
        members = Array(team.members.prefix(Self.maxMembers))
        currentTeamId = team.id
        selectedIds[format.id] = team.id
        persistSelected()
        invalidate()
    }

    /// A team someone asked to open as a draft while another draft in the same
    /// league was still unsaved; waits on the player's answer.
    struct PendingDraft {
        var members: [TeamMember]
        var format: RankingFormat?
    }
    private(set) var pendingDraft: PendingDraft?

    /// Opens `members` as a draft (Party Finder, Bench). If that would replace
    /// an unsaved draft in the same league, asks first (`pendingDraft`).
    func openDraft(_ members: [TeamMember], for format: RankingFormat?) {
        let sameLeague = format == nil || format?.id == activeFormatId
        if isDraft, sameLeague, members != self.members {
            pendingDraft = PendingDraft(members: members, format: format)
        } else {
            setTeam(members, for: format)
        }
    }

    func resolvePendingDraft(replace: Bool) {
        guard let pending = pendingDraft else { return }
        pendingDraft = nil
        if replace { setTeam(pending.members, for: pending.format) }
    }

    /// Picks up changes made to the open saved team from outside the builder
    /// (an import over the same name, an iCloud sync from another device).
    func syncFromSaved() {
        guard let currentTeamId, let team = savedTeams?.team(id: currentTeamId) else { return }
        let incoming = Array(team.members.prefix(Self.maxMembers))
        guard incoming != members else { return }
        members = incoming
        invalidate()
    }

    /// Marks the draft as now saved as `team`.
    func adopt(_ team: Team) {
        guard let activeFormatId else { return }
        currentTeamId = team.id
        selectedIds[activeFormatId] = team.id
        persistSelected()
    }

    /// Throws the draft away.
    func discardDraft() {
        guard isDraft else { return }
        members = []
        invalidate()
    }

    /// Deletes a saved team, emptying the builder if it was the one open.
    func deleteTeam(_ team: Team) {
        savedTeams?.delete(team)
        for (formatId, id) in selectedIds where id == team.id { selectedIds[formatId] = nil }
        persistSelected()
        if currentTeamId == team.id {
            currentTeamId = nil
            members = []
            invalidate()
        }
    }

    private func persistLastUsed() {
        guard let activeFormatId else { return }
        if members.isEmpty {
            lastUsed[activeFormatId] = nil
        } else {
            lastUsed[activeFormatId] = members
        }
        if let data = JSONFileStore.encode(lastUsed) {
            JSONFileStore.write(data, to: lastUsedURL)
        }
    }

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

    /// Swaps the member in a slot for another (no-op if that species is already on the team elsewhere).
    func replace(at index: Int, with member: TeamMember) {
        guard members.indices.contains(index),
              !members.enumerated().contains(where: { $0.offset != index && $0.element.speciesId == member.speciesId })
        else { return }
        members[index] = member
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

    func setMegaLevel(_ level: Int, at index: Int) {
        guard members.indices.contains(index), members[index].megaLevel != level else { return }
        members[index].megaLevel = level
        invalidate()
    }

    /// Sets (or clears, with `nil`) a charged-move slot (0 = first, 1 = second).
    func setChargedMove(_ id: String?, slot: Int, at index: Int) {
        guard members.indices.contains(index) else { return }
        let before = members[index]
        members[index].setChargedMove(id, slot: slot)
        guard members[index] != before else { return }
        invalidate()
    }

    /// Replaces the whole team (used when loading a saved team). Pass
    /// `format` when the caller is also switching the league, so the team
    /// lands in that league's slot rather than the one being left.
    /// The members are a draft: not tied to any saved team until saved.
    func setTeam(_ newMembers: [TeamMember], for format: RankingFormat? = nil) {
        if let format { activeFormatId = format.id }
        members = Array(newMembers.prefix(Self.maxMembers))
        currentTeamId = nil
        if let activeFormatId, selectedIds[activeFormatId] != nil {
            selectedIds[activeFormatId] = nil
            persistSelected()
        }
        invalidate()
    }

    /// Turning shadow off on a member whose species *is* the shadow form
    /// (e.g. "ampharos_shadow") also switches it to the regular species, so the
    /// name stops saying "(Shadow)". Needs `store` to confirm the regular entry exists.
    func setShadow(_ shadow: Bool, at index: Int, store: RankingsStore? = nil) {
        guard members.indices.contains(index) else { return }
        let id = members[index].speciesId
        let suffix = "_shadow"
        var changed = members[index].shadow != shadow
        members[index].shadow = shadow
        if !shadow, id.hasSuffix(suffix), let store {
            let base = String(id.dropLast(suffix.count))
            if store.pokemonById[base] != nil {
                members[index].speciesId = base
                changed = true
            }
        }
        if changed { invalidate() }
    }

    private func invalidate() {
        persistLastUsed()
        // Autosave: the saved team being edited always matches the builder.
        if let currentTeamId { savedTeams?.update(id: currentTeamId, members: members) }
        analysis = nil
        analyzeTask?.cancel()
        phase = hasMembers ? .ready : .empty
    }

    // MARK: - Building members from the data

    /// Builds a team member for a species, defaulting to its recommended moveset
    /// (from the current league's rankings) or its first available moves.
    func makeMember(speciesId: String, store: RankingsStore) -> TeamMember? {
        store.makeMember(speciesId: speciesId)
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
                fastMoveId: member.fastMoveId, chargedMoveIds: member.chargedMoveIds, megaLevel: member.megaLevel)
            // If the member has specific IVs (from the player's bench), compute
            // stats for those exact IVs at the best level under the cap.
            // Otherwise prefer the IV-optimal stats from ranking data, falling
            // back to the full optimizer for unranked mons.
            let levelCap = species.levelCap(megaLevel: member.megaLevel, isBestBuddy: member.isBestBuddy, cpCap: cpCap)
            let stats: BattlePokemon.Stats?
            if let ivs = member.ivs {
                stats = Self.statsForIVs(species: species, ivs: ivs, cpCap: cpCap, levelCap: levelCap)
            } else {
                // Ranked stats assume the species' default mega level (and
                // so its level cap), so a custom mega level recomputes them.
                stats = (member.megaLevel == nil ? Self.rankedStats(speciesId: member.speciesId, store: store) : nil)
                    ?? MatchupSimulator.optimalStats(for: combatant, cpCap: cpCap, levelCap: levelCap)
            }
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

    /// Whether each side's AI baits shields (selective, the pvpoke default) or
    /// always throws its best charged move. Takes effect on the next simulation.
    var yourTeamBaits = true
    var opponentBaits = true

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
        let baitA = yourTeamBaits
        let baitB = opponentBaits
        isBattling = true
        battleLog = nil
        battleTask = Task {
            let log = await Task.detached {
                ThreeVThreeBattle.runRecorded(
                    teamA: mine.combatants, statsA: mine.stats,
                    teamB: opp.combatants, statsB: opp.stats,
                    movesById: movesById, voluntarySwitching: true,
                    baitShieldsA: baitA, baitShieldsB: baitB)
            }.value
            if Task.isCancelled { return }
            self.battleLog = log
            self.isBattling = false
        }
    }

    /// Builds combatants + stats for a set of members. Members with specific IVs
    /// (from the player's bench) use those IVs; others use optimal / ranked stats.
    /// Internal so `TeamMetaTestModel` can reuse the same resolution logic.
    static func buildTeam(
        _ members: [TeamMember], store: RankingsStore
    ) -> (combatants: [MatchupSimulator.Combatant], stats: [BattlePokemon.Stats])? {
        let cap = store.format.cp
        var combatants: [MatchupSimulator.Combatant] = []
        var stats: [BattlePokemon.Stats] = []
        for member in members {
            guard let species = store.pokemonById[member.speciesId] else { continue }
            let c = MatchupSimulator.Combatant(species: species, shadow: member.shadow,
                                               fastMoveId: member.fastMoveId, chargedMoveIds: member.chargedMoveIds, megaLevel: member.megaLevel)
            let levelCap = species.levelCap(megaLevel: member.megaLevel, isBestBuddy: member.isBestBuddy, cpCap: cap)
            let s: BattlePokemon.Stats?
            if let ivs = member.ivs {
                s = statsForIVs(species: species, ivs: ivs, cpCap: cap, levelCap: levelCap)
            } else {
                s = (member.megaLevel == nil ? rankedStats(speciesId: member.speciesId, store: store) : nil)
                    ?? MatchupSimulator.optimalStats(for: c, cpCap: cap, levelCap: levelCap)
            }
            guard let s else { continue }
            combatants.append(c)
            stats.append(s)
        }
        return combatants.isEmpty ? nil : (combatants, stats)
    }

    /// Computes battle stats for a specific IV spread at the best level under the CP cap.
    private static func statsForIVs(
        species: Pokemon, ivs: IVs, cpCap: Int, levelCap: Double = 50
    ) -> BattlePokemon.Stats? {
        guard let r = IVCalculator.stats(
            baseAtk: species.baseStats.atk,
            baseDef: species.baseStats.def,
            baseHp: species.baseStats.hp,
            ivs: ivs, cpCap: cpCap, levelCap: levelCap) else { return nil }
        return BattlePokemon.Stats(atk: r.atk, def: r.def, hp: r.hp)
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
                  let r = RankingsStore.resolve(speciesId: entry.speciesId, pokemonById: pokemonById)
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

}
