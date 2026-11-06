//
//  ShieldReadingFilter.swift
//  PokeParty
//
//  The shield hexagons are read by colour from one frame at a time, and the
//  header dims or animates during charged-move animations, which can read as
//  every shield suddenly spent. This holds the last trusted count and only
//  believes a change once it has lasted:
//   - a drop must hold for a moment (longer if both sides "drop" together, which
//     is what a dimmed header looks like);
//   - shields never come back mid-battle, so a rise only counts at the start of
//     a battle, when all six Pokémon are still up.
//

import Foundation

nonisolated struct ShieldReadingFilter: Sendable {

    /// How long a lower reading must hold before it's believed.
    static let dropHold: TimeInterval = 1.5
    /// …when both sides appear to drop at once.
    static let simultaneousDropHold: TimeInterval = 4
    /// How long a first reading, or a rise at the start of a battle, must hold.
    static let settleHold: TimeInterval = 0.8

    private struct Pending {
        var value: Int
        var since: TimeInterval
    }

    /// The trusted counts: yours, then theirs. Nil until a reading has settled.
    private(set) var trusted: [Int?] = [nil, nil]
    private var pending: [Pending?] = [nil, nil]

    /// Feeds one frame's header reading (nil when the header wasn't readable)
    /// and returns the counts to trust: yours, theirs.
    mutating func update(_ reading: BattleHeaderReading?, now: TimeInterval) -> (mine: Int?, theirs: Int?) {
        guard let reading else { return (trusted[0], trusted[1]) }
        let values = [reading.myShields, reading.opponentShields]
        let fresh = reading.myAlive == 3 && reading.opponentAlive == 3

        for side in 0..<2 {
            let value = values[side]
            if let current = trusted[side] {
                if value == current || (value > current && !fresh) { pending[side] = nil; continue }
            }
            if pending[side]?.value != value { pending[side] = Pending(value: value, since: now) }
        }

        // Both sides falling at about the same moment is the header dimming, not two shields.
        let simultaneous: Bool = {
            guard let a = pending[0], let b = pending[1],
                  let ta = trusted[0], let tb = trusted[1], a.value < ta, b.value < tb else { return false }
            return abs(a.since - b.since) < 0.5
        }()

        for side in 0..<2 {
            guard let candidate = pending[side] else { continue }
            let hold: TimeInterval
            if let current = trusted[side], candidate.value < current {
                hold = simultaneous ? Self.simultaneousDropHold : Self.dropHold
            } else {
                hold = Self.settleHold
            }
            if now - candidate.since >= hold {
                trusted[side] = candidate.value
                pending[side] = nil
            }
        }
        return (trusted[0], trusted[1])
    }
}
