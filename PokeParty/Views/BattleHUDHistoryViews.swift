//
//  BattleHUDHistoryViews.swift
//  PokeParty
//
//  Battle HUD: the set tracker (wins and losses across a set of games), the
//  live battle log, and the sim review that says why a game was lost.
//

import SwiftUI

/// The set tracker. (The battle log, the sim review and "This team so far" are
/// `BattleLogSection`, `BattleReviewSection` and `BattleInsightsSection`, lower
/// down the screen, under the Pokémon.)
struct BattleHistorySection: View {
    let coach: BattleCoachModel
    let store: RankingsStore
    let team: [TeamMember]
    /// A game picked from the set; nil follows the game in progress.
    @Binding var selectedId: UUID?
    /// Ends the game in progress and clears the opponents for the next one.
    let onNewGame: () -> Void
    /// Same as a new game, but in a fresh set.
    let onNewSet: () -> Void

    private var history: BattleHistoryStore { coach.history }

    var body: some View {
        let shown = history.displayed(selectedId: selectedId)
        VStack(alignment: .leading, spacing: 14) {
            SetTrackerPanel(coach: coach, store: store, selectedId: $selectedId, shownId: shown?.id,
                            onNewGame: onNewGame, onNewSet: onNewSet)
        }
    }
}

/// How the sim's calls compare with your results over every game with this
/// team, kept under the sim review.
struct BattleInsightsSection: View {
    let coach: BattleCoachModel
    let store: RankingsStore
    let team: [TeamMember]

    var body: some View {
        BattleInsightsPanel(history: coach.history, team: team, store: store)
    }
}

/// The sim's review of the game shown above, kept under the battle log.
struct BattleReviewSection: View {
    let coach: BattleCoachModel
    let store: RankingsStore
    let team: [TeamMember]
    let selectedId: UUID?

    var body: some View {
        if let battle = coach.history.displayed(selectedId: selectedId) {
            BattleReviewPanel(coach: coach, store: store, battle: battle, team: team)
        }
    }
}

/// The log of the game shown above, kept below the Pokémon: it's reference
/// material and only grows, so it scrolls within a fixed height.
struct BattleLogSection: View {
    let coach: BattleCoachModel
    let store: RankingsStore
    let selectedId: UUID?

    var body: some View {
        if let battle = coach.history.displayed(selectedId: selectedId) {
            BattleLogPanel(coach: coach, store: store, battle: battle)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Battle log").font(.headline)
                Text("Press New game to start the next game. Earlier games are in the set above.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Set tracker

private struct SetTrackerPanel: View {
    let coach: BattleCoachModel
    let store: RankingsStore
    @Binding var selectedId: UUID?
    let shownId: UUID?
    let onNewGame: () -> Void
    /// Same as a new game, but in a fresh set.
    let onNewSet: () -> Void
    @State private var confirmingReset = false

    private var history: BattleHistoryStore { coach.history }

    var body: some View {
        let set = history.currentSet
        let games = set.battles
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Set").font(.headline)
                Text("\(set.wins)–\(set.losses)")
                    .font(.system(size: 30, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(set.wins > set.losses ? Theme.win : (set.wins < set.losses ? Theme.loss : .primary))
                Text(progressText(games: games))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }

            // Own row so a narrow panel never squeezes the score and progress text.
            // One main action, with the occasional ones tucked into labeled menus.
            HStack(spacing: 8) {
                Button(action: onNewGame) {
                    Label("Next game", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .help("Start the next game in this set, clearing the opponents and resetting shields and HP.")
                Menu {
                    Button("I won", systemImage: "checkmark.circle") {
                        history.addManual(outcome: .win, format: store.format)
                    }
                    Button("I lost", systemImage: "xmark.circle") {
                        history.addManual(outcome: .loss, format: store.format)
                    }
                } label: {
                    Label("Log a game", systemImage: "plus")
                }
                .help("Add a game the HUD missed, with its result, to this set")
                Menu {
                    Button("Start a new set", systemImage: "square.stack") {
                        selectedId = nil
                        onNewSet()
                    }
                    Divider()
                    Button("Reset this set to 0–0…", systemImage: "arrow.counterclockwise", role: .destructive) {
                        confirmingReset = true
                    }
                    .disabled(games.isEmpty)
                } label: {
                    Label("Set", systemImage: "ellipsis.circle")
                }
                .help("Start a new set (one starts by itself after \(BattleHistoryStore.setSize) games), or reset this one")
            }
            .controlSize(.regular)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                ForEach(Array(games.enumerated()), id: \.element.id) { index, game in
                    gameChip(index: index, game: game)
                }
                // After a delete the next game isn't there until "New game".
                if history.currentId == nil, games.count < BattleHistoryStore.setSize {
                    Text("\(games.count + 1) next")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .overlay(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                        .foregroundStyle(.secondary)
                        .help("Press New game to add it")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
            .dropDestination(for: String.self) { items, _ in drop(items, into: set.id) }

            if let battle = games.first(where: { $0.id == shownId }) {
                HStack(spacing: 8) {
                    Text("This game").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    resultButton("Won", outcome: .win, tint: Theme.win, battle: battle)
                    resultButton("Lost", outcome: .loss, tint: Theme.loss, battle: battle)
                    if battle.outcomeDetected {
                        Text("read from the screen — tap to correct")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { coach.deleteBattle(battle.id); selectedId = nil } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete this game from the history")
                }
            } else {
                Text("Press New game to add the next game to this set. Earlier sets are in Battle Log.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .confirmationDialog("Reset this set?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Delete \(games.count) game\(games.count == 1 ? "" : "s") and reset to 0–0", role: .destructive) {
                selectedId = nil
                history.resetSet()
            }
        } message: {
            Text("The games in this set and their logs are removed. Earlier sets aren't touched.")
        }
    }

    private func progressText(games: [RecordedBattle]) -> String {
        let decided = games.filter { $0.outcome != nil }.count
        let target = BattleHistoryStore.setSize
        if games.count >= target, decided == games.count, history.currentId == nil { return "set complete" }
        // The game in progress is already in `games`; between games the next one isn't.
        let number = history.currentId == nil ? games.count + 1 : games.count
        return "game \(min(max(number, 1), target)) of \(target) · \(decided) marked"
    }

    /// Games dragged onto a set join it.
    private func drop(_ items: [String], into setId: UUID) {
        for item in items {
            guard let id = UUID(uuidString: item) else { continue }
            history.move(id, toSet: setId)
        }
    }

    private func gameChip(index: Int, game: RecordedBattle) -> some View {
        let color: Color = game.outcome == .win ? Theme.win : (game.outcome == .loss ? Theme.loss : .secondary)
        let label = game.outcome == .win ? "W" : (game.outcome == .loss ? "L" : "…")
        let selected = game.id == shownId
        return Button {
            selectedId = game.id == history.currentId ? nil : game.id
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
            Button("Delete game", role: .destructive) {
                coach.deleteBattle(game.id)
                if selectedId == game.id { selectedId = nil }
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

// MARK: - Battle log

struct BattleLogPanel: View {
    let coach: BattleCoachModel
    let store: RankingsStore
    let battle: RecordedBattle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Battle log").font(.headline)
                Text(battle.id == coach.history.currentId ? "live" : battle.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            if battle.events.isEmpty {
                Text("Nothing logged yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                // Newest first, so what just happened is at the top.
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(battle.events.reversed()) { event in
                            row(event)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
            Text("Charged moves are named when the iPhone reads their \"used\" banner. Shields come from the shield icons.")
                .font(.caption2).foregroundStyle(.tertiary)
            if !battle.screenText.isEmpty {
                DisclosureGroup("Screen text the iPhone read (\(battle.screenText.count))") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(battle.screenText.reversed().prefix(150).enumerated()), id: \.offset) { _, entry in
                                HStack(spacing: 8) {
                                    Text(clock(entry.elapsed))
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                        .frame(width: 40, alignment: .trailing)
                                    Text(entry.y.map { "\(Int(($0 * 100).rounded()))%" } ?? "")
                                        .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                                        .frame(width: 36, alignment: .trailing)
                                        .help("How far down the screen this text was")
                                    Text(entry.text).font(.caption.monospaced()).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                    .padding(.top, 4)
                }
                .font(.caption)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private var summary: String {
        let swaps = battle.events.filter { $0.kind == .enter && $0.voluntary && $0.mine }.count
        let shields = battle.events.filter { $0.kind == .shield && $0.mine }.count
        return "\(swaps) swap\(swaps == 1 ? "" : "s") · \(shields) shield\(shields == 1 ? "" : "s") used by you"
    }

    private func row(_ event: BattleLogEvent) -> some View {
        if event.kind == .coach { return AnyView(coachRow(event)) }
        let (icon, color) = style(event)
        return AnyView(HStack(spacing: 8) {
            Text(clock(event.elapsed))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
            Image(systemName: icon).foregroundStyle(color).frame(width: 18)
            Text(event.text(name: { store.name(forSpeciesId: $0) }, move: { store.move(id: $0)?.name ?? $0 }))
                .font(.callout)
            Spacer(minLength: 0)
            Text("\(event.myShields)–\(event.opponentShields)")
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                .help("Shields: yours – theirs")
        })
    }

    /// The coach's advice: set apart from what happened, so it reads as the
    /// voice in your ear rather than another event.
    private func coachRow(_ event: BattleLogEvent) -> some View {
        // Entries from before the lines were kept separately have only the text.
        let lines = event.coachLines ?? [CoachNarrator.Line(kind: .call, text: event.note ?? "")]
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "megaphone.fill").foregroundStyle(.green)
                Text("Coach").font(.caption.weight(.semibold)).foregroundStyle(.green)
                Text(clock(event.elapsed))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                coachLine(line)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    /// One line of the advice. The call is the headline; the rest each get an icon, so the
    /// throw, the shield call and the fallback can be found by their symbols.
    @ViewBuilder
    private func coachLine(_ line: CoachNarrator.Line) -> some View {
        if line.kind == .call {
            Text(line.text)
                .font(.title3.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            let (icon, color) = coachStyle(line.kind)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon).foregroundStyle(color).frame(width: 18)
                Text(line.text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    private func coachStyle(_ kind: CoachNarrator.LineKind) -> (String, Color) {
        switch kind {
        case .call: return ("megaphone.fill", .green)
        case .throwMove: return ("bolt.fill", .orange)
        case .timing: return ("timer", .blue)
        case .shield: return ("shield.lefthalf.filled", .purple)
        case .plan: return ("list.bullet", .secondary)
        case .backup: return ("arrow.triangle.swap", .teal)
        case .closer: return ("star.fill", .yellow)
        }
    }

    private func style(_ event: BattleLogEvent) -> (String, Color) {
        let side: Color = event.mine ? .blue : .orange
        switch event.kind {
        case .enter: return (event.voluntary ? "arrow.left.arrow.right" : "arrow.right.circle", side)
        case .charged: return ("flame.fill", side)
        case .faint: return ("xmark.circle.fill", Theme.loss)
        case .shield: return ("shield.lefthalf.filled", .purple)
        case .bigHit: return ("bolt.fill", .yellow)
        case .effective: return ((event.value ?? 0) > 0 ? "arrow.up.circle" : "arrow.down.circle", .secondary)
        case .coach: return ("megaphone.fill", .green)
        }
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Sim review

struct BattleReviewPanel: View {
    let coach: BattleCoachModel
    let store: RankingsStore
    let battle: RecordedBattle
    let team: [TeamMember]

    private var review: BattleReviewer.Review? {
        coach.reviewedBattleId == battle.id ? coach.review : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("What could be better").font(.headline)
                if coach.isReviewing && coach.reviewedBattleId == battle.id { ProgressView().controlSize(.small) }
                Spacer()
                Button {
                    coach.reviewBattle(battle.id, store: store)
                } label: {
                    Label(review == nil ? "Run sim" : "Re-run", systemImage: "play.circle")
                }
                .disabled(battle.team.isEmpty || battle.opponents.isEmpty || coach.isReviewing)
                .help("Play these two teams through the 3v3 AI and compare with what happened")
            }

            if let review {
                verdict(review)
                ForEach(Array(review.findings.enumerated()), id: \.offset) { _, finding in
                    Label(finding, systemImage: "chevron.right")
                        .labelStyle(BulletLabelStyle())
                        .font(.callout)
                }
                DisclosureGroup("How the sim replayed it") {
                    simPlayback(review)
                }
                .font(.subheadline)
            } else if coach.reviewedBattleId == battle.id, let message = coach.reviewMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            } else if battle.outcome == nil {
                Text("Mark the game won or lost and the sim will check how it should have gone — or run it now.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private func verdict(_ review: BattleReviewer.Review) -> some View {
        let (title, color): (String, Color)
        switch review.diagnosis {
        case .asExpected?: (title, color) = ("Won", Theme.win)
        case .outplayedSim?: (title, color) = ("Won", Theme.win)
        case .execution?: (title, color) = ("Lost — what to change", Theme.loss)
        case .teamMatchup?: (title, color) = ("Lost — a tough matchup", Theme.loss)
        case nil: (title, color) = ("Review", Color.primary)
        }
        return Text(title).font(.title3.weight(.bold)).foregroundStyle(color)
    }

    @ViewBuilder
    private func simPlayback(_ review: BattleReviewer.Review) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(review.simLine.enumerated()), id: \.offset) { _, line in
                Label(line, systemImage: "arrow.right").font(.callout)
            }
            ForEach(Array(review.simLog.segments.enumerated()), id: \.offset) { _, segment in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(name(battle.team, segment.indexA))  vs  \(name(battle.opponents, segment.indexB))")
                        .font(.subheadline.weight(.semibold))
                    BattleTimelineView(
                        log: segment.log,
                        sideA: participant(battle.team, segment.indexA),
                        sideB: participant(battle.opponents, segment.indexB),
                        move: { store.move(id: $0) }, scenario: segment.shieldScenario)
                }
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(.top, 6)
    }

    private func name(_ members: [TeamMember], _ index: Int) -> String {
        members.indices.contains(index) ? store.name(forSpeciesId: members[index].speciesId) : "?"
    }

    private func participant(_ members: [TeamMember], _ index: Int) -> BattleParticipant {
        guard members.indices.contains(index) else { return BattleParticipant(name: "?", types: []) }
        let member = members[index]
        let species = store.pokemonById[member.speciesId]
        return BattleParticipant(
            name: species?.speciesName ?? member.speciesId, types: species?.displayTypes ?? [],
            shadow: member.shadow, chargedMoveIds: member.chargedMoveIds)
    }
}

/// A bullet with the text hanging beside it.
private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.font(.caption2).foregroundStyle(.secondary)
            configuration.title
        }
    }
}

// MARK: - Insights across games

/// Sim versus reality over every game marked with this team — the answer to
/// "is it me, the team, or the sim?".
struct BattleInsightsPanel: View {
    let history: BattleHistoryStore
    let team: [TeamMember]
    let store: RankingsStore
    /// The league to count games in; the current one unless given.
    var cup: String?
    var cp: Int?

    var body: some View {
        let ids = Set(team.map(\.speciesId))
        let insights = history.insights { battle in
            battle.cup == (cup ?? store.format.cup) && battle.cp == (cp ?? store.format.cp)
                && Set(battle.team.map(\.speciesId)) == ids
        }
        if insights.games > 0 {
            VStack(alignment: .leading, spacing: 6) {
                Text("This team so far").font(.headline)
                Text("You've won \(insights.wins) of \(insights.games) (\(percent(insights.realWinRate))). The sim had you winning \(insights.simPredictedWins) of them (\(percent(insights.simWinRate))).")
                    .font(.callout)
                let losses = insights.games - insights.wins
                if losses > 0 {
                    let execution = insights.diagnoses[.execution, default: 0]
                    let matchup = insights.diagnoses[.teamMatchup, default: 0]
                    Text("Of \(losses) loss\(losses == 1 ? "" : "es"): \(execution) the sim wins as played, \(matchup) the sim loses too.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let verdict = verdict(insights) {
                    Label(verdict, systemImage: "lightbulb").font(.callout)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    /// Needs a few games before it says anything.
    private func verdict(_ insights: BattleInsights) -> String? {
        guard insights.games >= 5 else { return "Mark a few more games for a read on whether it's play, leads or the team." }
        let losses = insights.games - insights.wins
        guard losses > 0 else { return nil }
        let execution = insights.diagnoses[.execution, default: 0]
        let matchup = insights.diagnoses[.teamMatchup, default: 0]
        guard execution + matchup > 0 else { return nil }
        if execution > matchup {
            return "Most losses are games the sim wins: look at shield use, charged moves and swap timing in the reviews."
        }
        if matchup > execution {
            return "Most losses are games the sim loses too: the team or the sim's read of it is the issue, not the play."
        }
        return "Losses split evenly between play and matchup."
    }
}

