// Conduck
// WatchAutoSpeakVerdictTests.swift
//
// Exhaustive matrix for the pure Watch auto-speak decider. The function never
// touches WatchKit / the recording service — it operates on plain values
// (source tag, two conversation ids, one flag), so each case is a single
// call with one term flipped off an all-satisfied baseline.
//
// The verdict is ELIGIBILITY only — "stage the one-shot speak?" — and does NOT
// gate on app-active (that "safe to play now" gate lives at the play site,
// `WatchConversationThreadView.attemptAutoSpeak`, re-fired on wrist-raise).
// True for a VOICE source (`.headless` / `.ask` / `.composer`) whose reply
// matches the in-flight conversation, with the toggle on — "voice speaks, text
// doesn't". Every other shape (TYPED `.composerText`, nil source, mismatched or
// nil in-flight id, toggle off) MUST stay silent — false.

import XCTest
@testable import Conduck

final class WatchAutoSpeakVerdictTests: XCTestCase {

    /// All-satisfied baseline; each test flips exactly the term under test.
    private func verdict(
        source: WatchCaptureSource?,
        replyConversationID: UUID,
        inFlightConversationID: UUID?,
        toggleOn: Bool = true
    ) -> Bool {
        WatchAutoSpeakVerdict.shouldAutoSpeak(
            source: source,
            replyConversationID: replyConversationID,
            inFlightConversationID: inFlightConversationID,
            toggleOn: toggleOn
        )
    }

    // MARK: - Source matrix (everything else satisfied)

    func testSpeaksForHeadlessSource() {
        let id = UUID()
        XCTAssertTrue(verdict(source: .headless, replyConversationID: id, inFlightConversationID: id))
    }

    func testSpeaksForAskSource() {
        let id = UUID()
        XCTAssertTrue(verdict(source: .ask, replyConversationID: id, inFlightConversationID: id))
    }

    func testSpeaksForComposerVoiceSource() {
        // Watch carve-out: in-thread VOICE follow-ups auto-speak ("voice speaks,
        // text doesn't") — the wrist is a glance/hands-free surface.
        let id = UUID()
        XCTAssertTrue(verdict(source: .composer, replyConversationID: id, inFlightConversationID: id))
    }

    func testStaysSilentForComposerTypedSource() {
        // Typed sends never auto-speak — you're reading the screen you typed into.
        let id = UUID()
        XCTAssertFalse(verdict(source: .composerText, replyConversationID: id, inFlightConversationID: id))
    }

    func testStaysSilentForNilSource() {
        // No latched turn (deferred-relay drain, or a reply with no live
        // capture context) — must stay silent.
        let id = UUID()
        XCTAssertFalse(verdict(source: nil, replyConversationID: id, inFlightConversationID: id))
    }

    // MARK: - Conversation match

    func testStaysSilentWhenReplyIsForADifferentConversation() {
        // The resurrected-old-task aliasing case: a stale background task's
        // reply for conversation B lands while conversation A's turn is in
        // flight — B must not speak over A.
        XCTAssertFalse(verdict(source: .headless, replyConversationID: UUID(), inFlightConversationID: UUID()))
    }

    func testStaysSilentWhenNoConversationIsInFlight() {
        // A nil in-flight id can't disambiguate whose reply this is → silent.
        XCTAssertFalse(verdict(source: .headless, replyConversationID: UUID(), inFlightConversationID: nil))
        XCTAssertFalse(verdict(source: .ask, replyConversationID: UUID(), inFlightConversationID: nil))
    }

    // MARK: - Toggle

    func testStaysSilentWhenToggleIsOff() {
        let id = UUID()
        XCTAssertFalse(verdict(source: .headless, replyConversationID: id, inFlightConversationID: id, toggleOn: false))
        XCTAssertFalse(verdict(source: .ask, replyConversationID: id, inFlightConversationID: id, toggleOn: false))
        XCTAssertFalse(verdict(source: .composer, replyConversationID: id, inFlightConversationID: id, toggleOn: false))
    }

    // MARK: - App state
    //
    // The verdict no longer gates on app-active — staging happens the moment the
    // reply lands (even wrist-down), and the "safe to play now" gate (scene
    // `.active`) lives at the play site (`attemptAutoSpeak`), re-fired on the
    // wrist-raise. So a wrist-down reply is eligible here and speaks when the
    // user next raises their wrist (within the mailbox freshness window).
}
