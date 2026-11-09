//
//  BattleHeaderReader.swift
//  PokeParty
//
//  Reads the state shown in a Pokémon GO battle's two header panels without
//  OCR, by sampling colours at fixed positions (measured on iPhone screenshots
//  of a PvP battle):
//   - the three Poké Ball icons per side — red while the Pokémon is alive,
//     dark once it has fainted;
//   - the lavender shield hexagons per side.
//  Your own type icons are read with `OpponentTypeReader` (mirrored slots).
//
//  A frame only counts as a battle screen if both sides show three balls, which
//  is what keeps menus and other apps from producing readings.
//

import CoreVideo
import Foundation
import Vision

nonisolated struct BattleHeaderReading: Equatable, Sendable {
    var myShields: Int
    var opponentShields: Int
    var myAlive: Int
    var opponentAlive: Int
}

nonisolated enum BattleHeaderReader {

    /// Icon centres as fractions of the frame's width and height.
    private static let nominalY = 0.1310
    private static let myBalls: [Double] = [0.0543, 0.1076, 0.1620]
    private static let myShieldSlots: [Double] = [0.2359, 0.2826]
    private static let opponentShieldSlots: [Double] = [0.7174, 0.7641]
    private static let opponentBalls: [Double] = [0.8370, 0.8913, 0.9457]

    /// The shield hexagon's fill, sampled from a real battle.
    private static let shieldColor = IconColor(r: 209, g: 165, b: 235)
    private static let shieldTolerance = 45.0

    private enum Ball { case alive, fainted, empty }

    /// Colours sampled at each header slot.
    private struct Samples {
        var myBalls: [IconColor]
        var opponentBalls: [IconColor]
        var myShields: [IconColor]
        var opponentShields: [IconColor]
    }

    /// nil unless the frame is BGRA and every slot is inside it.
    private static func sample(_ pixelBuffer: CVPixelBuffer, yShift: Double = 0) -> Samples? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        /// Median colour of a small plus-shaped patch, so one stray pixel doesn't decide.
        func color(atX fraction: Double) -> IconColor? {
            let cx = Int((fraction * Double(width)).rounded())
            let cy = Int(((nominalY + yShift) * Double(height)).rounded())
            let reach = max(2, Int(0.004 * Double(width)))
            let offsets = [(0, 0), (reach, 0), (-reach, 0), (0, reach), (0, -reach)]
            var rs: [Double] = [], gs: [Double] = [], bs: [Double] = []
            for (dx, dy) in offsets {
                let px = cx + dx, py = cy + dy
                guard px >= 0, py >= 0, px < width, py < height else { return nil }
                let offset = py * stride + px * 4
                rs.append(Double(bytes[offset + 2]))
                gs.append(Double(bytes[offset + 1]))
                bs.append(Double(bytes[offset]))
            }
            func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
            return IconColor(r: median(rs), g: median(gs), b: median(bs))
        }
        func colors(_ xs: [Double]) -> [IconColor]? {
            let found = xs.compactMap(color(atX:))
            return found.count == xs.count ? found : nil
        }

        guard let mb = colors(myBalls), let ob = colors(opponentBalls),
              let ms = colors(myShieldSlots), let os = colors(opponentShieldSlots)
        else { return nil }
        return Samples(myBalls: mb, opponentBalls: ob, myShields: ms, opponentShields: os)
    }

    /// nil unless the frame is BGRA and both sides show three balls.
    static func read(_ pixelBuffer: CVPixelBuffer, yShift: Double = 0) -> BattleHeaderReading? {
        guard let samples = sample(pixelBuffer, yShift: yShift) else { return nil }
        let mine = samples.myBalls.map(classifyBall)
        let theirs = samples.opponentBalls.map(classifyBall)
        guard mine.filter({ $0 != .empty }).count == 3,
              theirs.filter({ $0 != .empty }).count == 3
        else { return nil }

        func shields(_ colors: [IconColor]) -> Int {
            colors.filter { $0.distance(to: shieldColor) <= shieldTolerance }.count
        }
        return BattleHeaderReading(
            myShields: shields(samples.myShields),
            opponentShields: shields(samples.opponentShields),
            myAlive: mine.filter { $0 == .alive }.count,
            opponentAlive: theirs.filter { $0 == .alive }.count)
    }

    /// How far (as a fraction of the frame's height) the header sits from where
    /// the slot positions above were measured. The panels hang off the top safe
    /// area, so a phone with a different notch or status bar has them higher or
    /// lower; every header-relative reader takes this shift. Found by sliding
    /// the ball row until all six balls line up, trying the smallest shifts first.
    static func findShift(_ pixelBuffer: CVPixelBuffer) -> Double? {
        let steps = Array(-40...25).map { Double($0) * 0.0015 }.sorted { abs($0) < abs($1) }
        return steps.first { read(pixelBuffer, yShift: $0) != nil }
    }

    /// A pixel format's four-character code ("BGRA", "420v"…).
    static func fourCC(_ format: OSType) -> String {
        String(bytes: (0..<4).map { UInt8((format >> UInt32(24 - 8 * $0)) & 0xFF) }, encoding: .ascii) ?? "?"
    }

    /// One line describing what the reader sees, for the on-screen debug readout:
    /// the frame's format and size, and the colour at each header slot. This is
    /// how to tell a wrong pixel format or a mis-sized frame from a wrong position.
    static func diagnose(_ pixelBuffer: CVPixelBuffer, yShift: Double = 0) -> String {
        let code = fourCC(CVPixelBufferGetPixelFormatType(pixelBuffer))
        let size = "\(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))"
        guard let samples = sample(pixelBuffer, yShift: yShift) else { return "fmt \(code) \(size) — not BGRA, header unreadable" }
        func list(_ colors: [IconColor]) -> String {
            colors.map { "\(Int($0.r)),\(Int($0.g)),\(Int($0.b))" }.joined(separator: " ")
        }
        let result = read(pixelBuffer, yShift: yShift).map { "\($0)" } ?? "no battle header"
        return "fmt \(code) \(size) — \(result)\nballs L[\(list(samples.myBalls))] R[\(list(samples.opponentBalls))]\nshields L[\(list(samples.myShields))] R[\(list(samples.opponentShields))]"
    }

    private static func classifyBall(_ c: IconColor) -> Ball {
        // The panel behind an empty slot is white.
        if c.r > 235, c.g > 235, c.b > 235 { return .empty }
        // Alive: the ball's red half.
        if c.r > 170, c.g < 110, c.b < 100 { return .alive }
        // Fainted: the same ball dimmed to a dark brown-grey.
        if c.r < 150, c.g < 110, c.b < 110, c.r >= c.g { return .fainted }
        return .empty
    }
}

// MARK: - Effectiveness flash

/// "SUPER EFFECTIVE!" / "NOT VERY EFFECTIVE…" — the floating label that appears
/// above your active Pokémon's HP bar when an opposing fast move hits it.
/// Neutral hits show nothing.
nonisolated enum EffectivenessFlash: String, Codable, Equatable, Sendable {
    case superEffective
    case notVeryEffective

    /// Reads OCR lines, tolerating the usual slips ("SUPER EFFECTIV E!").
    static func parse(_ lines: [String]) -> EffectivenessFlash? {
        for line in lines {
            let letters = line.uppercased().filter(\.isLetter)
            // Check "not very" first: it also contains "effective".
            if letters.contains("NOTVERY") { return .notVeryEffective }
            if letters.contains("SUPEREFF") || letters.contains("SUPEREFFECTIVE") { return .superEffective }
        }
        return nil
    }
}

// MARK: - Faint messages

/// "<Pokémon> fainted!" — the message shown when a Pokémon is knocked out. The
/// name says *which* Pokémon, which the Pokémon-left icons can't.
nonisolated enum FaintedMessage {
    /// The text before "fainted" on each line that has it. The caller matches
    /// these against known Pokémon names; leading words like "Your" are left in
    /// and ignored by that match. Tolerates OCR slips in the word itself
    /// ("fainled", "falnted!") and a message split over two lines
    /// ("Greninja" / "fainted!").
    static func names(from lines: [String]) -> [String] {
        var names: [String] = []
        for (index, line) in lines.enumerated() {
            guard let marker = faintWord(in: line) else { continue }
            var prefix = clean(String(line[..<marker.lowerBound]))
            if prefix.filter(\.isLetter).count < 3, index > 0 {
                prefix = clean(lines[index - 1])      // the name on the line before
            }
            if prefix.filter(\.isLetter).count >= 3 { names.append(prefix) }
        }
        return names
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.letters.inverted.subtracting(CharacterSet(charactersIn: "'-")))
    }

    /// The range of the first word within two edits of "fainted".
    private static func faintWord(in line: String) -> Range<String.Index>? {
        var start = line.startIndex
        while start < line.endIndex {
            guard let wordStart = line[start...].firstIndex(where: \.isLetter) else { return nil }
            let wordEnd = line[wordStart...].firstIndex(where: { !$0.isLetter }) ?? line.endIndex
            if editDistance(line[wordStart..<wordEnd].lowercased(), "fainted") <= 2 { return wordStart..<wordEnd }
            start = wordEnd
        }
        return nil
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}

// MARK: - Result screen

/// The big "YOU WIN!" / "Good Effort" shown over the trainer when a battle ends.
nonisolated enum BattleResultText {
    /// Reads OCR lines, top of the screen first. The win screen says "YOU WIN!",
    /// the loss screen "GOOD" over "EFFORT!" — two lines — so each line is also
    /// read joined to the one after it.
    static func parse(_ lines: [String]) -> BattleOutcome? {
        let letters = lines.map { $0.uppercased().filter(\.isLetter) }
        for index in letters.indices {
            let candidates = index + 1 < letters.count ? [letters[index], letters[index] + letters[index + 1]] : [letters[index]]
            for text in candidates {
                if text.contains("YOUWIN") { return .win }
                if text.contains("GOODEFFORT") { return .loss }
            }
        }
        return nil
    }
}

// MARK: - Text reader

/// What one OCR pass over the battle screen found.
nonisolated struct BattleText: Equatable, Sendable {
    var flash: EffectivenessFlash?
    /// How far down the screen the effectiveness label was (0 top … 1 bottom).
    /// It floats over the Pokémon that was hit: upper half is the opponent.
    var flashY: Double?
    /// Names from any "<name> fainted" messages.
    var fainted: [String]
    /// "YOU WIN!" / "Good Effort" on the result screen.
    var result: BattleOutcome?
    /// Every line read, with where it was, top of the screen first.
    var screenLines: [ScreenLine]

    var lines: [String] { screenLines.map(\.text) }
}

/// OCRs the whole battle screen in one pass: the effectiveness label, faint
/// messages, move banners, the result screen. Not thread-safe: keep each
/// instance on one queue, like `OpponentStripReader`.
nonisolated final class BattleTextReader {
    /// Lines Vision is less sure of than this are dropped: the 3D scene produces
    /// plenty of confident-looking nonsense at low confidence.
    static let minimumConfidence: Float = 0.5
    /// Text shorter than this fraction of the frame's height isn't a label or
    /// banner. Scenery texture reads as tiny "text".
    static let minimumTextHeight: Float = 0.012

    private let request: VNRecognizeTextRequest = {
        let request = VNRecognizeTextRequest()
        // White text can sit over white smoke effects; the fast path misses it.
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = BattleTextReader.minimumTextHeight
        return request
    }()

    func read(_ pixelBuffer: CVPixelBuffer) -> BattleText {
        var lines: [ScreenLine] = []
        autoreleasepool {
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
            guard (try? handler.perform([request])) != nil else { return }
            for observation in request.results ?? [] {
                guard let candidate = observation.topCandidates(1).first,
                      candidate.confidence >= Self.minimumConfidence,
                      !lines.contains(where: { $0.text == candidate.string }) else { continue }
                // Vision's origin is the bottom-left; the screen reads from the top.
                lines.append(ScreenLine(text: candidate.string, y: 1 - observation.boundingBox.midY))
            }
        }
        lines.sort { $0.y < $1.y }
        let text = lines.map(\.text)
        return BattleText(
            flash: EffectivenessFlash.parse(text),
            flashY: lines.first { EffectivenessFlash.parse([$0.text]) != nil }?.y,
            fainted: FaintedMessage.names(from: text),
            result: BattleResultText.parse(text),
            screenLines: lines)
    }
}
