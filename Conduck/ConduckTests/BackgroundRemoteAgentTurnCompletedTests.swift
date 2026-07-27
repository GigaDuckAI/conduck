// SPDX-License-Identifier: Apache-2.0

// Conduck
// BackgroundRemoteAgentTurnCompletedTests.swift
//
// Coverage for the SHARED reply-completion signal. On a successful reply
// persist, `BackgroundRemoteAgent.recordReply` fires
// `BackgroundRemoteAgent.postTurnCompleted` as its LAST step — the single poster
// of `.remoteAgentTurnDidComplete` (userInfo `conversationID`), shared by the iOS
// background delegate AND the macOS foreground share-drain landing
// (`SharedInboxDrainer` → `RemoteAgentClient.send` → `recordReply`). The menu-bar
// reply cue (`MenuBarCoordinator`) observes it to raise the unread dot. We drive
// the extracted poster directly (no store / no network) and assert it carries the
// conversationID so the coordinator marks the RIGHT thread — the regression guard
// for the macOS share-reply-cue fix (a background URLSession deferred this signal
// until the inactive menu-bar app was re-activated; the foreground path fires it
// in-process, immediately).

import XCTest
@testable import Conduck

final class BackgroundRemoteAgentTurnCompletedTests: XCTestCase {

    func testPostTurnCompletedCarriesConversationID() async {
        let id = UUID()
        var capturedID: String?
        let expectation = expectation(description: "remoteAgentTurnDidComplete posted")
        let token = NotificationCenter.default.addObserver(
            forName: .remoteAgentTurnDidComplete,
            object: nil,
            queue: .main
        ) { note in
            capturedID = note.userInfo?[NotificationDeepLink.conversationIDKey] as? String
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        await BackgroundRemoteAgent.postTurnCompleted(conversationID: id)

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(
            capturedID, id.uuidString,
            "turn-completion must carry the conversationID so the menu-bar cue marks the right thread."
        )
    }
}
