//
//  TeamFinderView.swift
//  PokeParty
//
//  The 3v3 Party Finder: pick a format, pool and method, run it, and watch the
//  results settle. `TeamFinderView` is the content column (configuration, a
//  pinned run bar, and saved results); `TeamFinderResultsView` is the detail
//  column, which hands the live standings to `TeamFinderSimulationView`.
//
//  The column is a Form kept short on purpose: the choices that matter (format,
//  pool, method and its one or two headline settings) are always visible, and
//  everything else sits in collapsed groups — optimizer constraints, battle
//  simulation (shared by every method that fights battles) and advanced.
//

import SwiftUI

/// Content column: configure and start a run, or reopen a saved one.
struct TeamFinderView: View {
    var store: RankingsStore
    var model: TeamFinderModel
    var teamBuilder: TeamBuilderModel
    var bench: BenchStore
    var hiddenCups: HiddenCupsStore
    @Binding var selection: SidebarSelection?
    /// Forwarded to the pushed results screen (iOS) so a collapsed layout can
    /// navigate to the Team Builder column.
    var onOpenedTeamBuilder: () -> Void = {}
    @State private var showingLockedPicker = false
    @State private var showingStrongAgainstPicker = false
    @State private var showingResults = false
    @State private var showConstraints = false
    @State private var showSimulation = false
    @State private var showAdvanced = false
    @Environment(ShareImportModel.self) private var shareImport

    private static var deviceName: String {
        #if os(macOS)
        "the Mac"
        #else
        "this device"
        #endif
    }

    private var visibleCupFormats: [RankingFormat] {
        store.cupFormats.filter { !hiddenCups.isHidden($0.id) }
    }

    var body: some View {
        Form {
            setupSection
            methodSection
            if model.runsTournament { tournamentFieldSection }
            if model.method.isOptimizer { constraintsSection }
            if model.simulatesBattles { simulationSection }
            advancedSection
            savedSections
        }
        .formStyle(.grouped)
        .themedBackground()
        .onAppear { model.refreshOpponentSample() }
        // The run button, progress and Cancel stay pinned so a long form never
        // hides them.
        .safeAreaInset(edge: .bottom, spacing: 0) { runBar }
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
            TeamFinderResultsView(store: store, model: model, teamBuilder: teamBuilder, selection: $selection,
                                  onOpenedTeamBuilder: onOpenedTeamBuilder,
                                  dismissResults: { showingResults = false })
        }
        #endif
    }

    // MARK: - Setup & method

    private var setupSection: some View {
        Section("Setup") {
            presetControl

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

            Picker("Candidate pool", selection: Bindable(model).poolSize) {
                ForEach(TeamFinderModel.poolSizes, id: \.self) { size in
                    Text(size >= TeamFinderModel.fullListPoolSize ? "Full list (very slow)" : "Top \(size)").tag(size)
                }
            }
            .disabled(model.isRunning)
        }
        .themedRow()
    }

    /// Quick / Balanced / Thorough; nothing is selected once settings are
    /// adjusted by hand ("Custom").
    private var presetControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Effort", selection: Binding<TeamFinderModel.Preset?>(
                get: { model.currentPreset },
                set: { if let preset = $0 { model.apply(preset) } })
            ) {
                ForEach(TeamFinderModel.Preset.allCases) { preset in
                    Text(preset.title).tag(Optional(preset))
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isRunning)
            Text(model.currentPreset?.detail ?? "Custom — adjusted in the sections below")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var methodSection: some View {
        Section("Method") {
            Picker("Method", selection: Bindable(model).method) {
                ForEach(TeamFinderModel.Method.allCases) { method in
                    Text(method.title).tag(method)
                }
            }
            .disabled(model.isRunning)

            Text(model.method.summary)
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.method.supportsVerify {
                Toggle("Verify with a 3v3 tournament", isOn: Bindable(model).verifyWithTournament)
                    .disabled(model.isRunning)
                Text(verifyCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.method.isOptimizer {
                restartsControl
                if model.method == .aiOptimizer {
                    Toggle("Include opponents from my meta", isOn: Bindable(model).useObservedMeta)
                        .disabled(model.isRunning)
                    Text("Adds the opponents you've logged for this format as extra threats — leads count most.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if model.usesObservedMeta { opponentSampleNote }
        }
        .themedRow()
    }

    /// How much logged data backs the opponents being used, and how that
    /// limits their influence — so a thin log isn't mistaken for the real meta.
    private var opponentSampleNote: some View {
        let sample = model.opponentSample
        let battles = sample.battles
        let headline: String
        let detail: String
        let color: Color
        let icon: String
        switch sample.verdict {
        case .none:
            headline = "No opponents logged for this format"
            detail = model.method == .myMeta
                ? "Log opponents in the Team Builder or by scanning battles before running My Meta."
                : "Turning this on has no effect until you've logged some opponents."
            color = .orange; icon = "exclamationmark.triangle.fill"
        case .thin, .limited:
            let thin = sample.verdict == .thin
            headline = "\(battles) \(battles == 1 ? "battle" : "battles") logged — \(thin ? "very little" : "limited") data"
            detail = "Your logged opponents count at \(Int((sample.confidence * 100).rounded()))%; the rest of the weight stays on the regular meta. Log \(OpponentSample.fullConfidenceBattles - battles) more for full weight."
            color = thin ? .orange : Color(red: 0.75, green: 0.55, blue: 0)
            icon = thin ? "exclamationmark.triangle.fill" : "info.circle.fill"
        case .good:
            headline = "\(battles) battles logged — good data"
            detail = "Your logged opponents count at full weight."
            color = Theme.win; icon = "checkmark.circle.fill"
        }
        return VStack(alignment: .leading, spacing: 2) {
            Label(headline, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var verifyCaption: String {
        if model.verifyWithTournament {
            return model.method == .gradeCheck
                ? "Only teams graded A across the board fight a full 3v3 round robin, which settles their order."
                : "The chosen teams fight a full 3v3 round robin, which settles their order."
        }
        return model.method == .gradeCheck
            ? "Lists the AAAA teams from pairwise 1v1 matchups only — no battles, much faster."
            : "Lists the teams with their Team Builder grades — no battles, much faster."
    }

    private var restartsControl: some View {
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
    }

    // MARK: - Tournament

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

                Text(model.method == .tournament
                     ? "\(model.fieldSize) teams — \(model.estimatedBattles.formatted()) battles. Every team fights every other; bigger fields take longer."
                     : "Up to \(model.fieldSize) teams enter the round robin — only the teams that qualify, so it is often far fewer.")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .themedRow()
    }

    // MARK: - Optimizer constraints

    private var constraintsSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showConstraints) {
                lockedPokemonContent
                strongAgainstContent
            } label: {
                HStack {
                    Text("Constraints")
                    Spacer()
                    Text(constraintsSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .themedRow()
    }

    private var constraintsSummary: String {
        let locked = model.lockedMembers.count
        let strong = model.strongAgainstMembers.count
        if locked == 0 && strong == 0 { return "None" }
        var parts: [String] = []
        if locked > 0 { parts.append("\(locked) locked") }
        if strong > 0 { parts.append("\(strong) strong against") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var lockedPokemonContent: some View {
        Text("Locked Pokémon (\(model.lockedMembers.count)/\(TeamFinderModel.maxLockedMembers))")
            .font(.subheadline.weight(.semibold))
        ForEach(model.lockedMembers) { member in
            memberRow(member,
                      shadow: Binding(get: { member.shadow },
                                      set: { model.setLockedMemberShadow($0, for: member) }),
                      remove: { model.unlockMember(member) })
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
        Text("Every team is built around these, searching for the best partners and lead/switch/closer order.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var strongAgainstContent: some View {
        Text("Strong against (\(model.strongAgainstMembers.count)/\(TeamFinderModel.maxStrongAgainstMembers))")
            .font(.subheadline.weight(.semibold))
            .padding(.top, 4)
        ForEach(model.strongAgainstMembers) { member in
            memberRow(member,
                      shadow: Binding(get: { member.shadow },
                                      set: { model.setStrongAgainstShadow($0, for: member) }),
                      remove: { model.removeStrongAgainst(member) })
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
        Text("Teams are also weighted against these as extra threats, without forcing any onto the team.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// A locked / strong-against Pokémon row: name, optional shadow toggle, remove.
    private func memberRow(
        _ member: TeamMember, shadow: Binding<Bool>, remove: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(store.name(forSpeciesId: member.speciesId))
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            if let species = store.pokemonById[member.speciesId],
               species.isShadow || species.isShadowEligible || member.shadow {
                Toggle("Shadow", isOn: shadow)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption)
            }
        }
    }

    // MARK: - Battle simulation (shared)

    /// The AI and realism settings every battle-fighting method uses, in one
    /// collapsed group instead of repeated per method.
    private var simulationSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showSimulation) {
                toggleRow("Simulate counterswaps", isOn: Bindable(model).simulateCounterswaps,
                          detail: "Adds safe swaps, counterswaps, escapes and sac swaps to every battle. More realistic, slower.")
                toggleRow("Optimal shield timing", isOn: Bindable(model).optimalShields,
                          detail: "Solves the best shield play per matchup instead of the fast heuristic. Much slower.")
                toggleRow("Learned shield AI", isOn: Bindable(model).learnedShields,
                          detail: "A small network trained to imitate optimal shielding. Ignored when optimal timing is on.",
                          disabled: model.optimalShields)
                toggleRow("Learned switch AI", isOn: Bindable(model).learnedSwitches,
                          detail: "Picks switches with a network trained on rollouts — beats the built-in rules in about 63% of games.")
                toggleRow("Learned farming AI", isOn: Bindable(model).learnedFarming,
                          detail: "Decides whether to farm energy before switching (about +2 points). Needs counterswaps.",
                          disabled: !model.simulateCounterswaps)
                if model.method.isOptimizer { playSkillControl }
            } label: {
                HStack {
                    Text("Battle simulation")
                    Spacer()
                    Text(simulationSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .themedRow()
    }

    private var simulationSummary: String {
        var parts: [String] = []
        if model.optimalShields { parts.append("optimal shields") }
        else if model.learnedShields { parts.append("learned shields") }
        if model.learnedSwitches { parts.append("learned switches") }
        if model.simulateCounterswaps { parts.append("counterswaps") }
        return parts.isEmpty ? "Heuristics" : parts.joined(separator: ", ")
    }

    /// A toggle with a one-line explanation under it.
    private func toggleRow(
        _ title: String, isOn: Binding<Bool>, detail: String, disabled: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: isOn)
                .disabled(model.isRunning || disabled)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var playSkillControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Slider(
                value: Binding(
                    get: { Double(model.playSkill.rawValue) },
                    set: { model.playSkill = PlaySkill(rawValue: Int($0.rounded())) ?? .perfect }),
                in: 0...Double(PlaySkill.allCases.count - 1),
                step: 1
            ) {
                Text("Your play skill")
            } minimumValueLabel: {
                Text("Perfect")
            } maximumValueLabel: {
                Text("Beginner")
            }
            .disabled(model.isRunning || model.isValidatingBroadField)
            Text("\(model.playSkill.title): \(model.playSkill.detail)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.playSkill != .perfect {
                Text("Scores teams with your own switch decisions going wrong now and then. About 3× slower; win rates are typical outcomes, not exact odds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !model.simulateCounterswaps {
                    Text("Turn on “Simulate counterswaps” for the full effect — otherwise only the pick for a fainted Pokémon can go wrong.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        Section {
            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                if model.method.isOptimizer {
                    if model.method == .aiOptimizer {
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
                            Text("\(model.metaSize) top-ranked opponent threats to climb against (auto-scales with pool size). More is more representative but costs a battle per swap per threat.")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                    toggleRow("Explore alternate movesets", isOn: Bindable(model).exploreAlternateMovesets,
                              detail: "Also try alternate fast and charged move combos. Broader search, slower; off by default.")

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
                        Text("\(model.broadFieldSize.formatted()) random meta teams for the optional “Validate vs Full Meta” check")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

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
                    Text("Use up to \(model.coreLimit) of \(CoreLimit.totalCores) cores — fewer keeps \(Self.deviceName) responsive during a long search. Applies immediately.")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .themedRow()
    }

    // MARK: - Run bar

    /// Pinned at the bottom: the run button, or live progress with Cancel.
    private var runBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isRunning {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        progressView
                        if let eta = model.eta.label {
                            Text(eta)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(store.pokemonById.isEmpty)

                if let estimate = model.runTimeEstimate {
                    Text(estimate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            if case .failed(let message) = model.phase {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private var progressView: some View {
        if model.phase == .loadingRankings {
            ProgressView("Loading rankings…")
        } else if model.method.isOptimizer {
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
    }

    private var seedingLabel: String {
        switch model.method {
        case .tournament: return "Seeding tournament…"
        case .gradeCheck: return model.verifyWithTournament ? "Finding AAAA teams…" : "Grading teams…"
        case .aiOptimizer, .myMeta: return "Building meta field…"
        case .safeLeadCover: return "Finding safe leads and cover…"
        }
    }

    private var runButtonTitle: String {
        switch model.method {
        case .tournament: return "Run Tournament"
        case .gradeCheck: return model.verifyWithTournament ? "Run AAAA Tournament" : "Find AAAA Teams"
        case .aiOptimizer: return "Run AI Optimizer"
        case .myMeta: return "Run My Meta Optimizer"
        case .safeLeadCover: return "Find Safe-Lead Teams"
        }
    }

    // MARK: - Saved results

    @ViewBuilder
    private var savedSections: some View {
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
}
