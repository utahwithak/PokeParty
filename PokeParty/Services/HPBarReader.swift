//
//  HPBarReader.swift
//  PokeParty
//
//  Reads the two active Pokémon's HP bars off a battle frame. The bars float
//  over the Pokémon, so their position moves with the animation; what stays
//  fixed is their look: a white outline around a dark track, with a flat,
//  saturated fill (mint green at high HP; other colours as it drops) anchored
//  at the left. So instead of sampling fixed positions it looks for that
//  structure and measures how much of the track the fill covers.
//
//  A bar is accepted only if it has a flat coloured run, a white border above
//  and below it, and a track of the expected width ending at a white edge —
//  scenery (orange leaves, clothing) is textured and fails the flat-run test,
//  and the small bench-card bars are far too short.
//

import CoreVideo
import Foundation

nonisolated struct HPReading: Equatable, Sendable {
    /// Fraction of HP left (0…1) for your active Pokémon; nil if its bar wasn't found.
    var mine: Double?
    var opponent: Double?
}

nonisolated enum HPBarReader {

    /// Rows searched, as fractions of the frame's height: the area the bars float in.
    private static let rowRange = 0.30...0.80
    /// Shortest flat run counted as a possible bar fill (fraction of width). A
    /// nearly empty bar is a short run, so this is kept small; the white-border
    /// and track checks do the rejecting.
    private static let minRun = 0.012
    /// A bar's full track, border to border, as a fraction of the frame's width.
    private static let trackWidth = 0.20...0.34

    private struct Run {
        var y: Int
        var x0: Int
        var x1: Int
    }

    static func read(_ pixelBuffer: CVPixelBuffer) -> HPReading {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return HPReading() }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return HPReading() }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        @inline(__always) func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
            let o = y * stride + x * 4
            return (Int(bytes[o + 2]), Int(bytes[o + 1]), Int(bytes[o]))
        }
        /// Saturated and bright: a fill colour, not scenery shadow or a grey UI panel.
        @inline(__always) func isFill(_ p: (r: Int, g: Int, b: Int)) -> Bool {
            max(p.r, p.g, p.b) - min(p.r, p.g, p.b) >= 60 && max(p.r, p.g, p.b) >= 110
        }
        @inline(__always) func similar(_ a: (r: Int, g: Int, b: Int), _ b: (r: Int, g: Int, b: Int)) -> Bool {
            abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b) <= 12
        }
        @inline(__always) func isWhite(_ p: (r: Int, g: Int, b: Int)) -> Bool {
            p.r >= 238 && p.g >= 238 && p.b >= 238
        }

        let minRunPixels = max(8, Int(minRun * Double(width)))
        let yStart = Int(rowRange.lowerBound * Double(height))
        let yEnd = min(Int(rowRange.upperBound * Double(height)), height - 1)

        // 1. Flat saturated runs, every other row.
        var runs: [Run] = []
        var y = yStart
        while y < yEnd {
            var x = 0
            while x < width {
                let p = pixel(x, y)
                guard isFill(p) else { x += 1; continue }
                var end = x + 1
                while end < width, similar(pixel(end, y), p) { end += 1 }
                if end - x >= minRunPixels { runs.append(Run(y: y, x0: x, x1: end)) }
                x = end
            }
            y += 2
        }

        // 2. Stack runs that line up into candidate bars (a fill is ~20 px tall).
        var groups: [[Run]] = []
        for run in runs {
            if let index = groups.lastIndex(where: { group in
                guard let last = group.last else { return false }
                return abs(last.x0 - run.x0) <= 4 && run.y - last.y <= 4
            }) {
                groups[index].append(run)
            } else {
                groups.append([run])
            }
        }

        var mine: Double?, opponent: Double?
        var mineRows = 0, opponentRows = 0
        for group in groups where group.count >= 4 {
            guard let first = group.first, let last = group.last else { continue }
            let top = first.y, bottom = last.y
            let mid = group[group.count / 2]
            let x0 = mid.x0, x1 = mid.x1
            let midX = (x0 + x1) / 2

            // 3. A white border above and below the fill.
            func whiteNear(_ range: ClosedRange<Int>) -> Bool {
                range.contains { yy in yy >= 0 && yy < height && isWhite(pixel(midX, yy)) }
            }
            guard whiteNear((top - 18)...(top - 2)), whiteNear((bottom + 2)...(bottom + 18)) else { continue }

            // 4. The track runs on from the fill to the white edge at the bar's right end.
            let limit = min(width - 1, x0 + Int(trackWidth.upperBound * Double(width)))
            var edge = x1
            while edge < limit, !isWhite(pixel(edge, mid.y)) { edge += 1 }
            guard isWhite(pixel(edge, mid.y)) else { continue }
            let total = edge - x0
            guard Double(total) >= trackWidth.lowerBound * Double(width) * 0.9,
                  Double(total) <= trackWidth.upperBound * Double(width)
            else { continue }

            let fraction = min(1, max(0, Double(x1 - x0) / Double(total)))
            if midX < width / 2 {
                if group.count > mineRows { mine = fraction; mineRows = group.count }
            } else {
                if group.count > opponentRows { opponent = fraction; opponentRows = group.count }
            }
        }
        return HPReading(mine: mine, opponent: opponent)
    }
}
