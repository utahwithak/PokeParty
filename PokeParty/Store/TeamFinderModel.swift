//
//  TeamFinderModel.swift
//  PokeParty
//
//  Observable state for the 3v3 Party Finder. Picks a format (independent of
//  the sidebar selection), loads that format's rankings, builds a candidate
//  pool from the top of the list, and runs the `TeamFinder` round-robin
//  tournament — publishing live `Standings` snapshots so the leaderboard
//  animates as battles resolve. Completed runs are saved automatically so
//  an expensive tournament can be reviewed later without re-simulating.
//

import SwiftUI

@MainActor
@Observable
final class TeamFinderModel {

    enum Phase: Equatable {
        case idle
        case loadingRankings
        case searching
        case done
        case failed(String)
    }

    /// How suggested teams are found. `gradeCheck` and `safeLeadCover` are
    /// static analyses that can optionally hand their teams to the 3v3
    /// tournament to settle the order (`verifyWithTournament`).
    enum Method: String, CaseIterable, Identifiable {
        case tournament
        case gradeCheck
        case aiOptimizer
        case myMeta
        case safeLeadCover

        var id: Self { self }

        /// Both hill-climbing methods share the optimizer's settings and results UI.
        var isOptimizer: Bool { self == .aiOptimizer || self == .myMeta }
        /// Static methods whose teams can optionally be verified in a tournament.
        var supportsVerify: Bool { self == .gradeCheck || self == .safeLeadCover }

        var title: String {
            switch self {
            case .tournament: return "Tournament"
            case .gradeCheck: return "AAAA teams"
            case .aiOptimizer: return "AI Optimizer"
            case .myMeta: return "My Meta"
            case .safeLeadCover: return "Safe lead + cover"
            }
        }

        /// One line on what the method does (the view adds the verify detail).
        var summary: String {
            switch self {
            case .tournament:
                return "The most promising trios fight a full 3v3 round robin."
            case .gradeCheck:
                return "Grades every trio with the Team Builder's Coverage, Bulk, Safety and Consistency."
            case .aiOptimizer:
                return "Hill-climbs Pokémon and movesets against the top of the meta."
            case .myMeta:
                return "Hill-climbs against the opponents you've logged, leads weighted most."
            case .safeLeadCover:
                return "A safe lead with two backs that cover the whole meta, rank 1 counting most. Uses the top 150 candidates."
            }
        }
    }

    /// The format whose meta to build teams from (defaults to Great League;
    /// switchable to any core league or active cup).
    var format: RankingFormat = .great { didSet { persistSettings(); refreshOpponentSample() } }
    /// How many of the format's top-ranked Pokémon form the candidate pool.
    var poolSize: Int = 15 {
        didSet {
            metaSize = Self.defaultMetaSize(forPoolSize: poolSize)
            persistSettings()
        }
    }
    /// Sentinel pool size meaning "every ranked Pokémon" — larger than any
    /// ranking list, so the pool builders (which stop at `poolSize`) take it all.
    static let fullListPoolSize = 100_000
    static let poolSizes = [10, 15, 20, 25, 50, 75, 100, 125, 150, 200, 250, 500, fullListPoolSize]

    /// Human-readable pool size, e.g. "top 50" or "full list".
    static func poolDescription(_ size: Int) -> String {
        size >= fullListPoolSize ? "full list" : "top \(size)"
    }

    /// How many of the pool's top-ranked species become AI Optimizer opponent
    /// threats — the curated field the hill-climb scores candidate teams
    /// against (see `TeamOptimizer.buildMetaField`). Auto-scales with
    /// `poolSize` (via `defaultMetaSize`) whenever the pool changes, but can
    /// still be dialed in manually afterward: a bigger field is more
    /// representative of the pool but costs one extra battle per swap
    /// evaluation per added threat, so it isn't simply set equal to `poolSize`.
    var metaSize: Int = 15 { didSet { persistSettings() } }
    static let metaSizeRange = 5.0...500.0
    static let metaSizeStep = 5.0

    /// Default `metaSize` for a given `poolSize`: scales at half the pool,
    /// floored at 15 (today's fixed default) and capped at 60 to bound the
    /// hill-climb's per-step battle cost even for very large pools. The slider
    /// can go well past this cap (up to `metaSizeRange`) for slow, thorough runs.
    static func defaultMetaSize(forPoolSize poolSize: Int) -> Int {
        min(max(poolSize / 2, 15), 60)
    }

    var method: Method = .tournament { didSet { persistSettings() } }

    /// Pokémon the AI Optimizer must include on every team it searches (0–2).
    /// The hill-climb pins these to fixed slots and only searches for the best
    /// partner(s) — the final lead/switch/closer order is still optimized
    /// freely across all three members.
    private(set) var lockedMembers: [TeamMember] = [] { didSet { persistSettings() } }
    static let maxLockedMembers = 2

    func lockMember(_ member: TeamMember) {
        guard lockedMembers.count < Self.maxLockedMembers,
              !lockedMembers.contains(where: { $0.speciesId == member.speciesId })
        else { return }
        lockedMembers.append(member)
    }

    func unlockMember(_ member: TeamMember) {
        lockedMembers.removeAll { $0.id == member.id }
    }

    /// Toggles a locked member's shadow flag — only meaningful for species
    /// that can be caught as either form (see `Pokemon.isShadowEligible`).
    func setLockedMemberShadow(_ shadow: Bool, for member: TeamMember) {
        guard let index = lockedMembers.firstIndex(where: { $0.id == member.id }) else { return }
        lockedMembers[index].shadow = shadow
    }

    /// Pokémon the AI Optimizer should weight teams strongly against (0–4).
    /// Unlike `lockedMembers`, these don't join the searched team's slots —
    /// they're added to the meta field as extra opponent threats (see
    /// `TeamOptimizer.findTeams`), each weighted equal to the single
    /// top-ranked automatic threat so they aren't diluted away by a large
    /// meta field size.
    private(set) var strongAgainstMembers: [TeamMember] = [] { didSet { persistSettings() } }
    static let maxStrongAgainstMembers = 4

    func addStrongAgainst(_ member: TeamMember) {
        guard strongAgainstMembers.count < Self.maxStrongAgainstMembers,
              !strongAgainstMembers.contains(where: { $0.speciesId == member.speciesId })
        else { return }
        strongAgainstMembers.append(member)
    }

    func removeStrongAgainst(_ member: TeamMember) {
        strongAgainstMembers.removeAll { $0.id == member.id }
    }

    /// Toggles a "strong against" pick's shadow flag — only meaningful for
    /// species that can be caught as either form (see `Pokemon.isShadowEligible`).
    func setStrongAgainstShadow(_ shadow: Bool, for member: TeamMember) {
        guard let index = strongAgainstMembers.firstIndex(where: { $0.id == member.id }) else { return }
        strongAgainstMembers[index].shadow = shadow
    }

    /// Pokémon (and form — a shadow is excluded separately from its regular
    /// form) that no method may put on a team, e.g. to push the finder past a
    /// ubiquitous core. The AI Optimizer / My Meta still score teams against
    /// them as opponents; the other methods drop them from the ranked list.
    private(set) var excludedMembers: [TeamMember] = [] { didSet { persistSettings() } }

    func excludeMember(_ member: TeamMember) {
        guard !excludedMembers.contains(where: { $0.speciesId == member.speciesId })
        else { return }
        excludedMembers.append(member)
    }

    func removeExcluded(_ member: TeamMember) {
        excludedMembers.removeAll { $0.id == member.id }
    }

    /// Toggles an excluded pick's shadow flag — only meaningful for species
    /// that can be caught as either form (see `Pokemon.isShadowEligible`).
    func setExcludedShadow(_ shadow: Bool, for member: TeamMember) {
        guard let index = excludedMembers.firstIndex(where: { $0.id == member.id }) else { return }
        excludedMembers[index].shadow = shadow
    }

    /// `entries` without the excluded species/forms. Compares resolved
    /// (species, shadow) pairs so a ranking id like "machoke_shadow" matches
    /// an excluded Machoke with the shadow flag on.
    static func removing(
        _ excluded: [TeamMember], from entries: [RankingEntry], pokemonById: [String: Pokemon]
    ) -> [RankingEntry] {
        guard !excluded.isEmpty else { return entries }
        let keys = Set(excluded.map { Pokemon.formKey(speciesId: $0.speciesId, shadow: $0.shadow) })
        return entries.filter { entry in
            let shadow = RankingsStore.resolve(speciesId: entry.speciesId, pokemonById: pokemonById)?.shadow ?? false
            return !keys.contains(Pokemon.formKey(speciesId: entry.speciesId, shadow: shadow))
        }
    }

    /// How many coverage-seeded teams enter the round robin (slider-driven;
    /// the tournament fights fieldSize·(fieldSize−1)/2 battles).
    var fieldSize: Int = 500 { didSet { persistSettings() } }

    /// Number of hill-climbing restarts for the AI Optimizer (each begins from
    /// a different lead Pokémon and explores all single-swap neighbors).
    var restarts: Int = 20 { didSet { persistSettings() } }
    static let restartRange = 5.0...50.0
    static let restartStep = 5.0

    /// When off, the AI Optimizer only considers each Pokémon's recommended
    /// moveset — skipping the alternate (fast, c1, c2) combinations that
    /// otherwise expand the candidate pool and hill-climb search space.
    /// Off by default: alternates roughly multiply the search space and most
    /// runs care about recommended-moveset teams.
    var exploreAlternateMovesets = false { didSet { persistSettings() } }

    /// When on, the AI Optimizer also hill-climbs against the opponents logged
    /// in Opponent Check for the chosen format (see `OpponentUsageStore`), the
    /// opponent's leads weighted most.
    var useObservedMeta = false { didSet { persistSettings() } }
    /// How much logged-opponent data backs this format's "My Meta" (a cached
    /// read of the usage log; refreshed when the format changes or the view
    /// appears, since opponents are logged elsewhere).
    private(set) var opponentSample = OpponentSample(battles: 0)
    func refreshOpponentSample() {
        opponentSample = OpponentUsageStore().sample(in: format)
    }
    /// Whether the current method weights the logged opponents at all.
    var usesObservedMeta: Bool { method == .myMeta || (method == .aiOptimizer && useObservedMeta) }
    /// For the static methods (`Method.supportsVerify`): run the chosen teams
    /// through the 3v3 tournament instead of listing them straight from the
    /// static analysis.
    var verifyWithTournament = true { didSet { persistSettings() } }
    /// How long finished runs took on this device (feeds `runTimeEstimate`).
    private var runTimes = RunTimeLog()
    private var runStart: ContinuousClock.Instant?
    /// When the round robin began (the first standings snapshot), for the
    /// seconds-per-battle rate.
    private var tournamentStart: ContinuousClock.Instant?
    /// Whether this run ends in a round-robin tournament (drives which
    /// tournament settings and progress the UI shows).
    var runsTournament: Bool {
        method == .tournament || (method.supportsVerify && verifyWithTournament)
    }

    /// Number of ranked threats kept as a backfill in "My Meta" mode, so the
    /// field still has some general coverage beyond the opponents logged.
    static let myMetaBackfillSize = 6

    /// Opponent Pokémon to add as threats, weighted against the top automatic
    /// threat (1.0): seen species 0.5–1.5 by frequency, plus up to +1.5 for lead
    /// frequency. In `focus` ("My Meta") mode more species count and leads
    /// weigh up to +4, so the field is built mostly from what the user faces.
    private func observedThreats(using store: RankingsStore, focus: Bool = false) -> [TeamOptimizer.ObservedThreat] {
        let usage = OpponentUsageStore()
        let seen = usage.mostUsed(in: format, limit: focus ? 15 : 8)
        let leads = usage.recentLeads(in: format)
        let maxSeen = Double(seen.map(\.count).max() ?? 1)
        let maxLead = Double(leads.map(\.count).max() ?? 1)
        let leadBoost = focus ? 4.0 : 1.5
        var weights: [String: Double] = [:]
        for s in seen { weights[s.speciesId] = 0.5 + Double(s.count) / maxSeen }
        for l in leads.sorted(by: { $0.count > $1.count }).prefix(focus ? 6 : 4) {
            weights[l.speciesId, default: 0.5] += leadBoost * Double(l.count) / maxLead
        }
        let picked = Set(strongAgainstMembers.map(\.speciesId))
        return weights.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .compactMap { id, weight in
                guard !picked.contains(id), let member = store.makeMember(speciesId: id) else { return nil }
                return TeamOptimizer.ObservedThreat(member: member, weight: weight)
            }
    }

    /// Simulate voluntary switching in tournament battles (turn-0 safe swaps,
    /// counterswaps onto switch-locked opponents, switch-timer escapes, catch
    /// swaps onto a resist, and sac swaps that spend a nearly-fainted mon as an
    /// extra shield). More realistic, but each battle costs extra throwaway 1v1 sims.
    var simulateCounterswaps = false { didSet { persistSettings() } }

    /// Solve optimal shield timing (the game-theoretic search) for every 1v1
    /// segment instead of the greedy default. Far more expensive per battle.
    var optimalShields = false { didSet { persistSettings() } }

    /// Use the learned shield policy (RL milestone 1) instead of the greedy
    /// heuristic — near-optimal shielding at almost no extra cost. Ignored
    /// when `optimalShields` is on. Default ON: measured to change ~⅓ of game
    /// outcomes and reorder team rankings (Spearman 0.53 vs heuristic play)
    /// at 1.0x battle cost, so heuristic-play rankings are simply less accurate.
    var learnedShields = true { didSet { persistSettings() } }

    /// Use the learned switch policy (RL milestone 2) for boundary switches,
    /// counterswaps, and faint replacements instead of the hand-tuned rules.
    /// Default ON — same rationale as `learnedShields`.
    var learnedSwitches = true { didSet { persistSettings() } }

    /// Use the learned farm-vs-switch policy: when a switch is on the table but
    /// the opponent can't punish us yet, bank energy with fast moves for a short
    /// window instead of switching immediately. Only matters with counterswap
    /// simulation on. Default ON — measured +1.8 pts win rate / +18 mean rating
    /// on held-out teams (ungated farming is a wash; the policy picks the moments).
    var learnedFarming = true { didSet { persistSettings() } }

    /// How well the player is assumed to play (AI Optimizer). Anything below
    /// `.perfect` makes the player's own switch decisions fallible, so the search
    /// favors teams that still win when played imperfectly. Costs ~3x battle time.
    var playSkill: PlaySkill = .perfect { didSet { persistSettings() } }
    static let fieldSizeRange = 100.0...10000.0
    static let fieldSizeStep = 100.0

    /// Field size for the post-hoc broad-field validation pass: battles each
    /// AI Optimizer result against this many randomly sampled meta-team
    /// opponents (much larger than the curated field used during
    /// hill-climbing) to check which result actually holds up best.
    var broadFieldSize: Int = 3000 { didSet { persistSettings() } }

    /// Most cores a search may use at once. Applied live, even mid-run.
    var coreLimit: Int = CoreLimit.defaultWorkers {
        didSet {
            CoreLimit.executor.workers = coreLimit
            persistSettings()
        }
    }
    static let broadFieldSizeRange = 1000.0...10000.0
    static let broadFieldSizeStep = 1000.0

    // MARK: - Settings persistence

    /// The user's Party Finder choices, remembered across launches.
    private struct Settings: Codable {
        var format: RankingFormat
        var poolSize: Int
        var metaSize: Int
        var method: String
        var lockedMembers: [TeamMember]
        var strongAgainstMembers: [TeamMember]
        var excludedMembers: [TeamMember]?
        var fieldSize: Int
        var restarts: Int
        var exploreAlternateMovesets: Bool
        var useObservedMeta: Bool?
        var verifyWithTournament: Bool?
        var simulateCounterswaps: Bool
        var optimalShields: Bool
        var learnedShields: Bool
        var learnedSwitches: Bool
        var learnedFarming: Bool
        var playSkill: PlaySkill?
        var broadFieldSize: Int
        var coreLimit: Int
    }

    private static let settingsKey = "teamFinderSettings"
    /// Suppresses saving while `restoreSettings` assigns the stored values.
    private var isRestoringSettings = false

    init() {
        restoreSettings()
        refreshOpponentSample()
        CoreLimit.executor.workers = coreLimit
    }

    private func persistSettings() {
        guard !isRestoringSettings else { return }
        let settings = Settings(
            format: format, poolSize: poolSize, metaSize: metaSize, method: method.rawValue,
            lockedMembers: lockedMembers, strongAgainstMembers: strongAgainstMembers,
            excludedMembers: excludedMembers,
            fieldSize: fieldSize, restarts: restarts,
            exploreAlternateMovesets: exploreAlternateMovesets,
            useObservedMeta: useObservedMeta,
            verifyWithTournament: verifyWithTournament,
            simulateCounterswaps: simulateCounterswaps, optimalShields: optimalShields,
            learnedShields: learnedShields, learnedSwitches: learnedSwitches,
            learnedFarming: learnedFarming, playSkill: playSkill, broadFieldSize: broadFieldSize,
            coreLimit: coreLimit)
        if let data = JSONFileStore.encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
    }

    private func restoreSettings() {
        guard let data = UserDefaults.standard.data(forKey: Self.settingsKey),
              let saved = JSONFileStore.decode(Settings.self, from: data)
        else { return }
        isRestoringSettings = true
        defer { isRestoringSettings = false }
        format = saved.format
        poolSize = saved.poolSize
        metaSize = saved.metaSize   // after poolSize, whose didSet resets it
        // "combined" (AAAA grades, then a tournament) was folded into gradeCheck + verify.
        method = saved.method == "combined" ? .gradeCheck : (Method(rawValue: saved.method) ?? .tournament)
        lockedMembers = saved.lockedMembers
        strongAgainstMembers = saved.strongAgainstMembers
        excludedMembers = saved.excludedMembers ?? []
        fieldSize = saved.fieldSize
        restarts = saved.restarts
        exploreAlternateMovesets = saved.exploreAlternateMovesets
        useObservedMeta = saved.useObservedMeta ?? false
        verifyWithTournament = saved.verifyWithTournament ?? true
        simulateCounterswaps = saved.simulateCounterswaps
        optimalShields = saved.optimalShields
        learnedShields = saved.learnedShields
        learnedSwitches = saved.learnedSwitches
        learnedFarming = saved.learnedFarming
        playSkill = saved.playSkill ?? .perfect
        broadFieldSize = saved.broadFieldSize
        coreLimit = min(max(saved.coreLimit, 1), CoreLimit.totalCores)
    }

    /// Completed runs, persisted across launches.
    let savedTournaments = SavedTournamentsStore()
    /// Completed AI Optimizer runs, persisted across launches.
    let savedOptimizerRuns = SavedOptimizerRunsStore()

    private(set) var phase: Phase = .idle
    /// Seeding progress, 0…1 — the pairwise 1v1 matrix + field shortlist
    /// (meaningful while `phase == .searching` and `standings == nil`).
    private(set) var progress: Double = 0
    /// Live tournament snapshot; nil until seeding completes. Stays populated
    /// after the run (and after a cancel) so the leaderboard remains browsable.
    private(set) var standings: TeamFinder.Standings?
    /// Final ranked teams (set when the tournament completes).
    private(set) var results: [TeamFinder.RankedTeam] = []
    /// AAAA teams from a grade-check run (nil unless that method last ran).
    private(set) var gradedTeams: [GradeFinder.GradedTeam]?
    /// Live optimizer results (nil until first climber converges). Populated
    /// progressively and stays set after the run completes or is cancelled.
    private(set) var optimizerResults: TeamOptimizer.Results?
    /// The AI Optimizer config that produced `optimizerResults` — whether from
    /// a run just completed or a saved run just reloaded. `TeamOptimizer.buildPool`
    /// is a pure function of these plus the format's rankings, so a broad-field
    /// validation pass rebuilds the exact same pool on demand from this recipe
    /// instead of keeping the (potentially large) pool itself in memory.
    private(set) var resultsExploreAlternateMovesets = false
    private(set) var resultsLockedMembers: [TeamMember] = []
    /// The "strong against" picks the current `optimizerResults` were
    /// hill-climbed against — display only (see `SavedOptimizerRun.strongAgainstMembers`).
    private(set) var resultsStrongAgainstMembers: [TeamMember] = []
    /// Live broad-field validation results (nil until a validation pass has
    /// been started). Populated progressively and stays set after the pass
    /// completes or is cancelled.
    private(set) var broadFieldResults: TeamOptimizer.BroadFieldResults?
    private(set) var isValidatingBroadField = false
    /// Why the last validation couldn't run (nil when it could).
    private(set) var broadFieldMessage: String?
    /// The format and pool size the current run was started with.
    private(set) var resultsFormat: RankingFormat?
    private(set) var resultsPoolSize = 0

    /// Time-remaining estimate for the current stage of a run (seeding/grading,
    /// then the round robin's battles), measured from its recent speed.
    private(set) var eta = ProgressETA()

    private func noteProgress(_ fraction: Double) {
        progress = max(progress, fraction)
        eta.record(fraction)
    }

    private var searchTask: Task<Void, Never>?
    private var validateTask: Task<Void, Never>?

    var isRunning: Bool { phase == .loadingRankings || phase == .searching }

    /// Battles a full round robin of the current field size will fight.
    var estimatedBattles: Int { fieldSize * (fieldSize - 1) / 2 }

    /// Trios a grade-check sweep of the current pool will grade (C(pool, 3)).
    var estimatedTrios: Int { poolSize * (poolSize - 1) * (poolSize - 2) / 6 }

    // MARK: - Run-time estimate

    /// Every setting that drives a run's cost, so "last run with these
    /// settings" only matches a genuinely comparable run.
    private var runSignature: String {
        var parts = [method.rawValue, format.id, "pool\(poolSize)", "cores\(coreLimit)"]
        if runsTournament { parts.append("field\(fieldSize)") }
        if method.supportsVerify { parts.append("verify\(verifyWithTournament)") }
        if method.isOptimizer {
            parts += ["restarts\(restarts)", "meta\(metaSize)", "alt\(exploreAlternateMovesets)",
                      "obs\(useObservedMeta)", "skill\(playSkill.rawValue)",
                      "locked\(lockedMembers.count)", "strong\(strongAgainstMembers.count)"]
        }
        if !excludedMembers.isEmpty { parts.append("excl\(excludedMembers.count)") }
        if simulatesBattles { parts.append(battleSignature) }
        return parts.joined(separator: "|")
    }

    /// The battle-AI settings that decide how long one 3v3 takes.
    private var battleSignature: String {
        "ai\(simulateCounterswaps)\(optimalShields)\(learnedShields)\(learnedSwitches)\(learnedFarming)|cores\(coreLimit)"
    }

    /// Whether this run simulates battles (so the battle-simulation settings apply).
    var simulatesBattles: Bool { runsTournament || method.isOptimizer }

    /// What to expect, from runs measured on this device; nil until there's
    /// something to go on.
    var runTimeEstimate: String? {
        if let seconds = runTimes.lastRun(runSignature) {
            return "Last run with these settings took \(RunTimeLog.format(seconds: seconds))"
        }
        // A pure tournament scales with its battle count, so a rate measured at
        // another field size still gives a useful number.
        if method == .tournament, let rate = runTimes.secondsPerBattle(battleSignature) {
            return "Battles ≈ \(RunTimeLog.format(seconds: Double(estimatedBattles) * rate)), plus seeding"
        }
        return nil
    }

    /// Records a finished (not cancelled) run's duration; `battles` is the
    /// round robin's size when one ran.
    private func finishRun(battles: Int? = nil) {
        guard let runStart else { return }
        let end = ContinuousClock.now
        func seconds(_ d: Duration) -> Double {
            Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
        runTimes.record(signature: runSignature, seconds: seconds(end - runStart))
        if method == .tournament, let battles, let tournamentStart {
            runTimes.recordBattleRate(signature: battleSignature, battles: battles,
                                      seconds: seconds(end - tournamentStart))
        }
        self.runStart = nil
    }

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        if isRunning {
            phase = (standings == nil && gradedTeams == nil && optimizerResults == nil) ? .idle : .done
        }
    }

    /// Shows a previously saved tournament in the leaderboard.
    func load(_ run: SavedTournament) {
        guard !isRunning else { return }
        gradedTeams = nil
        results = run.teams
        resultsFormat = run.format
        resultsPoolSize = run.poolSize
        standings = TeamFinder.Standings(
            teams: run.teams,
            totalEntrants: run.fieldSize,
            battlesFought: run.battlesFought, totalBattles: run.battlesFought,
            round: max(run.fieldSize - 1, 0), totalRounds: max(run.fieldSize - 1, 0),
            isComplete: true)
        phase = .done
    }

    /// Shows a previously saved AI Optimizer run in the results list. Sets
    /// `method` to `.aiOptimizer` so `canValidateAgainstBroadField` (which
    /// gates on it) reflects what's actually on screen even if the picker was
    /// left on something else — the pool needed for that pass is rebuilt on
    /// demand from `resultsExploreAlternateMovesets`/`resultsLockedMembers`,
    /// so a reloaded run validates exactly like a freshly completed one.
    func load(_ run: SavedOptimizerRun) {
        guard !isRunning else { return }
        method = .aiOptimizer
        gradedTeams = nil
        standings = nil
        broadFieldResults = nil
        broadFieldMessage = nil
        resultsFormat = run.format
        resultsPoolSize = run.poolSize
        resultsExploreAlternateMovesets = run.exploreAlternateMovesets
        resultsLockedMembers = run.lockedMembers
        resultsStrongAgainstMembers = run.strongAgainstMembers
        broadFieldSize = run.broadFieldSize
        optimizerResults = TeamOptimizer.Results(
            teams: run.teams,
            completedClimbers: run.teams.count,
            totalClimbers: run.teams.count,
            isComplete: true)
        phase = .done
    }

    /// Loads the chosen format's rankings and runs the tournament.
    func run(using store: RankingsStore) {
        searchTask?.cancel()
        validateTask?.cancel()
        let format = format
        let poolSize = poolSize
        let fieldSize = fieldSize
        let simulateCounterswaps = simulateCounterswaps
        let optimalShields = optimalShields
        let learnedShields = learnedShields
        let learnedSwitches = learnedSwitches
        let learnedFarming = learnedFarming
        let playSkill = playSkill
        let movesById = store.movesById
        let pokemonById = store.pokemonById
        let method = method
        let verifyWithTournament = verifyWithTournament
        let restarts = restarts
        let isMyMeta = method == .myMeta
        let metaSize = isMyMeta ? Self.myMetaBackfillSize : metaSize
        let exploreAlternateMovesets = exploreAlternateMovesets
        let lockedMembers = lockedMembers
        let strongAgainstMembers = strongAgainstMembers
        let excludedMembers = excludedMembers
        let observedMeta = (isMyMeta || (method == .aiOptimizer && useObservedMeta))
            ? observedThreats(using: store, focus: isMyMeta) : []
        let broadFieldSize = broadFieldSize
        let observedConfidence = OpponentUsageStore().sample(in: format).confidence

        phase = .loadingRankings
        runStart = .now
        tournamentStart = nil
        progress = 0
        eta.reset()
        results = []
        standings = nil
        gradedTeams = nil
        optimizerResults = nil
        broadFieldResults = nil
        isValidatingBroadField = false
        resultsFormat = nil

        if isMyMeta && observedMeta.isEmpty {
            phase = .failed("No opponents logged for this format yet — check some opponents (or scan battles) first so My Meta has leads and seen Pokémon to build against.")
            return
        }

        searchTask = Task {
            await withTaskExecutorPreference(CoreLimit.executor) {
                let rankedEntries: [RankingEntry]
                do {
                    rankedEntries = try await DataService.shared.rankings(for: format)
                } catch {
                    if !Task.isCancelled { phase = .failed(error.localizedDescription) }
                    return
                }
                if Task.isCancelled { return }
                // The optimizer keeps excluded Pokémon in its pool (as opponents) and
                // bars them from teams itself; the other methods have no separate
                // opponent field, so they just drop them.
                let entries = method.isOptimizer
                    ? rankedEntries
                    : Self.removing(excludedMembers, from: rankedEntries, pokemonById: pokemonById)

                let pool = Self.buildPool(
                    entries: entries, poolSize: poolSize,
                    cpCap: format.cp, pokemonById: pokemonById)
                guard pool.count >= 3 else {
                    phase = .failed("Not enough ranked Pokémon in this format to build teams.")
                    return
                }

                phase = .searching
                resultsFormat = format
                resultsPoolSize = pool.count

                if method == .gradeCheck && !verifyWithTournament {
                    let teams = await GradeFinder.findTopGradedTeams(
                        pool: pool, cpCap: format.cp, movesById: movesById,
                        onProgress: { fraction in
                            Task { @MainActor in self.noteProgress(fraction) }
                        })
                    if Task.isCancelled { return }
                    withAnimation(.spring(duration: 0.6)) { gradedTeams = teams }
                    phase = .done
                    finishRun()
                    return
                }

                if method.isOptimizer {
                    // TeamOptimizer.findTeams builds its own pool internally (via
                    // TeamOptimizer.buildPool/buildCandidates, a *species-scanned*
                    // stopping rule) from `poolSize` below — not from the `pool`
                    // this function built above (TeamFinderModel.buildPool, a
                    // *successful-candidate-count* stopping rule). Recording the
                    // actual `poolSize` setting here, not `pool.count`, is what
                    // lets `validateAgainstBroadField` reproduce that same pool later.
                    resultsPoolSize = poolSize
                    resultsExploreAlternateMovesets = exploreAlternateMovesets
                    resultsLockedMembers = lockedMembers
                    resultsStrongAgainstMembers = strongAgainstMembers
                    let final = await TeamOptimizer.findTeams(
                        entries: entries,
                        poolSize: poolSize,
                        cpCap: format.cp,
                        pokemonById: pokemonById,
                        movesById: movesById,
                        lockedMembers: lockedMembers,
                        strongAgainstMembers: strongAgainstMembers,
                        excludedMembers: excludedMembers,
                        observedMeta: observedMeta,
                        observedFocus: isMyMeta,
                        observedConfidence: observedConfidence,
                        metaSize: metaSize,
                        restarts: restarts,
                        learnedShields: learnedShields,
                        learnedSwitches: learnedSwitches,
                        learnedFarming: learnedFarming,
                        voluntarySwitching: simulateCounterswaps,
                        optimalShields: optimalShields,
                        playSkill: playSkill,
                        exploreAlternateMovesets: exploreAlternateMovesets,
                        onProgress: { fraction in
                            Task { @MainActor in self.noteProgress(fraction) }
                        },
                        onResults: { snapshot in
                            Task { @MainActor [self] in
                                withAnimation(.spring(duration: 0.6)) { self.optimizerResults = snapshot }
                            }
                        })
                    // Note: `final.isComplete` is *not* a signal that the run
                    // wasn't cancelled — `TeamOptimizer.findTeams` only checks
                    // cancellation before the climbers' task group starts; once
                    // climbing begins it always drains the group and returns
                    // `isComplete: true` with whatever climbers converged before
                    // being cut off. So a cancelled run's `final.teams` here is
                    // already a fully valid set of hill-climbed results (each
                    // team converged on its own), not a partial/unreliable
                    // snapshot — unlike the round-robin below, there's no reason
                    // to discard it just because Cancel was pressed.
                    if final.teams.isEmpty {
                        if !Task.isCancelled, !lockedMembers.isEmpty {
                            phase = .failed("No valid partners found for the locked Pokémon in this pool — try a larger pool or different picks.")
                        }
                        return
                    }
                    withAnimation(.spring(duration: 0.6)) { optimizerResults = final }
                    phase = .done
                    finishRun()

                    savedOptimizerRuns.save(SavedOptimizerRun(
                        date: .now,
                        formatTitle: format.title, cup: format.cup, cp: format.cp,
                        poolSize: poolSize, metaSize: metaSize, restarts: restarts,
                        exploreAlternateMovesets: exploreAlternateMovesets, lockedMembers: lockedMembers,
                        strongAgainstMembers: strongAgainstMembers,
                        teams: final.teams, broadFieldSize: broadFieldSize))
                    return
                }

                // AAAA + verify: the grade check seeds the tournament's field, so the
                // round robin only ranks teams that already grade A across the board.
                var seededField: [[Int]]?
                // Safe lead + cover: pick a safe lead and complementary back pairs
                // from the pairwise ratings. Listed directly (graded, in score
                // order) unless the tournament is verifying them.
                if method == .safeLeadCover {
                    // Candidates come from the pool (the finder keeps the top 150); the
                    // opponents are the whole ranked list, weighted by rank.
                    let ranked = Self.buildPool(
                        entries: entries, poolSize: Self.fullListPoolSize,
                        cpCap: format.cp, pokemonById: pokemonById)
                    let found = await SafeLeadFinder.findTrios(
                        all: ranked, candidateCount: pool.count, opponentCount: ranked.count,
                        movesById: movesById,
                        onProgress: { fraction in
                            Task { @MainActor in self.noteProgress(fraction) }
                        })
                    if Task.isCancelled { return }
                    guard !found.trios.isEmpty else {
                        phase = .failed("Not enough compatible Pokémon in this pool to build safe-lead teams — try a larger pool.")
                        return
                    }
                    let trios = found.trios.map(\.indices)
                    if verifyWithTournament, trios.count >= 2 {
                        seededField = trios
                        eta.reset()
                    } else {
                        let graded = GradeFinder.gradeTrios(
                            trios, members: Array(ranked.prefix(found.field.candidateCount)),
                            threats: Array(ranked.prefix(found.field.opponentCount)),
                            threatRatings: found.field.threatRatings,
                            cpCap: format.cp, movesById: movesById)
                        withAnimation(.spring(duration: 0.6)) { gradedTeams = graded }
                        phase = .done
                        finishRun()
                        return
                    }
                }
                if method == .gradeCheck {   // verifying: the AAAA teams seed the tournament
                    let graded = await GradeFinder.findTopGradedTeams(
                        pool: pool, cpCap: format.cp, movesById: movesById,
                        maxResults: fieldSize,
                        onProgress: { fraction in
                            Task { @MainActor in self.noteProgress(fraction) }
                        })
                    if Task.isCancelled { return }
                    let aaaa = graded.filter(\.isAAAA)
                    guard aaaa.count >= 2 else {
                        phase = .failed(aaaa.isEmpty
                            ? "No AAAA teams in this pool — try a larger pool."
                            : "Only one AAAA team in this pool — nothing to battle. Try a larger pool.")
                        return
                    }
                    seededField = aaaa.map(\.poolIndices)
                    eta.reset()
                }

                let final = await TeamFinder.findTeams(
                    pool: pool, movesById: movesById, fieldSize: fieldSize,
                    voluntarySwitching: simulateCounterswaps,
                    optimalShields: optimalShields,
                    learnedShields: learnedShields,
                    learnedSwitches: learnedSwitches,
                    learnedFarming: learnedFarming,
                    seededField: seededField,
                    onSeedingProgress: { fraction in
                        Task { @MainActor in self.noteProgress(fraction) }
                    },
                    onStandings: { snapshot in
                        Task { @MainActor [self] in
                            // Snapshots hop actors independently; never regress.
                            guard snapshot.battlesFought >= (self.standings?.battlesFought ?? -1) else { return }
                            // Battle speed differs from seeding speed: start a fresh
                            // measurement when the round robin begins.
                            if self.standings == nil {
                                self.eta.reset()
                                self.tournamentStart = .now
                            }
                            self.eta.record(Double(snapshot.battlesFought) / Double(max(snapshot.totalBattles, 1)))
                            withAnimation(.spring(duration: 0.6)) { self.standings = snapshot }
                        }
                    })
                if Task.isCancelled { return }
                results = final.teams
                withAnimation(.spring(duration: 0.6)) { standings = final }
                phase = .done
                if final.isComplete { finishRun(battles: final.battlesFought) }

                // Only a finished round robin is worth keeping — a cancelled
                // run's records aren't a full account of the field.
                if final.isComplete {
                    savedTournaments.save(SavedTournament(
                        date: .now,
                        formatTitle: format.title, cup: format.cup, cp: format.cp,
                        poolSize: pool.count, fieldSize: final.totalEntrants,
                        battlesFought: final.battlesFought,
                        teams: final.teams))
                }
            }
        }
    }

    /// True once an AI Optimizer run has finished (fresh or reloaded from
    /// `savedOptimizerRuns`) and left results behind to validate against a
    /// broader random field. Gates on `optimizerResults.isComplete` rather
    /// than `isRunning`/`phase`: the optimizer's final results and `phase =
    /// .done` land via two separate, unordered MainActor hops (the engine's
    /// last `onResults` callback vs. `run(using:)`'s post-await write), so
    /// checking `phase` here could transiently — or, absent another state
    /// change to force a re-render, durably — read stale. `isComplete` is set
    /// atomically with the results it's read alongside, and already gates
    /// this whole section one level up (see `results.isComplete` in
    /// `OptimizerResultsView.body`), so tying to it instead removes the race
    /// entirely.
    var canValidateAgainstBroadField: Bool {
        method.isOptimizer
            && (optimizerResults?.isComplete ?? false)
            && !(optimizerResults?.teams.isEmpty ?? true)
    }

    /// Battles every current AI Optimizer result against `broadFieldSize`
    /// randomly sampled meta-team opponents — a much larger (if noisier)
    /// sample than the curated field used during hill-climbing, to check
    /// which result actually holds up best across the metagame. Rebuilds the
    /// candidate pool from `resultsFormat`/`resultsPoolSize`/
    /// `resultsExploreAlternateMovesets`/`resultsLockedMembers` on every call
    /// instead of keeping it around from run time — `TeamOptimizer.buildPool`
    /// is a pure function of those plus the format's rankings, so this
    /// reproduces the exact pool `optimizerResults` was built from whether
    /// that run just finished or was just reloaded from a saved run.
    func validateAgainstBroadField(using store: RankingsStore) {
        guard canValidateAgainstBroadField, let results = optimizerResults,
              let format = resultsFormat else { return }
        validateTask?.cancel()

        let teams = results.teams
        let poolSize = resultsPoolSize
        let exploreAlternateMovesets = resultsExploreAlternateMovesets
        let lockedMembers = resultsLockedMembers
        let pokemonById = store.pokemonById
        let movesById = store.movesById
        let fieldSize = broadFieldSize
        let learnedShields = learnedShields
        let learnedSwitches = learnedSwitches
        let learnedFarming = learnedFarming
        let voluntarySwitching = simulateCounterswaps
        let optimalShields = optimalShields
        let playSkill = playSkill

        isValidatingBroadField = true
        broadFieldResults = nil
        broadFieldMessage = nil

        validateTask = Task {
            await withTaskExecutorPreference(CoreLimit.executor) {
                let entries: [RankingEntry]
                do {
                    entries = try await DataService.shared.rankings(for: format)
                } catch {
                    if !Task.isCancelled { isValidatingBroadField = false }
                    return
                }
                if Task.isCancelled { return }

                let pool = TeamOptimizer.buildPool(
                    entries: entries, poolSize: poolSize, cpCap: format.cp,
                    pokemonById: pokemonById, exploreAlternateMovesets: exploreAlternateMovesets,
                    lockedMembers: lockedMembers).pool

                // A run synced or shared from another device can predate a
                // rankings update here; its pool indices would then point at
                // different Pokémon, so refuse rather than battle the wrong teams.
                guard Self.pool(pool, matches: teams) else {
                    broadFieldMessage = "This run was made with different rankings data than this device has now, so it can't be validated here. Re-run the AI Optimizer to validate."
                    isValidatingBroadField = false
                    return
                }

                let final = await TeamOptimizer.evaluateBroadField(
                    teams: teams, pool: pool, movesById: movesById, fieldSize: fieldSize,
                    learnedShields: learnedShields, learnedSwitches: learnedSwitches,
                    learnedFarming: learnedFarming,
                    voluntarySwitching: voluntarySwitching, optimalShields: optimalShields,
                    playSkill: playSkill,
                    onResults: { snapshot in
                        Task { @MainActor [self] in
                            withAnimation(.spring(duration: 0.6)) { self.broadFieldResults = snapshot }
                        }
                    })
                if Task.isCancelled { return }
                withAnimation(.spring(duration: 0.6)) { broadFieldResults = final }
                isValidatingBroadField = false
            }
        }
    }

    /// True when every team's pool indices resolve to the members stored with
    /// it (species, moveset and shadow flag, in team order).
    static func pool(_ pool: [TeamOptimizer.Candidate], matches teams: [TeamOptimizer.OptimizedTeam]) -> Bool {
        teams.allSatisfy { team in
            team.poolIndices.count == team.members.count
                && zip(team.poolIndices, team.members).allSatisfy { index, stored in
                    guard pool.indices.contains(index) else { return false }
                    let candidate = pool[index].member
                    return candidate.speciesId == stored.member.speciesId
                        && candidate.fastMoveId == stored.member.fastMoveId
                        && candidate.chargedMoveIds == stored.member.chargedMoveIds
                        && candidate.shadow == stored.member.shadow
                }
        }
    }

    func cancelBroadFieldValidation() {
        validateTask?.cancel()
        validateTask = nil
        isValidatingBroadField = false
    }

    /// The top `poolSize` ranked Pokémon as battle-ready candidates, using the
    /// recommended moveset and IV-optimal stats already in the ranking data
    /// (the IV optimizer only runs for the rare unranked-stats entry).
    static func buildPool(
        entries: [RankingEntry], poolSize: Int, cpCap: Int,
        pokemonById: [String: Pokemon]
    ) -> [TeamFinder.Candidate] {
        var pool: [TeamFinder.Candidate] = []
        for entry in entries {
            guard pool.count < poolSize else { break }
            guard entry.moveset.count >= 2,
                  let r = RankingsStore.resolve(speciesId: entry.speciesId, pokemonById: pokemonById)
            else { continue }
            let combatant = MatchupSimulator.Combatant(
                species: r.species, shadow: r.shadow,
                fastMoveId: entry.moveset[0],
                chargedMoveIds: Array(entry.moveset[1...].prefix(3)))
            let stats = entry.stats.map {
                BattlePokemon.Stats(atk: $0.atk, def: $0.def, hp: Int($0.hp))
            } ?? MatchupSimulator.optimalStats(for: combatant, cpCap: cpCap)
            guard let stats else { continue }

            let member = TeamMember(
                speciesId: r.species.speciesId,
                fastMoveId: combatant.fastMoveId,
                chargedMoveIds: combatant.chargedMoveIds,
                shadow: r.shadow)
            pool.append(.init(
                member: member,
                speciesName: r.species.speciesName,
                types: r.species.types.filter { $0 != "none" },
                shadow: r.shadow,
                familyId: r.species.family?.id,
                dex: r.species.dex,
                combatant: combatant,
                stats: stats,
                isMegaEvolution: r.species.isMegaEvolution,
                switchesScore: entry.switchesScore,
                closerScore: entry.closerScore))
        }
        return pool
    }

    /// Builds a `Candidate` pool from the player's bench entries for a given CP cap.
    /// IVs are used when present (with Best Buddy level cap if flagged); otherwise
    /// optimal stats are computed from the IV optimizer. When `includeMegaEvolutions`
    /// is set, each bench entry also contributes a candidate for every Mega
    /// Evolution of its species (e.g. an owned Charizard also offers Mega
    /// Charizard X/Y) — mega-evolving doesn't change a Pokémon's own IVs, just
    /// applies the Mega form's stat multipliers, so the entry's IVs/moves carry
    /// over unchanged. `teamCandidatesDistinct` already keeps a base form and
    /// its Mega from sharing a team (same dex number).
    static func buildBenchPool(
        entries: [BenchEntry], cpCap: Int, pokemonById: [String: Pokemon],
        includeMegaEvolutions: Bool = false
    ) -> [TeamFinder.Candidate] {
        entries.flatMap { entry -> [TeamFinder.Candidate] in
            guard let r = RankingsStore.resolve(speciesId: entry.speciesId, pokemonById: pokemonById) else { return [] }
            var candidates: [TeamFinder.Candidate] = []
            if let c = benchCandidate(entry: entry, species: r.species, cpCap: cpCap) {
                candidates.append(c)
            }
            if includeMegaEvolutions {
                for mega in Pokemon.megaEvolutions(ofDex: r.species.dex, pokemonById: pokemonById) {
                    if let c = benchCandidate(entry: entry, species: mega, cpCap: cpCap) {
                        candidates.append(c)
                    }
                }
            }
            return candidates
        }
    }

    /// One bench entry's candidate for a given species — normally the entry's
    /// own species, or a Mega Evolution of it when building the Mega-form
    /// option (see `buildBenchPool`).
    private static func benchCandidate(
        entry: BenchEntry, species: Pokemon, cpCap: Int
    ) -> TeamFinder.Candidate? {
        let combatant = MatchupSimulator.Combatant(
            species: species, shadow: entry.shadow,
            fastMoveId: entry.fastMoveId,
            chargedMoveIds: entry.chargedMoveIds, megaLevel: entry.megaLevel)
        let levelCap = species.levelCap(megaLevel: entry.megaLevel, isBestBuddy: entry.isBestBuddy, cpCap: cpCap)
        let stats: BattlePokemon.Stats
        if let ivs = entry.ivs,
           let s = IVCalculator.stats(
               baseAtk: species.baseStats.atk,
               baseDef: species.baseStats.def,
               baseHp: species.baseStats.hp,
               ivs: ivs, cpCap: cpCap, levelCap: levelCap) {
            stats = BattlePokemon.Stats(atk: s.atk, def: s.def, hp: s.hp)
        } else if let s = MatchupSimulator.optimalStats(for: combatant, cpCap: cpCap, levelCap: levelCap) {
            stats = s
        } else {
            return nil
        }
        let member = TeamMember(
            speciesId: species.speciesId,
            fastMoveId: entry.fastMoveId,
            chargedMoveIds: entry.chargedMoveIds,
            shadow: entry.shadow,
            ivs: entry.ivs,
            isBestBuddy: entry.isBestBuddy)
        return TeamFinder.Candidate(
            member: member,
            speciesName: species.speciesName,
            types: species.types.filter { $0 != "none" },
            shadow: entry.shadow,
            familyId: species.family?.id,
            dex: species.dex,
            combatant: combatant,
            stats: stats,
            isMegaEvolution: species.isMegaEvolution)
    }

}
