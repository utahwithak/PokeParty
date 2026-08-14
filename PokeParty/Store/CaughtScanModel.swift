//
//  CaughtScanModel.swift
//  PokeParty
//
//  Observable model for the "Scan Caught" sheet. Runs the same continuous
//  capture → OCR loop as ScannerModel, but outputs IVs + multi-league ranks
//  rather than a staged bench entry. Backed by ScreenScanner, which is
//  macOS-only.
//

#if os(macOS)

import Foundation
import SwiftUI

@MainActor
@Observable
final class CaughtScanModel {

    // MARK: - Types

    enum LiveStatus {
        case idle
        case scanning
        case found(LiveScan)
        case error(String)
    }

    struct LiveScan {
        var rawName: String
        var cp: Int?
        var level: Double?
        var maxHP: Int?
        var speciesId: String?
        /// True when all three IVs were read from the appraisal bars this tick.
        var fromBars: Bool
    }

    // MARK: - State

    var liveStatus: LiveStatus = .idle
    /// Current IV spread — updated from bar readings, also user-adjustable.
    var ivs = IVs(atk: 15, def: 15, hp: 15)
    /// Most recently matched species.
    var speciesId: String?

    var isScanning: Bool { liveTask != nil }

    // MARK: - Scanning

    private let scanner = ScreenScanner()
    private var liveTask: Task<Void, Never>?

    func startScanning(store: RankingsStore) {
        guard liveTask == nil else { return }
        liveStatus = .scanning
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scan(store: store)
                try? await Task.sleep(for: .seconds(4.5))
            }
        }
    }

    func stopScanning() {
        liveTask?.cancel()
        liveTask = nil
    }

    private func scan(store: RankingsStore) async {
        do {
            let image = try await scanner.capturePhoneMirroringFrame()
            let observations = try await scanner.recognizeText(in: image)

            guard let info = await scanner.extractPokemonInfo(from: observations) else {
                liveStatus = .error(ScanError.parseFailure.localizedDescription)
                return
            }

            let sid = fuzzyMatch(info.name, in: store.pokemonById)
            let barIVs = await scanner.extractBarIVs(from: observations, image: image)

            var fromBars = false
            if let atk = barIVs?.atk, let def = barIVs?.def, let hp = barIVs?.hp {
                ivs = IVs(atk: atk, def: def, hp: hp)
                fromBars = true
            }
            if let sid { speciesId = sid }

            liveStatus = .found(LiveScan(
                rawName: info.name, cp: info.cp, level: info.level, maxHP: info.maxHP,
                speciesId: sid, fromBars: fromBars
            ))
        } catch {
            liveStatus = .error(error.localizedDescription)
        }
    }

    // MARK: - Helpers (mirrors ScannerModel)

    private func fuzzyMatch(_ raw: String, in pokemonById: [String: Pokemon]) -> String? {
        let needle = normalized(raw)
        guard !needle.isEmpty else { return nil }
        var best: (id: String, score: Int)?
        for (id, pokemon) in pokemonById {
            let hay = normalized(pokemon.speciesName)
            let score: Int
            if      hay == needle                                  { score = 3 }
            else if hay.hasPrefix(needle) || needle.hasPrefix(hay) { score = 2 }
            else if hay.contains(needle)  || needle.contains(hay)  { score = 1 }
            else { continue }
            if best == nil || score > best!.score { best = (id, score) }
        }
        return best?.id
    }

    private func normalized(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "♀", with: "f")
            .replacingOccurrences(of: "♂", with: "m")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

#endif
