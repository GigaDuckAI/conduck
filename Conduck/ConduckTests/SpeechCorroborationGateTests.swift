// SPDX-License-Identifier: Apache-2.0

// Conduck
// SpeechCorroborationGateTests.swift
//
// Locks the CarPlay minimum-speech gate: the rule that decides whether a burst
// of above-threshold audio was somebody talking or a door closing.
//
// It exists because the streaming VAD has no minimum-speech rule of its own —
// `minSpeechDuration` belongs to the batch segmenter and is ignored on the
// streaming path — so ONE 256 ms chunk of road noise is enough to make the
// library declare speech. That single chunk used to cancel the no-speech timer,
// end the capture on the library's own end-of-speech, produce an empty
// transcript, and kill the session. The gate is what stands between a pothole
// and a dead conversation.
//
// The three properties worth breaking a build over:
//
//   1. RAW PROBABILITIES, NEVER THE LIBRARY'S STATE. Entry at 0.65 releases only
//      at 0.50, and that release is then held for the whole silence window, so
//      after a one-chunk blip the library still reports "in speech" for several
//      quiet chunks. A gate keyed on that state would auto-approve the exact
//      blip it exists to reject. Every test here feeds probabilities only.
//   2. THE SCAN DOES NOT STOP AT A DISCARDED BLIP. FluidAudio may never emit a
//      second `.speechStart` inside one episode, so real speech arriving after a
//      rejected blip has to be able to corroborate in the SAME episode.
//   3. CORROBORATION IS REPORTED EXACTLY ONCE. The caller wires an at-most-once
//      "speech started" callback straight to it, and that callback cancels the
//      kill timer and latches the detector's single-fire flag.
//
// Pure value type, no audio, no model — the whole gate is exercised here and
// the founder's cabin QA is left to judge the tuning, not the logic.

import XCTest
@testable import Conduck

final class SpeechCorroborationGateTests: XCTestCase {

    /// The shipping CarPlay configuration, so a change to the constant shows up
    /// here as well as in the timing contract test.
    private func carPlayGate() -> SpeechCorroborationGate {
        SpeechCorroborationGate(threshold: Constants.carPlayVADThreshold)
    }

    // MARK: - Starting state

    func testGateStartsUncorroboratedAndEmpty() {
        let gate = carPlayGate()
        XCTAssertFalse(gate.isCorroborated)
        XCTAssertEqual(gate.consecutiveQualifyingChunks, 0)
        XCTAssertFalse(gate.hasPendingQualifyingChunks)
    }

    func testDefaultRequirementIsTwoChunks() {
        XCTAssertEqual(SpeechCorroborationGate.defaultRequiredConsecutiveChunks, 2)
        XCTAssertEqual(carPlayGate().requiredConsecutiveChunks, 2)
    }

    // MARK: - The blip

    func testSingleQualifyingChunkDoesNotCorroborate() {
        var gate = carPlayGate()
        XCTAssertEqual(gate.observe(probability: 0.9), .qualifying)
        XCTAssertFalse(gate.isCorroborated)
        XCTAssertEqual(gate.consecutiveQualifyingChunks, 1)
    }

    func testSingleBlipFollowedBySilenceNeverCorroborates() {
        var gate = carPlayGate()
        gate.observe(probability: 0.97)
        // Everything after the blip is quiet — a door, a pothole, a wiper.
        for probability: Float in [0.10, 0.02, 0.31, 0.00, 0.44, 0.12] {
            XCTAssertEqual(gate.observe(probability: probability), .belowThreshold)
        }
        XCTAssertFalse(gate.isCorroborated)
        XCTAssertEqual(gate.consecutiveQualifyingChunks, 0)
    }

    func testSubThresholdChunkResetsTheRun() {
        var gate = carPlayGate()
        XCTAssertEqual(gate.observe(probability: 0.80), .qualifying)
        XCTAssertEqual(gate.observe(probability: 0.40), .belowThreshold)
        XCTAssertEqual(gate.consecutiveQualifyingChunks, 0)
        // The next loud chunk starts a NEW run rather than completing the old
        // one: two chunks either side of a quiet chunk are two blips.
        XCTAssertEqual(gate.observe(probability: 0.80), .qualifying)
        XCTAssertFalse(gate.isCorroborated)
    }

    // MARK: - Corroboration

    func testTwoConsecutiveQualifyingChunksCorroborate() {
        var gate = carPlayGate()
        XCTAssertEqual(gate.observe(probability: 0.71), .qualifying)
        XCTAssertEqual(gate.observe(probability: 0.68), .corroborated)
        XCTAssertTrue(gate.isCorroborated)
        // The run has done its job and is cleared, so the pending-chunk grace
        // cannot mistake a corroborated gate for one mid-run.
        XCTAssertEqual(gate.consecutiveQualifyingChunks, 0)
        XCTAssertFalse(gate.hasPendingQualifyingChunks)
    }

    func testProbabilityExactlyAtThresholdQualifies() {
        var gate = carPlayGate()
        XCTAssertEqual(gate.observe(probability: Constants.carPlayVADThreshold), .qualifying)
        XCTAssertEqual(gate.observe(probability: Constants.carPlayVADThreshold), .corroborated)
    }

    func testProbabilityJustBelowThresholdDoesNotQualify() {
        var gate = SpeechCorroborationGate(threshold: 0.65)
        XCTAssertEqual(gate.observe(probability: 0.649), .belowThreshold)
        XCTAssertEqual(gate.observe(probability: 0.649), .belowThreshold)
        XCTAssertFalse(gate.isCorroborated)
    }

    func testCorroborationIsReportedExactlyOnce() {
        var gate = carPlayGate()
        var corroboratedCount = 0
        // A long, loud, entirely ordinary utterance.
        for probability: Float in [0.9, 0.9, 0.95, 0.88, 0.30, 0.91, 0.93, 0.10] {
            if case .corroborated = gate.observe(probability: probability) {
                corroboratedCount += 1
            }
        }
        XCTAssertEqual(corroboratedCount, 1, "the speech-start callback is at-most-once")
    }

    func testEveryObservationAfterCorroborationReportsAlreadyCorroborated() {
        var gate = carPlayGate()
        gate.observe(probability: 0.9)
        XCTAssertEqual(gate.observe(probability: 0.9), .corroborated)
        // Loud, quiet and non-finite alike: the latch holds for the life of the
        // gate, which is one listen.
        XCTAssertEqual(gate.observe(probability: 0.99), .alreadyCorroborated)
        XCTAssertEqual(gate.observe(probability: 0.01), .alreadyCorroborated)
        XCTAssertEqual(gate.observe(probability: .nan), .alreadyCorroborated)
        XCTAssertTrue(gate.isCorroborated)
    }

    // MARK: - Scanning continues after a discarded blip

    func testScanningContinuesAfterADiscardedBlipInTheSameEpisode() {
        var gate = carPlayGate()
        // A blip, the library's uncorroborated `.speechEnd` (which the detector
        // discards without touching the gate), then the driver actually speaks.
        var corroboratedCount = 0
        let stream: [Float] = [0.88, 0.12, 0.05, 0.03, 0.79, 0.84, 0.91]
        for probability in stream {
            if case .corroborated = gate.observe(probability: probability) {
                corroboratedCount += 1
            }
        }
        XCTAssertEqual(corroboratedCount, 1)
        XCTAssertTrue(gate.isCorroborated, "a rejected blip must not stop the gate scanning")
    }

    func testManyBlipsInARowStillDoNotCorroborate() {
        var gate = carPlayGate()
        // Rhythmic road noise: one loud chunk, one quiet chunk, forever.
        for index in 0..<40 {
            gate.observe(probability: index.isMultiple(of: 2) ? 0.93 : 0.20)
        }
        XCTAssertFalse(gate.isCorroborated)
    }

    // MARK: - Non-finite probabilities

    func testNonFiniteProbabilitiesBreakTheRunAndNeverQualify() {
        for bad: Float in [.nan, .infinity, -.infinity] {
            var gate = carPlayGate()
            XCTAssertEqual(gate.observe(probability: 0.9), .qualifying)
            XCTAssertEqual(
                gate.observe(probability: bad), .belowThreshold,
                "a non-finite probability is never evidence of speech"
            )
            XCTAssertEqual(gate.consecutiveQualifyingChunks, 0)
            XCTAssertEqual(gate.observe(probability: 0.9), .qualifying)
            XCTAssertFalse(gate.isCorroborated)
        }
    }

    // MARK: - Pending-run visibility (drives the expiry-boundary grace)

    func testHasPendingQualifyingChunksTracksTheRunInProgress() {
        var gate = carPlayGate()
        XCTAssertFalse(gate.hasPendingQualifyingChunks)
        gate.observe(probability: 0.90)
        XCTAssertTrue(
            gate.hasPendingQualifyingChunks,
            "one qualifying chunk on the board is what earns the one-quantum deferral"
        )
        gate.observe(probability: 0.10)
        XCTAssertFalse(gate.hasPendingQualifyingChunks)
    }

    func testCorroboratedGateHasNoPendingChunks() {
        var gate = carPlayGate()
        gate.observe(probability: 0.9)
        gate.observe(probability: 0.9)
        XCTAssertFalse(
            gate.hasPendingQualifyingChunks,
            "a corroborated listen has already cancelled its kill timer; there is nothing to defer"
        )
    }

    // MARK: - Requirement configuration

    func testRequirementOfThreeNeedsThreeConsecutiveChunks() {
        var gate = SpeechCorroborationGate(threshold: 0.65, requiredConsecutiveChunks: 3)
        XCTAssertEqual(gate.observe(probability: 0.9), .qualifying)
        XCTAssertEqual(gate.observe(probability: 0.9), .qualifying)
        XCTAssertEqual(gate.observe(probability: 0.9), .corroborated)
    }

    func testRequirementIsClampedToAtLeastOneChunk() {
        // A zero or negative requirement would corroborate before observing
        // anything at all; clamping keeps the gate a gate.
        for requirement in [0, -3] {
            var gate = SpeechCorroborationGate(threshold: 0.65, requiredConsecutiveChunks: requirement)
            XCTAssertEqual(gate.requiredConsecutiveChunks, 1)
            XCTAssertFalse(gate.isCorroborated)
            XCTAssertEqual(gate.observe(probability: 0.9), .corroborated)
        }
    }

    // MARK: - Value semantics

    func testGateIsAValueTypeAndCopiesDoNotShareState() {
        var gate = carPlayGate()
        gate.observe(probability: 0.9)
        var copy = gate
        copy.observe(probability: 0.9)
        XCTAssertTrue(copy.isCorroborated)
        XCTAssertFalse(gate.isCorroborated, "one gate is built per listen and must not leak across")
    }
}
