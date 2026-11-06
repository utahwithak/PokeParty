//
//  OpponentStripReader.swift
//  PokeParty
//
//  Reads the opponent's name and CP from the top-right panel of a Pokémon GO
//  battle frame ("CP 1465   Sneasel"). Only that panel is handed to Vision
//  (via `regionOfInterest`), so no cropped copy of the frame is made and OCR
//  stays cheap.
//

import CoreVideo
import Foundation
import Vision

nonisolated struct OpponentReading: Equatable, Sendable {
    var name: String
    var cp: Int?
}

/// Not thread-safe: owns a reusable Vision request, so keep each instance on
/// one queue (the stream's sample-handler queue).
nonisolated final class OpponentStripReader {

    /// The opponent panel, in Vision's normalized coordinates (origin at the
    /// *bottom*-left): x 58–100%, and 9–15% down from the top. Measured on an
    /// iPhone screenshot of a PvP battle. It deliberately starts below the
    /// status bar (whose battery percentage would read as a CP) and ends
    /// above the bench tiles, whose CPs belong to the player's own team.
    static let region = CGRect(x: 0.58, y: 0.85, width: 0.42, height: 0.06)
    /// Your own panel, mirrored on the left ("Greninja158   CP 1483").
    static let myRegion = CGRect(x: 0.0, y: 0.85, width: 0.42, height: 0.06)

    /// Lines returned by the most recent `read`, for the on-screen debug readout.
    private(set) var lastRawLines: [String] = []

    /// Reused across frames — building a text request is comparatively costly.
    private let request: VNRecognizeTextRequest

    /// `region` picks which header panel is read (default: the opponent's).
    init(region: CGRect = OpponentStripReader.region) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Species names aren't dictionary words; correction mangles them.
        request.usesLanguageCorrection = false
        request.regionOfInterest = region
        self.request = request
    }

    func read(_ pixelBuffer: CVPixelBuffer) -> OpponentReading? {
        var lines: [String] = []
        autoreleasepool {
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
            guard (try? handler.perform([request])) != nil else { return }
            lines = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first }
                .filter { $0.confidence >= 0.3 }
                .map(\.string)
        }
        lastRawLines = lines
        return Self.parse(lines)
    }

    // MARK: - Parsing

    private static let cpPattern = try! NSRegularExpression(pattern: #"\bCP\s*(\d{2,4})\b"#, options: .caseInsensitive)

    /// Pulls a name and CP out of the panel's OCR lines. The CP may share a
    /// line with the name ("CP 1465 Sneasel"), sit on its own line, or be a
    /// bare number; the name is the longest remaining line with real letters.
    static func parse(_ lines: [String]) -> OpponentReading? {
        var cp: Int?
        var names: [String] = []

        for line in lines {
            var text = line
            let full = NSRange(text.startIndex..., in: text)
            if let match = cpPattern.firstMatch(in: text, range: full),
               let digits = Range(match.range(at: 1), in: text),
               let whole = Range(match.range, in: text) {
                cp = cp ?? Int(text[digits])
                text.removeSubrange(whole)
            }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // A lone 3–4 digit number is the CP with its small "CP" label read
            // separately (or dropped).
            if cp == nil, (3...4).contains(trimmed.count), trimmed.allSatisfy(\.isNumber) {
                cp = Int(trimmed)
                continue
            }

            let cleaned = String(trimmed.filter { $0.isLetter || " '-.:()".contains($0) })
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.filter(\.isLetter).count >= 3 {
                names.append(cleaned)
            }
        }

        guard let name = names.max(by: { $0.count < $1.count }) else { return nil }
        return OpponentReading(name: name, cp: cp)
    }

    // MARK: - Change detection

    /// A coarse fingerprint of the panel. Comparing two of these is far
    /// cheaper than running OCR, so OCR only runs when the panel changed.
    static func signature(of pixelBuffer: CVPixelBuffer, region: CGRect = OpponentStripReader.region) -> [UInt8]? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        // Bi-planar YUV: plane 0 is luma. Otherwise sample the packed buffer's
        // first byte per pixel (blue, for BGRA — plenty to see text change).
        let planar = CVPixelBufferGetPlaneCount(pixelBuffer) > 0
        let base = planar
            ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
            : CVPixelBufferGetBaseAddress(pixelBuffer)
        guard let base else { return nil }
        let width = planar ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) : CVPixelBufferGetWidth(pixelBuffer)
        let height = planar ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) : CVPixelBufferGetHeight(pixelBuffer)
        let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) : CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytesPerPixel = planar ? 1 : 4

        let columns = 32, rows = 8
        let x0 = Int(region.minX * CGFloat(width))
        let regionWidth = Int(region.width * CGFloat(width))
        // `region` is bottom-left-origin; pixel rows count from the top.
        let y0 = Int((1 - region.maxY) * CGFloat(height))
        let regionHeight = Int(region.height * CGFloat(height))
        guard regionWidth >= columns, regionHeight >= rows else { return nil }

        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var result: [UInt8] = []
        result.reserveCapacity(columns * rows)
        for row in 0..<rows {
            let y = y0 + (row * regionHeight) / rows
            for column in 0..<columns {
                let x = x0 + (column * regionWidth) / columns
                result.append(bytes[y * stride + x * bytesPerPixel])
            }
        }
        return result
    }

    /// Mean absolute difference between two signatures (0–255).
    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var total = 0
        for i in 0..<a.count { total += abs(Int(a[i]) - Int(b[i])) }
        return Double(total) / Double(a.count)
    }
}
