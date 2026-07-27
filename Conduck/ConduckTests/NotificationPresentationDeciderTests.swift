// SPDX-License-Identifier: Apache-2.0

// Conduck
// NotificationPresentationDeciderTests.swift
//
// Exhaustive matrix for the pure delivery-time decider. The function never
// touches `UNUserNotification` directly — it operates on the userInfo payload
// + a snapshot of `ActiveViewTracker.viewedConversationIDs`, so each case is a
// dictionary literal + a `Set<UUID>` literal.
//
// Suppress = `true` only when the userInfo carries a parseable conversationID
// AND the viewing set contains it. Every other input shape (missing key,
// non-string value, unparseable UUID, empty set, set with different ids) MUST
// fall back to `false` (present the banner — safer than silent drop).

import XCTest
@testable import Conduck

final class NotificationPresentationDeciderTests: XCTestCase {

    private let key = NotificationDeepLink.conversationIDKey

    // MARK: - Suppress = true

    func testSuppressesWhenViewingTheTargetConversation() {
        let id = UUID()
        let userInfo: [AnyHashable: Any] = [key: id.uuidString]
        let result = NotificationPresentationDecider.shouldSuppress(
            userInfo: userInfo,
            viewedConversationIDs: [id]
        )
        XCTAssertTrue(result)
    }

    func testSuppressesWhenTargetIsOneOfManyViewedIDs() {
        // Multi-window / iPad multi-scene scenario.
        let target = UUID()
        let other1 = UUID()
        let other2 = UUID()
        let userInfo: [AnyHashable: Any] = [key: target.uuidString]
        let result = NotificationPresentationDecider.shouldSuppress(
            userInfo: userInfo,
            viewedConversationIDs: [other1, target, other2]
        )
        XCTAssertTrue(result)
    }

    // MARK: - Suppress = false

    func testPresentsWhenSetIsEmpty() {
        let userInfo: [AnyHashable: Any] = [key: UUID().uuidString]
        let result = NotificationPresentationDecider.shouldSuppress(
            userInfo: userInfo,
            viewedConversationIDs: []
        )
        XCTAssertFalse(result)
    }

    func testPresentsWhenSetContainsADifferentID() {
        let target = UUID()
        let visible = UUID()
        let userInfo: [AnyHashable: Any] = [key: target.uuidString]
        let result = NotificationPresentationDecider.shouldSuppress(
            userInfo: userInfo,
            viewedConversationIDs: [visible]
        )
        XCTAssertFalse(result)
    }

    func testPresentsWhenUserInfoMissesTheKey() {
        let id = UUID()
        let userInfo: [AnyHashable: Any] = ["unrelated": "payload"]
        let result = NotificationPresentationDecider.shouldSuppress(
            userInfo: userInfo,
            viewedConversationIDs: [id]
        )
        XCTAssertFalse(result)
    }

    func testPresentsWhenValueIsNotAString() {
        let id = UUID()
        let userInfo: [AnyHashable: Any] = [key: NSNumber(value: 42)]
        let result = NotificationPresentationDecider.shouldSuppress(
            userInfo: userInfo,
            viewedConversationIDs: [id]
        )
        XCTAssertFalse(result)
    }

    func testPresentsWhenValueIsAnUnparseableUUIDString() {
        let id = UUID()
        let userInfo: [AnyHashable: Any] = [key: "not-a-uuid"]
        let result = NotificationPresentationDecider.shouldSuppress(
            userInfo: userInfo,
            viewedConversationIDs: [id]
        )
        XCTAssertFalse(result)
    }

    func testPresentsWhenValueIsAnEmptyString() {
        let id = UUID()
        let userInfo: [AnyHashable: Any] = [key: ""]
        let result = NotificationPresentationDecider.shouldSuppress(
            userInfo: userInfo,
            viewedConversationIDs: [id]
        )
        XCTAssertFalse(result)
    }

    func testPresentsWhenUserInfoIsEmpty() {
        let id = UUID()
        let userInfo: [AnyHashable: Any] = [:]
        let result = NotificationPresentationDecider.shouldSuppress(
            userInfo: userInfo,
            viewedConversationIDs: [id]
        )
        XCTAssertFalse(result)
    }
}
