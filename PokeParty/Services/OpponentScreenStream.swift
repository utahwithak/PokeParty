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

#if os(iOS)

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

    /// Called on the main actor for each confirmed opponent.
    @ObservationIgnored var onDetection: (@MainActor (OpponentDetection) -> Void)?
    /// Called on the main actor with a full frame whenever the appraisal
    /// screen is showing (throttled), for IV reading.
    @ObservationIgnored var onAppraisalFrame: (@MainActor (CGImage) -> Void)?

    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var relay: StreamRelay?

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

        let relay = StreamRelay(
            onReading: { [weak self] reading, icons, lines in
                Task { @MainActor in self?.received(reading, icons: icons, rawLines: lines) }
            },
            onAppraisalFrame: { [weak self] image in
                Task { @MainActor in self?.onAppraisalFrame?(image) }
            },
            onStop: { [weak self] message in
                Task { @MainActor in
                    self?.isStreaming = false
                    if let message { self?.errorMessage = message }
                }
            })

        do {
            let stream = SCStream(filter: filter, configuration: SCStreamConfiguration(), delegate: relay)
            try stream.addStreamOutput(relay, type: .screen, sampleHandlerQueue: relay.queue)
            try await stream.startCapture()
            self.stream = stream
            self.relay = relay
            isStreaming = true
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
    private let onStop: @Sendable (String?) -> Void
    private let reader = OpponentStripReader()
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
    private var lastSignature: [UInt8]?
    /// Seen once, waiting for a second matching read before it's trusted.
    private var candidate: OpponentReading?
    private var published: OpponentReading?
    private var lastReadable: TimeInterval = 0
    /// Whether the last OCR pass of the opponent panel found a reading. While
    /// it hasn't, the frame might be an appraisal screen instead.
    private var panelHasText = false
    private var lastAppraisalCheck: TimeInterval = 0

    init(onReading: @escaping @Sendable (OpponentReading?, [IconColor], [String]) -> Void,
         onAppraisalFrame: @escaping @Sendable (CGImage) -> Void,
         onStop: @escaping @Sendable (String?) -> Void) {
        self.onReading = onReading
        self.onAppraisalFrame = onAppraisalFrame
        self.onStop = onStop
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
        guard now - lastHandled >= Self.minimumInterval else { return }
        lastHandled = now

        // Skip OCR on an unchanged panel — unless a first read is still
        // waiting on its confirmation, which needs another look at the same pixels.
        let signature = OpponentStripReader.signature(of: pixelBuffer)
        if let signature, let last = lastSignature, candidate == nil,
           OpponentStripReader.difference(signature, last) < Self.changeThreshold {
            if !panelHasText { checkForAppraisal(pixelBuffer, now: now) }
            return
        }
        lastSignature = signature

        let reading = reader.read(pixelBuffer)
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
        let icons = OpponentTypeReader.read(pixelBuffer)
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

    /// Cheaply checks for the appraisal screen and, only if it's showing,
    /// hands the whole frame on for the full OCR + bar reading.
    private func checkForAppraisal(_ pixelBuffer: CVPixelBuffer, now: TimeInterval) {
        guard now - lastAppraisalCheck >= Self.appraisalInterval else { return }
        lastAppraisalCheck = now
        guard appraisalDetector.isAppraisalScreen(pixelBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let image = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        onAppraisalFrame(image)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(error.localizedDescription)
    }
}

#endif
