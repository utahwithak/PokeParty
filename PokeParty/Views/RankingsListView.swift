//
//  RankingsListView.swift
//  PokeParty
//
//  The middle column: a searchable, selectable list of ranked Pokémon for the
//  league chosen in the sidebar.
//

import SwiftUI

/// How the rankings list is ordered — mirrors PvPoke's own ranking
/// categories, each a sub-score (0–100) of how well a Pokémon performs in
/// that role. Each row still shows its true overall league standing (see
/// `RankingsStore.rankedEntries`) regardless of the chosen order — sorting
/// only changes row order and which score the badge displays.
enum RankingSortOrder: String, CaseIterable, Identifiable {
    case overall = "Overall"
    case lead = "Lead"
    case closer = "Closer"
    case switching = "Switch"
    case charger = "Charger"
    case attacker = "Attacker"
    case consistency = "Consistency"
    var id: String { rawValue }

    /// Index into `RankingEntry.scores` ([leads, closers, switches, chargers,
    /// attackers, consistency]); `nil` for `.overall`, which uses `displayScore`.
    private var scoresIndex: Int? {
        switch self {
        case .overall: return nil
        case .lead: return 0
        case .closer: return 1
        case .switching: return 2
        case .charger: return 3
        case .attacker: return 4
        case .consistency: return 5
        }
    }

    /// This category's score for `entry` (0–100), falling back to 0 if the
    /// sub-score is missing (older ranking data without a `scores` array).
    func score(for entry: RankingEntry) -> Double {
        guard let index = scoresIndex else { return entry.displayScore }
        let scores = entry.scores ?? []
        return index < scores.count ? scores[index] : 0
    }
}

struct RankingsListView: View {
    @Bindable var store: RankingsStore
    @Binding var selection: RankingEntry.ID?
    @State private var sortOrder: RankingSortOrder = .overall

    private var sortedEntries: [RankingsStore.RankedEntry] {
        guard sortOrder != .overall else { return store.rankedEntries }
        return store.rankedEntries.sorted { sortOrder.score(for: $0.entry) > sortOrder.score(for: $1.entry) }
    }

    var body: some View {
        Group {
            switch store.phase {
            case .loading where store.entries.isEmpty:
                ProgressView("Loading rankings…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Load", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await store.load() } }
                        .buttonStyle(.borderedProminent)
                }

            default:
                rankingsList
            }
        }
        .themedBackground()
        .navigationTitle(store.format.title)
        .inlineNavigationTitle()
        .searchable(text: $store.searchText, prompt: "Search Pokémon")
    }

    private var rankingsList: some View {
        List(selection: $selection) {
            Section {
                ForEach(sortedEntries) { ranked in
                    RankingRow(rank: ranked.rank, entry: ranked.entry, store: store, sortOrder: sortOrder)
                        .tag(ranked.entry.id)
                }
            } header: {
                Text(store.format.subtitle)
            }
            .themedPlainRow()

            AttributionFooter()
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 6) {
                Text("Sort")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Sort", selection: $sortOrder) {
                    ForEach(RankingSortOrder.allCases) { o in
                        Text(o.rawValue).tag(o)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) {
                Divider()
            }
        }
        .overlay {
            if store.rankedEntries.isEmpty {
                ContentUnavailableView.search(text: store.searchText)
            }
        }
        .refreshable { await store.refresh() }
    }
}

/// One row in the rankings list: rank, name, types and score.
private struct RankingRow: View {
    let rank: Int
    let entry: RankingEntry
    let store: RankingsStore
    let sortOrder: RankingSortOrder

    var body: some View {
        HStack(spacing: 12) {
            if let primaryType = store.pokemon(for: entry)?.displayTypes.first {
                RoundedRectangle(cornerRadius: 2)
                    .fill(PokemonType.gradient(for: primaryType))
                    .frame(width: 4)
            }

            Text("\(rank)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 28, alignment: .trailing)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(entry.speciesName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if store.pokemon(for: entry)?.isShadow == true { ShadowBadge() }
                }
                if let types = store.pokemon(for: entry)?.displayTypes, !types.isEmpty {
                    TypeBadgeRow(types: types)
                }
            }

            Spacer()

            ScoreBadge(score: sortOrder.score(for: entry))
        }
        .padding(.vertical, 2)
    }
}

/// The 0–100 ranking score, styled like PvPoke's dark score pill.
struct ScoreBadge: View {
    let score: Double

    var body: some View {
        Text(score, format: .number.precision(.fractionLength(1)))
            .font(.subheadline.weight(.bold).monospacedDigit())
            .foregroundStyle(Theme.scoreText)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.scoreBackground, in: RoundedRectangle(cornerRadius: 8))
    }
}
