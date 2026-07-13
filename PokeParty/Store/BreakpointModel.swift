//
//  BreakpointModel.swift
//  PokeParty
//
//  Observable state for the Breakpoints tool: one subject Pokémon at a chosen
//  level, analyzed across an IV grid (12–15 per stat) against the Master
//  League meta. See BreakpointAnalyzer for the analysis itself.
//

import SwiftUI

@MainActor
@Observable
final class BreakpointModel {

    /// The league whose meta defines the opponent set (Master for now).
    let format: RankingFormat = .master

    /// How many top-ranked meta Pokémon to battle.
    static let opponentCount = 20

    private(set) var member: TeamMember?

    /// The subject's recommended Master League moveset (labels the pickers).
    private(set) var recommendedMoveset: [String] = []

    private(set) var report: BreakpointAnalyzer.Report?
    private(set) var isAnalyzing = false
    private(set) var errorMessage: String?
    private var task: Task<Void, Never>?

    /// Sets the subject, defaulting to its recommended Master League moveset.
    func select(speciesId: String, store: RankingsStore) async {
        guard let species = store.pokemonById[speciesId] else { return }
        let entry = try? await store.rankings(for: format)
            .first { $0.speciesId == speciesId }
        recommendedMoveset = entry?.moveset ?? []
        if let entry, entry.moveset.count >= 2 {
            member = TeamMember(speciesId: speciesId,
                                fastMoveId: entry.moveset[0],
                                chargedMoveIds: Array(entry.moveset[1...].prefix(2)),
                                shadow: species.isShadow)
        } else if let fast = species.fastMoves.first {
            member = TeamMember(speciesId: speciesId,
                                fastMoveId: fast,
                                chargedMoveIds: Array(species.chargedMoves.prefix(2)),
                                shadow: species.isShadow)
        } else {
            member = nil
        }
        invalidate()
    }

    func setFastMove(_ id: String) {
        update { $0.fastMoveId = id }
    }

    /// Sets (or clears, with `nil`) a charged-move slot (0 = first, 1 = second).
    func setChargedMove(_ id: String?, slot: Int) {
        update { member in
            var charged = member.chargedMoveIds
            if let id {
                // Don't allow the same move in both charged slots.
                if charged.enumerated().contains(where: { $0.offset != slot && $0.element == id }) { return }
                if slot < charged.count { charged[slot] = id } else { charged.append(id) }
            } else if slot < charged.count {
                charged.remove(at: slot)
            }
            guard !charged.isEmpty else { return }
            member.chargedMoveIds = charged
        }
    }

    private func update(_ change: (inout TeamMember) -> Void) {
        guard var updated = member else { return }
        let before = updated
        change(&updated)
        guard updated != before else { return }
        member = updated
        invalidate()
    }

    private func invalidate() {
        task?.cancel()
        report = nil
        errorMessage = nil
        isAnalyzing = false
    }

    /// Runs (or re-runs) the full IV-grid analysis for the current subject.
    func analyze(using store: RankingsStore) {
        task?.cancel()
        guard let member, let species = store.pokemonById[member.speciesId] else {
            report = nil
            return
        }
        let subject = MatchupSimulator.Combatant(
            species: species, shadow: member.shadow,
            fastMoveId: member.fastMoveId, chargedMoveIds: member.chargedMoveIds)
        let movesById = store.movesById
        let pokemonById = store.pokemonById
        let format = format
        isAnalyzing = true
        report = nil
        errorMessage = nil
        task = Task {
            do {
                let entries = try await store.rankings(for: format)
                let opponents = Self.opponents(from: entries, pokemonById: pokemonById,
                                               cpCap: format.cp, count: Self.opponentCount,
                                               mirrorId: member.speciesId)
                let result = await Task.detached {
                    // IV grid at the level cap; the level sweep is built in.
                    await BreakpointAnalyzer.analyze(subject: subject,
                                                     level: IVCalculator.defaultLevelCap,
                                                     opponents: opponents, movesById: movesById)
                }.value
                guard !Task.isCancelled else { return }
                report = result
                if result == nil {
                    errorMessage = "Couldn't run the analysis for this Pokémon."
                }
                isAnalyzing = false
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                isAnalyzing = false
            }
        }
    }

    /// Top meta opponents, each with its recommended moveset and league-optimal
    /// stats. The subject's own mirror (at 15/15/15) is always included when it's
    /// ranked — IVs famously decide mirrors via attack-stat move priority.
    private nonisolated static func opponents(
        from entries: [RankingEntry],
        pokemonById: [String: Pokemon],
        cpCap: Int,
        count: Int,
        mirrorId: String
    ) -> [BreakpointAnalyzer.Opponent] {
        var result: [BreakpointAnalyzer.Opponent] = []
        for entry in entries.prefix(count) {
            if let opponent = opponent(for: entry, pokemonById: pokemonById, cpCap: cpCap) {
                result.append(opponent)
            }
        }
        if !result.contains(where: { $0.speciesId == mirrorId }),
           let mirrorEntry = entries.first(where: { $0.speciesId == mirrorId }),
           let mirror = opponent(for: mirrorEntry, pokemonById: pokemonById, cpCap: cpCap) {
            result.append(mirror)
        }
        return result
    }

    private nonisolated static func opponent(
        for entry: RankingEntry,
        pokemonById: [String: Pokemon],
        cpCap: Int
    ) -> BreakpointAnalyzer.Opponent? {
        guard let combatant = RankingsStore.combatant(for: entry, pokemonById: pokemonById)
        else { return nil }
        let stats: BattlePokemon.Stats
        if let s = entry.stats {
            stats = .init(atk: s.atk, def: s.def, hp: Int(s.hp))
        } else if let s = MatchupSimulator.optimalStats(for: combatant, cpCap: cpCap) {
            stats = .init(atk: s.atk, def: s.def, hp: s.hp)
        } else {
            return nil
        }
        return .init(speciesId: entry.speciesId, name: entry.speciesName,
                     combatant: combatant, stats: stats)
    }
}
