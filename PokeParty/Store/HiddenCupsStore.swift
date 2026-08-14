//
//  HiddenCupsStore.swift
//  PokeParty
//
//  Tracks which limited cups the user has hidden from the sidebar. Persisted
//  in UserDefaults. NOTE: cross-device sync via iCloud key-value storage
//  (NSUbiquitousKeyValueStore) was tried but requires the iCloud capability,
//  which needs a paid Apple Developer Program membership — the personal/free
//  team on this project can't provision it. If the team upgrades, swap the
//  UserDefaults calls below for NSUbiquitousKeyValueStore.default and add
//  the com.apple.developer.ubiquity-kvstore-identifier entitlement.
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class HiddenCupsStore {

    private static let key = "HiddenCupFormatIDs"

    private(set) var hiddenIds: Set<String>

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hiddenIds = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func isHidden(_ formatId: String) -> Bool {
        hiddenIds.contains(formatId)
    }

    func hide(_ formatId: String) {
        guard hiddenIds.insert(formatId).inserted else { return }
        persist()
    }

    func unhide(_ formatId: String) {
        guard hiddenIds.remove(formatId) != nil else { return }
        persist()
    }

    private func persist() {
        defaults.set(Array(hiddenIds), forKey: Self.key)
    }
}
