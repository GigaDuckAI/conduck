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
        let agent = try await store.appendMessage(
            role: "agent",
            text: "reply",
            conversationID: convo.id,
            sourceDevice: "watch",
            attachments: attachments
        )
        return (store, agent.id)
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

    func testInsertsOnlyMissingStoredKeys() async throws {
        let (store, agentID) = try await seed(existingKeys: ["a.pdf"])

        let inserted = try await store.reconcileOutputScan([
            (messageID: agentID, drafts: [serverRef("a.pdf"), serverRef("b.pdf")], markScanned: false)
        ])

        XCTAssertTrue(inserted, "a genuinely-new storedKey was inserted")
        let keys = try await attachments(of: agentID, in: store).compactMap(\.storedKey).sorted()
        XCTAssertEqual(keys, ["a.pdf", "b.pdf"], "the already-present a.pdf is not duplicated")
    }

    func testSequenceContinuesAfterExistingMax() async throws {
        let (store, agentID) = try await seed(existingKeys: ["a.pdf"])   // a.pdf at sequence 0

        _ = try await store.reconcileOutputScan([
            (messageID: agentID, drafts: [serverRef("b.pdf")], markScanned: false)
        ])

        let atts = try await attachments(of: agentID, in: store)
        let b = atts.first { $0.storedKey == "b.pdf" }
        XCTAssertEqual(b?.sequence, 1, "the new attachment's sequence continues after the existing max (0)")
    }

    // MARK: - markScanned

    func testMarkerSetWhenMarkScanned() async throws {
        let (store, agentID) = try await seed(existingKeys: [])

        _ = try await store.reconcileOutputScan([
            (messageID: agentID, drafts: [serverRef("out.pdf")], markScanned: true)
        ])

        let m = try await message(agentID, in: store)
        XCTAssertEqual(m?.outputScanDone, true, "a conclusive pass stamps outputScanDone")
    }

    func testMarkerNotSetWhenNotMarkScanned() async throws {
        let (store, agentID) = try await seed(existingKeys: [])

        _ = try await store.reconcileOutputScan([
            (messageID: agentID, drafts: [serverRef("out.pdf")], markScanned: false)
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
            (messageID: agentID, drafts: [], markScanned: true)
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
            (messageID: agentID, drafts: [serverRef("out.pdf")], markScanned: true)
        ])
        XCTAssertTrue(first, "first insert lands")

        let second = try await store.reconcileOutputScan([
            (messageID: agentID, drafts: [serverRef("out.pdf")], markScanned: true)
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
