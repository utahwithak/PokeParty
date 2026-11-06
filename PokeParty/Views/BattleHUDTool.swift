//
//  BattleHUDTool.swift
//  PokeParty
//
//  Battle HUD as a top-level tool. The middle column lists the team being
//  checked (edited in Team Builder); the detail column hosts `OpponentCheckView`.
//

import SwiftUI

#if os(macOS)

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
            ForEach(groups) { group in
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
    }

    private func matches(_ team: Team, query: String) -> Bool {
        team.name.localizedCaseInsensitiveContains(query)
            || team.members.contains { store.name(forSpeciesId: $0.speciesId).localizedCaseInsensitiveContains(query) }
    }

    private func teamRow(_ team: Team, in group: LeagueGroup) -> some View {
        let isLoaded = group.format != nil && team.matches(store.format) && team.members == model.members
        return Button {
            guard let format = group.format else { return }
            model.setTeam(team.members, for: format)
            store.format = format
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                CoachConnectionRow(phoneLink: phoneLink)
                BattleHistorySection(coach: coach, store: store, team: model.members, selectedId: $selectedBattleId)
                CoachInputsPanel(
                    coach: coach, team: model.members, opponents: opponents, store: store,
                    onNewBattle: newBattle)
                CoachBanner(coach: coach)
                teamCards
                OpponentCheckView(
                    store: store, model: model,
                    onOpponentsChange: { opponents = $0 },
                    observedFastMoves: coach.observedFastMoves,
                    onActiveOpponent: { activeOpponentId = $0 },
                    onReset: newBattle,
                    resetToken: resetToken,
                    faintedOpponents: coach.inputs.opponentFainted,
                    phoneLink: phoneLink)
                BattleLogSection(coach: coach, store: store, selectedId: selectedBattleId)
                BattleReviewSection(coach: coach, store: store, team: model.members, selectedId: selectedBattleId)
                BattleInsightsSection(coach: coach, store: store, team: model.members)
                AttributionFooter()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Battle HUD")
        .onAppear {
            phoneLink.start()
            refresh()
        }
        .onDisappear { phoneLink.stop() }
        .onChange(of: coach.inputs) { refresh() }
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
    }

    /// Starts over: opponents cleared, shields back to two each, nobody fainted.
    private func newBattle() {
        selectedBattleId = nil
        activeOpponentId = nil
        coach.newBattle()
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
        if opponents.indices.contains(previous), !coach.inputs.opponentFainted.contains(previous),
           coach.inputs.opponentAlive < 3 - coach.inputs.opponentFainted.count {
            coach.inputs.opponentFainted.insert(previous)
            coach.inputs.opponentHP[previous] = nil
        }
        coach.inputs.opponentActive = index
    }

    /// The team being coached, with the same editable moves and fast-move
    /// counts as the Team Builder.
    @ViewBuilder
    private var teamCards: some View {
        if !model.members.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                ForEach(0..<TeamBuilderModel.maxMembers, id: \.self) { index in
                    if index < model.members.count {
                        let fainted = coach.inputs.fainted.contains(index)
                        TeamMemberCard(index: index, store: store, model: model)
                            .opacity(fainted ? 0.4 : 1)
                            .overlay(alignment: .topTrailing) {
                                if fainted { FaintedBadge().padding(8) }
                            }
                    } else {
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func refresh() {
        coach.refresh(team: model.members, opponents: opponents, store: store)
    }
}

/// iPhone connection status, kept at the top so it's obvious whether the
/// phone is feeding the coach. Expands to setup instructions.
private struct CoachConnectionRow: View {
    let phoneLink: PhoneLinkServer
    @State private var showInfo = false

    private var status: (text: String, color: Color) {
        if let name = phoneLink.phoneName { return ("Connected to \(name)", .green) }
        switch phoneLink.state {
        case .listening: return ("Waiting for iPhone", .orange)
        case .failed: return ("iPhone link unavailable", .red)
        case .stopped: return ("iPhone link off", .secondary)
        }
    }

    var body: some View {
        let status = status
        DisclosureGroup(isExpanded: $showInfo) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your iPhone can send the opponent it sees in a Pokémon GO battle straight to this Mac, which fills in the opponent slots below.")
                Text("On iPhone: open PokeParty → Check Opponent → Detect from screen, choose Entire Screen, then start a battle. Both devices need to be on the same Wi-Fi network, and the iPhone needs iOS 27.")
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
                .font(.system(size: 38, weight: .heavy, design: .rounded))
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

/// What the coach can't read off the screen yet: shields, who's out, who's fainted.
private struct CoachInputsPanel: View {
    @Bindable var coach: BattleCoachModel
    let team: [TeamMember]
    let opponents: [TeamMember]
    let store: RankingsStore
    let onNewBattle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 24) {
                shieldPicker("Your shields", selection: $coach.inputs.myShields)
                shieldPicker("Their shields", selection: $coach.inputs.opponentShields)
                Spacer()
                Button(action: onNewBattle) {
                    Label("New battle", systemImage: "arrow.counterclockwise")
                }
                .help("Clear the opponents and reset shields, fainted Pokémon and HP")
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
                Label("Shields, Pokémon left and your active Pokémon are coming from your iPhone.", systemImage: "iphone.gen3.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let note = coach.note {
                Label(note, systemImage: "scope")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
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
#endif
