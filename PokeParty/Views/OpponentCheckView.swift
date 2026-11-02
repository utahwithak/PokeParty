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

import StoreKit
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
    /// Forms of a just-detected opponent when the screen's name alone can't
    /// say which one it is (Zacian, Kyurem, Necrozma…); the user taps one.
    @State private var formChoices: [Pokemon] = []
    @State private var detectionNote: String?
    #if DEBUG
    /// Measured type-icon colours of the last detection, for calibrating `TypeColors`.
    @State private var lastIconSummary = ""
    #endif
    #if os(iOS)
    @Environment(OpponentScanModel.self) private var scan
    #else
    @Environment(EntitlementStore.self) private var entitlements
    @State private var phoneLink = PhoneLinkServer()
    @State private var showPhoneLinkInfo = false
    #endif

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
            #if os(iOS)
            scanHint
            #else
            if entitlements.isUnlocked {
                phoneLinkRow
            } else {
                lockedPhoneLinkRow
            }
            #endif
            detectionFeedback
            searchField
            if !searchResults.isEmpty {
                resultsList
            }
            quickPicks
            if slots.contains(where: { $0 != nil }) {
                Button(role: .destructive) {
                    slots = Array(repeating: nil, count: 3)
                    activeSlot = 0
                } label: {
                    Label("Clear all opponents", systemImage: "xmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
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
            formChoices = []
        }
        #if os(iOS)
        .onAppear { takeScanned() }
        .onChange(of: scan.detections.first?.id) { takeScanned() }
        #else
        // The listener only runs while this screen is up.
        // Pro only: without it the row below just explains the feature.
        .onAppear { if entitlements.isUnlocked { phoneLink.start() } }
        .onDisappear { phoneLink.stop() }
        .onChange(of: entitlements.isUnlocked) { _, unlocked in
            if unlocked { phoneLink.start() } else { phoneLink.stop() }
        }
        .onChange(of: phoneLink.latest) { _, detection in
            if let detection { handle(detection) }
        }
        #endif
    }

    // MARK: - Detection feedback (both platforms)

    /// What was just detected, plus a form picker when the name alone is ambiguous.
    @ViewBuilder
    private var detectionFeedback: some View {
        if detectionNote != nil || !formChoices.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if let detectionNote {
                    Text(detectionNote).font(.caption).foregroundStyle(.secondary)
                }
                if !formChoices.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Which form?")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(formChoices) { form in
                                    Button {
                                        pick(form.speciesId)
                                        formChoices = []
                                    } label: {
                                        Text(form.speciesName)
                                            .font(.caption.weight(.medium))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    #if os(macOS)
    // MARK: - iPhone link (macOS)

    private var phoneLinkStatus: (text: String, color: Color) {
        if let name = phoneLink.phoneName { return ("Connected to \(name)", .green) }
        switch phoneLink.state {
        case .listening: return ("Waiting for iPhone", .orange)
        case .failed: return ("iPhone link unavailable", .red)
        case .stopped: return ("iPhone link off", .secondary)
        }
    }

    /// Shown instead of the connection row when Pro isn't unlocked, so the
    /// feature is discoverable while Check Opponent itself stays fully usable.
    private var lockedPhoneLinkRow: some View {
        DisclosureGroup(isExpanded: $showPhoneLinkInfo) {
            VStack(alignment: .leading, spacing: 8) {
                Text("With PokeParty Pro, Screen Scan on your iPhone reads the opponent from your Pokémon GO battle and sends it here, filling in these slots automatically.")
                Text("One purchase unlocks Pro on iPhone and Mac. Check Opponent works the same without it — just pick opponents yourself.")
                Button {
                    Task { await entitlements.purchase() }
                } label: {
                    if let price = entitlements.product?.displayPrice {
                        Text("Unlock PokeParty Pro · \(price)")
                    } else {
                        Text("Unlock PokeParty Pro")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(entitlements.isPurchasing || entitlements.product == nil)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .foregroundStyle(.yellow)
                Text("Detect opponents from your iPhone — Pro")
                    .font(.subheadline.weight(.medium))
            }
        }
        .padding(10)
        .background(Color.yellow.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.yellow.opacity(0.45), lineWidth: 1))
    }

    /// "Connected to <phone>" with a disclosure explaining the feature.
    private var phoneLinkRow: some View {
        let status = phoneLinkStatus
        return DisclosureGroup(isExpanded: $showPhoneLinkInfo) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your iPhone can send the opponent it sees in a Pokémon GO battle straight to this Mac, which fills in the opponent slots below.")
                Text("On iPhone: open PokeParty → Check Opponent → Detect from screen, choose Entire Screen, then start a battle. Both devices need to be on the same Wi-Fi network, and the iPhone needs iOS 27.")
                if case .failed(let message) = phoneLink.state {
                    Text(message).foregroundStyle(.red)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
                Text(status.text)
                    .font(.subheadline.weight(.medium))
                Circle().fill(status.color).frame(width: 8, height: 8)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
    #endif

    #if os(iOS)
    // MARK: - Screen Scan hand-off (iOS)

    /// Points at the Screen Scan tool until a scan is running.
    @ViewBuilder
    private var scanHint: some View {
        if scan.isScanning {
            Label("Screen Scan is running — opponents appear here as you battle.", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label("Open Screen Scan to detect opponents from Pokémon GO.", systemImage: "viewfinder")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Resolves anything Screen Scan found since this screen last looked.
    private func takeScanned() {
        for detection in scan.takeUntaken() { handle(detection) }
    }
    #endif

    // MARK: - Resolving a detection

    /// Resolves a detected name to a species: a single match fills the next
    /// slot straight away, several (alternate forms) ask the user to choose.
    private func handle(_ detection: OpponentDetection) {
        let ranked = store.entries.compactMap { store.pokemonById[$0.speciesId] }
        let byName = OpponentNameMatcher.candidates(for: detection.name, in: ranked)
        // The type icons separate regional variants the name can't (Ninetales, Golem…).
        let matches = OpponentNameMatcher.narrow(byName, byIcons: detection.icons)
        let usedTypes = matches.count < byName.count
        let cp = detection.cp.map { " (CP \($0))" } ?? ""

        // Opponents swap in and out mid-battle, so the same one is seen again
        // and again. If any form of it already sits in a slot — including a
        // variant the user switched it to — leave the slots alone.
        let matchIds = Set(matches.map(\.speciesId))
        if let existing = slots.firstIndex(where: { $0.map { matchIds.contains($0.speciesId) } ?? false }),
           let present = slots[existing] {
            formChoices = []
            detectionNote = "\(store.name(forSpeciesId: present.speciesId))\(cp) is already in slot \(existing + 1)."
            return
        }
        switch matches.count {
        case 0:
            formChoices = []
            detectionNote = "Saw “\(detection.name)”\(cp) but couldn't match it to a ranked Pokémon in this format."
        case 1:
            formChoices = []
            detectionNote = "Detected \(matches[0].speciesName)\(cp)\(usedTypes ? ", form chosen by type" : "")."
            pick(matches[0].speciesId)
        default:
            let rank = store.rankBySpeciesId
            formChoices = matches.sorted { (rank[$0.speciesId] ?? .max) < (rank[$1.speciesId] ?? .max) }
            detectionNote = "Detected \(detection.name)\(cp) — pick the form."
        }
        #if DEBUG
        lastIconSummary = detection.iconSummary
        #endif
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
                        speciesTitle(member: member, species: species)
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

    /// The species name — a drop-down of its variants when there are any.
    @ViewBuilder
    private func speciesTitle(member: TeamMember, species: Pokemon) -> some View {
        let options = variants(of: species)
        if options.count > 1 {
            Menu {
                ForEach(options) { option in
                    Button {
                        guard option.speciesId != species.speciesId,
                              var replacement = store.makeMember(speciesId: option.speciesId) else { return }
                        // Keep the Shadow toggle across forms that can still be Shadow.
                        let target = store.pokemonById[option.speciesId]
                        replacement.shadow = member.shadow && (target?.isShadowEligible ?? false)
                        onChange(replacement)
                    } label: {
                        if option.speciesId == species.speciesId {
                            Label(option.speciesName, systemImage: "checkmark")
                        } else {
                            Text(option.speciesName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(species.speciesName)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Switch to a different form")
        } else {
            Text(species.speciesName)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
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

/// Two-lane timeline of the optimal throw timing: the top lane is your fast
/// moves (the highlighted cell is where the charged move goes), the bottom
/// lane is the opponent's fast moves. Cell widths are proportional to
/// duration, so you can see where the opponent's move lands relative to yours.
private struct ThrowTimingDiagram: View {
    let timed: [Int]
    let pokeFast: Move
    let opponentFast: Move

    private static let laneHeight: CGFloat = 14

    private struct Cell: Identifiable {
        let id: Int
        let turns: Int
        let isCharged: Bool
    }

    /// Own lane: `timed[i]` fast moves then a one-turn charged move,     /// many throws as fit (at least one, at most three).
    private var ownCells: [Cell] {
        var cells: [Cell] = []
        let pokeTurns = pokeFast.cooldown / 500
        for count in timed {
            for _ in 0..<count { cells.append(Cell(id: cells.count, turns: pokeTurns, isCharged: false)) }
            cells.append(Cell(id: cells.count, turns: 1, isCharged: true))
        }
        return cells
    }

    var body: some View {
        let own = ownCells
        let totalTurns = max(1, own.reduce(0) { $0 + $1.turns })
        let oppTurns = max(1, opponentFast.cooldown / 500)
        let oppCells = (0..<Int((Double(totalTurns) / Double(oppTurns)).rounded(.up)))
            .map { Cell(id: $0, turns: oppTurns, isCharged: false) }

        VStack(spacing: 2) {
            lane(own, totalTurns: totalTurns, fill: Color.yellow.opacity(0.25), highlight: Color.yellow.opacity(0.85))
            lane(oppCells, totalTurns: totalTurns, fill: Color.orange.opacity(0.65), highlight: .orange)
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.4), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Optimal move timing: throw after \(ChargeTiming.formatThrowPoints(timed)) fast moves")
    }

    private func lane(_ cells: [Cell], totalTurns: Int, fill: Color, highlight: Color) -> some View {
        GeometryReader { geo in
            let unit = geo.size.width / CGFloat(totalTurns)
            HStack(spacing: 0) {
                ForEach(cells) { cell in
                    Rectangle()
                        .fill(cell.isCharged ? highlight : fill)
                        .overlay(Rectangle().stroke(cell.isCharged ? Color.primary.opacity(0.8) : Color.secondary.opacity(0.5),
                                                    lineWidth: cell.isCharged ? 1.5 : 1))
                        .frame(width: unit * CGFloat(cell.turns))
                }
            }
            .frame(width: geo.size.width, alignment: .leading)
            .clipped()
        }
        .frame(height: Self.laneHeight)
    }
}
