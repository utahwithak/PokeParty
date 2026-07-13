//
//  RankingsStore.swift
//  PokeParty
//
//  Observable state backing the rankings browser.
//

import SwiftUI

/// Drives the rankings UI: holds the loaded gamemaster lookups, the rankings for
/// the selected league, and the current loading/search state.
@MainActor
@Observable
final class RankingsStore {

    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    /// The format (core league or cup) currently being viewed. Changing it
    /// loads that format's rankings.
    var format: RankingFormat = .great {
        didSet {
            guard format != oldValue else { return }
            Task { await loadRankings() }
        }
    }

    var searchText: String = ""
    private(set) var phase: Phase = .loading
    private(set) var entries: [RankingEntry] = [] {
        didSet {
            rankBySpeciesId = Dictionary(
                uniqueKeysWithValues: entries.enumerated().map { ($1.speciesId, $0 + 1) }
            )
        }
    }
    /// 1-based overall rank for each species in the current league.
    private(set) var rankBySpeciesId: [String: Int] = [:]
    private(set) var pokemonById: [String: Pokemon] = [:]
    private(set) var movesById: [String: Move] = [:]
    /// All Pokémon, dex-sorted, for the Rank Checker's search.
    private(set) var allPokemon: [Pokemon] = []
    /// Active limited cups (e.g. Summer Cup) with published rankings.
    private(set) var cupFormats: [RankingFormat] = []

    /// Per-format cache so switching back to a format is instant.
    private var rankingsCache: [RankingFormat: [RankingEntry]] = [:]
    private var gameMasterLoaded = false

    private let service = DataService.shared

    /// A ranking row: its 1-based standing within the full league list.
    struct RankedEntry: Identifiable {
        let rank: Int
        let entry: RankingEntry
        var id: String { entry.id }
    }

    /// Entries paired with their true rank, filtered by the current search text.
    /// Ranks reflect overall standing, so they stay correct while searching.
    var rankedEntries: [RankedEntry] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return entries.enumerated().compactMap { index, entry in
            if !query.isEmpty, !entry.speciesName.localizedCaseInsensitiveContains(query) {
                return nil
            }
            return RankedEntry(rank: index + 1, entry: entry)
        }
    }

    // MARK: - Loading

    /// Loads the gamemaster (once) and the current league's rankings.
    func load(policy: DataService.LoadPolicy = .cache) async {
        phase = .loading
        await loadGameMasterIfNeeded(policy: policy)
        await loadRankings(policy: policy)
    }

    /// Re-checks the server for newer data (cheap ETag revalidation).
    func refresh() async {
        gameMasterLoaded = false
        rankingsCache.removeAll()
        await load(policy: .revalidate)
    }

    /// Wipes the on-disk cache and re-downloads everything from scratch.
    func rebuildCache() async {
        await service.clearCache()
        gameMasterLoaded = false
        rankingsCache.removeAll()
        await load(policy: .reload)
    }

    private func loadGameMasterIfNeeded(policy: DataService.LoadPolicy = .cache) async {
        guard !gameMasterLoaded else { return }
        do {
            let gm = try await service.gameMaster(policy: policy)
            pokemonById = Dictionary(gm.pokemon.map { ($0.speciesId, $0) }, uniquingKeysWith: { first, _ in first })
            movesById = Dictionary(gm.moves.map { ($0.moveId, $0) }, uniquingKeysWith: { first, _ in first })
            allPokemon = gm.pokemon
                .filter { $0.released != false && !($0.tags?.contains("shadow") ?? false) }
                .sorted { ($0.dex, $0.speciesName) < ($1.dex, $1.speciesName) }
            cupFormats = (gm.formats ?? []).filter { !$0.isCoreLeague && $0.hasRankings && $0.showFormat == true }
            gameMasterLoaded = true
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func loadRankings(policy: DataService.LoadPolicy = .cache) async {
        guard gameMasterLoaded else { return }

        if let cached = rankingsCache[format] {
            entries = cached
            phase = .loaded
            return
        }

        phase = .loading
        do {
            let loaded = try await service.rankings(for: format, policy: policy)
            rankingsCache[format] = loaded
            entries = loaded
            phase = .loaded
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Rankings for an arbitrary format, sharing the browser's per-format cache
    /// (used by tools pinned to one league, like Breakpoints).
    func rankings(for format: RankingFormat) async throws -> [RankingEntry] {
        if let cached = rankingsCache[format] { return cached }
        let loaded = try await service.rankings(for: format)
        rankingsCache[format] = loaded
        return loaded
    }

    // MARK: - Lookups

    func entry(id: RankingEntry.ID) -> RankingEntry? {
        entries.first { $0.id == id }
    }

    func pokemon(for entry: RankingEntry) -> Pokemon? {
        pokemonById[entry.speciesId]
    }

    func move(id: String) -> Move? {
        movesById[id]
    }

    /// Resolves a species id to its display name, falling back to a prettified id.
    func name(forSpeciesId id: String) -> String {
        pokemonById[id]?.speciesName
            ?? id.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Every Pokémon in the same evolution family as `id` (the line shares a
    /// `family.id`), dex-sorted. Falls back to just the Pokémon itself.
    func family(for id: String) -> [Pokemon] {
        guard let pokemon = pokemonById[id] else { return [] }
        guard let familyId = pokemon.family?.id else { return [pokemon] }
        let members = allPokemon.filter { $0.family?.id == familyId }
        return members.isEmpty ? [pokemon] : members
    }

    // MARK: - Live matchup simulation

    /// Resolves the species (and shadow flag) for a ranking-entry species id.
    nonisolated static func resolve(
        speciesId: String, pokemonById: [String: Pokemon]
    ) -> (species: Pokemon, shadow: Bool)? {
        // Shadow Pokémon are their own gamemaster entries (tagged "shadow");
        // fall back to stripping a "_shadow" suffix if the entry is ever missing.
        var species = pokemonById[speciesId]
        if species == nil, speciesId.hasSuffix("_shadow") {
            species = pokemonById[String(speciesId.dropLast("_shadow".count))]
        }
        guard let species else { return nil }
        return (species, species.isShadow || speciesId.hasSuffix("_shadow"))
    }

    /// Builds a combatant from a ranking entry's recommended moveset.
    nonisolated static func combatant(
        for entry: RankingEntry,
        pokemonById: [String: Pokemon]
    ) -> MatchupSimulator.Combatant? {
        guard let r = resolve(speciesId: entry.speciesId, pokemonById: pokemonById),
              entry.moveset.count >= 2 else { return nil }
        return .init(species: r.species, shadow: r.shadow,
                     fastMoveId: entry.moveset[0], chargedMoveIds: Array(entry.moveset[1...]))
    }

    /// Simulates `entry` (using the given moveset) against every other Pokémon in
    /// the loaded league at the given shield counts, returning each opponent's
    /// battle rating from `entry`'s perspective, sorted best-first. Opponents use
    /// their own recommended movesets. Runs across all CPU cores.
    func simulateMatchups(
        for entry: RankingEntry,
        fastMoveId: String,
        chargedMoveIds: [String],
        yourShields: Int,
        opponentShields: Int,
        maxOpponents: Int = .max
    ) async -> [RankingEntry.Matchup] {
        let cap = format.cp
        let moves = movesById
        let pokes = pokemonById
        // Fast enough (≈0.3s parallel) to run the whole league; cap is optional.
        let allEntries = Array(entries.prefix(maxOpponents))
        guard let r = Self.resolve(speciesId: entry.speciesId, pokemonById: pokes),
              !chargedMoveIds.isEmpty else { return [] }
        let me = MatchupSimulator.Combatant(species: r.species, shadow: r.shadow,
                                            fastMoveId: fastMoveId, chargedMoveIds: chargedMoveIds)
        guard let meStats = MatchupSimulator.optimalStats(for: me, cpCap: cap) else { return [] }

        return await withTaskGroup(of: RankingEntry.Matchup?.self) { group in
            for opp in allEntries where opp.speciesId != entry.speciesId {
                group.addTask {
                    // `me` stats are computed once and reused; each opponent's
                    // stats are computed once here (fast, no battle in the IV calc).
                    guard let oppCombatant = Self.combatant(for: opp, pokemonById: pokes),
                          let oppStats = MatchupSimulator.optimalStats(for: oppCombatant, cpCap: cap),
                          let result = MatchupSimulator.rate(
                            me, statsA: meStats, oppCombatant, statsB: oppStats,
                            movesById: moves, shieldsA: yourShields, shieldsB: opponentShields)
                    else { return nil }
                    return RankingEntry.Matchup(opponent: opp.speciesId, rating: result.a)
                }
            }
            var results: [RankingEntry.Matchup] = []
            for await m in group { if let m { results.append(m) } }
            return results.sorted { $0.rating > $1.rating }
        }
    }

    /// The optimal-shield timeline for a matchup plus the win/loss breakdown across
    /// every shield scenario (M8.2).
    struct MatchupReplay: Sendable {
        let log: BattleLog
        let scenario: ShieldSearch.Solution
    }

    /// Records a single matchup — `entry` (with the given moveset) vs one opponent
    /// (using its recommended moveset) at the given shields — under optimal shield
    /// play, returning the timeline + scenario stats. Synchronous; a 1v1 is fast.
    func battleReplay(
        for entry: RankingEntry,
        fastMoveId: String, chargedMoveIds: [String],
        opponentId: String,
        yourShields: Int, opponentShields: Int
    ) -> MatchupReplay? {
        let cap = format.cp
        guard let meR = Self.resolve(speciesId: entry.speciesId, pokemonById: pokemonById),
              !chargedMoveIds.isEmpty else { return nil }
        let me = MatchupSimulator.Combatant(species: meR.species, shadow: meR.shadow,
                                            fastMoveId: fastMoveId, chargedMoveIds: chargedMoveIds)

        // Opponent: its recommended moveset from the rankings, else its first moves.
        let opp: MatchupSimulator.Combatant
        if let oppEntry = self.entry(id: opponentId), let c = Self.combatant(for: oppEntry, pokemonById: pokemonById) {
            opp = c
        } else if let r = Self.resolve(speciesId: opponentId, pokemonById: pokemonById),
                  let fast = r.species.fastMoves.first {
            opp = MatchupSimulator.Combatant(species: r.species, shadow: r.shadow,
                                             fastMoveId: fast, chargedMoveIds: Array(r.species.chargedMoves.prefix(2)))
        } else {
            return nil
        }

        guard let meStats = MatchupSimulator.optimalStats(for: me, cpCap: cap),
              let oppStats = MatchupSimulator.optimalStats(for: opp, cpCap: cap),
              // Solve the shield game once, then replay the optimal line with recording.
              let sol = ShieldSearch.optimal(me, statsA: meStats, opp, statsB: oppStats,
                                             movesById: movesById,
                                             shieldsA: yourShields, shieldsB: opponentShields),
              let log = ShieldSearch.play(me, statsA: meStats, opp, statsB: oppStats,
                                          movesById: movesById,
                                          shieldsA: yourShields, shieldsB: opponentShields,
                                          policyA: sol.policyA, policyB: sol.policyB, record: true)?.log
        else { return nil }

        return MatchupReplay(log: log, scenario: sol)
    }
}
