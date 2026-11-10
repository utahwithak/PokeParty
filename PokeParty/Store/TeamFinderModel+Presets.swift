//
//  TeamFinderModel+Presets.swift
//  PokeParty
//
//  One-tap presets for the settings that decide how long and how thorough a
//  Party Finder run is, so most runs never need the detailed controls.
//

import Foundation

extension TeamFinderModel {

    /// Effort levels. Each sets the candidate pool, tournament field, optimizer
    /// restarts and counterswap realism together; the learned AIs are always on
    /// and optimal shield timing off (it is far too slow for a preset).
    enum Preset: String, CaseIterable, Identifiable {
        case quick, balanced, thorough

        var id: Self { self }

        var title: String {
            switch self {
            case .quick: return "Quick"
            case .balanced: return "Balanced"
            case .thorough: return "Thorough"
            }
        }

        var poolSize: Int {
            switch self {
            case .quick: return 50
            case .balanced: return 100
            case .thorough: return 150
            }
        }

        var fieldSize: Int {
            switch self {
            case .quick: return 100
            case .balanced: return 300
            case .thorough: return 600
            }
        }

        var restarts: Int {
            switch self {
            case .quick: return 10
            case .balanced: return 20
            case .thorough: return 40
            }
        }

        var simulateCounterswaps: Bool { self == .thorough }

        /// What the preset changes, for the caption under the picker.
        var detail: String {
            "Top \(poolSize) pool, \(fieldSize)-team field, \(restarts) restarts"
                + (simulateCounterswaps ? ", counterswaps on" : "")
        }
    }

    /// The preset the current settings exactly match, or nil once any of its
    /// settings has been adjusted by hand ("Custom").
    var currentPreset: Preset? {
        guard learnedShields, learnedSwitches, learnedFarming, !optimalShields else { return nil }
        return Preset.allCases.first {
            $0.poolSize == poolSize && $0.fieldSize == fieldSize
                && $0.restarts == restarts && $0.simulateCounterswaps == simulateCounterswaps
        }
    }

    func apply(_ preset: Preset) {
        poolSize = preset.poolSize   // also resets the meta field size to its default
        fieldSize = preset.fieldSize
        restarts = preset.restarts
        simulateCounterswaps = preset.simulateCounterswaps
        learnedShields = true
        learnedSwitches = true
        learnedFarming = true
        optimalShields = false
    }
}
