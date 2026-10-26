//
//  OpponentUsageStore.swift
//  PokeParty
//
//  Tracks which opponents the user checks in the Team Builder's "Check
//  Opponent" tab, per format (cup + CP cap), so recently/frequently checked
//  opponents — likely common in that meta — can be re-picked quickly.
//  Stored locally as a small JSON file in Application Support.
//

import Foundation
import SwiftUI

/// Usage of opponents within one format.
nonisolated struct OpponentUsage: Codable, Hashable {
    var formatId: String
    /// Times each species was checked.
    var counts: [String: Int] = [:]
    /// Most recently checked first, de-duplicated.
    var recent: [String] = []
}

@MainActor
@Observable
final class OpponentUsageStore {

    private static let maxRecent = 12

    private(set) var usage: [OpponentUsage] = []
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? JSONFileStore.defaultFileURL(filename: "OpponentUsage.json")
        usage = JSONFileStore.load(from: self.fileURL)
    }

    /// Records that `speciesId` was checked in `format`.
    func record(_ speciesId: String, in format: RankingFormat) {
        let index: Int
        if let existing = usage.firstIndex(where: { $0.formatId == format.id }) {
            index = existing
        } else {
            usage.append(OpponentUsage(formatId: format.id))
            index = usage.count - 1
        }
        usage[index].counts[speciesId, default: 0] += 1
        usage[index].recent.removeAll { $0 == speciesId }
        usage[index].recent.insert(speciesId, at: 0)
        if usage[index].recent.count > Self.maxRecent {
            usage[index].recent.removeLast(usage[index].recent.count - Self.maxRecent)
        }
        persist()
    }

    func recent(in format: RankingFormat) -> [String] {
        usage.first { $0.formatId == format.id }?.recent ?? []
    }

    /// Most-checked species in `format`, highest count first.
    func mostUsed(in format: RankingFormat, limit: Int = 8) -> [(speciesId: String, count: Int)] {
        guard let u = usage.first(where: { $0.formatId == format.id }) else { return [] }
        return u.counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map { (speciesId: $0.key, count: $0.value) }
    }

    func count(for speciesId: String, in format: RankingFormat) -> Int {
        usage.first { $0.formatId == format.id }?.counts[speciesId] ?? 0
    }

    func clear(format: RankingFormat) {
        usage.removeAll { $0.formatId == format.id }
        persist()
    }

    private func persist() {
        guard let data = JSONFileStore.encode(usage) else { return }
        JSONFileStore.write(data, to: fileURL)
    }
}
