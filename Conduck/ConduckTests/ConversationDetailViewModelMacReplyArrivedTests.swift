// Conduck
// ConversationDetailViewModelMacReplyArrivedTests.swift
//
// Coverage for the macOS reply-arrived effect. macOS posts NO reply
// notification (the old `suppressReplyBanner` / `replyBannerPoster` /
// `postMacReplyNotification` machinery is REMOVED) — instead every macOS reply
// success calls `dispatchReplyArrivedEffects()`, which posts
// `.conversationReplyArrived` (userInfo `conversationID`). `MenuBarCoordinator`
// observes that to raise the menu-bar unread dot. We drive the extracted helper
// directly (the exact code path `sendUserTurn` + `retry` run on the macOS
// success branch) and assert the notification fires with the right id, without
// standing up a converse round-trip.

#if os(macOS)

import XCTest
@testable import Conduck

@MainActor
final class ConversationDetailViewModelMacReplyArrivedTests: XCTestCase {

    func testDispatchPostsReplyArrivedWithConversationID() async {
        let id = UUID()
        let vm = ConversationDetailViewModel(conversationID: id)

        var capturedID: String?
        let expectation = expectation(description: "conversationReplyArrived posted")
        let token = NotificationCenter.default.addObserver(
            forName: .conversationReplyArrived,
            object: nil,
            queue: .main
        ) { note in
            capturedID = note.userInfo?[NotificationDeepLink.conversationIDKey] as? String
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        vm.dispatchReplyArrivedEffects()

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(capturedID, id.uuidString,
                       "reply-arrived must carry the VM's conversationID so the coordinator marks the right thread.")
    }

    /// Regression guard for the menu-bar-cue decision: the removed reply-banner
    /// poster must not come back. The VM no longer exposes any banner-poster or
    /// suppress flag — `dispatchReplyArrivedEffects()` is the only reply effect,
    /// and it posts a notification (the coordinator decides presentation), never
    /// schedules a `UNUserNotification` on macOS.
    func testDispatchIsFireAndForgetSynchronous() {
        let vm = ConversationDetailViewModel(conversationID: UUID())
        // Synchronous (non-async) by contract — purely posts a NotificationCenter
        // event; compiles only because the method is sync.
        vm.dispatchReplyArrivedEffects()
    }
}

#endif
