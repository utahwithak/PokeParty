//
//  MatchupDetailView.swift
//  PokeParty
//
//  Main panel of the 1v1 Simulator: two editable combatant cards (moveset,
//  shadow, shields), a 3×3 grid of shield scenarios — each solved with
//  game-optimal shield timing for both sides — and the scrubbable timeline for
//  the selected scenario. Pokémon are added from the palette in the middle
//  column (`MatchupSimulatorView`).
//

import SwiftUI

struct MatchupDetailView: View {
    @Bindable var store: RankingsStore
    @Bindable var model: MatchupModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                controlsHeader
                combatantsRow
                Divider()
                resultsContent
                AttributionFooter()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("1v1 Simulator")
        .onAppear { model.simulate(using: store) }
        .onChange(of: model.memberA) { model.simulate(using: store) }
        .onChange(of: model.memberB) { model.simulate(using: store) }
        // League changes reload the ranking data (and CP cap) asynchronously;
        // re-simulate once the new data has arrived.
        .onChange(of: store.entries) { model.simulate(using: store) }
    }

    // MARK: - Controls

    private var controlsHeader: some View {
        HStack(spacing: 10) {
            Text("Simulated at")
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
            if model.isSimulating {
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: - Combatants

    private var combatantsRow: some View {
        HStack(alignment: .top, spacing: 12) {
            MatchupMemberCard(side: .a, store: store, model: model)
            Text("vs")
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.top, 60)
            MatchupMemberCard(side: .b, store: store, model: model)
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsContent: some View {
        if let results = model.results {
            shieldGrid(results)
            if let current = model.current {
                timelineSection(current)
            }
        } else if model.isSimulating {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Simulating shield scenarios…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        } else if !model.hasBothSides {
            ContentUnavailableView(
                "Pick Two Pokémon",
                systemImage: "bolt.horizontal.fill",
                description: Text("Choose a Pokémon for each side from the list to simulate the 1v1 with every shield scenario for \(store.format.title)."))
            .frame(maxWidth: .infinity, minHeight: 200)
        }
    }

    // MARK: - Shield scenario grid

    private func shieldGrid(_ results: MatchupModel.Results) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shield Scenarios")
                .font(.title3.weight(.semibold))
            Text("\(name(.a))'s battle rating when both sides shield with optimal timing. Rows: \(name(.a))'s shields · columns: \(name(.b))'s. Tap a scenario to inspect it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    Color.clear
                        .gridCellUnsizedAxes([.horizontal, .vertical])
                    ForEach(0..<3, id: \.self) { shieldsB in
                        Label("\(shieldsB)", systemImage: "shield.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(0..<3, id: \.self) { shieldsA in
                    GridRow {
                        Label("\(shieldsA)", systemImage: "shield.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(0..<3, id: \.self) { shieldsB in
                            scenarioCell(rating: results.solutions[shieldsA][shieldsB].ratingA,
                                         shieldsA: shieldsA, shieldsB: shieldsB)
                        }
                    }
                }
            }
        }
    }

    private func scenarioCell(rating: Int, shieldsA: Int, shieldsB: Int) -> some View {
        let selected = shieldsA == model.shieldsA && shieldsB == model.shieldsB
        let color = ratingColor(rating)
        return Button {
            model.shieldsA = shieldsA
            model.shieldsB = shieldsB
        } label: {
            Text("\(rating)")
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
                .frame(width: 64, height: 34)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .help("\(name(.a)) with \(shieldsA) shield(s) vs \(name(.b)) with \(shieldsB)")
    }

    private func ratingColor(_ rating: Int) -> Color {
        if rating > 500 { return Theme.win }
        if rating < 500 { return Theme.loss }
        return .secondary
    }

    // MARK: - Timeline

    private func timelineSection(_ current: (solution: ShieldSearch.Solution, log: BattleLog)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(name(.a))  vs  \(name(.b)) — \(model.shieldsA) vs \(model.shieldsB) shields")
                .font(.subheadline.weight(.semibold))
            Text(policySummary(current.solution))
                .font(.caption)
                .foregroundStyle(.secondary)
            BattleTimelineView(
                log: current.log,
                sideA: participant(.a), sideB: participant(.b),
                move: { store.move(id: $0) },
                scenario: current.solution)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        // Reset the timeline scrubber whenever a different battle is shown.
        .id(current.log)
    }

    /// Human-readable optimal shield timing for both sides.
    private func policySummary(_ s: ShieldSearch.Solution) -> String {
        "Optimal timing — \(policyText(s.policyA, name: name(.a))) · \(policyText(s.policyB, name: name(.b)))"
    }

    private func policyText(_ policy: Set<Int>, name: String) -> String {
        guard !policy.isEmpty else { return "\(name) doesn't shield" }
        let list = policy.sorted().map { ordinal($0 + 1) }.joined(separator: " and ")
        return "\(name) shields the \(list) charged move faced"
    }

    private func ordinal(_ n: Int) -> String {
        switch n {
        case 1: return "1st"
        case 2: return "2nd"
        case 3: return "3rd"
        default: return "\(n)th"
        }
    }

    // MARK: - Helpers

    private func name(_ side: MatchupModel.Side) -> String {
        guard let member = model.member(for: side) else { return side == .a ? "Side A" : "Side B" }
        return store.pokemonById[member.speciesId]?.speciesName ?? member.speciesId
    }

    private func participant(_ side: MatchupModel.Side) -> BattleParticipant {
        guard let member = model.member(for: side) else {
            return BattleParticipant(name: "?", types: [])
        }
        let species = store.pokemonById[member.speciesId]
        return BattleParticipant(
            name: species?.speciesName ?? member.speciesId,
            types: species?.displayTypes ?? [],
            shadow: member.shadow)
    }
}

// MARK: - Combatant card

private struct MatchupMemberCard: View {
    let side: MatchupModel.Side
    let store: RankingsStore
    @Bindable var model: MatchupModel

    private var member: TeamMember? { model.member(for: side) }
    private var species: Pokemon? {
        member.flatMap { store.pokemonById[$0.speciesId] }
    }
    private var recommended: [String] {
        member.flatMap { store.entry(id: $0.speciesId)?.moveset } ?? []
    }
    /// Matches the timeline's lane colors (side A blue, side B orange).
    private var accent: Color { side == .a ? .blue : .orange }

    var body: some View {
        if let member, let species {
            VStack(alignment: .leading, spacing: 8) {
                header(member: member, species: species)
                TypeBadgeRow(types: species.displayTypes)
                Divider()
                movesetEditor(member: member, species: species)
                if species.isShadow || member.shadow {
                    shadowToggle(member: member)
                }
                Divider()
                shieldPicker
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        } else {
            emptySlot
        }
    }

    private func header(member: TeamMember, species: Pokemon) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                sideLabel
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
                model.set(nil, side: side)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear this side")
        }
    }

    private var sideLabel: some View {
        HStack(spacing: 5) {
            Circle().fill(accent).frame(width: 8, height: 8)
            Text(side == .a ? "SIDE A" : "SIDE B")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
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
                species: species,
                store: store,
                onSelect: { if let id = $0 { model.setFastMove(id, side: side) } })
            TeamMovePicker(
                label: "Charged 1",
                currentId: member.chargedMoveIds.first ?? "",
                optionIds: species.chargedMoves,
                recommendedId: recommended.count > 1 ? recommended[1] : nil,
                includesNone: false,
                species: species,
                store: store,
                onSelect: { if let id = $0 { model.setChargedMove(id, slot: 0, side: side) } })
            TeamMovePicker(
                label: "Charged 2",
                currentId: member.chargedMoveIds.count > 1 ? member.chargedMoveIds[1] : "",
                optionIds: species.chargedMoves,
                recommendedId: recommended.count > 2 ? recommended[2] : nil,
                includesNone: true,
                species: species,
                store: store,
                onSelect: { model.setChargedMove($0, slot: 1, side: side) })
        }
    }

    private func shadowToggle(member: TeamMember) -> some View {
        Toggle("Shadow", isOn: Binding(
            get: { member.shadow },
            set: { model.setShadow($0, side: side) }))
        .toggleStyle(.switch)
        .controlSize(.mini)
        .font(.caption)
    }

    private var shieldPicker: some View {
        HStack(spacing: 6) {
            Text("Shields")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Picker("Shields", selection: side == .a ? $model.shieldsA : $model.shieldsB) {
                ForEach(0..<3, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
    }

    private var emptySlot: some View {
        VStack(spacing: 6) {
            sideLabel
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
}
