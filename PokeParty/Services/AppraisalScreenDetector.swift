//
//  AppraisalScreenDetector.swift
//  PokeParty
//
//  A cheap "is this Pokémon GO's appraisal screen?" check, run on frames from
//  the iOS screen capture before any full-frame OCR. Reading the whole frame
//  is expensive and would otherwise run on whatever else is on screen (the
//  home screen, a message, the GO map); here only a band around the
//  Attack / Defense / HP bar card is read, and the full scan is only
//  triggered when both "Attack" and "Defense" are in it.
//

import CoreVideo
import Foundation
import Vision

/// Not thread-safe (owns a reusable Vision request) — keep each instance on one queue.
nonisolated final class AppraisalScreenDetector {

    /// Where the bar card's labels sit, in Vision's bottom-left-origin
    /// normalized coordinates. Deliberately generous: the card moves up and
    /// down with the length of the speech bubble beneath it and with the
    /// device's aspect ratio. Measured on an iPhone screenshot, where the
    /// labels span x 12–27%, y 15–26%.
    static let region = CGRect(x: 0.0, y: 0.08, width: 0.6, height: 0.32)

    private let request: VNRecognizeTextRequest = {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.regionOfInterest = AppraisalScreenDetector.region
        return request
    }()

    func isAppraisalScreen(_ pixelBuffer: CVPixelBuffer) -> Bool {
        var words: Set<String> = []
        autoreleasepool {
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
            guard (try? handler.perform([request])) != nil else { return }
            for observation in request.results ?? [] {
                guard let text = observation.topCandidates(1).first?.string else { continue }
                words.insert(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }
        }
        return words.contains("attack") && words.contains("defense")
    }
}
