//
//  BattleLogTool.swift
//  PokeParty
//
//  Battle Log as a top-level tool: every recorded set, grouped into sessions
//  (the middle column), and the picked game's teams, log and sim review (the
//  detail column). The Battle HUD keeps only the set in progress.
//

import SwiftUI

/// Middle column: sessions (sets played within an hour of each other), each
/// listing its sets and their games. Picking a game shows it in the detail column.
struct BattleLogListPane: View {
    let history: BattleHistoryStore
    let store: RankingsStore
    @Binding var selectedId: UUID?
    /// Moves to the detail column when the split view is collapsed (iPhone-width layouts).
    var onSelect: () -> Void = {}

    var body: some View {
        let sessions = BattleSession.group(history.sets)
        List {
            if sessions.isEmpty {
                Text("Games recorded in Battle HUD show up here, grouped into sessions.")
                    .foregroundStyle(.secondary)
            }
            ForEach(sessions) { session in
                Section {
                    ForEach(session.sets) { set in
                        setRow(set)
                    }
                } header: {
                    HStack(spacing: 8) {
                        Text(title(of: session))
                        Spacer()
                        Text("\(session.wins)–\(session.losses)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                    }
                }
            }
        }
        .navigationTitle("Battle Log")
    }

    /// "Nov 9, 2026 · 9:06–9:26 AM": the day and the span the session covered.
    private func title(of session: BattleSession) -> String {
        let day = session.start.formatted(date: .abbreviated, time: .omitted)
        let start = session.start.formatted(date: .omitted, time: .shortened)
        let end = session.end.formatted(date: .omitted, time: .shortened)
        return start == end ? "\(day) · \(start)" : "\(day) · \(start)–\(end)"
    }

    private func setRow(_ set: BattleSetSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(set.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
                Text("\(set.wins)–\(set.losses)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                if set.id == history.currentSet.id {
                    Text("current").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                ForEach(Array(set.battles.enumerated()), id: \.element.id) { index, game in
                    chip(index: index, game: game)
                }
                Spacer(minLength: 0)
            }
            Text(opponentSummary(set))
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
        // Games dragged onto a set join it.
        .dropDestination(for: String.self) { items, _ in
            for item in items {
                if let id = UUID(uuidString: item) { history.move(id, toSet: set.id) }
            }
        }
    }

    /// Who the set was played against, from each game's opponents.
    private func opponentSummary(_ set: BattleSetSummary) -> String {
        var seen: [String] = []
        for game in set.battles {
            for member in game.opponents where !seen.contains(member.speciesId) { seen.append(member.speciesId) }
        }
        guard !seen.isEmpty else { return "No opponents recorded" }
        return "vs " + seen.map { store.name(forSpeciesId: $0) }.joined(separator: " · ")
    }

    private func chip(index: Int, game: RecordedBattle) -> some View {
        let color: Color = game.outcome == .win ? Theme.win : (game.outcome == .loss ? Theme.loss : .secondary)
        let label = game.outcome == .win ? "W" : (game.outcome == .loss ? "L" : "…")
        let selected = game.id == selectedId
        return Button {
            selectedId = game.id
            onSelect()
        } label: {
            Text("\(index + 1) \(label)")
                .font(.caption.weight(.bold).monospacedDigit())
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(color.opacity(selected ? 0.35 : 0.15), in: Capsule())
                .overlay(Capsule().stroke(selected ? color : .clear, lineWidth: 1.5))
                .foregroundStyle(color == .secondary ? Color.primary : color)
        }
        .buttonStyle(.plain)
        .help(game.date.formatted(date: .abbreviated, time: .shortened) + " — drag onto another set to move it")
        .draggable(game.id.uuidString)
        .contextMenu {
            Button("Move to a new set") { history.move(game.id, toSet: nil) }
            // The game in progress belongs to the Battle HUD until it ends.
            Button("Delete game", role: .destructive) {
                history.delete(game.id)
                if selectedId == game.id { selectedId = nil }
            }
            .disabled(game.id == history.currentId)
        }
    }
}

/// Detail column: one recorded game — result, both teams with the moves seen,
/// the event log and the sim's review.
struct BattleLogDetailView: View {
    let history: BattleHistoryStore
    let store: RankingsStore
    let selectedId: UUID?
    /// Marks results and runs reviews over the same history the HUD records into.
    @State private var coach: BattleCoachModel

    init(history: BattleHistoryStore, store: RankingsStore, selectedId: UUID?) {
        self.history = history
        self.store = store
        self.selectedId = selectedId
        _coach = State(initialValue: BattleCoachModel(history: history))
    }

    var body: some View {
        if let id = selectedId, let battle = history.battles.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(battle)
                    BattleTeamsCard(battle: battle, store: store)
                    BattleLogPanel(coach: coach, store: store, battle: battle)
                    BattleReviewPanel(coach: coach, store: store, battle: battle, team: battle.team)
                    BattleInsightsPanel(history: history, team: battle.team, store: store,
                                        cup: battle.cup, cp: battle.cp)
                    AttributionFooter()
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Battle Log")
        } else {
            ContentUnavailableView("Pick a game", systemImage: "clock.arrow.circlepath",
                                   description: Text("Choose a game from a set to see its teams, log and review."))
        }
    }

    private func header(_ battle: RecordedBattle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(battle.date.formatted(date: .complete, time: .shortened))
                .font(.title3.weight(.semibold))
            HStack(spacing: 8) {
                resultButton("Won", outcome: .win, tint: Theme.win, battle: battle)
                resultButton("Lost", outcome: .loss, tint: Theme.loss, battle: battle)
                if battle.outcomeDetected {
                    Text("read from the screen — tap to correct")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func resultButton(_ title: String, outcome: BattleOutcome, tint: Color, battle: RecordedBattle) -> some View {
        let isOn = battle.outcome == outcome
        return Button {
            coach.mark(battle, as: isOn ? nil : outcome, store: store)
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 4)
                .background(isOn ? tint.opacity(0.3) : Color.primary.opacity(0.07), in: Capsule())
                .overlay(Capsule().stroke(isOn ? tint : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}

/// Your team and theirs, with each opponent's charged moves marked seen (thrown
/// in the game) or guessed (the set the HUD had filled in).
struct BattleTeamsCard: View {
    let battle: RecordedBattle
    let store: RankingsStore

    var body: some View {
        let seen = battle.observedOpponentMoves
        VStack(alignment: .leading, spacing: 12) {
            side("Your team", members: battle.team, seen: nil)
            Divider()
            side("Opponent", members: battle.opponents, seen: seen)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    /// `seen` is nil for your own team, whose moves are all known.
    private func side(_ title: String, members: [TeamMember], seen: [String: [String]]?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if members.isEmpty {
                Text("None recorded").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(members) { member in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(store.name(forSpeciesId: member.speciesId) + (member.shadow ? " (Shadow)" : ""))
                        .font(.body.weight(.medium))
                    Text(moveName(member.fastMoveId)).font(.caption).foregroundStyle(.secondary)
                    ForEach(member.chargedMoveIds, id: \.self) { id in
                        let thrown = seen?[member.speciesId]?.contains(id) ?? false
                        Text(moveName(id))
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background((seen == nil || thrown ? Color.accentColor : Color.secondary).opacity(0.18), in: Capsule())
                            .help(seen == nil ? "" : (thrown ? "Seen thrown in this game" : "Not seen — a guess"))
                    }
                    Spacer(minLength: 0)
                }
            }
            // A move thrown that isn't in the stored set (the guess was wrong).
            if let seen {
                ForEach(members) { member in
                    let extra = (seen[member.speciesId] ?? []).filter { !member.chargedMoveIds.contains($0) }
                    if !extra.isEmpty {
                        Text("\(store.name(forSpeciesId: member.speciesId)) also threw \(extra.map(moveName).joined(separator: ", "))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Highlighted moves were seen thrown; dimmed ones are the HUD's guess.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func moveName(_ id: String) -> String {
        store.move(id: id)?.name ?? id
    }
}
