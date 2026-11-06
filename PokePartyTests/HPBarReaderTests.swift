//
//  HPBarReaderTests.swift
//  PokePartyTests
//
//  Synthetic frames: a white-outlined bar with a dark track and flat fill, on a
//  noisy background standing in for scenery.
//

import CoreVideo
import Foundation
import Testing
@testable import PokeParty

private let width = 1206, height = 2622

private func frame(bars: [(x: Int, y: Int, fill: Double)]) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
    let pixelBuffer = buffer!
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
    func set(_ x: Int, _ y: Int, _ r: Int, _ g: Int, _ b: Int) {
        let o = y * stride + x * 4
        base[o] = UInt8(b); base[o + 1] = UInt8(g); base[o + 2] = UInt8(r); base[o + 3] = 255
    }
    // Textured grass-ish background.
    for y in 0..<height { for x in 0..<width { let n = (x * 7 + y * 13) % 17; set(x, y, 60 + n, 80 + n, 45 + n) } }
    let trackWidth = 330
    for bar in bars {
        // White outline, dark track, flat mint fill (119, 251, 193) over `fill` of the track.
        for y in (bar.y - 8)...(bar.y + 28) { for x in (bar.x - 6)...(bar.x + trackWidth + 6) { set(x, y, 255, 255, 255) } }
        for y in bar.y...(bar.y + 20) { for x in bar.x..<(bar.x + trackWidth) { set(x, y, 45, 56, 37) } }
        for y in bar.y...(bar.y + 20) { for x in bar.x..<(bar.x + Int(Double(trackWidth) * bar.fill)) { set(x, y, 119, 251, 193) } }
    }
    return pixelBuffer
}

@Suite struct HPBarReaderTests {

    @Test func readsBothBars() {
        let reading = HPBarReader.read(frame(bars: [(x: 70, y: 1500, fill: 0.78), (x: 640, y: 1150, fill: 0.93)]))

        #expect(abs((reading.mine ?? -1) - 0.78) < 0.03)
        #expect(abs((reading.opponent ?? -1) - 0.93) < 0.03)
    }

    @Test func readsAFullBar() {
        let reading = HPBarReader.read(frame(bars: [(x: 70, y: 1500, fill: 1.0)]))

        #expect((reading.mine ?? 0) > 0.97)
        #expect(reading.opponent == nil)
    }

    @Test func aFrameWithoutBarsReadsNothing() {
        #expect(HPBarReader.read(frame(bars: [])) == HPReading())
    }
}
