//
//  ChargeTiming.swift
//  PokeParty
//
//  Charge-move timing: when to throw a charged move relative to the
//  opponent's fast-move cycle. The battle AI (`ActionLogic`, "Optimize move
//  timing") holds back a ready charged move until the opponent's fast move is
//  about to land, so their attack can't sneak in while ours is mid-animation.
//  The target window lives here so the AI and the Team Builder's timing
//  readout use the exact same rule.
//

import Foundation

nonisolated enum ChargeTiming {

    /// How much of the opponent's fast-move cooldown (ms) may remain when we
    /// throw. 0 means no timing games (throw as soon as the move is ready).
    /// Ported from PvPoke's ActionLogic move-timing optimization.
    static func targetCooldown(pokeFastCooldown: Int, opponentFastCooldown: Int) -> Int {
        guard opponentFastCooldown > 0 else { return 0 }
        var target = 500
        if pokeFastCooldown >= 2000 { target = 1000 }
        if pokeFastCooldown >= 1500 && opponentFastCooldown == 2500 { target = 1000 }
        if pokeFastCooldown == 1000 && opponentFastCooldown == 2000 { target = 1000 }
        if pokeFastCooldown == opponentFastCooldown { target = 0 }
        if pokeFastCooldown % opponentFastCooldown == 0 && pokeFastCooldown > opponentFastCooldown { target = 0 }
        return target
    }

    struct Result: Hashable {
        /// Fast moves to throw between charged moves when timed (first 5 throws).
        var timed: [Int]
        /// Fast moves needed purely for energy (first 5 throws).
        var ready: [Int]
        /// False when timing changes nothing (aligned cycles, or the energy
        /// count already lands in the window).
        var timingMatters: Bool { timed != ready }
    }

    /// Simulates farming `pokeFast` against an opponent farming `opponentFast`
    /// (both starting a move on turn 0) and records after how many fast
    /// moves each of the next `throwCount` throws of a `cost`-energy charged
    /// move happens. Assumes the charged move takes one turn and ignores
    /// opponent charged moves — an approximation of the AI's decision, not
    /// a replacement for it (HP / KO checks can override the delay).
    static func throwCounts(cost: Int, pokeFast: Move, opponentFast: Move, throwCount: Int = 5) -> Result? {
        guard cost > 0, pokeFast.energyGain > 0, pokeFast.cooldown >= 500, opponentFast.cooldown >= 500
        else { return nil }
        let pokeTurns = pokeFast.cooldown / 500
        let oppTurns = opponentFast.cooldown / 500
        let target = targetCooldown(pokeFastCooldown: pokeFast.cooldown,
                                    opponentFastCooldown: opponentFast.cooldown)

        var timed: [Int] = []
        var turn = 0, energy = 0, fasts = 0
        while timed.count < throwCount && turn < 2000 {
            turn += pokeTurns
            energy = min(100, energy + pokeFast.energyGain)
            fasts += 1
            guard energy >= cost else { continue }
            // Remaining opponent cooldown, in turns, at this boundary (a
            // freshly started move counts as its full length).
            let remaining = oppTurns - (turn % oppTurns)
            let inWindow = target == 0
                || remaining * 500 <= target
                || energy + pokeFast.energyGain > 100   // can't afford to wait: energy would cap
            if inWindow {
                timed.append(fasts)
                energy -= cost
                fasts = 0
                turn += 1
            }
        }

        guard timed.count == throwCount,
              let ready = pokeFast.energyGain > 0
                ? Move.readyCounts(cost: cost, gain: pokeFast.energyGain, throwCount: throwCount) : nil
        else { return nil }
        return Result(timed: timed, ready: ready)
    }

    /// Running fast-move tally at each throw, e.g. gaps [3, 2, 2, 2] → "3 · 5 · 7 · 9".
    static func formatThrowPoints(_ counts: [Int]) -> String {
        var total = 0
        return counts.map { total += $0; return String(total) }.joined(separator: " · ")
    }

    /// "Straight 4" or "5 - 4 - 4 - 4 - 4".
    static func format(_ counts: [Int]) -> String {
        if let first = counts.first, counts.allSatisfy({ $0 == first }) {
            return "Straight \(first)"
        }
        return counts.map(String.init).joined(separator: " - ")
    }
}
