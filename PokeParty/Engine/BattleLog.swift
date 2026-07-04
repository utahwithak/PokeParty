//
//  BattleLog.swift
//  PokeParty
//
//  Opt-in recording of a battle as a key-frame timeline (plan Milestone 7). A
//  frame is captured at each key event with both Pokémon's residuals (HP, energy,
//  shields, buff stages), so the UI can scrub through the fight. Recording is off
//  by default and must never be enabled in the analyzer/finder hot loops.
//

import Foundation

nonisolated enum BattleEventKind: String, Sendable, Hashable {
    case fast, charged, faint, switchIn, timeout
}

/// One thing that happened on the timeline (a move, a faint, a switch).
nonisolated struct BattleEvent: Sendable, Hashable {
    let actor: Int          // index 0/1 of the Pokémon that acted (or fainted)
    let kind: BattleEventKind
    let moveId: String?
    let damage: Int?
    let shielded: Bool
}

/// A snapshot of the battle right after an event, indexed [side0, side1].
nonisolated struct BattleFrame: Sendable, Hashable {
    let turn: Int
    let timeMs: Int
    let hp: [Int]
    let energy: [Int]
    let shields: [Int]
    let buffs: [[Int]]      // [ [atk,def], [atk,def] ]
    let event: BattleEvent?
}

/// The recorded timeline of a single 1v1 battle plus its end-state residuals.
nonisolated struct BattleLog: Sendable, Hashable {
    let frames: [BattleFrame]
    let ratingA: Int
    let ratingB: Int
    let hpA: Int
    let hpB: Int
    let energyA: Int
    let energyB: Int
    let shieldsA: Int
    let shieldsB: Int
}
