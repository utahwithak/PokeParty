//
//  TempoTracker.swift
//  PokeParty
//
//  Tracks when each side can switch again. The timer starts when a side swaps
//  by choice; a swap after a faint doesn't start it, nor does choosing the lead.
//
//  Times are plain seconds on any steady clock; the caller supplies them.
//

import Foundation

nonisolated struct TempoTracker: Equatable, Sendable {

    enum Side: Equatable, Sendable { case mine, theirs }

    /// How long a side waits after switching before it can switch again, as the game
    /// shows it. (The sims keep their own, shorter constant; it's tuned separately.)
    static let switchTimer: TimeInterval = 45

    private struct SideState: Equatable {
        var active: Int?
        var lastSwitch: TimeInterval?
        /// What the side looked like before its latest change of Pokémon, so a faint
        /// read late can take that change back.
        var before: (active: Int?, lastSwitch: TimeInterval?, at: TimeInterval)?

        static func == (a: SideState, b: SideState) -> Bool {
            a.active == b.active && a.lastSwitch == b.lastSwitch
                && a.before?.active == b.before?.active && a.before?.lastSwitch == b.before?.lastSwitch
                && a.before?.at == b.before?.at
        }
    }

    /// How long after a change of Pokémon a faint read for the one it replaced
    /// still counts: the banner is easy to miss, or to read a moment late.
    static let lateFaintWindow: TimeInterval = 10

    private var mine = SideState()
    private var theirs = SideState()

    private subscript(side: Side) -> SideState {
        get { side == .mine ? mine : theirs }
        set { if side == .mine { mine = newValue } else { theirs = newValue } }
    }

    /// `index` is now the side's Pokémon on the field. A change of Pokémon starts
    /// the switch timer unless a faint (`fainted` clears the active one) forced it.
    mutating func setActive(_ side: Side, index: Int, at time: TimeInterval) {
        var state = self[side]
        guard state.active != index else { return }
        state.before = (state.active, state.lastSwitch, time)
        if state.active != nil { state.lastSwitch = time }
        state.active = index
        self[side] = state
    }

    /// The side's Pokémon `index` fainted. If it was out, the next one in isn't a switch.
    /// If the swap to its replacement was already counted (the faint was read late),
    /// that swap wasn't a choice: the timer it started is taken back.
    mutating func fainted(_ side: Side, index: Int, at time: TimeInterval) {
        var state = self[side]
        if state.active == index {
            state.active = nil
        } else if let before = state.before, before.active == index, time - before.at <= Self.lateFaintWindow {
            state.lastSwitch = before.lastSwitch
            state.before = nil
        }
        self[side] = state
    }

    /// Which Pokémon the tracker thinks is out for `side`.
    func active(_ side: Side) -> Int? { self[side].active }

    /// Seconds until the side may switch again; 0 when it already can.
    func switchRemaining(_ side: Side, at time: TimeInterval) -> TimeInterval {
        guard let last = self[side].lastSwitch else { return 0 }
        return max(0, Self.switchTimer - (time - last))
    }
}
