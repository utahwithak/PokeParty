//
//  HiddenCupsStore.swift
//  PokeParty
//
//  Tracks which limited cups the user has hidden from the sidebar. Backed by
//  NSUbiquitousKeyValueStore so the hidden set syncs across the user's
//  devices via iCloud, with a local UserDefaults mirror so the choice is
//  available offline / before the first iCloud sync completes.
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class HiddenCupsStore {

    private static let key = "HiddenCupFormatIDs"

    private(set) var hiddenIds: Set<String>

    private let defaults: UserDefaults
    private let cloud: NSUbiquitousKeyValueStore

    init(defaults: UserDefaults = .standard, cloud: NSUbiquitousKeyValueStore = .default) {
        self.defaults = defaults
        self.cloud = cloud

        // Prefer whatever iCloud already has; fall back to the local mirror
        // (e.g. first launch before iCloud has synced, or iCloud is unavailable).
        let cloudIds = cloud.array(forKey: Self.key) as? [String] ?? []
        let localIds = defaults.stringArray(forKey: Self.key) ?? []
        hiddenIds = Set(cloudIds.isEmpty ? localIds : cloudIds)

        cloud.synchronize()

        // This store lives for the app's lifetime, so no observer token needed.
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyCloudChange()
            }
        }
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
        let ids = Array(hiddenIds)
        defaults.set(ids, forKey: Self.key)
        cloud.set(ids, forKey: Self.key)
        cloud.synchronize()
    }

    private func applyCloudChange() {
        let ids = cloud.array(forKey: Self.key) as? [String] ?? []
        hiddenIds = Set(ids)
        defaults.set(ids, forKey: Self.key)
    }
}
