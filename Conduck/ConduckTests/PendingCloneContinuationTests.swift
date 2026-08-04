// SPDX-License-Identifier: Apache-2.0

// Conduck
// PendingCloneContinuationTests.swift
//
// Locks the one-shot authorization that carries "Clone & continue on <gateway>"
// from the SOURCE thread's sheet (which performs the clone) to the DESTINATION
// thread's view (the only place that can dispatch on it).
//
// The properties that matter are all about NOT firing:
//   - consumed exactly once, so two surfaces reaching the same thread cannot
//     both dispatch
//   - scoped to its conversation, so concurrent clones in two scenes cannot
//     drain each other
//   - the ARMED phase expires, so a token stranded by a failed navigation cannot
//     fire on some later visit to the thread — the authorization is a tap, and a
//     tap does not stay fresh
//   - the DISPATCHING phase does not expire, and is shared rather than per-view,
//     so a retry in flight is never interrupted by a clock and a second window
//     cannot offer Try Again for a turn another window is already sending
//   - `isSuppressed` never consumes and never mutates: it is read from `body`
//     during a SwiftUI view update.

import XCTest
@testable import Conduck

@MainActor
final class PendingCloneContinuationTests: XCTestCase {

    private let box = PendingCloneContinuation.shared

    override func setUp() async throws {
        box.resetForTesting()
    }

    override func tearDown() async throws {
        box.resetForTesting()
    }

    func testTakeConsumesExactlyOnce() {
        let conversation = UUID(), message = UUID()
        box.arm(conversationID: conversation, messageID: message)

        XCTAssertEqual(box.take(conversationID: conversation), message)
        XCTAssertNil(box.take(conversationID: conversation),
                     "A second claim must find nothing — `beginRetry`'s CAS is the backstop, not the primary guard.")
    }

    func testTakeIgnoresOtherConversations() {
        let mine = UUID(), theirs = UUID(), message = UUID()
        box.arm(conversationID: mine, messageID: message)

        XCTAssertNil(box.take(conversationID: theirs),
                     "A thread must never drain another thread's continuation.")
        XCTAssertEqual(box.take(conversationID: mine), message,
                       "…and the rightful owner's claim must still be there afterwards.")
    }

    func testConcurrentClonesDoNotClobberEachOther() {
        // macOS window + menu-bar popover, or an iPad split view, can clone two
        // different conversations before either destination appears.
        let a = (conversation: UUID(), message: UUID())
        let b = (conversation: UUID(), message: UUID())
        box.arm(conversationID: a.conversation, messageID: a.message)
        box.arm(conversationID: b.conversation, messageID: b.message)

        XCTAssertEqual(box.take(conversationID: a.conversation), a.message)
        XCTAssertEqual(box.take(conversationID: b.conversation), b.message)
    }

    func testExpiredTokenNeverFires() {
        let conversation = UUID(), message = UUID()
        let armedAt = Date()
        box.arm(conversationID: conversation, messageID: message, now: armedAt)

        let tooLate = armedAt.addingTimeInterval(PendingCloneContinuation.validity + 1)
        XCTAssertFalse(box.isSuppressed(conversationID: conversation, messageID: message, now: tooLate))
        XCTAssertNil(box.take(conversationID: conversation, now: tooLate),
                     "A stranded token must not dispatch on some later visit to the thread.")
    }

    func testIsSuppressedDoesNotConsume() {
        let conversation = UUID(), message = UUID()
        box.arm(conversationID: conversation, messageID: message)

        // Read from `body` on every render — consuming here would let the first
        // re-render disarm the continuation before `.onAppear` ever claimed it.
        XCTAssertTrue(box.isSuppressed(conversationID: conversation, messageID: message))
        XCTAssertTrue(box.isSuppressed(conversationID: conversation, messageID: message))
        XCTAssertEqual(box.take(conversationID: conversation), message)
    }

    func testIsSuppressedIsScopedToTheExactMessage() {
        let conversation = UUID(), message = UUID()
        box.arm(conversationID: conversation, messageID: message)

        XCTAssertFalse(box.isSuppressed(conversationID: conversation, messageID: UUID()),
                       "Only the continued row suppresses its delivery error; every other failed row in the thread keeps it.")
    }

    func testFinishClearsSuppressionAfterAClaim() {
        // The suppression must never outlive the attempt it covers: a
        // continuation that genuinely failed has to show its real verdict.
        let conversation = UUID(), message = UUID()
        box.arm(conversationID: conversation, messageID: message)
        XCTAssertEqual(box.take(conversationID: conversation), message)

        XCTAssertTrue(box.isSuppressed(conversationID: conversation, messageID: message),
                      "Still dispatching — the delivery row stays withheld.")
        box.finish(conversationID: conversation)
        XCTAssertFalse(box.isSuppressed(conversationID: conversation, messageID: message))
    }

    func testDispatchingSuppressionIsSharedAcrossSurfacesAndDoesNotExpire() {
        // A second window on the same conversation must not render a Try Again
        // for a turn the first window is dispatching — which is why the
        // dispatching phase lives in the shared box, not per-view state. And an
        // in-flight retry has no deadline: expiring it would surface a delivery
        // error for a delivery still in progress.
        let conversation = UUID(), message = UUID()
        let armedAt = Date()
        box.arm(conversationID: conversation, messageID: message, now: armedAt)
        XCTAssertEqual(box.take(conversationID: conversation, now: armedAt), message)

        let wayLater = armedAt.addingTimeInterval(PendingCloneContinuation.validity * 100)
        XCTAssertTrue(box.isSuppressed(conversationID: conversation, messageID: message, now: wayLater))
    }
}
