// SPDX-License-Identifier: Apache-2.0

// Conduck
// CarPlayVADQuantizationTests.swift
//
// Makes the CarPlay endpointing dial's dead zones executable knowledge.
//
// The streaming VAD consumes fixed 4096-sample frames at 16 kHz, so a
// `minSilenceDuration` in seconds is rounded UP to whole 256 ms chunks — and the
// first silent chunk contributes nothing to the library's silence counter, which
// costs one chunk more:
//
//     felt = (ceil(minSilence / 0.256) + 1) × 0.256
//
// Two consequences a tuner has to know before touching the constant. First, the
// felt endpoint is always LONGER than the setting — 1.5 s buys 1.792 s of
// trailing silence. Second, every value inside one 256 ms band behaves
// identically, so "nudge it up a bit" is frequently a no-op, and somebody
// concluding the dial does nothing is how a dial ends up dead.
//
// The bands are half-open on the LEFT: a setting sitting exactly on a 256 ms
// multiple belongs to the band BELOW it. That boundary is where binary floating
// point can lie (`0.768 / 0.256` can land a hair above 3), so every step in the
// design's table is asserted from both sides — on the boundary and just past it
// — rather than only at comfortable midpoints.

import XCTest
@testable import Conduck

final class CarPlayVADQuantizationTests: XCTestCase {

    /// One chunk, in seconds. Everything here is a multiple of it.
    private let chunk = CarPlayVADQuantization.chunkDuration

    /// Comparisons are on doubles built by different arithmetic (a literal here,
    /// `chunks × 0.256` in the implementation), so they are compared with a
    /// tolerance far tighter than a chunk and far looser than a rounding error.
    private let tolerance = 1e-9

    private func assertFelt(
        _ minSilence: TimeInterval,
        _ expected: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            CarPlayVADQuantization.feltEndOfSpeechDelay(minSilence: minSilence),
            expected,
            accuracy: tolerance,
            "minSilence \(minSilence) s should feel like \(expected) s",
            file: file,
            line: line
        )
    }

    // MARK: - The frame quantum

    func testChunkDurationIsOneStreamingFrame() {
        // 4096 samples at 16 kHz.
        XCTAssertEqual(chunk, 4096.0 / 16000.0, accuracy: tolerance)
        XCTAssertEqual(chunk, 0.256, accuracy: tolerance)
    }

    // MARK: - The shipping value

    func testShippingMinSilenceFeelsLikeOnePointSevenNineTwoSeconds() {
        // The number the design commits to, and the reason 1.5 s was chosen over
        // anything in the band below it.
        assertFelt(1.5, 1.792)
        assertFelt(Constants.carPlayVADMinSilence, 1.792)
    }

    // MARK: - Both sides of every step boundary

    // Each pair is (boundary value, the felt time it still belongs to). A value
    // exactly on the boundary sits in the LOWER band; a hair above it moves up
    // one full chunk. These are the six steps the design tabulates.

    func testBoundaryHalfSecondTwelve() {
        assertFelt(0.512, 0.768)          // on the boundary → lower band
        assertFelt(0.512 + 0.001, 1.024)  // just past it → next band
    }

    func testBoundarySevenSixEight() {
        assertFelt(0.768, 1.024)
        assertFelt(0.768 + 0.001, 1.280)
    }

    func testBoundaryOneZeroTwoFour() {
        assertFelt(1.024, 1.280)
        assertFelt(1.024 + 0.001, 1.536)
    }

    func testBoundaryOneTwoEight() {
        assertFelt(1.280, 1.536)
        assertFelt(1.280 + 0.001, 1.792)
    }

    func testBoundaryOneFiveThreeSix() {
        assertFelt(1.536, 1.792)
        assertFelt(1.536 + 0.001, 2.048)
    }

    func testBoundaryOneSevenNineTwo() {
        assertFelt(1.792, 2.048)
        assertFelt(1.792 + 0.001, 2.304)
    }

    // MARK: - The dead zone, stated directly

    func testEveryValueInsideOneBandFeelsIdentical() {
        // The whole (1.280, 1.536] band lands on 1.792 s. Anyone "tuning" from
        // 1.30 to 1.50 has changed nothing at the microphone.
        let band: [TimeInterval] = [1.281, 1.30, 1.4, 1.45, 1.5, 1.536]
        let felt = band.map { CarPlayVADQuantization.feltEndOfSpeechDelay(minSilence: $0) }
        for value in felt {
            XCTAssertEqual(value, 1.792, accuracy: tolerance)
        }
    }

    func testTheOldSettingFeltLongerThanItsNumberToo() {
        // Kept as a worked example of the formula on a value from the band two
        // steps below the shipping one: 0.8 s of configured silence was 1.28 s
        // of felt silence.
        assertFelt(0.8, 1.280)
    }

    // MARK: - Structural properties

    func testFeltDelayIsAlwaysAWholeNumberOfChunks() {
        for hundredths in 1...400 {
            let minSilence = TimeInterval(hundredths) / 100.0
            let felt = CarPlayVADQuantization.feltEndOfSpeechDelay(minSilence: minSilence)
            let chunks = felt / chunk
            XCTAssertEqual(chunks, chunks.rounded(), accuracy: 1e-6, "felt \(felt) is not a whole chunk count")
        }
    }

    func testFeltDelayIsAlwaysStrictlyLongerThanTheSetting() {
        // The extra chunk is not an implementation detail anyone may optimize
        // away: it is the library's silence counter ignoring the first silent
        // chunk. If this ever fails, the endpoint arrived early.
        for hundredths in 1...400 {
            let minSilence = TimeInterval(hundredths) / 100.0
            XCTAssertGreaterThan(
                CarPlayVADQuantization.feltEndOfSpeechDelay(minSilence: minSilence),
                minSilence
            )
        }
    }

    func testFeltDelayNeverDecreasesAsTheSettingGrows() {
        var previous = 0.0
        for thousandths in 1...4000 {
            let felt = CarPlayVADQuantization.feltEndOfSpeechDelay(
                minSilence: TimeInterval(thousandths) / 1000.0
            )
            XCTAssertGreaterThanOrEqual(felt, previous)
            previous = felt
        }
    }

    // MARK: - Degenerate input

    func testNonPositiveSettingsCollapseToOneChunk() {
        // Nothing can endpoint faster than a single frame of inference.
        assertFelt(0, chunk)
        assertFelt(-1, chunk)
    }

    func testAVerySmallSettingStillCostsTwoChunks() {
        // One chunk to reach the threshold, one the counter ignores.
        assertFelt(0.001, 0.512)
    }
}
