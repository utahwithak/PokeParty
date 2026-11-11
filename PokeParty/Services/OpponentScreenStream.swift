//
//  OpponentScreenStream.swift
//  PokeParty
//
//  iOS 27 full-display capture via ScreenCaptureKit: the user picks "entire
//  screen" in the system picker, then the `screen-capture` background mode
//  keeps frames flowing while Pokémon GO is in front. Each frame's opponent
//  panel is OCR'd (see `OpponentStripReader`) and confirmed readings are
//  published as `latest` for Opponent Check to resolve to a species.
//

// ScreenCaptureKit isn't in the iOS simulator SDK, so the simulator gets the
// inert stub at the bottom of this file.
#if os(iOS) && !targetEnvironment(simulator)

import CoreImage
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

@Observable
@MainActor
final class OpponentScreenStream: NSObject, SCContentSharingPickerObserver {
    private(set) var isStreaming = false
    /// Newest confirmed opponent. Each detection has a fresh `id`, so views
    /// can react to a repeat of the same species (a rematch).
    private(set) var latest: OpponentDetection?
    private(set) var errorMessage: String?
    /// Raw OCR lines from the latest pass, for tuning `OpponentStripReader.region`.
    private(set) var debugLines: [String] = []
    /// What the battle-header reader sees (frame format, size, slot colours).
    private(set) var debugHeader = ""

    /// Called on the main actor for each confirmed opponent.
    @ObservationIgnored var onDetection: (@MainActor (OpponentDetection) -> Void)?
    /// Called on the main actor with a full frame whenever the appraisal
    /// screen is showing (throttled), for IV reading.
    @ObservationIgnored var onAppraisalFrame: (@MainActor (CGImage) -> Void)?
    /// Called on the main actor whenever the battle header reads differently
    /// (shields, Pokémon left, your active Pokémon) or an effectiveness label shows.
    @ObservationIgnored var onSnapshot: (@MainActor (BattleSnapshot) -> Void)?

    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var relay: StreamRelay?
    /// Bumped on every stop, so a stopped stream's late callbacks can be told apart from the current one's.
    @ObservationIgnored private var generation = 0

    // MARK: - Control

    /// Shows the system picker; the stream starts once the user chooses a
    /// full-display capture.
    func present() {
        errorMessage = nil
        let picker = SCContentSharingPicker.shared
        picker.add(self)
        picker.isActive = true
        picker.present()
    }

    func stop() async {
        generation += 1
        let current = stream
        stream = nil
        relay = nil
        isStreaming = false
        try? await current?.stopCapture()
    }

    // MARK: - Picker callbacks

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        nonisolated(unsafe) let filter = filter
        Task { @MainActor in await self.start(with: filter) }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {}

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        let message = error.localizedDescription
        Task { @MainActor in self.errorMessage = message }
    }

    // MARK: - Streaming

    private func start(with filter: SCContentFilter) async {
        await stop()
        let generation = self.generation

        let relay = StreamRelay(
            onReading: { [weak self] reading, icons, lines in
                Task { @MainActor in self?.received(reading, icons: icons, rawLines: lines) }
            },
            onAppraisalFrame: { [weak self] image in
                Task { @MainActor in self?.onAppraisalFrame?(image) }
            },
            onSnapshot: { [weak self] snapshot in
                Task { @MainActor in self?.onSnapshot?(snapshot) }
            },
            onHeaderDebug: { [weak self] text in
                Task { @MainActor in self?.debugHeader = text }
            },
            onStop: { [weak self] message in
                Task { @MainActor in
                    // A stream that was already replaced or stopped can report its failure late.
                    guard let self, self.generation == generation else { return }
                    self.isStreaming = false
                    if let message { self.errorMessage = message }
                }
            })

        do {
            let stream = SCStream(filter: filter, configuration: SCStreamConfiguration(), delegate: relay)
            try stream.addStreamOutput(relay, type: .screen, sampleHandlerQueue: relay.queue)
            try await stream.startCapture()
            self.stream = stream
            self.relay = relay
            isStreaming = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func received(_ reading: OpponentReading?, icons: [IconColor], rawLines: [String]) {
        debugLines = rawLines
        if let reading {
            let detection = OpponentDetection(name: reading.name, cp: reading.cp, icons: icons)
            latest = detection
            onDetection?(detection)
        }
    }
}

/// Receives frames on its own queue and does the OCR there, so none of it
/// touches the main actor. Plain non-isolated class because `SCStreamOutput`
/// needs `NSObjectProtocol` (same reason `ScreenScanner` has `FrameStreamRelay`).
nonisolated private final class StreamRelay: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "PokeParty.OpponentScreenStream", qos: .userInitiated)

    private let onReading: @Sendable (OpponentReading?, [IconColor], [String]) -> Void
    private let onAppraisalFrame: @Sendable (CGImage) -> Void
    private let onSnapshot: @Sendable (BattleSnapshot) -> Void
    private let onHeaderDebug: @Sendable (String) -> Void
    private let onStop: @Sendable (String?) -> Void
    private let reader = OpponentStripReader()
    private let myReader = OpponentStripReader(region: OpponentStripReader.myRegion)
    private let textReader = BattleTextReader()
    private let appraisalDetector = AppraisalScreenDetector()
    private let ciContext = CIContext()

    /// Panel changes smaller than this (mean pixel difference) skip OCR.
    private static let changeThreshold = 2.0
    /// With no readable panel for this long, the same opponent may be
    /// published again (a rematch).
    private static let forgetAfter: TimeInterval = 4

    /// iOS has no `minimumFrameInterval`, so frames arriving faster than this are dropped here.
    private static let minimumInterval: TimeInterval = 0.33
    /// How often to look for the appraisal screen while no battle panel is
    /// showing. The IV reading needs two matching frames, so this sets how
    /// quickly a result appears.
    private static let appraisalInterval: TimeInterval = 0.5

    // Only touched on `queue`.
    private var lastHandled: TimeInterval = 0
    /// How far this phone's battle header sits from where the readers' positions
    /// were measured (fraction of frame height); see `BattleHeaderReader.findShift`.
    private var headerShift = 0.0
    private var lastSignature: [UInt8]?
    /// Seen once, waiting for a second matching read before it's trusted.
    private var candidate: OpponentReading?
    private var published: OpponentReading?
    private var lastReadable: TimeInterval = 0
    /// Whether the last OCR pass of the opponent panel found a reading. While
    /// it hasn't, the frame might be an appraisal screen instead.
    private var panelHasText = false
    private var lastAppraisalCheck: TimeInterval = 0
    // Battle-header state, also only touched on `queue`.
    private var mySignature: [UInt8]?
    private var myName: String?
    private var lastSnapshot: BattleSnapshot?
    private var lastFlashSent: TimeInterval = 0
    private var lastHeaderDebug: TimeInterval = 0
    private var lastBandLines: [String] = []
    private var lastFaintedSent: [String: TimeInterval] = [:]
    private var lastTextSent: [String: TimeInterval] = [:]
    private var shieldFilter = ShieldReadingFilter()
    private var lastResultCheck: TimeInterval = 0
    private var lastResultSent: TimeInterval = -100
    // Pacing of the full-screen OCR, only touched on `queue`.
    private var nextTextPass: TimeInterval = 0
    private var lastTextPass: TimeInterval = 0
    private var textSignature: [UInt8]?
    /// Smoothed duration of the full-screen OCR pass, so slow phones back off.
    private var textPassCost: TimeInterval = 0
    #if DEBUG
    private var passCount = 0
    private var lastTextLog: TimeInterval = 0
    private var framesIn = 0
    private var stageTotal: [String: TimeInterval] = [:]
    private var stageMax: [String: TimeInterval] = [:]
    private var framesHandled = 0
    private var handlerTotal: TimeInterval = 0
    private var handlerMax: TimeInterval = 0
    private var skippedForCost = 0
    private var skippedUnchanged = 0
    #endif

    /// A label that stays up across several frames is one hit's worth of news.
    private static let flashRepeatInterval: TimeInterval = 0.8
    /// The same faint message, still on screen, isn't a second faint.
    private static let faintRepeatInterval: TimeInterval = 4
    /// How often to look for the result screen while no battle is showing.
    private static let resultCheckInterval: TimeInterval = 0.75
    /// The result screen stays up for a while; report it once.
    private static let resultRepeatInterval: TimeInterval = 8
    /// The same line of text, still on screen, isn't news again.
    private static let textRepeatInterval: TimeInterval = 2.5
    /// The next full-screen OCR waits this many times the last one's duration, so a
    /// slow phone spends its time on the quick readers instead of dropping frames.
    private static let textPassBackoff = 1.5
    /// A full-frame signature this close to the last OCR'd frame's skips the pass...
    private static let textChangeThreshold = 0.25
    /// ...but never for longer than this, in case the change was too small to sample.
    private static let textMaxStale: TimeInterval = 1.5

    init(onReading: @escaping @Sendable (OpponentReading?, [IconColor], [String]) -> Void,
         onAppraisalFrame: @escaping @Sendable (CGImage) -> Void,
         onSnapshot: @escaping @Sendable (BattleSnapshot) -> Void,
         onHeaderDebug: @escaping @Sendable (String) -> Void,
         onStop: @escaping @Sendable (String?) -> Void) {
        self.onReading = onReading
        self.onAppraisalFrame = onAppraisalFrame
        self.onSnapshot = onSnapshot
        self.onHeaderDebug = onHeaderDebug
        self.onStop = onStop
    }

    /// Runs `body`, adding its duration to the DEBUG log's per-stage breakdown.
    @inline(__always)
    private func timed<T>(_ stage: String, _ body: () -> T) -> T {
        #if DEBUG
        let start = ProcessInfo.processInfo.systemUptime
        defer {
            let cost = ProcessInfo.processInfo.systemUptime - start
            stageTotal[stage, default: 0] += cost
            stageMax[stage] = max(stageMax[stage] ?? 0, cost)
        }
        #endif
        return body()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRawValue = attachmentsArray.first?[.status] as? Int,
              // Only `.complete` is a genuinely new frame.
              SCFrameStatus(rawValue: statusRawValue) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        let now = ProcessInfo.processInfo.systemUptime
        #if DEBUG
        framesIn += 1
        #endif
        guard now - lastHandled >= Self.minimumInterval else { return }
        lastHandled = now
        #if DEBUG
        framesHandled += 1
        defer {
            let cost = ProcessInfo.processInfo.systemUptime - now
            handlerTotal += cost
            handlerMax = max(handlerMax, cost)
            if now - lastTextLog >= 5 {
                lastTextLog = now
                print(String(format: "frames: %d delivered, %d handled · handler %.0f ms avg, %.0f ms max · OCR %.0f ms avg, %d passes, skipped %d (busy) %d (unchanged)",
                             framesIn, framesHandled, handlerTotal / Double(max(framesHandled, 1)) * 1000, handlerMax * 1000,
                             textPassCost * 1000, passCount, skippedForCost, skippedUnchanged))
                let stages = stageTotal.keys.sorted().map {
                    String(format: "%@ %.0f/%.0f", $0, stageTotal[$0]! / Double(max(framesHandled, 1)) * 1000, stageMax[$0]! * 1000)
                }.joined(separator: " · ")
                print("  stages (avg per frame/max ms): " + stages)
                stageTotal = [:]; stageMax = [:]
                framesIn = 0; framesHandled = 0; handlerTotal = 0; handlerMax = 0
            }
        }
        #endif

        // The header and icon readers sample BGRA pixels, and iOS doesn't let the
        // capture be configured for that, so convert when the frame arrives as YUV.
        let bgra = timed("convert") { bgraBuffer(for: pixelBuffer) }
        timed("shift") { updateHeaderShift(bgra ?? pixelBuffer) }
        timed("battle") { readBattleState(bgra ?? pixelBuffer, sourceFormat: CVPixelBufferGetPixelFormatType(pixelBuffer), now: now) }

        // Skip OCR on an unchanged panel — unless a first read is still
        // waiting on its confirmation, which needs another look at the same pixels.
        let signature = OpponentStripReader.signature(of: pixelBuffer, region: OpponentStripReader.shifted(OpponentStripReader.region, by: headerShift))
        if let signature, let last = lastSignature, candidate == nil,
           OpponentStripReader.difference(signature, last) < Self.changeThreshold {
            if !panelHasText { checkForAppraisal(pixelBuffer, now: now) }
            return
        }
        lastSignature = signature

        let reading = timed("oppOCR") { reader.read(pixelBuffer, yShift: headerShift) }
        panelHasText = reading != nil
        guard let reading else {
            if !panelHasText { checkForAppraisal(pixelBuffer, now: now) }
            candidate = nil
            if now - lastReadable > Self.forgetAfter { published = nil }
            onReading(nil, [], reader.lastRawLines)
            return
        }
        lastReadable = now

        // Icons are only sampled once there's a name to attach them to.
        let icons = timed("oppIcons") { OpponentTypeReader.read(bgra ?? pixelBuffer, yShift: headerShift) }
        if reading == published {
            candidate = nil
            onReading(nil, icons, reader.lastRawLines)
        } else if reading == candidate {
            published = reading
            candidate = nil
            onReading(reading, icons, reader.lastRawLines)
        } else {
            candidate = reading
            onReading(nil, icons, reader.lastRawLines)
        }
    }

    /// Re-finds the header's position when it no longer lines up (a new phone, or a
    /// frame that isn't a battle leaves the last shift in place).
    private func updateHeaderShift(_ pixelBuffer: CVPixelBuffer) {
        if BattleHeaderReader.read(pixelBuffer, yShift: headerShift) != nil { return }
        if let found = BattleHeaderReader.findShift(pixelBuffer) { headerShift = found }
    }

    /// A reusable BGRA copy of `source`, or nil when it's already BGRA.
    private var bgraTarget: CVPixelBuffer?

    private func bgraBuffer(for source: CVPixelBuffer) -> CVPixelBuffer? {
        guard CVPixelBufferGetPixelFormatType(source) != kCVPixelFormatType_32BGRA else { return nil }
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        if bgraTarget.map({ CVPixelBufferGetWidth($0) != width || CVPixelBufferGetHeight($0) != height }) ?? true {
            var target: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &target)
            bgraTarget = target
        }
        guard let target = bgraTarget else { return nil }
        ciContext.render(CIImage(cvPixelBuffer: source), to: target)
        return target
    }

    /// Reads the battle header (shields, Pokémon left, your active Pokémon), both
    /// HP bars, and the effectiveness label / faint messages, and reports a
    /// snapshot when something changed. Frames that show neither the header nor
    /// an HP bar aren't a battle and produce nothing.
    private func readBattleState(_ pixelBuffer: CVPixelBuffer, sourceFormat: OSType, now: TimeInterval) {
        let header = timed("header") { BattleHeaderReader.read(pixelBuffer, yShift: headerShift) }
        let hp = timed("hpBars") { HPBarReader.read(pixelBuffer) }

        #if DEBUG
        if now - lastHeaderDebug >= 1 {
            lastHeaderDebug = now
            let bars = "HP mine \(hp.mine.map { String(format: "%.2f", $0) } ?? "—") opp \(hp.opponent.map { String(format: "%.2f", $0) } ?? "—")"
            onHeaderDebug("source \(BattleHeaderReader.fourCC(sourceFormat)) · " + BattleHeaderReader.diagnose(pixelBuffer, yShift: headerShift)
                          + "\n\(bars)\nband: " + (lastBandLines.isEmpty ? "—" : lastBandLines.joined(separator: " | ")))
        }
        #endif
        guard header != nil || hp.mine != nil || hp.opponent != nil else {
            // No battle on screen — but the result screen ("YOU WIN!") has no header either.
            checkForResult(pixelBuffer, now: now)
            return
        }
        // Colour-read shield counts blip while the header animates; only trust ones that hold.
        let shields = shieldFilter.update(header, now: now)

        // The name needs OCR, so only re-read it when the panel changed.
        let signature = OpponentStripReader.signature(of: pixelBuffer, region: OpponentStripReader.shifted(OpponentStripReader.myRegion, by: headerShift))
        if myName == nil || signature == nil || mySignature == nil
            || OpponentStripReader.difference(signature!, mySignature!) >= Self.changeThreshold {
            mySignature = signature
            myName = timed("myOCR") { myReader.read(pixelBuffer, yShift: headerShift)?.name } ?? myName
        }
        let icons = timed("myIcons") { OpponentTypeReader.read(pixelBuffer, slots: OpponentTypeReader.mySlots, yShift: headerShift) }

        let text = readText(pixelBuffer, now: now) ?? BattleText(flash: nil, flashY: nil, fainted: [], result: nil, screenLines: [])
        if !text.screenLines.isEmpty { lastBandLines = text.lines }
        var result = text.result
        if result != nil {
            if now - lastResultSent < Self.resultRepeatInterval { result = nil } else { lastResultSent = now }
        }
        var flash = text.flash
        if flash != nil {
            if now - lastFlashSent < Self.flashRepeatInterval { flash = nil } else { lastFlashSent = now }
        }
        // A faint message stays up for a moment; report each name once per battle moment.
        var fainted: [String] = []
        for name in text.fainted where now - (lastFaintedSent[name] ?? -100) >= Self.faintRepeatInterval {
            lastFaintedSent[name] = now
            fainted.append(name)
        }

        // Banners and messages stay up for a couple of seconds; send each line once per showing.
        var screenText: [ScreenLine] = []
        for line in text.screenLines {
            let key = line.text.lowercased().filter(\.isLetter)
            guard key.count >= 3, now - (lastTextSent[key] ?? -100) >= Self.textRepeatInterval else { continue }
            lastTextSent[key] = now
            screenText.append(line)
        }

        // HP moves continuously; 5% steps keep the phone from reporting every pixel.
        func steps(_ value: Double?) -> Double? { value.map { ($0 * 20).rounded() / 20 } }

        let snapshot = BattleSnapshot(
            myName: myName, myIcons: icons,
            myShields: header == nil ? nil : shields.mine, opponentShields: header == nil ? nil : shields.theirs,
            myAlive: header?.myAlive, opponentAlive: header?.opponentAlive,
            flash: flash, myHP: steps(hp.mine), opponentHP: steps(hp.opponent), fainted: fainted,
            screenText: screenText.isEmpty ? nil : screenText,
            flashY: flash == nil ? nil : text.flashY, result: result)
        // Compare without the one-off events: those are news on their own, a repeat of the state isn't.
        var stateOnly = snapshot
        stateOnly.flash = nil
        stateOnly.fainted = []
        stateOnly.screenText = nil
        stateOnly.flashY = nil
        stateOnly.result = nil
        if flash != nil || !fainted.isEmpty || !screenText.isEmpty || result != nil || stateOnly != lastSnapshot {
            lastSnapshot = stateOnly
            onSnapshot(snapshot)
        }
    }

    /// The full-screen OCR, paced to the phone: it's skipped while the last pass's
    /// cost says it can't keep up, and when the frame looks the same as the last
    /// one read. Returns nil when skipped. One-off events (flashes, faints) only
    /// matter on the frame they appear, so a skipped pass loses nothing but latency.
    private func readText(_ pixelBuffer: CVPixelBuffer, now: TimeInterval) -> BattleText? {
        guard now >= nextTextPass else {
            #if DEBUG
            skippedForCost += 1
            #endif
            return nil
        }
        let signature = OpponentStripReader.signature(of: pixelBuffer, region: CGRect(x: 0, y: 0, width: 1, height: 1))
        if let signature, let last = textSignature, now - lastTextPass < Self.textMaxStale,
           OpponentStripReader.difference(signature, last) < Self.textChangeThreshold {
            #if DEBUG
            skippedUnchanged += 1
            #endif
            return nil
        }
        textSignature = signature
        lastTextPass = now

        let start = ProcessInfo.processInfo.systemUptime
        let text = timed("textOCR") { textReader.read(pixelBuffer) }
        let cost = ProcessInfo.processInfo.systemUptime - start
        textPassCost = textPassCost == 0 ? cost : textPassCost * 0.6 + cost * 0.4
        // No floor at the frame interval: frames are already spaced by `minimumInterval`, and
        // a floor made frames arriving a few ms early get skipped.
        nextTextPass = start + textPassCost * Self.textPassBackoff

        #if DEBUG
        passCount += 1
        #endif
        return text
    }

    /// Looks for the "YOU WIN!" / "Good Effort" screen while no battle header is
    /// showing, and reports it as a snapshot carrying only the result. Throttled,
    /// since it OCRs the frame.
    private func checkForResult(_ pixelBuffer: CVPixelBuffer, now: TimeInterval) {
        guard now - lastResultCheck >= Self.resultCheckInterval else { return }
        lastResultCheck = now
        guard let text = readText(pixelBuffer, now: now),
              let result = text.result, now - lastResultSent >= Self.resultRepeatInterval else { return }
        lastResultSent = now
        onSnapshot(BattleSnapshot(
            myName: nil, myIcons: [], myShields: nil, opponentShields: nil, myAlive: nil, opponentAlive: nil,
            flash: nil, myHP: nil, opponentHP: nil, fainted: [], screenText: text.screenLines, result: result))
    }

    /// Cheaply checks for the appraisal screen and, only if it's showing,
    /// hands the whole frame on for the full OCR + bar reading.
    private func checkForAppraisal(_ pixelBuffer: CVPixelBuffer, now: TimeInterval) {
        guard now - lastAppraisalCheck >= Self.appraisalInterval else { return }
        lastAppraisalCheck = now
        guard timed("appraisal", { appraisalDetector.isAppraisalScreen(pixelBuffer) }) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let image = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        onAppraisalFrame(image)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(error.localizedDescription)
    }
}

#elseif os(iOS)

import CoreGraphics
import Foundation

/// Simulator stand-in with the same surface as the real stream; it never captures.
@Observable
@MainActor
final class OpponentScreenStream {
    private(set) var isStreaming = false
    private(set) var latest: OpponentDetection?
    private(set) var errorMessage: String?
    private(set) var debugLines: [String] = []
    private(set) var debugHeader = ""

    @ObservationIgnored var onDetection: (@MainActor (OpponentDetection) -> Void)?
    @ObservationIgnored var onAppraisalFrame: (@MainActor (CGImage) -> Void)?
    @ObservationIgnored var onSnapshot: (@MainActor (BattleSnapshot) -> Void)?

    func present() {
        errorMessage = "Screen capture isn't available in the simulator."
    }

    func stop() async {}
}

#endif
