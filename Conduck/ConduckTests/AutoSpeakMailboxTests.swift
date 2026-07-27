// SPDX-License-Identifier: Apache-2.0

// Conduck
// AutoSpeakMailboxTests.swift
//
// Coverage for the shared read-aloud one-shot mailbox (`AutoSpeakMailbox`,
// `Services/TTS/SpeakEngine.swift`) — the type both the iOS notification-open
// path and the Watch arrival/open paths stage requests through. The one-shot
// + freshness semantics are exactly what keeps a stale request from ambushing
// a later thread open, so they get direct tests (the deciders that GATE
// staging are covered separately in `ReplyAutoSpeakDeciderTests` /
// `WatchAutoSpeakVerdictTests`).
//
// Deterministic: every test constructs its own mailbox with an injected
// clock — no singleton state, no sleeping.

import XCTest
@testable import Conduck

@MainActor
final class AutoSpeakMailboxTests: XCTestCase {

    /// Mutable injected clock — tests advance `currentDate` to cross the
    /// freshness boundary without sleeping.
    private final class Clock {
        var currentDate = Date(timeIntervalSinceReferenceDate: 1_000_000)
    }

    private func makeMailbox(freshness: TimeInterval = 60) -> (AutoSpeakMailbox, Clock) {
        let clock = Clock()
        let mailbox = AutoSpeakMailbox(freshness: freshness, now: { clock.currentDate })
        return (mailbox, clock)
    }

    // MARK: - One-shot consume

    func testConsumeMatchingFreshRequestReturnsTrueAndClears() {
        let (mailbox, _) = makeMailbox()
        let id = UUID()
        mailbox.request(id)
        XCTAssertTrue(mailbox.consume(matching: id))
        XCTAssertNil(mailbox.pending, "Consume is one-shot — the request must be cleared.")
        XCTAssertFalse(mailbox.consume(matching: id), "A second consume must find nothing.")
    }

    func testConsumeWithNothingPendingReturnsFalse() {
        let (mailbox, _) = makeMailbox()
        XCTAssertFalse(mailbox.consume(matching: UUID()))
    }

    // MARK: - Mismatched conversation (fresh request survives)

    func testFreshMismatchLeavesRequestPending() {
        let (mailbox, _) = makeMailbox()
        let target = UUID()
        mailbox.request(target)
        XCTAssertFalse(mailbox.consume(matching: UUID()),
                       "A different thread must not consume another thread's request.")
        XCTAssertNotNil(mailbox.pending,
                        "A fresh mismatch leaves the request for its real target (e.g. an iPad split view's other pane).")
        XCTAssertTrue(mailbox.consume(matching: target),
                      "The real target must still be able to drain it.")
    }

    // MARK: - Freshness expiry

    func testExpiredRequestIsClearedOnAnyConsumeAttempt() {
        let (mailbox, clock) = makeMailbox(freshness: 60)
        let target = UUID()
        mailbox.request(target)
        clock.currentDate += 61
        XCTAssertFalse(mailbox.consume(matching: UUID()),
                       "Expired request must not fire — even for a mismatched asker.")
        XCTAssertNil(mailbox.pending,
                     "Expiry clears on ANY consume attempt so the stale flag can't ambush a later open.")
    }

    func testExpiredRequestDoesNotFireForItsOwnTarget() {
        let (mailbox, clock) = makeMailbox(freshness: 15)
        let target = UUID()
        mailbox.request(target)
        clock.currentDate += 16
        XCTAssertFalse(mailbox.consume(matching: target))
        XCTAssertNil(mailbox.pending)
    }

    func testExactFreshnessBoundaryIsExpired() {
        // Strictly-within semantics: age == freshness counts as stale (the
        // `<` boundary the two former per-target coordinators disagreed on).
        let (mailbox, clock) = makeMailbox(freshness: 60)
        let target = UUID()
        mailbox.request(target)
        clock.currentDate += 60
        XCTAssertFalse(mailbox.consume(matching: target))
    }

    func testJustInsideFreshnessBoundaryFires() {
        let (mailbox, clock) = makeMailbox(freshness: 60)
        let target = UUID()
        mailbox.request(target)
        clock.currentDate += 59.5
        XCTAssertTrue(mailbox.consume(matching: target))
    }

    // MARK: - Latest-wins overwrite

    func testSecondRequestOverwritesFirst() {
        let (mailbox, _) = makeMailbox()
        let first = UUID()
        let second = UUID()
        mailbox.request(first)
        mailbox.request(second)
        XCTAssertFalse(mailbox.consume(matching: first),
                       "Only the most recent request may speak — the first was superseded.")
        XCTAssertTrue(mailbox.consume(matching: second))
    }

    // MARK: - Payload round-trip (watch arrival stages reply id + text)

    func testRequestWithPayloadStagesMessageIDAndText() {
        let (mailbox, _) = makeMailbox()
        let convo = UUID()
        let msg = UUID()
        mailbox.request(convo, messageID: msg, text: "the new reply")
        XCTAssertEqual(mailbox.pending?.conversationID, convo)
        XCTAssertEqual(mailbox.pending?.messageID, msg)
        XCTAssertEqual(mailbox.pending?.text, "the new reply")
        XCTAssertTrue(mailbox.consume(matching: convo))
        XCTAssertNil(mailbox.pending, "Payload consume is still one-shot.")
    }

    func testRequestWithoutPayloadLeavesMessageIDAndTextNil() {
        let (mailbox, _) = makeMailbox()
        let convo = UUID()
        mailbox.request(convo)
        XCTAssertNil(mailbox.pending?.messageID,
                     "The no-payload overload (notification-tap) carries no id.")
        XCTAssertNil(mailbox.pending?.text,
                     "The no-payload overload (notification-tap) carries no text.")
    }

    // MARK: - clear()

    func testClearDropsPendingRequest() {
        let (mailbox, _) = makeMailbox()
        let target = UUID()
        mailbox.request(target)
        mailbox.clear()
        XCTAssertNil(mailbox.pending)
        XCTAssertFalse(mailbox.consume(matching: target),
                       "Mic-wins clear must guarantee nothing fires afterwards.")
    }
}
