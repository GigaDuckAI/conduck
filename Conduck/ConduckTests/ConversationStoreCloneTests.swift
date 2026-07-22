// Conduck
// ConversationStoreCloneTests.swift
//
// Locks the `ConversationStore.cloneConversation(id:toBackend:)` contract —
// the ONLY sanctioned gateway-switch path (a thread's backend binding locks
// after its first turn, so switching gateways is a CLEAN CUT into a NEW thread,
// never a rebind). Previously had ZERO tests despite being the recovery action
// behind "Clone & continue on <gateway>".
//
// The copy contract verified here (read from the method body, June 2026):
//   - mints a NEW conversation id (≠ source id)
//   - copies the source's TEXT turns in createdAt-ascending order, preserving
//     role / text / sourceDevice (fresh per-clone message ids)
//   - carries the source titleSnippet
//   - binds the clone to the target backend (rawString verbatim), title stays nil
//   - normalizes every cloned turn's status to nil (NEVER `sending` — clones are
//     historical, no in-flight)
//   - V1 TEXT-ONLY: attachments are NOT copied
//   - leaves the ORIGINAL conversation + its turns untouched
//
// Also locks `conversationID(forMessageID:)` (owning-conversation resolver behind
// the Share-Extension notification-tap navigation): known message → owning id;
// unknown id → nil.
//
// Uses the in-memory testability seam (`ConversationStore(inMemory: true)`) — the
// App Group sqlite is never touched, CloudKit is off in that seam. No network, no
// Keychain. Mirrors `ConversationStoreTests.swift` setup.

import XCTest
import CoreData
@testable import Conduck

final class ConversationStoreCloneTests: XCTestCase {

    /// Fresh isolated in-memory store per test.
    private func makeStore() -> ConversationStore {
        ConversationStore(inMemory: true)
    }

    // MARK: - cloneConversation

    func testCloneCopiesTextHistoryRebindsBackendDropsAttachmentsAndLeavesOriginalIntact() async throws {
        let store = makeStore()

        // Seed a conversation bound to backend A ("openclaw") with:
        //   - a user turn (carrying an image attachment + "sending" status)
        //   - an agent turn
        // The first user turn also captures the titleSnippet.
        let source = try await store.createConversation(backend: "openclaw")

        let imageDraft = AttachmentDraft(
            mimeType: "image/jpeg",
            filename: nil,
            data: Data((0..<512).map { UInt8($0 % 256) }),
            thumbnailData: Data([0xAB, 0xCD]),
            width: 100,
            height: 80,
            byteSize: 512,
            sequence: 0
        )
        let userTurn = try await store.appendMessage(
            role: "user",
            text: "Plan my trip to Lisbon",
            conversationID: source.id,
            sourceDevice: "phone",
            status: "sending",
            attachments: [imageDraft]
        )
        try await Task.sleep(nanoseconds: 5_000_000) // keep agent turn strictly later
        let agentTurn = try await store.appendMessage(
            role: "agent",
            text: "Here is a plan for Lisbon.",
            conversationID: source.id,
            sourceDevice: "phone",
            status: nil
        )

        // Precondition: the source captured the snippet from its first user turn,
        // and its user turn really does carry the image attachment we'll prove the
        // clone drops.
        let sourceConvoFetch = try await store.fetchConversation(id: source.id)
        let sourceConvo = try XCTUnwrap(sourceConvoFetch)
        XCTAssertEqual(sourceConvo.titleSnippet, "Plan my trip to Lisbon",
                       "Precondition: source titleSnippet captured from the first user turn.")
        let sourceMessages = try await store.fetchMessages(for: source.id)
        XCTAssertEqual(sourceMessages.count, 2, "Precondition: source has exactly the two seeded turns.")
        XCTAssertEqual(sourceMessages.first(where: { $0.id == userTurn.id })?.attachments.count, 1,
                       "Precondition: the source user turn carries the image attachment.")

        // Clone onto backend B ("hermes").
        let clone = try await store.cloneConversation(id: source.id, toBackend: "hermes")

        // --- Clone identity + binding ---
        XCTAssertNotEqual(clone.id, source.id, "Clone must mint a NEW conversation id (clean cut, not a rebind).")
        XCTAssertEqual(clone.backend, "hermes", "Clone must be bound to the target backend rawString verbatim.")
        XCTAssertNil(clone.title, "Clone title stays nil (gateways never supply a real title).")
        XCTAssertEqual(clone.titleSnippet, "Plan my trip to Lisbon",
                       "Clone must carry the source's titleSnippet.")
        XCTAssertNotEqual(clone.sessionID, source.sessionID,
                          "Clone is a new thread → fresh local sessionID.")

        // --- Clone message history ---
        let clonedMessages = try await store.fetchMessages(for: clone.id)
        XCTAssertEqual(clonedMessages.count, 2, "Clone must carry both text turns.")
        // Text history is preserved IN ORDER (createdAt-ascending render order).
        XCTAssertEqual(clonedMessages.map(\.text),
                       ["Plan my trip to Lisbon", "Here is a plan for Lisbon."],
                       "Clone must carry the text history in original order.")
        XCTAssertEqual(clonedMessages.map(\.role), ["user", "agent"],
                       "Clone must preserve each turn's role in order.")
        XCTAssertEqual(clonedMessages.map(\.sourceDevice), ["phone", "phone"],
                       "Clone must preserve each turn's sourceDevice.")

        // Cloned turns are historical → NEVER `sending`; status normalized to nil.
        for message in clonedMessages {
            XCTAssertNil(message.status,
                         "Cloned turns are historical: status must be normalized to nil (never `sending`).")
        }

        // Cloned message ids are FRESH (not the source ids) — a clean-cut copy.
        let clonedIDs = Set(clonedMessages.map(\.id))
        XCTAssertFalse(clonedIDs.contains(userTurn.id),
                       "Cloned turns get fresh message ids, not the source ids.")
        XCTAssertFalse(clonedIDs.contains(agentTurn.id),
                       "Cloned turns get fresh message ids, not the source ids.")

        // V1 TEXT-ONLY: attachments are NOT copied into the clone.
        for message in clonedMessages {
            XCTAssertTrue(message.attachments.isEmpty,
                          "Clone is text-only — image/text attachments must NOT be copied.")
        }
        // And the underlying image bytes are not reachable on the cloned user turn.
        let clonedUserTurn = try XCTUnwrap(clonedMessages.first { $0.role == "user" })
        let clonedImageBytes = try await store.loadAttachmentData(for: clonedUserTurn.id)
        XCTAssertTrue(clonedImageBytes.isEmpty,
                      "No attachment bytes should be reachable on a cloned turn (text-only clone).")

        // --- ORIGINAL is untouched ---
        let originalAfterFetch = try await store.fetchConversation(id: source.id)
        let originalAfter = try XCTUnwrap(originalAfterFetch)
        XCTAssertEqual(originalAfter.backend, "openclaw",
                       "The original conversation's backend binding must be unchanged.")
        XCTAssertEqual(originalAfter.titleSnippet, "Plan my trip to Lisbon",
                       "The original's titleSnippet must be unchanged.")
        let originalMessagesAfter = try await store.fetchMessages(for: source.id)
        XCTAssertEqual(originalMessagesAfter.map(\.id), [userTurn.id, agentTurn.id],
                       "The original's turns (and their ids) must be unchanged.")
        XCTAssertEqual(originalMessagesAfter.first(where: { $0.id == userTurn.id })?.attachments.count, 1,
                       "The original user turn must still carry its image attachment (clone did not move it).")
        XCTAssertEqual(originalMessagesAfter.first(where: { $0.id == userTurn.id })?.status, "sending",
                       "The original's `sending` status must be unchanged (only the CLONE normalizes status).")

        // Both conversations now exist independently.
        let all = try await store.fetchConversations()
        XCTAssertEqual(Set(all.map(\.id)), [source.id, clone.id],
                       "Both the original and the clone must coexist as independent threads.")
    }

    func testCloneOfUnknownConversationThrowsConversationNotFound() async throws {
        let store = makeStore()
        do {
            _ = try await store.cloneConversation(id: UUID(), toBackend: "hermes")
            XCTFail("Cloning a non-existent conversation must throw conversationNotFound.")
        } catch ConversationStore.StoreError.conversationNotFound {
            // expected
        }
    }

    func testCloneOntoCustomGatewayRawStringBindsVerbatim() async throws {
        // The toBackend argument is a RemoteAgentRef rawString — for a custom
        // gateway it is `custom_<uuid>`. The clone must store it verbatim (the
        // routing resolver reads it back to address the gateway).
        let store = makeStore()
        let source = try await store.createConversation(backend: "openclaw")
        _ = try await store.appendMessage(
            role: "user", text: "hi", conversationID: source.id, sourceDevice: "phone"
        )

        let customRaw = "custom_8E4E2D0A-1B7C-4F4E-9D1A-2C3B4A5D6E7F"
        let clone = try await store.cloneConversation(id: source.id, toBackend: customRaw)

        XCTAssertEqual(clone.backend, customRaw,
                       "A custom-gateway rawString must be stored verbatim on the clone.")
        let refetchedFetch = try await store.fetchConversation(id: clone.id)
        let refetched = try XCTUnwrap(refetchedFetch)
        XCTAssertEqual(refetched.backend, customRaw,
                       "The persisted clone must surface the same rawString on re-fetch.")
    }

    // MARK: - conversationID(forMessageID:)

    func testConversationIDForKnownMessageReturnsOwningConversation() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let message = try await store.appendMessage(
            role: "user", text: "which thread owns me?", conversationID: convo.id, sourceDevice: "phone"
        )

        let owner = try await store.conversationID(forMessageID: message.id)
        XCTAssertEqual(owner, convo.id,
                       "A known message must resolve to its owning conversation id.")
    }

    func testConversationIDForUnknownMessageReturnsNil() async throws {
        let store = makeStore()
        // Seed an unrelated conversation + message so the store is non-empty.
        let convo = try await store.createConversation(backend: "openclaw")
        _ = try await store.appendMessage(
            role: "user", text: "unrelated", conversationID: convo.id, sourceDevice: "phone"
        )

        let owner = try await store.conversationID(forMessageID: UUID())
        XCTAssertNil(owner, "An unknown message id must resolve to nil, not throw.")
    }
}
