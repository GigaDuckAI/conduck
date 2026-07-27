// SPDX-License-Identifier: Apache-2.0

// Conduck
// SpeechChunkQueueSeamStallTests.swift
//
// Behavioral tests for `SpeechChunkQueue`'s OPTIONAL seam-stall grace — the
// Watch-only mid-turn stall bound (`seamStallTimeout`). The surface engine's
// first-audio watchdog covers a stalled HEAD; once audio starts it disarms, so
// a wedged TAIL fetch would otherwise silence a seam for the fetch's whole
// transport timeout. The grace timer bounds that wait and routes through the
// EXISTING failed-chunk fallback machinery (Apple speaks `segments[k...]`,
// played chunks never re-spoken, `onFinished` never fires).
//
// What this suite locks (the file-header contract of SpeechChunkQueue.swift):
//   - expiry at a stuck seam ⇒ the SAME terminal as a fetch failure at that
//     index (remainder text + firstAudioFired), exactly once;
//   - a user-paused/parked queue NEVER runs the timer (audio must never start
//     under a pause); `resume()` re-arms with a fresh grace;
//   - a chunk landing inside the grace disarms the timer (no stale expiry
//     killing a healthy turn);
//   - nil `seamStallTimeout` (the iOS/CarPlay default) = no timer at all —
//     byte-identical waiting behavior;
//   - the HEAD wait never arms it (pre-first-audio is the watchdog's job).
//
// Reuses the neighbor suite's fakes (fake players + suspendable fetches +
// terminal recorder) so the two files can't drift on the player contract.
// Unlike the neighbor suite, the grace timer is REAL time — tests inject tiny
// (150 ms) deadlines and pump with a condition-driven drain, mirroring
// ReplyVoiceChunkingTests' watchdog test; negative waits sleep well past the
// deadline (400 ms) so "must not fire" can't pass by racing the clock. Privacy:
// no reply text, audio bytes, or errors are ever logged; segment strings are
// neutral fixtures.

#if !os(watchOS)
import XCTest
@testable import Conduck

@MainActor
final class SpeechChunkQueueSeamStallTests: XCTestCase {

    private typealias FakeChunkPlayerFactory = SpeechChunkQueueTests.FakeChunkPlayerFactory
    private typealias FetchController = SpeechChunkQueueTests.FetchController
    private typealias TerminalRecorder = SpeechChunkQueueTests.TerminalRecorder

    // MARK: - Helpers

    /// Bounded executor pump (yields + 1 ms sleeps) — used before NEGATIVE
    /// assertions to give a stray timer a chance to incorrectly fire.
    private func drain(_ iterations: Int = 25) async {
        for _ in 0..<iterations {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// Condition-driven drain (bounded, deterministic outcome): pump until
    /// `condition` holds; the assertions that follow report any real mismatch.
    /// The budget (~0.5 s+) comfortably covers the 150 ms test graces.
    private func drain(until condition: @autoclosure @MainActor () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// Build a queue wired to a fresh recorder, with the seam-stall grace
    /// under test (nil = the iOS/CarPlay default).
    private func makeQueue(
        segments: [String],
        fetches: FetchController,
        factory: FakeChunkPlayerFactory,
        seamStallTimeout: Duration?
    ) -> (SpeechChunkQueue, TerminalRecorder) {
        let recorder = TerminalRecorder()
        let queue = SpeechChunkQueue(
            segments: segments,
            fetch: { index, _ in try await fetches.fetch(index: index) },
            players: factory,
            seamStallTimeout: seamStallTimeout,
            onFirstAudio: { recorder.recordFirstAudio() },
            onFinished: { recorder.recordFinished() },
            onFallback: { remaining, fired in recorder.recordFallback(remaining, fired) }
        )
        return (queue, recorder)
    }

    // MARK: - 1. Expiry at a stuck seam = the existing fallback, played chunks preserved

    /// Chunk 0 plays and finishes; chunk 1's fetch never resolves. At the
    /// grace deadline the queue must fall back exactly like a chunk-1 fetch
    /// failure: `segments[1...].joined()` to Apple, `firstAudioFired == true`,
    /// no `onFinished`, chunk 0 never re-spoken — and the late fetch resolving
    /// afterwards stays inert.
    func testSeamStallExpiryFallsBackWithUnplayedRemainder() async throws {
        let segments = ["A. ", "B. ", "C."]
        let fetches = FetchController()
        fetches.modes = [0: .succeed, 1: .suspend, 2: .suspend]
        let factory = FakeChunkPlayerFactory()
        let (queue, recorder) = makeQueue(segments: segments, fetches: fetches,
                                          factory: factory, seamStallTimeout: .milliseconds(150))

        queue.start(); await drain()
        let player0 = try XCTUnwrap(factory.player(forChunk: 0))
        XCTAssertEqual(recorder.firstAudioCount, 1)
        player0.finish(); await drain(10)        // parked at the chunk-1 seam
        XCTAssertEqual(recorder.fallbackCount, 0, "The grace hasn't elapsed yet.")

        await drain(until: recorder.fallbackCount == 1)
        XCTAssertEqual(recorder.fallbackCount, 1, "Expiry must fire the fallback terminal.")
        XCTAssertEqual(recorder.lastFallbackRemaining, segments[1...].joined(),
                       "Only the UNPLAYED remainder goes to Apple — played chunks are never re-spoken.")
        XCTAssertEqual(recorder.lastFallbackFirstAudioFired, true)
        XCTAssertEqual(recorder.finishedCount, 0, "A stall turn never fires onFinished.")
        XCTAssertEqual(player0.playCount, 1, "Chunk 0 must not replay.")

        // The wedged fetch resolving late must change nothing.
        fetches.releaseAllRemaining(); await drain()
        XCTAssertEqual(recorder.terminalCount, 1, "Exactly one terminal total.")
        XCTAssertEqual(factory.players.count, 1, "No player may be built post-terminal.")
    }

    // MARK: - 2. Paused queues never run the timer; resume re-arms

    /// A user pause landing at the seam must park the timer with the queue —
    /// no fallback can fire under a pause (audio must never start there).
    /// `resume()` re-arms a FRESH grace, after which the stall falls back.
    func testUserPauseParksTimerAndResumeRearms() async throws {
        let segments = ["Head. ", "Tail."]
        let fetches = FetchController()
        fetches.modes = [0: .succeed, 1: .suspend]
        let factory = FakeChunkPlayerFactory()
        let (queue, recorder) = makeQueue(segments: segments, fetches: fetches,
                                          factory: factory, seamStallTimeout: .milliseconds(150))

        queue.start(); await drain()
        try XCTUnwrap(factory.player(forChunk: 0)).finish(); await drain()   // at the seam
        queue.pause()

        // Wait well past the grace: the parked queue must stay silent.
        try? await Task.sleep(for: .milliseconds(400)); await drain()
        XCTAssertEqual(recorder.fallbackCount, 0,
                       "A user-paused queue must NOT run the seam-stall timer.")

        queue.resume()
        await drain(until: recorder.fallbackCount == 1)
        XCTAssertEqual(recorder.fallbackCount, 1, "resume() re-arms the grace, which then expires.")
        XCTAssertEqual(recorder.lastFallbackRemaining, segments[1...].joined())
        XCTAssertEqual(recorder.finishedCount, 0)

        fetches.releaseAllRemaining(); await drain()
        XCTAssertEqual(recorder.terminalCount, 1)
    }

    // MARK: - 3. A chunk landing inside the grace disarms the timer

    /// The awaited chunk arriving before the deadline must cancel the timer —
    /// the turn then completes normally with no stale expiry ambushing it.
    func testChunkLandingWithinGraceDisarmsTimer() async throws {
        let segments = ["Head. ", "Tail."]
        let fetches = FetchController()
        fetches.modes = [0: .succeed, 1: .suspend]
        let factory = FakeChunkPlayerFactory()
        let (queue, recorder) = makeQueue(segments: segments, fetches: fetches,
                                          factory: factory, seamStallTimeout: .milliseconds(150))

        queue.start(); await drain()
        try XCTUnwrap(factory.player(forChunk: 0)).finish()                  // timer armed
        fetches.release(1); await drain()                                    // lands well inside the grace
        let player1 = try XCTUnwrap(factory.player(forChunk: 1))
        XCTAssertEqual(player1.playCount, 1, "The landed chunk plays normally.")

        // Wait past the (disarmed) deadline mid-play: nothing may fire.
        try? await Task.sleep(for: .milliseconds(400)); await drain()
        XCTAssertEqual(recorder.fallbackCount, 0, "A disarmed timer must never fire.")

        player1.finish(); await drain()
        XCTAssertEqual(recorder.finishedCount, 1)
        XCTAssertEqual(recorder.terminalCount, 1)
    }

    // MARK: - 4. Nil timeout (iOS/CarPlay default) = no timer at all

    /// Without a configured grace the queue waits indefinitely (the fetch's
    /// own transport timeout is the only bound) — the pre-existing behavior
    /// the nil default must keep byte-identical.
    func testNilSeamStallTimeoutWaitsUnbounded() async throws {
        let segments = ["Head. ", "Tail."]
        let fetches = FetchController()
        fetches.modes = [0: .succeed, 1: .suspend]
        let factory = FakeChunkPlayerFactory()
        let (queue, recorder) = makeQueue(segments: segments, fetches: fetches,
                                          factory: factory, seamStallTimeout: nil)

        queue.start(); await drain()
        try XCTUnwrap(factory.player(forChunk: 0)).finish(); await drain()

        try? await Task.sleep(for: .milliseconds(400)); await drain()
        XCTAssertEqual(recorder.fallbackCount, 0, "No grace configured → no stall terminal.")
        XCTAssertEqual(recorder.finishedCount, 0, "The queue is still (correctly) waiting.")

        fetches.release(1); await drain()
        try XCTUnwrap(factory.player(forChunk: 1)).finish(); await drain()
        XCTAssertEqual(recorder.finishedCount, 1, "The landed chunk completes the turn normally.")
        XCTAssertEqual(recorder.terminalCount, 1)
    }

    // MARK: - 5. The head wait never arms the timer

    /// Pre-first-audio stalls are the SURFACE watchdog's job (it hands the
    /// whole reply to Apple and tears the queue down) — the queue's grace must
    /// not double-cover the head, or the two timers would race.
    func testHeadWaitDoesNotArmSeamStall() async throws {
        let segments = ["Head. ", "Tail."]
        let fetches = FetchController()
        fetches.modes = [0: .suspend, 1: .suspend]
        let factory = FakeChunkPlayerFactory()
        let (queue, recorder) = makeQueue(segments: segments, fetches: fetches,
                                          factory: factory, seamStallTimeout: .milliseconds(150))

        queue.start(); await drain()

        try? await Task.sleep(for: .milliseconds(400)); await drain()
        XCTAssertEqual(recorder.fallbackCount, 0,
                       "A stalled HEAD must not trigger the seam grace — that's the watchdog's job.")
        XCTAssertEqual(recorder.firstAudioCount, 0)

        // The head landing late still plays normally.
        fetches.release(0); await drain()
        XCTAssertEqual(recorder.firstAudioCount, 1)

        fetches.releaseAllRemaining(); await drain()
        try XCTUnwrap(factory.player(forChunk: 0)).finish(); await drain()
        try XCTUnwrap(factory.player(forChunk: 1)).finish(); await drain()
        XCTAssertEqual(recorder.finishedCount, 1)
        XCTAssertEqual(recorder.terminalCount, 1)
    }
}
#endif
