// Conduck
// ReplyAutoSpeakDeciderTests.swift
//
// Exhaustive matrix for the pure notification-tap auto-speak decider (the
// "speak the reply when opened from its notification" feature). The function never
// touches `UNNotificationResponse` directly — it operates on the request
// identifier + userInfo payload + two Bool snapshots (the device-local toggle,
// the live-CarPlay flag), so each case is a string + dictionary literal.
//
// Non-nil ONLY when the identifier carries the REPLY prefix AND the userInfo
// carries a parseable conversationID AND the toggle is on AND no CarPlay voice
// session is live. Every other input shape (failure-prefix identifier, toggle
// off, CarPlay active, missing key, non-string value, unparseable UUID, empty
// string) MUST fall back to nil (stay silent — safer than speaking a stale or
// wrong reply). The failure-prefix case is load-bearing: failure notifications
// (`remoteAgent.failure.<uuid>`) also carry a conversationID for tap-to-retry.

import XCTest
@testable import Conduck

final class ReplyAutoSpeakDeciderTests: XCTestCase {

    private let key = NotificationDeepLink.conversationIDKey

    /// A well-formed REPLY identifier, exactly as `postReplyNotification`
    /// mints it (prefix + the conversation UUID string).
    private func replyIdentifier(for id: UUID) -> String {
        NotificationDeepLink.replyIdentifierPrefix + id.uuidString
    }

    // MARK: - Non-nil (the single happy path)

    func testReturnsConversationIDForReplyTapWithToggleOnAndNoCarPlay() {
        let id = UUID()
        let userInfo: [AnyHashable: Any] = [key: id.uuidString]
        let result = ReplyAutoSpeakDecider.conversationIDForAutoSpeak(
            requestIdentifier: replyIdentifier(for: id),
            userInfo: userInfo,
            toggleOn: true,
            carPlayActive: false
        )
        XCTAssertEqual(result, id)
    }

    // MARK: - Nil: identifier discrimination

    func testNilForFailureIdentifierEvenWithValidConversationID() {
        // FAILURE notifications carry a conversationID too (tap-to-retry) —
        // the prefix test is what stops them speaking a stale previous reply.
        let id = UUID()
        let userInfo: [AnyHashable: Any] = [key: id.uuidString]
        let result = ReplyAutoSpeakDecider.conversationIDForAutoSpeak(
            requestIdentifier: "remoteAgent.failure.\(id.uuidString)",
            userInfo: userInfo,
            toggleOn: true,
            carPlayActive: false
        )
        XCTAssertNil(result)
    }

    // MARK: - Nil: gates

    func testNilWhenToggleIsOff() {
        let id = UUID()
        let userInfo: [AnyHashable: Any] = [key: id.uuidString]
        let result = ReplyAutoSpeakDecider.conversationIDForAutoSpeak(
            requestIdentifier: replyIdentifier(for: id),
            userInfo: userInfo,
            toggleOn: false,
            carPlayActive: false
        )
        XCTAssertNil(result)
    }

    func testNilWhenCarPlaySessionIsActive() {
        let id = UUID()
        let userInfo: [AnyHashable: Any] = [key: id.uuidString]
        let result = ReplyAutoSpeakDecider.conversationIDForAutoSpeak(
            requestIdentifier: replyIdentifier(for: id),
            userInfo: userInfo,
            toggleOn: true,
            carPlayActive: true
        )
        XCTAssertNil(result)
    }

    // MARK: - Nil: malformed payloads

    func testNilWhenUserInfoMissesTheKey() {
        let id = UUID()
        let userInfo: [AnyHashable: Any] = ["unrelated": "payload"]
        let result = ReplyAutoSpeakDecider.conversationIDForAutoSpeak(
            requestIdentifier: replyIdentifier(for: id),
            userInfo: userInfo,
            toggleOn: true,
            carPlayActive: false
        )
        XCTAssertNil(result)
    }

    func testNilWhenValueIsNotAString() {
        let id = UUID()
        let userInfo: [AnyHashable: Any] = [key: NSNumber(value: 42)]
        let result = ReplyAutoSpeakDecider.conversationIDForAutoSpeak(
            requestIdentifier: replyIdentifier(for: id),
            userInfo: userInfo,
            toggleOn: true,
            carPlayActive: false
        )
        XCTAssertNil(result)
    }

    func testNilWhenValueIsAnUnparseableUUIDString() {
        let id = UUID()
        let userInfo: [AnyHashable: Any] = [key: "not-a-uuid"]
        let result = ReplyAutoSpeakDecider.conversationIDForAutoSpeak(
            requestIdentifier: replyIdentifier(for: id),
            userInfo: userInfo,
            toggleOn: true,
            carPlayActive: false
        )
        XCTAssertNil(result)
    }

    func testNilWhenValueIsAnEmptyString() {
        let id = UUID()
        let userInfo: [AnyHashable: Any] = [key: ""]
        let result = ReplyAutoSpeakDecider.conversationIDForAutoSpeak(
            requestIdentifier: replyIdentifier(for: id),
            userInfo: userInfo,
            toggleOn: true,
            carPlayActive: false
        )
        XCTAssertNil(result)
    }

    func testNilWhenUserInfoIsEmpty() {
        let id = UUID()
        let userInfo: [AnyHashable: Any] = [:]
        let result = ReplyAutoSpeakDecider.conversationIDForAutoSpeak(
            requestIdentifier: replyIdentifier(for: id),
            userInfo: userInfo,
            toggleOn: true,
            carPlayActive: false
        )
        XCTAssertNil(result)
    }
}
