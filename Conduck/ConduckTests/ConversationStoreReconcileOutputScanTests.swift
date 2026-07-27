// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationStoreReconcileOutputScanTests.swift
//
// Locks `ConversationStore.reconcileOutputScan(_:)` — the single-save
// reconcile the retroactive output scan drives. Pins:
//   • per-storedKey dedupe: only drafts whose storedKey is NOT already attached
//     on the message insert (a prior partial success never double-inserts);
//   • sequence allocation continues AFTER the message's current max attachment
//     sequence;
//   • `outputScanDone` set only when `markScanned` — and a marker-only entry
//     (conclusive pass, no new file) inserts nothing and returns false;
//   • idempotence: replaying the same drafts is a no-op.
//
// Each test builds its OWN isolated `inMemory` store (CloudKit OFF in the seam)
// — no `.shared` singleton, no App Group
// sqlite. Deterministic + headless; synthetic keys only.

import XCTest
@testable import Conduck

final class ConversationStoreReconcileOutputScanTests: XCTestCase {

    private let reconciliationLaneID = String(repeating: "w", count: 64)

    private func makeStore() -> ConversationStore {
        ConversationStore(inMemory: true)
    }

    private func serverRef(_ storedKey: String, sequence: Int = 0) -> AttachmentDraft {
        var draft = AttachmentDraft(
            mimeType: "application/pdf",
            filename: storedKey,
            data: Data(),
            thumbnailData: nil,
            width: 0,
            height: 0,
            byteSize: 0,
            sequence: sequence
        )
        draft.isServerReference = true
        draft.storedKey = storedKey
        return draft
    }

    /// Seed a conversation with one agent turn carrying `existingKeys` as
    /// server-ref attachments; returns (store, agent message id).
    private func seed(existingKeys: [String]) async throws -> (ConversationStore, UUID) {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let attachments = existingKeys.enumerated().map { serverRef($1, sequence: $0) }
        let user = try await store.appendMessage(
            role: "user",
            text: "create output",
            conversationID: convo.id,
            sourceDevice: "watch",
            status: "sending"
        )
        let agent = try await store.completeAgentTurn(
            userMessageID: user.id,
            userStatus: "sent",
            agentText: "reply",
            conversationID: convo.id,
            sourceDevice: "watch",
            outputScanLaneID: reconciliationLaneID,
            attachments: attachments
        )
        return (store, agent.id)
    }

    private func seedMacCompletion(
        outputScanLaneID: String?
    ) async throws -> (
        store: ConversationStore,
        conversationID: UUID,
        userID: UUID,
        agentID: UUID,
        returnedAgent: MessageRecord
    ) {
        let store = makeStore()
        let conversation = try await store.createConversation(backend: "openclaw")
        let user = try await store.appendMessage(
            role: "user",
            text: "create output.pdf",
            conversationID: conversation.id,
            sourceDevice: "mac",
            status: "sending"
        )
        let agentID = UUID()
        let agent = try await store.completeAgentTurn(
            userMessageID: user.id,
            userStatus: "sent",
            agentText: "Done: output.pdf",
            conversationID: conversation.id,
            sourceDevice: "mac",
            agentMessageID: agentID,
            outputScanLaneID: outputScanLaneID
        )
        return (store, conversation.id, user.id, agent.id, agent)
    }

    private func attachments(of messageID: UUID, in store: ConversationStore) async throws -> [AttachmentRecord] {
        let messages = try await store.fetchMessages(for: findConversation(store))
        return messages.first { $0.id == messageID }?.attachments ?? []
    }

    private func message(_ messageID: UUID, in store: ConversationStore) async throws -> MessageRecord? {
        let messages = try await store.fetchMessages(for: findConversation(store))
        return messages.first { $0.id == messageID }
    }

    private func findConversation(_ store: ConversationStore) async throws -> UUID {
        try await store.fetchConversations().first!.id
    }

    // MARK: - dedupe + insert

    func testReadyMacCompletionAtomicallyPersistsPendingFalseWithSentFlip() async throws {
        let laneID = String(repeating: "a", count: 64)
        let seeded = try await seedMacCompletion(outputScanLaneID: laneID)

        XCTAssertEqual(seeded.returnedAgent.outputScanDone, false)
        XCTAssertEqual(seeded.returnedAgent.outputScanLaneID, laneID)
        let messages = try await seeded.store.fetchMessages(for: seeded.conversationID)
        XCTAssertEqual(messages.first { $0.id == seeded.userID }?.status, "sent")
        XCTAssertEqual(messages.first { $0.id == seeded.agentID }?.outputScanDone, false,
                       "the pending marker must share the reply + sent-flip save")
        XCTAssertEqual(messages.first { $0.id == seeded.agentID }?.outputScanLaneID, laneID,
                       "the dispatch lane identity must share that atomic save")
        XCTAssertEqual(seeded.returnedAgent.id, seeded.agentID,
                       "the caller-generated ID is the persisted agent turn ID")
    }

    func testNoLaneMacCompletionLeavesOutputScanMarkerNil() async throws {
        let seeded = try await seedMacCompletion(outputScanLaneID: nil)

        XCTAssertNil(seeded.returnedAgent.outputScanDone)
        XCTAssertNil(seeded.returnedAgent.outputScanLaneID)
        let messages = try await seeded.store.fetchMessages(for: seeded.conversationID)
        XCTAssertNil(messages.first { $0.id == seeded.agentID }?.outputScanDone,
                     "a no-lane dispatch must not create speculative recovery work")
        XCTAssertNil(messages.first { $0.id == seeded.agentID }?.outputScanLaneID)
    }

    func testAppendMessagePersistsInputFileTransferLaneID() async throws {
        let laneID = String(repeating: "i", count: 64)
        let store = makeStore()
        let conversation = try await store.createConversation(backend: "openclaw")

        let returned = try await store.appendMessage(
            role: "user",
            text: "read report.pdf",
            conversationID: conversation.id,
            sourceDevice: "mac",
            fileTransferLaneID: laneID,
            attachments: [serverRef("report.pdf")]
        )

        XCTAssertEqual(returned.fileTransferLaneID, laneID)
        let persisted = try await store.fetchMessages(for: conversation.id)
            .first { $0.id == returned.id }
        XCTAssertEqual(persisted?.fileTransferLaneID, laneID,
                       "server-backed input ownership must survive the durable store round trip")
    }

    func testPendingMacRecoveryUsesConclusiveReconcileAndDedupes() async throws {
        let laneID = String(repeating: "a", count: 64)
        let seeded = try await seedMacCompletion(outputScanLaneID: laneID)
        let duplicateDrafts = [serverRef("output.pdf"), serverRef("output.pdf")]

        let first = try await seeded.store.reconcileOutputScan([
            .init(
                messageID: seeded.agentID,
                drafts: duplicateDrafts,
                markScanned: true,
                expectedLaneID: laneID
            )
        ])
        let replay = try await seeded.store.reconcileOutputScan([
            .init(
                messageID: seeded.agentID,
                drafts: duplicateDrafts,
                markScanned: true,
                expectedLaneID: laneID
            )
        ])

        XCTAssertTrue(first)
        XCTAssertFalse(replay)
        let recovered = try await message(seeded.agentID, in: seeded.store)
        XCTAssertEqual(recovered?.outputScanDone, true,
                       "a conclusive immediate/recovery pass clears pending")
        XCTAssertEqual(recovered?.outputScanLaneID, laneID,
                       "completion preserves the durable lane identity")
        XCTAssertEqual(recovered?.attachments.compactMap(\.storedKey), ["output.pdf"],
                       "shared reconciliation inserts one chip across duplicate/replayed results")
    }

    func testMismatchedLaneCannotAttachOrMarkMacReply() async throws {
        let persistedLaneID = String(repeating: "a", count: 64)
        let wrongLaneID = String(repeating: "b", count: 64)
        let seeded = try await seedMacCompletion(outputScanLaneID: persistedLaneID)

        let inserted = try await seeded.store.reconcileOutputScan([
            .init(
                messageID: seeded.agentID,
                drafts: [serverRef("wrong-server.pdf")],
                markScanned: true,
                expectedLaneID: wrongLaneID
            )
        ])

        XCTAssertFalse(inserted)
        let recovered = try await message(seeded.agentID, in: seeded.store)
        XCTAssertEqual(recovered?.outputScanDone, false,
                       "a lane mismatch must leave the original recovery pending")
        XCTAssertTrue(recovered?.attachments.isEmpty ?? false,
                      "a result from another lane must not attach")
    }

    func testLegacyWatchOutputWithConfirmedDraftClaimsCurrentLane() async throws {
        let currentLaneID = String(repeating: "w", count: 64)
        let (store, agentID) = try await seed(existingKeys: [])

        let inserted = try await store.reconcileOutputScan([
            .init(
                messageID: agentID,
                drafts: [serverRef("watch-output.pdf")],
                markScanned: true,
                expectedLaneID: currentLaneID
            )
        ])

        XCTAssertTrue(inserted)
        let recovered = try await message(agentID, in: store)
        XCTAssertEqual(recovered?.outputScanLaneID, currentLaneID,
                       "a newly discovered legacy Watch output must pin its chip to the probed lane")
        XCTAssertEqual(recovered?.outputScanDone, true)
        XCTAssertEqual(recovered?.attachments.compactMap(\.storedKey), ["watch-output.pdf"])
    }

    func testLegacyMarkerOnlyScanDoesNotClaimCurrentLane() async throws {
        let currentLaneID = String(repeating: "w", count: 64)
        let (store, agentID) = try await seed(existingKeys: [])

        let inserted = try await store.reconcileOutputScan([
            .init(
                messageID: agentID,
                drafts: [],
                markScanned: true,
                expectedLaneID: currentLaneID
            )
        ])

        XCTAssertFalse(inserted)
        let recovered = try await message(agentID, in: store)
        XCTAssertEqual(recovered?.outputScanLaneID, currentLaneID,
                       "a marker-only pass preserves the dispatch-time lane")
        XCTAssertEqual(recovered?.outputScanDone, true)
    }

    func testLegacyLaneClaimCannotOverwriteExistingOwnership() async throws {
        let persistedLaneID = String(repeating: "a", count: 64)
        let wrongLaneID = String(repeating: "b", count: 64)
        let seeded = try await seedMacCompletion(outputScanLaneID: persistedLaneID)

        let inserted = try await seeded.store.reconcileOutputScan([
            .init(
                messageID: seeded.agentID,
                drafts: [serverRef("wrong-server.pdf")],
                markScanned: true,
                expectedLaneID: wrongLaneID
            )
        ])

        XCTAssertFalse(inserted)
        let recovered = try await message(seeded.agentID, in: seeded.store)
        XCTAssertEqual(recovered?.outputScanLaneID, persistedLaneID)
        XCTAssertEqual(recovered?.outputScanDone, false,
                       "a conflicting legacy claim must not mark the original lane complete")
        XCTAssertTrue(recovered?.attachments.isEmpty ?? false)
    }

    func testInsertsOnlyMissingStoredKeys() async throws {
        let (store, agentID) = try await seed(existingKeys: ["a.pdf"])

        let inserted = try await store.reconcileOutputScan([
            .init(
                messageID: agentID,
                drafts: [serverRef("a.pdf"), serverRef("b.pdf")],
                markScanned: false,
                expectedLaneID: reconciliationLaneID
            )
        ])

        XCTAssertTrue(inserted, "a genuinely-new storedKey was inserted")
        let keys = try await attachments(of: agentID, in: store).compactMap(\.storedKey).sorted()
        XCTAssertEqual(keys, ["a.pdf", "b.pdf"], "the already-present a.pdf is not duplicated")
    }

    func testSequenceContinuesAfterExistingMax() async throws {
        let (store, agentID) = try await seed(existingKeys: ["a.pdf"])   // a.pdf at sequence 0

        _ = try await store.reconcileOutputScan([
            .init(
                messageID: agentID,
                drafts: [serverRef("b.pdf")],
                markScanned: false,
                expectedLaneID: reconciliationLaneID
            )
        ])

        let atts = try await attachments(of: agentID, in: store)
        let b = atts.first { $0.storedKey == "b.pdf" }
        XCTAssertEqual(b?.sequence, 1, "the new attachment's sequence continues after the existing max (0)")
    }

    // MARK: - markScanned

    func testMarkerSetWhenMarkScanned() async throws {
        let (store, agentID) = try await seed(existingKeys: [])

        _ = try await store.reconcileOutputScan([
            .init(
                messageID: agentID,
                drafts: [serverRef("out.pdf")],
                markScanned: true,
                expectedLaneID: reconciliationLaneID
            )
        ])

        let m = try await message(agentID, in: store)
        XCTAssertEqual(m?.outputScanDone, true, "a conclusive pass stamps outputScanDone")
    }

    func testMarkerNotSetWhenNotMarkScanned() async throws {
        let (store, agentID) = try await seed(existingKeys: [])

        _ = try await store.reconcileOutputScan([
            .init(
                messageID: agentID,
                drafts: [serverRef("out.pdf")],
                markScanned: false,
                expectedLaneID: reconciliationLaneID
            )
        ])

        let m = try await message(agentID, in: store)
        XCTAssertNotEqual(m?.outputScanDone, true,
                          "an inconclusive pass leaves the turn unmarked so a later open retries")
    }

    /// A marker-only entry (conclusive pass that found no NEW file) stamps the
    /// marker but inserts nothing — and must report `false` so the caller never
    /// posts a reload echo.
    func testMarkerOnlyEntryInsertsNothing() async throws {
        let (store, agentID) = try await seed(existingKeys: [])

        let inserted = try await store.reconcileOutputScan([
            .init(
                messageID: agentID,
                drafts: [],
                markScanned: true,
                expectedLaneID: reconciliationLaneID
            )
        ])

        XCTAssertFalse(inserted, "no attachment inserted → returns false (no reload echo)")
        let m = try await message(agentID, in: store)
        XCTAssertEqual(m?.outputScanDone, true, "the marker still persists")
        XCTAssertTrue(m?.attachments.isEmpty ?? false, "no chip was added")
    }

    // MARK: - idempotence

    func testReplayingSameDraftsIsNoOp() async throws {
        let (store, agentID) = try await seed(existingKeys: [])

        let first = try await store.reconcileOutputScan([
            .init(
                messageID: agentID,
                drafts: [serverRef("out.pdf")],
                markScanned: true,
                expectedLaneID: reconciliationLaneID
            )
        ])
        XCTAssertTrue(first, "first insert lands")

        let second = try await store.reconcileOutputScan([
            .init(
                messageID: agentID,
                drafts: [serverRef("out.pdf")],
                markScanned: true,
                expectedLaneID: reconciliationLaneID
            )
        ])
        XCTAssertFalse(second, "replaying the same storedKey inserts nothing")

        let keys = try await attachments(of: agentID, in: store).compactMap(\.storedKey)
        XCTAssertEqual(keys, ["out.pdf"], "still exactly one chip after the replay")
    }

    func testEmptyResultsReturnsFalse() async throws {
        let store = makeStore()
        let inserted = try await store.reconcileOutputScan([])
        XCTAssertFalse(inserted, "an empty pass is a no-op")
    }
}
