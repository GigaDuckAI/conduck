// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardAudioCardTests.swift
//
// The two parts of the desk's audio card that are decidable without audio
// hardware: the transport's clock/progress arithmetic, and the exclusivity
// registry that makes starting one card stop another. Playback itself needs a
// real `AVAudioPlayer` and a real session, so it is a founder-QA item; these
// hold the rules that decide what the person is shown and which card owns
// output, which is where a silent regression would actually live.

import XCTest
@testable import Conduck

@MainActor
final class WorkboardAudioCardTests: XCTestCase {

    // MARK: - Clock and progress

    func testProgressIsZeroUntilAClipLengthIsKnown() {
        // A card that has never been played has no duration, and a bar that
        // started full would say the opposite of the truth.
        XCTAssertEqual(WorkboardAudioTiming.fraction(elapsed: 0, duration: 0), 0)
        XCTAssertEqual(WorkboardAudioTiming.fraction(elapsed: 5, duration: 0), 0)
        XCTAssertEqual(WorkboardAudioTiming.fraction(elapsed: 5, duration: -1), 0)
        XCTAssertEqual(WorkboardAudioTiming.fraction(elapsed: .nan, duration: 30), 0)
        XCTAssertEqual(WorkboardAudioTiming.fraction(elapsed: 5, duration: .infinity), 0)
    }

    func testProgressIsTheClampedFractionOfTheClip() {
        XCTAssertEqual(WorkboardAudioTiming.fraction(elapsed: 15, duration: 30), 0.5, accuracy: 0.0001)
        XCTAssertEqual(WorkboardAudioTiming.fraction(elapsed: 30, duration: 30), 1, accuracy: 0.0001)
        // `currentTime` can read a shade past the end on the last tick; the bar
        // must not overflow its track.
        XCTAssertEqual(WorkboardAudioTiming.fraction(elapsed: 31, duration: 30), 1, accuracy: 0.0001)
    }

    func testTheClockReadsAsMinutesAndSecondsAndGrowsAnHourField() {
        XCTAssertEqual(WorkboardAudioTiming.label(0), "0:00")
        XCTAssertEqual(WorkboardAudioTiming.label(7), "0:07")
        XCTAssertEqual(WorkboardAudioTiming.label(59), "0:59")
        XCTAssertEqual(WorkboardAudioTiming.label(60), "1:00")
        XCTAssertEqual(WorkboardAudioTiming.label(723), "12:03")
        XCTAssertEqual(WorkboardAudioTiming.label(3600), "1:00:00")
        XCTAssertEqual(WorkboardAudioTiming.label(3723), "1:02:03")
    }

    func testTheClockTruncatesRatherThanRoundsSoItNeverShowsAnUnreachedSecond() {
        // 7.9s into a clip is still the seventh second: rounding up would show
        // 0:08 against a bar that has not reached it.
        XCTAssertEqual(WorkboardAudioTiming.label(7.9), "0:07")
        XCTAssertEqual(WorkboardAudioTiming.label(59.999), "0:59")
    }

    func testAnUnusableClockValueReadsAsTheStartOfTheClip() {
        XCTAssertEqual(WorkboardAudioTiming.label(-3), "0:00")
        XCTAssertEqual(WorkboardAudioTiming.label(.nan), "0:00")
        XCTAssertEqual(WorkboardAudioTiming.label(.infinity), "0:00")
    }

    // MARK: - Exclusivity

    @MainActor
    private final class StubPlayer: WorkboardAudioExclusive {
        private(set) var stopCount = 0
        func stopForExclusivity() { stopCount += 1 }
    }

    func testStartingOneCardStopsTheCardThatHeldOutput() {
        let registry = WorkboardAudioExclusivity()
        let first = StubPlayer()
        let second = StubPlayer()

        registry.claim(first)
        XCTAssertEqual(first.stopCount, 0)
        XCTAssertTrue(registry.currentHolder === first)

        registry.claim(second)
        XCTAssertEqual(first.stopCount, 1, "The card that held output must be stopped, not left playing under the new one.")
        XCTAssertEqual(second.stopCount, 0)
        XCTAssertTrue(registry.currentHolder === second)
    }

    func testReclaimingTheSameCardDoesNotStopIt() {
        let registry = WorkboardAudioExclusivity()
        let player = StubPlayer()

        registry.claim(player)
        registry.claim(player)

        // Resuming after a pause claims again; stopping itself there would make
        // resume unreachable.
        XCTAssertEqual(player.stopCount, 0)
        XCTAssertTrue(registry.currentHolder === player)
    }

    func testAStaleTerminalCannotSilenceTheCardThatTookOutput() {
        let registry = WorkboardAudioExclusivity()
        let first = StubPlayer()
        let second = StubPlayer()

        registry.claim(first)
        registry.claim(second)
        // `first`'s own teardown resigns AFTER `second` claimed. It must not
        // clear the slot the newer card owns.
        registry.resign(first)

        XCTAssertTrue(registry.currentHolder === second)
        XCTAssertEqual(second.stopCount, 0)
    }

    func testResigningClearsTheSlotWhenTheHolderIsTheOneResigning() {
        let registry = WorkboardAudioExclusivity()
        let player = StubPlayer()

        registry.claim(player)
        registry.resign(player)

        XCTAssertNil(registry.currentHolder)
    }

    func testTheRegistryDoesNotKeepAFinishedCardAlive() {
        let registry = WorkboardAudioExclusivity()
        var player: StubPlayer? = StubPlayer()
        registry.claim(player!)

        player = nil

        // A card scrolled out of existence without resigning must read as no
        // holder, or the next card would send `stopForExclusivity` to a corpse.
        XCTAssertNil(registry.currentHolder)
    }

    // MARK: - Transport phase

    func testAFreshPlayerIsIdleAndItsNextTapStartsPlayback() {
        let player = WorkboardAudioCardPlayer(exclusivity: WorkboardAudioExclusivity())

        XCTAssertEqual(player.phase, .idle)
        XCTAssertEqual(player.elapsed, 0)
        XCTAssertEqual(player.duration, 0)
        XCTAssertEqual(player.fraction, 0)
        XCTAssertTrue(player.willStartPlayback)
    }

    func testBytesThatDoNotDecodeLeaveTheCardFailedAndStillTappable() async {
        let registry = WorkboardAudioExclusivity()
        let player = WorkboardAudioCardPlayer(exclusivity: registry)

        player.toggle { Data("not audio".utf8) }
        await settle(until: { player.phase == .failed })

        XCTAssertEqual(player.phase, .failed)
        // Failure is a state the person can retry out of: the next tap must
        // still mean "play", and the failed card must not be holding output.
        XCTAssertTrue(player.willStartPlayback)
        XCTAssertNil(registry.currentHolder)
        XCTAssertEqual(player.duration, 0)
    }

    func testACardWithNoBytesBehindItFailsRatherThanClaimingOutput() async {
        let registry = WorkboardAudioExclusivity()
        let player = WorkboardAudioCardPlayer(exclusivity: registry)

        // What a `.syncPending` or reattachable card answers if it is ever
        // asked for bytes.
        player.toggle { nil }
        await settle(until: { player.phase == .failed })

        XCTAssertEqual(player.phase, .failed)
        XCTAssertNil(registry.currentHolder)
    }

    func testLeavingTheBoardReturnsTheCardToIdle() async {
        let registry = WorkboardAudioExclusivity()
        let player = WorkboardAudioCardPlayer(exclusivity: registry)

        player.toggle { Data("not audio".utf8) }
        await settle(until: { player.phase == .failed })
        player.deactivate()

        XCTAssertEqual(player.phase, .idle)
        XCTAssertEqual(player.elapsed, 0)
        XCTAssertNil(registry.currentHolder)
    }

    func testASecondTapWhileBytesAreInFlightAbandonsTheAttempt() async {
        let player = WorkboardAudioCardPlayer(exclusivity: WorkboardAudioExclusivity())
        let gate = Gate()

        player.toggle {
            await gate.wait()
            return Data("not audio".utf8)
        }
        XCTAssertEqual(player.phase, .loading)

        player.toggle { nil }
        XCTAssertEqual(player.phase, .idle, "A tap during the load cancels it rather than queueing a second read.")

        await gate.open()
    }

    // MARK: - Helpers

    /// Spins the main actor until `condition` holds, so an assertion never
    /// races a payload read that hops off and back.
    private func settle(
        until condition: () -> Bool,
        attempts: Int = 200,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<attempts {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition never held", file: file, line: line)
    }

    /// A payload read the test controls the timing of.
    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }
}
