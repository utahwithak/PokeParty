//
//  SidebarOrderStore.swift
//  PokeParty
//
//  The order the player has dragged the sidebar's rows into, per section. Only
//  the order is saved, by each row's stable key, so rows added by an update
//  (or a new cup) show up at the end of their section instead of vanishing.
//

import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class SidebarOrderStore {

    enum Section: String, CaseIterable {
        case tools, pro, leagues, cups
    }

    /// Row keys in the saved order, by section.
    private(set) var saved: [String: [String]]
    private let defaults: UserDefaults
    private static let defaultsKey = "sidebarOrder"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        saved = defaults.dictionary(forKey: Self.defaultsKey) as? [String: [String]] ?? [:]
    }

    /// `items` in the player's order: saved ones first, in their saved order,
    /// then any not seen before in their default order.
    func ordered<T>(_ items: [T], in section: Section, key: (T) -> String) -> [T] {
        Self.apply(saved[section.rawValue] ?? [], to: items, key: key)
    }

    /// Moves rows within a section, as a `ForEach`'s `onMove` reports it.
    func move<T>(_ items: [T], in section: Section, key: (T) -> String, from source: IndexSet, to destination: Int) {
        var current = ordered(items, in: section, key: key)
        current.move(fromOffsets: source, toOffset: destination)
        saved[section.rawValue] = current.map(key)
        defaults.set(saved, forKey: Self.defaultsKey)
    }

    /// Puts every section back in its default order.
    func reset() {
        saved = [:]
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    var isCustomized: Bool { !saved.isEmpty }

    static func apply<T>(_ order: [String], to items: [T], key: (T) -> String) -> [T] {
        var remaining = items
        var result: [T] = []
        for id in order {
            if let index = remaining.firstIndex(where: { key($0) == id }) {
                result.append(remaining.remove(at: index))
            }
        }
        return result + remaining
    }
}
