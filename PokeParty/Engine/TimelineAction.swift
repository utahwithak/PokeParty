//
//  TimelineAction.swift
//  PokeParty
//
//  An action a Pokémon performs on a turn. Ported from TimelineAction.js.
//

import Foundation

nonisolated final class TimelineAction {
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
