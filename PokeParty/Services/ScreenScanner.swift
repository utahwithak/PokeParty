//
//  ScreenScanner.swift
//  PokeParty
//
//  Captures a frame from the iPhone Mirroring window via ScreenCaptureKit
//  and uses Vision OCR to extract the Pokémon's species, level, and HP
//  shown on the detail screen.
//
//  iPhone Mirroring and ScreenCaptureKit desktop-window capture are
//  macOS-only, so this whole file is unavailable on iOS.
//

#if os(macOS)

import AppKit
import Foundation
import ScreenCaptureKit
import Vision

enum ScanError: LocalizedError {
    case windowNotFound
    case parseFailure
    case accessibilityDenied
    case inputSynthesisFailed

    var errorDescription: String? {
        switch self {
        case .windowNotFound:
            "iPhone Mirroring window not found. Open iPhone Mirroring, navigate to a Pokémon's detail screen, then try again."
        case .parseFailure:
            "Could not read a Pokémon name. Make sure a Pokémon's detail screen is fully visible in iPhone Mirroring."
        case .accessibilityDenied:
            "Accessibility permission is required to auto-advance. Grant access in System Settings → Privacy & Security → Accessibility, then try again."
        case .inputSynthesisFailed:
            "Couldn't send the swipe gesture to iPhone Mirroring."
        }
    }
}

/// Values extracted from OCR of the Pokémon GO detail screen.
struct PokemonScanInfo {
    /// Species name — from "This {name} was caught…" if available; otherwise first plausible text.
    var name: String
    /// Level shown as "Lvl XX" or "Lvl XX.X" on the detail screen.
    var level: Double?
    /// Max HP shown as "XXX / XXX HP".
    var maxHP: Int?
    /// CP value if successfully read (the gold badge is often OCR-unreliable).
    var cp: Int?
}

/// IVs read directly off the Attack/Defense/HP fill bars on the detail
/// screen (each bar's fill fraction is the stat's IV / 15). nil per-stat
/// when that bar's label wasn't found or its fill couldn't be measured.
struct BarIVs {
    var atk: Int?
    var def: Int?
    var hp: Int?
}

actor ScreenScanner {

    // MARK: - Capture

    /// Finds the iPhone Mirroring window among `content`'s windows.
    ///
    /// Priority 1: ScreenContinuity window titled exactly "iPhone Mirroring".
    /// Priority 2: Any ScreenContinuity window large enough to be the mirroring viewport
    ///             (excludes the tiny menu-bar status icon at ~54×54).
    /// Priority 3: Any window with "iPhone Mirroring" in the title as a last resort.
    private func findMirroringWindow(in content: SCShareableContent) -> SCWindow? {
        content.windows.first {
            $0.owningApplication?.bundleIdentifier == "com.apple.ScreenContinuity"
                && $0.title == "iPhone Mirroring"
        } ?? content.windows.first {
            $0.owningApplication?.bundleIdentifier == "com.apple.ScreenContinuity"
                && $0.frame.width > 100 && $0.frame.height > 100
        } ?? content.windows.first {
            ($0.title ?? "").localizedCaseInsensitiveContains("iPhone Mirroring")
                && $0.frame.width > 100 && $0.frame.height > 100
        }
    }

    /// The iPhone Mirroring window's current on-screen frame, in the same
    /// global-display coordinate space `CGEventPost` expects — used to aim
    /// the auto-advance swipe without capturing a screenshot.
    private func mirroringWindowFrame() async throws -> CGRect {
        let content = try await SCShareableContent.current
        guard let window = findMirroringWindow(in: content) else {
            throw ScanError.windowNotFound
        }
        return window.frame
    }

    /// Finds the iPhone Mirroring window and returns a retina-resolution screenshot.
    func capturePhoneMirroringFrame() async throws -> CGImage {
        let content = try await SCShareableContent.current
        guard let window = findMirroringWindow(in: content) else {
            #if DEBUG
            // The list is only worth dumping when nothing matched — it's every
            // window on the system, and this runs on a loop.
            print("[ScreenScanner] No mirroring window among \(content.windows.count):")
            for w in content.windows {
                print("  bundleID=\(w.owningApplication?.bundleIdentifier ?? "nil")  title=\(w.title ?? "nil")  frame=\(w.frame)")
            }
            #endif
            throw ScanError.windowNotFound
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        // Capture at the display's native pixel density (physical pixels ÷ logical
        // points). Hardcoding × 2 upscales content on a 1× (non-Retina) display,
        // blurring bar fill/track edges so the saturation classifier in classify()
        // reads wrong IV fractions. On a 2× Retina display this computes the same
        // value as before; on a 1× display it captures at actual pixel resolution.
        //
        // SCDisplay.width/.height are documented as points — the same unit as
        // .frame.width/.height — so dividing one by the other (an earlier version
        // of this code) always yields ~1.0 and never detects Retina at all. The
        // actual backing scale has to come from the matching NSScreen instead.
        let displayScale: CGFloat = {
            var bestScale: CGFloat = 2.0
            var bestOverlap: CGFloat = 0
            for display in content.displays {
                let overlap = window.frame.intersection(display.frame).width
                guard overlap > bestOverlap else { continue }
                guard let screen = NSScreen.screens.first(where: {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
                }) else { continue }
                bestOverlap = overlap
                bestScale = screen.backingScaleFactor
            }
            return max(bestScale, 1.0)
        }()
        #if DEBUG
        print("[ScreenScanner] Display scale: \(displayScale)×  capture: \(Int(window.frame.width * displayScale))×\(Int(window.frame.height * displayScale))")
        #endif
        config.width  = max(Int(window.frame.width  * displayScale), 100)
        config.height = max(Int(window.frame.height * displayScale), 100)
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            #if DEBUG
            let nsError = error as NSError
            print("[ScreenScanner] Capture of \(config.width)×\(config.height)px failed: \(nsError.domain) \(nsError.code) — \(nsError.userInfo)")
            #endif
            throw error
        }
    }

    // MARK: - Input synthesis (auto-advance swipe)

    /// Whether this process currently has the Accessibility permission
    /// needed to post synthetic mouse events into other applications —
    /// separate from the Screen Recording permission used for capture.
    /// Passing `prompt: true` shows the system permission dialog (and adds
    /// the app to the Accessibility list) the first time it's called.
    func hasAccessibilityAccess(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): prompt] as CFDictionary)
    }

    /// Swipes from the top-right toward the top-left of the iPhone Mirroring
    /// window — the gesture Pokémon GO's detail/appraisal screen uses to
    /// advance to the next Pokémon in the box/list. The exact tap point
    /// doesn't matter as long as it clears the status bar and lands on the
    /// card, so this uses fixed proportions of the window rather than
    /// anything OCR-derived.
    func swipeToNextPokemon() async throws {
        guard hasAccessibilityAccess(prompt: true) else {
            throw ScanError.accessibilityDenied
        }
        let frame = try await mirroringWindowFrame()
        let y = frame.minY + frame.height * 0.18
        let start = CGPoint(x: frame.minX + frame.width * 0.85, y: y)
        let end = CGPoint(x: frame.minX + frame.width * 0.15, y: y)
        try await postDrag(from: start, to: end)
    }

    /// Posts a mouseDown at `start`, several interpolated mouseDragged
    /// events toward `end`, then a mouseUp at `end` — indistinguishable to
    /// the receiving app from a real trackpad/mouse drag.
    private func postDrag(from start: CGPoint, to end: CGPoint, steps: Int = 12) async throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ScanError.inputSynthesisFailed
        }
        func post(_ type: CGEventType, at point: CGPoint) throws {
            guard let event = CGEvent(
                mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left
            ) else {
                throw ScanError.inputSynthesisFailed
            }
            event.post(tap: .cghidEventTap)
        }
        try post(.leftMouseDown, at: start)
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            try post(.leftMouseDragged, at: point)
            try await Task.sleep(for: .milliseconds(12))
        }
        try post(.leftMouseUp, at: end)
    }

    // MARK: - OCR

    /// Runs Vision text recognition on `image` and returns all text observations.
    func recognizeText(in image: CGImage) async throws -> [VNRecognizedTextObservation] {
        try await withCheckedThrowingContinuation { cont in
            let request = VNRecognizeTextRequest { req, err in
                if let err { cont.resume(throwing: err); return }
                cont.resume(returning: (req.results as? [VNRecognizedTextObservation]) ?? [])
            }
            request.recognitionLevel = .accurate
            // Pokémon names aren't English dictionary words — skip language correction.
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    // MARK: - Extraction

    /// Extracts the Pokémon's species name, level, max HP, and (best-effort) CP
    /// from Vision observations of the detail screen.
    ///
    /// The gold CP badge OCRs unreliably, so CP is treated as a bonus signal.
    /// Two much more reliable signals are used instead:
    ///  - The catch message "This {species} was caught on…" gives the true
    ///    species name even if the player renamed the Pokémon.
    ///  - "{cur} / {max} HP" plus "Lvl {level}" pin down the HP IV exactly via
    ///    the CPM table, since HP = floor(cpm * (baseHp + hpIV)).
    func extractPokemonInfo(
        from observations: [VNRecognizedTextObservation]
    ) -> PokemonScanInfo? {
        let sorted  = observations.sorted { $0.boundingBox.minY > $1.boundingBox.minY }
        let strings = sorted.compactMap {
            $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces)
        }

        // Strings that are definitely not Pokémon names.
        let skipWords: Set<String> = [
            "hp", "atk", "def", "sta", "cp", "buddy", "stardust", "candy",
            "candies", "power up", "evolve", "transfer", "favorite",
            "appraise", "purify", "shadow", "traded", "lucky", "search",
            "water", "fire", "grass", "normal", "flying", "poison", "ground",
            "rock", "bug", "ghost", "steel", "fighting", "psychic", "ice",
            "dragon", "dark", "fairy", "electric"
        ]

        var caughtName: String?
        var fallbackName: String?
        var cp: Int?
        var level: Double?
        var maxHP: Int?

        for (i, text) in strings.enumerated() {
            let upper = text.uppercased()

            // Catch message: "This {name} was caught on …" — the reliable
            // species name, even for a nicknamed Pokémon.
            if caughtName == nil, let match = firstMatch(in: text, pattern: #"^This\s+(.+?)\s+was\s+caught\b"#) {
                caughtName = match
            }

            // HP: "218 / 218 HP" — take the second (max) number.
            // Primary: full "cur / max HP" in one observation.
            if maxHP == nil, let match = firstMatch(in: text, pattern: #"(\d+)\s*/\s*(\d+)\s*HP"#, group: 2) {
                maxHP = Int(match)
            }
            // Fallback A: Vision split "67 / 97" + "HP" across observations;
            // this observation starts with "/" so only the max-HP number is here.
            if maxHP == nil, let match = firstMatch(in: text, pattern: #"^/\s*(\d+)\s*HP"#, group: 1),
               let n = Int(match), n >= 10 { maxHP = n }
            // Fallback B: "97HP" or "97 HP" as a standalone observation
            // (slash and current-HP are on a prior observation).
            if maxHP == nil, upper.hasSuffix("HP") {
                let numStr = String(text.dropLast(2)).trimmingCharacters(in: .whitespaces)
                if let n = Int(numStr), n >= 10 { maxHP = n }
            }

            // Level: "Lvl 50" or "Lvl 32.5".
            if level == nil, let match = firstMatch(in: text, pattern: #"Lvl\.?\s*(\d+(?:\.\d+)?)"#) {
                level = Double(match)
            }

            // CP detection: "CP 1234", "CP1234", or a bare number on the line after "CP".
            if cp == nil {
                if upper.hasPrefix("CP") {
                    let numStr = String(upper.dropFirst(2))
                        .trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: ",", with: "")
                    if let n = Int(numStr), n >= 10 { cp = n }
                } else if i > 0, strings[i - 1].uppercased() == "CP" {
                    let numStr = text.trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: ",", with: "")
                    if let n = Int(numStr), n >= 10 { cp = n }
                }
            }

            // Fallback name: first text that isn't a stat label, number, or CP prefix.
            // Species names are always letters (plus ♀/♂/apostrophes/hyphens for names
            // like "Farfetch'd"), so require a letter too — without it, a status-bar
            // clock reading like "9:41" passes every other check (it's not an `Int`,
            // doesn't start with "CP"/"#") and gets mistaken for the species name. A
            // clock with an AM/PM suffix ("9:41 AM") does contain letters, so it's
            // excluded separately by shape (digits, colon, optional AM/PM).
            if fallbackName == nil {
                let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
                if !skipWords.contains(lower)
                    && Int(text) == nil
                    && !upper.hasPrefix("CP")
                    && !upper.hasPrefix("#")
                    && text.count >= 3
                    && text.contains(where: { $0.isLetter })
                    && text.range(of: #"^\d{1,2}:\d{2}(\s*[AP]M)?$"#, options: [.regularExpression, .caseInsensitive]) == nil {
                    fallbackName = text
                }
            }
        }

        guard let name = caughtName ?? fallbackName else { return nil }
        return PokemonScanInfo(name: name, level: level, maxHP: maxHP, cp: cp)
    }

    /// Returns the first capture group (default group 1) of the first regex match in `text`.
    private func firstMatch(in text: String, pattern: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > group,
              let matchRange = Range(match.range(at: group), in: text) else { return nil }
        return String(text[matchRange])
    }

    // MARK: - IV bar pixel analysis

    /// Reads all three IVs off the appraisal screen's Attack/Defense/HP bars,
    /// anchored on the OCR'd row labels. This is the only signal that pins
    /// down attack and defense — the CP badge OCRs unreliably and the level
    /// isn't shown as text on this screen at all.
    ///
    /// A bar is three rounded segments of 5 IVs each, separated by narrow gaps
    /// of card background, so there's no single fill→track edge to find. Each
    /// bar is measured by counting instead: `IV = 15 * fill / (fill + track)`,
    /// with the gaps landing in neither bucket. That ratio needs no knowledge
    /// of the bar's pixel width, which changes with the mirroring window's
    /// size, and no calibration against a separately known IV.
    func extractBarIVs(
        from observations: [VNRecognizedTextObservation],
        image: CGImage
    ) -> BarIVs? {
        guard let sampler = PixelSampler(image: image) else {
            #if DEBUG
            print("[ScreenScanner] PixelSampler init failed")
            #endif
            return nil
        }
        let width = Double(image.width)
        let height = Double(image.height)

        let labels = ["Attack", "Defense", "HP"]
        // Build rows in order, using Attack/Defense positions to disambiguate "HP":
        // the appraisal screen's "cur/max HP" text can produce a standalone "HP"
        // observation near the top of the screen. If that's found first, the bar
        // search anchors in the wrong place and reads the wrong IV. Instead, once
        // Attack and Defense are located we require the HP bar label to be within
        // 1.5× their spacing of the expected position (one step below Defense).
        var rows: [(label: String, obs: VNRecognizedTextObservation)] = []
        for label in labels {
            if label == "HP", rows.count == 2 {
                let atkY = rows[0].obs.boundingBox.midY   // Vision Y: 0=bottom, 1=top
                let defY = rows[1].obs.boundingBox.midY
                let spacing = abs(atkY - defY)
                let expectedY = min(atkY, defY) - spacing  // one step below Defense
                let tolerance = max(spacing * 1.5, 0.05)
                if let obs = observations.first(where: {
                    guard firstWordMatches($0, label: "HP") else { return false }
                    return abs($0.boundingBox.midY - expectedY) < tolerance
                }) {
                    rows.append((label, obs))
                }
            } else if let obs = labelObservation(label, in: observations) {
                rows.append((label, obs))
            }
        }
        guard rows.count == labels.count else {
            #if DEBUG
            let allText = observations.compactMap { $0.topCandidates(1).first?.string }
            print("[ScreenScanner] Bars skipped: only found labels \(rows.map { $0.label }) — all recognized text: \(allText)")
            #endif
            return nil
        }

        let labelRowYs: [(label: String, rowY: Int)] = rows.map { label, obs in
            let box = obs.boundingBox
            let topPx = (1 - box.maxY) * height
            let bottomPx = (1 - box.minY) * height
            return (label, Int(((topPx + bottomPx) / 2).rounded()))
        }
        let sortedYs = labelRowYs.map { $0.rowY }.sorted()
        let rowSpacing = Double(sortedYs.last! - sortedYs.first!) / Double(sortedYs.count - 1)
        guard rowSpacing > 4 else { return nil }

        // Every tolerance below is a fraction of the label row spacing, so the
        // reader works at whatever scale the mirroring window is captured at.
        let gapTolerance = max(Int(rowSpacing * 0.15), 3)
        // Bars are left-aligned with their labels; start slightly left of the
        // label box so a pixel or two of OCR imprecision can't clip the bar.
        let scanStartX = max(Int((rows.map { $0.obs.boundingBox.minX * width }.min()!).rounded()) - Int(rowSpacing * 0.1), 0)
        let scanEndX = min(scanStartX + Int(width * 0.6), image.width - 1)
        guard scanStartX < scanEndX else { return nil }

        // The bar's exact offset below its label isn't fixed, so find it:
        // within the band between this label and the next, the bar's own row
        // has overwhelmingly more bar-colored pixels than anything else (the
        // label text itself scores an order of magnitude lower).
        var measurements: [String: BarMeasurement] = [:]
        for (label, labelY) in labelRowYs {
            let searchStart = labelY + Int(rowSpacing * 0.15)
            let searchEnd = labelY + Int(rowSpacing * 0.9)
            var best: BarMeasurement?
            for y in stride(from: searchStart, through: searchEnd, by: 1) {
                let m = measureBarRow(sampler: sampler, rowY: y, startX: scanStartX, endX: scanEndX, gapTolerance: gapTolerance)
                if m.total > (best?.total ?? 0) { best = m }
            }
            guard let best, best.total > Int(rowSpacing) else {
                #if DEBUG
                print("[ScreenScanner] Bar '\(label)': no bar row found below label y=\(labelY)")
                #endif
                continue
            }
            measurements[label] = best
            #if DEBUG
            print("[ScreenScanner] Bar '\(label)': row=\(best.rowY) fill=\(best.fill) track=\(best.track) end=\(best.endX)")
            #endif
        }
        guard measurements.count == labels.count else { return nil }

        #if DEBUG
        saveBarDebugImage(image: image, measurements: measurements, startX: scanStartX)
        #endif

        // All three bars are the same width, so a row that stopped short (or
        // ran long into the artwork behind the card) disagrees with the other
        // two. Re-measure everything against the middle extent.
        let sharedEndX = measurements.values.map { $0.endX }.sorted()[1]
        var ivs: [String: Int] = [:]
        for (label, m) in measurements {
            // Re-measure the best row against the calibrated sharedEndX — the
            // search above used a wide upper bound; this locks all three bars
            // to the same pixel range so fill fractions are comparable.
            //
            // Averaging rows at ±2px (an earlier approach) was meant to smooth
            // antialiasing at the bars' rounded caps, but those nearby rows can
            // fall near a segment boundary and have a completely different
            // fill:track ratio, corrupting the result (e.g. HP IV=9 when the
            // single best row clearly shows IV=13). The best row is found by
            // maximising total pixel count, so it is the vertical centre of the
            // bar — not a cap — and is already the most reliable measurement.
            let row = measureBarRow(
                sampler: sampler, rowY: m.rowY, startX: scanStartX,
                endX: sharedEndX, gapTolerance: gapTolerance)
            guard row.total > 0 else { continue }
            ivs[label] = min(max(Int((15 * Double(row.fill) / Double(row.total)).rounded()), 0), 15)
        }
        #if DEBUG
        print("[ScreenScanner] Bar IVs: \(ivs.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        #endif

        return BarIVs(atk: ivs["Attack"], def: ivs["Defense"], hp: ivs["HP"])
    }

    /// One horizontal pass across a candidate bar row.
    private struct BarMeasurement {
        var rowY: Int
        var fill: Int
        var track: Int
        var endX: Int
        var total: Int { fill + track }
    }

    /// Counts filled and unfilled bar pixels along `rowY`, stopping at the end
    /// of the bar — that is, at the first stretch of card background wider
    /// than `gapTolerance`, which is what separates the gaps between the
    /// bar's segments from the empty card beyond its right edge.
    private func measureBarRow(
        sampler: PixelSampler, rowY: Int, startX: Int, endX: Int, gapTolerance: Int
    ) -> BarMeasurement {
        var fill = 0, track = 0
        var started = false
        var cardRun = 0
        var lastBarX = startX
        for x in startX...endX {
            guard let color = sampler.color(x: x, y: rowY) else { break }
            switch classify(color) {
            case .fill:
                fill += 1
                started = true
                cardRun = 0
                lastBarX = x
            case .track:
                track += 1
                started = true
                cardRun = 0
                lastBarX = x
            case .card:
                guard started else { continue }
                cardRun += 1
                if cardRun > gapTolerance {
                    return BarMeasurement(rowY: rowY, fill: fill, track: track, endX: lastBarX)
                }
            }
        }
        return BarMeasurement(rowY: rowY, fill: fill, track: track, endX: lastBarX)
    }

    private enum BarPixel { case fill, track, card }

    /// A filled segment is saturated; an unfilled one is a pale gray that's
    /// still distinctly darker than the white card behind the bars. Going by
    /// chroma and lightness rather than specific colors keeps this working
    /// across the different hues the game gives each stat.
    private func classify(_ c: PixelColor) -> BarPixel {
        if max(c.r, c.g, c.b) - min(c.r, c.g, c.b) > 25 { return .fill }
        return (c.r + c.g + c.b) / 3 < 248 ? .track : .card
    }

    private func labelObservation(
        _ label: String, in observations: [VNRecognizedTextObservation]
    ) -> VNRecognizedTextObservation? {
        observations.first { firstWordMatches($0, label: label) }
    }

    /// Matches on the observation's first word rather than requiring the
    /// whole observation to be exactly the label — Vision sometimes fuses a
    /// row's label with adjacent text (trailing punctuation, a qualifier
    /// word) into one observation, which an exact match silently rejects.
    private func firstWordMatches(_ observation: VNRecognizedTextObservation, label: String) -> Bool {
        let text = observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces) ?? ""
        let firstWord = text.split(separator: " ", maxSplits: 1).first.map(String.init) ?? text
        let stripped = firstWord.trimmingCharacters(in: CharacterSet.punctuationCharacters)
        return stripped.caseInsensitiveCompare(label) == .orderedSame
    }


    #if DEBUG
    /// Saves a wide crop spanning the whole bar block, with a green line at
    /// each detected bar row and red lines at the scan's start and each bar's
    /// detected right edge. Lets the located geometry be checked by eye
    /// against the real pixels — the readings are otherwise invisible.
    private func saveBarDebugImage(
        image: CGImage, measurements: [String: BarMeasurement], startX: Int
    ) {
        let rowYs = measurements.values.map { $0.rowY }
        guard let minRowY = rowYs.min(), let maxRowY = rowYs.max() else { return }

        let y = max(minRowY - 120, 0)
        let cropHeight = min(maxRowY + 120, image.height) - y
        guard cropHeight > 0,
              let cropped = image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: cropHeight)) else { return }

        let edges = [startX] + measurements.values.map { $0.endX }
        let toSave = annotated(cropped, verticalXs: edges, horizontalYs: rowYs.map { $0 - y }) ?? cropped

        let rep = NSBitmapImageRep(cgImage: toSave)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pokeparty_bar_debug.png")
        try? data.write(to: url)
        print("[ScreenScanner] Saved bar debug image (crop origin y=\(y), green rows at rel y=\(rowYs.map { $0 - y }), red edges at x=\(edges.sorted())) to \(url.path)")
    }

    /// Draws vertical (red) and horizontal (green) marker lines. Uses a
    /// fresh, throwaway `CGContext` — `context.draw`/`context.makeImage` are
    /// high-level APIs that handle image orientation correctly on their own
    /// (unlike `PixelSampler`'s raw buffer reads, which needed the explicit
    /// flip fix), so the base image comes out right-side-up unconditionally.
    /// `CGContext`'s own drawing coordinate space is bottom-up, though, so a
    /// horizontal line's Y (computed top-down, same convention as the rest
    /// of this file) needs converting before `context.fill` — vertical
    /// lines don't, since X isn't affected by the flip.
    private func annotated(_ image: CGImage, verticalXs: [Int], horizontalYs: [Int]) -> CGImage? {
        let w = image.width, h = image.height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        for x in verticalXs where x >= 0 && x < w {
            context.fill(CGRect(x: CGFloat(x), y: 0, width: 2, height: CGFloat(h)))
        }
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        for topDownY in horizontalYs where topDownY >= 0 && topDownY < h {
            let contextY = h - topDownY - 1
            context.fill(CGRect(x: 0, y: CGFloat(contextY), width: CGFloat(w), height: 2))
        }
        return context.makeImage()
    }

    #endif
}

// `nonisolated` on both: they're pure pixel math used from `ScreenScanner`'s
// actor context, and would otherwise pick up the project's default main-actor
// isolation.
nonisolated private struct PixelColor {
    var r: Double
    var g: Double
    var b: Double
}

/// Reads raw RGB pixel values from a `CGImage` by drawing it into an sRGB
/// bitmap context once, up front, then indexing into the resulting buffer.
nonisolated private struct PixelSampler {
    let width: Int
    let height: Int
    private let bytesPerRow: Int
    private let bytesPerPixel = 4
    private let data: [UInt8]

    init?(image: CGImage) {
        // Computed as locals, not `self.` properties: capturing `self` inside
        // the closure below (even indirectly, via a stored property) isn't
        // allowed until every stored property has been assigned.
        let w = image.width
        let h = image.height
        let bpp = 4
        let rowBytes = w * bpp
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        var buffer = [UInt8](repeating: 0, count: rowBytes * h)
        let ok = buffer.withUnsafeMutableBytes { ptr -> Bool in
            guard let base = ptr.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: w, height: h,
                    bitsPerComponent: 8, bytesPerRow: rowBytes,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }

        width = w
        height = h
        bytesPerRow = rowBytes
        data = buffer
    }

    /// `(x, y)` in top-left-origin pixel coordinates, matching Vision's
    /// converted bounding boxes and the rest of this file.
    ///
    /// No vertical flip: a bitmap context's drawing space is y-up, but its
    /// backing buffer is stored top-down — row 0 is the image's top row — so
    /// the row index is the top-down y directly. An earlier version flipped
    /// here and read every bar from its mirror image elsewhere on the screen.
    func color(x: Int, y: Int) -> PixelColor? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        let offset = y * bytesPerRow + x * bytesPerPixel
        return PixelColor(r: Double(data[offset]), g: Double(data[offset + 1]), b: Double(data[offset + 2]))
    }
}

#endif
