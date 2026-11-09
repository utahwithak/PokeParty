//
//  TeamBuilderView.swift
//  PokeParty
//
//  Middle column of the 3v3 Team Builder: every saved team, grouped by league
//  (the way Battle HUD lists them), each league with a "+" to start a team in
//  it. Picking a team opens it in the editor (`TeamBuilderDetailView`), where
//  edits save as they're made. A team opened from elsewhere (Party Finder,
//  Bench) shows up as an unsaved draft until it's saved.
//

import SwiftUI

struct TeamBuilderView: View {
    var store: RankingsStore
    @Bindable var model: TeamBuilderModel
    var savedTeams: SavedTeamsStore
    var hiddenCups: HiddenCupsStore
    /// Called after a team is opened, so a collapsed layout (iPhone) can move to the editor.
    var onOpenEditor: () -> Void = {}

    @State private var renaming: Team?
    @State private var renameText = ""
    @State private var deleting: Team?
    /// A switch waiting on the answer to "discard the draft?".
    @State private var pendingSwitch: (() -> Void)?
    @Environment(ShareImportModel.self) private var shareImport

    /// Core leagues and the cups in rotation: always listed, even with no teams yet.
    /// A cup the player hid from the sidebar still appears while it has teams,
    /// so those teams don't vanish.
    private var formats: [RankingFormat] {
        RankingFormat.coreLeagues + store.cupFormats.filter { cup in
            !hiddenCups.isHidden(cup.id) || savedTeams.teams.contains { $0.matches(cup) }
        }
    }

    /// Teams from cups that are no longer running: their rankings aren't
    /// loaded, so they can't be opened, only removed.
    private var pastTeams: [Team] {
        let known = store.cupFormats + RankingFormat.coreLeagues
        return savedTeams.teams.filter { team in !known.contains { team.matches($0) } }
    }

    var body: some View {
        List {
            ForEach(formats) { format in
                Section {
                    if model.isDraft, format == store.format { draftRow }
                    ForEach(savedTeams.teams(for: format)) { team in
                        teamRow(team, in: format)
                    }
                } header: {
                    header(for: format)
                }
            }
            let past = pastTeams
            if !past.isEmpty {
                Section("Past leagues") {
                    ForEach(Dictionary(grouping: past, by: { "\($0.cup) · \($0.cp) CP" }).sorted { $0.key < $1.key }, id: \.key) { group in
                        Text(group.key)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(group.value) { team in pastRow(team) }
                    }
                }
            }
        }
        .navigationTitle("Team Builder")
        .inlineNavigationTitle()
        .toolbar {
            ToolbarItem {
                Button {
                    shareImport.isImporterPresented = true
                } label: {
                    Label("Import Shared Team…", systemImage: "square.and.arrow.down")
                }
                .help("Import a team someone shared with you")
            }
        }
        .alert("Rename Team", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Team name", text: $renameText)
            Button("Rename") {
                if let renaming { savedTeams.rename(id: renaming.id, to: renameText) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete \(deleting?.name ?? "team")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let deleting { model.deleteTeam(deleting) }
            }
        } message: {
            Text("This can't be undone.")
        }
        .confirmationDialog(
            "Discard the unsaved draft?", isPresented: Binding(get: { pendingSwitch != nil }, set: { if !$0 { pendingSwitch = nil } }),
            titleVisibility: .visible
        ) {
            Button("Discard Draft", role: .destructive) {
                model.discardDraft()
                pendingSwitch?()
            }
        } message: {
            Text("The team you opened hasn't been saved. Save it from the editor first to keep it.")
        }
    }

    // MARK: - Rows

    private func header(for format: RankingFormat) -> some View {
        HStack(spacing: 6) {
            Image(systemName: format.isCoreLeague ? "shield.lefthalf.filled" : "trophy.fill")
                .foregroundStyle(format.tint)
            Text(format.title)
            Spacer()
            Button {
                switchTeam { newTeam(in: format) }
            } label: {
                Image(systemName: "plus.circle")
                    .touchTarget()
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("New team")
            .help("New team in \(format.title)")
        }
    }

    private var draftRow: some View {
        Button {
            onOpenEditor()
        } label: {
            row(title: "Untitled draft", subtitle: model.members.map { store.name(forSpeciesId: $0.speciesId) },
                selected: true, badge: "DRAFT")
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Discard Draft", role: .destructive) { model.discardDraft() }
        }
    }

    private func teamRow(_ team: Team, in format: RankingFormat) -> some View {
        Button {
            switchTeam { open(team, in: format) }
        } label: {
            row(title: team.name, subtitle: team.members.map { store.name(forSpeciesId: $0.speciesId) },
                selected: model.currentTeamId == team.id)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename…") { renameText = team.name; renaming = team }
            Button("Duplicate") {
                let copy = savedTeams.duplicate(team)
                switchTeam { open(copy, in: format) }
            }
            ShareLink(
                item: ResultsShareItem(teamNamed: team.name, members: team.members, cup: team.cup, cp: team.cp),
                preview: SharePreview(team.name)
            ) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button("Delete…", role: .destructive) { deleting = team }
        }
    }

    private func pastRow(_ team: Team) -> some View {
        row(title: team.name, subtitle: team.members.map { store.name(forSpeciesId: $0.speciesId) }, selected: false)
            .opacity(0.6)
            .contextMenu {
                Button("Delete…", role: .destructive) { deleting = team }
            }
            .help("This cup has ended, so its teams can't be edited.")
    }

    private func row(title: String, subtitle: [String], selected: Bool, badge: String? = nil) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.25), in: Capsule())
                    }
                }
                Text(subtitle.isEmpty ? "No Pokémon yet" : subtitle.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    // MARK: - Actions

    /// Runs `action` straight away, or after the player agrees to drop an unsaved draft.
    private func switchTeam(_ action: @escaping () -> Void) {
        if model.isDraft {
            pendingSwitch = action
        } else {
            action()
        }
    }

    private func open(_ team: Team, in format: RankingFormat) {
        store.format = format
        model.select(team, for: format)
        onOpenEditor()
    }

    private func newTeam(in format: RankingFormat) {
        let team = savedTeams.add(name: "New Team", members: [], cup: format.cup, cp: format.cp)
        open(team, in: format)
    }
}
