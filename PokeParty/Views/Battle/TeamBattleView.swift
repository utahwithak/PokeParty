//
//  TeamBattleView.swift
//  PokeParty
//
//  Head-to-head 3v3 battle (plan M7.5). Your team (from the Team Builder) fights a
//  chosen opponent team; runs the recorded `ThreeVThreeBattle` and shows the result
//  plus each 1v1 segment as a `BattleTimelineView`.
//

import SwiftUI

struct TeamBattleView: View {
    var store: RankingsStore
    @Bindable var model: TeamBuilderModel
    var savedTeams: SavedTeamsStore
    var bench: BenchStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var opponentSource: OpponentSource = .all

    private enum OpponentSource: String, CaseIterable, Identifiable {
        case all = "All", bench = "Bench"
        var id: String { rawValue }
    }

    private var opponentResults: [Pokemon] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return store.eligiblePokemon(for: store.format).filter { p in
            if model.opponentContains(speciesId: p.speciesId) { return false }
            guard !query.isEmpty else { return true }
            return p.speciesName.localizedCaseInsensitiveContains(query)
        }
    }

    private var benchOpponentResults: [BenchEntry] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return bench.entries.filter { entry in
            if model.opponentContains(speciesId: entry.speciesId) { return false }
            guard !query.isEmpty else { return true }
            let name = store.pokemonById[entry.speciesId]?.speciesName ?? entry.speciesId
            return name.localizedCaseInsensitiveContains(query)
                || entry.nickname.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    teamsHeader
                    if !model.opponentIsFull { opponentPicker }
                    battleControls
                    resultsSection
                }
                .padding(20)
            }
            .navigationTitle("3v3 Battle")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 640)
        #endif
    }

    // MARK: - Teams

    private var teamsHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            teamColumn(title: "Your Team", members: model.members, opponent: false)
            Text("vs").font(.headline).foregroundStyle(.secondary).padding(.top, 28)
            teamColumn(title: "Opponent", members: model.opponentMembers, opponent: true)
        }
    }

    private var savedTeamsForCurrentFormat: [Team] {
        savedTeams.teams(for: store.format)
    }

    private func teamColumn(title: String, members: [TeamMember], opponent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                if opponent, !savedTeamsForCurrentFormat.isEmpty {
                    Spacer()
                    Menu("Load Saved") {
                        ForEach(savedTeamsForCurrentFormat) { team in
                            Button(team.name) { model.setOpponentTeam(team.members) }
                        }
                    }
                    .fixedSize()
                    .font(.caption)
                    .help("Use a saved team as the opponent")
                }
            }
            if members.isEmpty {
                Text(opponent ? "Add three below" : "Build a team first")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
                memberChip(member, isLead: index == 0, removable: opponent) { model.removeOpponent(at: index) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func memberChip(_ member: TeamMember, isLead: Bool, removable: Bool, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            if isLead {
                Text("LEAD")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(Color.accentColor, in: Capsule())
            }
            Text(species(member)?.speciesName ?? member.speciesId)
                .font(.subheadline.weight(.medium)).lineLimit(1)
            if member.shadow { ShadowBadge() }
            Spacer(minLength: 4)
            TypeBadgeRow(types: species(member)?.displayTypes ?? [])
            if removable {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Opponent picker

    private var opponentPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add opponent (\(model.opponentMembers.count)/\(TeamBuilderModel.maxMembers))")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)

            if !bench.entries.isEmpty {
                Picker("Source", selection: $opponentSource) {
                    ForEach(OpponentSource.allCases) { source in
                        Text(source.rawValue).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            TextField("Search Pokémon", text: $search)
                .textFieldStyle(.roundedBorder)

            VStack(spacing: 4) {
                if opponentSource == .bench {
                    if benchOpponentResults.isEmpty {
                        Text("No matching bench Pokémon").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(benchOpponentResults) { entry in
                            Button {
                                model.addOpponent(entry.asTeamMember())
                            } label: {
                                HStack(spacing: 8) {
                                    let name = store.pokemonById[entry.speciesId]?.speciesName ?? entry.speciesId
                                    Text(entry.nickname.isEmpty ? name : entry.nickname)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                    Spacer()
                                    TypeBadgeRow(types: store.pokemonById[entry.speciesId]?.displayTypes ?? [])
                                }
                                .padding(6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    ForEach(opponentResults.prefix(12)) { pokemon in
                        Button {
                            if let m = model.makeMember(speciesId: pokemon.speciesId, store: store) {
                                model.addOpponent(m)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Text(pokemon.speciesName).font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Spacer()
                                TypeBadgeRow(types: pokemon.displayTypes)
                            }
                            .padding(6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Battle controls

    private var battleControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    model.runTeamBattle(using: store)
                } label: {
                    Label("Simulate Battle", systemImage: "bolt.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.hasMembers || model.opponentMembers.isEmpty || model.isBattling)

                if model.isBattling {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            HStack(spacing: 16) {
                Toggle("Your team baits shields", isOn: $model.yourTeamBaits)
                Toggle("Opponent baits shields", isOn: $model.opponentBaits)
            }
            .checkboxToggleStyle()
            .font(.caption)
            .disabled(model.isBattling)
            .help("Baiting throws cheap charged moves to draw shields before the big one. Turn off to always throw the best move.")
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsSection: some View {
        if let log = model.battleLog {
            VStack(alignment: .leading, spacing: 14) {
                outcomeHeader(log.result)
                ForEach(Array(log.segments.enumerated()), id: \.offset) { index, segment in
                    switchDivider(index == 0
                                  ? leadSwapTransitions(log)
                                  : switchTransitions(from: log.segments[index - 1], to: segment))
                    segmentView(segment)
                }
            }
        }
    }

    private func outcomeHeader(_ result: TeamBattleResult) -> some View {
        let title: String
        switch result.winner {
        case .teamA: title = "Your team wins"
        case .teamB: title = "Opponent wins"
        case .tie: title = "Tie"
        }
        let color: Color = result.winner == .teamA ? Theme.win : (result.winner == .teamB ? Theme.loss : .secondary)
        return HStack {
            Text(title).font(.title3.weight(.bold)).foregroundStyle(color)
            Spacer()
            Text("Survivors \(result.survivorsA)–\(result.survivorsB)")
                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            if result.timedOut {
                Text("· timed out").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func segmentView(_ segment: TeamBattleLog.Segment) -> some View {
        let a = participant(model.members, index: segment.indexA)
        let b = participant(model.opponentMembers, index: segment.indexB)
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(a.name)  vs  \(b.name)")
                .font(.subheadline.weight(.semibold))
            BattleTimelineView(log: segment.log, sideA: a, sideB: b,
                               move: { store.move(id: $0) }, scenario: segment.shieldScenario)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Switch section

    private enum SwitchCause { case fainted, voluntary }

    private struct SwitchTransition: Identifiable {
        let id: Int   // side (0 or 1) — at most one transition per side per boundary
        let outName: String
        let inName: String
        let cause: SwitchCause
        /// Energy the opponent banked for free while this side spent its turn
        /// switching. Always 0 for `.fainted` (a faint doesn't cost extra tempo).
        let tempoEnergy: Int
        /// Damage those same free fast moves dealt to the Pokémon switching in.
        let tempoDamage: Int
        let opponentName: String
    }

    /// The switches (if any) that happened between two consecutive segments —
    /// a side's active Pokémon differs either because it fainted or because it
    /// voluntarily switched, which (unlike a faint) spends a turn and lets the
    /// opponent bank free energy and free damage.
    private func switchTransitions(from previous: TeamBattleLog.Segment, to current: TeamBattleLog.Segment) -> [SwitchTransition] {
        var out: [SwitchTransition] = []
        if current.indexA != previous.indexA {
            let cause: SwitchCause = previous.log.hpA <= 0 ? .fainted : .voluntary
            let voluntary = current.voluntarySwitchSide == 0
            out.append(SwitchTransition(
                id: 0,
                outName: participant(model.members, index: previous.indexA).name,
                inName: participant(model.members, index: current.indexA).name,
                cause: cause,
                tempoEnergy: voluntary ? current.switchTempoEnergy : 0,
                tempoDamage: voluntary ? current.switchTempoDamage : 0,
                opponentName: participant(model.opponentMembers, index: current.indexB).name))
        }
        if current.indexB != previous.indexB {
            let cause: SwitchCause = previous.log.hpB <= 0 ? .fainted : .voluntary
            let voluntary = current.voluntarySwitchSide == 1
            out.append(SwitchTransition(
                id: 1,
                outName: participant(model.opponentMembers, index: previous.indexB).name,
                inName: participant(model.opponentMembers, index: current.indexB).name,
                cause: cause,
                tempoEnergy: voluntary ? current.switchTempoEnergy : 0,
                tempoDamage: voluntary ? current.switchTempoDamage : 0,
                opponentName: participant(model.members, index: current.indexA).name))
        }
        return out
    }

    /// The switches (if any) that happened before the very first segment: a
    /// turn-0 safe-swap can move either side off its configured lead before any
    /// battle plays out, so the first segment shown may not be lead-vs-lead.
    private func leadSwapTransitions(_ log: TeamBattleLog) -> [SwitchTransition] {
        guard let first = log.segments.first else { return [] }
        let leadA = log.result.entrancesA.first ?? first.indexA
        let leadB = log.result.entrancesB.first ?? first.indexB
        var out: [SwitchTransition] = []
        if first.indexA != leadA {
            let voluntary = first.voluntarySwitchSide == 0
            out.append(SwitchTransition(
                id: 0,
                outName: participant(model.members, index: leadA).name,
                inName: participant(model.members, index: first.indexA).name,
                cause: .voluntary,
                tempoEnergy: voluntary ? first.switchTempoEnergy : 0,
                tempoDamage: voluntary ? first.switchTempoDamage : 0,
                opponentName: participant(model.opponentMembers, index: first.indexB).name))
        }
        if first.indexB != leadB {
            let voluntary = first.voluntarySwitchSide == 1
            out.append(SwitchTransition(
                id: 1,
                outName: participant(model.opponentMembers, index: leadB).name,
                inName: participant(model.opponentMembers, index: first.indexB).name,
                cause: .voluntary,
                tempoEnergy: voluntary ? first.switchTempoEnergy : 0,
                tempoDamage: voluntary ? first.switchTempoDamage : 0,
                opponentName: participant(model.members, index: first.indexA).name))
        }
        return out
    }

    @ViewBuilder
    private func switchDivider(_ transitions: [SwitchTransition]) -> some View {
        if !transitions.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(transitions) { switchRow($0) }
            }
        }
    }

    private func switchRow(_ t: SwitchTransition) -> some View {
        let color: Color = t.id == 0 ? .blue : .orange
        return HStack(spacing: 8) {
            Image(systemName: "arrow.left.arrow.right.circle.fill")
                .foregroundStyle(color)
            Text(t.cause == .fainted
                 ? "\(t.outName) fainted — \(t.inName) in"
                 : "\(t.outName) switched out for \(t.inName)")
                .font(.caption.weight(.medium))
            if t.cause == .voluntary, t.tempoEnergy > 0 {
                Spacer(minLength: 4)
                tempoBar(t.tempoEnergy)
                Text("\(t.opponentName) gets +\(t.tempoEnergy) energy and hits \(t.inName) for \(t.tempoDamage)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.loss)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        .help("Switching spends this side's whole turn — the opponent's Pokémon stays on the field and gets free energy and damage in while the new one comes in.")
    }

    private func tempoBar(_ energy: Int) -> some View {
        Capsule()
            .fill(Color.primary.opacity(0.08))
            .overlay(alignment: .leading) {
                Capsule().fill(Theme.loss)
                    .scaleEffect(x: Double(energy) / 100.0, y: 1, anchor: .leading)
            }
            .frame(width: 36, height: 5)
    }

    // MARK: - Helpers

    private func species(_ member: TeamMember) -> Pokemon? {
        store.pokemonById[member.speciesId]
    }

    private func participant(_ members: [TeamMember], index: Int) -> BattleParticipant {
        guard members.indices.contains(index) else {
            return BattleParticipant(name: "?", types: [])
        }
        let member = members[index]
        let p = store.pokemonById[member.speciesId]
        return BattleParticipant(
            name: p?.speciesName ?? member.speciesId,
            types: p?.displayTypes ?? [],
            shadow: member.shadow,
            chargedMoveIds: member.chargedMoveIds)
    }
}
