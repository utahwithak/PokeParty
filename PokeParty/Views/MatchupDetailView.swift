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
            scenarioStack(results)
            let sol = results.solutions[model.shieldsA][model.shieldsB]
            if sol.scenarios.count > 1 {
                subScenarioSection(sol)
            }
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
        let aAbbr = String(name(.a).prefix(1)) + "."
        return VStack(alignment: .leading, spacing: 8) {
            Text("Shield Scenarios")
                .font(.title3.weight(.semibold))
            Text("Tap any cell to inspect that battle. Rows = \(name(.a)) shields · columns = \(name(.b)) shields.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                // Side B name spanning all 3 data columns
                GridRow {
                    Color.clear
                        .gridCellUnsizedAxes([.horizontal, .vertical])
                    Text(name(.b))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .gridCellColumns(3)
                }
                // Shield-count column headers for side B
                GridRow {
                    Color.clear
                        .gridCellUnsizedAxes([.horizontal, .vertical])
                    ForEach(0..<3, id: \.self) { shieldsB in
                        Label("\(shieldsB)", systemImage: "shield.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                // Data rows — row label uses first-initial abbreviation (e.g. "L. 0")
                ForEach(0..<3, id: \.self) { shieldsA in
                    GridRow {
                        Label("\(aAbbr) \(shieldsA)", systemImage: "shield.fill")
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
        let icon = rating > 500 ? "circle" : rating < 500 ? "xmark" : "minus"
        return Button {
            model.shieldsA = shieldsA
            model.shieldsB = shieldsB
        } label: {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                Text("\(rating)")
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
            .foregroundStyle(color)
            .frame(width: 64, height: 44)
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

    // MARK: - Scenario stack (all 9 scenarios with mini timelines)

    private func scenarioStack(_ results: MatchupModel.Results) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Battle Timelines")
                .font(.title3.weight(.semibold))
            VStack(spacing: 0) {
                ForEach(0..<9, id: \.self) { i in
                    let sA = i / 3, sB = i % 3
                    ScenarioStripRow(
                        shieldsA: sA, shieldsB: sB,
                        solution: results.solutions[sA][sB],
                        log: results.logs[sA][sB],
                        selected: sA == model.shieldsA && sB == model.shieldsB,
                        onSelect: { model.shieldsA = sA; model.shieldsB = sB },
                        isLast: i == 8
                    )
                }
            }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Shield-timing sub-scenarios

    private func subScenarioSection(_ sol: ShieldSearch.Solution) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shield Timing Plays")
                .font(.title3.weight(.semibold))
            Text("How each timing choice plays out at \(model.shieldsA) vs \(model.shieldsB) shields — tap a row to watch that battle.")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(sol.scenarios.enumerated()), id: \.offset) { idx, item in
                    subScenarioRow(item, optimal: sol, isLast: idx == sol.scenarios.count - 1)
                }
            }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func subScenarioRow(
        _ item: ShieldSearch.ScenarioItem,
        optimal sol: ShieldSearch.Solution,
        isLast: Bool
    ) -> some View {
        let isOptimal = item.policyA == sol.policyA && item.policyB == sol.policyB
        let isSelected: Bool = {
            if let sub = model.selectedSubScenario {
                return sub.policyA == item.policyA && sub.policyB == item.policyB
            }
            return isOptimal  // no selection → optimal row is "active"
        }()
        let color = ratingColor(item.ratingA)
        let icon = item.ratingA > 500 ? "circle" : item.ratingA < 500 ? "xmark" : "minus"

        return VStack(spacing: 0) {
            Button {
                if isSelected && model.selectedSubScenario != nil {
                    model.clearSubScenario()
                } else if !isOptimal || model.selectedSubScenario != nil {
                    model.selectSubScenario(item, using: store)
                }
            } label: {
                HStack(spacing: 10) {
                    HStack(spacing: 3) {
                        Image(systemName: icon)
                            .font(.system(size: 9, weight: .bold))
                        Text("\(item.ratingA)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                    }
                    .foregroundStyle(color)
                    .frame(width: 48, alignment: .leading)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(policyText(item.policyA, name: name(.a)))
                            .font(.caption2)
                            .foregroundStyle(.primary)
                        Text(policyText(item.policyB, name: name(.b)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if isOptimal {
                        Text("Optimal")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(isSelected ? Color.accentColor.opacity(0.12) : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isLast { Divider().padding(.leading, 10) }
        }
    }

    // MARK: - Timeline

    private func timelineSection(_ current: (solution: ShieldSearch.Solution, log: BattleLog)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(name(.a))  vs  \(name(.b)) — \(model.shieldsA) vs \(model.shieldsB) shields")
                .font(.subheadline.weight(.semibold))
            Text(effectivePolicySummary(optimal: current.solution))
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

    /// Policy summary line: uses the selected sub-scenario's timing when active,
    /// otherwise the optimal timing from the solution.
    private func effectivePolicySummary(optimal s: ShieldSearch.Solution) -> String {
        if let sub = model.selectedSubScenario {
            return "Selected timing — \(policyText(sub.policyA, name: name(.a))) · \(policyText(sub.policyB, name: name(.b)))"
        }
        return "Optimal timing — \(policyText(s.policyA, name: name(.a))) · \(policyText(s.policyB, name: name(.b)))"
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
            shadow: member.shadow,
            chargedMoveIds: member.chargedMoveIds)
    }
}

// MARK: - Scenario strip row

private struct ScenarioStripRow: View {
    let shieldsA: Int
    let shieldsB: Int
    let solution: ShieldSearch.Solution
    let log: BattleLog
    let selected: Bool
    let onSelect: () -> Void
    let isLast: Bool

    private var rating: Int { solution.ratingA }
    private var color: Color { rating > 500 ? Theme.win : rating < 500 ? Theme.loss : .secondary }
    private var icon: String { rating > 500 ? "circle" : rating < 500 ? "xmark" : "minus" }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    // Shield counts — blue for A, orange for B
                    HStack(spacing: 4) {
                        Label("\(shieldsA)", systemImage: "shield.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue)
                        Text("/")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                        Label("\(shieldsB)", systemImage: "shield.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    .frame(width: 68)

                    // Win/loss icon + rating
                    HStack(spacing: 3) {
                        Image(systemName: icon)
                            .font(.system(size: 9, weight: .bold))
                        Text("\(rating)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                    }
                    .foregroundStyle(color)
                    .frame(width: 44, alignment: .leading)

                    // Mini timeline strips: one lane per Pokémon
                    VStack(spacing: 3) {
                        MiniTimelineStrip(log: log, side: 0, color: .blue)
                        MiniTimelineStrip(log: log, side: 1, color: .orange)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(selected ? Color.accentColor.opacity(0.12) : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !isLast {
                Divider().padding(.leading, 10)
            }
        }
    }
}

// MARK: - Mini timeline strip (Canvas-drawn, one lane)

private struct MiniTimelineStrip: View {
    let log: BattleLog
    let side: Int
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            let maxTime = Double(max(log.frames.last?.timeMs ?? 1, 1))

            // Background track
            var track = Path()
            track.addRoundedRect(
                in: CGRect(x: 0, y: (size.height - 2) / 2, width: size.width, height: 2),
                cornerSize: .init(width: 1, height: 1))
            ctx.fill(track, with: .color(.primary.opacity(0.08)))

            for frame in log.frames {
                guard let event = frame.event, event.actor == side else { continue }
                let x = size.width * Double(frame.timeMs) / maxTime
                switch event.kind {
                case .charged:
                    var p = Path()
                    p.addRoundedRect(
                        in: CGRect(x: x - 3, y: 0, width: 6, height: size.height),
                        cornerSize: .init(width: 1.5, height: 1.5))
                    ctx.fill(p, with: .color(color))
                case .fast:
                    let h = size.height * 0.5
                    var p = Path()
                    p.addRect(CGRect(x: x - 1, y: (size.height - h) / 2, width: 2, height: h))
                    ctx.fill(p, with: .color(color.opacity(0.4)))
                case .faint:
                    let r: CGFloat = 4, cy = size.height / 2
                    var p = Path()
                    p.move(to: .init(x: x - r, y: cy - r)); p.addLine(to: .init(x: x + r, y: cy + r))
                    p.move(to: .init(x: x + r, y: cy - r)); p.addLine(to: .init(x: x - r, y: cy + r))
                    ctx.stroke(p, with: .color(Theme.loss), lineWidth: 1.5)
                default:
                    break
                }
            }
        }
        .frame(height: 16)
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
