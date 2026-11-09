//
//  BenchView.swift
//  PokeParty
//
//  Middle and detail columns for the "My Bench" section. The middle column
//  lists Pokémon grouped by league (GL/UL/ML) and lets you search to add
//  new ones; the detail column provides a full editor (nickname, league,
//  moves, IVs, shadow).
//

import SwiftUI

// MARK: - Sort order

enum BenchSortOrder: String, CaseIterable, Identifiable {
    case alphabetical = "Name"
    case dexNumber = "Number"
    case cp = "CP"
    case ivRank = "Rank"
    var id: String { rawValue }
}

// Pre-computed sort keys for CP and rank (expensive to compute on-demand).
private struct BenchSortCache {
    var cp: [BenchEntry.ID: Int] = [:]
    var rank: [BenchEntry.ID: Int] = [:]
}

// MARK: - Middle column

struct BenchView: View {
    @Bindable var bench: BenchStore
    var store: RankingsStore
    @Binding var selectedID: BenchEntry.ID?
    /// Called when the user taps "Open in Team Builder" in the bench finder results.
    var openTeamInBuilder: ((League, [TeamMember]) -> Void)? = nil
    @State private var searchText = ""
    /// Closed after adding a Pokémon, so the detail screen it opens isn't pushed
    /// with the search field still active (which hid the navigation bar).
    @State private var isSearchPresented = false
    @State private var addLeague: League = .great
    @State private var sortOrder: BenchSortOrder = .alphabetical
    @State private var sortCache = BenchSortCache()
    @State private var cacheTask: Task<Void, Never>?
    @State private var benchFinder = BenchFinderModel()
    @State private var showingBenchResults = false
    /// Set when a swipe-to-delete is tapped; cleared once the confirmation
    /// dialog is answered either way.
    @State private var pendingDelete: BenchEntry?

    /// Entries for `league` matching the current search, in the chosen sort
    /// order. `nil` returns the unclassified bucket.
    private func sortedFilteredEntries(for league: League?) -> [BenchEntry] {
        var entries = bench.entries.filter { $0.league == league }
        if !searchText.isEmpty {
            let q = searchText.trimmingCharacters(in: .whitespaces)
            entries = entries.filter { entry in
                let name = store.pokemonById[entry.speciesId]?.speciesName ?? entry.speciesId
                return name.localizedCaseInsensitiveContains(q)
                    || (!entry.nickname.isEmpty && entry.nickname.localizedCaseInsensitiveContains(q))
            }
        }
        switch sortOrder {
        case .alphabetical:
            entries.sort { entryName($0) < entryName($1) }
        case .dexNumber:
            entries.sort {
                (store.pokemonById[$0.speciesId]?.dex ?? Int.max) <
                (store.pokemonById[$1.speciesId]?.dex ?? Int.max)
            }
        case .cp:
            entries.sort { (sortCache.cp[$0.id] ?? 0) > (sortCache.cp[$1.id] ?? 0) }
        case .ivRank:
            entries.sort { (sortCache.rank[$0.id] ?? Int.max) < (sortCache.rank[$1.id] ?? Int.max) }
        }
        return entries
    }

    private func entryName(_ entry: BenchEntry) -> String {
        entry.nickname.isEmpty
            ? (store.pokemonById[entry.speciesId]?.speciesName ?? entry.speciesId)
            : entry.nickname
    }

    private func refreshSortCache() {
        cacheTask?.cancel()
        let entries = bench.entries
        let pokemonById = store.pokemonById
        cacheTask = Task.detached(priority: .utility) {
            var cpMap: [BenchEntry.ID: Int] = [:]
            var rankMap: [BenchEntry.ID: Int] = [:]
            for entry in entries {
                guard !Task.isCancelled else { return }
                guard let sp = pokemonById[entry.speciesId] else { continue }
                // Unclassified entries have no CP cap to rank against — leave
                // them out of the cache; CP/Rank sort falls back to the
                // defaults below and sinks them to the bottom.
                guard let league = entry.league else { continue }
                let cap = league.cp
                let levelCap = sp.levelCap(megaLevel: entry.megaLevel, isBestBuddy: entry.isBestBuddy, cpCap: cap)
                if let ivs = entry.ivs {
                    let result = IVCalculator.rank(
                        baseAtk: sp.baseStats.atk, baseDef: sp.baseStats.def, baseHp: sp.baseStats.hp,
                        cpCap: cap, ivs: ivs, levelCap: levelCap)
                    cpMap[entry.id] = result?.combo.cp ?? 0
                    rankMap[entry.id] = result?.rank ?? Int.max
                } else {
                    cpMap[entry.id] = IVCalculator.optimalStats(
                        baseAtk: sp.baseStats.atk, baseDef: sp.baseStats.def, baseHp: sp.baseStats.hp,
                        cpCap: cap, levelCap: levelCap)?.cp ?? 0
                    rankMap[entry.id] = 1
                }
            }
            guard !Task.isCancelled else { return }
            let cache = BenchSortCache(cp: cpMap, rank: rankMap)
            await MainActor.run { sortCache = cache }
        }
    }

    /// Pokémon from the rankings that aren't already on the bench for `addLeague`.
    private var addableResults: [Pokemon] {
        guard !searchText.isEmpty else { return [] }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        return store.pokemonForPicker.filter { p in
            !bench.contains(speciesId: p.speciesId, league: addLeague) &&
            p.speciesName.localizedCaseInsensitiveContains(q)
        }
    }

    private var isEmpty: Bool {
        bench.entries.isEmpty && searchText.isEmpty
    }

    /// Per-league (+ unclassified) filtered/sorted entries, computed once per
    /// body evaluation and shared between the list sections and the "no
    /// results" check below — `sortedFilteredEntries` re-filters/sorts the
    /// whole bench, and both call sites previously recomputed it independently.
    private func computeBuckets() -> (byLeagueId: [Int: [BenchEntry]], unclassified: [BenchEntry]) {
        var byLeagueId: [Int: [BenchEntry]] = [:]
        for league in League.allCases {
            byLeagueId[league.id] = sortedFilteredEntries(for: league)
        }
        return (byLeagueId, sortedFilteredEntries(for: nil))
    }

    var body: some View {
        let buckets = computeBuckets()
        List(selection: $selectedID) {
            benchSections(buckets)
            addToBenchSection
        }
        .themedBackground()
        .navigationTitle("My Bench")
        .inlineNavigationTitle()
        .searchable(text: $searchText, isPresented: $isSearchPresented, prompt: "Search or add Pokémon")
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 6) {
                Text("Sort")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Sort", selection: $sortOrder) {
                    ForEach(BenchSortOrder.allCases) { o in
                        Text(o.rawValue).tag(o)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                Spacer()
                Menu {
                    ForEach(League.allCases) { league in
                        Button(league.title + " League") {
                            showingBenchResults = true
                            benchFinder.run(league: league, bench: bench, store: store)
                        }
                    }
                } label: {
                    Label("Find Teams", systemImage: "wand.and.stars")
                        .labelStyle(.iconOnly)
                        .font(.caption)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .help("Find the best teams from your bench")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .themedBar()
            .overlay(alignment: .bottom) {
                Divider()
            }
        }
        .sheet(isPresented: $showingBenchResults) {
            BenchTeamResultsView(
                model: benchFinder,
                onOpenInBuilder: openTeamInBuilder)
        }
        .confirmationDialog(
            "Remove \(pendingDelete.map(entryName) ?? "this Pokémon") from your bench?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                guard let entry = pendingDelete else { return }
                if selectedID == entry.id { selectedID = nil }
                bench.delete(entry)
                pendingDelete = nil
            }
        }
        .onAppear { refreshSortCache() }
        .onChange(of: bench.entries) { refreshSortCache() }
        .overlay {
            if isEmpty {
                ContentUnavailableView(
                    "No Pokémon on your bench",
                    systemImage: "tray",
                    description: Text("Search to add a Pokémon and set its league, IVs and moves.")
                )
            } else if !searchText.isEmpty
                        && buckets.byLeagueId.values.allSatisfy(\.isEmpty)
                        && buckets.unclassified.isEmpty
                        && addableResults.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    @ViewBuilder
    private func benchSections(_ buckets: (byLeagueId: [Int: [BenchEntry]], unclassified: [BenchEntry])) -> some View {
        ForEach(League.allCases) { league in
            benchSection(title: league.title + " League", entries: buckets.byLeagueId[league.id] ?? [])
        }
        // Fresh scans that could fit several leagues, kept without committing
        // to one yet — see BenchDetailView's league grid to assign one later.
        benchSection(title: "Unclassified", entries: buckets.unclassified)
    }

    @ViewBuilder
    private func benchSection(title: String, entries: [BenchEntry]) -> some View {
        if !entries.isEmpty {
            Section(title) {
                ForEach(entries) { entry in
                    BenchRowView(
                        entry: entry, store: store,
                        sortOrder: sortOrder,
                        cp: sortCache.cp[entry.id],
                        rank: sortCache.rank[entry.id])
                        .tag(entry.id)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingDelete = entry
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                }
            }
            .themedRow()
        }
    }

    @ViewBuilder
    private var addToBenchSection: some View {
        let results = Array(addableResults.prefix(20))
        if !results.isEmpty {
            Section {
                ForEach(results) { pokemon in
                    Button { addToBench(pokemon) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "plus.circle")
                                .foregroundColor(.accentColor)
                            Text(pokemon.speciesName)
                                .font(.body.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                            TypeBadgeRow(types: pokemon.displayTypes)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                HStack {
                    Text("Add to Bench")
                    Spacer()
                    Picker("League", selection: $addLeague) {
                        ForEach(League.allCases) { l in
                            Text(l.title).tag(l)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            .themedRow()
        }
    }

    private func addToBench(_ pokemon: Pokemon) {
        let entry = bench.addFromRankings(
            speciesId: pokemon.speciesId, store: store, league: addLeague)
        searchText = ""
        isSearchPresented = false
        // Defer so the list re-renders with the new row before selection is applied.
        Task { @MainActor in selectedID = entry.id }
    }
}

// MARK: - List row

private struct BenchRowView: View {
    let entry: BenchEntry
    let store: RankingsStore
    let sortOrder: BenchSortOrder
    let cp: Int?
    let rank: Int?

    private var species: Pokemon? { store.pokemonById[entry.speciesId] }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(displayName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if entry.shadow { ShadowBadge() }
                    if entry.isBestBuddy {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.yellow)
                    }
                }
                HStack(spacing: 6) {
                    ivSubtitle
                    sortAnnotation
                }
            }
            Spacer()
            TypeBadgeRow(types: species?.displayTypes ?? [])
        }
    }

    @ViewBuilder
    private var ivSubtitle: some View {
        if let ivs = entry.ivs {
            Text("IVs \(ivs.atk)/\(ivs.def)/\(ivs.hp)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            Text("Optimal IVs")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var sortAnnotation: some View {
        switch sortOrder {
        case .cp:
            if let cp {
                Text("· \(cp) CP")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .ivRank:
            if let rank {
                Text("· Rank \(rank)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .dexNumber:
            if let dex = species?.dex {
                Text("· #\(dex)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .alphabetical:
            EmptyView()
        }
    }

    private var displayName: String {
        entry.nickname.isEmpty
            ? (species?.speciesName ?? entry.speciesId)
            : entry.nickname
    }
}

// MARK: - Detail column
