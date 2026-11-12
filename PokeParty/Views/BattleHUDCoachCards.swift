//
//  BattleHUDCoachCards.swift
//  PokeParty
//
//  Coach cards shown in the Battle HUD (tempo and the inputs panel). The coach's advice itself
//  is written into the battle log (see `CoachNarrator`).
//

import SwiftUI

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
                .help("Show the shields, to correct them by hand")
                if showManual { shieldRow }
                // Always in reach: the screen's faint banner can be read late or against the
                // wrong Pokémon, and a wrong faint skews the whole call.
                whoIsOut
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

    private var shieldRow: some View {
        HStack(spacing: 24) {
            shieldPicker("Your shields", selection: $coach.inputs.myShields)
            shieldPicker("Their shields", selection: $coach.inputs.opponentShields)
            Spacer()
        }
    }

    /// Both sides' Pokémon: tap one to make it the one on the field; the ✕ beside it
    /// marks it fainted (↩ puts it back).
    @ViewBuilder
    private var whoIsOut: some View {
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
    }

    private var inputs: some View {
        VStack(alignment: .leading, spacing: 12) {
            shieldRow
            whoIsOut
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

    /// Tap to make this Pokémon the active one; the ✕ (or the context menu) marks it fainted.
    private func myChip(index: Int, member: TeamMember) -> some View {
        let fainted = coach.inputs.fainted.contains(index)
        return chip(store.name(forSpeciesId: member.speciesId),
                    selected: coach.inputs.myActive == index && !fainted, fainted: fainted,
                    select: { if !fainted { coach.inputs.myActive = index } },
                    toggleFainted: {
                        if fainted { coach.inputs.fainted.remove(index) } else { coach.inputs.fainted.insert(index) }
                    })
    }

    /// Tap to make this the opponent on the field; the ✕ (or the context menu) marks it fainted.
    private func theirChip(index: Int, member: TeamMember) -> some View {
        let fainted = coach.inputs.opponentFainted.contains(index)
        return chip(store.name(forSpeciesId: member.speciesId),
                    selected: coach.inputs.opponentActive == index && !fainted, fainted: fainted,
                    select: { if !fainted { coach.inputs.opponentActive = index } },
                    toggleFainted: {
                        if fainted { coach.inputs.opponentFainted.remove(index) } else { coach.inputs.opponentFainted.insert(index) }
                    })
    }

    /// A Pokémon's chip: the name selects it, the button beside it flips its fainted mark.
    private func chip(_ title: String, selected: Bool, fainted: Bool,
                      select: @escaping () -> Void, toggleFainted: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Button(action: select) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .strikethrough(fainted)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            Button(action: toggleFainted) {
                Image(systemName: fainted ? "arrow.uturn.backward.circle.fill" : "xmark.circle")
                    .foregroundStyle(fainted ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(fainted ? "Mark \(title) alive again" : "Mark \(title) fainted")
        }
        .padding(.leading, 10).padding(.trailing, 7)
        .padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.07), in: Capsule())
        .overlay(Capsule().stroke(selected ? Color.accentColor : .clear, lineWidth: 1.5))
        .opacity(fainted ? 0.55 : 1)
        .contextMenu {
            Button(fainted ? "Mark alive" : "Mark fainted", action: toggleFainted)
        }
    }
}
