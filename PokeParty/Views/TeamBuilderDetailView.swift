//
//  TeamBuilderDetailView.swift
//  PokeParty
//
//  Main panel of the 3v3 Team Builder. Shows the team as up to three editable
//  cards (moveset pickers, reorder, remove, shadow), a league selector for what
//  the team is rated against, and the analysis (grades / threats / suggested
//  teammates) below. Pokémon are added from the palette in the middle column
//  (`TeamBuilderView`).
//

import SwiftUI

struct TeamBuilderDetailView: View {
    @Bindable var store: RankingsStore
    @Bindable var model: TeamBuilderModel
    @State private var showingBattle = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                controlsHeader
                teamEditor
                Divider()
                analysisContent
                AttributionFooter()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Team Builder")
        .onAppear { analyzeIfNeeded() }
        .onChange(of: model.members) { analyzeIfNeeded() }
        // League changes reload the ranking list asynchronously; re-analyze once
        // the new meta has arrived.
        .onChange(of: store.entries) { analyzeIfNeeded() }
        .sheet(isPresented: $showingBattle) {
            TeamBattleView(store: store, model: model)
        }
    }

    private func analyzeIfNeeded() {
        guard model.hasMembers else { return }
        model.analyze(using: store)
    }

    // MARK: - Controls

    private var controlsHeader: some View {
        HStack(spacing: 10) {
            Text("Rated against")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker("League", selection: $store.format) {
                ForEach(RankingFormat.coreLeagues) { Text($0.title).tag($0) }
                if !store.cupFormats.isEmpty {
                    Divider()
                    ForEach(store.cupFormats) { Text($0.title).tag($0) }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            Spacer()
            Button {
                showingBattle = true
            } label: {
                Label("Battle", systemImage: "bolt.fill")
            }
            .disabled(!model.hasMembers)
            .help("Simulate a 3v3 against an opponent team")
            Text("\(model.members.count)/\(TeamBuilderModel.maxMembers)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Team editor

    private var teamEditor: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(0..<TeamBuilderModel.maxMembers, id: \.self) { index in
                if index < model.members.count {
                    TeamMemberCard(index: index, store: store, model: model)
                } else {
                    emptySlot
                }
            }
        }
    }

    private var emptySlot: some View {
        VStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Add from the list")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 150)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                .foregroundStyle(.quaternary)
        )
    }

    // MARK: - Analysis

    @ViewBuilder
    private var analysisContent: some View {
        if let analysis = model.analysis {
            TeamAnalysisSections(
                analysis: analysis,
                onAddSuggestion: model.isFull ? nil : { addSuggestion($0) })
        } else if model.phase == .analyzing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Analyzing team…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        } else if !model.hasMembers {
            ContentUnavailableView(
                "Build a Team",
                systemImage: "person.3.sequence.fill",
                description: Text("Add up to three Pokémon from the list to see coverage, bulk, threats and suggested teammates for \(store.format.title)."))
            .frame(maxWidth: .infinity, minHeight: 200)
        }
    }

    private func addSuggestion(_ speciesId: String) {
        if let member = model.makeMember(speciesId: speciesId, store: store) {
            model.add(member)
        }
    }
}

// MARK: - Team member card

private struct TeamMemberCard: View {
    let index: Int
    let store: RankingsStore
    @Bindable var model: TeamBuilderModel

    private var member: TeamMember? {
        model.members.indices.contains(index) ? model.members[index] : nil
    }
    private var species: Pokemon? {
        member.flatMap { store.pokemonById[$0.speciesId] }
    }
    private var recommended: [String] {
        member.flatMap { store.entry(id: $0.speciesId)?.moveset } ?? []
    }

    var body: some View {
        if let member, let species {
            VStack(alignment: .leading, spacing: 8) {
                header(member: member, species: species)
                TypeBadgeRow(types: species.displayTypes)
                reorderControls
                Divider()
                movesetEditor(member: member, species: species)
                if species.isShadow || member.shadow {
                    shadowToggle(member: member)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func header(member: TeamMember, species: Pokemon) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(slotLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text(species.speciesName)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if member.shadow { ShadowBadge() }
                }
            }
            Spacer()
            Button {
                model.remove(at: index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove from team")
        }
    }

    private var slotLabel: String {
        switch index {
        case 0: return "LEAD"
        default: return "#\(index + 1)"
        }
    }

    @ViewBuilder
    private var reorderControls: some View {
        if model.members.count > 1 {
            HStack(spacing: 6) {
                Button { model.move(from: index, to: index - 1) } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(index == 0)
                Button { model.move(from: index, to: index + 1) } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(index >= model.members.count - 1)
                Spacer()
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .help("Reorder")
        }
    }

    private func movesetEditor(member: TeamMember, species: Pokemon) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TeamMovePicker(
                label: "Fast",
                currentId: member.fastMoveId,
                optionIds: species.fastMoves,
                recommendedId: recommended.first,
                includesNone: false,
                store: store,
                onSelect: { if let id = $0 { model.setFastMove(id, at: index) } })
            TeamMovePicker(
                label: "Charged 1",
                currentId: member.chargedMoveIds.first ?? "",
                optionIds: species.chargedMoves,
                recommendedId: recommended.count > 1 ? recommended[1] : nil,
                includesNone: false,
                store: store,
                onSelect: { if let id = $0 { model.setChargedMove(id, slot: 0, at: index) } })
            TeamMovePicker(
                label: "Charged 2",
                currentId: member.chargedMoveIds.count > 1 ? member.chargedMoveIds[1] : "",
                optionIds: species.chargedMoves,
                recommendedId: recommended.count > 2 ? recommended[2] : nil,
                includesNone: true,
                store: store,
                onSelect: { model.setChargedMove($0, slot: 1, at: index) })
        }
    }

    private func shadowToggle(member: TeamMember) -> some View {
        Toggle("Shadow", isOn: Binding(
            get: { member.shadow },
            set: { model.setShadow($0, at: index) }))
        .toggleStyle(.switch)
        .controlSize(.mini)
        .font(.caption)
    }
}

// MARK: - Move picker

/// A compact menu to pick a move for a team slot, showing the current move's
/// name + type. Mirrors `PokemonDetailView`'s picker but sized for the cards.
private struct TeamMovePicker: View {
    let label: String
    let currentId: String            // "" == none
    let optionIds: [String]
    let recommendedId: String?
    let includesNone: Bool
    let store: RankingsStore
    /// nil argument means "None" was chosen (second charged slot only).
    let onSelect: (String?) -> Void

    private var move: Move? { store.move(id: currentId) }

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Menu {
                if includesNone {
                    button(id: nil, label: "None")
                }
                ForEach(optionIds, id: \.self) { id in
                    button(id: id, label: optionLabel(id))
                }
            } label: {
                HStack(spacing: 5) {
                    Text(move?.name ?? "None")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let move { TypeBadge(type: move.type) }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func button(id: String?, label: String) -> some View {
        Button {
            onSelect(id)
        } label: {
            if (id ?? "") == currentId {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    private func optionLabel(_ id: String) -> String {
        guard let m = store.move(id: id) else { return id }
        var name = m.name
        if id == recommendedId { name += " (Recommended)" }
        return name
    }
}
