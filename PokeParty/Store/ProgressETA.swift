//
//  ProgressETA.swift
//  PokeParty
//
//  Time-remaining estimate for long runs. Feed it completed fractions
//  (battles fought ÷ expected battles, pairs graded ÷ total pairs, …) as they
//  arrive; it measures the recent speed and extrapolates to 100%.
//

import Foundation

struct ProgressETA {
    private struct Sample {
        let time: ContinuousClock.Instant
        let fraction: Double
    }

    private var samples: [Sample] = []

    /// Speed is measured over this trailing window, so the estimate tracks
    /// the current pace (battles get cheaper or dearer as a run progresses)
    /// without jittering on every update.
    private static let window: Duration = .seconds(30)
    /// Don't show an estimate until there's enough data to be believable.
    private static let minimumElapsed: Duration = .seconds(3)
    private static let minimumFraction = 0.005

    mutating func reset() { samples.removeAll() }

    /// Records the overall completed fraction (0…1) at the current moment.
    mutating func record(_ fraction: Double, at time: ContinuousClock.Instant = .now) {
        // Out-of-order callbacks hop actors independently; ignore regressions.
        if let last = samples.last, fraction <= last.fraction { return }
        samples.append(Sample(time: time, fraction: fraction))
        let cutoff = time - Self.window
        // Keep one sample at/before the cutoff as the window's anchor.
        while samples.count > 2, samples[1].time <= cutoff { samples.removeFirst() }
    }

    /// Estimated seconds until completion, or nil while there's too little data.
    var remainingSeconds: Double? {
        guard let first = samples.first, let last = samples.last,
              last.time - first.time >= Self.minimumElapsed,
              last.fraction >= Self.minimumFraction,
              last.fraction > first.fraction
        else { return nil }
        let elapsed = last.time - first.time
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        let rate = (last.fraction - first.fraction) / seconds
        return max(1 - last.fraction, 0) / rate
    }

    /// e.g. "about 12 min remaining", or nil while still measuring.
    var label: String? {
        guard let seconds = remainingSeconds else { return nil }
        let rounded = Duration.seconds(seconds < 60 ? seconds.rounded() : (seconds / 60).rounded() * 60)
        let text = rounded.formatted(.units(allowed: [.days, .hours, .minutes, .seconds],
                                            width: .abbreviated, maximumUnitCount: 2))
        return "about \(text) remaining"
    }
}
