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
    /// Times each species was the opponent's lead.
    var leadCounts: [String: Int] = [:]
    /// Most recent leads first, de-duplicated.
    var recentLeads: [String] = []

    init(formatId: String) { self.formatId = formatId }

    // Files written before lead tracking lack the lead keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatId = try c.decode(String.self, forKey: .formatId)
        counts = try c.decodeIfPresent([String: Int].self, forKey: .counts) ?? [:]
        recent = try c.decodeIfPresent([String].self, forKey: .recent) ?? []
        leadCounts = try c.decodeIfPresent([String: Int].self, forKey: .leadCounts) ?? [:]
        recentLeads = try c.decodeIfPresent([String].self, forKey: .recentLeads) ?? []
    }

    /// Drops one count of `id` from the check (or lead) history, and its
    /// recent entry once none remain.
    mutating func decrement(_ id: String, leads: Bool) {
        let left = ((leads ? leadCounts[id] : counts[id]) ?? 0) - 1
        if leads {
            leadCounts[id] = left > 0 ? left : nil
            if left <= 0 { recentLeads.removeAll { $0 == id } }
        } else {
            counts[id] = left > 0 ? left : nil
            if left <= 0 { recent.removeAll { $0 == id } }
        }
    }
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

    /// Index of `format`'s usage, creating it if needed.
    private func index(for format: RankingFormat) -> Int {
        if let existing = usage.firstIndex(where: { $0.formatId == format.id }) { return existing }
        usage.append(OpponentUsage(formatId: format.id))
        return usage.count - 1
    }

    /// Records that `speciesId` was the opponent's lead in `format`.
    func recordLead(_ speciesId: String, in format: RankingFormat) {
        let i = index(for: format)
        usage[i].leadCounts[speciesId, default: 0] += 1
        usage[i].recentLeads.removeAll { $0 == speciesId }
        usage[i].recentLeads.insert(speciesId, at: 0)
        if usage[i].recentLeads.count > Self.maxRecent {
            usage[i].recentLeads.removeLast(usage[i].recentLeads.count - Self.maxRecent)
        }
        persist()
    }

    /// Undoes one `recordLead`, for a lead that was marked on the wrong
    /// Pokémon and then corrected.
    func unrecordLead(_ speciesId: String, in format: RankingFormat) {
        guard let i = usage.firstIndex(where: { $0.formatId == format.id }) else { return }
        usage[i].decrement(speciesId, leads: true)
        persist()
    }

    /// A checked opponent was switched to another form (`old` → `new`), so
    /// the count follows it rather than crediting a form that wasn't faced.
    func replace(_ old: String, with new: String, isLead: Bool, in format: RankingFormat) {
        guard old != new, let i = usage.firstIndex(where: { $0.formatId == format.id }) else { return }
        usage[i].decrement(old, leads: false)
        usage[i].counts[new, default: 0] += 1
        usage[i].recent.removeAll { $0 == new }
        usage[i].recent.insert(new, at: 0)
        if isLead {
            usage[i].decrement(old, leads: true)
            usage[i].leadCounts[new, default: 0] += 1
            usage[i].recentLeads.removeAll { $0 == new }
            usage[i].recentLeads.insert(new, at: 0)
        }
        persist()
    }

    /// Recent leads with how often each has led, most recent first.
    func recentLeads(in format: RankingFormat) -> [(speciesId: String, count: Int)] {
        guard let u = usage.first(where: { $0.formatId == format.id }) else { return [] }
        return u.recentLeads.map { (speciesId: $0, count: u.leadCounts[$0] ?? 0) }
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
