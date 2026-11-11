//
//  TeamBuilderDetailView.swift
//  PokeParty
//
//  Main panel of the 3v3 Team Builder. Shows the team as up to three editable
//  cards (moveset pickers, reorder, remove, shadow) under the team's name and
//  league, and the analysis (grades / threats / suggested teammates) below.
//  The team is the one picked in the middle column (`TeamBuilderView`), rated
//  against its own league; edits save as they're made. Pokémon are added from
//  a popover on an empty slot (`TeamPokemonPicker`).
//

import SwiftUI

struct TeamBuilderDetailView: View {
    var store: RankingsStore
    @Bindable var model: TeamBuilderModel
    var savedTeams: SavedTeamsStore
    var bench: BenchStore
    /// Mac only: jumps to Battle HUD with the current team loaded.
    var openBattleHUD: (() -> Void)? = nil
    @State private var showingBattle = false
    @State private var showingMetaTest = false
    @State private var metaTestModel = TeamMetaTestModel()
    @State private var showingSavePrompt = false
    @State private var saveName = ""
    /// The slot whose Pokémon picker is open.
    @State private var pickerSlot: Int?
    /// The slot whose Pokémon is being swapped for another.
    @State private var replaceSlot: Int?
    /// Pokémon checked against the current team (cleared when the team changes,
    /// since their ratings are for that team).
    @State private var checked: [ThreatEntry] = []
    @State private var nameText = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                controlsHeader
                teamEditor
                Divider()
                analysisContent
                AttributionFooter()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Team Builder")
        .onAppear { model.syncFromSaved(); analyzeIfNeeded(); syncNameText() }
        .onChange(of: model.members) { checked = []; analyzeIfNeeded() }
        // The open team changed outside the builder (an import, another device).
        .onChange(of: currentTeam?.members) { model.syncFromSaved() }
        .confirmationDialog(
            "Replace the unsaved draft?",
            isPresented: Binding(get: { model.pendingDraft != nil },
                                 set: { if !$0 { model.resolvePendingDraft(replace: false) } }),
            titleVisibility: .visible
        ) {
            Button("Replace Draft", role: .destructive) { model.resolvePendingDraft(replace: true) }
            Button("Keep Current Draft", role: .cancel) { model.resolvePendingDraft(replace: false) }
        } message: {
            Text("You have a draft in \(store.format.title) that hasn't been saved. Opening this team replaces it.")
        }
        .onChange(of: model.currentTeamId) { syncNameText() }
        .onChange(of: currentTeam?.name) { syncNameText() }
        // League changes reload the ranking list asynchronously; re-analyze once
        // the new meta has arrived.
        .onChange(of: store.entries) { analyzeIfNeeded() }
        .toolbar {
            ToolbarItem {
                Button {
                    pickerSlot = model.members.count
                } label: {
                    Label("Add Pokémon", systemImage: "magnifyingglass")
                }
                .disabled(model.isFull)
                .help("Search for a Pokémon to add to this team")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.isDraft { draftBar }
        }
        .sheet(isPresented: $showingBattle) {
            TeamBattleView(store: store, model: model, savedTeams: savedTeams, bench: bench)
        }
        .sheet(isPresented: $showingMetaTest) {
            TeamMetaTestView(store: store, teamBuilder: model, model: metaTestModel)
        }
        .alert("Save Team", isPresented: $showingSavePrompt) {
            TextField("Team name", text: $saveName)
            Button("Save") {
                let name = saveName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                let team = savedTeams.add(name: name, members: model.members,
                                          cup: store.format.cup, cp: store.format.cp)
                model.adopt(team)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves this team in \(store.format.title). From then on, changes save automatically.")
        }
    }

    // MARK: - Team name and draft

    private var currentTeam: Team? {
        model.currentTeamId.flatMap { savedTeams.team(id: $0) }
    }

    private func syncNameText() {
        nameText = currentTeam?.name ?? ""
    }

    private func commitName() {
        guard let id = model.currentTeamId else { return }
        savedTeams.rename(id: id, to: nameText)
        // An empty name isn't kept; show the stored one again.
        syncNameText()
    }

    /// The team's name, editable in place; a draft has none yet.
    @ViewBuilder
    private var titleField: some View {
        if currentTeam != nil {
            TextField("Team name", text: $nameText)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .focused($nameFocused)
                .onSubmit(commitName)
                .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
                .help("Rename this team")
        } else {
            Text(model.hasMembers ? "Untitled draft" : "No team open")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var leagueBadge: some View {
        Text(store.format.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(store.format.tint)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(store.format.tint.opacity(0.15), in: Capsule())
            .help("The league this team is rated against")
    }

    /// Pinned under a draft: it isn't saved until the player says so.
    private var draftBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            Text("This team isn't saved yet.").font(.subheadline.weight(.medium))
            Spacer()
            Button("Discard", role: .destructive) { model.discardDraft() }
            Button("Save Team…") {
                saveName = defaultSaveName
                showingSavePrompt = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func analyzeIfNeeded() {
        guard model.hasMembers else { return }
        model.analyze(using: store)
    }

    // MARK: - Controls

    /// The team's name and league, then the actions. On iOS the actions don't
    /// fit beside the name, so they drop to a second row.
    private var controlsHeader: some View {
        #if os(iOS)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                titleField
                leagueBadge
                Spacer()
                memberCountText
            }
            HStack(spacing: 10) {
                battleButton
                metaTestButton
                coachButton
                Spacer()
            }
        }
        #else
        HStack(spacing: 10) {
            titleField
            leagueBadge
            Spacer()
            battleButton
            metaTestButton
            coachButton
            memberCountText
        }
        #endif
    }

    private var battleButton: some View {
        Button {
            showingBattle = true
        } label: {
            Label("Battle", systemImage: "bolt.fill")
        }
        .disabled(!model.hasMembers)
        .help("Simulate a 3v3 against an opponent team")
    }

    @ViewBuilder
    private var coachButton: some View {
        if let openBattleHUD {
            Button(action: openBattleHUD) {
                Label("Battle HUD", systemImage: "speedometer")
            }
            .disabled(!model.hasMembers)
            .help("Coach this team through a live battle")
        }
    }

    private var metaTestButton: some View {
        Button {
            showingMetaTest = true
        } label: {
            Label("Test Against Meta", systemImage: "shuffle")
        }
        .disabled(!model.hasMembers)
        .help("Battle this team against a randomly generated field of meta teams")
    }

    private var memberCountText: some View {
        Text("\(model.members.count)/\(TeamBuilderModel.maxMembers)")
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    /// Default name for the save prompt: the members' species names.
    private var defaultSaveName: String {
        model.members
            .map { store.pokemonById[$0.speciesId]?.speciesName ?? $0.speciesId }
            .joined(separator: " / ")
    }

    // MARK: - Team editor

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// Side by side wherever there's room (Mac, iPad). On a compact-width
    /// iPhone three cards in a row can't shrink enough to fit, so they stack
    /// full-width instead.
    @ViewBuilder
    private var teamEditor: some View {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            VStack(spacing: 12) { teamSlots }
        } else {
            HStack(alignment: .top, spacing: 12) { teamSlots }
        }
        #else
        HStack(alignment: .top, spacing: 12) { teamSlots }
        #endif
    }

    @ViewBuilder
    private var teamSlots: some View {
        ForEach(0..<TeamBuilderModel.maxMembers, id: \.self) { index in
            if index < model.members.count {
                TeamMemberCard(index: index, store: store, model: model, onReplace: { replaceSlot = index })
                    .contextMenu {
                        Button("Replace Pokémon…") { replaceSlot = index }
                    }
                    .popover(isPresented: Binding(
                        get: { replaceSlot == index },
                        set: { if !$0, replaceSlot == index { replaceSlot = nil } }
                    )) {
                        TeamPokemonPicker(store: store, model: model, bench: bench, replacing: index,
                                          onDone: { replaceSlot = nil })
                            #if os(iOS)
                            .presentationCompactAdaptation(.sheet)
                            #endif
                    }
            } else {
                emptySlot(index)
            }
        }
    }

    /// An empty slot: click to pick a Pokémon from this league's bench and list,
    /// or tap one of the suggested teammates (the ones that beat the team's
    /// biggest threats) to add it straight away. Once the team is full there
    /// are no empty slots, so no suggestions are shown.
    private func emptySlot(_ index: Int) -> some View {
        let suggestions = slotSuggestions(index)
        let league = League(cpCap: store.format.cp)
        return VStack(spacing: 8) {
            Button {
                pickerSlot = index
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Add Pokémon")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: suggestions.isEmpty ? 120 : 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Suggested")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(suggestions) { suggestion in
                        suggestionChip(suggestion, inBench: bench.contains(speciesId: suggestion.speciesId, league: league))
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .top)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                .foregroundStyle(.quaternary)
        )
        .popover(isPresented: Binding(
            get: { pickerSlot == index },
            set: { if !$0, pickerSlot == index { pickerSlot = nil } }
        )) {
            TeamPokemonPicker(store: store, model: model, bench: bench, onDone: { pickerSlot = nil })
                #if os(iOS)
                .presentationCompactAdaptation(.sheet)
                #endif
        }
    }

    private func suggestionChip(_ suggestion: SuggestionEntry, inBench: Bool) -> some View {
        Button {
            addSuggestion(suggestion.speciesId)
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(suggestion.speciesName)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        if suggestion.shadow { ShadowBadge() }
                        if inBench {
                            Image(systemName: "tray.fill")
                                .font(.caption2)
                                .foregroundStyle(.tint)
                                .help("In your bench")
                        }
                    }
                    TypeBadgeRow(types: suggestion.types)
                }
                Spacer(minLength: 0)
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.tint)
            }
            .padding(6)
            .frame(maxWidth: .infinity)
            .background(inBench ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Analysis

    #if os(iOS)
    /// On iPhone, Check Opponent stays a tab here; on Mac it's the Battle HUD tool.
    private enum DetailTab: String, CaseIterable {
        case analysis = "Analysis"
        case checkOpponent = "Check Opponent"
    }
    @State private var activeTab: DetailTab = .analysis

    @ViewBuilder
    private var analysisContent: some View {
        Picker("", selection: $activeTab) {
            ForEach(DetailTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 360)

        switch activeTab {
        case .analysis:
            analysisTabContent
        case .checkOpponent:
            OpponentCheckView(store: store, model: model)
        }
    }
    #else
    private var analysisContent: some View { analysisTabContent }
    #endif

    @ViewBuilder
    private var analysisTabContent: some View {
        if let analysis = model.analysis {
            TeamAnalysisSections(
                analysis: analysis,
                checked: checked,
                checkPicker: CheckPicker(store: store, bench: bench),
                onCheck: { check($0) },
                onRemoveChecked: { entry in checked.removeAll { $0.speciesId == entry.speciesId } },
                members: insightMembers,
                bannedTypes: TeamWeakness.bannedTypes(
                    in: store.cups.first { $0.name == store.format.cup }, cpCap: store.format.cp))
        } else if model.phase == .analyzing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Analyzing team…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        } else if !model.hasMembers {
            ContentUnavailableView(
                "Build a Team",
                systemImage: "person.3.sequence.fill",
                description: Text("Add up to three Pokémon from the list to see coverage, bulk, threats and suggested teammates for \(store.format.title)."))
            .frame(maxWidth: .infinity, minHeight: 200)
        }
    }

    /// The team as the weakness / lead panels need it: names, types and the
    /// ranking's per-role scores (the shadow ranking entry for a shadow member).
    private var insightMembers: [TeamInsightMember] {
        model.members.compactMap { member in
            guard let species = store.pokemonById[member.speciesId] else { return nil }
            let rankingId = member.shadow && !member.speciesId.hasSuffix("_shadow")
                ? member.speciesId + "_shadow" : member.speciesId
            let entry = store.entry(id: rankingId) ?? store.entry(id: member.speciesId)
            return TeamInsightMember(
                // A shadow species' own name may already say "(Shadow)".
                name: species.speciesName
                    + (member.shadow && !species.speciesName.hasSuffix("(Shadow)") ? " (Shadow)" : ""),
                types: species.types.filter { $0 != "none" },
                roles: RoleOrder.Scores(entry?.scores))
        }
    }

    /// Rates a searched-for Pokémon against the team and pins it above the threats.
    private func check(_ member: TeamMember) {
        Task {
            guard let entry = await model.compare(member, store: store) else { return }
            checked.removeAll { $0.speciesId == entry.speciesId }
            checked.insert(entry, at: 0)
        }
    }

    /// Suggested teammates for one empty slot: three each, so two empty slots
    /// offer different Pokémon. Skips anything already on the team (the analysis
    /// lags a team change by a moment).
    private func slotSuggestions(_ index: Int) -> [SuggestionEntry] {
        guard let all = model.analysis?.suggestions else { return [] }
        let available = all.filter { !model.contains(speciesId: $0.speciesId) }
        let ordinal = max(index - model.members.count, 0)   // empty slots trail the team
        return Array(available.dropFirst(ordinal * 3).prefix(3))
    }

    private func addSuggestion(_ speciesId: String) {
        if let member = model.makeMember(speciesId: speciesId, store: store) {
            model.add(member)
        }
    }
}

// MARK: - Team member card
