//
//  OpponentCheckView.swift
//  PokeParty
//
//  "Check Opponent" tab of the Team Builder's detail panel. Mirrors the team
//  editor's three-column layout: fill up to three opponent slots (search, or
//  tap a recently / most-used opponent), tweak each opponent's moveset, and see
//  — under each one — how every member of your current team fares against it.
//  A counts table for your own team sits below. Picks are tracked per format
//  in `OpponentUsageStore`. Toggled alongside `TeamAnalysisSections` from
//  `TeamBuilderDetailView`.
//

import SwiftUI

struct OpponentCheckView: View {
    let store: RankingsStore
    let model: TeamBuilderModel

    @State private var usage = OpponentUsageStore()
    @State private var searchText = ""
    @State private var slots: [TeamMember?] = Array(repeating: nil, count: 3)
    /// Slot replaced when all three are full.
    @State private var activeSlot = 0
    /// `ratings[slot][teamIndex]`, recomputed when the inputs change.
    @State private var ratings: [[Int?]] = Array(repeating: [], count: 3)

    /// Ranked opponents matching the search — restricting to `store.entries`
    /// (rather than every released species) guarantees a moveset + stats
    /// are available once one is picked.
    private var searchResults: [RankingEntry] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return Array(store.entries
            .filter { $0.speciesName.localizedCaseInsensitiveContains(query) }
            .prefix(8))
    }

    private var recentIds: [String] {
        usage.recent(in: store.format).filter { store.pokemonById[$0] != nil }
    }

    private var mostUsed: [(speciesId: String, count: Int)] {
        usage.mostUsed(in: store.format).filter { store.pokemonById[$0.speciesId] != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            searchField
            if !searchResults.isEmpty {
                resultsList
            }
            quickPicks
            HStack(alignment: .top, spacing: 12) {
                ForEach(0..<3, id: \.self) { slot in
                    OpponentColumn(
                        slot: slot, store: store, model: model,
                        member: slots[slot],
                        ratings: ratings[slot],
                        isActive: activeSlot == slot,
                        onActivate: { activeSlot = slot },
                        onChange: { slots[slot] = $0 })
                }
            }
        }
        .onAppear { refreshRatings() }
        .onChange(of: slots) { refreshRatings() }
        .onChange(of: model.members) { refreshRatings() }
        .onChange(of: store.entries) { refreshRatings() }
        .onChange(of: store.format) {
            // Movesets and rankings are per format, so start fresh.
            slots = Array(repeating: nil, count: 3)
            activeSlot = 0
        }
    }

    // MARK: - Picking

    private func pick(_ speciesId: String) {
        guard let member = store.makeMember(speciesId: speciesId) else { return }
        let target = slots.firstIndex(where: { $0 == nil }) ?? activeSlot
        slots[target] = member
        activeSlot = slots.firstIndex(where: { $0 == nil }) ?? target
        usage.record(speciesId, in: store.format)
        searchText = ""
    }

    private func refreshRatings() {
        ratings = slots.map { slot in
            guard let slot, model.hasMembers else { return [] }
            return store.teamRatings(for: model.members, against: slot)
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search opponent Pokémon", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private var resultsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(searchResults) { entry in
                Button {
                    pick(entry.speciesId)
                } label: {
                    HStack(spacing: 8) {
                        if let rank = store.rankBySpeciesId[entry.speciesId] {
                            Text("#\(rank)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 30, alignment: .trailing)
                        }
                        Text(entry.speciesName)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Spacer()
                        if let species = store.pokemonById[entry.speciesId] {
                            TypeBadgeRow(types: species.displayTypes)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Recent / most used

    @ViewBuilder
    private var quickPicks: some View {
        if !recentIds.isEmpty || !mostUsed.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !recentIds.isEmpty {
                    chipRow(title: "Recent", items: recentIds.map { ($0, nil) })
                }
                if !mostUsed.isEmpty {
                    chipRow(title: "Most used", items: mostUsed.map { ($0.speciesId, $0.count) })
                }
            }
        }
    }

    private func chipRow(title: String, items: [(String, Int?)]) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(items, id: \.0) { id, count in
                        Button {
                            pick(id)
                        } label: {
                            HStack(spacing: 4) {
                                Text(store.name(forSpeciesId: id))
                                if let count {
                                    Text("×\(count)").foregroundStyle(.secondary)
                                }
                            }
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

}

// MARK: - Opponent column

private struct OpponentColumn: View {
    let slot: Int
    let store: RankingsStore
    let model: TeamBuilderModel
    let member: TeamMember?
    let ratings: [Int?]
    let isActive: Bool
    let onActivate: () -> Void
    let onChange: (TeamMember?) -> Void

    private var species: Pokemon? { member.flatMap { store.pokemonById[$0.speciesId] } }
    private var recommended: [String] {
        member.flatMap { store.entry(id: $0.speciesId)?.moveset } ?? []
    }

    var body: some View {
        Group {
            if let member, let species {
                filled(member: member, species: species)
            } else {
                empty
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onActivate)
    }

    private var slotLabel: String { slot == 0 ? "LEAD" : "#\(slot + 1)" }

    private var empty: some View {
        VStack(spacing: 6) {
            Text(slotLabel)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Search or tap a recent opponent")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 150)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: isActive ? 2 : 1, dash: [5]))
                .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
        )
    }

    private func filled(member: TeamMember, species: Pokemon) -> some View {
        VStack(alignment: .leading, spacing: 8) {
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
                    onChange(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear this opponent")
            }
            TypeBadgeRow(types: species.displayTypes)
            Divider()
            movesetEditor(member: member, species: species)
            if species.isShadow || species.isShadowEligible || member.shadow {
                Toggle("Shadow", isOn: Binding(
                    get: { member.shadow },
                    set: { var m = member; m.shadow = $0; onChange(m) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)
            }
            Divider()
            Text("Your team")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            teamMatchups(opponent: species, opponentFastId: member.fastMoveId)
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2)
        )
    }

    private func movesetEditor(member: TeamMember, species: Pokemon) -> some View {
        let fastGain = store.move(id: member.fastMoveId)?.energyGain
        return VStack(alignment: .leading, spacing: 6) {
            TeamMovePicker(
                label: "Fast", currentId: member.fastMoveId, optionIds: species.fastMoves,
                recommendedId: recommended.first, includesNone: false,
                species: species, store: store,
                onSelect: { id in
                    guard let id else { return }
                    var m = member; m.fastMoveId = id; onChange(m)
                },
                showsDetail: true)
            TeamMovePicker(
                label: "Charged 1", currentId: member.chargedMoveIds.first ?? "",
                optionIds: species.chargedMoves,
                recommendedId: recommended.count > 1 ? recommended[1] : nil,
                includesNone: false, species: species, store: store,
                onSelect: { id in
                    var m = member; m.setChargedMove(id, slot: 0); onChange(m)
                },
                showsDetail: true, fastEnergyGain: fastGain)
            TeamMovePicker(
                label: "Charged 2",
                currentId: member.chargedMoveIds.count > 1 ? member.chargedMoveIds[1] : "",
                optionIds: species.chargedMoves,
                recommendedId: recommended.count > 2 ? recommended[2] : nil,
                includesNone: true, species: species, store: store,
                onSelect: { id in
                    var m = member; m.setChargedMove(id, slot: 1); onChange(m)
                },
                showsDetail: true, fastEnergyGain: fastGain)
        }
    }

    // MARK: - Team matchups

    @ViewBuilder
    private func teamMatchups(opponent: Pokemon, opponentFastId: String) -> some View {
        Group {
            if model.members.isEmpty {
                Text("Add Pokémon to your team to see whether they beat \(opponent.speciesName).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(model.members.enumerated()), id: \.element.id) { index, teamMember in
                        VStack(alignment: .leading, spacing: 3) {
                            matchupRow(teamMember: teamMember,
                                       rating: ratings.indices.contains(index) ? ratings[index] : nil)
                            throwTiming(teamMember: teamMember, opponentFastId: opponentFastId)
                        }
                    }
                }
            }
        }
    }

    /// When to throw each of the team member's charged moves against this
    /// opponent's fast move, as a running fast-move tally ("3 · 5 · 7 · 9"),
    /// using the same timing window as the battle AI. Shows the energy-only
    /// tally alongside when waiting for the opponent's cycle changes it.
    @ViewBuilder
    private func throwTiming(teamMember: TeamMember, opponentFastId: String) -> some View {
        if let myFast = store.move(id: teamMember.fastMoveId),
           let oppFast = store.move(id: opponentFastId) {
            ForEach(teamMember.chargedMoveIds.filter { !$0.isEmpty }, id: \.self) { id in
                if let move = store.move(id: id),
                   let result = ChargeTiming.throwCounts(cost: move.energy, pokeFast: myFast, opponentFast: oppFast) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(move.name)
                            .font(.caption2.weight(.semibold))
                        Text("throw on")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(ChargeTiming.formatThrowPoints(result.timed))
                            .font(.caption2.weight(.semibold).monospacedDigit())
                        if result.timingMatters {
                            Text("(ready: \(ChargeTiming.formatThrowPoints(result.ready)))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else {
                            Text("no timing needed")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .help("Fast-move number to throw on, timed so the opponent's fast move can't land during your charged move. Assumes both sides are farming from the same start.")
                }
            }
        }
    }

    private func matchupRow(teamMember: TeamMember, rating: Int?) -> some View {
        let name = store.pokemonById[teamMember.speciesId]?.speciesName ?? teamMember.speciesId
        return HStack(spacing: 6) {
            Text(name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let rating {
                RatingBar(rating: rating)
                    .frame(width: 50)
                Text("\(rating)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(rating > 500 ? Theme.win : Theme.loss)
                    .frame(width: 30, alignment: .trailing)
                Image(systemName: rating > 500 ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(rating > 500 ? Theme.win : Theme.loss)
            } else {
                Text("No data")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
