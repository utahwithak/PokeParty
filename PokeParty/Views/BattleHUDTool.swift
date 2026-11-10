//
//  BattleHUDTool.swift
//  PokeParty
//
//  Battle HUD as a top-level tool. The middle column lists the team being
//  checked (edited in Team Builder); the detail column hosts `OpponentCheckView`.
//

import SwiftUI

/// Middle column: every saved team across all leagues, active cups first,
/// with a search box and a league filter. Picking one switches the league
/// and loads the team, so the coach is ready for that league's battle.
struct BattleHUDTeamPane: View {
    let store: RankingsStore
    let model: TeamBuilderModel
    let savedTeams: SavedTeamsStore

    @State private var searchText = ""
    /// `RankingFormat.id` to show, or nil for every league.
    @State private var leagueFilter: String?
    /// The team and league last picked here, restored on the next launch.
    @AppStorage("battleHUDLastTeamId") private var lastTeamId = ""
    @AppStorage("battleHUDLastFormatId") private var lastFormatId = ""
    /// Restore only once per launch, so later visits keep what Team Builder has open.
    private static var didRestoreLastTeam = false

    /// A league's saved teams. `format` is nil for a cup that's no longer
    /// running — its rankings aren't loaded, so its teams can't be coached.
    private struct LeagueGroup: Identifiable {
        let id: String
        let title: String
        let format: RankingFormat?
        let teams: [Team]
    }

    /// Active cups first, then the core leagues, then past cups.
    private var groups: [LeagueGroup] {
        let known = store.cupFormats + RankingFormat.coreLeagues
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = savedTeams.teams.filter { team in
            query.isEmpty || matches(team, query: query)
        }

        var result: [LeagueGroup] = []
        for format in known {
            let teams = visible.filter { $0.matches(format) }
            if !teams.isEmpty {
                result.append(LeagueGroup(id: format.id, title: format.title, format: format, teams: teams))
            }
        }
        let pastCups = visible.filter { team in !known.contains { team.matches($0) } }
        for cup in Dictionary(grouping: pastCups, by: { "\($0.cup)-\($0.cp)" }).sorted(by: { $0.key < $1.key }) {
            let sample = cup.value[0]
            result.append(LeagueGroup(
                id: cup.key, title: "\(sample.cup) · \(sample.cp) CP (ended)",
                format: nil, teams: cup.value))
        }
        return result.filter { leagueFilter == nil || $0.id == leagueFilter }
    }

    /// Leagues that have any saved team, for the filter menu.
    private var filterOptions: [(id: String, title: String)] {
        let known = store.cupFormats + RankingFormat.coreLeagues
        var options = known.filter { format in savedTeams.teams.contains { $0.matches(format) } }
            .map { (id: $0.id, title: $0.title) }
        if savedTeams.teams.contains(where: { team in !known.contains { team.matches($0) } }) {
            options += Dictionary(grouping: savedTeams.teams.filter { team in !known.contains { team.matches($0) } },
                                  by: { "\($0.cup)-\($0.cp)" })
                .sorted { $0.key < $1.key }
                .map { (id: $0.key, title: "\($0.value[0].cup) · \($0.value[0].cp) CP (ended)") }
        }
        return options
    }

    var body: some View {
        List {
            if savedTeams.teams.isEmpty {
                Section("Saved teams") {
                    Text("Save a team from Team Builder and it will show up here.")
                        .foregroundStyle(.secondary)
                }
            } else if groups.isEmpty {
                Section("Saved teams") {
                    Text("No teams match.").foregroundStyle(.secondary)
                }
            }
            let allGroups = groups
            ForEach(allGroups.filter { $0.format != nil }) { group in
                Section {
                    ForEach(group.teams) { team in teamRow(team, in: group) }
                } header: {
                    HStack(spacing: 6) {
                        if let format = group.format {
                            Image(systemName: format.isCoreLeague ? "shield.lefthalf.filled" : "trophy.fill")
                                .foregroundStyle(format.tint)
                        }
                        Text(group.title)
                    }
                }
            }
            // Cups no longer in rotation can't be coached, so they sit apart.
            let past = allGroups.filter { $0.format == nil }
            if !past.isEmpty {
                Section("Past leagues") {
                    ForEach(past) { group in
                        Text(group.title.replacingOccurrences(of: " (ended)", with: ""))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        ForEach(group.teams) { team in teamRow(team, in: group) }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search teams or Pokémon")
        .toolbar {
            ToolbarItem {
                Picker("League", selection: $leagueFilter) {
                    Text("All leagues").tag(String?.none)
                    Divider()
                    ForEach(filterOptions, id: \.id) { Text($0.title).tag(String?.some($0.id)) }
                }
                .pickerStyle(.menu)
                .help("Show saved teams from one league")
            }
        }
        .navigationTitle("Battle HUD")
        .onAppear(perform: restoreLastTeam)
        // Cup formats load after launch; a remembered cup team waits for them.
        .onChange(of: store.cupFormats.map(\.id)) { restoreLastTeam() }
    }

    /// Reopens the team last loaded here, in its league, the first time the HUD
    /// shows after launch. Later visits keep whatever Team Builder has open.
    private func restoreLastTeam() {
        guard !Self.didRestoreLastTeam, let teamId = UUID(uuidString: lastTeamId) else { return }
        guard let team = savedTeams.team(id: teamId) else {
            // The team was deleted; nothing to restore.
            Self.didRestoreLastTeam = true
            return
        }
        guard let format = (store.cupFormats + RankingFormat.coreLeagues).first(where: { $0.id == lastFormatId && team.matches($0) })
        else { return }
        Self.didRestoreLastTeam = true
        guard model.currentTeamId != teamId || store.format != format else { return }
        model.select(team, for: format)
        store.format = format
    }

    private func matches(_ team: Team, query: String) -> Bool {
        team.name.localizedCaseInsensitiveContains(query)
            || team.members.contains { store.name(forSpeciesId: $0.speciesId).localizedCaseInsensitiveContains(query) }
    }

    private func teamRow(_ team: Team, in group: LeagueGroup) -> some View {
        let isLoaded = group.format != nil && team.matches(store.format) && team.members == model.members
        return Button {
            guard let format = group.format else { return }
            model.select(team, for: format)
            store.format = format
            lastTeamId = team.id.uuidString
            lastFormatId = format.id
            Self.didRestoreLastTeam = true
        } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(team.name).font(.headline)
                    Text(team.members.map { store.name(forSpeciesId: $0.speciesId) }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isLoaded {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(group.format == nil)
        .help(group.format == nil ? "This cup has ended, so it can't be coached." : "Load this team into Battle HUD")
    }
}

/// Detail column: the coaching banner and its battle inputs, above the opponent check.
struct BattleHUDDetailView: View {
    let store: RankingsStore
    let model: TeamBuilderModel
    @State private var coach: BattleCoachModel
    @State private var opponents: [TeamMember] = []
    /// Listens for opponents sent from the iPhone while this screen is up.
    @State private var phoneLink = PhoneLinkServer()
    /// The opponent most recently detected or picked — the one on the field.
    @State private var activeOpponentId: String?
    /// Bumped to make the opponent slots clear along with the coach's state.
    @State private var resetToken = UUID()
    /// A past game picked from the set tracker; nil follows the game in progress.
    @State private var selectedBattleId: UUID?
    init(store: RankingsStore, model: TeamBuilderModel, history: BattleHistoryStore) {
        self.store = store
        self.model = model
        _coach = State(initialValue: BattleCoachModel(history: history))
    }

    /// Whether the coaching bar on the right is showing.
    @AppStorage("battleHUDShowCoachBar") private var showCoachBar = true
    /// Width of the whole detail column, to pick side-by-side or stacked layout.
    @State private var availableWidth: CGFloat = 1000
    /// Width of the coaching bar, set by dragging its left edge.
    @AppStorage("battleHUDCoachBarWidth") private var storedCoachBarWidth = 340.0
    private static let coachBarWidthRange: ClosedRange<Double> = 260...640
    private var coachBarWidth: Binding<Double> {
        Binding(get: { min(max(storedCoachBarWidth, Self.coachBarWidthRange.lowerBound), Self.coachBarWidthRange.upperBound) },
                set: { storedCoachBarWidth = $0 })
    }
    /// Below this the coaching bar can't sit beside the main panel, so it stacks above it.
    /// Three Pokémon cards need about 860pt across, plus the bar. Stacking
    /// the bar instead keeps all three cards in a row on a 1440pt-wide window.
    private static let mainPanelMinWidth: CGFloat = 880
    private var isWide: Bool { availableWidth >= Self.mainPanelMinWidth + coachBarWidth.wrappedValue }
    #if os(iOS)
    /// iPad: this device's own Screen Scan also feeds the coach.
    @Environment(OpponentScanModel.self) private var scan
    #endif

    /// Where the coach's live readings come from right now.
    private var detectionSource: String? {
        #if os(iOS)
        if scan.isScanning { return "this iPad" }
        #endif
        return phoneLink.phoneName != nil ? "your iPhone" : nil
    }

    var body: some View {
        // The main panel is always the first child of the same stack, so resizing
        // across the wide/narrow threshold keeps its identity — and with it the
        // opponent slots, edited movesets and lead held in its @State. Narrow
        // windows just drop the side bar (the coaching content moves inside the panel).
        HStack(spacing: 0) {
            mainPanel
                .frame(minWidth: 0, maxWidth: .infinity)
            if isWide && showCoachBar {
                // Dragging can't widen the bar past the point where the layout would stack.
                let maxWidth = max(Self.coachBarWidthRange.lowerBound,
                                   min(Self.coachBarWidthRange.upperBound, availableWidth - Self.mainPanelMinWidth))
                CoachBarDivider(width: coachBarWidth, range: Self.coachBarWidthRange.lowerBound...maxWidth)
                ScrollView { coachContent.padding(16) }
                    .frame(width: coachBarWidth.wrappedValue)
                    .transition(.move(edge: .trailing))
            }
        }
        .clipped()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .animation(.easeInOut(duration: 0.2), value: showCoachBar)
        .toolbar {
            ToolbarItem {
                Button {
                    showCoachBar.toggle()
                } label: {
                    Label(showCoachBar ? "Hide Coaching Bar" : "Show Coaching Bar",
                          systemImage: "sidebar.trailing")
                }
                .help(showCoachBar ? "Hide the coaching bar" : "Show the coaching bar")
            }
        }
        .navigationTitle("Battle HUD")
        .onAppear {
            phoneLink.start()
            refresh()
        }
        .onDisappear { phoneLink.stop() }
        .onChange(of: coach.inputs) { refresh() }
        .onChange(of: coach.seenOpponentMoves) { refresh() }
        .onChange(of: model.members) { refresh() }
        .onChange(of: opponents) {
            syncActiveOpponent()
            refresh()
        }
        .onChange(of: activeOpponentId) { syncActiveOpponent() }
        .onChange(of: store.format) { refresh() }
        .onChange(of: phoneLink.latestSnapshot) { _, snapshot in
            guard let snapshot else { return }
            coach.apply(snapshot, team: model.members, opponents: opponents, store: store)
        }
        #if os(iOS)
        .onChange(of: scan.latestSnapshot) { _, snapshot in
            guard let snapshot else { return }
            coach.apply(snapshot, team: model.members, opponents: opponents, store: store)
        }
        #endif
    }

    /// Right-hand column: the coach's call and plans, with the battle log.
    private var coachContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            CoachBanner(coach: coach)
            CoachOptionsCard(coach: coach)
            ShieldPlanCard(coach: coach)
            TempoCard(coach: coach)
            LeadPlanCard(coach: coach)
            MidGameCard(coach: coach)
            BackLineCard(coach: coach)
            BattleLogSection(coach: coach, store: store, selectedId: selectedBattleId)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Left column: connection, battle inputs, and both teams. In a narrow
    /// window the coaching content sits on top, since there's no room beside it.
    private var mainPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !isWide && showCoachBar {
                    coachContent
                }
                CoachConnectionRow(phoneLink: phoneLink, store: store)
                BattleHistorySection(coach: coach, store: store, team: model.members, selectedId: $selectedBattleId,
                                     onNewGame: { newBattle() }, onNewSet: { newBattle(newSet: true) })
                CoachInputsPanel(coach: coach, team: model.members, opponents: opponents, store: store,
                                 detecting: detectionSource != nil && coach.hasPhoneData,
                                 source: detectionSource ?? "your iPhone")
                teamCards
                OpponentCheckView(
                    store: store, model: model,
                    onOpponentsChange: { opponents = $0 },
                    observedFastMoves: coach.observedFastMoves,
                    seenChargedMoves: coach.seenOpponentMoves,
                    onActiveOpponent: { activeOpponentId = $0 },
                    resetToken: resetToken,
                    faintedOpponents: coach.inputs.opponentFainted,
                    phoneLink: phoneLink)
                BattleReviewSection(coach: coach, store: store, team: model.members, selectedId: selectedBattleId)
                BattleInsightsSection(coach: coach, store: store, team: model.members)
                AttributionFooter()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Starts over: opponents cleared, shields back to two each, nobody fainted.
    /// A new set is the same thing in a fresh set.
    private func newBattle(newSet: Bool = false) {
        selectedBattleId = nil
        activeOpponentId = nil
        coach.newBattle(format: store.format, newSet: newSet)
        resetToken = UUID()
    }

    /// Points the coach at the most recently seen opponent. Done on a new
    /// sighting only, so choosing a different one by hand sticks.
    private func syncActiveOpponent() {
        guard let id = activeOpponentId, let index = opponents.firstIndex(where: { $0.speciesId == id }),
              coach.inputs.opponentActive != index else { return }
        // A missed faint banner: their Pokémon-left count is lower than the faints
        // seen, and someone new is out, so the one that was out has fainted.
        let previous = coach.inputs.opponentActive
        if coach.opponentActiveEstablished, opponents.indices.contains(previous),
           !coach.inputs.opponentFainted.contains(previous),
           coach.inputs.opponentAlive < 3 - coach.inputs.opponentFainted.count {
            coach.inputs.opponentFainted.insert(previous)
            coach.inputs.opponentHP[previous] = nil
        }
        coach.inputs.opponentActive = index
        coach.opponentActiveEstablished = true
    }

    /// The team being coached, with the same editable moves and fast-move
    /// counts as the Team Builder.
    @ViewBuilder
    private var teamCards: some View {
        if !model.members.isEmpty {
            // Side by side when wide; stacked when three cards won't fit.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { teamCardItems(padEmpty: true) }
                VStack(spacing: 12) { teamCardItems(padEmpty: false) }
            }
        }
    }

    @ViewBuilder
    private func teamCardItems(padEmpty: Bool) -> some View {
        ForEach(0..<TeamBuilderModel.maxMembers, id: \.self) { index in
            if index < model.members.count {
                let fainted = coach.inputs.fainted.contains(index)
                TeamMemberCard(index: index, store: store, model: model)
                    .opacity(fainted ? 0.4 : 1)
                    .overlay(alignment: .topTrailing) {
                        if fainted { FaintedBadge().padding(8) }
                    }
            } else if padEmpty {
                Color.clear.frame(maxWidth: .infinity)
            }
        }
    }

    private func refresh() {
        coach.refresh(team: model.members, opponents: opponents, store: store)
    }
}
