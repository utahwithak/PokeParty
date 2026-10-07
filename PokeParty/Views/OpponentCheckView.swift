//
//  OpponentCheckView.swift
//  PokeParty
//
//  "Check Opponent" tab of the Team Builder's detail panel: search for a
//  single opponent and see its common (recommended) moveset — with fast/
//  charge move counts — plus whether any of your current team members beat
//  it. Toggled alongside `TeamAnalysisSections` from `TeamBuilderDetailView`.
//

import SwiftUI

struct OpponentCheckView: View {
    let store: RankingsStore
    let model: TeamBuilderModel

    @State private var searchText = ""
    @State private var selectedId: String?

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

    private var selectedEntry: RankingEntry? {
        selectedId.flatMap { store.entry(id: $0) }
    }
    private var selectedSpecies: Pokemon? {
        selectedId.flatMap { store.pokemonById[$0] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            searchField
            if !searchResults.isEmpty {
                resultsList
            }
            if let entry = selectedEntry, let species = selectedSpecies {
                opponentDetail(entry: entry, species: species)
            } else if selectedId == nil {
                ContentUnavailableView(
                    "Search for an Opponent",
                    systemImage: "magnifyingglass",
                    description: Text("Find a Pokémon to see its common moveset and how your current team matches up against it."))
                .frame(maxWidth: .infinity, minHeight: 160)
            }
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
                    selectedId = entry.speciesId
                    searchText = ""
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

    // MARK: - Opponent detail

    private func opponentDetail(entry: RankingEntry, species: Pokemon) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            header(entry: entry, species: species)
            movesetSection(entry: entry, species: species)
            teamSection(entry: entry)
        }
    }

    private func header(entry: RankingEntry, species: Pokemon) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.speciesName)
                    .font(.title3.weight(.semibold))
                TypeBadgeRow(types: species.displayTypes)
            }
            Spacer()
            Button {
                selectedId = nil
            } label: {
                Label("Change", systemImage: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Moveset

    @ViewBuilder
    private func movesetSection(entry: RankingEntry, species: Pokemon) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Common Moveset")
                .font(.title3.weight(.semibold))
            if entry.moveset.isEmpty {
                Text("No moveset data available.")
                    .foregroundStyle(.secondary)
            } else {
                let fastId = entry.moveset[0]
                let fastMove = store.move(id: fastId)
                if let fastMove {
                    moveRow(id: fastId, move: fastMove, species: species, fastEnergyGain: nil)
                }
                ForEach(Array(entry.moveset.dropFirst()), id: \.self) { id in
                    if let move = store.move(id: id) {
                        moveRow(id: id, move: move, species: species, fastEnergyGain: fastMove?.energyGain)
                    }
                }
            }
        }
    }

    private func moveRow(id: String, move: Move, species: Pokemon, fastEnergyGain: Int?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(move.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let designation = species.moveDesignation(for: id) {
                    Text("(\(designation.label))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(designation.help)
                }
                TypeBadge(type: move.type)
                Spacer()
            }
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
                    if let countText = move.chargeCounts(fastEnergyGain: fastEnergyGain) {
                        MoveStat(label: "COUNT", value: countText, color: Theme.moveDuration,
                                 help: "Count — fast moves needed to reach this move on each of the next 5 throws, carrying leftover energy between them.")
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Your team

    @ViewBuilder
    private func teamSection(entry: RankingEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your Team")
                .font(.title3.weight(.semibold))
            if model.members.isEmpty {
                Text("Add Pokémon to your team to see whether they beat \(entry.speciesName).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let ratings = store.teamRatings(for: model.members, against: entry.speciesId)
                ForEach(Array(model.members.enumerated()), id: \.element.id) { index, member in
                    teamRow(member: member, opponentName: entry.speciesName,
                            rating: ratings.indices.contains(index) ? ratings[index] : nil)
                }
            }
        }
    }

    private func teamRow(member: TeamMember, opponentName: String, rating: Int?) -> some View {
        let species = store.pokemonById[member.speciesId]
        let name = species?.speciesName ?? member.speciesId
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(name)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        if member.shadow { ShadowBadge() }
                    }
                    if let species {
                        TypeBadgeRow(types: species.displayTypes)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let rating {
                    RatingBar(rating: rating)
                        .frame(width: 90)
                    Text("\(rating)")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(rating > 500 ? Theme.win : Theme.loss)
                        .frame(width: 44, alignment: .trailing)
                    Image(systemName: rating > 500 ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(rating > 500 ? Theme.win : Theme.loss)
                } else {
                    Text("No data")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let rating {
                Text(matchupSummary(member: name, opponent: opponentName, rating: rating))
                    .font(.caption)
                    .foregroundStyle(rating > 500 ? Theme.win : Theme.loss)
            }
        }
        .padding(.vertical, 2)
    }

    /// A plain-language read on the rating, matching the band thresholds
    /// `ThreatRatingChip` already uses for its color bands (just phrased
    /// from the team member's perspective instead of the threat's).
    private func matchupSummary(member: String, opponent: String, rating: Int) -> String {
        switch rating {
        case 750...:    return "\(member) is a hard counter to \(opponent)"
        case 501..<750: return "\(member) has a favorable matchup against \(opponent)"
        case 250..<501: return "\(member) is at a disadvantage against \(opponent)"
        default:        return "\(member) is hard countered by \(opponent)"
        }
    }
}
