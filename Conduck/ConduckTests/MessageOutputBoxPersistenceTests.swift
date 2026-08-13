// SPDX-License-Identifier: Apache-2.0

// Conduck
// MessageOutputBoxPersistenceTests.swift
//
// Locks the persistence half of "a reply remembers the box it was told to write
// into": `Message.outputBoxKey` (v8 model) and its `MessageRecord` mirror. Pins:
//   • both write paths (`appendMessage`, `completeAgentTurn`) store the folder
//     in the SAME save as `outputScanLaneID` — a re-fetched row carries both or
//     neither, never one;
//   • the in-memory `MessageRecord` a write returns agrees with the row it just
//     wrote, so a caller never renders one truth and persists another;
//   • a laneless write stores no folder — folder-without-lane cannot exist;
//   • an absent value decodes as nil (UNKNOWN), which is what keeps a legacy or
//     not-yet-synced row out of the automatic pass instead of closing it.
//
// Each test builds its OWN isolated `inMemory` store (CloudKit OFF in the seam).
// Deterministic + headless; synthetic keys only.

import XCTest
import CoreData
@testable import Conduck

final class MessageOutputBoxPersistenceTests: XCTestCase {

    private let laneID = String(repeating: "a", count: 64)

    private func makeStore() -> ConversationStore {
        ConversationStore(inMemory: true)
    }

    private func outboxKey(_ conversationID: UUID) -> String {
        "\(conversationID.uuidString)/out-0123456789abcdef"
    }

    // MARK: - appendMessage

    func testAppendMessageStoresOutputBoxKeyBesideTheLane() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let box = outboxKey(convo.id)

        let returned = try await store.appendMessage(
            role: "agent",
            text: "done",
            conversationID: convo.id,
            sourceDevice: "watch",
            outputScanLaneID: laneID,
            outputBoxKey: box
        )

        XCTAssertEqual(returned.outputBoxKey, box, "the returned record mirrors the row it wrote")
        XCTAssertEqual(returned.outputScanLaneID, laneID)
        XCTAssertEqual(returned.outputScanDone, false)

        let refetched = try await store.fetchMessages(for: convo.id)
        let agent = try XCTUnwrap(refetched.first { $0.id == returned.id })
        XCTAssertEqual(agent.outputBoxKey, box, "the folder survives the round trip through Core Data")
        XCTAssertEqual(agent.outputScanLaneID, laneID, "lane and folder land in the same save")
        XCTAssertEqual(agent.outputScanDone, false)
    }

    func testAppendMessageWithoutALaneStoresNoOutputBoxKey() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")

        // A folder with no owning lane could never be listed against a proven
        // server, so the pair is written or neither is.
        let returned = try await store.appendMessage(
            role: "agent",
            text: "done",
            conversationID: convo.id,
            sourceDevice: "watch",
            outputScanLaneID: nil,
            outputBoxKey: outboxKey(convo.id)
        )

        XCTAssertNil(returned.outputBoxKey, "no lane means no folder, in the returned record")
        XCTAssertNil(returned.outputScanLaneID)

        let refetched = try await store.fetchMessages(for: convo.id)
        let agent = try XCTUnwrap(refetched.first { $0.id == returned.id })
        XCTAssertNil(agent.outputBoxKey, "no lane means no folder, in the store")
        XCTAssertNil(agent.outputScanDone)
    }

    func testAppendMessageOmittingTheFolderLeavesItNil() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")

        let returned = try await store.appendMessage(
            role: "agent",
            text: "done",
            conversationID: convo.id,
            sourceDevice: "watch",
            outputScanLaneID: laneID
        )

        // The Watch's shape: a lane it was couriered, no folder it could mint.
        XCTAssertNil(returned.outputBoxKey)
        XCTAssertEqual(returned.outputScanLaneID, laneID)

        let refetched = try await store.fetchMessages(for: convo.id)
        let agent = try XCTUnwrap(refetched.first { $0.id == returned.id })
        XCTAssertNil(agent.outputBoxKey, "nil is UNKNOWN — a lane can land without a folder")
        XCTAssertEqual(agent.outputScanLaneID, laneID)
    }

    // MARK: - completeAgentTurn

    func testCompleteAgentTurnStoresOutputBoxKeyBesideTheLane() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let box = outboxKey(convo.id)

        let user = try await store.appendMessage(
            role: "user",
            text: "make me a file",
            conversationID: convo.id,
            sourceDevice: "mac",
            status: "sending"
        )
        let returned = try await store.completeAgentTurn(
            userMessageID: user.id,
            userStatus: "sent",
            agentText: "done",
            conversationID: convo.id,
            sourceDevice: "mac",
            outputScanLaneID: laneID,
            outputBoxKey: box
        )

        XCTAssertEqual(returned.outputBoxKey, box, "the returned record mirrors the row it wrote")

        let refetched = try await store.fetchMessages(for: convo.id)
        let agent = try XCTUnwrap(refetched.first { $0.id == returned.id })
        XCTAssertEqual(agent.outputBoxKey, box)
        XCTAssertEqual(agent.outputScanLaneID, laneID, "lane and folder land in the same save")
        XCTAssertEqual(agent.outputScanDone, false)

        // The paired user flip rode the SAME save — proving the folder did not
        // arrive on a separate transaction.
        let userRow = try XCTUnwrap(refetched.first { $0.id == user.id })
        XCTAssertEqual(userRow.status, "sent")
    }

    func testCompleteAgentTurnWithoutALaneStoresNoOutputBoxKey() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")

        let user = try await store.appendMessage(
            role: "user",
            text: "make me a file",
            conversationID: convo.id,
            sourceDevice: "mac",
            status: "sending"
        )
        let returned = try await store.completeAgentTurn(
            userMessageID: user.id,
            userStatus: "sent",
            agentText: "done",
            conversationID: convo.id,
            sourceDevice: "mac",
            outputScanLaneID: nil,
            outputBoxKey: outboxKey(convo.id)
        )

        XCTAssertNil(returned.outputBoxKey)

        let refetched = try await store.fetchMessages(for: convo.id)
        let agent = try XCTUnwrap(refetched.first { $0.id == returned.id })
        XCTAssertNil(agent.outputBoxKey, "folder-without-lane is impossible for a newly-written row")
    }

    // MARK: - MessageRecord decode

    func testMessageRecordDefaultsTheFolderToNil() {
        // The memberwise default is what keeps every pre-v8 construction site
        // compiling AND reading as UNKNOWN rather than as "produced nothing".
        let record = MessageRecord(
            id: UUID(),
            role: "agent",
            text: "done",
            createdAt: Date(),
            sourceDevice: "phone"
        )
        XCTAssertNil(record.outputBoxKey)
    }

    func testMessageRecordDecodesAnUnsetFolderAsNilWithoutCrashing() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        // A row written with the lane but never given a folder is exactly the
        // shape a CloudKit row takes before the attribute syncs.
        let written = try await store.appendMessage(
            role: "agent",
            text: "legacy shape",
            conversationID: convo.id,
            sourceDevice: "watch",
            outputScanLaneID: laneID
        )

        let refetched = try await store.fetchMessages(for: convo.id)
        let agent = try XCTUnwrap(refetched.first { $0.id == written.id })
        XCTAssertNil(agent.outputBoxKey)
        XCTAssertEqual(agent.outputScanDone, false, "UNKNOWN folder does not imply a closed scan")
    }
}
