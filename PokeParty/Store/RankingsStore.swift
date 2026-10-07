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
            reloadRankings()
        }
    }

    /// The in-flight rankings load, if any — cancelled and replaced on every
    /// `format`/`rankingSource` change so a slow, superseded request can
    /// never overwrite what a later, faster one already displayed (e.g.
    /// clicking through leagues quickly, or a PvPoke fallback resolving
    /// after the local ranking it was standing in for already loaded).
    private var loadTask: Task<Void, Never>?

    private func reloadRankings() {
        loadTask?.cancel()
        loadTask = Task { await loadRankings() }
    }

    var searchText: String = ""
    private(set) var phase: Phase = .loading
    private(set) var entries: [RankingEntry] = [] {
        didSet {
            rankBySpeciesId = Dictionary(
                uniqueKeysWithValues: entries.enumerated().map { ($1.speciesId, $0 + 1) }
            )
            entryBySpeciesId = Dictionary(uniqueKeysWithValues: entries.map { ($0.speciesId, $0) })
        }
    }
    /// 1-based overall rank for each species in the current league.
    private(set) var rankBySpeciesId: [String: Int] = [:]
    /// O(1) index for `entry(id:)`, kept in sync with `entries`.
    private(set) var entryBySpeciesId: [String: RankingEntry] = [:]
    private(set) var pokemonById: [String: Pokemon] = [:]
    private(set) var movesById: [String: Move] = [:]
    /// All Pokémon, dex-sorted, for the Rank Checker's search. Excludes Mega
    /// Evolutions, which are banned outside the dedicated Mega cups — use
    /// `eligiblePokemon(for:)` where the current format matters (e.g. the
    /// Team Builder's add palette).
    private(set) var allPokemon: [Pokemon] = []
    /// `allPokemon` plus Mega Evolutions, dex-sorted, for formats that allow
    /// them (see `RankingFormat.allowsMegaEvolution`).
    private(set) var allPokemonIncludingMegas: [Pokemon] = []
    /// Active limited cups (e.g. Summer Cup) with published rankings.
    private(set) var cupFormats: [RankingFormat] = []
    /// Every cup's eligibility rules — `MetaPool`'s filter input, not just
    /// the currently-active `cupFormats`.
    private(set) var cups: [Cup] = []
    /// Species banned from Great/Ultra League regardless of cup filters.
    private(set) var greatLeagueIneligible: [String] = []
    /// Every released Pokémon INCLUDING shadow-tagged entries (unlike
    /// `allPokemon`/`allPokemonIncludingMegas`, which drop shadows since
    /// those are represented via a toggle, not separate picker rows) — the
    /// local Ranker needs shadows as their own distinct pool members, same
    /// as PvPoke's own rankings do.
    private(set) var allPokemonIncludingShadows: [Pokemon] = []
    /// A hash of the currently-loaded gamemaster data — `LocalRankingBuilder`
    /// compares this against each cached local ranking to detect staleness.
    private(set) var gameMasterHash: String = ""

    /// Where the displayed ranking ORDER comes from — PvPoke's own
    /// precomputed list, or the locally-computed `Ranker`. Persisted
    /// locally, same inline pattern as `showMegaEvolutions`.
    enum RankingSource: String {
        case pvpoke
        case local
    }
    var rankingSource: RankingSource = RankingSource(
        rawValue: UserDefaults.standard.string(forKey: RankingsStore.rankingSourceKey) ?? ""
    ) ?? .pvpoke {
        didSet {
            guard rankingSource != oldValue else { return }
            UserDefaults.standard.set(rankingSource.rawValue, forKey: RankingsStore.rankingSourceKey)
            Task { await loadRankings() }
        }
    }
    private static let rankingSourceKey = "RankingSource"

    /// Keeps the 3 core leagues' local rankings warm in the background,
    /// regardless of `rankingSource` — see `LocalRankingBuilder`.
    let localRankingBuilder = LocalRankingBuilder()

    init() {
        // A background build can finish (or get skipped because another one
        // was already running) well after `loadRankings()` last checked —
        // without this, the currently-viewed format could be stuck showing
        // PvPoke's fallback rankings even once its local version is ready,
        // or never get its on-demand build re-queued after being dropped.
        localRankingBuilder.onIdle = { [weak self] in
            guard let self, self.rankingSource == .local else { return }
            Task { await self.loadRankings() }
        }
    }

    /// User preference (Settings): let Mega Evolutions be picked in any
    /// format/tool, not just a dedicated Mega cup — lets players compare or
    /// build with Megas even when no Mega cup is active. Persisted locally.
    var showMegaEvolutions: Bool = UserDefaults.standard.bool(forKey: RankingsStore.showMegaEvolutionsKey) {
        didSet {
            guard showMegaEvolutions != oldValue else { return }
            UserDefaults.standard.set(showMegaEvolutions, forKey: RankingsStore.showMegaEvolutionsKey)
        }
    }
    private static let showMegaEvolutionsKey = "ShowMegaEvolutions"

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
            let (gm, rawData) = try await service.gameMasterWithRawData(policy: policy)
            pokemonById = Dictionary(gm.pokemon.map { ($0.speciesId, $0) }, uniquingKeysWith: { first, _ in first })
            movesById = Dictionary(gm.moves.map { ($0.moveId, $0) }, uniquingKeysWith: { first, _ in first })
            allPokemonIncludingMegas = gm.pokemon
                .filter { $0.released != false && !($0.tags?.contains("shadow") ?? false) }
                .sorted { ($0.dex, $0.speciesName) < ($1.dex, $1.speciesName) }
            allPokemon = allPokemonIncludingMegas.filter { !$0.isMegaEvolution }
            allPokemonIncludingShadows = gm.pokemon.filter { $0.released != false }
            cupFormats = (gm.formats ?? []).filter { !$0.isCoreLeague && $0.hasRankings && $0.showFormat == true }
            cups = gm.cups ?? []
            greatLeagueIneligible = gm.greatLeagueIneligible ?? []
            gameMasterHash = LocalRankingBuilder.hash(of: rawData)
            buildFamilyGraph()
            gameMasterLoaded = true

            localRankingBuilder.rebuildCoreLeaguesIfStale(context: gameMasterContext)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func loadRankings(policy: DataService.LoadPolicy = .cache) async {
        guard gameMasterLoaded else { return }

        if rankingSource == .local {
            if let local = localRankingBuilder.cachedEntries(formatId: format.id, gameMasterHash: gameMasterHash) {
                entries = local
                phase = .loaded
                return
            }
            // Not ready yet — kick a background build and fall through to
            // PvPoke's rankings so the UI never blocks on it.
            localRankingBuilder.buildIfStale(format: format, context: gameMasterContext)
        }

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

    private var gameMasterContext: LocalRankingBuilder.GameMasterContext {
        .init(hash: gameMasterHash, allPokemon: allPokemonIncludingShadows,
              greatLeagueIneligible: greatLeagueIneligible, cups: cups, movesById: movesById)
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
        entryBySpeciesId[id]
    }

    func pokemon(for entry: RankingEntry) -> Pokemon? {
        pokemonById[entry.speciesId]
    }

    /// The roster to offer for a given format: includes Mega Evolutions when
    /// that format's cup allows them, or when the user's turned on "Show
    /// Mega Evolutions" in Settings regardless of format.
    func eligiblePokemon(for format: RankingFormat) -> [Pokemon] {
        format.allowsMegaEvolution ? allPokemonIncludingMegas : pokemonForPicker
    }

    /// `allPokemon`, plus Mega Evolutions when "Show Mega Evolutions" is on —
    /// for tools (Rank Checker, 1v1 Simulator, Breakpoints, Bench) that pick
    /// a Pokémon without a specific format/cup in play.
    var pokemonForPicker: [Pokemon] {
        showMegaEvolutions ? allPokemonIncludingMegas : allPokemon
    }

    /// The Mega Evolution(s) available for an owned species (e.g. a bench
    /// entry), or empty if it has none.
    func megaEvolutions(for speciesId: String) -> [Pokemon] {
        guard let dex = pokemonById[speciesId]?.dex else { return [] }
        return Pokemon.megaEvolutions(ofDex: dex, pokemonById: pokemonById)
    }

    /// Builds a team member for a species, defaulting to its recommended
    /// moveset (from the current league's rankings) or its first available
    /// moves. Shared by `TeamBuilderModel` and `MatchupModel`.
    func makeMember(speciesId: String) -> TeamMember? {
        guard let species = pokemonById[speciesId] else { return nil }
        if let entry = entry(id: speciesId), entry.moveset.count >= 2 {
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

    func move(id: String) -> Move? {
        movesById[id]
    }

    /// Resolves a species id to its display name, falling back to a prettified id.
    func name(forSpeciesId id: String) -> String {
        pokemonById[id]?.speciesName
            ?? id.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Every species directly linked to another by an evolution — built from
    /// `family.parent`/`family.evolutions`, not `family.id`, so a species
    /// whose own gamemaster entry is missing its `family` object (e.g.
    /// Gastrodon, which has no `family` key at all in some dumps) still
    /// groups correctly as long as a relative declares the link (Shellos
    /// declares Gastrodon as its evolution). Undirected: covers both the
    /// forward (`evolutions`) and backward (`parent`) declaration of the
    /// same edge.
    private var evolutionNeighbors: [String: Set<String>] = [:]
    /// Immediate pre-evolution for each species that has one, derived from
    /// the same links.
    private var parentOf: [String: String] = [:]

    private func buildFamilyGraph() {
        evolutionNeighbors = [:]
        parentOf = [:]
        func link(_ a: String, _ b: String) {
            evolutionNeighbors[a, default: []].insert(b)
            evolutionNeighbors[b, default: []].insert(a)
        }
        for pokemon in allPokemon {
            guard let family = pokemon.family else { continue }
            if let parent = family.parent {
                link(pokemon.speciesId, parent)
                parentOf[pokemon.speciesId] = parent
            }
            for evolution in family.evolutions ?? [] {
                link(pokemon.speciesId, evolution)
                parentOf[evolution] = pokemon.speciesId
            }
        }
    }

    /// Every Pokémon connected to `id` by a direct evolution link (forward or
    /// backward, transitively) — the whole line, dex-sorted. Falls back to
    /// just the Pokémon itself if it neither evolves nor is evolved into.
    /// When `excludingPreEvolutions` is set, strict ancestors of `id` along
    /// its own lineage are dropped — you can only evolve one way, so once a
    /// scan/bench entry confirms the current stage, earlier stages can't
    /// apply to it anymore (sibling branches from a fork, e.g. Gardevoir
    /// when `id` is Gallade, are unaffected — only direct ancestors of `id`).
    func family(for id: String, excludingPreEvolutions: Bool = false) -> [Pokemon] {
        guard let pokemon = pokemonById[id] else { return [] }
        var groupIds: Set<String> = [id]
        var queue = [id]
        while let next = queue.popLast() {
            for neighbor in evolutionNeighbors[next] ?? [] where !groupIds.contains(neighbor) {
                groupIds.insert(neighbor)
                queue.append(neighbor)
            }
        }
        var members = allPokemon.filter { groupIds.contains($0.speciesId) }
        if excludingPreEvolutions {
            var ancestors: Set<String> = []
            var current = id
            while let parent = parentOf[current] {
                ancestors.insert(parent)
                current = parent
            }
            members.removeAll { ancestors.contains($0.speciesId) }
        }
        return members.isEmpty ? [pokemon] : members
    }

    // MARK: - Live matchup simulation

    /// Resolves the species (and shadow flag) for a ranking-entry species id.
    nonisolated static func resolve(
        speciesId: String, pokemonById: [String: Pokemon]
    ) -> (species: Pokemon, shadow: Bool)? {
        Pokemon.resolve(speciesId: speciesId, pokemonById: pokemonById)
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

    /// Each team member's battle rating against `opponentId`'s recommended
    /// moveset, at 1 shield each side (the same default the Team Builder's
    /// threat scoring uses). nil for a member whose stats/moves can't be
    /// resolved, or if the opponent itself has no rankings/moveset data.
    func teamRatings(for members: [TeamMember], against opponentId: String) -> [Int?] {
        guard let oppEntry = entry(id: opponentId),
              let oppCombatant = Self.combatant(for: oppEntry, pokemonById: pokemonById),
              let oppStats = MatchupSimulator.optimalStats(for: oppCombatant, cpCap: format.cp)
        else { return members.map { _ in nil } }
        let cpCap = format.cp
        return members.map { member in
            guard let species = pokemonById[member.speciesId], !member.chargedMoveIds.isEmpty else { return nil }
            let combatant = MatchupSimulator.Combatant(
                species: species, shadow: member.shadow,
                fastMoveId: member.fastMoveId, chargedMoveIds: member.chargedMoveIds)
            let stats = entry(id: member.speciesId)?.stats.map { BattlePokemon.Stats(atk: $0.atk, def: $0.def, hp: Int($0.hp)) }
                ?? MatchupSimulator.optimalStats(for: combatant, cpCap: cpCap)
            guard let stats else { return nil }
            return MatchupSimulator.rate(
                combatant, statsA: stats, oppCombatant, statsB: oppStats,
                movesById: movesById, shieldsA: 1, shieldsB: 1)?.a
        }
    }
}
