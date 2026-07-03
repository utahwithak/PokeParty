//
//  TimelineAction.swift
//  PokeParty
//
//  An action a Pokémon performs on a turn. Ported from TimelineAction.js.
//

import Foundation

final class TimelineAction {
    enum Kind: String { case fast, charged, wait }

    let type: Kind
    let actor: Int
    let turn: Int
    let value: Int        // charged-move index (into chargedMoves)
    var priority: Int
    var shielded: Bool
    var charge: Double
    var valid: Bool = false
    var processed: Bool = false

    init(type: Kind, actor: Int, turn: Int, value: Int, priority: Int, shielded: Bool = false, charge: Double = 1) {
        self.type = type
        self.actor = actor
        self.turn = turn
        self.value = value
        self.priority = priority
        self.shielded = shielded
        self.charge = charge
    }
}
