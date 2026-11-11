//
//  OpponentColumnView.swift
//  PokeParty
//
//  One side of the Check Opponent comparison.
//

import StoreKit
import SwiftUI

struct OpponentColumn: View {
    let slot: Int
    let store: RankingsStore
    let model: TeamBuilderModel
    let member: TeamMember?
    let ratings: [Int?]
    let cmp: [CMPOutlook?]
    /// Charged moves seen thrown or chosen by hand; the others are guesses and show lighter.
    let confirmedCharged: Set<String>
    /// Whether the fast move was chosen by hand (it's never read from a banner).
    let fastConfirmed: Bool
    let isActive: Bool
    let isFainted: Bool
    let isLead: Bool
    let onActivate: () -> Void
    let onSetLead: () -> Void
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
        .opacity(isFainted ? 0.4 : 1)
        .overlay(alignment: .topTrailing) {
            if isFainted { FaintedBadge().padding(8) }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onActivate)
    }

    private var slotLabel: String { isLead ? "LEAD" : "#\(slot + 1)" }

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
                    HStack(spacing: 6) {
                        Text(slotLabel)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(isLead ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        if !isLead {
                            Button("Set lead", action: onSetLead)
                                .font(.caption2)
                                .buttonStyle(.plain)
                                .foregroundStyle(.tint)
                        }
                    }
                    HStack(spacing: 4) {
                        speciesTitle(member: member, species: species)
                        if member.shadow || species.isShadow { ShadowBadge() }
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
            variantChips(member: member, species: species)
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

    /// Ranked species whose name contains this one's base name — "Palkia"
    /// offers "Palkia (Origin)" and vice versa — so a wrong form, whether
    /// auto-detected or picked, can be switched in place.
    private func variants(of species: Pokemon) -> [RankingEntry] {
        let base = species.speciesName
            .split(separator: "(", maxSplits: 1, omittingEmptySubsequences: false).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? species.speciesName
        guard !base.isEmpty else { return [] }
        let rank = store.rankBySpeciesId
        return store.entries
            .filter { $0.speciesName.localizedCaseInsensitiveContains(base) }
            .sorted { (rank[$0.speciesId] ?? .max) < (rank[$1.speciesId] ?? .max) }
    }

    /// The species name. Its other forms are shown as chips under the type badges.
    private func speciesTitle(member: TeamMember, species: Pokemon) -> some View {
        // The flame badge already says Shadow.
        Text(species.speciesName.replacingOccurrences(of: " (Shadow)", with: ""))
            .font(.headline)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    /// Other forms of this species, as chips right in the cell — so a wrong form
    /// can be fixed without opening the search. Shadow forms are left to the
    /// Shadow toggle.
    @ViewBuilder
    private func variantChips(member: TeamMember, species: Pokemon) -> some View {
        let options = variants(of: species).filter { store.pokemonById[$0.speciesId]?.isShadow != true }
        if options.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(options) { option in
                        let selected = option.speciesId == species.speciesId
                        Button {
                            guard !selected, var replacement = store.makeMember(speciesId: option.speciesId) else { return }
                            // Keep the Shadow toggle across forms that can still be Shadow.
                            let target = store.pokemonById[option.speciesId]
                            replacement.shadow = member.shadow && (target?.isShadowEligible ?? false)
                            onChange(replacement)
                        } label: {
                            Text(formLabel(option.speciesName, of: species))
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(selected ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.07), in: Capsule())
                                .overlay(Capsule().stroke(selected ? Color.accentColor : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .help("Switch to a different form")
        }
    }

    /// "Ninetales (Alolan)" → "Alolan"; the plain species → "Standard".
    private func formLabel(_ name: String, of species: Pokemon) -> String {
        if let open = name.firstIndex(of: "("), let close = name.lastIndex(of: ")"), open < close {
            return String(name[name.index(after: open)..<close])
        }
        let base = species.speciesName
            .split(separator: "(", maxSplits: 1, omittingEmptySubsequences: false).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? species.speciesName
        return name.caseInsensitiveCompare(base) == .orderedSame ? "Standard" : name
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
                showsDetail: true, isGuess: !fastConfirmed)
            TeamMovePicker(
                label: "Charged 1", currentId: member.chargedMoveIds.first ?? "",
                optionIds: species.chargedMoves,
                recommendedId: recommended.count > 1 ? recommended[1] : nil,
                includesNone: false, species: species, store: store,
                onSelect: { id in
                    var m = member; m.setChargedMove(id, slot: 0); onChange(m)
                },
                showsDetail: true, fastEnergyGain: fastGain,
                isGuess: !confirmedCharged.contains(member.chargedMoveIds.first ?? ""))
            TeamMovePicker(
                label: "Charged 2",
                currentId: member.chargedMoveIds.count > 1 ? member.chargedMoveIds[1] : "",
                optionIds: species.chargedMoves,
                recommendedId: recommended.count > 2 ? recommended[2] : nil,
                includesNone: true, species: species, store: store,
                onSelect: { id in
                    var m = member; m.setChargedMove(id, slot: 1); onChange(m)
                },
                showsDetail: true, fastEnergyGain: fastGain,
                isGuess: !confirmedCharged.contains(member.chargedMoveIds.count > 1 ? member.chargedMoveIds[1] : ""))
            if species.hasThirdChargedMove {
                TeamMovePicker(
                    label: "Charged 3",
                    currentId: member.chargedMoveIds.count > 2 ? member.chargedMoveIds[2] : "",
                    optionIds: species.extraChargedMoves ?? [],
                    recommendedId: recommended.count > 3 ? recommended[3] : nil,
                    includesNone: true, species: species, store: store,
                    onSelect: { id in
                        var m = member; m.setChargedMove(id, slot: 2); onChange(m)
                    },
                    showsDetail: true, fastEnergyGain: fastGain)
                MegaLevelPicker(level: member.megaLevel ?? species.megaLevel,
                                onSelect: { var m = member; m.megaLevel = $0; onChange(m) })
            }
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
                                       rating: ratings.indices.contains(index) ? ratings[index] : nil,
                                       cmp: cmp.indices.contains(index) ? cmp[index] : nil)
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
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(move.name)
                                .font(.caption2.weight(.semibold))
                            Text("throw after")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(ChargeTiming.formatThrowPoints(Array(result.timed.prefix(3))))
                                .font(.caption2.weight(.semibold).monospacedDigit())
                        }
                        if result.timingMatters {
                            ThrowTimingDiagram(timed: Array(result.timed.prefix(3)), pokeFast: myFast, opponentFast: oppFast)
                        }
                    }
                    .help("Fast-move number to throw on, timed so the opponent's fast move can't land during your charged move. Assumes both sides are farming from the same start.")
                }
            }
        }
    }

    private func matchupRow(teamMember: TeamMember, rating: Int?, cmp: CMPOutlook?) -> some View {
        let name = store.pokemonById[teamMember.speciesId]?.speciesName ?? teamMember.speciesId
        return HStack(spacing: 6) {
            Text(name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let cmp { CMPBadge(outlook: cmp) }
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
