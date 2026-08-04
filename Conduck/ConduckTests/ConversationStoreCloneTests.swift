// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationStoreCloneTests.swift
//
// Locks the `ConversationStore.cloneConversation(id:toBackend:targetFileLaneID:)`
// contract — the ONLY sanctioned gateway-switch path (a thread's backend binding
// locks after its first turn, so switching gateways is a CLEAN CUT into a NEW
// thread, never a rebind).
//
// The copy contract verified here:
//   - mints a NEW conversation id (≠ source id) + a fresh sessionID
//   - copies turns in createdAt-ascending order, preserving role / text /
//     sourceDevice (fresh per-clone message ids)
//   - carries the source titleSnippet; binds to the target backend rawString
//     verbatim; title stays nil
//   - DEEP-COPIES attachments. Inline bytes always carry. A server reference
//     carries its `storedKey` + owning lane ONLY when the target file lane is
//     the same lane that minted it; otherwise it is detached to a byte-less
//     tombstone so the file is still NAMED but never falsely addressable.
//   - INVARIANT: never a `storedKey` without its owning lane, in either
//     direction (a key with a nil/foreign lane fails `canAccessExistingBlob`
//     closed and would refuse the user's Try Again with a bogus "file transfer
//     isn't configured"; it would also pollute the retro-output detector's
//     token set, which matches inbound keys WITHOUT a lane check)
//   - normalizes mid-thread status to nil, and stamps a TRAILING user turn
//     `failed` (the affordance-bearing state) while reporting what that row's
//     status WAS, so the caller can auto-continue only a genuinely failed turn
//   - never copies `failureCode` / `failureWireCode` / `failureHadHistoryImages`
//     (a verdict from the OLD gateway must not govern the new one)
//   - leaves the ORIGINAL conversation + its turns untouched
//
// The WIRE half of the detached-reference contract lives in
// `RemoteAgent/ConverseWireTests.swift` (`testPriorServerFileMismatchedLane…`,
// `testPriorServerFileLegacyNilOwner…`) — a clone tombstone is exactly the
// nil-owner shape those already lock, so it is not re-fixtured here.
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

    private static let laneA = "aaaa1111"
    private static let laneB = "bbbb2222"

    private func imageDraft(sequence: Int = 0, storedKey: String? = nil) -> AttachmentDraft {
        var draft = AttachmentDraft(
            mimeType: "image/jpeg",
            filename: nil,
            data: Data((0..<512).map { UInt8($0 % 256) }),
            thumbnailData: Data([0xAB, 0xCD]),
            width: 100,
            height: 80,
            byteSize: 512,
            sequence: sequence
        )
        draft.storedKey = storedKey
        return draft
    }

    private func serverFileDraft(
        name: String = "report.pdf",
        storedKey: String = "abcd__report.pdf",
        sequence: Int = 0
    ) -> AttachmentDraft {
        var draft = AttachmentDraft(
            mimeType: "application/pdf",
            filename: name,
            data: Data(),
            thumbnailData: nil,
            width: 0,
            height: 0,
            byteSize: 11_264,
            sequence: sequence
        )
        draft.isServerReference = true
        draft.storedKey = storedKey
        draft.previewData = Data("a text preview".utf8)
        draft.previewKind = "text"
        return draft
    }

    // MARK: - cloneConversation — history, identity, original untouched

    func testCloneCopiesInlineImageBytesAndLeavesOriginalIntact() async throws {
        let store = makeStore()
        let source = try await store.createConversation(backend: "openclaw")

        let userTurn = try await store.appendMessage(
            role: "user",
            text: "Plan my trip to Lisbon",
            conversationID: source.id,
            sourceDevice: "phone",
            status: "sending",
            attachments: [imageDraft()]
        )
        try await Task.sleep(nanoseconds: 5_000_000) // keep agent turn strictly later
        let agentTurn = try await store.appendMessage(
            role: "agent",
            text: "Here is a plan for Lisbon.",
            conversationID: source.id,
            sourceDevice: "phone",
            status: nil
        )

        let sourceConvoFetch = try await store.fetchConversation(id: source.id)
        let sourceConvo = try XCTUnwrap(sourceConvoFetch)
        XCTAssertEqual(sourceConvo.titleSnippet, "Plan my trip to Lisbon",
                       "Precondition: source titleSnippet captured from the first user turn.")

        let clone = try await store.cloneConversation(id: source.id, toBackend: "hermes")

        // --- Clone identity + binding ---
        XCTAssertNotEqual(clone.conversation.id, source.id,
                          "Clone must mint a NEW conversation id (clean cut, not a rebind).")
        XCTAssertEqual(clone.conversation.backend, "hermes",
                       "Clone must be bound to the target backend rawString verbatim.")
        XCTAssertNil(clone.conversation.title, "Clone title stays nil.")
        XCTAssertEqual(clone.conversation.titleSnippet, "Plan my trip to Lisbon",
                       "Clone must carry the source's titleSnippet.")
        XCTAssertNotEqual(clone.conversation.sessionID, source.sessionID,
                          "Clone is a new thread → fresh local sessionID.")

        // --- Clone message history ---
        let clonedMessages = try await store.fetchMessages(for: clone.conversation.id)
        XCTAssertEqual(clonedMessages.map(\.text),
                       ["Plan my trip to Lisbon", "Here is a plan for Lisbon."],
                       "Clone must carry the text history in original order.")
        XCTAssertEqual(clonedMessages.map(\.role), ["user", "agent"])
        XCTAssertEqual(clonedMessages.map(\.sourceDevice), ["phone", "phone"])

        let clonedIDs = Set(clonedMessages.map(\.id))
        XCTAssertFalse(clonedIDs.contains(userTurn.id),
                       "Cloned turns get fresh message ids, not the source ids.")
        XCTAssertFalse(clonedIDs.contains(agentTurn.id))

        // --- Attachments deep-copied ---
        let clonedUserTurn = try XCTUnwrap(clonedMessages.first { $0.role == "user" })
        XCTAssertEqual(clonedUserTurn.attachments.count, 1,
                       "Inline image attachment must be deep-copied onto the clone.")
        let clonedAttachment = try XCTUnwrap(clonedUserTurn.attachments.first)
        XCTAssertFalse(clonedAttachment.isServerReference)
        XCTAssertNil(clonedAttachment.storedKey)

        let sourceBytes = try await store.loadAttachmentData(for: userTurn.id)
        let clonedBytes = try await store.loadAttachmentData(for: clonedUserTurn.id)
        XCTAssertEqual(clonedBytes, sourceBytes,
                       "The cloned turn's image bytes must equal the source's — inline bytes are gateway-independent and are what make the clone answerable.")

        let sourceMessagesForID = try await store.fetchMessages(for: source.id)
        let sourceAttachmentID = try XCTUnwrap(
            sourceMessagesForID.first { $0.id == userTurn.id }?.attachments.first?.id
        )
        XCTAssertNotEqual(clonedAttachment.id, sourceAttachmentID,
                          "Cloned attachments get fresh ids (a copy, never a move).")

        // --- ORIGINAL untouched ---
        let originalAfterFetch = try await store.fetchConversation(id: source.id)
        let originalAfter = try XCTUnwrap(originalAfterFetch)
        XCTAssertEqual(originalAfter.backend, "openclaw")
        XCTAssertEqual(originalAfter.titleSnippet, "Plan my trip to Lisbon")
        let originalMessagesAfter = try await store.fetchMessages(for: source.id)
        XCTAssertEqual(originalMessagesAfter.map(\.id), [userTurn.id, agentTurn.id])
        XCTAssertEqual(originalMessagesAfter.first(where: { $0.id == userTurn.id })?.attachments.count, 1,
                       "The original user turn must still carry its attachment (clone copied, did not move).")
        XCTAssertEqual(originalMessagesAfter.first(where: { $0.id == userTurn.id })?.status, "sending",
                       "The original's `sending` status must be unchanged.")

        let all = try await store.fetchConversations()
        XCTAssertEqual(Set(all.map(\.id)), [source.id, clone.conversation.id],
                       "Both the original and the clone must coexist as independent threads.")
    }

    func testCloneCopiesInlineTextFileWithExtractedText() async throws {
        let store = makeStore()
        let source = try await store.createConversation(backend: "openclaw")
        let textDraft = AttachmentDraft(
            mimeType: "text/csv",
            filename: "rows.csv",
            data: Data("a,b\n1,2".utf8),
            thumbnailData: nil,
            width: 0, height: 0, byteSize: 7, sequence: 0
        )
        _ = try await store.appendMessage(
            role: "user", text: "check this", conversationID: source.id,
            sourceDevice: "phone", attachments: [textDraft]
        )

        let clone = try await store.cloneConversation(id: source.id, toBackend: "hermes")
        let cloned = try await store.fetchMessages(for: clone.conversation.id)
        let attachment = try XCTUnwrap(cloned.first?.attachments.first)
        XCTAssertEqual(attachment.filename, "rows.csv")
        XCTAssertEqual(attachment.extractedText, "a,b\n1,2",
                       "A text file's extracted text must survive the clone — it is what the history assembler fences inline.")
    }

    // MARK: - The lane contract

    func testCloneKeepsServerReferenceWhenTargetLaneMintedIt() async throws {
        // The lane is SHA256(file-server URL + credential), NOT a gateway
        // identity — two gateways pointed at one WebDAV share a lane, and the
        // key genuinely still resolves. Detaching it would throw away a working
        // attachment.
        let store = makeStore()
        let source = try await store.createConversation(backend: "openclaw")
        _ = try await store.appendMessage(
            role: "user", text: "summarize this", conversationID: source.id,
            sourceDevice: "phone", fileTransferLaneID: Self.laneA,
            attachments: [serverFileDraft()]
        )

        let clone = try await store.cloneConversation(
            id: source.id, toBackend: "hermes", targetFileLaneID: Self.laneA
        )
        let cloned = try await store.fetchMessages(for: clone.conversation.id)
        let userTurn = try XCTUnwrap(cloned.first)
        let attachment = try XCTUnwrap(userTurn.attachments.first)

        XCTAssertEqual(attachment.storedKey, "abcd__report.pdf",
                       "Same lane → the key still addresses the blob and must be preserved.")
        XCTAssertEqual(userTurn.fileTransferLaneID, Self.laneA,
                       "The owning lane must ride along with the key it authorizes.")
        XCTAssertEqual(attachment.previewKind, "text",
                       "A preserved reference keeps its preview — the bytes are still reachable.")
    }

    func testCloneDetachesServerReferenceWhenTargetLaneDiffers() async throws {
        let store = makeStore()
        let source = try await store.createConversation(backend: "openclaw")
        _ = try await store.appendMessage(
            role: "user", text: "summarize this", conversationID: source.id,
            sourceDevice: "phone", fileTransferLaneID: Self.laneA,
            attachments: [serverFileDraft()]
        )

        let clone = try await store.cloneConversation(
            id: source.id, toBackend: "hermes", targetFileLaneID: Self.laneB
        )
        let cloned = try await store.fetchMessages(for: clone.conversation.id)
        let userTurn = try XCTUnwrap(cloned.first)
        let attachment = try XCTUnwrap(userTurn.attachments.first)

        XCTAssertTrue(attachment.isServerReference,
                      "The row SURVIVES as a tombstone — dropping it would let the new gateway read the request with no file AND no notice that one was attached.")
        XCTAssertNil(attachment.storedKey,
                     "A key minted on another lane is meaningless here and must never be carried.")
        XCTAssertNil(userTurn.fileTransferLaneID,
                     "With no key to authorize, the lane must not ride along either.")
        XCTAssertEqual(attachment.filename, "report.pdf",
                       "The tombstone still NAMES the file — that is its whole purpose.")
        XCTAssertNil(attachment.previewKind,
                     "Previews derive from bytes this thread cannot reach; keeping them would be a half-alive row.")
    }

    func testCloneDetachesServerReferenceWhenTargetHasNoLane() async throws {
        // Target gateway has no file transfer configured at all (nil lane).
        let store = makeStore()
        let source = try await store.createConversation(backend: "openclaw")
        _ = try await store.appendMessage(
            role: "user", text: "summarize this", conversationID: source.id,
            sourceDevice: "phone", fileTransferLaneID: Self.laneA,
            attachments: [serverFileDraft()]
        )

        let clone = try await store.cloneConversation(
            id: source.id, toBackend: "openrouter", targetFileLaneID: nil
        )
        let clonedRows = try await store.fetchMessages(for: clone.conversation.id)
        let attachment = try XCTUnwrap(clonedRows.first?.attachments.first)
        XCTAssertNil(attachment.storedKey)
    }

    func testCloneNeverEmitsStoredKeyWithoutOwningLane() async throws {
        // THE INVARIANT. A dual-route inline image carries a storedKey on an
        // otherwise ordinary image row, so this is not a server-file-only
        // concern: `RetryFileReferenceResolver.hasRequiredStoredKeys` looks at
        // ANY non-empty key, and a key whose lane cannot be proven makes the
        // whole turn refuse to retry. If you are here because you want to carry
        // a key across a lane boundary: you cannot. Read the header.
        let store = makeStore()
        let source = try await store.createConversation(backend: "openclaw")
        _ = try await store.appendMessage(
            role: "user", text: "look", conversationID: source.id,
            sourceDevice: "phone", fileTransferLaneID: Self.laneA,
            attachments: [
                imageDraft(sequence: 0, storedKey: "img__photo.jpg"),
                serverFileDraft(sequence: 1)
            ]
        )
        _ = try await store.appendMessage(
            role: "agent", text: "made you a file", conversationID: source.id,
            sourceDevice: "phone", outputScanLaneID: Self.laneA,
            attachments: [serverFileDraft(name: "out.md", storedKey: "z__out.md")]
        )

        for targetLane in [Self.laneA, Self.laneB, nil] {
            let clone = try await store.cloneConversation(
                id: source.id, toBackend: "hermes", targetFileLaneID: targetLane
            )
            for message in try await store.fetchMessages(for: clone.conversation.id) {
                let ownerLane = message.role == "agent"
                    ? message.outputScanLaneID
                    : message.fileTransferLaneID
                let hasKey = message.attachments.contains { $0.storedKey?.isEmpty == false }
                if hasKey {
                    XCTAssertNotNil(ownerLane,
                                    "A cloned message carrying a storedKey MUST carry its owning lane (target lane: \(String(describing: targetLane))).")
                }
                if ownerLane != nil {
                    XCTAssertTrue(hasKey,
                                  "A cloned message must not carry an owning lane with no key to authorize.")
                }
            }
        }
    }

    func testCloneUsesOutputScanLaneForAgentRowOwnership() async throws {
        // Agent rows own their outputs via `outputScanLaneID`, user rows via
        // `fileTransferLaneID` — the same grain `ConverseRequest.fileLaneID`
        // uses. Getting this wrong would detach a reference the wire trusts.
        let store = makeStore()
        let source = try await store.createConversation(backend: "openclaw")
        _ = try await store.appendMessage(
            role: "user", text: "make me a file", conversationID: source.id, sourceDevice: "phone"
        )
        try await Task.sleep(nanoseconds: 5_000_000)
        _ = try await store.appendMessage(
            role: "agent", text: "done", conversationID: source.id,
            sourceDevice: "phone", outputScanLaneID: Self.laneA,
            attachments: [serverFileDraft(name: "out.md", storedKey: "z__out.md")]
        )

        let clone = try await store.cloneConversation(
            id: source.id, toBackend: "hermes", targetFileLaneID: Self.laneA
        )
        let clonedRows = try await store.fetchMessages(for: clone.conversation.id)
        let agentRow = try XCTUnwrap(clonedRows.first { $0.role == "agent" })
        XCTAssertEqual(agentRow.attachments.first?.storedKey, "z__out.md",
                       "Same lane → the agent's output file is still reachable and must be preserved.")
        XCTAssertEqual(agentRow.outputScanLaneID, Self.laneA)
        XCTAssertEqual(agentRow.outputScanDone, true,
                       "A preserved output is already scanned — re-arming would re-probe the file server for a file it has already adopted.")
    }

    func testCloneNeverArmsOutputScanOnDetachedAgentTurns() async throws {
        let store = makeStore()
        let source = try await store.createConversation(backend: "openclaw")
        _ = try await store.appendMessage(
            role: "user", text: "make me a file", conversationID: source.id, sourceDevice: "phone"
        )
        try await Task.sleep(nanoseconds: 5_000_000)
        _ = try await store.appendMessage(
            role: "agent", text: "done", conversationID: source.id,
            sourceDevice: "phone", outputScanLaneID: Self.laneA,
            attachments: [serverFileDraft(name: "out.md", storedKey: "z__out.md")]
        )

        let clone = try await store.cloneConversation(
            id: source.id, toBackend: "hermes", targetFileLaneID: Self.laneB
        )
        let clonedRows = try await store.fetchMessages(for: clone.conversation.id)
        let agentRow = try XCTUnwrap(clonedRows.first { $0.role == "agent" })
        XCTAssertNil(agentRow.outputScanLaneID,
                     "A detached agent row must not be probed against the NEW gateway's file server for a file the OLD agent wrote.")
        XCTAssertNil(agentRow.outputScanDone)
    }

    // MARK: - The trailing turn

    func testCloneStampsTrailingUserTurnFailedWithNoClassification() async throws {
        let store = makeStore()
        let source = try await store.createConversation(backend: "openclaw")
        let userTurn = try await store.appendMessage(
            role: "user", text: "please check those two files",
            conversationID: source.id, sourceDevice: "mac", status: "sending"
        )
        await store.failTurn(
            messageID: userTurn.id,
            classification: ConversationStore.TurnFailureClassification(
                failureCode: AppError.remoteAgentTimeout.errorCode,
                wireCode: nil,
                hadHistoryImages: false
            )
        )

        let clone = try await store.cloneConversation(id: source.id, toBackend: "hermes")
        let clonedRows = try await store.fetchMessages(for: clone.conversation.id)
        let cloned = try XCTUnwrap(clonedRows.first)

        XCTAssertEqual(cloned.status, "failed",
                       "A trailing user turn has no reply in the clone and never will unless something acts — `failed` is the affordance-bearing state.")
        XCTAssertNil(cloned.failureCode,
                     "A verdict rendered by the OLD gateway must not govern the new one — `retry` re-asserts a stored terminal code and would refuse to dispatch forever.")
        XCTAssertNil(cloned.failureWireCode)
        XCTAssertEqual(clone.continuationMessageID, cloned.id,
                       "The caller needs the cloned row's id to continue it.")
        XCTAssertEqual(clone.trailingSourceStatus, "failed",
                       "The SOURCE row's status decides whether continuing is safe.")
    }

    func testCloneReportsInFlightSourceStatusSoCallerCanRefuseToAutoContinue() async throws {
        // A source turn still `sending` may yet land on the old gateway. The
        // clone still normalizes it to `failed` (the user needs an affordance),
        // but reports `sending` so the caller does NOT fire it automatically —
        // that would run the same action on two gateways at once.
        let store = makeStore()
        let source = try await store.createConversation(backend: "openclaw")
        _ = try await store.appendMessage(
            role: "user", text: "delete the old backups",
            conversationID: source.id, sourceDevice: "mac", status: "sending"
        )

        let clone = try await store.cloneConversation(id: source.id, toBackend: "hermes")
        XCTAssertEqual(clone.trailingSourceStatus, "sending")
        let clonedRows = try await store.fetchMessages(for: clone.conversation.id)
        let cloned = try XCTUnwrap(clonedRows.first)
        XCTAssertEqual(cloned.status, "failed",
                       "Still surfaced as actionable — the user may fire it deliberately.")
    }

    func testCloneLeavesTrailingAgentTurnUnmarked() async throws {
        let store = makeStore()
        let source = try await store.createConversation(backend: "openclaw")
        _ = try await store.appendMessage(
            role: "user", text: "hi", conversationID: source.id, sourceDevice: "phone"
        )
        try await Task.sleep(nanoseconds: 5_000_000)
        _ = try await store.appendMessage(
            role: "agent", text: "hello", conversationID: source.id, sourceDevice: "phone"
        )

        let clone = try await store.cloneConversation(id: source.id, toBackend: "hermes")
        XCTAssertNil(clone.continuationMessageID,
                     "A thread that ends on a reply is not awaiting anything — the fork stays a fork.")
        for message in try await store.fetchMessages(for: clone.conversation.id) {
            XCTAssertNil(message.status)
        }
    }

    func testCloneNormalizesMidThreadFailedAndSendingToNil() async throws {
        let store = makeStore()
        let source = try await store.createConversation(backend: "openclaw")
        let first = try await store.appendMessage(
            role: "user", text: "one", conversationID: source.id,
            sourceDevice: "phone", status: "sending"
        )
        await store.markPendingUserTurn(messageID: first.id, to: "failed")
        try await Task.sleep(nanoseconds: 5_000_000)
        _ = try await store.appendMessage(
            role: "agent", text: "reply one", conversationID: source.id, sourceDevice: "phone"
        )
        try await Task.sleep(nanoseconds: 5_000_000)
        _ = try await store.appendMessage(
            role: "user", text: "two", conversationID: source.id,
            sourceDevice: "phone", status: "sending"
        )
        try await Task.sleep(nanoseconds: 5_000_000)
        _ = try await store.appendMessage(
            role: "agent", text: "reply two", conversationID: source.id, sourceDevice: "phone"
        )

        let clone = try await store.cloneConversation(id: source.id, toBackend: "hermes")
        for message in try await store.fetchMessages(for: clone.conversation.id) {
            XCTAssertNil(message.status,
                         "Mid-thread rows already have replies — an un-actionable Retry chip above an existing answer would be nonsense.")
        }
        XCTAssertNil(clone.continuationMessageID)
    }

    // MARK: - Scale

    func testCloneCarriesAttachmentsOnEveryTurnOfALongThread() async throws {
        // Locks per-turn attachment survival at depth — NOT the transaction's
        // memory ceiling. These fixtures are 512 bytes; a clone's real peak is
        // driven by megabyte photos held on both sides of one `save()`, which a
        // unit test cannot meaningfully assert. That risk is mitigated in the
        // copy loop (`context.refresh` re-faults each source row) and belongs to
        // instrument-based measurement, not here — do not let this test's
        // greenness read as coverage of it.
        let store = makeStore()
        let source = try await store.createConversation(backend: "openclaw")
        for index in 0..<60 {
            _ = try await store.appendMessage(
                role: "user", text: "turn \(index)", conversationID: source.id,
                sourceDevice: "phone", attachments: [imageDraft()]
            )
        }

        let clone = try await store.cloneConversation(id: source.id, toBackend: "hermes")
        let cloned = try await store.fetchMessages(for: clone.conversation.id)
        XCTAssertEqual(cloned.count, 60)
        XCTAssertTrue(cloned.allSatisfy { $0.attachments.count == 1 },
                      "Every turn's attachment must survive an image-heavy clone.")
        let lastCloned = try XCTUnwrap(cloned.last)
        let lastBytes = try await store.loadAttachmentData(for: lastCloned.id)
        XCTAssertEqual(lastBytes.count, 1, "Bytes must be intact on the last copied turn, not just the first.")
    }

    // MARK: - Flags and malformed rows

    func testCloneCarriesHideEarlierPhotos() async throws {
        // A SAFETY switch the user threw after a gateway choked on this thread's
        // images. Load-bearing now that attachments deep-copy AND the clone may
        // auto-continue: a reset flag would replay the exact image payload the
        // user suppressed, on the first request, unprompted.
        let store = makeStore()
        let source = try await store.createConversation(backend: "openclaw")
        _ = try await store.appendMessage(
            role: "user", text: "look", conversationID: source.id,
            sourceDevice: "phone", attachments: [imageDraft()]
        )
        await store.setHideEarlierPhotos(conversationID: source.id, true)

        let clone = try await store.cloneConversation(id: source.id, toBackend: "hermes")
        let clonedConvoFetch = try await store.fetchConversation(id: clone.conversation.id)
        let clonedConvo = try XCTUnwrap(clonedConvoFetch)
        XCTAssertTrue(clonedConvo.hideEarlierPhotos,
                      "The photo-suppression switch must survive the fork.")
    }

    func testCloneKeepsATrailingUserTurnWhoseTextIsNil() async throws {
        // `Message.text` is optional in the model, so a partially-synced
        // CloudKit row can arrive with nil text. Skipping it would drop the
        // user's actual last message AND its attachments from the fork, and
        // aim the continuation at the agent reply before it.
        let store = makeStore()
        let source = try await store.createConversation(backend: "openclaw")
        let turn = try await store.appendMessage(
            role: "user", text: "placeholder", conversationID: source.id,
            sourceDevice: "phone", attachments: [imageDraft()]
        )
        try await store.debugClearMessageText(messageID: turn.id)

        let clone = try await store.cloneConversation(id: source.id, toBackend: "hermes")
        let cloned = try await store.fetchMessages(for: clone.conversation.id)
        XCTAssertEqual(cloned.count, 1, "A nil-text row must still be cloned, not skipped.")
        XCTAssertEqual(cloned.first?.text, "", "Nil text coalesces, matching the read path.")
        XCTAssertEqual(cloned.first?.attachments.count, 1,
                       "Skipping the row would have silently dropped its attachments too.")
        XCTAssertEqual(clone.continuationMessageID, cloned.first?.id,
                       "The continuation must still target the user's real last turn.")
    }

    func testCloneNeverMarksADeliveredTrailingTurnFailed() async throws {
        // `sent` is only written when a reply lands, so that turn provably
        // reached its gateway. A missing agent row is a lost/partially-synced
        // reply — stamping it `failed` would put "this message wasn't
        // delivered" under a message that was.
        let store = makeStore()
        let source = try await store.createConversation(backend: "openclaw")
        let turn = try await store.appendMessage(
            role: "user", text: "delivered", conversationID: source.id,
            sourceDevice: "phone", status: "sending"
        )
        try await store.updateStatus(messageID: turn.id, status: "sent")

        let clone = try await store.cloneConversation(id: source.id, toBackend: "hermes")
        let clonedRows = try await store.fetchMessages(for: clone.conversation.id)
        let cloned = try XCTUnwrap(clonedRows.first)
        XCTAssertNil(cloned.status,
                     "A delivered turn must not be re-stamped as undelivered.")
        XCTAssertNil(clone.continuationMessageID,
                     "…and there is nothing to auto-continue.")
    }

    // MARK: - Errors + binding

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
        let store = makeStore()
        let source = try await store.createConversation(backend: "openclaw")
        _ = try await store.appendMessage(
            role: "user", text: "hi", conversationID: source.id, sourceDevice: "phone"
        )

        let customRaw = "custom_8E4E2D0A-1B7C-4F4E-9D1A-2C3B4A5D6E7F"
        let clone = try await store.cloneConversation(id: source.id, toBackend: customRaw)

        XCTAssertEqual(clone.conversation.backend, customRaw,
                       "A custom-gateway rawString must be stored verbatim on the clone.")
        let refetchedFetch = try await store.fetchConversation(id: clone.conversation.id)
        let refetched = try XCTUnwrap(refetchedFetch)
        XCTAssertEqual(refetched.backend, customRaw)
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
        let convo = try await store.createConversation(backend: "openclaw")
        _ = try await store.appendMessage(
            role: "user", text: "unrelated", conversationID: convo.id, sourceDevice: "phone"
        )

        let owner = try await store.conversationID(forMessageID: UUID())
        XCTAssertNil(owner, "An unknown message id must resolve to nil, not throw.")
    }
}
