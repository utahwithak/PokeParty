//
//  ScreenScannerTests.swift
//  PokePartyTests
//
//  Exercises the appraisal-bar reader, which is what actually determines the
//  scanned IVs — the CP badge OCRs unreliably and the appraisal screen never
//  shows the level as text, so nothing else pins down attack and defense.
//
//  Two layers: synthetic screens drawn at known IVs, and a real capture of the
//  iPhone Mirroring window. The synthetic ones cover spreads that are awkward
//  to collect by hand (empty bars, hundos); the real one is the guard against
//  assumptions that only hold in a drawing, which is how earlier versions of
//  this reader kept passing while returning nonsense.
//
//  ScreenScanner itself is macOS-only, so this whole file is unavailable on
//  iOS.
//

#if os(macOS)

import AppKit
import Foundation
import Testing
import Vision
@testable import PokeParty

// MARK: - Synthetic screens

private let imageWidth = 800
private let imageHeight = 460
private let labelX = 60
private let segmentWidth = 90
private let segmentGap = 6
private let barHeight = 18
private let rowSpacing = 110

/// Renders the appraisal card's layout: three left-aligned stat labels, each
/// with a bar below it split into three segments of 5 IVs, on a white card
/// with artwork alongside. Colors and proportions are taken from a real
/// capture (`Fixtures/metang_appraisal.png`).
private func makeAppraisalImage(atk: Int, def: Int, hp: Int) -> CGImage? {
    let rows: [(label: String, labelY: Int, iv: Int)] = [
        ("Attack", 70, atk), ("Defense", 70 + rowSpacing, def), ("HP", 70 + rowSpacing * 2, hp)
    ]
    let fillColor = CGColor(red: 243 / 255, green: 166 / 255, blue: 75 / 255, alpha: 1)
    let trackColor = CGColor(red: 226 / 255, green: 226 / 255, blue: 228 / 255, alpha: 1)

    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(
        data: nil, width: imageWidth, height: imageHeight, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
    // Saturated artwork past the card's right edge — the trainer photo behind
    // the real card, which the reader must not mistake for bar fill.
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 520, y: 0, width: imageWidth - 520, height: imageHeight))

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    defer { NSGraphicsContext.restoreGraphicsState() }

    for (label, labelY, iv) in rows {
        // Laid out top-down, matching the scanner's convention, then converted
        // for CGContext's bottom-up drawing space.
        let textRectHeight = 34
        let textRect = NSRect(
            x: labelX, y: imageHeight - labelY - textRectHeight / 2,
            width: 300, height: textRectHeight)
        (label as NSString).draw(in: textRect, withAttributes: [
            .font: NSFont.systemFont(ofSize: 26, weight: .semibold),
            .foregroundColor: NSColor(cgColor: fillColor)!
        ])

        // The bar sits below its label at no fixed offset — the reader locates
        // it — so use a proportion that differs from any constant in the code.
        let barY = labelY + Int(Double(rowSpacing) * 0.44)
        for segment in 0..<3 {
            let x = labelX + segment * (segmentWidth + segmentGap)
            let rect = CGRect(
                x: x, y: imageHeight - barY - barHeight / 2,
                width: segmentWidth, height: barHeight)
            context.setFillColor(trackColor)
            context.fill(rect)

            let filledIVs = min(max(iv - segment * 5, 0), 5)
            guard filledIVs > 0 else { continue }
            context.setFillColor(fillColor)
            context.fill(CGRect(
                x: rect.minX, y: rect.minY,
                width: Double(segmentWidth) * Double(filledIVs) / 5, height: rect.height))
        }
    }
    return context.makeImage()
}

private func readBars(_ image: CGImage) async throws -> BarIVs? {
    let scanner = ScreenScanner()
    let observations = try await scanner.recognizeText(in: image)
    return await scanner.extractBarIVs(from: observations, image: image)
}

// A reading within 1 of the truth is as good as exact downstream, where bar
// IVs feed a ±1 filter on the candidate list.
@Test(arguments: [
    (atk: 10, def: 15, hp: 12),   // ordinary mixed spread
    (atk: 15, def: 15, hp: 15),   // hundo: every segment full
    (atk: 14, def: 14, hp: 13),   // equal attack and defense — the case that broke
                                  // an earlier cross-row "shared edge" heuristic
    (atk: 0,  def: 7,  hp: 15),   // empty attack bar: no fill pixels at all
    (atk: 3,  def: 12, hp: 1),    // a sliver of fill in the first segment
    (atk: 5,  def: 10, hp: 15),   // fills ending exactly on segment boundaries
    (atk: 3,  def: 8,  hp: 13),   // Inkay spread: three-row ±2px averaging returned
                                  // hp=9 because adjacent rows fell near a segment
                                  // boundary; single best-row reads hp=13 correctly
])
func barReaderRecoversKnownIVs(expected: (atk: Int, def: Int, hp: Int)) async throws {
    let image = try #require(makeAppraisalImage(atk: expected.atk, def: expected.def, hp: expected.hp))
    let bars = try #require(
        await readBars(image),
        "bar reader gave up on a spread it should have read: \(expected)")

    let readAtk = try #require(bars.atk)
    let readDef = try #require(bars.def)
    let readHp = try #require(bars.hp)
    #expect(abs(readAtk - expected.atk) <= 1, "attack read \(readAtk), expected \(expected.atk)")
    #expect(abs(readDef - expected.def) <= 1, "defense read \(readDef), expected \(expected.def)")
    #expect(abs(readHp - expected.hp) <= 1, "HP read \(readHp), expected \(expected.hp)")
}

// MARK: - Real capture

/// A capture of the iPhone Mirroring window showing a Metang's appraisal, the
/// same image the scanner gets at runtime. Its bars measure out to 2/15/13:
/// attack barely into its first segment, defense full, HP most of the way
/// through its third.
private func metangCapture() throws -> CGImage {
    let url = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/metang_appraisal.png")
    let data = try #require(NSData(contentsOf: url))
    let rep = try #require(NSBitmapImageRep(data: data as Data))
    return try #require(rep.cgImage)
}

@Test func barReaderReadsRealCapture() async throws {
    let bars = try #require(await readBars(metangCapture()))
    #expect(bars.atk == 2)
    #expect(bars.def == 15)
    #expect(bars.hp == 13)
}

@Test func realCaptureOCRFindsSpeciesAndHP() async throws {
    let image = try metangCapture()
    let scanner = ScreenScanner()
    let observations = try await scanner.recognizeText(in: image)
    let info = try #require(await scanner.extractPokemonInfo(from: observations))

    // The name comes from "This Metang was caught on…", not the header, which
    // reads "Metang 55" — the player's nickname.
    #expect(info.name == "Metang")
    #expect(info.maxHP == 129)
    // No level anywhere on this screen as text, which is why the HP-and-level
    // route to the HP IV can't carry the feature on its own.
    #expect(info.level == nil)
}

#endif
