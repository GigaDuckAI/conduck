// Conduck
// ConversationStorePreviewTests.swift
//
// Locks the model-v6 server-reference PREVIEW store primitives:
//   • `applyPreviews(_:)` — patches the matching (messageID, storedKey) row's
//     nil preview fields, FIRST-WRITER-WINS per field (never clobbers an
//     existing previewData / thumbnailData), and returns false / posts nothing
//     when no row matched;
//   • `fetchPreviewText(messageID:attachmentID:)` — lazy UTF-8 fault of the one
//     row's previewData, nil on a non-text (invalid-UTF-8) blob.
//
// Each test builds its OWN isolated `inMemory` store (CloudKit OFF in the seam).
// Deterministic + headless; synthetic keys
// and content only (nothing logged).

import XCTest
@testable import Conduck

final class ConversationStorePreviewTests: XCTestCase {

    private func makeStore() -> ConversationStore {
        ConversationStore(inMemory: true)
    }

    private func serverRef(_ storedKey: String, sequence: Int = 0) -> AttachmentDraft {
        var draft = AttachmentDraft(
            mimeType: "application/json",
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

    /// Seed a conversation with one agent turn carrying `keys` as server-ref
    /// attachments; returns (store, agent message id).
    private func seed(keys: [String]) async throws -> (ConversationStore, UUID) {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let attachments = keys.enumerated().map { serverRef($1, sequence: $0) }
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
        let cid = try await store.fetchConversations().first!.id
        let messages = try await store.fetchMessages(for: cid)
        return messages.first { $0.id == messageID }?.attachments ?? []
    }

    // MARK: - applyPreviews

    func testApplyPreviewsPatchesMatchingRow() async throws {
        let (store, agentID) = try await seed(keys: ["a.json", "b.json"])

        let wrote = try await store.applyPreviews([
            (messageID: agentID, storedKey: "b.json",
             previewData: Data("{\"ok\":true}".utf8), previewKind: "text", thumbnailData: nil)
        ])
        XCTAssertTrue(wrote, "a nil field on the matching row was written")

        let atts = try await attachments(of: agentID, in: store)
        let a = atts.first { $0.storedKey == "a.json" }
        let b = atts.first { $0.storedKey == "b.json" }
        XCTAssertNil(a?.previewKind, "the non-matching row is untouched")
        XCTAssertEqual(b?.previewKind, "text", "previewKind flows to the snapshot for the matched row")
        XCTAssertTrue(b?.hasTextPreview ?? false)
    }

    func testApplyPreviewsDoesNotClobberExistingPreviewData() async throws {
        let (store, agentID) = try await seed(keys: ["a.json"])

        let first = try await store.applyPreviews([
            (messageID: agentID, storedKey: "a.json",
             previewData: Data("FIRST".utf8), previewKind: "text", thumbnailData: nil)
        ])
        XCTAssertTrue(first)

        // A second, concurrent-style enrich must NOT overwrite the existing blob.
        let second = try await store.applyPreviews([
            (messageID: agentID, storedKey: "a.json",
             previewData: Data("SECOND".utf8), previewKind: "text", thumbnailData: nil)
        ])
        XCTAssertFalse(second, "every field already set → nothing written → returns false")

        let att = try await attachments(of: agentID, in: store).first { $0.storedKey == "a.json" }
        let id = try XCTUnwrap(att?.id)
        let text = await store.fetchPreviewText(messageID: agentID, attachmentID: id)
        XCTAssertEqual(text, "FIRST", "first-writer-wins: the original preview survives")
    }

    func testApplyPreviewsDoesNotClobberExistingThumbnail() async throws {
        let (store, agentID) = try await seed(keys: ["img.bin"])

        let first = try await store.applyPreviews([
            (messageID: agentID, storedKey: "img.bin",
             previewData: nil, previewKind: nil, thumbnailData: Data([0x01, 0x02]))
        ])
        XCTAssertTrue(first)

        let second = try await store.applyPreviews([
            (messageID: agentID, storedKey: "img.bin",
             previewData: nil, previewKind: nil, thumbnailData: Data([0x09, 0x09]))
        ])
        XCTAssertFalse(second, "thumbnail already present → not overwritten")

        let att = try await attachments(of: agentID, in: store).first { $0.storedKey == "img.bin" }
        XCTAssertEqual(att?.thumbnailData, Data([0x01, 0x02]), "the original thumbnail survives")
    }

    func testApplyPreviewsReturnsFalseWhenNothingMatched() async throws {
        let (store, agentID) = try await seed(keys: ["a.json"])

        let wrote = try await store.applyPreviews([
            (messageID: agentID, storedKey: "does-not-exist.json",
             previewData: Data("x".utf8), previewKind: "text", thumbnailData: nil)
        ])
        XCTAssertFalse(wrote, "no server-ref row with that storedKey → false (no reload echo)")
    }

    func testApplyPreviewsEmptyIsNoOp() async throws {
        let store = makeStore()
        let wrote = try await store.applyPreviews([])
        XCTAssertFalse(wrote, "an empty patch set is a no-op")
    }

    // MARK: - fetchPreviewText

    func testFetchPreviewTextRoundTripsUTF8() async throws {
        let (store, agentID) = try await seed(keys: ["a.json"])
        let payload = "héllo, wrist — 日本語"
        _ = try await store.applyPreviews([
            (messageID: agentID, storedKey: "a.json",
             previewData: Data(payload.utf8), previewKind: "text", thumbnailData: nil)
        ])

        let att = try await attachments(of: agentID, in: store).first { $0.storedKey == "a.json" }
        let id = try XCTUnwrap(att?.id)
        let text = await store.fetchPreviewText(messageID: agentID, attachmentID: id)
        XCTAssertEqual(text, payload, "the UTF-8 preview round-trips exactly")
    }

    func testFetchPreviewTextReturnsNilForNonTextBlob() async throws {
        let (store, agentID) = try await seed(keys: ["a.json"])
        // 0xFF / 0xFE are never valid UTF-8 lead bytes → strict decode fails.
        _ = try await store.applyPreviews([
            (messageID: agentID, storedKey: "a.json",
             previewData: Data([0xFF, 0xFE, 0xFF]), previewKind: "text", thumbnailData: nil)
        ])

        let att = try await attachments(of: agentID, in: store).first { $0.storedKey == "a.json" }
        let id = try XCTUnwrap(att?.id)
        let text = await store.fetchPreviewText(messageID: agentID, attachmentID: id)
        XCTAssertNil(text, "a non-UTF-8 blob decodes to nil, not garbage")
    }

    func testFetchPreviewTextReturnsNilForMissingRow() async throws {
        let (store, agentID) = try await seed(keys: ["a.json"])
        let text = await store.fetchPreviewText(messageID: agentID, attachmentID: UUID())
        XCTAssertNil(text, "an unknown attachment id yields nil")
    }
}
