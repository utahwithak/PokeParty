//
//  OpponentTypeReader.swift
//  PokeParty
//
//  Reads the opponent's type icons — the one or two small coloured circles
//  above the CP panel — as raw fill colours. `OpponentNameMatcher.narrow`
//  then compares them with the types of each candidate form, which tells
//  regional variants apart when the name alone can't (Ninetales: fire vs.
//  ice/fairy; Golem: rock/ground vs. rock/electric; Weezing: one icon vs. two).
//
//  Colours rather than glyphs, and compared only *between a name's own
//  candidates*, so it doesn't matter that most of `TypeColors.table` is
//  approximate.
//

import CoreVideo
import Foundation

nonisolated struct IconColor: Equatable, Sendable, Codable {
    var r: Double
    var g: Double
    var b: Double

    func distance(to other: IconColor) -> Double {
        let dr = r - other.r, dg = g - other.g, db = b - other.b
        return (dr * dr + dg * dg + db * db).squareRoot()
    }
}

nonisolated enum TypeColors {
    /// Icon fill colours. Dark, ice, ghost and fairy were sampled from a real
    /// battle screenshot; the rest are estimates and should be replaced with
    /// sampled values as screenshots of those types turn up (the debug readout
    /// prints each icon's measured colour).
    static let table: [String: IconColor] = [
        // Measured.
        "dark": IconColor(r: 98, g: 97, b: 113),
        "ice": IconColor(r: 148, g: 211, b: 201),
        "ghost": IconColor(r: 103, g: 110, b: 186),
        "fairy": IconColor(r: 228, g: 158, b: 224),
        // Estimated.
        "normal": IconColor(r: 160, g: 162, b: 159),
        "fire": IconColor(r: 240, g: 128, b: 48),
        "water": IconColor(r: 80, g: 144, b: 215),
        "electric": IconColor(r: 244, g: 210, b: 60),
        "grass": IconColor(r: 90, g: 190, b: 90),
        "fighting": IconColor(r: 206, g: 64, b: 105),
        "poison": IconColor(r: 171, g: 106, b: 200),
        "ground": IconColor(r: 217, g: 119, b: 67),
        "flying": IconColor(r: 143, g: 168, b: 221),
        "psychic": IconColor(r: 249, g: 113, b: 118),
        "bug": IconColor(r: 144, g: 193, b: 44),
        "rock": IconColor(r: 199, g: 183, b: 139),
        "dragon": IconColor(r: 10, g: 109, b: 197),
        "steel": IconColor(r: 90, g: 142, b: 162),
    ]

    /// The closest known type to `icon`, for the debug readout.
    static func nearest(to icon: IconColor) -> (type: String, distance: Double)? {
        table.map { ($0.key, $0.value.distance(to: icon)) }.min { $0.1 < $1.1 }
    }
}

nonisolated enum OpponentTypeReader {

    /// Icon centres as fractions of the frame's width and height, and the
    /// icon radius as a fraction of the width — measured on an iPhone
    /// screenshot. The opponent's icons are right-aligned under the status
    /// bar; both slots are checked, and an empty one is simply skipped.
    private static let slots: [(x: Double, y: Double)] = [(0.9005, 0.0774), (0.9560, 0.0774)]
    private static let radiusFraction = 0.0216

    /// Mean per-channel wobble allowed around an icon's ring (a flat fill has little).
    private static let maxRingDeviation = 20.0
    /// A real icon's ring differs from the scenery just outside it; a patch of
    /// plain sky doesn't, which is what stops it reading as a "water" icon.
    private static let minContrastWithSurroundings = 45.0

    /// Fill colours of the icons found, left to right. Empty when the frame
    /// isn't BGRA or no icon-like circle is present.
    static func read(_ pixelBuffer: CVPixelBuffer) -> [IconColor] {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return [] }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return [] }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        func pixel(_ x: Double, _ y: Double) -> IconColor? {
            let px = Int(x.rounded()), py = Int(y.rounded())
            guard px >= 0, py >= 0, px < width, py < height else { return nil }
            let offset = py * stride + px * 4
            return IconColor(r: Double(bytes[offset + 2]), g: Double(bytes[offset + 1]), b: Double(bytes[offset]))
        }

        /// Median colour of points on a circle, plus their mean deviation from it.
        func ring(cx: Double, cy: Double, radius: Double) -> (color: IconColor, deviation: Double)? {
            let samples = (0..<16).compactMap { i -> IconColor? in
                let angle = Double(i) * .pi / 8
                return pixel(cx + radius * cos(angle), cy + radius * sin(angle))
            }
            guard samples.count == 16 else { return nil }
            func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
            let color = IconColor(r: median(samples.map(\.r)), g: median(samples.map(\.g)), b: median(samples.map(\.b)))
            let deviation = samples.map { abs($0.r - color.r) + abs($0.g - color.g) + abs($0.b - color.b) }
                .reduce(0, +) / Double(samples.count * 3)
            return (color, deviation)
        }

        let radius = radiusFraction * Double(width)
        var icons: [IconColor] = []
        for slot in slots {
            let cx = slot.x * Double(width), cy = slot.y * Double(height)
            guard let inner = ring(cx: cx, cy: cy, radius: radius * 0.62),
                  inner.deviation <= maxRingDeviation,
                  let outer = ring(cx: cx, cy: cy, radius: radius * 1.35),
                  inner.color.distance(to: outer.color) >= minContrastWithSurroundings
            else { continue }
            icons.append(inner.color)
        }
        return icons
    }
}
