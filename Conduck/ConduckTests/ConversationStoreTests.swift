// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationStoreTests.swift
//
// Conversation store. Covers the two-level `ConversationStore`
// CRUD via the in-memory testability seam so the App Group sqlite is
// never touched. Each test constructs its OWN isolated `inMemory` store (not
// the `.shared` singleton) — full per-test isolation, no wipe coordination.
//
// Coverage:
//   1. createConversation returns a populated record
//   2. createConversation defaults (nil title, fresh sessionID, stamps)
//   3. appendMessage links the message + returns the record
//   4. appendMessage bumps the parent conversation's lastActivityAt
//   5. appendMessage on an unknown ID throws conversationNotFound
//   6. fetchMessages returns createdAt-ASCending order
//   7. fetchConversations returns lastActivityAt-DESCending order
//   8. deleteConversation cascades (its messages are gone)
//   9. deleteAll empties the store
//  10. Sendable snapshot round-trip — defensive init tolerates nil fields
//  11. delete paths clear the per-device quick-capture pointer (matching id
//      and deleteAll; a non-pointer delete leaves it intact)

import XCTest
import CoreData
@testable import Conduck

final class ConversationStoreTests: XCTestCase {

    /// Fresh isolated in-memory store per test.
    private func makeStore() -> ConversationStore {
        ConversationStore(inMemory: true)
    }

    // The delete-clears-pointer tests touch the SHARED App-Group quick-capture
    // pointer (the store's delete paths call `SettingsManager.shared`, not an
    // injected seam) — clear it around every test so a leftover pointer can't
    // leak into other tests/suites. App-Group UserDefaults only (no signing).
    override func setUp() async throws {
        try await super.setUp()
        await SettingsManager.shared.clearActiveConversation()
    }

    override func tearDown() async throws {
        await SettingsManager.shared.clearActiveConversation()
        try await super.tearDown()
    }

    // MARK: - createConversation

    func testCreateConversationReturnsPopulatedRecord() async throws {
        let store = makeStore()
        let record = try await store.createConversation(backend: "openclaw")

        XCTAssertEqual(record.backend, "openclaw")
        XCTAssertNil(record.title)
        XCTAssertFalse(record.sessionID.isEmpty)
        // createdAt == lastActivityAt at birth.
        XCTAssertEqual(record.createdAt, record.lastActivityAt)
    }

    func testCreateConversationMintsDistinctSessionIDs() async throws {
        let store = makeStore()
        let a = try await store.createConversation(backend: "openclaw")
        let b = try await store.createConversation(backend: "hermes")

        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(a.sessionID, b.sessionID)
        XCTAssertEqual(b.backend, "hermes")
    }

    // MARK: - appendMessage

    func testAppendMessageLinksAndReturnsRecord() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")

        let msg = try await store.appendMessage(
            role: "user",
            text: "Hello agent",
            conversationID: convo.id,
            sourceDevice: "phone"
        )

        XCTAssertEqual(msg.role, "user")
        XCTAssertEqual(msg.text, "Hello agent")
        XCTAssertEqual(msg.sourceDevice, "phone")

        let messages = try await store.fetchMessages(for: convo.id)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.id, msg.id)
    }

    func testAppendMessageBumpsLastActivityAt() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let originalActivity = convo.lastActivityAt

        // Small real delay so the bumped timestamp is strictly greater.
        try await Task.sleep(nanoseconds: 20_000_000) // 20ms

        _ = try await store.appendMessage(
            role: "user",
            text: "ping",
            conversationID: convo.id,
            sourceDevice: "phone"
        )

        let conversations = try await store.fetchConversations()
        let refreshed = try XCTUnwrap(conversations.first { $0.id == convo.id })
        XCTAssertGreaterThan(refreshed.lastActivityAt, originalActivity)
    }

    func testAppendMessageUnknownConversationThrows() async throws {
        let store = makeStore()
        let bogusID = UUID()

        do {
            _ = try await store.appendMessage(
                role: "user",
                text: "orphan",
                conversationID: bogusID,
                sourceDevice: "phone"
            )
            XCTFail("Expected conversationNotFound to be thrown")
        } catch ConversationStore.StoreError.conversationNotFound {
            // expected
        }
    }

    // MARK: - fetchConversation(id:)

    func testFetchConversationByIDRoundTrips() async throws {
        let store = makeStore()
        let created = try await store.createConversation(backend: "hermes")

        let fetched = try await store.fetchConversation(id: created.id)
        let unwrapped = try XCTUnwrap(fetched, "A created conversation must be fetchable by its id.")
        XCTAssertEqual(unwrapped.id, created.id)
        XCTAssertEqual(unwrapped.backend, "hermes",
                       "fetchConversation must surface the bound backend (the routing resolver reads it).")
        XCTAssertEqual(unwrapped.sessionID, created.sessionID)
    }

    func testFetchConversationMissReturnsNil() async throws {
        let store = makeStore()
        _ = try await store.createConversation(backend: "openclaw")

        let miss = try await store.fetchConversation(id: UUID())
        XCTAssertNil(miss, "An unknown id must resolve nil, not throw.")
    }

    // MARK: - fetch ordering

    func testFetchMessagesAreCreatedAtAscending() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")

        let first = try await store.appendMessage(
            role: "user", text: "first", conversationID: convo.id, sourceDevice: "phone"
        )
        try await Task.sleep(nanoseconds: 10_000_000)
        let second = try await store.appendMessage(
            role: "agent", text: "second", conversationID: convo.id, sourceDevice: "phone"
        )
        try await Task.sleep(nanoseconds: 10_000_000)
        let third = try await store.appendMessage(
            role: "user", text: "third", conversationID: convo.id, sourceDevice: "phone"
        )

        let messages = try await store.fetchMessages(for: convo.id)
        XCTAssertEqual(messages.map(\.id), [first.id, second.id, third.id])
        XCTAssertEqual(messages.map(\.text), ["first", "second", "third"])
    }

    func testFetchConversationsAreLastActivityDescending() async throws {
        let store = makeStore()
        let a = try await store.createConversation(backend: "openclaw")
        try await Task.sleep(nanoseconds: 10_000_000)
        let b = try await store.createConversation(backend: "openclaw")
        try await Task.sleep(nanoseconds: 10_000_000)

        // Touch `a` so it becomes the most-recently-active.
        _ = try await store.appendMessage(
            role: "user", text: "revive a", conversationID: a.id, sourceDevice: "phone"
        )

        let conversations = try await store.fetchConversations()
        XCTAssertEqual(conversations.count, 2)
        // `a` bumped most recently → first; `b` second.
        XCTAssertEqual(conversations.first?.id, a.id)
        XCTAssertEqual(conversations.last?.id, b.id)
    }

    // MARK: - delete

    func testDeleteConversationCascadesMessages() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        _ = try await store.appendMessage(
            role: "user", text: "m1", conversationID: convo.id, sourceDevice: "phone"
        )
        _ = try await store.appendMessage(
            role: "agent", text: "m2", conversationID: convo.id, sourceDevice: "phone"
        )

        try await store.deleteConversation(id: convo.id)

        let conversations = try await store.fetchConversations()
        XCTAssertTrue(conversations.isEmpty)
        // Cascade: the messages must be gone too.
        let messages = try await store.fetchMessages(for: convo.id)
        XCTAssertTrue(messages.isEmpty)
    }

    func testDeleteAllEmptiesStore() async throws {
        let store = makeStore()
        _ = try await store.createConversation(backend: "openclaw")
        _ = try await store.createConversation(backend: "hermes")

        try await store.deleteAll()

        let conversations = try await store.fetchConversations()
        XCTAssertTrue(conversations.isEmpty)
    }

    // MARK: - delete clears the quick-capture pointer (per-device lane)

    func testDeleteConversationClearsMatchingQuickPointer() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        await SettingsManager.shared.recordActiveConversation(convo.id)

        try await store.deleteConversation(id: convo.id)

        let pointer = await SettingsManager.shared.currentActiveConversationID()
        XCTAssertNil(pointer,
                     "Deleting the pointed-at conversation must clear the quick-capture pointer.")
    }

    func testDeleteConversationLeavesUnrelatedQuickPointer() async throws {
        let store = makeStore()
        let pointed = try await store.createConversation(backend: "openclaw")
        let other = try await store.createConversation(backend: "openclaw")
        await SettingsManager.shared.recordActiveConversation(pointed.id)

        try await store.deleteConversation(id: other.id)

        let pointer = await SettingsManager.shared.currentActiveConversationID()
        XCTAssertEqual(pointer, pointed.id,
                       "Deleting a NON-pointer conversation must leave the pointer intact.")
    }

    func testDeleteAllClearsQuickPointer() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        await SettingsManager.shared.recordActiveConversation(convo.id)

        try await store.deleteAll()

        let pointer = await SettingsManager.shared.currentActiveConversationID()
        XCTAssertNil(pointer,
                     "deleteAll must clear the quick-capture pointer unconditionally.")
    }

    // MARK: - Sendable snapshot round-trip / defensive init

    func testRecordDefensiveInitToleratesNilFields() async throws {
        // Bridge bare (attribute-less) managed objects through the defensive
        // `init(managedObject:)` against the REAL loaded model — mirrors a
        // partially-synced CloudKit row. Every field must nil-coalesce to a
        // safe default rather than crash. Uses the store's test seam so the
        // compiled model doesn't have to be reconstructed out-of-band.
        let store = makeStore()
        let (convoRecord, msgRecord) = try await store.defensiveSnapshotsFromBareObjects()

        XCTAssertNil(convoRecord.title)
        XCTAssertNil(convoRecord.titleSnippet, "Defensive init must tolerate a nil titleSnippet.")
        XCTAssertEqual(convoRecord.sessionID, "")
        XCTAssertEqual(convoRecord.backend, "")

        XCTAssertEqual(msgRecord.role, "agent")
        XCTAssertEqual(msgRecord.text, "")
        XCTAssertEqual(msgRecord.sourceDevice, "unknown")
        // V1.1 defaults: nil status (= legacy = sent) + empty attachments.
        XCTAssertNil(msgRecord.status)
        XCTAssertTrue(msgRecord.attachments.isEmpty)
    }

    // MARK: - V1.1 Core Attachments — image attachment + send-state

    func testAppendUserTurnWithImageAttachmentStoresMetadataNotFullBytes() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")

        let fullJPEG = Data((0..<2048).map { UInt8($0 % 256) }) // stand-in "full image bytes"
        let thumb = Data((0..<64).map { _ in UInt8(0xAB) })
        let draft = AttachmentDraft(
            mimeType: "image/jpeg",
            filename: nil,
            data: fullJPEG,
            thumbnailData: thumb,
            width: 1568,
            height: 1176,
            byteSize: fullJPEG.count,
            sequence: 0
        )

        let msg = try await store.appendMessage(
            role: "user",
            text: "what's this?",
            conversationID: convo.id,
            sourceDevice: "phone",
            status: "sending",
            attachments: [draft]
        )

        // Returned record + status.
        XCTAssertEqual(msg.status, "sending")
        XCTAssertEqual(msg.attachments.count, 1)

        // Re-fetch the persisted snapshot (not just the returned value).
        let fetched = try await store.fetchMessages(for: convo.id)
        let stored = try XCTUnwrap(fetched.first)
        XCTAssertEqual(stored.status, "sending")
        XCTAssertEqual(stored.attachments.count, 1)

        let att = try XCTUnwrap(stored.attachments.first)
        XCTAssertTrue(att.isImage)
        XCTAssertFalse(att.isText)
        XCTAssertEqual(att.mimeType, "image/jpeg")
        XCTAssertEqual(att.width, 1568)
        XCTAssertEqual(att.height, 1176)
        XCTAssertEqual(att.byteSize, fullJPEG.count)
        // Snapshot carries the thumbnail + metadata...
        XCTAssertEqual(att.thumbnailData, thumb, "Snapshot must carry the small thumbnail.")
        // ...but NEVER the full image bytes (no field exposes them; extractedText
        // is nil for images).
        XCTAssertNil(att.extractedText, "Image snapshots must not inline any decoded text.")

        // Full bytes are reachable ONLY via loadAttachmentData.
        let loaded = try await store.loadAttachmentData(for: stored.id)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first, fullJPEG,
                       "Full image bytes must round-trip via loadAttachmentData(for:).")
        // The thumbnail (64 bytes) must NOT equal the full image (2048 bytes) —
        // proves the snapshot is not just handing back the full blob.
        XCTAssertNotEqual(att.thumbnailData?.count, fullJPEG.count)
    }

    func testAppendUserTurnWithTextFileAttachmentRoundTrips() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")

        let extracted = "col_a,col_b\n1,2\n3,4"
        let draft = AttachmentDraft(
            mimeType: "text/csv",
            filename: "report.csv",
            data: Data(extracted.utf8),  // text files store their UTF-8 text bytes
            thumbnailData: nil,
            width: 0,
            height: 0,
            byteSize: extracted.utf8.count,
            sequence: 0
        )

        _ = try await store.appendMessage(
            role: "user",
            text: "summarise this",
            conversationID: convo.id,
            sourceDevice: "phone",
            status: "sending",
            attachments: [draft]
        )

        let fetched = try await store.fetchMessages(for: convo.id)
        let att = try XCTUnwrap(fetched.first?.attachments.first)

        XCTAssertTrue(att.isText)
        XCTAssertFalse(att.isImage)
        XCTAssertEqual(att.filename, "report.csv", "Text-file filename must round-trip.")
        XCTAssertEqual(att.extractedText, extracted, "Extracted text must round-trip via the snapshot.")
        XCTAssertNil(att.thumbnailData, "Text files carry no thumbnail.")

        // loadAttachmentData returns IMAGE bytes only — a text-only turn yields
        // an empty array.
        let loaded = try await store.loadAttachmentData(for: fetched.first!.id)
        XCTAssertTrue(loaded.isEmpty, "loadAttachmentData must return image bytes only (text files surface via extractedText).")
    }

    func testAttachmentsSortedBySequence() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")

        func imageDraft(seq: Int, marker: UInt8) -> AttachmentDraft {
            AttachmentDraft(
                mimeType: "image/jpeg",
                filename: nil,
                data: Data([marker]),
                thumbnailData: Data([marker]),
                width: 10, height: 10, byteSize: 1, sequence: seq
            )
        }
        // Insert out of order; the snapshot must come back sorted by sequence.
        _ = try await store.appendMessage(
            role: "user", text: "three images",
            conversationID: convo.id, sourceDevice: "phone", status: "sending",
            attachments: [imageDraft(seq: 2, marker: 2),
                          imageDraft(seq: 0, marker: 0),
                          imageDraft(seq: 1, marker: 1)]
        )

        let fetched = try await store.fetchMessages(for: convo.id)
        let seqs = try XCTUnwrap(fetched.first).attachments.map(\.sequence)
        XCTAssertEqual(seqs, [0, 1, 2], "Attachments must be ordered by `sequence`.")

        // loadAttachmentData must also be sequence-ordered (the wire data-URI order).
        let loaded = try await store.loadAttachmentData(for: fetched.first!.id)
        XCTAssertEqual(loaded.map { $0.first }, [0, 1, 2],
                       "loadAttachmentData must return image bytes in sequence order.")
    }

    func testUpdateStatusFlipsAMessage() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let msg = try await store.appendMessage(
            role: "user", text: "pending", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )

        try await store.updateStatus(messageID: msg.id, status: "sent")

        let fetched = try await store.fetchMessages(for: convo.id)
        XCTAssertEqual(fetched.first?.status, "sent", "updateStatus must flip sending → sent.")
    }

    func testUpdateStatusUnknownMessageIsNoOp() async throws {
        let store = makeStore()
        // Must not throw for a non-existent message id (deleted mid-flight).
        try await store.updateStatus(messageID: UUID(), status: "failed")
    }

    // MARK: - markPendingUserTurns (the stuck-spinner fix)

    func testMarkPendingUserTurnsFlipsOnlySendingUserTurns() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")

        // 1) A user turn in `sending` — SHOULD flip.
        let sendingUser = try await store.appendMessage(
            role: "user", text: "u-sending", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        // 2) An AGENT turn (status nil) — must be UNTOUCHED.
        let agentTurn = try await store.appendMessage(
            role: "agent", text: "a-reply", conversationID: convo.id,
            sourceDevice: "phone", status: nil
        )
        // 3) A user turn with nil status (headless capture = sent) — UNTOUCHED.
        let nilStatusUser = try await store.appendMessage(
            role: "user", text: "u-headless", conversationID: convo.id,
            sourceDevice: "phone", status: nil
        )

        await store.markPendingUserTurns(conversationID: convo.id, to: "sent")

        let fetched = try await store.fetchMessages(for: convo.id)
        func status(of id: UUID) -> String?? {
            fetched.first { $0.id == id }?.status
        }

        XCTAssertEqual(status(of: sendingUser.id), .some("sent"),
                       "A `sending` user turn must flip to `sent`.")
        XCTAssertEqual(status(of: agentTurn.id), .some(nil),
                       "An agent turn (nil status) must be left untouched.")
        XCTAssertEqual(status(of: nilStatusUser.id), .some(nil),
                       "A nil-status user turn (headless = sent) must be left untouched.")
    }

    func testMarkPendingUserTurnsToFailed() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let sendingUser = try await store.appendMessage(
            role: "user", text: "u-sending", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        // An already-`sent` user turn must NOT be re-flipped to failed.
        let alreadySent = try await store.appendMessage(
            role: "user", text: "u-sent", conversationID: convo.id,
            sourceDevice: "phone", status: "sent"
        )

        await store.markPendingUserTurns(conversationID: convo.id, to: "failed")

        let fetched = try await store.fetchMessages(for: convo.id)
        XCTAssertEqual(fetched.first { $0.id == sendingUser.id }?.status, "failed",
                       "A `sending` user turn must flip to `failed`.")
        XCTAssertEqual(fetched.first { $0.id == alreadySent.id }?.status, "sent",
                       "An already-`sent` user turn must NOT be touched (scoped to status == sending).")
    }

    // MARK: - CarPlay route-error persistence (notification-cut regression net)

    // Plan D5 #4 cut the CarPlay after-disconnect FAILURE NOTIFICATION from
    // `CarPlayConverseUploader.routeError`'s `!hasLiveService` branch. The
    // DURABLE state — the failed user turn — must survive that cut so the iOS
    // thread still shows the Retry chip on next open. `routeError` flips the
    // turn through this exact `ConversationStore` seam (exact-message flip when
    // the upload threaded a `userMessageID`, conversation-wide fallback when it
    // did not); these two tests pin that the flip persists with NO dependency
    // on the removed notification side effect. `routeError` itself is a private
    // method on a singleton with a background URLSession (no DI seam to drive
    // headlessly), so this guards the persistence contract it relies on.

    func testCarPlayRouteErrorExactMessageFlipPersistsWithoutNotification() async throws {
        // The exact-message path: the CarPlay upload threaded a `userMessageID`,
        // so `routeError` calls `markPendingUserTurn(messageID:to:"failed")`.
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let sendingUser = try await store.appendMessage(
            role: "user", text: "carplay turn", conversationID: convo.id,
            sourceDevice: "carplay", status: "sending"
        )

        await store.markPendingUserTurn(messageID: sendingUser.id, to: "failed")

        let fetched = try await store.fetchMessages(for: convo.id)
        XCTAssertEqual(fetched.first { $0.id == sendingUser.id }?.status, "failed",
                       "After the notification cut, the failed CarPlay turn must still persist for Retry (exact-message path).")
    }

    func testCarPlayRouteErrorConversationWideFlipPersistsWithoutNotification() async throws {
        // The fallback path: an old blob / caller not threading the id, so
        // `routeError` calls `markPendingUserTurns(conversationID:to:"failed")`.
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let sendingUser = try await store.appendMessage(
            role: "user", text: "carplay turn", conversationID: convo.id,
            sourceDevice: "carplay", status: "sending"
        )

        await store.markPendingUserTurns(conversationID: convo.id, to: "failed")

        let fetched = try await store.fetchMessages(for: convo.id)
        XCTAssertEqual(fetched.first { $0.id == sendingUser.id }?.status, "failed",
                       "After the notification cut, the failed CarPlay turn must still persist for Retry (conversation-wide fallback).")
    }

    // MARK: - titleSnippet (denormalized list-row title)

    func testCreateConversationReturnsNilTitleSnippet() async throws {
        let store = makeStore()
        let record = try await store.createConversation(backend: "openclaw")
        XCTAssertNil(record.titleSnippet, "A fresh conversation has no user turn yet → nil snippet.")
    }

    func testAppendMessageWritesTitleSnippetOnFirstUserTurnOnly() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")

        // First user turn → snippet captured.
        _ = try await store.appendMessage(
            role: "user", text: "Plan my trip to Lisbon", conversationID: convo.id, sourceDevice: "phone"
        )
        var fetched = try await store.fetchConversation(id: convo.id)
        var refreshed = try XCTUnwrap(fetched)
        XCTAssertEqual(refreshed.titleSnippet, "Plan my trip to Lisbon")

        // Agent reply → must NOT change the snippet.
        _ = try await store.appendMessage(
            role: "agent", text: "Sure, here is a plan…", conversationID: convo.id, sourceDevice: "phone"
        )
        fetched = try await store.fetchConversation(id: convo.id)
        refreshed = try XCTUnwrap(fetched)
        XCTAssertEqual(refreshed.titleSnippet, "Plan my trip to Lisbon",
                       "Agent replies must never overwrite the snippet.")

        // Second user turn → must NOT overwrite (write-once on the first user turn).
        _ = try await store.appendMessage(
            role: "user", text: "Actually make it Porto", conversationID: convo.id, sourceDevice: "phone"
        )
        fetched = try await store.fetchConversation(id: convo.id)
        refreshed = try XCTUnwrap(fetched)
        XCTAssertEqual(refreshed.titleSnippet, "Plan my trip to Lisbon",
                       "A later user turn must not overwrite the first-turn snippet.")
    }

    func testSnippetTruncatesAndStripsEmpty() {
        // First non-empty line, trimmed.
        XCTAssertEqual(ConversationStore.snippet(from: "  hello world  "), "hello world")
        XCTAssertEqual(ConversationStore.snippet(from: "\n\nfirst line\nsecond"), "first line")
        // Empty / whitespace-only → nil (an attachment-only turn).
        XCTAssertNil(ConversationStore.snippet(from: ""))
        XCTAssertNil(ConversationStore.snippet(from: "   \n  "))
        // Cap at 60 + ellipsis.
        let long = String(repeating: "x", count: 100)
        let snip = try! XCTUnwrap(ConversationStore.snippet(from: long))
        XCTAssertTrue(snip.hasSuffix("…"))
        XCTAssertEqual(snip.count, 61, "60-char head + ellipsis.")
    }

    func testAttachmentOnlyFirstTurnLeavesSnippetNilThenLaterTextFills() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")

        // Attachment-only user turn (empty text) → snippet stays nil.
        let draft = AttachmentDraft(
            mimeType: "image/jpeg", filename: nil, data: Data([0x1]), thumbnailData: Data([0x1]),
            width: 1, height: 1, byteSize: 1, sequence: 0
        )
        _ = try await store.appendMessage(
            role: "user", text: "", conversationID: convo.id, sourceDevice: "phone",
            status: "sending", attachments: [draft]
        )
        var fetched = try await store.fetchConversation(id: convo.id)
        var refreshed = try XCTUnwrap(fetched)
        XCTAssertNil(refreshed.titleSnippet, "An empty-text attachment turn yields nil snippet.")

        // A later user turn WITH text fills it.
        _ = try await store.appendMessage(
            role: "user", text: "what is in this image?", conversationID: convo.id, sourceDevice: "phone"
        )
        fetched = try await store.fetchConversation(id: convo.id)
        refreshed = try XCTUnwrap(fetched)
        XCTAssertEqual(refreshed.titleSnippet, "what is in this image?")
    }

    func testBackfillPopulatesNilSnippetConversationsAndIsIdempotent() async throws {
        // The backfill flag lives in the shared App Group UserDefaults; reset it
        // so this test controls the one-shot guard deterministically.
        let flagKey = "conversationTitleSnippetBackfillDone"
        let defaults = TestStores.defaults
        defaults.removeObject(forKey: flagKey)
        defer { defaults.removeObject(forKey: flagKey) }

        let store = makeStore()
        // Seed a conversation whose snippet is nil by appending an AGENT turn
        // first (agent never sets the snippet) — but the backfill keys off the
        // first USER turn, so add a user turn too without it being captured.
        // Easiest: directly seed via the test seam isn't available for arbitrary
        // text, so simulate a legacy row by clearing the snippet after a user turn.
        let convo = try await store.createConversation(backend: "openclaw")
        _ = try await store.appendMessage(
            role: "user", text: "legacy first line", conversationID: convo.id, sourceDevice: "phone"
        )
        // Force the legacy (pre-field) state: clear the just-written snippet.
        try await store.debugClearTitleSnippet(conversationID: convo.id)
        var fetched = try await store.fetchConversation(id: convo.id)
        var refreshed = try XCTUnwrap(fetched)
        XCTAssertNil(refreshed.titleSnippet, "Precondition: snippet cleared to simulate a legacy row.")

        // Backfill → snippet derived from the first user message.
        await store.backfillTitleSnippetsIfNeeded()
        fetched = try await store.fetchConversation(id: convo.id)
        refreshed = try XCTUnwrap(fetched)
        XCTAssertEqual(refreshed.titleSnippet, "legacy first line")

        // Idempotent: clear again, run backfill — the flag short-circuits it so
        // the snippet stays nil (proves the one-shot guard).
        try await store.debugClearTitleSnippet(conversationID: convo.id)
        await store.backfillTitleSnippetsIfNeeded()
        fetched = try await store.fetchConversation(id: convo.id)
        refreshed = try XCTUnwrap(fetched)
        XCTAssertNil(refreshed.titleSnippet,
                     "Backfill must run once (flag set) — a second call is a no-op.")
    }

    // MARK: - markPendingUserTurn (exact per-message flip — anti-aliasing)

    func testMarkPendingUserTurnFlipsOnlyTheTargetMessage() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")

        // TWO concurrent in-flight turns in ONE conversation (the aliasing
        // scenario: long headless think + an in-app follow-up).
        let first = try await store.appendMessage(
            role: "user", text: "u-first", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        let second = try await store.appendMessage(
            role: "user", text: "u-second", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )

        // Exact flip of the FIRST turn must not touch the second.
        await store.markPendingUserTurn(messageID: first.id, to: "sent")

        let fetched = try await store.fetchMessages(for: convo.id)
        XCTAssertEqual(fetched.first { $0.id == first.id }?.status, "sent",
                       "The addressed turn must flip.")
        XCTAssertEqual(fetched.first { $0.id == second.id }?.status, "sending",
                       "The sibling in-flight turn must be left untouched (no conversation-wide aliasing).")
    }

    func testMarkPendingUserTurnOnlyTouchesSendingUserTurns() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")

        // Already-resolved user turn — must NOT be re-flipped.
        let resolved = try await store.appendMessage(
            role: "user", text: "u-sent", conversationID: convo.id,
            sourceDevice: "phone", status: "sent"
        )
        // Agent turn — must NOT be touched even if addressed directly.
        let agent = try await store.appendMessage(
            role: "agent", text: "a-reply", conversationID: convo.id,
            sourceDevice: "phone", status: nil
        )

        await store.markPendingUserTurn(messageID: resolved.id, to: "failed")
        await store.markPendingUserTurn(messageID: agent.id, to: "failed")
        // Unknown id — silent no-op (must not throw / crash).
        await store.markPendingUserTurn(messageID: UUID(), to: "failed")

        let fetched = try await store.fetchMessages(for: convo.id)
        XCTAssertEqual(fetched.first { $0.id == resolved.id }?.status, "sent",
                       "A resolved turn is never re-flipped (scoped to status == sending).")
        XCTAssertEqual(fetched.first { $0.id == agent.id }?.status, .some(nil),
                       "An agent turn is never touched (scoped to role == user).")
    }

    // MARK: - sweepStaleSendingUserTurns (launch-time recovery)

    func testSweepFlipsStaleSendingTurnToFailed() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let stuck = try await store.appendMessage(
            role: "user", text: "u-stuck", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )

        // `olderThan: 0` → cutoff = now, so the just-appended turn qualifies.
        await store.sweepStaleSendingUserTurns(olderThan: 0)

        let fetched = try await store.fetchMessages(for: convo.id)
        XCTAssertEqual(fetched.first { $0.id == stuck.id }?.status, "failed",
                       "A stale `sending` user turn with no reply must flip to `failed` (Retry).")
    }

    func testSweepRespectsGraceWindow() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let inFlight = try await store.appendMessage(
            role: "user", text: "u-fresh", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )

        // Default-style grace (1 hour here): a freshly-appended turn is far
        // younger than the cutoff → must NOT be flipped (it may legitimately
        // still be in flight, incl. on another device via CloudKit).
        await store.sweepStaleSendingUserTurns(olderThan: 3600)

        let fetched = try await store.fetchMessages(for: convo.id)
        XCTAssertEqual(fetched.first { $0.id == inFlight.id }?.status, "sending",
                       "A turn younger than the grace window must be left alone.")
    }

    func testSweepSkipsExcludedConversations() async throws {
        let store = makeStore()
        let live = try await store.createConversation(backend: "openclaw")
        let dead = try await store.createConversation(backend: "openclaw")
        let liveTurn = try await store.appendMessage(
            role: "user", text: "u-live", conversationID: live.id,
            sourceDevice: "phone", status: "sending"
        )
        let deadTurn = try await store.appendMessage(
            role: "user", text: "u-dead", conversationID: dead.id,
            sourceDevice: "phone", status: "sending"
        )

        // `live` simulates a conversation with a LIVE background task (the
        // delegate owns its resolution) — excluded; `dead` is swept.
        await store.sweepStaleSendingUserTurns(
            olderThan: 0, excludingConversationIDs: [live.id]
        )

        let liveFetched = try await store.fetchMessages(for: live.id)
        let deadFetched = try await store.fetchMessages(for: dead.id)
        XCTAssertEqual(liveFetched.first { $0.id == liveTurn.id }?.status, "sending",
                       "An excluded (live-task) conversation's turn must be left alone.")
        XCTAssertEqual(deadFetched.first { $0.id == deadTurn.id }?.status, "failed",
                       "A non-excluded stale turn must flip to `failed`.")
    }

    func testSweepMarksAnsweredTurnSentNotFailed() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")

        // Kill-between-append-and-flip simulation: the reply IS persisted but
        // the user turn is still `sending`. A LATER agent message must make
        // the sweep flip it to `sent` (a `failed` + Retry chip under a landed
        // reply would invite a duplicate send).
        let answered = try await store.appendMessage(
            role: "user", text: "u-answered", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        // Ensure the reply's createdAt is strictly LATER than the user turn's.
        try await Task.sleep(for: .milliseconds(20))
        _ = try await store.appendMessage(
            role: "agent", text: "a-reply", conversationID: convo.id,
            sourceDevice: "phone", status: nil
        )
        // A SECOND stuck turn appended AFTER the reply — no later agent
        // message exists for it, so it must still flip to `failed`.
        try await Task.sleep(for: .milliseconds(20))
        let unanswered = try await store.appendMessage(
            role: "user", text: "u-unanswered", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )

        await store.sweepStaleSendingUserTurns(olderThan: 0)

        let fetched = try await store.fetchMessages(for: convo.id)
        XCTAssertEqual(fetched.first { $0.id == answered.id }?.status, "sent",
                       "A stuck turn WITH a later agent reply was delivered → `sent`, not `failed`.")
        XCTAssertEqual(fetched.first { $0.id == unanswered.id }?.status, "failed",
                       "A stuck turn with NO later agent reply must flip to `failed`.")
    }

    // MARK: - addAttachments (post-append chip attach)

    func testAddAttachmentsAppendsToExistingMessage() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let reply = try await store.appendMessage(
            role: "agent", text: "wrote report.pdf", conversationID: convo.id,
            sourceDevice: "phone"
        )

        var draft = AttachmentDraft(
            mimeType: "application/pdf",
            filename: "report.pdf",
            data: Data(),
            thumbnailData: nil,
            width: 0, height: 0, byteSize: 0, sequence: 0
        )
        draft.isServerReference = true
        draft.storedKey = "report.pdf"

        try await store.addAttachments(messageID: reply.id, attachments: [draft])

        let fetched = try await store.fetchMessages(for: convo.id)
        let attachments = try XCTUnwrap(fetched.first { $0.id == reply.id }).attachments
        XCTAssertEqual(attachments.count, 1, "The draft must attach to the existing message.")
        XCTAssertEqual(attachments.first?.storedKey, "report.pdf")
        XCTAssertEqual(attachments.first?.isServerReference, true)
    }

    func testAddAttachmentsMissingMessageIsNoOp() async throws {
        let store = makeStore()
        let draft = AttachmentDraft(
            mimeType: "application/pdf",
            filename: "ghost.pdf",
            data: Data(),
            thumbnailData: nil,
            width: 0, height: 0, byteSize: 0, sequence: 0
        )
        // Unknown message id (deleted mid-flight) → silent no-op, must not throw.
        try await store.addAttachments(messageID: UUID(), attachments: [draft])
    }
}
