//
//  RankingsListView.swift
//  PokeParty
//
//  The middle column: a searchable, selectable list of ranked Pokémon for the
//  league chosen in the sidebar.
//

import SwiftUI

struct RankingsListView: View {
    @Bindable var store: RankingsStore
    @Binding var selection: RankingEntry.ID?

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
        .navigationTitle(store.format.title)
        .inlineNavigationTitle()
        .searchable(text: $store.searchText, prompt: "Search Pokémon")
        .toolbar {
            ToolbarItem {
                Menu {
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        Label("Check for Updates", systemImage: "arrow.clockwise")
                    }
                    Button {
                        Task { await store.rebuildCache() }
                    } label: {
                        Label("Rebuild Data Cache", systemImage: "arrow.triangle.2.circlepath")
                    }
                } label: {
                    Label("Data", systemImage: "arrow.clockwise")
                }
                .help("Refresh or rebuild PvPoke data")
            }
        }
    }

    private var rankingsList: some View {
        List(selection: $selection) {
            Section {
                ForEach(store.rankedEntries) { ranked in
                    RankingRow(rank: ranked.rank, entry: ranked.entry, store: store)
                        .tag(ranked.entry.id)
                }
            } header: {
                Text(store.format.subtitle)
            }

            AttributionFooter()
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
                    if store.pokemon(for: entry)?.isShadow == true { ShadowBadge() }
                }
                if let types = store.pokemon(for: entry)?.displayTypes, !types.isEmpty {
                    TypeBadgeRow(types: types)
                }
            }

            Spacer()

            ScoreBadge(score: entry.displayScore)
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
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.scoreBackground, in: RoundedRectangle(cornerRadius: 8))
    }
}
