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
        .onChange(of: model.members) { analyzeIfNeeded() }
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

    /// Click to pick a Pokémon from this league's bench and list.
    private func emptySlot(_ index: Int) -> some View {
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
            .frame(maxWidth: .infinity)
            .frame(minHeight: 150)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                    .foregroundStyle(.quaternary)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
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
                onAddSuggestion: model.isFull ? nil : { addSuggestion($0) },
                bench: bench,
                league: League(cpCap: store.format.cp))
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

    private func addSuggestion(_ speciesId: String) {
        if let member = model.makeMember(speciesId: speciesId, store: store) {
            model.add(member)
        }
    }
}

// MARK: - Team member card

/// Also used by Battle HUD to show the team being coached.
struct TeamMemberCard: View {
    let index: Int
    let store: RankingsStore
    @Bindable var model: TeamBuilderModel
    /// When set, the card shows a swap button that calls it (the Team Builder
    /// opens its Pokémon picker; Battle HUD leaves it off).
    var onReplace: (() -> Void)? = nil

    private var member: TeamMember? {
        model.members.indices.contains(index) ? model.members[index] : nil
    }
    private var species: Pokemon? {
        member.flatMap { store.pokemonById[$0.speciesId] }
    }
    private var recommended: [String] {
        member.flatMap { store.entry(id: $0.speciesId)?.moveset } ?? []
    }

    var body: some View {
        if let member, let species {
            VStack(alignment: .leading, spacing: 8) {
                header(member: member, species: species)
                TypeBadgeRow(types: species.displayTypes)
                reorderControls
                Divider()
                movesetEditor(member: member, species: species)
                if species.isShadow || species.isShadowEligible || member.shadow {
                    shadowToggle(member: member)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func header(member: TeamMember, species: Pokemon) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(slotLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text(species.speciesName)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if member.shadow { ShadowBadge() }
                }
            }
            Spacer()
            if let onReplace {
                Button(action: onReplace) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .foregroundStyle(.secondary)
                        .touchTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Replace Pokémon")
                .help("Replace with another Pokémon")
            }
            Button {
                model.remove(at: index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .touchTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove from team")
            .help("Remove from team")
        }
    }

    private var slotLabel: String {
        switch index {
        case 0: return "LEAD"
        default: return "#\(index + 1)"
        }
    }

    @ViewBuilder
    private var reorderControls: some View {
        if model.members.count > 1 {
            HStack(spacing: 6) {
                Button { model.move(from: index, to: index - 1) } label: {
                    Image(systemName: "chevron.left")
                        .touchTarget(width: 40, height: 32)
                }
                .accessibilityLabel("Move earlier")
                .disabled(index == 0)
                Button { model.move(from: index, to: index + 1) } label: {
                    Image(systemName: "chevron.right")
                        .touchTarget(width: 40, height: 32)
                }
                .accessibilityLabel("Move later")
                .disabled(index >= model.members.count - 1)
                Spacer()
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .help("Reorder")
        }
    }

    private func movesetEditor(member: TeamMember, species: Pokemon) -> some View {
        let fastGain = store.move(id: member.fastMoveId)?.energyGain
        return VStack(alignment: .leading, spacing: 6) {
            TeamMovePicker(
                label: "Fast",
                currentId: member.fastMoveId,
                optionIds: species.fastMoves,
                recommendedId: recommended.first,
                includesNone: false,
                species: species,
                store: store,
                onSelect: { if let id = $0 { model.setFastMove(id, at: index) } },
                showsDetail: true)
            TeamMovePicker(
                label: "Charged 1",
                currentId: member.chargedMoveIds.first ?? "",
                optionIds: species.chargedMoves,
                recommendedId: recommended.count > 1 ? recommended[1] : nil,
                includesNone: false,
                species: species,
                store: store,
                onSelect: { if let id = $0 { model.setChargedMove(id, slot: 0, at: index) } },
                showsDetail: true, fastEnergyGain: fastGain)
            TeamMovePicker(
                label: "Charged 2",
                currentId: member.chargedMoveIds.count > 1 ? member.chargedMoveIds[1] : "",
                optionIds: species.chargedMoves,
                recommendedId: recommended.count > 2 ? recommended[2] : nil,
                includesNone: true,
                species: species,
                store: store,
                onSelect: { model.setChargedMove($0, slot: 1, at: index) },
                showsDetail: true, fastEnergyGain: fastGain)
            if species.hasThirdChargedMove {
                TeamMovePicker(
                    label: "Charged 3",
                    currentId: member.chargedMoveIds.count > 2 ? member.chargedMoveIds[2] : "",
                    optionIds: species.extraChargedMoves ?? [],
                    recommendedId: recommended.count > 3 ? recommended[3] : nil,
                    includesNone: true,
                    species: species,
                    store: store,
                    onSelect: { model.setChargedMove($0, slot: 2, at: index) },
                    showsDetail: true, fastEnergyGain: fastGain)
                MegaLevelPicker(level: member.megaLevel ?? species.megaLevel,
                                onSelect: { model.setMegaLevel($0, at: index) })
            }
        }
    }

    private func shadowToggle(member: TeamMember) -> some View {
        Toggle("Shadow", isOn: Binding(
            get: { member.shadow },
            set: { model.setShadow($0, at: index, store: store) }))
        .toggleStyle(.switch)
        .controlSize(.mini)
        .font(.caption)
    }
}

// MARK: - Mega level picker

/// Mega level (1–4) for a Mega with a third charged move. The mega move's
/// damage scales with it, and level 4 raises the level cap in Master League.
struct MegaLevelPicker: View {
    /// The level in effect (the member's own, else the species default).
    let level: Int
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("Mega Lv")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Picker("Mega level", selection: Binding(get: { level }, set: { onSelect($0) })) {
                ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
    }
}

// MARK: - Move picker

/// A compact menu to pick a move for a team slot, showing the current move's
/// name + type. Mirrors `PokemonDetailView`'s picker but sized for the cards.
/// Also used by the 1v1 Simulator's combatant cards (`MatchupDetailView`).
struct TeamMovePicker: View {
    let label: String
    let currentId: String            // "" == none
    let optionIds: [String]
    let recommendedId: String?
    let includesNone: Bool
    /// Species providing the move pool, for Elite TM / Legacy designations.
    let species: Pokemon
    let store: RankingsStore
    /// nil argument means "None" was chosen (second charged slot only).
    let onSelect: (String?) -> Void
    /// When set, a caption under the picker shows the move's turns / energy
    /// / fast-move counts. For a charged move, pass the fast move's energy gain.
    var showsDetail = false
    var fastEnergyGain: Int? = nil

    private var move: Move? { store.move(id: currentId) }
    private var designation: Pokemon.MoveDesignation? {
        species.moveDesignation(for: currentId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            pickerRow
            if showsDetail, let move {
                Text(move.detailText(fastEnergyGain: fastEnergyGain))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 64)   // label width + spacing
            }
        }
    }

    private var pickerRow: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Menu {
                if includesNone {
                    button(id: nil, label: "None")
                }
                ForEach(optionIds, id: \.self) { id in
                    button(id: id, label: optionLabel(id))
                }
            } label: {
                HStack(spacing: 5) {
                    Text(currentName)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .help(designation?.help ?? "")
                    if let move {
                        TypeBadge(type: move.type)
                        if showsDetail { ChargeBankBars(count: move.bankSize) }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func button(id: String?, label: String) -> some View {
        Button {
            onSelect(id)
        } label: {
            if (id ?? "") == currentId {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    /// Collapsed label: PvPoke's `*` convention flags Elite TM / Legacy moves.
    private var currentName: String {
        guard let move else { return "None" }
        return designation == nil ? move.name : move.name + "*"
    }

    private func optionLabel(_ id: String) -> String {
        guard let m = store.move(id: id) else { return id }
        var name = m.name
        if let designation = species.moveDesignation(for: id) {
            name += " (\(designation.label))"
        }
        if id == recommendedId { name += " (Recommended)" }
        return name
    }
}

/// One slanted segment per charge that fits in a full energy bar, like the
/// bars Pokémon GO draws beside a charged move.
struct ChargeBankBars: View {
    let count: Int

    var body: some View {
        if count > 0 {
            HStack(spacing: 2) {
                ForEach(0..<count, id: \.self) { _ in
                    Slant()
                        .fill(Color.secondary.opacity(0.6))
                        .frame(width: 14, height: 7)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Can bank \(count)")
            .help("A full energy bar holds \(count) of this move")
        }
    }

    /// A trapezoid leaning right, wider along the bottom.
    private nonisolated struct Slant: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let inset = rect.height * 0.5
            path.move(to: CGPoint(x: rect.minX + inset, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
            return path
        }
    }
}
