//
//  BenchDetailView.swift
//  PokeParty
//
//  Detail pane for a single bench entry.
//

import SwiftUI

struct BenchDetailView: View {
    @Bindable var bench: BenchStore
    let store: RankingsStore
    let entryID: BenchEntry.ID

    @State private var local: BenchEntry?
    @State private var ivRank: IVCalculator.RankResult?
    @State private var rankTask: Task<Void, Never>?
    @State private var showingDeleteConfirmation = false

    private var species: Pokemon? {
        local.flatMap { store.pokemonById[$0.speciesId] }
    }

    private var recommended: [String] {
        local.flatMap { store.entry(id: $0.speciesId)?.moveset } ?? []
    }

    /// Opaque key that changes whenever IVs, league, or Best Buddy status
    /// changes. nil for unclassified entries — there's no CP cap to rank
    /// against until a league is chosen.
    private var rankKey: String? {
        guard let e = local, let ivs = e.ivs, let league = e.league else { return nil }
        return "\(e.speciesId)-\(ivs.atk)-\(ivs.def)-\(ivs.hp)-\(league.rawValue)-\(e.isBestBuddy)"
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
        .confirmationDialog(
            "Remove \(local.map(localDisplayName) ?? "this Pokémon") from your bench?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                guard let entry = local else { return }
                bench.delete(entry)
            }
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
              let e = local, let ivs = e.ivs, let league = e.league,
              let sp = species else {
            ivRank = nil
            return
        }
        let base = sp.baseStats
        let cap = league.cp
        let levelCap = sp.levelCap(megaLevel: e.megaLevel, isBestBuddy: e.isBestBuddy, cpCap: cap)
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
                Text("Unclassified").tag(League?.none)
                ForEach(League.allCases) { l in
                    Text(l.title).tag(League?.some(l))
                }
            }
            .pickerStyle(.segmented)
            if let league = entry.league {
                Text(league.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not committed to a league yet — pick one from the ranks below, or scanning will suggest one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
                            // Only clear when slot 2 is the last move; a third
                            // (mega) move has to be cleared first.
                            if local?.chargedMoveIds.count == 2 {
                                local?.chargedMoveIds.removeLast()
                            }
                        }
                    })

                if sp.hasThirdChargedMove {
                    TeamMovePicker(
                        label: "Charged 3",
                        currentId: entry.chargedMoveIds.count > 2 ? entry.chargedMoveIds[2] : "",
                        optionIds: sp.extraChargedMoves ?? [],
                        recommendedId: recommended.count > 3 ? recommended[3] : nil,
                        includesNone: true,
                        species: sp,
                        store: store,
                        onSelect: { id in
                            guard var ids = local?.chargedMoveIds else { return }
                            if let id {
                                // Needs both normal slots filled first.
                                guard ids.count >= 2 else { return }
                                if ids.count > 2 { ids[2] = id } else { ids.append(id) }
                            } else if ids.count > 2 {
                                ids.removeLast()
                            }
                            local?.chargedMoveIds = ids
                        })
                    MegaLevelPicker(level: entry.megaLevel ?? sp.megaLevel,
                                    onSelect: { local?.megaLevel = $0 })
                }
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
                    if let league = entry.league {
                        ivStatsPreview(sp: sp, ivs: ivs, league: league, bestBuddy: entry.isBestBuddy)
                    } else {
                        unclassifiedGrid(sp: sp, ivs: ivs)
                    }
                }
            } else if let league = entry.league {
                Text("Uses the best possible IV spread for \(league.title) League's CP cap.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Pick a league above, or turn on specific IVs to see ranks across all three.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Multi-league rank grid for an unclassified entry — tapping a cell
    /// assigns that league to this bench entry (species/IVs stay the same).
    private func unclassifiedGrid(sp: Pokemon, ivs: IVs) -> some View {
        IVLeagueGridView(
            // A bench entry is an actual caught Pokémon at a known stage —
            // earlier stages in the line aren't reachable from here either.
            family: store.familyIncludingMegas(for: sp.speciesId, excludingPreEvolutions: true),
            ivs: ivs,
            onSelect: { _, league in
                local?.league = League(rawValue: league.cap)
            })
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
            showingDeleteConfirmation = true
        } label: {
            Label("Remove from Bench", systemImage: "trash")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.red)
    }
}

// MARK: - Bench team results sheet

struct IVRow: View {
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
