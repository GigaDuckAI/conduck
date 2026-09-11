// SPDX-License-Identifier: Apache-2.0

// A project conversation keeps its draft but never lends a delayed composer
// submission to a different conversation, gateway, or reopened presentation.

import XCTest
@testable import Conduck

@MainActor
final class WorkDeskConversationSessionTests: XCTestCase {
    func testProjectRoundTripPreservesDraftAndRejectsAnOldSubmission() {
        let id = UUID()
        let session = WorkDeskConversationSession(conversationID: id)
        session.draft = "Keep this unsent thought"
        let firstPresentation = session.resume()
        let conversation = record(id: id)
        let dispatch = dispatch(conversationID: id)
        XCTAssertTrue(session.accepts(dispatch, conversation: conversation,
                                      viewModelID: id, presentation: firstPresentation))

        session.suspend()
        XCTAssertEqual(session.draft, "Keep this unsent thought")
        XCTAssertFalse(session.accepts(dispatch, conversation: conversation,
                                       viewModelID: id, presentation: firstPresentation))

        let reopened = session.resume()
        XCTAssertFalse(session.accepts(dispatch, conversation: conversation,
                                       viewModelID: id, presentation: firstPresentation))
        XCTAssertTrue(session.accepts(dispatch, conversation: conversation,
                                      viewModelID: id, presentation: reopened))
        session.suspend()
    }

    func testLateDisappearanceCannotSuspendReopenedConversation() {
        let session = WorkDeskConversationSession(conversationID: UUID())
        let old = session.resume()
        session.suspend()
        let current = session.resume()
        session.suspend(ifCurrent: old)
        XCTAssertTrue(session.isCurrentPresentation(current))
        session.suspend(ifCurrent: current)
        XCTAssertFalse(session.isCurrentPresentation(current))
    }

    func testExistingConversationRefusesNewChatAndCrossConversationDispatches() {
        let id = UUID()
        let session = WorkDeskConversationSession(conversationID: id)
        let token = session.resume()
        for sealedID in [nil, UUID()] as [UUID?] {
            XCTAssertFalse(session.accepts(dispatch(conversationID: sealedID), conversation: record(id: id),
                                           viewModelID: id, presentation: token))
        }
        XCTAssertFalse(session.accepts(dispatch(conversationID: id), conversation: record(id: id),
                                       viewModelID: UUID(), presentation: token))
        XCTAssertFalse(session.accepts(dispatch(conversationID: id), conversation: record(id: UUID()),
                                       viewModelID: id, presentation: token))
        session.suspend()
    }

    func testChangedOrUnknownGatewayCannotRerouteSealedAttachments() {
        let id = UUID()
        let session = WorkDeskConversationSession(conversationID: id)
        let token = session.resume()
        for backend in ["hermes", "custom_\(UUID().uuidString)", "invalid-gateway"] {
            XCTAssertFalse(session.accepts(dispatch(conversationID: id), conversation: record(id: id, backend: backend),
                                           viewModelID: id, presentation: token))
        }
        session.suspend()
    }

    #if os(iOS)
    func testSuspensionDefersAttachmentCleanupUntilDispatchHasSettled() {
        let session = WorkDeskConversationSession(conversationID: UUID())
        session.resume()
        session.draft = "Typed words survive"
        session.attachments.staged = [StagedAttachment(kind: .image(Data([1, 2, 3])))]
        XCTAssertTrue(session.attachments.beginAttachmentDispatch())
        session.suspend()
        XCTAssertEqual(session.attachments.staged.count, 1, "Dispatch gets the first chance to hand off sealed items")
        session.attachments.endAttachmentDispatch()
        XCTAssertTrue(session.attachments.staged.isEmpty)
        XCTAssertEqual(session.draft, "Typed words survive")
    }
    #endif

    private func record(id: UUID, backend: String = "openclaw") -> ConversationRecord {
        ConversationRecord(id: id, title: "Draft ideas", createdAt: Date(), lastActivityAt: Date(),
                           sessionID: "test-session", backend: backend, titleSnippet: nil)
    }

    private func dispatch(conversationID: UUID?) -> ComposerTurnDispatch {
        ComposerTurnDispatch(text: "Keep these words", attachments: [], ref: .builtin(.openclaw),
                             fileLaneID: nil, handedOffServerAttachmentIDs: [],
                             conversationID: conversationID, pendingConversationID: UUID(),
                             stagingGeneration: UUID(), stagedAttachmentIDs: [])
    }
}
