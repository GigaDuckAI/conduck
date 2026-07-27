// SPDX-License-Identifier: Apache-2.0

// Conduck
// AutoSpeakSelectionTests.swift
//
// Locks the fix for the Watch follow-up auto-speak bug: a reply-arrival stages
// the EXACT reply (id + text) in the mailbox, and that payload must WIN over the
// thread view's `threadMessages` array — which, on a follow-up turn, still holds
// the PREVIOUS reply at arm time (the new bubble lands via an async, coalesced
// refresh). The decision lives in the pure `AutoSpeakSelection.resolve`
// (`Services/TTS/SpeakEngine.swift`), so it is testable headless without the
// SwiftUI view.

import XCTest
@testable import Conduck

@MainActor
final class AutoSpeakSelectionTests: XCTestCase {

    private func staged(
        conversationID: UUID = UUID(),
        messageID: UUID?,
        text: String?
    ) -> AutoSpeakMailbox.Request {
        AutoSpeakMailbox.Request(
            conversationID: conversationID,
            requestedAt: Date(),
            messageID: messageID,
            text: text
        )
    }

    /// THE bug fix: the staged reply is spoken even though the view's array
    /// still shows the previous turn's bubble.
    func testStagedPayloadWinsOverStaleArray() {
        let newID = UUID()
        let pick = AutoSpeakSelection.resolve(
            staged: staged(messageID: newID, text: "current reply"),
            arrayLatest: (id: UUID(), text: "previous reply")
        )
        XCTAssertEqual(pick?.id, newID)
        XCTAssertEqual(pick?.text, "current reply")
    }

    /// Notification-tap open (no payload) falls back to the loaded thread's
    /// latest agent bubble — preserves iOS/macOS + watch tap behavior.
    func testNilPayloadFallsBackToArrayLatest() {
        let latestID = UUID()
        let pick = AutoSpeakSelection.resolve(
            staged: staged(messageID: nil, text: nil),
            arrayLatest: (id: latestID, text: "loaded reply")
        )
        XCTAssertEqual(pick?.id, latestID)
        XCTAssertEqual(pick?.text, "loaded reply")
    }

    /// Nothing speakable yet (no payload, no agent bubble) → nil, so the caller
    /// skips the destructive consume and the one-shot survives to the refresh.
    func testNoPayloadAndEmptyArrayReturnsNil() {
        XCTAssertNil(AutoSpeakSelection.resolve(
            staged: staged(messageID: nil, text: nil), arrayLatest: nil))
        XCTAssertNil(AutoSpeakSelection.resolve(staged: nil, arrayLatest: nil))
    }

    /// An empty staged text must not win — degrade to the array fallback.
    func testEmptyStagedTextFallsBackToArray() {
        let latestID = UUID()
        let pick = AutoSpeakSelection.resolve(
            staged: staged(messageID: UUID(), text: ""),
            arrayLatest: (id: latestID, text: "loaded reply")
        )
        XCTAssertEqual(pick?.id, latestID)
    }

    /// A staged payload missing its id can't be spoken with the right bubble
    /// identity → fall back to the array.
    func testStagedTextWithoutMessageIDFallsBackToArray() {
        let latestID = UUID()
        let pick = AutoSpeakSelection.resolve(
            staged: staged(messageID: nil, text: "orphan text"),
            arrayLatest: (id: latestID, text: "loaded reply")
        )
        XCTAssertEqual(pick?.id, latestID)
    }
}
