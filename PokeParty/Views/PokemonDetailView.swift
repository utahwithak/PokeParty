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
    }

    private func moveName(_ id: String) -> String {
        store.move(id: id)?.name ?? id.replacingOccurrences(of: "_", with: " ").capitalized
    }

    // MARK: - Live simulation controls

    @ViewBuilder
    private var simulateSection: some View {
        Section {
            if let pokemon {
                Picker("Fast Move", selection: $fastMoveId) {
                    ForEach(pokemon.fastMoves, id: \.self) { Text(moveName($0)).tag($0) }
                }
                Picker("Charged 1", selection: $charged1Id) {
                    ForEach(pokemon.chargedMoves, id: \.self) { Text(moveName($0)).tag($0) }
                }
                Picker("Charged 2", selection: $charged2Id) {
                    Text("None").tag("")
                    ForEach(pokemon.chargedMoves, id: \.self) { Text(moveName($0)).tag($0) }
                }
            }

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
        let moves = entry.moveset.compactMap { store.move(id: $0) }
        Section("Recommended Moveset") {
            if moves.isEmpty {
                Text("No moveset data available.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(moves) { move in
                    MoveRow(move: move)
                }
            }
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
                    }
                }
            } header: {
                Label(title, systemImage: systemImage)
                    .foregroundStyle(tint)
            } footer: {
                if showFooter {
                    Text("Battle rating vs. each opponent. 500 is an even fight.")
                }
            }
        }
    }
}

/// A single move with its type and PvPoke-colored power/energy stats.
private struct MoveRow: View {
    let move: Move

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(move.name)
                    .font(.body.weight(.medium))
                TypeBadge(type: move.type)
                Spacer()
                Text(move.isFast ? "Fast" : "Charged")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                MoveStat(label: "PWR", value: "\(move.power)", color: Theme.movePower)
                if move.isFast {
                    MoveStat(label: "NRG", value: "+\(move.energyGain)", color: Theme.moveEnergy)
                    if let turns = move.turns {
                        MoveStat(label: "TURNS", value: "\(turns)", color: Theme.moveDuration)
                    }
                } else {
                    MoveStat(label: "NRG", value: "\(move.energy)", color: Theme.moveEnergy)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// A small colored chip showing one move statistic.
private struct MoveStat: View {
    let label: String
    let value: String
    let color: Color

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
    }
}
