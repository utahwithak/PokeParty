//
//  BattleCoachModel.swift
//  PokeParty
//
//  Observable state behind the Battle HUD banner: the coach's view of the
//  battle and the latest `BattleCoach` advice for it. The view is filled in
//  from the iPhone's battle snapshots (shields, Pokémon left, your active
//  Pokémon, effectiveness labels) and can be overridden by hand. Any change to
//  the inputs re-runs the coach, cancelling a run still in flight.
//

#if os(macOS)
import SwiftUI

@MainActor
@Observable
final class BattleCoachModel {

    /// What the coach knows about the battle.
    struct Inputs: Equatable {
        var myShields = 2
        var opponentShields = 2
        /// Index into the team builder's members of the Pokémon on the field.
        var myActive = 0
        /// Indices into the team builder's members that have fainted.
        var fainted: Set<Int> = []
        /// Index into the revealed opponents of the one on the field.
        var opponentActive = 0
        /// Indices into the revealed opponents that have fainted.
        var opponentFainted: Set<Int> = []
        /// Pokémon the opponent has left, revealed or not.
        var opponentAlive = 3
        /// Last HP fraction (0…1) seen for each Pokémon, by team / revealed-opponent
        /// index. Kept after a Pokémon swaps out. Unlisted ones are assumed full.
        var myHP: [Int: Double] = [:]
        var opponentHP: [Int: Double] = [:]

        /// The same state in the form the battle log reads.
        var observation: BattleObservation {
            BattleObservation(
                myActive: myActive, opponentActive: opponentActive,
                myFainted: fainted, opponentFainted: opponentFainted,
                myShields: myShields, opponentShields: opponentShields,
                myHP: myHP, opponentHP: opponentHP)
        }
    }

    enum Phase: Equatable {
        case needsTeam
        case needsOpponent
        case needsActive          // the active Pokémon is marked fainted
        case thinking
        case ready
        case failed(String)
    }

    var inputs = Inputs()
    private(set) var phase: Phase = .needsTeam
    private(set) var advice: BattleCoach.Advice?
    /// Opponent fast moves inferred from effectiveness labels, by species id.
    private(set) var observedFastMoves: [String: String] = [:]
    /// The most recent thing the phone told us that changed the picture.
    private(set) var note: String?
    /// Whether a phone snapshot has been applied this session.
    private(set) var hasPhoneData = false

    /// Every game seen, grouped into sets; the one in progress is logged live.
    let history: BattleHistoryStore
    /// The sim's review of a game, for the one last asked about.
    private(set) var review: BattleReviewer.Review?
    private(set) var reviewedBattleId: UUID?
    private(set) var isReviewing = false
    private(set) var reviewMessage: String?
    private var reviewTask: Task<Void, Never>?
    private var lastOpponentCount = 0
    private var awaitingOpponentClear = false

    private var runTask: Task<Void, Never>?
    /// Meta pool for filling unrevealed opponent slots, per format id.
    private var poolCache: [String: [TeamFinder.Candidate]] = [:]

    init(history: BattleHistoryStore = BattleHistoryStore()) {
        self.history = history
    }

    /// Forgets everything about the current battle: shields, who's fainted, HP,
    /// what's been inferred. Your team and the league are untouched. The game
    /// just played stays in the history.
    func newBattle() {
        history.startNewBattle()
        awaitingOpponentClear = lastOpponentCount > 0
        inputs = Inputs()
        observedFastMoves = [:]
        note = nil
    }

    // MARK: - History and review

    /// Marks the game won or lost (nil clears it) and, once there's a result,
    /// has the sim take a look at it.
    func mark(_ battle: RecordedBattle, as outcome: BattleOutcome?, store: RankingsStore) {
        history.mark(battle.id, as: outcome)
        if outcome != nil { reviewBattle(battle.id, store: store) }
    }

    /// Plays the game's two teams through the sim and compares with what happened.
    func reviewBattle(_ id: UUID, store: RankingsStore) {
        // The result screen is reported more than once; one review is enough.
        if isReviewing, reviewedBattleId == id { return }
        reviewTask?.cancel()
        guard let battle = history.battles.first(where: { $0.id == id }) else { return }
        reviewedBattleId = id
        review = nil
        reviewMessage = nil

        guard battle.cup == store.format.cup, battle.cp == store.format.cp else {
            reviewMessage = "This game was played in another league. Switch to it to review it."
            return
        }
        // Where an opponent's charged moves were read off the screen, play those
        // (topping up from the ranked set when only one was seen) instead of the guess.
        let seenMoves = battle.observedOpponentMoves
        var opponentMembers = battle.opponents
        for index in opponentMembers.indices {
            guard let seen = seenMoves[opponentMembers[index].speciesId] else { continue }
            let guessed = opponentMembers[index].chargedMoveIds.filter { !seen.contains($0) }
            opponentMembers[index].chargedMoveIds = Array((seen + guessed).prefix(max(2, seen.count)))
        }

        guard let mine = TeamBuilderModel.buildTeam(battle.team, store: store), mine.combatants.count == battle.team.count,
              let theirs = TeamBuilderModel.buildTeam(opponentMembers, store: store),
              theirs.combatants.count == battle.opponents.count else {
            reviewMessage = "Couldn't build one of the Pokémon for simulation."
            return
        }
        let movesById = store.movesById
        let moveNames = movesById.mapValues(\.name)
        let teamNames = battle.team.map { store.name(forSpeciesId: $0.speciesId) }
        let opponentNames = battle.opponents.map { store.name(forSpeciesId: $0.speciesId) }
        isReviewing = true

        reviewTask = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> BattleReviewer.Review? in
                guard let myTeam = ThreeVThreeBattle.makeTeam(mine.combatants, stats: mine.stats, movesById: movesById),
                      let opponentTeam = ThreeVThreeBattle.makeTeam(theirs.combatants, stats: theirs.stats, movesById: movesById)
                else { return nil }
                return BattleReviewer.review(
                    battle: battle, team: myTeam, opponents: opponentTeam,
                    teamNames: teamNames, opponentNames: opponentNames,
                    moveName: { moveNames[$0] ?? $0 })
            }.value
            if Task.isCancelled { return }
            isReviewing = false
            guard let result else { reviewMessage = "Couldn't simulate this game."; return }
            review = result
            history.setReview(id, simPredictsWin: result.simPredictsWin, diagnosis: result.diagnosis)
        }
    }

    /// Logs the current state. Runs on every refresh, so it sees every change
    /// to the inputs, the team and the revealed opponents.
    private func recordProgress(team: [TeamMember], opponents: [TeamMember], store: RankingsStore) {
        lastOpponentCount = opponents.count
        // After "New battle" the old opponents linger for a moment; don't log them as a new game.
        if awaitingOpponentClear {
            if opponents.isEmpty { awaitingOpponentClear = false }
            return
        }
        history.observe(inputs.observation, team: team, opponents: opponents, format: store.format)
    }

    // MARK: - Phone snapshots

    /// Applies a battle snapshot from the phone to the inputs.
    func apply(_ snapshot: BattleSnapshot, team: [TeamMember], opponents: [TeamMember], store: RankingsStore) {
        hasPhoneData = true
        var updated = inputs

        // A fresh battle: everyone's back at full strength.
        if snapshot.myAlive == 3, snapshot.opponentAlive == 3 {
            // If the last game got as far as a faint or a result, this is the next one.
            if history.currentIsFinished { history.startNewBattle() }
            updated.fainted = []
            updated.opponentFainted = []
            updated.myHP = [:]
            updated.opponentHP = [:]
            observedFastMoves = [:]
        }

        // Who fainted comes from the "<name> fainted" message. (The Pokémon-left
        // icons only say how many, not which.)
        for name in snapshot.fainted {
            applyFaint(named: name, to: &updated, snapshot: snapshot, team: team, opponents: opponents, store: store)
        }

        if let value = snapshot.myShields { updated.myShields = value }
        if let value = snapshot.opponentShields { updated.opponentShields = value }
        if let value = snapshot.opponentAlive { updated.opponentAlive = value }

        // Which of your Pokémon is out: by name, then type icons.
        let species = team.compactMap { Self.regularSpecies(of: $0, store: store) }
        if species.count == team.count,
           let index = BattleActiveMatcher.activeIndex(
            name: snapshot.myName ?? "", icons: snapshot.myIcons, team: species),
           !updated.fainted.contains(index) {
            // The faint banner is easy to miss. If the Pokémon-left count is lower
            // than the faints seen and a different Pokémon is now out, the one that
            // was out fainted (a swap by choice doesn't change the count).
            if index != updated.myActive, team.indices.contains(updated.myActive),
               let alive = snapshot.myAlive, alive < team.count - updated.fainted.count {
                updated.fainted.insert(updated.myActive)
                updated.myHP[updated.myActive] = nil
            }
            updated.myActive = index
        }

        // HP of the two Pokémon on the field, remembered per Pokémon.
        if let hp = snapshot.myHP, team.indices.contains(updated.myActive) {
            updated.myHP[updated.myActive] = hp
        }
        if let hp = snapshot.opponentHP, opponents.indices.contains(updated.opponentActive) {
            updated.opponentHP[updated.opponentActive] = hp
        }

        if updated != inputs { inputs = updated }

        // The result screen is the word on who won; it beats a guess from the faint count.
        if let result = snapshot.result, let id = history.observeResult(result) {
            reviewBattle(id, store: store)
        }

        if let lines = snapshot.screenText, !lines.isEmpty {
            observeMoves(lines, team: team, opponents: opponents, store: store)
            history.observeScreenText(lines)
        }

        if let flash = snapshot.flash {
            let targetMine = flashTargetIsMine(flash, flashY: snapshot.flashY, team: team, opponents: opponents, store: store)
            history.observeFlash(superEffective: flash == .superEffective, targetMine: targetMine, inputs.observation,
                                 team: team, opponents: opponents)
            // What an opposing fast move did to yours says what it is; a hit on theirs says nothing about their moves.
            if targetMine { observe(flash, team: team, opponents: opponents, store: store) }
        }
    }

    /// Whether an effectiveness label was a hit on your Pokémon (true) or theirs.
    ///
    /// Where the label sits isn't reliable on its own: it floats and drifts, and a
    /// charged move's shows in the middle whoever it hit. So the types decide
    /// first. For each side, would its attack — its fast move, plus a charged move
    /// it just threw — give this label against the other side's types? If only one
    /// side's would, that's the attacker. Otherwise a charged throw just logged
    /// means a hit on the thrower's opponent, and failing that the label's position
    /// (lower half of the screen is yours, upper half theirs).
    private func flashTargetIsMine(_ flash: EffectivenessFlash, flashY: Double?, team: [TeamMember],
                                   opponents: [TeamMember], store: RankingsStore) -> Bool {
        let recent = history.recentCharged()

        func fits(_ moveId: String?, against types: [String]) -> Bool {
            guard let moveId, let move = store.move(id: moveId) else { return false }
            let multiplier = TypeChart.effectiveness(moveType: move.type, targetTypes: types)
            return flash == .superEffective ? multiplier > 1.01 : multiplier < 0.99
        }

        if team.indices.contains(inputs.myActive), opponents.indices.contains(inputs.opponentActive),
           let myTypes = Self.regularSpecies(of: team[inputs.myActive], store: store)?.displayTypes,
           let theirTypes = store.pokemonById[opponents[inputs.opponentActive].speciesId]?.displayTypes,
           // A throw that was seen but not named could be anything, so types can't say.
           recent?.moveId != nil || recent == nil {
            let mine = team[inputs.myActive], theirs = opponents[inputs.opponentActive]
            let theirFast = observedFastMoves[theirs.speciesId] ?? theirs.fastMoveId

            var mineMoves: [String?] = [mine.fastMoveId], theirMoves: [String?] = [theirFast]
            if let recent {
                if recent.mine { mineMoves.append(recent.moveId) } else { theirMoves.append(recent.moveId) }
            }
            let mineFit = mineMoves.contains { fits($0, against: theirTypes) }      // yours hit them
            let theirsFit = theirMoves.contains { fits($0, against: myTypes) }      // theirs hit you
            if mineFit != theirsFit { return theirsFit }
        }

        if let thrower = recent?.mine { return !thrower }
        return (flashY ?? 1) >= 0.5
    }

    /// Reads "<Pokémon> used <Move>!" banners out of the screen text and logs the
    /// charged moves they name. Your own move buttons show the same move names
    /// all the time, so only banners count. The rating after your charge-up
    /// swipe (NICE! / GREAT! / EXCELLENT!) marks a throw of yours even when the
    /// banner wasn't read.
    private func observeMoves(_ lines: [ScreenLine], team: [TeamMember], opponents: [TeamMember], store: RankingsStore) {
        guard team.indices.contains(inputs.myActive), opponents.indices.contains(inputs.opponentActive) else { return }
        let text = lines.map(\.text)

        func mover(_ member: TeamMember, learnset: [String]) -> ChargedMoveMatcher.Mover {
            // "Ampharos (Shadow)" is "Ampharos" on screen.
            let full = store.name(forSpeciesId: member.speciesId)
            let name = full.split(separator: "(", maxSplits: 1, omittingEmptySubsequences: false).first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? full
            let moves = Set(learnset).union(member.chargedMoveIds).compactMap { id in
                store.move(id: id).map { (id: id, name: $0.name) }
            }
            return .init(name: name, moves: moves)
        }
        // Yours are the moves you have; theirs are anything they learn, since their set is a guess.
        let mine = mover(team[inputs.myActive], learnset: [])
        let theirMember = opponents[inputs.opponentActive]
        let theirs = mover(theirMember, learnset: store.pokemonById[theirMember.speciesId]?.chargedMoves ?? [])

        for match in ChargedMoveMatcher.matchBanners(text, mine: mine, theirs: theirs) {
            guard let owner = match.mine else { continue }
            history.observeCharged(moveId: match.moveId, mine: owner, inputs.observation, team: team, opponents: opponents)
        }
        if text.contains(where: ChargedMoveMatcher.isThrowRating) {
            history.observeCharged(moveId: nil, mine: true, inputs.observation, team: team, opponents: opponents)
        }
    }

    /// Marks the Pokémon a faint message names. A name can fit both sides (a
    /// mirror match); then the side whose Pokémon-left count dropped, or whose
    /// active Pokémon it is, gets it.
    private func applyFaint(named message: String, to inputs: inout Inputs, snapshot: BattleSnapshot,
                            team: [TeamMember], opponents: [TeamMember], store: RankingsStore) {
        func base(_ pokemon: Pokemon) -> String {
            (pokemon.speciesName.split(separator: "(", maxSplits: 1, omittingEmptySubsequences: false).first
                .map(String.init) ?? pokemon.speciesName)
                .trimmingCharacters(in: .whitespaces)
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        }
        let text = message.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)

        let mine = team.indices.filter { index in
            !inputs.fainted.contains(index)
                && Self.regularSpecies(of: team[index], store: store).map { text.contains(base($0)) } == true
        }
        let theirs = opponents.indices.filter { index in
            !inputs.opponentFainted.contains(index)
                && store.pokemonById[opponents[index].speciesId].map { text.contains(base($0)) } == true
        }

        var side: Bool?          // true = yours, false = theirs
        switch (mine.isEmpty, theirs.isEmpty) {
        case (false, true): side = true
        case (true, false): side = false
        case (false, false):
            let myDrop = snapshot.myAlive.map { $0 < 3 - inputs.fainted.count } ?? false
            let theirDrop = snapshot.opponentAlive.map { $0 < 3 - inputs.opponentFainted.count } ?? false
            if myDrop != theirDrop {
                side = myDrop
            } else {
                let mineActive = mine.contains(inputs.myActive), theirsActive = theirs.contains(inputs.opponentActive)
                if mineActive != theirsActive { side = mineActive }
            }
        case (true, true): break
        }
        guard let side else { return }
        if side {
            inputs.fainted.insert(mine.contains(inputs.myActive) ? inputs.myActive : mine[0])
        } else {
            inputs.opponentFainted.insert(theirs.contains(inputs.opponentActive) ? inputs.opponentActive : theirs[0])
        }
    }

    /// The species with any `_shadow` suffix removed, so a shadow matches its
    /// regular name on screen.
    private static func regularSpecies(of member: TeamMember, store: RankingsStore) -> Pokemon? {
        var id = member.speciesId
        if id.hasSuffix("_shadow") { id = String(id.dropLast("_shadow".count)) }
        return store.pokemonById[id] ?? store.pokemonById[member.speciesId]
    }

    /// An effectiveness label means the opponent's fast move hit your active
    /// Pokémon. Of the fast moves they could have, only some are super effective
    /// (or resisted) against your types — if their current move isn't one of
    /// them, switch to one that is.
    private func observe(_ flash: EffectivenessFlash, team: [TeamMember], opponents: [TeamMember], store: RankingsStore) {
        guard team.indices.contains(inputs.myActive), opponents.indices.contains(inputs.opponentActive),
              let mine = Self.regularSpecies(of: team[inputs.myActive], store: store),
              let theirs = store.pokemonById[opponents[inputs.opponentActive].speciesId]
        else { return }
        let opponent = opponents[inputs.opponentActive]

        let matching = theirs.fastMoves.filter { id in
            guard let move = store.move(id: id) else { return false }
            let multiplier = TypeChart.effectiveness(moveType: move.type, targetTypes: mine.displayTypes)
            return flash == .superEffective ? multiplier > 1.01 : multiplier < 0.99
        }
        guard !matching.isEmpty else { return }

        let label = flash == .superEffective ? "super effective" : "not very effective"
        let theirName = store.name(forSpeciesId: opponent.speciesId)
        if matching.contains(opponent.fastMoveId) {
            note = "\(theirName)'s fast move hit \(mine.speciesName) \(label) — matches \(store.move(id: opponent.fastMoveId)?.name ?? "its move")."
            return
        }
        // Prefer the ranked move among the ones that fit.
        let ranked = store.entry(id: opponent.speciesId)?.moveset.first
        guard let moveId = matching.first(where: { $0 == ranked }) ?? matching.first else { return }
        observedFastMoves[opponent.speciesId] = moveId
        note = "\(theirName)'s fast move hit \(mine.speciesName) \(label) — probably \(store.move(id: moveId)?.name ?? moveId)."
    }

    // MARK: - Coaching

    /// Re-runs the coach for `team` against the revealed `opponents`.
    func refresh(team: [TeamMember], opponents: [TeamMember], store: RankingsStore) {
        runTask?.cancel()
        recordProgress(team: team, opponents: opponents, store: store)

        guard !team.isEmpty else { phase = .needsTeam; advice = nil; return }
        guard !opponents.isEmpty else { phase = .needsOpponent; advice = nil; return }

        // Keep the selections inside the lists as they change.
        let active = min(max(inputs.myActive, 0), team.count - 1)
        let opponentActive = min(max(inputs.opponentActive, 0), opponents.count - 1)
        guard !inputs.fainted.contains(active) else { phase = .needsActive; advice = nil; return }
        // Their active Pokémon fainted and the next one hasn't shown yet.
        guard !inputs.opponentFainted.contains(opponentActive) else { phase = .needsOpponent; advice = nil; return }

        let alive = team.indices.filter { !inputs.fainted.contains($0) }
        let myTeamMembers = alive.map { team[$0] }
        let opponentAlive = opponents.indices.filter { !inputs.opponentFainted.contains($0) }
        let opponentMembers = opponentAlive.map { opponents[$0] }
        guard let mine = TeamBuilderModel.buildTeam(myTeamMembers, store: store),
              mine.combatants.count == myTeamMembers.count,
              let theirs = TeamBuilderModel.buildTeam(opponentMembers, store: store),
              theirs.combatants.count == opponentMembers.count
        else { phase = .failed("Couldn't build one of the Pokémon for simulation."); advice = nil; return }

        let movesById = store.movesById
        let pokemonById = store.pokemonById
        let format = store.format
        let inputs = inputs
        phase = .thinking

        runTask = Task {
            // The screen changes several times a second; wait for it to settle so
            // a burst of updates costs one simulation, not one each.
            try? await Task.sleep(for: .milliseconds(350))
            if Task.isCancelled { return }
            guard let myTeam = ThreeVThreeBattle.makeTeam(mine.combatants, stats: mine.stats, movesById: movesById),
                  let opponentTeam = ThreeVThreeBattle.makeTeam(theirs.combatants, stats: theirs.stats, movesById: movesById),
                  let myActive = alive.firstIndex(of: active),
                  let theirActive = opponentAlive.firstIndex(of: opponentActive)
            else { phase = .failed("Couldn't build one of the Pokémon for simulation."); return }

            let pool = await pool(for: format, pokemonById: pokemonById)
            if Task.isCancelled { return }

            // HP is tracked by team / revealed index; the sim's teams drop the fainted.
            var myHP: [Int: Double] = [:]
            for (position, original) in alive.enumerated() { myHP[position] = inputs.myHP[original] }
            var opponentHP: [Int: Double] = [:]
            for (position, original) in opponentAlive.enumerated() { opponentHP[position] = inputs.opponentHP[original] }

            var state = BattleCoach.State(
                myTeam: myTeam, myActive: myActive, myShields: inputs.myShields,
                opponentRevealed: opponentTeam, opponentActive: theirActive,
                opponentShields: inputs.opponentShields,
                opponentTeamSize: max(inputs.opponentAlive, opponentTeam.count))
            state.myHP = myHP
            state.opponentHP = opponentHP
            let result = await BattleCoach.advise(state, pool: pool, movesById: movesById)
            if Task.isCancelled { return }

            advice = result
            phase = result == nil ? .failed("Couldn't evaluate this situation.") : .ready
        }
    }

    private func pool(for format: RankingFormat, pokemonById: [String: Pokemon]) async -> [TeamFinder.Candidate] {
        if let cached = poolCache[format.id] { return cached }
        guard let entries = try? await DataService.shared.rankings(for: format) else { return [] }
        let built = TeamFinderModel.buildPool(
            entries: entries, poolSize: 40, cpCap: format.cp, pokemonById: pokemonById)
        poolCache[format.id] = built
        return built
    }
}
#endif
