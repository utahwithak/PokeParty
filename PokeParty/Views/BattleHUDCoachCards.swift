//
//  BattleHUDCoachCards.swift
//  PokeParty
//
//  Coach cards shown in the Battle HUD (shield plan, tempo, lead, bait, mid-game, back line, inputs).
//

import SwiftUI

/// The shield call for each charged move their Pokémon might throw, shown before
/// any of them goes off so the decision is already made when the banner appears.
struct ShieldPlanCard: View {
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
struct TempoCard: View {
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
struct LeadPlanCard: View {
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
struct BaitCallView: View {
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
struct MidGameCard: View {
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

/// Why the banner says what it does: every option's win chance and how much of
/// your team it leaves standing. When win chances tie, the HP column is the reason.
struct CoachOptionsCard: View {
    let coach: BattleCoachModel

    var body: some View {
        if let advice = coach.advice, advice.options.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                Text("Why this call")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(advice.options, id: \.pokemonIndex) { option in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(option.pokemonName).font(.body.weight(.medium))
                        Text(option.action == .stay ? "stay" : "switch")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("wins \(Int((option.winRate * 100).rounded()))%")
                            .font(.body.monospacedDigit())
                        Text("HP left \(Int((option.averageRating / 10).rounded()))")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .fontWeight(option.action == advice.recommended.action ? .semibold : .regular)
                }
                if tiedOnWinRate(advice) {
                    Text("Win chances are level, so the call goes to the option that finishes with more of your team's HP.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    /// The recommended option and staying in win equally often, to the shown percent.
    private func tiedOnWinRate(_ advice: BattleCoach.Advice) -> Bool {
        guard advice.recommended.action != .stay,
              let stay = advice.options.first(where: { $0.action == .stay }) else { return false }
        return Int((advice.recommended.winRate * 100).rounded()) == Int((stay.winRate * 100).rounded())
    }
}

/// Who the opponent probably has in the back, from what they've shown and what
/// the meta pairs with it.
struct BackLineCard: View {
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
struct CoachInputsPanel: View {
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
