//
//  BattleHeaderTests.swift
//  PokePartyTests
//
//  Header reading is tested on synthetic frames painted with the colours
//  sampled from real battle screenshots.
//

import CoreVideo
import Foundation
import Testing
@testable import PokeParty

private let alive = (r: 220, g: 54, b: 43)
private let fainted = (r: 100, g: 71, b: 69)
private let shield = (r: 209, g: 165, b: 235)
private let white = (r: 255, g: 255, b: 255)

/// A white 1206×2622 BGRA frame with a coloured dot at each (x fraction, colour) on the header row.
private func frame(dots: [(Double, (r: Int, g: Int, b: Int))]) -> CVPixelBuffer {
    let width = 1206, height = 2622
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
    let pixelBuffer = buffer!
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
    for row in 0..<height {
        for column in 0..<width {
            let o = row * stride + column * 4
            base[o] = 255; base[o + 1] = 255; base[o + 2] = 255; base[o + 3] = 255
        }
    }
    let cy = Int((0.1310 * Double(height)).rounded())
    for (fraction, c) in dots {
        let cx = Int((fraction * Double(width)).rounded())
        for dy in -12...12 {
            for dx in -12...12 {
                let o = (cy + dy) * stride + (cx + dx) * 4
                base[o] = UInt8(c.b); base[o + 1] = UInt8(c.g); base[o + 2] = UInt8(c.r)
            }
        }
    }
    return pixelBuffer
}

private let myBalls = [0.0543, 0.1076, 0.1620]
private let opponentBalls = [0.8370, 0.8913, 0.9457]
private let myShields = [0.2359, 0.2826]
private let opponentShields = [0.7174, 0.7641]

@Suite struct BattleHeaderTests {

    @Test func readsFullHealthFreshBattle() {
        let dots = myBalls.map { ($0, alive) } + opponentBalls.map { ($0, alive) }
            + myShields.map { ($0, shield) } + opponentShields.map { ($0, shield) }
        let reading = BattleHeaderReader.read(frame(dots: dots))

        #expect(reading == BattleHeaderReading(myShields: 2, opponentShields: 2, myAlive: 3, opponentAlive: 3))
    }

    @Test func countsFaintedBallsAndSpentShields() {
        let dots = [(myBalls[0], alive), (myBalls[1], alive), (myBalls[2], fainted)]
            + [(opponentBalls[0], fainted), (opponentBalls[1], fainted), (opponentBalls[2], alive)]
            + [(myShields[0], shield)]
            + [(opponentShields[0], shield), (opponentShields[1], shield)]
        let reading = BattleHeaderReader.read(frame(dots: dots))

        #expect(reading == BattleHeaderReading(myShields: 1, opponentShields: 2, myAlive: 2, opponentAlive: 1))
    }

    @Test func aFrameWithoutBallsIsNotABattle() {
        #expect(BattleHeaderReader.read(frame(dots: [])) == nil)
    }

    @Test func parsesEffectivenessLabels() {
        #expect(EffectivenessFlash.parse(["SUPER EFFECTIVE!"]) == .superEffective)
        #expect(EffectivenessFlash.parse(["NOT VERY EFFECTIVE..."]) == .notVeryEffective)
        #expect(EffectivenessFlash.parse(["Clodsire21", "CP 1495"]) == nil)
    }
}
