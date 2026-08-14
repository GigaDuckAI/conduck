// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationRowFormatterTests.swift
//
// The conversation-list row's two pure string derivations:
// `MessageRowFormatters.conversationSubtitle` (role-aware "You: " prefix) and
// `MessageRowFormatters.rowAccessibilityLabel` (the composed VoiceOver label).
//
// The load-bearing properties, each of which is a real defect if it inverts:
//
//   1. THE PREFIX NEVER REACHES A HEADLINE. `conversationTitle` uses the same
//      raw tail text as its title fallback, so a "You: " baked into the cached
//      preview would render as the conversation's name. Pinned by asserting
//      both functions against ONE raw string.
//   2. AN ATTACHMENT-ONLY TURN SHOWS NO LINE. Those rows store empty `text`;
//      a bare "You:" with nothing after it is the failure mode.
//   3. STATE LEADS THE SPOKEN LABEL, and a delivery state coexisting with an
//      unseen reply announces BOTH — the same orthogonality the mark and the
//      bold title render.
//   4. NO LIVE CLOCK IN THE LABEL. An accessibility label that rewrites on a
//      timer produces a stream of repeated announcements over the whole wait.

import XCTest
@testable import Conduck

@MainActor
final class ConversationRowFormatterTests: XCTestCase {

    // MARK: - Fixtures

    private let noon = Date(timeIntervalSince1970: 1_760_000_000)

    private func working(
        _ confidence: WorkingConfidence = .live,
        since: TimeInterval = 0,
        unseen: Bool = false
    ) -> ConversationRowState {
        ConversationRowState(
            activity: .working(confidence, since: noon.addingTimeInterval(-since)),
            hasUnseenReply: unseen
        )
    }

    // MARK: - Subtitle

    func testUserTailIsPrefixed() {
        let subtitle = MessageRowFormatters.conversationSubtitle(
            text: "can you check the permit", role: .user)
        XCTAssertEqual(subtitle, String(localized: "conversation.row.youSaid",
                                        defaultValue: "You: \("can you check the permit")"))
        XCTAssertTrue(subtitle?.contains("can you check the permit") == true)
    }

    func testAgentTailIsNotPrefixed() {
        let reply = "The permit is approved."
        XCTAssertEqual(MessageRowFormatters.conversationSubtitle(text: reply, role: .agent), reply)
    }

    /// A row whose tail role has not been projected yet (the lazy tail fetch is
    /// still in flight) must not GUESS a prefix — the row renders the text plain
    /// and repaints when the role lands.
    func testUnknownRoleIsNotPrefixed() {
        let text = "either of us could have said this"
        XCTAssertEqual(MessageRowFormatters.conversationSubtitle(text: text, role: nil), text)
    }

    func testNilTailProducesNoLine() {
        XCTAssertNil(MessageRowFormatters.conversationSubtitle(text: nil, role: .user))
        XCTAssertNil(MessageRowFormatters.conversationSubtitle(text: nil, role: nil))
    }

    /// Property 2. An attachment-only user turn stores empty text; the row must
    /// omit the subtitle rather than render a dangling "You:".
    func testAttachmentOnlyTurnProducesNoLine() {
        for empty in ["", "   ", "\n\n", " \t\n "] {
            XCTAssertNil(
                MessageRowFormatters.conversationSubtitle(text: empty, role: .user),
                "An attachment-only turn (empty text) must omit the subtitle, never render a bare prefix.")
            XCTAssertNil(MessageRowFormatters.conversationSubtitle(text: empty, role: .agent))
        }
    }

    /// Property 1. The SAME raw tail string drives both the subtitle and the
    /// title fallback; only the subtitle may carry the prefix.
    func testPrefixNeverLeaksIntoTheTitleFallback() {
        let raw = "can you check the permit"
        let subtitle = MessageRowFormatters.conversationSubtitle(text: raw, role: .user)
        let title = MessageRowFormatters.conversationTitle(
            title: nil, titleSnippet: nil, lastMessagePreview: raw)

        XCTAssertNotEqual(subtitle, title, "The subtitle is prefixed; the headline is not.")
        XCTAssertEqual(title, raw)
        XCTAssertFalse(title.hasPrefix("You"),
                       "A 'You: ' baked into the cached preview would render as the conversation's NAME.")
    }

    // MARK: - Accessibility label — state leads

    func testIdleRowLeadsWithItsTitle() {
        let label = MessageRowFormatters.rowAccessibilityLabel(
            state: ConversationRowState(activity: .idle, hasUnseenReply: false),
            title: "Kitchen renovation",
            subtitle: "The permit is approved.",
            gatewayName: "OpenClaw",
            lastActivityAt: noon,
            showsGateway: false,
            now: noon)
        XCTAssertTrue(label.hasPrefix("Kitchen renovation"),
                      "A row with nothing to report opens with its title, not a state word.")
    }

    func testAnsweredUnseenLeadsWithNewReply() {
        let label = MessageRowFormatters.rowAccessibilityLabel(
            state: ConversationRowState(activity: .answeredUnseen, hasUnseenReply: true),
            title: "Kitchen renovation",
            subtitle: "The permit is approved.",
            gatewayName: "OpenClaw",
            lastActivityAt: noon,
            showsGateway: false,
            now: noon)
        XCTAssertTrue(label.hasPrefix(String(localized: "activity.a11y.newReply", defaultValue: "New reply")))
    }

    func testWorkingLeadsWithWorkingAndThenTheStatusSentence() {
        let label = MessageRowFormatters.rowAccessibilityLabel(
            state: working(.live, since: 120),
            title: "Kitchen renovation",
            subtitle: "You: can you check the permit",
            gatewayName: "OpenClaw",
            lastActivityAt: noon,
            showsGateway: true,
            now: noon)

        XCTAssertTrue(label.hasPrefix(String(localized: "activity.a11y.working", defaultValue: "Working")))
        XCTAssertTrue(label.contains("OpenClaw"), "The status sentence names the gateway for a live turn.")
        XCTAssertTrue(label.contains("You: can you check the permit"))
    }

    func testFailedLeadsWithNotSent() {
        let label = MessageRowFormatters.rowAccessibilityLabel(
            state: ConversationRowState(activity: .failed, hasUnseenReply: false),
            title: "Kitchen renovation",
            subtitle: "You: can you check the permit",
            gatewayName: "OpenClaw",
            lastActivityAt: noon,
            showsGateway: false,
            now: noon)
        XCTAssertTrue(label.hasPrefix(ConversationActivityCopy.notSent))
    }

    /// Acknowledgement is PRESENTATIONAL — it retires the red mark and cools the
    /// metadata colour, neither of which a VoiceOver user perceives. The spoken
    /// label is therefore identical: the message still was not sent, and a label
    /// that changed on being read would announce the row twice for no new fact.
    func testASeenFailureSpeaksExactlyAsAnUnseenOneDoes() {
        func label(acknowledged: Bool) -> String {
            MessageRowFormatters.rowAccessibilityLabel(
                state: ConversationRowState(
                    activity: .failed,
                    hasUnseenReply: false,
                    failureAcknowledged: acknowledged
                ),
                title: "Kitchen renovation",
                subtitle: "You: can you check the permit",
                gatewayName: "OpenClaw",
                lastActivityAt: noon,
                showsGateway: false,
                now: noon)
        }
        XCTAssertEqual(label(acknowledged: true), label(acknowledged: false))
        XCTAssertTrue(label(acknowledged: true).hasPrefix(ConversationActivityCopy.notSent))
    }

    /// "Not sent … Sent at 12:00" tells a VoiceOver user the turn both was and
    /// was not sent — and the sighted row says only the first half, because a
    /// failed row's metadata line replaces the date with "Not sent".
    func testAFailedRowNeverClaimsItWasSent() {
        let stamp = MessageRowFormatters.conversationListDate(from: noon, now: noon)
        let label = MessageRowFormatters.rowAccessibilityLabel(
            state: ConversationRowState(activity: .failed, hasUnseenReply: false),
            title: "Kitchen renovation",
            subtitle: "You: can you check the permit",
            gatewayName: "OpenClaw",
            lastActivityAt: noon,
            showsGateway: false,
            now: noon)
        XCTAssertFalse(label.contains(String(localized: "activity.a11y.sentAtTime",
                                             defaultValue: "Sent at \(stamp)")))
        XCTAssertTrue(label.hasSuffix("You: can you check the permit"))
    }

    /// Property 3. Delivery and attention are orthogonal, and the label says
    /// both — a failed-and-unseen row must not announce only one of them.
    func testCoexistingStatesAreBothAnnounced() {
        let failedUnseen = MessageRowFormatters.rowAccessibilityLabel(
            state: ConversationRowState(activity: .failed, hasUnseenReply: true),
            title: "Kitchen renovation",
            subtitle: nil,
            gatewayName: "",
            lastActivityAt: noon,
            showsGateway: false,
            now: noon)
        XCTAssertTrue(failedUnseen.hasPrefix(
            String(localized: "activity.a11y.notSentUnseen", defaultValue: "Not sent, new reply")))

        let workingUnseen = MessageRowFormatters.rowAccessibilityLabel(
            state: working(.hedged, since: 300, unseen: true),
            title: "Kitchen renovation",
            subtitle: nil,
            gatewayName: "",
            lastActivityAt: noon,
            showsGateway: false,
            now: noon)
        XCTAssertTrue(workingUnseen.hasPrefix(
            String(localized: "activity.a11y.workingUnseen", defaultValue: "Working, new reply")))
    }

    // MARK: - Accessibility label — gateway naming

    func testGatewayIsNamedOnceForALiveTurn() {
        let label = MessageRowFormatters.rowAccessibilityLabel(
            state: working(.live, since: 60),
            title: "Kitchen renovation",
            subtitle: nil,
            gatewayName: "OpenClaw",
            lastActivityAt: noon,
            showsGateway: true,
            now: noon)
        let occurrences = label.components(separatedBy: "OpenClaw").count - 1
        XCTAssertEqual(occurrences, 1,
                       "The status sentence already names the gateway; the badge stand-in must not repeat it.")
    }

    /// A hedged turn's words ("Waiting for a reply…") deliberately do NOT claim
    /// the gateway is doing anything — so when the badge is on screen the name
    /// still has to reach VoiceOver from somewhere.
    func testHedgedTurnStillNamesTheGatewayWhenTheBadgeShows() {
        let shown = MessageRowFormatters.rowAccessibilityLabel(
            state: working(.hedged, since: 300),
            title: "Kitchen renovation",
            subtitle: nil,
            gatewayName: "OpenClaw",
            lastActivityAt: noon,
            showsGateway: true,
            now: noon)
        XCTAssertTrue(shown.contains("OpenClaw"))

        let hidden = MessageRowFormatters.rowAccessibilityLabel(
            state: working(.hedged, since: 300),
            title: "Kitchen renovation",
            subtitle: nil,
            gatewayName: "OpenClaw",
            lastActivityAt: noon,
            showsGateway: false,
            now: noon)
        XCTAssertFalse(hidden.contains("OpenClaw"),
                       "With no badge on screen there is nothing for the name to stand in for.")
    }

    func testUnresolvableGatewayNameIsNeverSpoken() {
        let label = MessageRowFormatters.rowAccessibilityLabel(
            state: working(.live, since: 60),
            title: "Kitchen renovation",
            subtitle: nil,
            gatewayName: "   ",
            lastActivityAt: noon,
            showsGateway: true,
            now: noon)
        XCTAssertFalse(label.contains(" is answering"),
                       "An unresolved name must fall back to a bare 'Answering…', never ' is answering…'.")
    }

    // MARK: - Accessibility label — the timestamp

    /// Property 4. The label carries an ABSOLUTE reference, and it must not move
    /// as the turn ages: the same row resolved a minute later reads identically.
    func testLabelIsStableAsTheTurnAges() {
        func label(at now: Date) -> String {
            MessageRowFormatters.rowAccessibilityLabel(
                state: working(.hedged, since: 300),
                title: "Kitchen renovation",
                subtitle: "You: can you check the permit",
                gatewayName: "OpenClaw",
                lastActivityAt: noon,
                showsGateway: true,
                now: now)
        }
        XCTAssertEqual(label(at: noon), label(at: noon.addingTimeInterval(600)))
    }

    /// "Sent at Yesterday" is what one format string plus `conversationListDate`
    /// would have produced, so the day-shaped stamp gets its own whole phrase.
    func testTimestampPhraseMatchesTheDayShapeOfTheStamp() {
        let older = noon.addingTimeInterval(-3 * 86_400)
        let stamp = MessageRowFormatters.conversationListDate(from: older, now: noon)

        let label = MessageRowFormatters.rowAccessibilityLabel(
            state: ConversationRowState(activity: .idle, hasUnseenReply: false),
            title: "Kitchen renovation",
            subtitle: nil,
            gatewayName: "",
            lastActivityAt: older,
            showsGateway: false,
            now: noon)

        XCTAssertTrue(label.hasSuffix(String(localized: "activity.a11y.sentOnDay",
                                             defaultValue: "Sent \(stamp)")))
        XCTAssertFalse(label.contains(String(localized: "activity.a11y.sentAtTime",
                                             defaultValue: "Sent at \(stamp)")))
    }

    func testTodayUsesTheAtTimePhrase() {
        let stamp = MessageRowFormatters.conversationListDate(from: noon, now: noon)
        let label = MessageRowFormatters.rowAccessibilityLabel(
            state: ConversationRowState(activity: .idle, hasUnseenReply: false),
            title: "Kitchen renovation",
            subtitle: nil,
            gatewayName: "",
            lastActivityAt: noon,
            showsGateway: false,
            now: noon)
        XCTAssertTrue(label.hasSuffix(String(localized: "activity.a11y.sentAtTime",
                                             defaultValue: "Sent at \(stamp)")))
    }

    // MARK: - Composition

    /// A row with no subtitle must not leave an empty sentence behind — ". ." is
    /// an audible stutter.
    func testNoEmptyComponentsWhenTheSubtitleIsAbsent() {
        let label = MessageRowFormatters.rowAccessibilityLabel(
            state: ConversationRowState(activity: .idle, hasUnseenReply: false),
            title: "Kitchen renovation",
            subtitle: nil,
            gatewayName: "",
            lastActivityAt: noon,
            showsGateway: false,
            now: noon)
        XCTAssertFalse(label.contains(". ."))
        XCTAssertFalse(label.contains("…."))
    }

    func testStatusSentenceLosesItsTrailingEllipsis() {
        let label = MessageRowFormatters.rowAccessibilityLabel(
            state: working(.live, since: 60),
            title: "Kitchen renovation",
            subtitle: "You: check the permit",
            gatewayName: "OpenClaw",
            lastActivityAt: noon,
            showsGateway: true,
            now: noon)
        XCTAssertFalse(label.contains("…."), "A trailing ellipsis plus the joiner is a stutter.")
        XCTAssertTrue(label.contains("OpenClaw is answering. "))
    }
}
