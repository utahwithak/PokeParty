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
    @State private var addLeague: League = .great
    @State private var sortOrder: BenchSortOrder = .alphabetical
    @State private var sortCache = BenchSortCache()
    @State private var cacheTask: Task<Void, Never>?
    @State private var benchFinder = BenchFinderModel()
    @State private var showingBenchResults = false
    @State private var showingScanner = false

    /// Entries for `league` matching the current search, in the chosen sort order.
    private func sortedFilteredEntries(for league: League) -> [BenchEntry] {
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
                let cap = entry.league.cp
                let levelCap: Double = entry.isBestBuddy ? 51 : 50
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
        return store.allPokemon.filter { p in
            !bench.contains(speciesId: p.speciesId, league: addLeague) &&
            p.speciesName.localizedCaseInsensitiveContains(q)
        }
    }

    private var isEmpty: Bool {
        bench.entries.isEmpty && searchText.isEmpty
    }

    var body: some View {
        List(selection: $selectedID) {
            benchSections
            addToBenchSection
        }
        .navigationTitle("My Bench")
        .inlineNavigationTitle()
        .searchable(text: $searchText, prompt: "Search or add Pokémon")
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
                }
                .fixedSize()
                .help("Find the best teams from your bench")
                Button { showingScanner = true } label: {
                    Label("Scan", systemImage: "camera.viewfinder")
                        .labelStyle(.iconOnly)
                        .font(.caption)
                }
                .fixedSize()
                .help("Scan a Pokémon from iPhone Mirroring")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) {
                Divider()
            }
        }
        .sheet(isPresented: $showingBenchResults) {
            BenchTeamResultsView(
                model: benchFinder,
                onOpenInBuilder: openTeamInBuilder)
        }
        .sheet(isPresented: $showingScanner) {
            ScannerSheet(bench: bench, store: store) { newID in
                selectedID = newID
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
                        && League.allCases.allSatisfy({ sortedFilteredEntries(for: $0).isEmpty })
                        && addableResults.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    @ViewBuilder
    private var benchSections: some View {
        ForEach(League.allCases) { league in
            let entries = sortedFilteredEntries(for: league)
            if !entries.isEmpty {
                Section(league.title + " League") {
                    ForEach(entries) { entry in
                        BenchRowView(
                            entry: entry, store: store,
                            sortOrder: sortOrder,
                            cp: sortCache.cp[entry.id],
                            rank: sortCache.rank[entry.id])
                            .tag(entry.id)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    if selectedID == entry.id { selectedID = nil }
                                    bench.delete(entry)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                    }
                }
            }
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
        }
    }

    private func addToBench(_ pokemon: Pokemon) {
        let entry = bench.addFromRankings(
            speciesId: pokemon.speciesId, store: store, league: addLeague)
        searchText = ""
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

struct BenchDetailView: View {
    @Bindable var bench: BenchStore
    let store: RankingsStore
    let entryID: BenchEntry.ID

    @State private var local: BenchEntry?
    @State private var ivRank: IVCalculator.RankResult?
    @State private var rankTask: Task<Void, Never>?

    private var species: Pokemon? {
        local.flatMap { store.pokemonById[$0.speciesId] }
    }

    private var recommended: [String] {
        local.flatMap { store.entry(id: $0.speciesId)?.moveset } ?? []
    }

    /// Opaque key that changes whenever IVs, league, or Best Buddy status changes.
    private var rankKey: String? {
        guard let e = local, let ivs = e.ivs else { return nil }
        return "\(e.speciesId)-\(ivs.atk)-\(ivs.def)-\(ivs.hp)-\(e.league.rawValue)-\(e.isBestBuddy)"
    }

    var body: some View {
        ScrollView {
            if let entry = local {
                VStack(alignment: .leading, spacing: 20) {
                    header(entry: entry)
                    Divider()
                    leagueSection(entry: entry)
                    Divider()
                    movesSection(entry: entry)
                    Divider()
                    ivsSection(entry: entry)
                    if let sp = species, sp.isShadow || sp.isShadowEligible || entry.shadow {
                        Divider()
                        shadowSection(entry: entry)
                    }
                    Divider()
                    bestBuddySection(entry: entry)
                    Divider()
                    deleteButton(entry: entry)
                    AttributionFooter()
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle(local.map { localDisplayName($0) } ?? "")
        .onAppear { sync() }
        .onChange(of: entryID) { sync() }
        .onChange(of: local) { _, new in
            if let new { bench.update(new) }
        }
        .onChange(of: rankKey) { _, key in
            computeRank(key: key)
        }
    }

    private func sync() {
        guard let entry = bench.entry(id: entryID) else { return }
        local = entry
        ivRank = nil
        computeRank(key: rankKey)
    }

    private func computeRank(key: String?) {
        rankTask?.cancel()
        guard let key, !key.isEmpty,
              let e = local, let ivs = e.ivs,
              let sp = species else {
            ivRank = nil
            return
        }
        let base = sp.baseStats
        let cap = e.league.cp
        let levelCap: Double = e.isBestBuddy ? 51 : 50
        rankTask = Task.detached(priority: .userInitiated) {
            let result = IVCalculator.rank(
                baseAtk: base.atk, baseDef: base.def, baseHp: base.hp,
                cpCap: cap, ivs: ivs, levelCap: levelCap)
            guard !Task.isCancelled else { return }
            await MainActor.run { ivRank = result }
        }
    }

    private func localDisplayName(_ entry: BenchEntry) -> String {
        entry.nickname.isEmpty
            ? (species?.speciesName ?? entry.speciesId)
            : entry.nickname
    }

    // MARK: Header

    private func header(entry: BenchEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let sp = species {
                TypeBadgeRow(types: sp.displayTypes)
            }
            TextField("Nickname", text: Binding(
                get: { entry.nickname },
                set: { local?.nickname = $0 }
            ), prompt: Text(species?.speciesName ?? entry.speciesId))
            .textFieldStyle(.roundedBorder)
            .font(.title3.weight(.semibold))
        }
    }

    // MARK: League

    private func leagueSection(entry: BenchEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("League")
                .font(.headline)
            Picker("League", selection: Binding(
                get: { entry.league },
                set: { local?.league = $0 }
            )) {
                ForEach(League.allCases) { l in
                    Text(l.title).tag(l)
                }
            }
            .pickerStyle(.segmented)
            Text(entry.league.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Moves

    private func movesSection(entry: BenchEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Moves")
                .font(.headline)

            if let sp = species {
                TeamMovePicker(
                    label: "Fast",
                    currentId: entry.fastMoveId,
                    optionIds: sp.fastMoves,
                    recommendedId: recommended.first,
                    includesNone: false,
                    species: sp,
                    store: store,
                    onSelect: { if let id = $0 { local?.fastMoveId = id } })

                TeamMovePicker(
                    label: "Charged 1",
                    currentId: entry.chargedMoveIds.first ?? "",
                    optionIds: sp.chargedMoves,
                    recommendedId: recommended.count > 1 ? recommended[1] : nil,
                    includesNone: false,
                    species: sp,
                    store: store,
                    onSelect: { id in
                        guard let id else { return }
                        if local?.chargedMoveIds.isEmpty == false {
                            local?.chargedMoveIds[0] = id
                        } else {
                            local?.chargedMoveIds = [id]
                        }
                    })

                TeamMovePicker(
                    label: "Charged 2",
                    currentId: entry.chargedMoveIds.count > 1 ? entry.chargedMoveIds[1] : "",
                    optionIds: sp.chargedMoves,
                    recommendedId: recommended.count > 2 ? recommended[2] : nil,
                    includesNone: true,
                    species: sp,
                    store: store,
                    onSelect: { id in
                        if let id {
                            if (local?.chargedMoveIds.count ?? 0) > 1 {
                                local?.chargedMoveIds[1] = id
                            } else {
                                local?.chargedMoveIds.append(id)
                            }
                        } else {
                            if (local?.chargedMoveIds.count ?? 0) > 1 {
                                local?.chargedMoveIds.removeLast()
                            }
                        }
                    })
            }
        }
    }

    // MARK: IVs

    private func ivsSection(entry: BenchEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("IVs")
                .font(.headline)

            Toggle("Use specific IVs", isOn: Binding(
                get: { entry.ivs != nil },
                set: { on in
                    local?.ivs = on ? (entry.ivs ?? IVs(atk: 15, def: 15, hp: 15)) : nil
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            if let ivs = entry.ivs {
                VStack(spacing: 6) {
                    IVRow(label: "Attack", value: Binding(
                        get: { ivs.atk },
                        set: { local?.ivs?.atk = $0 }))
                    IVRow(label: "Defense", value: Binding(
                        get: { ivs.def },
                        set: { local?.ivs?.def = $0 }))
                    IVRow(label: "HP", value: Binding(
                        get: { ivs.hp },
                        set: { local?.ivs?.hp = $0 }))
                }
                .padding(.leading, 4)

                if let sp = species {
                    ivStatsPreview(sp: sp, ivs: ivs, league: entry.league, bestBuddy: entry.isBestBuddy)
                }
            } else {
                Text("Uses the best possible IV spread for \(entry.league.title) League's CP cap.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Shows computed battle stats + IV rank for these IVs at the entry's league CP cap.
    private func ivStatsPreview(sp: Pokemon, ivs: IVs, league: League, bestBuddy: Bool) -> some View {
        let levelCap: Double = bestBuddy ? 51 : 50
        let battleStats = IVCalculator.stats(
            baseAtk: sp.baseStats.atk, baseDef: sp.baseStats.def, baseHp: sp.baseStats.hp,
            ivs: ivs, cpCap: league.cp, levelCap: levelCap)
        return Group {
            if let s = battleStats {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Label(league.title, systemImage: "shield.lefthalf.filled")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(league.tint)
                        Spacer()
                        Text("Atk \(String(format: "%.1f", s.atk))  Def \(String(format: "%.1f", s.def))  HP \(s.hp)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    if let rank = ivRank {
                        HStack {
                            Text("Rank \(rank.rank) / \(rank.total)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.1f%%", rank.percent))
                                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                                .foregroundStyle(rankColor(rank.percent))
                        }
                    } else {
                        Text("Computing rank…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text("These IVs exceed the \(league.title) League CP cap.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func rankColor(_ percent: Double) -> Color {
        switch percent {
        case 99...: .green
        case 95..<99: .mint
        case 90..<95: .blue
        default: .secondary
        }
    }

    // MARK: Shadow

    private func shadowSection(entry: BenchEntry) -> some View {
        Toggle("Shadow", isOn: Binding(
            get: { entry.shadow },
            set: { local?.shadow = $0 }
        ))
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    // MARK: Best Buddy

    private func bestBuddySection(entry: BenchEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { entry.isBestBuddy },
                set: { local?.isBestBuddy = $0 }
            )) {
                Label("Best Buddy", systemImage: "star.fill")
                    .foregroundStyle(entry.isBestBuddy ? .yellow : .secondary)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Text("Allows powering up one extra level (51 instead of 50), raising CP and stats.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Delete

    private func deleteButton(entry: BenchEntry) -> some View {
        Button(role: .destructive) {
            bench.delete(entry)
        } label: {
            Label("Remove from Bench", systemImage: "trash")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.red)
    }
}

// MARK: - Bench team results sheet

/// Two-phase sheet: static grade analysis finds bench trios, then a full
/// round-robin tournament measures how those trios actually perform against
/// a competitive meta field. Only bench teams' records are shown.
struct BenchTeamResultsView: View {
    var model: BenchFinderModel
    var onOpenInBuilder: ((League, [TeamMember]) -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            content
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    private var titleBar: some View {
        HStack {
            if let league = model.resultsLeague {
                Text("\(league.title) League · \(model.benchCount) bench Pokémon")
                    .font(.headline)
            } else {
                Text("Bench Team Finder")
                    .font(.headline)
            }
            Spacer()
            if model.isRunning {
                Button("Cancel") { model.cancel() }
            } else {
                Button("Done") { dismiss() }
            }
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            EmptyView()

        case .loadingRankings:
            ProgressView("Loading rankings…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .gradingBench:
            VStack(spacing: 10) {
                ProgressView(value: model.progress / 0.45) {
                    Text("Phase 1 — Grading bench teams against the meta…")
                }
                .padding(.horizontal)
                Text("Finding the best bench trios using static grade analysis.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .searching:
            tournamentView

        case .done:
            tournamentView

        case .failed(let message):
            ContentUnavailableView(
                "Could Not Find Teams",
                systemImage: "exclamationmark.triangle",
                description: Text(message))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Tournament leaderboard (phases 2 + done)

    private var tournamentView: some View {
        VStack(spacing: 0) {
            tournamentHeader.padding()
            Divider()
            if model.benchStandings.isEmpty {
                ContentUnavailableView(
                    "Seeding tournament…",
                    systemImage: "wand.and.stars",
                    description: Text("Bench teams enter the leaderboard as battles resolve."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.benchStandings.enumerated()), id: \.element.id) { index, team in
                            benchTournamentRow(rank: index + 1, team: team)
                                .transition(.asymmetric(insertion: .opacity, removal: .opacity))
                        }
                    }
                    .padding(.vertical, 4)
                    .animation(.spring(duration: 0.6), value: model.benchStandings.map(\.id))
                }
            }
        }
    }

    private var tournamentHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                if let standings = model.standings {
                    Text(standings.isComplete
                         ? "Tournament complete"
                         : "Round \(standings.round + 1) of \(standings.totalRounds + 1)")
                        .font(.headline)
                        .contentTransition(.numericText())
                } else {
                    Text("Tournament starting…").font(.headline)
                }
                Spacer()
                Text("\(model.benchStandings.count) bench team\(model.benchStandings.count == 1 ? "" : "s")")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if model.phase == .searching, let standings = model.standings {
                ProgressView(
                    value: Double(standings.battlesFought),
                    total: Double(max(standings.totalBattles, 1)))
                    .progressViewStyle(.linear)
            } else if model.phase == .searching {
                ProgressView(value: (model.progress - 0.45) / 0.55)
                    .progressViewStyle(.linear)
            }
            Text(tournamentCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var tournamentCaption: String {
        let league = model.resultsLeague.map { "\($0.title) League — " } ?? ""
        let benched = model.gradedBenchTeams.count
        let field = model.tournamentFieldSize
        if model.phase == .done {
            return "\(league)\(benched) bench trio\(benched == 1 ? "" : "s") in a \(field)-team round robin alongside top-\(BenchFinderModel.metaPoolSize) meta teams. Bench records below, best win rate first. The first member is the lead."
        }
        return "\(league)Phase 2 — \(benched) bench trio\(benched == 1 ? "" : "s") battling in a \(field)-team round robin with top-\(BenchFinderModel.metaPoolSize) meta teams. Bench results update live."
    }

    // MARK: - Tournament row (bench team)

    private func benchTournamentRow(rank: Int, team: TeamFinder.RankedTeam) -> some View {
        let graded = model.gradedBenchTeams.first(where: { $0.id == team.id })
        return HStack(alignment: .center, spacing: 12) {
            Text("#\(rank)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
                .contentTransition(.numericText())

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    ForEach(Array(team.members.enumerated()), id: \.offset) { index, member in
                        benchMemberCell(member: member, isLead: index == 0)
                    }
                }
                benchRecordLine(team: team, graded: graded)
            }

            Spacer()

            if let onOpenInBuilder, let league = model.resultsLeague {
                Button("Open in Team Builder") {
                    onOpenInBuilder(league, team.members.map(\.member))
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func benchRecordLine(team: TeamFinder.RankedTeam, graded: GradeFinder.GradedTeam?) -> some View {
        if team.gamesPlayed == 0 {
            Text("Seeded — awaiting first battles")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 8) {
                Text(team.winRate, format: .percent.precision(.fractionLength(0)))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText())
                Text("\(team.wins)W · \(team.losses)L\(team.ties > 0 ? " · \(team.ties)T" : "") vs field")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                RatingBar(rating: Int(team.averageRating.rounded()))
                    .frame(maxWidth: 120)
                if let graded {
                    Text(graded.gradeString)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background((graded.isAAAA ? Color.green : Color.orange).gradient, in: Capsule())
                        .help("Static grades (Coverage · Bulk · Safety · Consistency)")
                }
            }
        }
    }

    private func benchMemberCell(member: TeamFinder.RankedTeam.Member, isLead: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(member.speciesName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if member.shadow { ShadowBadge() }
                if isLead {
                    Text("LEAD")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            TypeBadgeRow(types: member.types)
        }
        .frame(minWidth: 110, alignment: .leading)
    }
}

// MARK: - IV text field row

private struct IVRow: View {
    let label: String
    @Binding var value: Int

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            TextField("0–15", value: Binding(
                get: { value },
                set: { value = max(0, min(15, $0)) }
            ), format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 52)
            .multilineTextAlignment(.center)
            .font(.system(.caption, design: .monospaced))
        }
    }
}
