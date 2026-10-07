//
//  TimelineAction.swift
//  PokeParty
//
//  An action a Pokémon performs on a turn. Ported from TimelineAction.js.
//

import Foundation

/// A value type — allocated (and copied) on every turn for every actor in
/// every simulated battle, so avoiding a class here removes per-turn ARC
/// retain/release traffic from the hottest loop in the engine.
nonisolated struct TimelineAction {
    enum Kind: String { case fast, charged, wait }

    let type: Kind
    let actor: Int
    let turn: Int
    let value: Int        // charged-move index (into chargedMoves)
    var priority: Int
    var valid: Bool = false
    var processed: Bool = false

    init(type: Kind, actor: Int, turn: Int, value: Int, priority: Int) {
        self.type = type
        self.actor = actor
        self.turn = turn
        self.value = value
        self.priority = priority
    }
}
