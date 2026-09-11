// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// ConversationStoreReferencedStoredKeysTests.swift
//
// `referencedStoredKeys` is the only "do not delete this" authority both upload
// reclaim paths consult before issuing an irreversible DELETE against the user's
// own file server. Its answer is a string set, so a write-side change that
// altered the persisted `Attachment.storedKey` spelling would silently return
// nothing and license erasing the attachments of a successfully sent message.
// These tests pin the round trip: what the journal registers is exactly what the
// durable conversation reports back as owned.

import XCTest
@testable import Conduck

final class ConversationStoreReferencedStoredKeysTests: XCTestCase {

    private func serverReference(storedKey: String, sequence: Int = 0) -> AttachmentDraft {
        var draft = AttachmentDraft(
            mimeType: "application/pdf",
            filename: "brief.pdf",
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

    func testPersistedStoredKeyIsReportedAndUnrelatedKeysAreNot() async throws {
        let store = ConversationStore(inMemory: true)
        let conversation = try await store.createConversation(backend: "openclaw")
        let ownedKey = "abc123__brief.pdf"
        let unrelatedKey = "zzz999__somebody-elses.pdf"

        _ = try await store.appendMessage(
            role: "user",
            text: "with an uploaded file",
            conversationID: conversation.id,
            sourceDevice: "phone",
            attachments: [serverReference(storedKey: ownedKey)]
        )

        let referenced = try await store.referencedStoredKeys([ownedKey, unrelatedKey])
        XCTAssertEqual(referenced, [ownedKey],
                       "a key the durable conversation owns must never be reclaimable")
    }

    func testUnreferencedAndEmptyCandidateSetsReportNothing() async throws {
        let store = ConversationStore(inMemory: true)
        let conversation = try await store.createConversation(backend: "openclaw")
        _ = try await store.appendMessage(
            role: "user",
            text: "plain turn, no upload",
            conversationID: conversation.id,
            sourceDevice: "phone"
        )

        let unreferenced = try await store.referencedStoredKeys(["orphan__file.pdf"])
        XCTAssertTrue(unreferenced.isEmpty)
        let empty = try await store.referencedStoredKeys([])
        XCTAssertTrue(empty.isEmpty)
    }

    func testEveryKeyOfAMultiUploadTurnIsReported() async throws {
        let store = ConversationStore(inMemory: true)
        let conversation = try await store.createConversation(backend: "openclaw")
        let first = "aaa111__one.pdf"
        let second = "bbb222__two.pdf"

        _ = try await store.appendMessage(
            role: "user",
            text: "two uploaded files",
            conversationID: conversation.id,
            sourceDevice: "phone",
            attachments: [
                serverReference(storedKey: first, sequence: 0),
                serverReference(storedKey: second, sequence: 1),
            ]
        )

        let referenced = try await store.referencedStoredKeys([first, second, "ccc333__three.pdf"])
        XCTAssertEqual(referenced, [first, second])
    }
}
