//
//  TeamFinderView.swift
//  PokeParty
//
//  The 3v3 Party Finder: pick a format, pool and tournament field, run the
//  round robin, and watch the leaderboard settle. `TeamFinderView` is the
//  content column (configuration + run controls + saved results);
//  `TeamFinderResultsView` is the detail column, which hands the live
//  standings to `TeamFinderSimulationView`.
//

import SwiftUI

/// Content column: configure and start the tournament, or reopen a saved one.
struct TeamFinderView: View {
    var store: RankingsStore
    var model: TeamFinderModel
    var teamBuilder: TeamBuilderModel
    var bench: BenchStore
    var hiddenCups: HiddenCupsStore
    @Binding var selection: SidebarSelection?
    @State private var showingLockedPicker = false
    @State private var showingStrongAgainstPicker = false
    @State private var showingResults = false
    @Environment(ShareImportModel.self) private var shareImport

    private var visibleCupFormats: [RankingFormat] {
        store.cupFormats.filter { !hiddenCups.isHidden($0.id) }
    }

    var body: some View {
        Form {
            Section("Format") {
                Picker("Format", selection: Bindable(model).format) {
                    ForEach(RankingFormat.coreLeagues) { format in
                        Text(format.title).tag(format)
                    }
                    if !visibleCupFormats.isEmpty {
                        Divider()
                        ForEach(visibleCupFormats) { format in
                            Text(format.title).tag(format)
                        }
                    }
                }
                .disabled(model.isRunning)
            }
            .themedRow()

            Section("Candidate pool") {
                Picker("Top ranked Pokémon", selection: Bindable(model).poolSize) {
                    ForEach(TeamFinderModel.poolSizes, id: \.self) { size in
                        Text(size >= TeamFinderModel.fullListPoolSize ? "Full list (very slow)" : "Top \(size)").tag(size)
                    }
                }
                .disabled(model.isRunning)
            }
            .themedRow()

            Section("Performance") {
                VStack(alignment: .leading, spacing: 4) {
                    Slider(
                        value: Binding(
                            get: { Double(model.coreLimit) },
                            set: { model.coreLimit = Int($0) }),
                        in: 1...Double(max(2, CoreLimit.totalCores)),
                        step: 1
                    ) {
                        Text("CPU cores")
                    }
                    Text("Use up to \(model.coreLimit) of \(CoreLimit.totalCores) cores — fewer keeps the Mac responsive while a long search runs in the background. Changes apply immediately.")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .themedRow()

            Section("Method") {
                Picker("Method", selection: Bindable(model).method) {
                    ForEach(TeamFinderModel.Method.allCases) { method in
                        Text(method.title).tag(method)
                    }
                }
                .disabled(model.isRunning)

                if model.method == .gradeCheck {
                    Text("Every trio from the pool (\(model.poolSize >= TeamFinderModel.fullListPoolSize ? "potentially millions of" : model.estimatedTrios.formatted()) teams) is graded with the Team Builder's static analysis — Coverage, Bulk, Safety and Consistency — and the teams graded A across the board are listed. Pairwise 1v1 matchups only; no 3v3 battle simulations.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.method == .combined {
                    Text("Every trio from the pool is first graded with the Team Builder's static analysis; only the teams graded A in Coverage, Bulk, Safety and Consistency enter the tournament, where a full 3v3 round robin settles their order.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.method == .aiOptimizer {
                    Text("Hill-climbs the (Pokémon × moveset) space using recommended movesets by default — optionally alternate charged moves and fast moves with significant simulated usage too. Each restart begins from a different lead and swaps one team slot at a time until no improvement remains. Results appear as climbers converge.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .themedRow()

            if model.method == .aiOptimizer {
                lockedPokemonSection
                strongAgainstSection
                optimizerSection
            } else if model.method != .gradeCheck {
                tournamentFieldSection
            }

            Section {
                if model.isRunning {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.phase == .loadingRankings {
                            ProgressView("Loading rankings…")
                        } else if model.method == .aiOptimizer {
                            if let results = model.optimizerResults, results.completedClimbers > 0 {
                                ProgressView(
                                    value: Double(results.completedClimbers),
                                    total: Double(max(results.totalClimbers, 1))
                                ) {
                                    Text("\(results.completedClimbers) of \(results.totalClimbers) climbers converged")
                                }
                            } else if let results = model.optimizerResults {
                                ProgressView("Climbing… 0 of \(results.totalClimbers) done")
                            } else {
                                ProgressView("Building meta field…")
                            }
                        } else if let standings = model.standings {
                            ProgressView(
                                value: Double(standings.battlesFought),
                                total: Double(max(standings.totalBattles, 1))
                            ) {
                                Text("Round \(standings.round + 1) of \(standings.totalRounds + 1) — \(standings.battlesFought.formatted()) of \(standings.totalBattles.formatted()) battles")
                            }
                        } else {
                            ProgressView(value: model.progress) {
                                Text(seedingLabel)
                            }
                        }
                        if let eta = model.eta.label {
                            Text(eta)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button("Cancel", role: .cancel) { model.cancel() }
                    }
                } else {
                    Button {
                        model.run(using: store)
                    } label: {
                        // Plain label style: inside a Form row the default style
                        // draws the icon in the tint color, which is the button's
                        // fill color, so the icon vanished.
                        Label(runButtonTitle, systemImage: "wand.and.stars")
                            .labelStyle(.titleAndIcon)
                            #if os(iOS)
                            .frame(maxWidth: .infinity)
                            #endif
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.pokemonById.isEmpty)
                }

                if case .failed(let message) = model.phase {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .themedRow()

            if !model.savedTournaments.runs.isEmpty {
                Section("Saved tournaments") {
                    ForEach(model.savedTournaments.runs) { run in
                        SavedTournamentRow(run: run) {
                            model.load(run)
                        } onDelete: {
                            model.savedTournaments.delete(run)
                        }
                        .disabled(model.isRunning)
                    }
                }
                .themedRow()
            }

            if !model.savedOptimizerRuns.runs.isEmpty {
                Section("Saved AI Optimizer runs") {
                    ForEach(model.savedOptimizerRuns.runs) { run in
                        SavedOptimizerRunRow(run: run) {
                            model.load(run)
                            #if os(iOS)
                            // Results live in a pushed screen on iOS.
                            showingResults = true
                            #endif
                        } onDelete: {
                            model.savedOptimizerRuns.delete(run)
                        }
                        .disabled(model.isRunning)
                    }
                }
                .themedRow()
            }
        }
        .formStyle(.grouped)
        .themedBackground()
        .navigationTitle("Party Finder")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    shareImport.isImporterPresented = true
                } label: {
                    Label("Import Shared Results", systemImage: "square.and.arrow.down")
                }
                .help("Import a tournament, AI Optimizer run or team someone shared with you")
            }
        }
        #if os(iOS)
        // See MatchupSimulatorView: on iOS the detail column (here,
        // TeamFinderResultsView) has no other way to become reachable.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingResults = true
                } label: {
                    Label("View Results", systemImage: "wand.and.stars")
                }
                .disabled(model.phase != .done)
            }
        }
        .navigationDestination(isPresented: $showingResults) {
            TeamFinderResultsView(store: store, model: model, teamBuilder: teamBuilder, selection: $selection)
        }
        #endif
    }

    private var seedingLabel: String {
        switch model.method {
        case .tournament: return "Seeding tournament…"
        case .gradeCheck: return "Grading teams…"
        case .combined: return "Finding AAAA teams…"
        case .aiOptimizer: return "Building meta field…"
        }
    }

    private var runButtonTitle: String {
        switch model.method {
        case .tournament: return "Run Tournament"
        case .gradeCheck: return "Find AAAA Teams"
        case .combined: return "Run AAAA Tournament"
        case .aiOptimizer: return "Run AI Optimizer"
        }
    }

    private var lockedPokemonSection: some View {
        Section {
            ForEach(model.lockedMembers) { member in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text(store.name(forSpeciesId: member.speciesId))
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        Spacer()
                        Button {
                            model.unlockMember(member)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    if let species = store.pokemonById[member.speciesId],
                       species.isShadow || species.isShadowEligible || member.shadow {
                        Toggle("Shadow", isOn: Binding(
                            get: { member.shadow },
                            set: { model.setLockedMemberShadow($0, for: member) }))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .font(.caption)
                    }
                }
            }
            .disabled(model.isRunning)

            if model.lockedMembers.count < TeamFinderModel.maxLockedMembers {
                Button {
                    showingLockedPicker = true
                } label: {
                    Label("Lock a Pokémon", systemImage: "lock")
                }
                .disabled(model.isRunning)
                .popover(isPresented: $showingLockedPicker) {
                    LockedPokemonPickerView(
                        store: store, bench: bench, format: model.format,
                        excludingSpeciesIds: Set(model.lockedMembers.map(\.speciesId)),
                        onSelect: { member in
                            model.lockMember(member)
                            showingLockedPicker = false
                        })
                }
            }
        } header: {
            Text("Locked Pokémon (\(model.lockedMembers.count)/\(TeamFinderModel.maxLockedMembers))")
        } footer: {
            Text("The optimizer builds every team around these, searching for the best partner(s) and lead/switch/closer order.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .themedRow()
    }

    private var strongAgainstSection: some View {
        Section {
            ForEach(model.strongAgainstMembers) { member in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text(store.name(forSpeciesId: member.speciesId))
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        Spacer()
                        Button {
                            model.removeStrongAgainst(member)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    if let species = store.pokemonById[member.speciesId],
                       species.isShadow || species.isShadowEligible || member.shadow {
                        Toggle("Shadow", isOn: Binding(
                            get: { member.shadow },
                            set: { model.setStrongAgainstShadow($0, for: member) }))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .font(.caption)
                    }
                }
            }
            .disabled(model.isRunning)

            if model.strongAgainstMembers.count < TeamFinderModel.maxStrongAgainstMembers {
                Button {
                    showingStrongAgainstPicker = true
                } label: {
                    Label("Add a Pokémon", systemImage: "shield")
                }
                .disabled(model.isRunning)
                .popover(isPresented: $showingStrongAgainstPicker) {
                    LockedPokemonPickerView(
                        store: store, bench: bench, format: model.format,
                        excludingSpeciesIds: Set(model.strongAgainstMembers.map(\.speciesId)),
                        onSelect: { member in
                            model.addStrongAgainst(member)
                            showingStrongAgainstPicker = false
                        })
                }
            }
        } header: {
            Text("Strong Against (\(model.strongAgainstMembers.count)/\(TeamFinderModel.maxStrongAgainstMembers))")
        } footer: {
            Text("Every hill-climbed team is also weighted against these as extra opponent threats, so results favor teams with a good answer to them — without forcing any of them onto the team itself.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .themedRow()
    }

    private var optimizerSection: some View {
        Section("Optimizer") {
            VStack(alignment: .leading, spacing: 4) {
                Slider(
                    value: Binding(
                        get: { Double(model.restarts) },
                        set: { model.restarts = Int($0) }),
                    in: TeamFinderModel.restartRange,
                    step: TeamFinderModel.restartStep
                ) {
                    Text("Restarts")
                }
                .disabled(model.isRunning)
                Text("\(model.restarts) hill-climbs from diverse starting teams")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Slider(
                    value: Binding(
                        get: { Double(model.metaSize) },
                        set: { model.metaSize = Int($0) }),
                    in: TeamFinderModel.metaSizeRange,
                    step: TeamFinderModel.metaSizeStep
                ) {
                    Text("Meta field size")
                }
                .disabled(model.isRunning)
                Text("\(model.metaSize) top-ranked opponent threats to hill-climb against (auto-scales with pool size; more threats is a more representative field but costs one extra battle per swap per threat)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Toggle("Explore alternate movesets", isOn: Bindable(model).exploreAlternateMovesets)
                .disabled(model.isRunning)
            Text("When on, each Pokémon can also appear with alternate fast/charged move combos, expanding the candidate pool and search space for slower but more thorough runs. Off by default (recommended movesets only).")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Slider(
                    value: Binding(
                        get: { Double(model.broadFieldSize) },
                        set: { model.broadFieldSize = Int($0) }),
                    in: TeamFinderModel.broadFieldSizeRange,
                    step: TeamFinderModel.broadFieldSizeStep
                ) {
                    Text("Broad validation field")
                }
                .disabled(model.isRunning || model.isValidatingBroadField)
                Text("\(model.broadFieldSize.formatted()) random meta teams for the optional post-run \"Validate vs Full Meta\" check")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Toggle("Simulate counterswaps", isOn: Bindable(model).simulateCounterswaps)
                .disabled(model.isRunning)
            Toggle("Learned shield AI", isOn: Bindable(model).learnedShields)
                .disabled(model.isRunning || model.optimalShields)
            Toggle("Learned switch AI", isOn: Bindable(model).learnedSwitches)
                .disabled(model.isRunning)
            Toggle("Learned farming AI", isOn: Bindable(model).learnedFarming)
                .disabled(model.isRunning || !model.simulateCounterswaps)
        }
        .themedRow()
    }

    private var tournamentFieldSection: some View {
        Section("Tournament field") {
            VStack(alignment: .leading, spacing: 4) {
                Slider(
                    value: Binding(
                        get: { Double(model.fieldSize) },
                        set: { model.fieldSize = Int($0) }),
                    in: TeamFinderModel.fieldSizeRange,
                    step: TeamFinderModel.fieldSizeStep
                ) {
                    Text("Field size")
                }
                .disabled(model.isRunning)

                Text("\(model.fieldSize) teams — \(model.estimatedBattles.formatted()) battles")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text("The most promising teams from the pool fight a full round robin — every team battles every other team in true 3v3 simulations (recommended movesets, best-matchup switching), so a record is measured against the entire field. Bigger fields take longer, but standings stream live and finished tournaments are saved below.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Simulate counterswaps", isOn: Bindable(model).simulateCounterswaps)
                .disabled(model.isRunning)
            Text("Adds voluntary switching to every battle: safe swaps on a bad lead, counterswaps onto a switch-locked opponent, escapes from a bad matchup once the switch timer allows, catches of incoming super-effective moves on a resist, and sac swaps that spend a nearly-fainted mon as an extra shield. More realistic records, slower tournaments.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Optimal shield timing", isOn: Bindable(model).optimalShields)
                .disabled(model.isRunning)
            Text("Solves the best shield play for every 1v1 segment instead of the fast greedy heuristic. Much slower — best kept for small fields.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Learned shield AI", isOn: Bindable(model).learnedShields)
                .disabled(model.isRunning || model.optimalShields)
            Text("Shields with a small neural network trained to imitate the optimal shield search — close to optimal timing at nearly greedy speed. Ignored when optimal shield timing is on.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Learned switch AI", isOn: Bindable(model).learnedSwitches)
                .disabled(model.isRunning)
            Text("Chooses switches with a neural network trained on rollout search — it replays each choice to the end of the match and learns which one wins. Beats the built-in switching rules in about 63% of paired games.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Learned farming AI", isOn: Bindable(model).learnedFarming)
                .disabled(model.isRunning || !model.simulateCounterswaps)
            Text("When a switch is available but the opponent can't punish yet, a small neural network decides whether to farm energy with fast moves for a few seconds first or switch right away. Needs counterswap simulation. A modest edge: about +2 points of win rate in held-out games.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .themedRow()
    }
}

/// One saved run: configuration summary + when it was fought.
private struct SavedTournamentRow: View {
    let run: SavedTournament
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.formatTitle)
                        .font(.subheadline.weight(.medium))
                    Text("\(TeamFinderModel.poolDescription(run.poolSize).capitalized) pool · \(run.fieldSize)-team field · \(run.date.formatted(date: .abbreviated, time: .shortened))\(run.importedAt == nil ? "" : " · shared")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            Spacer()

            ShareLink(item: ResultsShareItem(run: run), preview: SharePreview(run.shareTitle)) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .help("Share this tournament")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this saved tournament")
        }
    }
}

/// One saved AI Optimizer run: configuration summary + when it climbed.
private struct SavedOptimizerRunRow: View {
    let run: SavedOptimizerRun
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.formatTitle)
                        .font(.subheadline.weight(.medium))
                    Text("\(TeamFinderModel.poolDescription(run.poolSize).capitalized) pool · \(run.restarts) restarts · \(run.date.formatted(date: .abbreviated, time: .shortened))\(run.importedAt == nil ? "" : " · shared")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            Spacer()

            ShareLink(item: ResultsShareItem(run: run), preview: SharePreview(run.shareTitle)) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .help("Share this run")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this saved run")
        }
    }
}

/// Detail column: the live tournament leaderboard (which doubles as the
/// final results once the run completes).
struct TeamFinderResultsView: View {
    var store: RankingsStore
    var model: TeamFinderModel
    var teamBuilder: TeamBuilderModel
    @Binding var selection: SidebarSelection?

    var body: some View {
        Group {
            if let graded = model.gradedTeams {
                GradedTeamsView(
                    teams: graded,
                    format: model.resultsFormat,
                    poolSize: model.resultsPoolSize,
                    openInBuilder: { openInTeamBuilder($0.members.map(\.member)) })
            } else if let results = model.optimizerResults {
                OptimizerResultsView(
                    results: results,
                    format: model.resultsFormat,
                    poolSize: model.resultsPoolSize,
                    movesById: store.movesById,
                    store: store,
                    model: model,
                    openInBuilder: { openInTeamBuilder($0.members.map(\.member)) })
            } else if let standings = model.standings {
                TeamFinderSimulationView(
                    standings: standings,
                    format: model.resultsFormat,
                    poolSize: model.resultsPoolSize,
                    openInBuilder: { openInTeamBuilder($0.members.map(\.member)) })
            } else {
                ContentUnavailableView(
                    "Find Suggested Teams",
                    systemImage: "wand.and.stars",
                    description: Text(emptyDescription)
                )
            }
        }
        .navigationTitle("Suggested Teams")
    }

    private var emptyDescription: String {
        switch model.phase {
        case .searching where model.method == .gradeCheck:
            "Grading every candidate trio with the Team Builder's static analysis…"
        case .searching where model.method == .aiOptimizer:
            "Building the meta field and starting hill-climbs…"
        case .searching: "Seeding the tournament — ranking every candidate trio by meta coverage…"
        case .loadingRankings: "Loading rankings…"
        default: "Pick a format and run the Party Finder to watch teams battle for the top of the leaderboard."
        }
    }

    /// Loads the team into the Team Builder (and points it at the finder's
    /// format so the analysis grades match the cup the team was found for).
    private func openInTeamBuilder(_ members: [TeamMember]) {
        if let format = model.resultsFormat {
            store.format = format
        }
        teamBuilder.setTeam(members)
        selection = .teamBuilder
    }
}

/// Popover content for locking a Pokémon into every AI Optimizer team: a
/// search field filters both the bench (for the finder's league) and the
/// full roster, so the user can lock either an owned Pokémon (with its real
/// IVs/moves) or any meta pick. A plain `TextField` is used instead of
/// `.searchable` since this view has no navigation container to host a
/// search field in on macOS.
private struct LockedPokemonPickerView: View {
    var store: RankingsStore
    var bench: BenchStore
    var format: RankingFormat
    var excludingSpeciesIds: Set<String>
    var onSelect: (TeamMember) -> Void

    @State private var searchText = ""

    private var league: League { League(cpCap: format.cp) }

    private var benchResults: [BenchEntry] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return bench.entries.filter { entry in
            guard entry.league == league, !excludingSpeciesIds.contains(entry.speciesId) else { return false }
            guard !query.isEmpty else { return true }
            let name = store.pokemonById[entry.speciesId]?.speciesName ?? entry.speciesId
            return name.localizedCaseInsensitiveContains(query)
                || (!entry.nickname.isEmpty && entry.nickname.localizedCaseInsensitiveContains(query))
        }
    }

    private var allResults: [Pokemon] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return store.eligiblePokemon(for: format).filter { pokemon in
            guard !excludingSpeciesIds.contains(pokemon.speciesId) else { return false }
            guard !query.isEmpty else { return true }
            return pokemon.speciesName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search Pokémon", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            Divider()
            List {
                if !benchResults.isEmpty {
                    Section("From Your Bench") {
                        ForEach(benchResults) { entry in
                            benchRow(entry)
                        }
                    }
                    .themedRow()
                }
                Section("All Pokémon") {
                    ForEach(Array(allResults.prefix(50))) { pokemon in
                        allRow(pokemon)
                    }
                }
                .themedRow()
            }
            .overlay {
                if benchResults.isEmpty && allResults.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
        .frame(minWidth: 300, idealWidth: 320, minHeight: 360, idealHeight: 440)
    }

    private func benchRow(_ entry: BenchEntry) -> some View {
        Button {
            onSelect(entry.asTeamMember())
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(entry.nickname.isEmpty
                             ? (store.pokemonById[entry.speciesId]?.speciesName ?? entry.speciesId)
                             : entry.nickname)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        if entry.shadow { ShadowBadge() }
                    }
                    Text(entry.ivs.map { "IVs \($0.atk)/\($0.def)/\($0.hp)" } ?? "Optimal IVs")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let sp = store.pokemonById[entry.speciesId] {
                    TypeBadgeRow(types: sp.displayTypes)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func allRow(_ pokemon: Pokemon) -> some View {
        Button {
            if let member = store.makeMember(speciesId: pokemon.speciesId) {
                onSelect(member)
            }
        } label: {
            HStack(spacing: 10) {
                Text(pokemon.speciesName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer()
                TypeBadgeRow(types: pokemon.displayTypes)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
