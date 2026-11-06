//
//  SidebarOrderStoreTests.swift
//  PokePartyTests
//

import Foundation
import Testing
@testable import PokeParty

@MainActor
@Suite struct SidebarOrderStoreTests {

    private func makeStore() -> SidebarOrderStore {
        let suite = "SidebarOrderStoreTests-\(UUID().uuidString)"
        return SidebarOrderStore(defaults: UserDefaults(suiteName: suite)!)
    }

    private let items = ["a", "b", "c", "d"]

    @Test func startsInTheDefaultOrder() {
        #expect(makeStore().ordered(items, in: .tools, key: { $0 }) == items)
    }

    @Test func movingARowIsRemembered() {
        let store = makeStore()
        store.move(items, in: .tools, key: { $0 }, from: IndexSet(integer: 3), to: 0)

        #expect(store.ordered(items, in: .tools, key: { $0 }) == ["d", "a", "b", "c"])
        // Other sections are untouched.
        #expect(store.ordered(items, in: .pro, key: { $0 }) == items)
    }

    @Test func aRowAddedLaterGoesAtTheEnd() {
        let store = makeStore()
        store.move(items, in: .tools, key: { $0 }, from: IndexSet(integer: 3), to: 0)

        #expect(store.ordered(items + ["e"], in: .tools, key: { $0 }) == ["d", "a", "b", "c", "e"])
    }

    @Test func aRemovedRowIsDroppedFromTheSavedOrder() {
        let store = makeStore()
        store.move(items, in: .tools, key: { $0 }, from: IndexSet(integer: 3), to: 0)

        #expect(store.ordered(["a", "c", "d"], in: .tools, key: { $0 }) == ["d", "a", "c"])
    }

    @Test func theOrderSurvivesARelaunch() {
        let suite = "SidebarOrderStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        SidebarOrderStore(defaults: defaults).move(items, in: .leagues, key: { $0 }, from: IndexSet(integer: 0), to: 4)

        #expect(SidebarOrderStore(defaults: defaults).ordered(items, in: .leagues, key: { $0 }) == ["b", "c", "d", "a"])
    }

    @Test func resettingRestoresTheDefaultOrder() {
        let store = makeStore()
        store.move(items, in: .tools, key: { $0 }, from: IndexSet(integer: 3), to: 0)
        store.reset()

        #expect(store.ordered(items, in: .tools, key: { $0 }) == items)
        #expect(!store.isCustomized)
    }
}
