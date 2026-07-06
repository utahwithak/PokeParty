//
//  PokemonDetailView.swift
//  PokeParty
//
//  Detail for a single ranked Pokémon: stats, moveset, matchups and counters.
//  Styled after PvPoke (type-gradient header, colored stat/rating bars).
//

import SwiftUI

struct PokemonDetailView: View {
    let entry: RankingEntry
    let store: RankingsStore

    @State private var yourShields = 1
    @State private var opponentShields = 1
    @State private var simulated: [RankingEntry.Matchup]?
    @State private var isSimulating = false

    // Editable moveset for the simulated side (seeded from the recommended set).
    @State private var fastMoveId: String
    @State private var charged1Id: String
    @State private var charged2Id: String   // "" == none

    /// How deep into the meta (by rank) to consider simulated matchups.
    private enum MetaScope: Int, CaseIterable, Identifiable {
        case top50 = 50, top100 = 100, top250 = 250, all = 1_000_000
        var id: Int { rawValue }
        var label: String { self == .all ? "All" : "Top \(rawValue)" }
    }
    @State private var metaScope: MetaScope = .top100
    @State private var resultCount = 20

    /// The opponent whose battle timeline is being viewed (drives the sheet).
    @State private var timelineOpponent: RankingEntry.Matchup?

    init(entry: RankingEntry, store: RankingsStore) {
        self.entry = entry
        self.store = store
        _fastMoveId = State(initialValue: entry.moveset.first ?? "")
        _charged1Id = State(initialValue: entry.moveset.count > 1 ? entry.moveset[1] : "")
        _charged2Id = State(initialValue: entry.moveset.count > 2 ? entry.moveset[2] : "")
    }

    private var chargedMoveIds: [String] {
        [charged1Id] + (charged2Id.isEmpty ? [] : [charged2Id])
    }

    private var pokemon: Pokemon? { store.pokemon(for: entry) }

    private func withinScope(_ m: RankingEntry.Matchup) -> Bool {
        (store.rankBySpeciesId[m.opponent] ?? .max) <= metaScope.rawValue
    }

    /// Favorable matchups: simulated (scoped & limited) or the stored top-5.
    private var wins: [RankingEntry.Matchup] {
        guard let simulated else { return Array(entry.matchups.filter(\.isFavorable).prefix(10)) }
        return Array(simulated.filter { $0.isFavorable && withinScope($0) }.prefix(resultCount))
    }

    private var counters: [RankingEntry.Matchup] {
        guard let simulated else { return Array(entry.counters.prefix(10)) }
        return Array(simulated.filter { !$0.isFavorable && withinScope($0) }
            .sorted { $0.rating < $1.rating }
            .prefix(resultCount))
    }

    var body: some View {
        List {
            headerSection
            statsSection
            movesetSection
            simulateSection
            matchupSection(
                title: simulated == nil ? "Key Wins" : "Key Wins (Simulated)",
                systemImage: "checkmark.seal.fill",
                tint: Theme.win,
                matchups: wins,
                showFooter: true
            )
            matchupSection(
                title: "Counters",
                systemImage: "exclamationmark.triangle.fill",
                tint: Theme.loss,
                matchups: counters,
                showFooter: false
            )
        }
        .navigationTitle(entry.speciesName)
        .inlineNavigationTitle()
        // Shields and moveset change the outcome, so cached results become stale.
        .onChange(of: yourShields) { simulated = nil }
        .onChange(of: opponentShields) { simulated = nil }
        .onChange(of: fastMoveId) { simulated = nil }
        .onChange(of: charged1Id) { simulated = nil }
        .onChange(of: charged2Id) { simulated = nil }
        .sheet(item: $timelineOpponent) { matchup in
            timelineSheet(for: matchup)
        }
    }

    /// The battle timeline for one matchup, re-run with recording on.
    @ViewBuilder
    private func timelineSheet(for matchup: RankingEntry.Matchup) -> some View {
        NavigationStack {
            Group {
                if let replay = store.battleReplay(
                    for: entry, fastMoveId: fastMoveId, chargedMoveIds: chargedMoveIds,
                    opponentId: matchup.opponent,
                    yourShields: yourShields, opponentShields: opponentShields) {
                    ScrollView {
                        BattleTimelineView(
                            log: replay.log,
                            sideA: BattleParticipant(name: entry.speciesName,
                                                     types: pokemon?.displayTypes ?? [],
                                                     shadow: pokemon?.isShadow ?? false),
                            sideB: opponentParticipant(matchup.opponent),
                            move: { store.move(id: $0) },
                            scenario: replay.scenario)
                        .padding(20)
                    }
                } else {
                    ContentUnavailableView("Couldn't build battle", systemImage: "exclamationmark.triangle")
                }
            }
            .navigationTitle("\(entry.speciesName) vs \(store.name(forSpeciesId: matchup.opponent))")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { timelineOpponent = nil }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 520)
    }

    private func opponentParticipant(_ id: String) -> BattleParticipant {
        let p = store.pokemonById[id]
            ?? (id.hasSuffix("_shadow") ? store.pokemonById[String(id.dropLast("_shadow".count))] : nil)
        return BattleParticipant(
            name: store.name(forSpeciesId: id),
            types: p?.displayTypes ?? [],
            shadow: (p?.isShadow ?? false) || id.hasSuffix("_shadow"))
    }

    // MARK: - Live simulation controls

    @ViewBuilder
    private var simulateSection: some View {
        Section {
            // Menu style, not segmented: segmented pickers inside a macOS List
            // emit "AttributeGraph: cycle detected" whenever the list re-lays-out.
            Picker("Your Shields", selection: $yourShields) {
                ForEach(0...2, id: \.self) { Text("\($0)").tag($0) }
            }
            Picker("Opponent Shields", selection: $opponentShields) {
                ForEach(0...2, id: \.self) { Text("\($0)").tag($0) }
            }

            // Keep the button's label constant while it's clicked: swapping in a
            // ProgressView (or disabling it) mid-press triggers AttributeGraph cycles.
            HStack {
                Button("Simulate vs Entire Meta") {
                    guard !isSimulating else { return }
                    runSimulation()
                }
                if isSimulating {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if simulated != nil {
                Picker("Meta", selection: $metaScope) {
                    ForEach(MetaScope.allCases) { Text($0.label).tag($0) }
                }

                // A menu picker instead of a Stepper: Steppers in macOS Lists
                // are a known AttributeGraph-cycle source.
                Picker("Show", selection: $resultCount) {
                    ForEach([10, 20, 30, 50], id: \.self) { Text("\($0) each").tag($0) }
                }

                Button("Show PvPoke's Stored Matchups", role: .cancel) { simulated = nil }
            }
        } header: {
            Label("Battle Simulator", systemImage: "bolt.fill")
        } footer: {
            Group {
                if simulated == nil {
                    Text("Runs this Pokémon against every Pokémon in \(store.format.title) at the chosen shield counts, using PokeParty's own battle engine.")
                } else {
                    Text("Showing matchups within the \(metaScope.label.lowercased()) of the meta. Adjust shields and re-simulate to compare scenarios.")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func runSimulation() {
        isSimulating = true
        let your = yourShields
        let opp = opponentShields
        let fast = fastMoveId
        let charged = chargedMoveIds
        Task {
            let results = await store.simulateMatchups(
                for: entry, fastMoveId: fast, chargedMoveIds: charged,
                yourShields: your, opponentShields: opp)
            simulated = results
            isSimulating = false
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        Section {
            ZStack(alignment: .bottomLeading) {
                PokemonType.gradient(for: pokemon?.displayTypes.first ?? "normal")

                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let dex = pokemon?.dex {
                            Text("#\(dex)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        Text(entry.speciesName)
                            .font(.title.weight(.bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                        if let types = pokemon?.displayTypes, !types.isEmpty {
                            TypeBadgeRow(types: types)
                        }
                    }
                    Spacer()
                    VStack(spacing: 2) {
                        ScoreBadge(score: entry.displayScore)
                        Text("Score")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding()
            }
            .frame(height: 130)
            .listRowInsets(EdgeInsets())
        }
    }

    @ViewBuilder
    private var statsSection: some View {
        Section("Stats (\(store.format.title))") {
            if let stats = entry.stats {
                StatBar(label: "Attack", value: stats.atk, color: Theme.attack)
                StatBar(label: "Defense", value: stats.def, color: Theme.defense)
                StatBar(label: "HP", value: stats.hp, color: Theme.hp)
                if let product = stats.product {
                    LabeledContent("Stat Product") {
                        Text(product, format: .number.precision(.fractionLength(0)))
                            .monospacedDigit()
                    }
                }
            } else {
                Text("No stat data available.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var movesetSection: some View {
        // Counts use the selected fast move, so they stay in sync with the moveset.
        let fastEnergyGain = store.move(id: fastMoveId)?.energyGain
        Section {
            if let pokemon {
                MoveSelectorRow(
                    slot: "Fast",
                    selection: $fastMoveId,
                    optionIds: pokemon.fastMoves,
                    recommendedId: entry.moveset.first,
                    includesNone: false,
                    fastEnergyGain: nil,
                    store: store
                )
                MoveSelectorRow(
                    slot: "Charged",
                    selection: $charged1Id,
                    optionIds: pokemon.chargedMoves,
                    recommendedId: entry.moveset.count > 1 ? entry.moveset[1] : nil,
                    includesNone: false,
                    fastEnergyGain: fastEnergyGain,
                    store: store
                )
                MoveSelectorRow(
                    slot: "Charged",
                    selection: $charged2Id,
                    optionIds: pokemon.chargedMoves,
                    recommendedId: entry.moveset.count > 2 ? entry.moveset[2] : nil,
                    includesNone: true,
                    fastEnergyGain: fastEnergyGain,
                    store: store
                )
            } else {
                Text("No moveset data available.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Moveset")
        } footer: {
            Text("Tap a move to change it — the meta simulation below uses this moveset.")
        }
    }

    @ViewBuilder
    private func matchupSection(
        title: String,
        systemImage: String,
        tint: Color,
        matchups: [RankingEntry.Matchup],
        showFooter: Bool
    ) -> some View {
        if !matchups.isEmpty {
            Section {
                ForEach(matchups) { matchup in
                    Button {
                        timelineOpponent = matchup
                    } label: {
                        HStack(spacing: 12) {
                            if let rank = store.rankBySpeciesId[matchup.opponent] {
                                Text("#\(rank)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 34, alignment: .trailing)
                            }
                            Text(store.name(forSpeciesId: matchup.opponent))
                                .font(.subheadline)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            RatingBar(rating: matchup.rating)
                                .frame(width: 90)
                            Text("\(matchup.rating)")
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(matchup.isFavorable ? Theme.win : Theme.loss)
                                .frame(width: 44, alignment: .trailing)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Label(title, systemImage: systemImage)
                    .foregroundStyle(tint)
            } footer: {
                if showFooter {
                    Text("Battle rating vs. each opponent — tap a row to watch the battle timeline. 500 is an even fight.")
                }
            }
        }
    }
}

/// An editable moveset slot: a menu to pick the move (with the recommended
/// choice flagged and DPS/EPS shown per option) plus PvPoke-colored stat chips
/// for the current selection.
private struct MoveSelectorRow: View {
    let slot: String
    @Binding var selection: String
    let optionIds: [String]
    /// The PvPoke-recommended move for this slot, flagged in the menu.
    let recommendedId: String?
    /// Whether this slot offers a "None" choice (second charged move).
    let includesNone: Bool
    /// Energy gained per use of the selected fast move, used for charged-move counts.
    let fastEnergyGain: Int?
    let store: RankingsStore

    private var move: Move? { store.move(id: selection) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Menu {
                    if includesNone {
                        selectionButton(id: "", label: "None")
                    }
                    ForEach(optionIds, id: \.self) { id in
                        selectionButton(id: id, label: optionLabel(id))
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(move?.name ?? "None")
                            .font(.body.weight(.medium))
                        if let move { TypeBadge(type: move.type) }
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Text(slot)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if let move {
                HStack(spacing: 8) {
                    MoveStat(label: "PWR", value: "\(move.power)", color: Theme.movePower,
                             help: "Power — base damage this move deals before type effectiveness and stats.")
                    if move.isFast {
                        MoveStat(label: "NRG", value: "+\(move.energyGain)", color: Theme.moveEnergy,
                                 help: "Energy gained — energy this fast move adds to your meter each use.")
                        if let turns = move.turns {
                            MoveStat(label: "TURNS", value: "\(turns)", color: Theme.moveDuration,
                                     help: String(format: "Turns — duration in 0.5s battle turns (%d turns = %.1fs).", turns, Double(turns) * 0.5))
                        }
                    } else {
                        MoveStat(label: "NRG", value: "\(move.energy)", color: Theme.moveEnergy,
                                 help: "Energy cost — energy required to fire this charged move.")
                        if let countText = countText(for: move) {
                            MoveStat(label: "COUNT", value: countText, color: Theme.moveDuration,
                                     help: "Count — fast moves needed to reach this move on each of the next 5 throws, carrying leftover energy between them.")
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func selectionButton(id: String, label: String) -> some View {
        Button {
            selection = id
        } label: {
            if id == selection {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    /// Menu label: move name, "(Recommended)" flag, and DPS/EPS (fast) or DPE (charged).
    private func optionLabel(_ id: String) -> String {
        guard let m = store.move(id: id) else { return id }
        var name = m.name
        if id == recommendedId { name += " (Recommended)" }
        if m.isFast {
            let turns = m.turns ?? max(m.cooldown / 500, 1)
            let seconds = Double(turns) * 0.5
            guard seconds > 0 else { return name }
            let dps = Double(m.power) / seconds
            let eps = Double(m.energyGain) / seconds
            return String(format: "%@  ·  %d turns · %.1f DPS · %.1f EPS", name, turns, dps, eps)
        } else if m.energy > 0 {
            let dpe = Double(m.power) / Double(m.energy)
            return String(format: "%@  ·  %d PWR · %.2f DPE", name, m.power, dpe)
        }
        return name
    }

    /// Fast-move counts to fire this charged move on each of the next 5 throws,
    /// carrying leftover energy between throws. "Straight N" when every throw is
    /// the same, otherwise a dash-separated series like "5 - 4 - 4 - 4 - 4".
    private func countText(for move: Move) -> String? {
        guard !move.isFast, let gain = fastEnergyGain, gain > 0, move.energy > 0 else { return nil }
        var stored = 0
        var counts: [Int] = []
        for _ in 0..<5 {
            let needed = max(0, move.energy - stored)
            let fastMoves = Int((Double(needed) / Double(gain)).rounded(.up))
            counts.append(fastMoves)
            stored += fastMoves * gain - move.energy
        }
        if let first = counts.first, counts.allSatisfy({ $0 == first }) {
            return "Straight \(first)"
        }
        return counts.map(String.init).joined(separator: " - ")
    }
}

/// A small colored chip showing one move statistic.
private struct MoveStat: View {
    let label: String
    let value: String
    let color: Color
    /// Tooltip shown on hover (macOS) and surfaced to VoiceOver.
    var help: String = ""

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.85))
            Text(value)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color, in: Capsule())
        .help(help)
    }
}
