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
    @State private var coach = BattleCoachModel()
    @State private var opponents: [TeamMember] = []
    /// Listens for opponents sent from the iPhone while this screen is up.
    @State private var phoneLink = PhoneLinkServer()
    /// The opponent most recently detected or picked — the one on the field.
    @State private var activeOpponentId: String?
    /// Bumped to make the opponent slots clear along with the coach's state.
    @State private var resetToken = UUID()
    /// A past game picked from the set tracker; nil follows the game in progress.
    @State private var selectedBattleId: UUID?
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

/// The line between the main panel and the coaching bar. Drag it left or right
/// to resize the bar; double-click resets it to the default width.
private struct CoachBarDivider: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    /// The bar's width when the current drag began.
    @State private var startWidth: Double?
    @State private var hovering = false

    var body: some View {
        Divider()
            // A wider, invisible grab area around the 1pt line.
            .overlay {
                Rectangle()
                    .fill(hovering || startWidth != nil ? Color.accentColor.opacity(0.35) : .clear)
                    .frame(width: 4)
            }
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            #if os(macOS)
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            #endif
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = startWidth ?? width
                        startWidth = start
                        // The bar is on the right, so dragging left makes it wider.
                        width = min(max(start - drag.translation.width, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in startWidth = nil }
            )
            .onTapGesture(count: 2) { width = 340 }
            .help("Drag to resize the coaching bar. Double-click to reset.")
    }
}

/// iPhone connection status, kept at the top so it's obvious whether the
/// phone is feeding the coach. Expands to setup instructions.
private struct CoachConnectionRow: View {
    let phoneLink: PhoneLinkServer
    let store: RankingsStore
    @State private var showInfo = false
    #if os(iOS)
    /// iPad: this device's own Screen Scan, started and stopped from here.
    @Environment(OpponentScanModel.self) private var scan
    #endif

    private var deviceName: String {
        #if os(macOS)
        "this Mac"
        #else
        "this iPad"
        #endif
    }

    private var status: (text: String, color: Color) {
        #if os(iOS)
        if scan.isScanning { return ("Scanning this iPad's screen", .green) }
        #endif
        if let name = phoneLink.phoneName { return ("Connected to \(name)", .green) }
        switch phoneLink.state {
        case .listening: return ("Waiting for iPhone", .orange)
        case .failed: return ("iPhone link unavailable", .red)
        case .stopped: return ("iPhone link off", .secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            card
            #if os(iOS)
            // Why a scan didn't start (e.g. no screen capture on the simulator).
            if let message = scan.stream.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            #endif
        }
    }

    private var card: some View {
        let status = status
        return DisclosureGroup(isExpanded: $showInfo) {
            VStack(alignment: .leading, spacing: 6) {
                #if os(iOS)
                Text("Tap Begin Scan, choose Entire Screen, then open Pokémon GO next to PokeParty in Split View or Slide Over. This iPad reads the battle itself and fills in the opponent slots below.")
                #endif
                Text("Your iPhone can also send the opponent it sees in a Pokémon GO battle straight to \(deviceName), which fills in the opponent slots below.")
                Text("On iPhone: open PokeParty → Screen Scan, choose Entire Screen, then start a battle. Both devices need to be on the same Wi-Fi network, and the iPhone needs iOS 27.")
                if case .failed(let message) = phoneLink.state {
                    Text(message).foregroundStyle(.red)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
                Text(status.text)
                    .font(.subheadline.weight(.medium))
                Circle().fill(status.color).frame(width: 8, height: 8)
                #if os(iOS)
                Spacer()
                Button(scan.isScanning ? "Stop Scan" : "Begin Scan") {
                    if scan.isScanning {
                        Task { await scan.end() }
                    } else {
                        scan.begin(store: store)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(scan.isScanning ? .red : .accentColor)
                .controlSize(.small)
                #endif
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The tip itself — big enough to read at a glance mid-battle.
private struct CoachBanner: View {
    let coach: BattleCoachModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headline)
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(2)
                .foregroundStyle(tint)
            Text(detail)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        // In a corner overlay, not the stack, so it appearing doesn't resize the banner.
        .overlay(alignment: .topTrailing) {
            ProgressView()
                .controlSize(.small)
                .padding(14)
                .opacity(coach.phase == .thinking ? 1 : 0)
        }
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(tint.opacity(0.4), lineWidth: 2))
        .animation(.easeOut(duration: 0.2), value: headline)
    }

    private var isSwitch: Bool {
        if case .switchTo? = coach.advice?.recommended.action { return true }
        return false
    }

    private var tint: Color {
        guard coach.advice != nil, coach.phase == .ready || coach.phase == .thinking else { return .secondary }
        return isSwitch ? .orange : .green
    }

    private var headline: String {
        switch coach.phase {
        case .needsTeam: return "Build your team"
        case .needsOpponent: return "Add the opponent"
        case .needsActive: return "Pick your active Pokémon"
        case .failed: return "No advice"
        case .thinking, .ready: return coach.advice?.headline ?? "Thinking…"
        }
    }

    private var detail: String {
        switch coach.phase {
        case .needsTeam: return "Add up to three Pokémon in Team Builder."
        case .needsOpponent: return "Search for the opponent below, or detect them from your iPhone."
        case .needsActive: return "The Pokémon marked as active is also marked fainted."
        case .failed(let message): return message
        case .thinking, .ready:
            guard let advice = coach.advice else { return "Simulating this matchup…" }
            return advice.detail
        }
    }
}

/// The shield call for each charged move their Pokémon might throw, shown before
/// any of them goes off so the decision is already made when the banner appears.
private struct ShieldPlanCard: View {
    let coach: BattleCoachModel

    var body: some View {
        if !coach.shieldPlan.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("If they throw…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(coach.shieldPlan, id: \.moveName) { move in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verdict(move))
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(tint(move).opacity(0.22), in: Capsule())
                        VStack(alignment: .leading, spacing: 1) {
                            Text(move.moveName).font(.body.weight(.semibold))
                            Text(move.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("The sim's call against your Pokémon at its current HP. Their moves are a guess until seen thrown.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func verdict(_ move: ThrowAlert.Incoming) -> String {
        switch move.call {
        case .shield: return "SHIELD"
        case .takeIt: return "TANK"
        case .noShields: return "NO SHIELD"
        }
    }

    private func tint(_ move: ThrowAlert.Incoming) -> Color {
        switch move.call {
        case .shield: return .red
        case .takeIt: return .green
        case .noShields: return .orange
        }
    }
}

/// The shield call when they throw a charged move, and how long until each side
/// can switch again.
private struct TempoCard: View {
    let coach: BattleCoachModel

    /// How long the shield call stays up after a throw.
    private static let incomingLifetime: TimeInterval = 6

    var body: some View {
        if coach.hasPhoneData, coach.tempo.active(.mine) != nil || coach.tempo.active(.theirs) != nil {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let now = context.date.timeIntervalSinceReferenceDate
                VStack(alignment: .leading, spacing: 12) {
                    if let incoming = coach.incomingThrow, now - coach.incomingThrowAt < Self.incomingLifetime {
                        incomingBanner(incoming)
                    }
                    HStack(alignment: .top, spacing: 24) {
                        column("You", side: .mine, at: now)
                        column("Them", side: .theirs, at: now)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func incomingBanner(_ incoming: ThrowAlert.Incoming) -> some View {
        let tint: Color = incoming.call == .shield ? .red : (incoming.call == .takeIt ? .green : .orange)
        return VStack(alignment: .leading, spacing: 2) {
            Text(incoming.headline).font(.title2.weight(.bold))
            Text(incoming.detail).font(.callout)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.5), lineWidth: 2))
    }

    private func column(_ title: String, side: TempoTracker.Side, at now: TimeInterval) -> some View {
        let wait = coach.tempo.switchRemaining(side, at: now)
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Text(wait > 0 ? "Switch in \(Int(wait.rounded(.up)))s" : "Can switch")
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(wait > 0 ? .orange : .green)
        }
        .frame(maxWidth: 220, alignment: .leading)
    }
}

/// The script for the lead matchup, from the sims: what to shield, what to throw,
/// and whether to swap. Shown only while it's still the lead.
private struct LeadPlanCard: View {
    let coach: BattleCoachModel

    var body: some View {
        if let plan = coach.leadPlan {
            VStack(alignment: .leading, spacing: 10) {
                Text("Lead plan · \(plan.myName) vs \(plan.opponentName)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(plan.headline)
                    .font(.title2.weight(.bold))
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(plan.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(index + 1).")
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(step)
                        }
                    }
                }
                BaitCallView(bait: plan.bait)
                HStack(spacing: 8) {
                    ForEach(plan.shieldLines, id: \.shields) { line in
                        Text("\(line.shields)–\(line.shields) shields: \(line.verdict.phrase)")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(color(for: line.verdict).opacity(0.18), in: Capsule())
                    }
                }
                Text("Based on \(plan.samples) simulated games, most of which end this way (\(Int((plan.share * 100).rounded()))%).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color(for: plan.verdict).opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func color(for verdict: LeadCoach.Verdict) -> Color {
        switch verdict {
        case .dominant, .favored: return .green
        case .close: return .yellow
        case .unfavored, .hopeless: return .red
        }
    }
}

/// The bait and shield calls, shared by the lead and mid-game cards.
private struct BaitCallView: View {
    let bait: BaitCall.Plan?

    var body: some View {
        if let bait, !bait.lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Bait & shields")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(bait.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.callout)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// After the lead: where the shields stand, rules of thumb for them, and who to
/// close the game with.
private struct MidGameCard: View {
    let coach: BattleCoachModel

    var body: some View {
        if !coach.inLead, let plan = coach.midGame {
            VStack(alignment: .leading, spacing: 10) {
                Text("Mid-game")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(plan.headline)
                    .font(.title2.weight(.bold))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(plan.tips.enumerated()), id: \.offset) { _, tip in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•").foregroundStyle(.secondary)
                            Text(tip)
                        }
                    }
                }
                BaitCallView(bait: plan.bait)
                if plan.endgame.count > 1 {
                    Divider()
                    Text("Endgame, no shields left")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(plan.endgame) { row in
                        HStack(spacing: 8) {
                            Text(row.name).font(.body.weight(.medium))
                            Text("beats \(Int((row.winShare * 100).rounded()))%")
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                            switch row.role {
                            case .closer: tag("Closer", .green)
                            case .sacrifice: tag("Spare", .orange)
                            case .neutral: EmptyView()
                            }
                        }
                    }
                }
                Text("Sims assume fresh energy (it isn't on screen); HP is used where read. Rules of thumb are guidance, not certainties.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule())
    }
}

/// Who the opponent probably has in the back, from what they've shown and what
/// the meta pairs with it.
private struct BackLineCard: View {
    let coach: BattleCoachModel

    var body: some View {
        if !coach.backLine.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Likely in the back")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(coach.backLine) { guess in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(guess.name).font(.body.weight(.medium))
                        Text("\(Int((guess.likelihood * 100).rounded()))%")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if !guess.covers.isEmpty {
                            Text("covers \(guess.covers.map(\.capitalized).joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text("A guess from their lead's weaknesses and the most-used Pokémon in this league. The coach plays its advice against teams like these.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// What the coach can't read off the screen yet: shields, who's out, who's fainted.
private struct CoachInputsPanel: View {
    @Bindable var coach: BattleCoachModel
    let team: [TeamMember]
    let opponents: [TeamMember]
    let store: RankingsStore
    /// The phone is connected and feeding the coach.
    let detecting: Bool
    /// Who's feeding it: "your iPhone", or "this iPad" when its own Screen Scan is.
    let source: String
    /// Open by hand while detecting, to correct what the phone read.
    @State private var showManual = false

    var body: some View {
        if detecting {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showManual.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "iphone.gen3.radiowaves.left.and.right").foregroundStyle(.green)
                        Text("Detecting from \(source)").font(.subheadline.weight(.medium))
                        Text(summary).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(showManual ? 90 : 0))
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show the shields and active Pokémon, to correct them by hand")
                if showManual { inputs }
                noteLabel
            }
            .padding(12)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        } else {
            inputs
                .padding(12)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    /// What the phone has read, in a line.
    private var summary: String {
        var parts = ["Shields \(coach.inputs.myShields)–\(coach.inputs.opponentShields)"]
        if team.indices.contains(coach.inputs.myActive) {
            parts.append(store.name(forSpeciesId: team[coach.inputs.myActive].speciesId))
        }
        return parts.joined(separator: " · ")
    }

    private var inputs: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 24) {
                shieldPicker("Your shields", selection: $coach.inputs.myShields)
                shieldPicker("Their shields", selection: $coach.inputs.opponentShields)
                Spacer()
            }
            if !team.isEmpty {
                HStack(spacing: 8) {
                    Text("You").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .leading)
                    ForEach(Array(team.enumerated()), id: \.offset) { index, member in
                        myChip(index: index, member: member)
                    }
                }
            }
            if !opponents.isEmpty {
                HStack(spacing: 8) {
                    Text("Them").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .leading)
                    ForEach(Array(opponents.enumerated()), id: \.offset) { index, member in
                        theirChip(index: index, member: member)
                    }
                }
            }
            if coach.hasPhoneData {
                Label("Shields, Pokémon left and your active Pokémon are coming from \(source).", systemImage: "iphone.gen3.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !detecting { noteLabel }
        }
    }

    /// What the coach inferred from the screen (e.g. an opponent's fast move).
    @ViewBuilder
    private var noteLabel: some View {
        if let note = coach.note {
            Label(note, systemImage: "scope")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func shieldPicker(_ title: String, selection: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                ForEach(0...2, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 120)
        }
    }

    /// Tap to make this Pokémon the active one; the context menu marks it fainted.
    private func myChip(index: Int, member: TeamMember) -> some View {
        let fainted = coach.inputs.fainted.contains(index)
        return chip(store.name(forSpeciesId: member.speciesId) + (fainted ? " ✕ fainted" : hpText(coach.inputs.myHP[index])),
                    selected: coach.inputs.myActive == index && !fainted) {
            if !fainted { coach.inputs.myActive = index }
        }
        .opacity(fainted ? 0.45 : 1)
        .contextMenu {
            Button(fainted ? "Mark alive" : "Mark fainted") {
                if fainted { coach.inputs.fainted.remove(index) } else { coach.inputs.fainted.insert(index) }
            }
        }
        .help("Click to make active. Right-click to mark fainted.")
    }

    /// Tap to make this the opponent on the field; the context menu marks it fainted.
    private func theirChip(index: Int, member: TeamMember) -> some View {
        let fainted = coach.inputs.opponentFainted.contains(index)
        return chip(store.name(forSpeciesId: member.speciesId) + (fainted ? " ✕ fainted" : hpText(coach.inputs.opponentHP[index])),
                    selected: coach.inputs.opponentActive == index && !fainted) {
            if !fainted { coach.inputs.opponentActive = index }
        }
        .opacity(fainted ? 0.45 : 1)
        .contextMenu {
            Button(fainted ? "Mark alive" : "Mark fainted") {
                if fainted { coach.inputs.opponentFainted.remove(index) } else { coach.inputs.opponentFainted.insert(index) }
            }
        }
    }

    /// " 77%" when this Pokémon's HP has been read.
    private func hpText(_ fraction: Double?) -> String {
        fraction.map { " \(Int(($0 * 100).rounded()))%" } ?? ""
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(selected ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.07), in: Capsule())
                .overlay(Capsule().stroke(selected ? Color.accentColor : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}
