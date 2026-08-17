// SPDX-License-Identifier: Apache-2.0

// Conduck
// HeadlessRetryGuardSpanTests.swift
//
// SOURCE DRIFT GUARD over invariant I6 on the ONE lane that can break it
// silently: never destroy a recording the user has already made.
//
// The bug this locks down. `ConverseIntent.perform()` arms `PendingRetryGuard`
// before the microphone's output is spent, and used to disarm the instant STT
// returned — while the DESTINATION was still unresolved. `disarm` cancels the
// deferred "Recording Saved" notification AND clears `PendingRetryStore`, so any
// refusal raised after that point deleted the only copy of what the user said.
// It is reachable through a TIME gap rather than a rule gap: the pre-flight
// approves because a quick-capture pointer is TTL-fresh, the user speaks for
// thirty seconds, the pointer crosses its `SessionContinuationPolicy` window
// mid-recording, and the post-mic resolve refuses. No pre-flight ordering rule
// can close that — only the guard's SPAN can.
//
// Why a source guard and not a behavioural test. `ConverseIntent` is an App
// Intent whose `perform()` takes an `IntentFile` supplied by the Shortcuts
// runtime and drives a live `STTClient` upload; the iOS-Simulator suite cannot
// construct one or reach the code without a network provider. `PendingRetryGuard`
// itself is exercised elsewhere. What is untestable here — and what actually
// broke — is WHERE the disarm sits relative to the refusals, so that is what is
// asserted, in the style of `HeadlessRefusalLaneDriftGuardTests`.
//
// ─────────────────────────────────────────────────────────────────────────────
// WHAT THIS GUARD CHECKS (on comment-stripped source)
//
//   Rule 1 — `perform()` never disarms unconditionally. Its one disarm is gated
//     on the words NOT yet existing as text.
//
//   Rule 2 — the disarm that does run sits BELOW the destination resolve and
//     BELOW the store append, so every refusal on the way is still armed.
//
//   Rule 0 — the negative control: the ordering check genuinely fails on the
//     shape the code used to have.

import XCTest
@testable import Conduck

final class HeadlessRetryGuardSpanTests: XCTestCase {

    private static let intentPath = "Conduck/Intents/ConverseIntent.swift"

    // MARK: - Rule 1 — the pre-transcript gate

    /// A bad-input verdict (silence, an oversized clip, a missing key) may still
    /// clear the lane, because the same bytes cannot succeed twice. A verdict
    /// about the DESTINATION may not, because the same bytes succeed as soon as
    /// the user fixes what it names. `transcriptCaptured` is the line between
    /// them, and it has to be the gate on the disarm rather than a comment about
    /// one.
    func testPerformOnlyDisarmsBeforeTheWordsExistAsText() throws {
        let source = try RefusalLaneSource.source(at: Self.intentPath)
        let body = try RefusalLaneSource.body(ofFunction: "perform", in: source, path: Self.intentPath)

        let disarms = body.components(separatedBy: "PendingRetryGuard.disarm").count - 1
        XCTAssertEqual(disarms, 1,
                       "`perform()` must hold exactly ONE disarm. A second one is how the unconditional "
                       + "post-STT disarm arrived, and it deleted the user's recording on every "
                       + "destination refusal.")

        let gateAt = try XCTUnwrap(
            body.range(of: "if !transcriptCaptured {")?.lowerBound,
            "`perform()`'s disarm is no longer gated on the transcript not existing yet. Ungated, every "
            + "destination verdict — code 12 included — clears the retry lane and the spoken words are "
            + "gone (I6)."
        )
        let disarmAt = try XCTUnwrap(body.range(of: "PendingRetryGuard.disarm")?.lowerBound)
        XCTAssertLessThan(gateAt, disarmAt, "The gate has to precede the disarm, or it gates nothing.")

        // …and the flag must actually be raised, or the gate is always open.
        XCTAssertTrue(body.contains("transcriptCaptured = true"),
                      "Nothing sets the flag, so `!transcriptCaptured` is permanently true and the gate "
                      + "is decorative.")
    }

    /// The flag is raised only once the transcript has been validated non-empty
    /// — before that, `noSpeechDetected` is a verdict about the BYTES and must
    /// still disarm.
    func testTheTranscriptFlagIsRaisedAfterTheEmptyTranscriptRefusal() throws {
        let source = try RefusalLaneSource.source(at: Self.intentPath)
        let body = try RefusalLaneSource.body(ofFunction: "perform", in: source, path: Self.intentPath)

        let silenceAt = try XCTUnwrap(
            body.range(of: "throw AppError.noSpeechDetected")?.lowerBound,
            "The empty-transcript refusal is gone; update this guard."
        )
        let raisedAt = try XCTUnwrap(body.range(of: "transcriptCaptured = true")?.lowerBound)
        XCTAssertLessThan(silenceAt, raisedAt,
                          "Raising the flag before the silence check would preserve a recording of nothing "
                          + "and hand the user a Retry that reaches the same emptiness.")
    }

    // MARK: - Rule 2 — the span reaches past the destination

    /// The refusal that costs the user their words is thrown by
    /// `SharedInboxRouting.resolveOrMint()`, inside `runConverseHop`. The disarm
    /// has to sit below it — and below the append that makes the transcript
    /// durable, which is the moment the recording stops being the only copy.
    func testTheConverseHopDisarmsOnlyAfterTheUserTurnIsStored() throws {
        let source = try RefusalLaneSource.source(at: Self.intentPath)
        let body = try RefusalLaneSource.body(ofFunction: "runConverseHop", in: source, path: Self.intentPath)

        let resolveAt = try XCTUnwrap(
            body.range(of: "SharedInboxRouting.resolveOrMint")?.lowerBound,
            "`runConverseHop` no longer resolves the destination; update this guard."
        )
        let appendAt = try XCTUnwrap(
            body.range(of: "ConversationStore.shared.appendMessage")?.lowerBound,
            "`runConverseHop` no longer appends the user turn; update this guard."
        )
        let disarmAt = try XCTUnwrap(
            body.range(of: "PendingRetryGuard.disarm(retryGuardToken)")?.lowerBound,
            "`runConverseHop` never disarms, so a successful capture leaves a Retry card and a deferred "
            + "'Recording Saved' notification behind for a turn that went out fine."
        )
        XCTAssertLessThan(resolveAt, disarmAt,
                          "A destination refusal raised above the disarm is what keeps the audio in the "
                          + "retry lane. Below it, the words are deleted before the refusal is even "
                          + "surfaced (I6).")
        XCTAssertLessThan(appendAt, disarmAt,
                          "The transcript stops depending on the recording at the append, not before it.")
    }

    /// The token is a required parameter, not an optional with a default. An
    /// optional would let a future call site omit it and silently reinstate the
    /// never-disarms half of the bug.
    func testTheRetryTokenIsThreadedAsARequiredParameter() throws {
        let source = try RefusalLaneSource.source(at: Self.intentPath)
        XCTAssertTrue(source.contains("retryGuardToken: PendingRetryGuard.Token"),
                      "The hop must OWN the disarm decision through a non-optional token.")
        XCTAssertFalse(source.contains("retryGuardToken: PendingRetryGuard.Token?"),
                       "An optional token makes 'forgot to pass it' a compiling, silent no-disarm.")
        XCTAssertTrue(source.contains("retryGuardToken: guardToken"),
                      "`perform()` must actually hand its armed token down, or the hop disarms a token "
                      + "nobody armed.")
    }

    // MARK: - Rule 0 — the negative control

    /// The ordering assertions must genuinely fail on the shape the code had
    /// before this round, or they are checks nobody has seen bite.
    func testTheOrderingChecksDistinguishTheOldShapeFromTheNewOne() throws {
        let oldShape = """
        let response = try await STTClient.shared.transcribe(...)
        await PendingRetryGuard.disarm(guardToken)
        try await Self.runConverseHop(userText: transcript)
        """
        let newShape = """
        let response = try await STTClient.shared.transcribe(...)
        transcriptCaptured = true
        try await Self.runConverseHop(userText: transcript, retryGuardToken: guardToken)
        """
        XCTAssertTrue(oldShape.contains("PendingRetryGuard.disarm"),
                      "Control: the drifted shape disarms inside perform, above the hop.")
        let disarmAt = try XCTUnwrap(oldShape.range(of: "PendingRetryGuard.disarm")?.lowerBound)
        let hopAt = try XCTUnwrap(oldShape.range(of: "runConverseHop")?.lowerBound)
        XCTAssertLessThan(disarmAt, hopAt,
                          "Control: the old shape really did spend the guard before the destination was "
                          + "resolved — that is the whole defect.")
        XCTAssertFalse(newShape.contains("PendingRetryGuard.disarm"),
                       "Control: the compliant shape hands the token down instead of spending it.")
    }
}
