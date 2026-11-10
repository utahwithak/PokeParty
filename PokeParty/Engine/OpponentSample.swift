//
//  OpponentSample.swift
//  PokeParty
//
//  How much logged-opponent data backs "My Meta". The optimizer weights the
//  Pokémon you've faced relative to the most-seen one, which says nothing
//  about how many battles that is — three logged battles would steer the
//  search as hard as three hundred. This turns the battle count into a
//  confidence that scales those weights, so a thin log stays close to the
//  regular meta and a rich one takes over.
//

import Foundation

nonisolated struct OpponentSample: Sendable, Equatable {

    enum Verdict: Sendable, Equatable {
        case none, thin, limited, good
    }

    /// Battles needed for full confidence — enough that the top handful of
    /// opponents' frequencies stop being noise.
    static let fullConfidenceBattles = 30
    /// Below this the log is too thin to say much.
    static let limitedBattles = 10

    /// Estimated battles logged. The store keeps sightings and lead counts, not
    /// battles: each battle logs up to three opponent species and at most one
    /// lead, so the larger of leads and sightings ÷ 3 is a fair lower bound.
    let battles: Int

    init(battles: Int) { self.battles = max(battles, 0) }

    init(leadsLogged: Int, sightings: Int) {
        self.init(battles: max(leadsLogged, Int((Double(max(sightings, 0)) / 3).rounded(.up))))
    }

    /// 0…1 — how far to trust the logged opponents over the regular meta.
    var confidence: Double { min(1, Double(battles) / Double(Self.fullConfidenceBattles)) }

    var verdict: Verdict {
        switch battles {
        case 0: return .none
        case ..<Self.limitedBattles: return .thin
        case ..<Self.fullConfidenceBattles: return .limited
        default: return .good
        }
    }
}
