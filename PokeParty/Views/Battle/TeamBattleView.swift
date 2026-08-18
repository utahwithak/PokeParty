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

    private var opponentResults: [Pokemon] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return store.allPokemon.filter { p in
            if model.opponentContains(speciesId: p.speciesId) { return false }
            guard !query.isEmpty else { return true }
            return p.speciesName.localizedCaseInsensitiveContains(query)
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

    private func teamColumn(title: String, members: [TeamMember], opponent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                if opponent, !savedTeams.teams.isEmpty {
                    Spacer()
                    Menu("Load Saved") {
                        ForEach(savedTeams.teams) { team in
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

            // Bench Pokémon not already on the opponent team
            let benchAvailable = bench.entries.filter {
                !model.opponentContains(speciesId: $0.speciesId)
            }
            if !benchAvailable.isEmpty && search.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("From your bench")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(benchAvailable) { entry in
                        Button {
                            model.addOpponent(entry.asTeamMember())
                        } label: {
                            HStack(spacing: 8) {
                                let name = store.pokemonById[entry.speciesId]?.speciesName ?? entry.speciesId
                                Text(entry.nickname.isEmpty ? name : entry.nickname)
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                TypeBadgeRow(types: store.pokemonById[entry.speciesId]?.displayTypes ?? [])
                            }
                            .padding(6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            TextField("Search Pokémon", text: $search)
                .textFieldStyle(.roundedBorder)
            VStack(spacing: 4) {
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
                ForEach(Array(log.segments.enumerated()), id: \.offset) { _, segment in
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
