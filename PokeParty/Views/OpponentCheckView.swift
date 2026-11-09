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
    /// Called with the opponents currently in the slots (in slot order) whenever they change.
    var onOpponentsChange: (([TeamMember]) -> Void)?
    /// Fast moves inferred in battle (species id → move id), applied to the matching slots.
    var observedFastMoves: [String: String] = [:]
    /// Charged moves seen thrown in battle (species id → move ids), put into the matching slots.
    var seenChargedMoves: [String: [String]] = [:]
    /// Called with the species an opponent was just detected or picked as — the one on the field.
    var onActiveOpponent: ((String) -> Void)?
    /// Changing this clears the opponents — lets the host trigger a new battle.
    var resetToken: UUID?
    /// Indices (in slot order, counting only filled slots) of opponents that have
    /// fainted; their cells are greyed out.
    var faintedOpponents: Set<Int> = []

    @State private var usage = OpponentUsageStore()
    @State private var searchText = ""
    /// Whether the search box and recent / most-used lists are showing. Remembered,
    /// since with a live scan running they're rarely needed.
    @AppStorage("OpponentCheck.showPicker") private var showPicker = true
    @State private var slots: [TeamMember?] = Array(repeating: nil, count: 3)
    /// Slot replaced when all three are full.
    @State private var activeSlot = 0
    /// Slot holding the opponent's lead — the first one picked or detected
    /// once the slots were empty (a new battle). The user can reassign it.
    @State private var leadSlot: Int?
    /// Species whose fast move the user chose by hand, so the in-battle guess leaves it alone.
    @State private var userSetFastMoves: Set<String> = []
    /// Charged moves the user chose by hand, per species. Those count as confirmed.
    @State private var userSetCharged: [String: Set<String>] = [:]
    /// Species credited as lead in `usage`, so reassigning the lead moves the credit.
    @State private var recordedLead: String?
    /// `ratings[slot][teamIndex]`, recomputed when the inputs change.
    @State private var ratings: [[Int?]] = Array(repeating: [], count: 3)
    /// `cmp[slot][teamIndex]`: who wins a charge move priority tie, recomputed with `ratings`.
    @State private var cmp: [[CMPOutlook?]] = Array(repeating: [], count: 3)
    /// Forms of a just-detected opponent when the screen's name alone can't
    /// say which one it is (Zacian, Kyurem, Necrozma…); the user taps one.
    @State private var formChoices: [Pokemon] = []
    @State private var detectionNote: String?
    #if DEBUG
    /// Measured type-icon colours of the last detection, for calibrating `TypeColors`.
    @State private var lastIconSummary = ""
    #endif
    /// Owned by `BattleHUDDetailView`, which also shows the connection status.
    /// Nil where nothing is listening for a phone (the Team Builder's tab on iPhone).
    var phoneLink: PhoneLinkServer? = nil
    #if os(iOS)
    @Environment(OpponentScanModel.self) private var scan
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

    @ViewBuilder
    private var opponentColumns: some View {
        ForEach(0..<3, id: \.self) { slot in
            OpponentColumn(
                slot: slot, store: store, model: model,
                member: slots[slot],
                ratings: ratings[slot],
                cmp: cmp[slot],
                confirmedCharged: slots[slot].map { member in
                    Set(seenChargedMoves[member.speciesId] ?? []).union(userSetCharged[member.speciesId] ?? [])
                } ?? [],
                fastConfirmed: slots[slot].map { userSetFastMoves.contains($0.speciesId) } ?? false,
                isActive: activeSlot == slot,
                isFainted: isFainted(slot),
                isLead: isLead(slot),
                onActivate: { activeSlot = slot },
                onSetLead: { setLead(slot) },
                onChange: { change(slot, to: $0) })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            #if os(iOS)
            scanHint
            #endif
            detectionFeedback
            DisclosureGroup(isExpanded: $showPicker) {
                VStack(alignment: .leading, spacing: 16) {
                    searchField
                    if !searchResults.isEmpty {
                        resultsList
                    }
                    quickPicks
                    leadHistory
                }
                .padding(.top, 8)
            } label: {
                Label("Search & recent opponents", systemImage: "magnifyingglass")
                    .font(.subheadline.weight(.medium))
            }
            if slots.contains(where: { $0 != nil }) {
                Button(role: .destructive) {
                    clearOpponents()
                } label: {
                    Label("Clear all opponents", systemImage: "xmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            // Side by side when wide; stacked when the window is too narrow for three columns.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { opponentColumns }
                VStack(spacing: 12) { opponentColumns }
            }
        }
        .onAppear { refreshRatings() }
        .onChange(of: resetToken) { clearOpponents() }
        .onChange(of: observedFastMoves) { _, moves in
            for (speciesId, moveId) in moves {
                // A fast move picked by hand beats the guess from what hit you.
                guard !userSetFastMoves.contains(speciesId),
                      let slot = slots.firstIndex(where: { $0?.speciesId == speciesId }),
                      slots[slot]?.fastMoveId != moveId else { continue }
                slots[slot]?.fastMoveId = moveId
            }
        }
        .onChange(of: seenChargedMoves) { applySeenMoves() }
        .onChange(of: slots) {
            applySeenMoves()
            refreshRatings()
            onOpponentsChange?(slots.compactMap { $0 })
        }
        .onChange(of: model.members) { refreshRatings() }
        .onChange(of: store.entries) { refreshRatings() }
        .onChange(of: store.format) {
            // Movesets and rankings are per format, so start fresh.
            slots = Array(repeating: nil, count: 3)
            userSetFastMoves = []
        userSetCharged = [:]
            activeSlot = 0
            leadSlot = nil
            recordedLead = nil
            formChoices = []
        }
        #if os(iOS)
        .onAppear { takeScanned() }
        .onChange(of: scan.detections.first?.id) { takeScanned() }
        #endif
        .onChange(of: phoneLink?.latest) { _, detection in
            if let detection { handle(detection) }
        }
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
            Label(phoneLink == nil
                  ? "Open Screen Scan to detect opponents from Pokémon GO."
                  : "Begin Scan above to detect opponents from Pokémon GO.",
                  systemImage: "viewfinder")
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
        let ranked = store.opponentPool(forName: detection.name)
        let byName = OpponentNameMatcher.candidates(for: detection.name, in: ranked)
        // An exact name ("Corsola") doesn't list its regional variants, but the
        // screen may not show the prefix, so let the icons choose among the family.
        let family = OpponentNameMatcher.family(of: byName, in: ranked)
        // The type icons separate regional variants the name can't (Ninetales, Golem…).
        let matches = OpponentNameMatcher.narrow(detection.icons.isEmpty ? byName : family, byIcons: detection.icons)
        let usedTypes = matches.count < family.count
        let cp = detection.cp.map { " (CP \($0))" } ?? ""

        // Opponents swap in and out mid-battle, so the same one is seen again
        // and again. If any form of it already sits in a slot — including a
        // variant the user switched it to — leave the slots alone. The whole
        // family counts, not just the forms this sighting resolved to: after
        // switching Corsola to Galarian, the name still reads "Corsola".
        let matchIds = Set(family.map(\.speciesId))
        if let existing = slots.firstIndex(where: { $0.map { matchIds.contains($0.speciesId) } ?? false }),
           let present = slots[existing] {
            formChoices = []
            detectionNote = "\(store.name(forSpeciesId: present.speciesId))\(cp) is already in slot \(existing + 1)."
            onActiveOpponent?(present.speciesId)
            return
        }
        switch matches.count {
        case 0:
            formChoices = []
            detectionNote = "Saw “\(detection.name)”\(cp) but couldn't match it to a Pokémon."
        case 1:
            formChoices = []
            detectionNote = "Detected \(matches[0].speciesName)\(cp)\(usedTypes ? ", form chosen by type" : "")."
            pick(matches[0].speciesId, fromDetection: true)
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

    /// The marked lead, or — before anything is picked — the first slot,
    /// since whatever is picked first will become the lead.
    private func isLead(_ slot: Int) -> Bool {
        if let leadSlot { return leadSlot == slot }
        return slot == 0 && slots.allSatisfy { $0 == nil }
    }

    /// Marks `slot` as the lead and credits it in the lead history, moving
    /// the credit from any previously marked lead.
    private func setLead(_ slot: Int) {
        guard let id = slots[slot]?.speciesId else { return }
        leadSlot = slot
        if let recordedLead { usage.unrecordLead(recordedLead, in: store.format) }
        usage.recordLead(id, in: store.format)
        recordedLead = id
    }

    /// Applies an edit to a slot. Switching to another form moves the usage
    /// counts to it; clearing the lead slot unmarks the lead.
    private func change(_ slot: Int, to member: TeamMember?) {
        if let old = slots[slot]?.speciesId, let new = member?.speciesId, old != new {
            let wasLead = leadSlot == slot
            usage.replace(old, with: new, isLead: wasLead, in: store.format)
            if wasLead { recordedLead = new }
        }
        if let old = slots[slot], let member, old.speciesId == member.speciesId,
           old.fastMoveId != member.fastMoveId {
            userSetFastMoves.insert(member.speciesId)
        }
        if let old = slots[slot], let member, old.speciesId == member.speciesId {
            let added = Set(member.chargedMoveIds).subtracting(old.chargedMoveIds).subtracting([""])
            if !added.isEmpty { userSetCharged[member.speciesId, default: []].formUnion(added) }
        }
        slots[slot] = member
        if member == nil, leadSlot == slot { leadSlot = nil }
    }

    /// Puts the charged moves seen thrown into their slots: seen moves first, then
    /// moves the user picked, then the rest of the guess. Moves a Mega has in a third
    /// slot are left alone. Leaves the slot untouched when nothing would change.
    private func applySeenMoves() {
        for index in slots.indices {
            guard let member = slots[index], member.chargedMoveIds.count <= 2,
                  let seen = seenChargedMoves[member.speciesId], !seen.isEmpty else { continue }
            let known = store.pokemonById[member.speciesId]?.chargedMoves ?? []
            let thrown = seen.filter { known.contains($0) }
            let chosen = userSetCharged[member.speciesId] ?? []
            let rest = member.chargedMoveIds.filter { !thrown.contains($0) }
            let ordered = thrown + rest.filter { chosen.contains($0) } + rest.filter { !chosen.contains($0) }
            let updated = Array(ordered.prefix(max(2, thrown.count)))
            if updated != member.chargedMoveIds { slots[index]?.chargedMoveIds = updated }
        }
    }

    /// Whether the user changed this opponent's moves or Shadow from the defaults.
    private func isCustomized(_ member: TeamMember) -> Bool {
        guard let standard = store.makeMember(speciesId: member.speciesId) else { return false }
        return member.fastMoveId != standard.fastMoveId
            || member.chargedMoveIds != standard.chargedMoveIds
            || member.shadow != standard.shadow
    }

    /// Picks an opponent into a slot. A detection (`fromDetection`) never writes over
    /// a slot the user has set up: with all three full it takes an untouched one, or
    /// does nothing. Picking by hand still replaces the active slot.
    private func pick(_ speciesId: String, fromDetection: Bool = false) {
        guard let member = store.makeMember(speciesId: speciesId) else { return }
        var target = slots.firstIndex(where: { $0 == nil }) ?? activeSlot
        if fromDetection, slots[target] != nil {
            let untouched = slots.indices.filter { slots[$0].map { !isCustomized($0) } ?? true }
            guard let free = untouched.contains(activeSlot) ? activeSlot : untouched.first else {
                detectionNote = "\(store.name(forSpeciesId: speciesId)) isn't in the opponent slots, and all three have custom moves, so nothing was replaced."
                return
            }
            target = free
        }
        let isNewBattle = slots.allSatisfy { $0 == nil }
        slots[target] = member
        activeSlot = slots.firstIndex(where: { $0 == nil }) ?? target
        usage.record(speciesId, in: store.format)
        if isNewBattle { setLead(target) }
        onActiveOpponent?(speciesId)
        searchText = ""
    }

    /// Whether the opponent in `slot` has fainted (see `faintedOpponents`).
    private func isFainted(_ slot: Int) -> Bool {
        guard slots.indices.contains(slot), slots[slot] != nil else { return false }
        let position = slots[..<slot].filter { $0 != nil }.count
        return faintedOpponents.contains(position)
    }

    /// Empties the opponent slots and the notes about them.
    private func clearOpponents() {
        slots = Array(repeating: nil, count: 3)
        userSetFastMoves = []
        userSetCharged = [:]
        activeSlot = 0
        leadSlot = nil
        recordedLead = nil
        formChoices = []
        detectionNote = nil
    }

    private func refreshRatings() {
        ratings = slots.map { slot in
            guard let slot, model.hasMembers else { return [] }
            return store.teamRatings(for: model.members, against: slot)
        }
        let cap = store.format.cp
        cmp = slots.map { slot in
            guard let slot, model.hasMembers, let species = store.pokemonById[slot.speciesId],
                  let theirs = CMPOutlook.attackRange(
                    species: species, shadow: slot.shadow, megaLevel: slot.megaLevel,
                    isBestBuddy: false, ivs: nil, cpCap: cap)
            else { return [] }
            return model.members.map { member in
                guard let mine = store.pokemonById[member.speciesId],
                      let range = CMPOutlook.attackRange(
                        species: mine, shadow: member.shadow, megaLevel: member.megaLevel,
                        isBestBuddy: member.isBestBuddy, ivs: member.ivs, cpCap: cap)
                else { return nil }
                return CMPOutlook.compare(mine: range, theirs: theirs)
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
                .autocorrectionDisabled()
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

    /// Recent leads with how often each has led — a very common starter stands out.
    @ViewBuilder
    private var leadHistory: some View {
        let leads = usage.recentLeads(in: store.format).filter { store.pokemonById[$0.speciesId] != nil }
        if !leads.isEmpty {
            chipRow(title: "Leads", items: leads.map { ($0.speciesId, $0.count) })
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
        Text(species.speciesName)
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

/// Small "CMP" tag: whether you win a simultaneous charged-move tie against this opponent.
private struct CMPBadge: View {
    let outlook: CMPOutlook

    private var detail: (symbol: String, color: Color, help: String) {
        switch outlook {
        case .alwaysWins:
            ("checkmark", Theme.win, "Always wins charge move priority: higher Attack than this opponent at any IVs.")
        case .ivDependent:
            ("questionmark", .orange, "Charge move priority depends on IVs: the Attack ranges overlap.")
        case .cannotWin:
            ("xmark", Theme.loss, "Can't win charge move priority: lower Attack than this opponent at any IVs.")
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            Text("CMP")
            Image(systemName: detail.symbol)
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(detail.color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(detail.color.opacity(0.15), in: Capsule())
        .help(detail.help)
        .accessibilityLabel(detail.help)
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

/// "FAINTED" tag laid over a greyed-out Pokémon card.
struct FaintedBadge: View {
    var body: some View {
        Text("FAINTED")
            .font(.caption2.weight(.heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.red.opacity(0.85), in: Capsule())
    }
}
