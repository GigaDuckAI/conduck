// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardChatCaptureTests.swift
//
// Chat → Work is a capture onto the one desk. These cases pin what that means
// where it is easy to regress: the turn's own identity is the card's identity
// (so a repeat is a no-op rather than a second card), the desk is the only
// Work item the lane ever writes, and an attachment that cannot be copied is
// reported rather than silently dropped.

import XCTest
@testable import Conduck

final class WorkboardChatCaptureTests: XCTestCase {
    func testCapturingATurnAppendsItToTheDeskUnderTheMessageIdentity() async throws {
        let store = ConversationStore(inMemory: true)
        let conversation = try await store.createConversation(backend: "hermes")
        let message = try await store.appendMessage(
            role: "user",
            text: "Draft the migration plan",
            conversationID: conversation.id,
            sourceDevice: "test"
        )

        let before = try await store.fetchWorkItems()
        XCTAssertTrue(before.isEmpty, "The desk row is created by the first capture, not before it")

        let receipt = try await store.captureMessageToWork(message, conversationID: conversation.id)

        XCTAssertEqual(receipt.itemID, Constants.workboardDeskItemID)
        XCTAssertEqual(receipt.addedMaterialCount, 1)
        XCTAssertEqual(receipt.failedMaterialCount, 0)
        XCTAssertFalse(receipt.wasAlreadyCaptured)

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        let card = try XCTUnwrap(desk.materials.first)
        XCTAssertEqual(desk.materials.count, 1)
        XCTAssertEqual(card.id, message.id, "The turn is the card, so a replay repairs it instead of adding one")
        XCTAssertEqual(card.workItemID, Constants.workboardDeskItemID)
        XCTAssertEqual(card.kind, .note)
        XCTAssertEqual(card.storageMode, .metadataOnly)
        XCTAssertEqual(card.textContent, "Draft the migration plan")
        XCTAssertEqual(card.sequence, 0)
    }

    func testASecondCaptureOfTheSameTurnReturnsTheExistingCardWithoutADuplicate() async throws {
        let store = ConversationStore(inMemory: true)
        let conversation = try await store.createConversation(backend: "hermes")
        let payload = Data("one source".utf8)
        let message = try await store.appendMessage(
            role: "user",
            text: "Keep this",
            conversationID: conversation.id,
            sourceDevice: "test",
            attachments: [
                AttachmentDraft(
                    mimeType: "text/plain",
                    filename: "source.txt",
                    data: payload,
                    thumbnailData: nil,
                    width: 0,
                    height: 0,
                    byteSize: payload.count,
                    sequence: 0
                )
            ]
        )

        let first = try await store.captureMessageToWork(message, conversationID: conversation.id)
        XCTAssertEqual(first.addedMaterialCount, 2)
        let afterFirstValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let stamps = try XCTUnwrap(afterFirstValue).materials.map(\.updatedAt)

        let second = try await store.captureMessageToWork(message, conversationID: conversation.id)

        XCTAssertTrue(second.wasAlreadyCaptured)
        XCTAssertEqual(second.itemID, Constants.workboardDeskItemID)
        XCTAssertEqual(second.addedMaterialCount, 0)
        XCTAssertEqual(second.referencedOnlyMaterialCount, 0)
        XCTAssertEqual(second.failedMaterialCount, 0)

        let items = try await store.fetchWorkItems()
        XCTAssertEqual(items.count, 1)
        let desk = try XCTUnwrap(items.first)
        XCTAssertEqual(desk.materials.count, 2)
        XCTAssertEqual(desk.materials.map(\.updatedAt), stamps, "A repeat rewrites nothing")

        let rows = await store._workMaterialRowsForTesting(id: message.id)
        XCTAssertEqual(rows.count, 1, "The turn keeps ONE physical card row")
        let copied = try await store.loadWorkMaterialPayload(
            id: try XCTUnwrap(desk.materials.first { $0.filename == "source.txt" }).id
        )
        XCTAssertEqual(copied, payload, "The attachment's bytes survive the repeat")
    }

    func testCaptureAppendsAfterTheCardsTheDeskAlreadyHolds() async throws {
        let store = ConversationStore(inMemory: true)
        _ = try await store.upsertDeskMaterial(
            WorkMaterialDraft(kind: .note, title: "Earlier", textContent: "collected earlier")
        )
        let conversation = try await store.createConversation(backend: "hermes")
        let message = try await store.appendMessage(
            role: "agent",
            text: "Here is the outline",
            conversationID: conversation.id,
            sourceDevice: "test"
        )

        _ = try await store.captureMessageToWork(message, conversationID: conversation.id)

        let items = try await store.fetchWorkItems()
        XCTAssertEqual(items.count, 1, "Chat → Work never opens a board of its own")
        let desk = try XCTUnwrap(items.first)
        XCTAssertEqual(desk.materials.count, 2)
        XCTAssertEqual(desk.materials.map(\.sequence), [0, 1])
        let card = try XCTUnwrap(desk.materials.first { $0.id == message.id })
        XCTAssertEqual(card.sequence, 1, "The captured turn lands at the end of the desk")
    }

    func testAttachmentsThatCannotBeCopiedAreReportedRatherThanDropped() async throws {
        let store = ConversationStore(inMemory: true)
        let conversation = try await store.createConversation(backend: "hermes")
        let textBytes = Data("source notes".utf8)
        let local = AttachmentDraft(
            mimeType: "text/plain",
            filename: "notes.txt",
            data: textBytes,
            thumbnailData: nil,
            width: 0,
            height: 0,
            byteSize: textBytes.count,
            sequence: 0
        )
        var remote = AttachmentDraft(
            mimeType: "application/pdf",
            filename: "gateway-report.pdf",
            data: Data(),
            thumbnailData: nil,
            width: 0,
            height: 0,
            byteSize: 2_048,
            sequence: 1
        )
        remote.isServerReference = true
        // Empty image bytes cannot render, so the payload loader skips them and
        // the card has to say so instead of promising a picture it lacks.
        let hollowImage = AttachmentDraft(
            mimeType: "image/png",
            filename: "screenshot.png",
            data: Data(),
            thumbnailData: nil,
            width: 0,
            height: 0,
            byteSize: 0,
            sequence: 2
        )
        let message = try await store.appendMessage(
            role: "user",
            text: "Three sources",
            conversationID: conversation.id,
            sourceDevice: "test",
            attachments: [local, remote, hollowImage]
        )

        let receipt = try await store.captureMessageToWork(message, conversationID: conversation.id)

        XCTAssertEqual(receipt.addedMaterialCount, 4)
        XCTAssertEqual(receipt.referencedOnlyMaterialCount, 2)
        XCTAssertEqual(receipt.failedMaterialCount, 0)

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        let copied = try XCTUnwrap(desk.materials.first { $0.filename == "notes.txt" })
        let referenced = try XCTUnwrap(desk.materials.first { $0.title == "gateway-report.pdf" })
        let uncopyable = try XCTUnwrap(desk.materials.first { $0.title == "screenshot.png" })

        XCTAssertEqual(copied.kind, .file)
        XCTAssertTrue(copied.hasPayload)
        XCTAssertEqual(referenced.kind, .note)
        XCTAssertFalse(referenced.hasPayload)
        XCTAssertTrue(referenced.textContent?.contains("gateway-report.pdf") == true)
        XCTAssertEqual(uncopyable.kind, .note)
        XCTAssertFalse(uncopyable.hasPayload)
        XCTAssertNotEqual(
            referenced.caption,
            uncopyable.caption,
            "A gateway file and a file this device could not read are different problems"
        )
    }

    func testCaptureMintsNoWorkItemOfItsOwn() async throws {
        let store = ConversationStore(inMemory: true)
        let first = try await store.createConversation(backend: "hermes")
        let second = try await store.createConversation(backend: "openclaw")
        let firstMessage = try await store.appendMessage(
            role: "user",
            text: "First turn",
            conversationID: first.id,
            sourceDevice: "test"
        )
        let secondMessage = try await store.appendMessage(
            role: "agent",
            text: "Second turn",
            conversationID: second.id,
            sourceDevice: "test"
        )

        _ = try await store.captureMessageToWork(firstMessage, conversationID: first.id)
        _ = try await store.captureMessageToWork(secondMessage, conversationID: second.id)

        let items = try await store.fetchWorkItems()
        XCTAssertEqual(items.map(\.id), [Constants.workboardDeskItemID])
        XCTAssertEqual(
            Set(try XCTUnwrap(items.first).materials.map(\.id)),
            [firstMessage.id, secondMessage.id]
        )
        let byTurnIdentity = try await store.fetchWorkItem(captureEnvelopeID: firstMessage.id)
        XCTAssertNil(byTurnIdentity, "A captured turn is a card, so no item carries it as capture identity")
    }

    // MARK: - Replay repairs rather than reports

    /// The desk already showing a card is not proof the card can be opened: the
    /// blob and the material row commit in different stores, so a crash between
    /// them — or an import that has not brought the bytes — leaves a card
    /// claiming a payload that is not there. Skipping an attachment on its id
    /// alone would report the turn as captured while the card stays unreadable
    /// for good, so a repeat republishes every attachment this device can still
    /// read and lets the store decide whether that is a repair or a no-op.
    func testRecapturingATurnRestagesAnAttachmentWhoseSyncedBytesAreGone() async throws {
        let store = ConversationStore(inMemory: true)
        let conversation = try await store.createConversation(backend: "hermes")
        let payload = Data("the source the card promises".utf8)
        let message = try await store.appendMessage(
            role: "user",
            text: "Keep this",
            conversationID: conversation.id,
            sourceDevice: "test",
            attachments: [
                AttachmentDraft(
                    mimeType: "text/plain",
                    filename: "source.txt",
                    data: payload,
                    thumbnailData: nil,
                    width: 0,
                    height: 0,
                    byteSize: payload.count,
                    sequence: 0
                )
            ]
        )
        _ = try await store.captureMessageToWork(message, conversationID: conversation.id)
        let capturedValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let captured = try XCTUnwrap(capturedValue)
        let attachmentCard = try XCTUnwrap(captured.materials.first { $0.filename == "source.txt" })
        XCTAssertEqual(attachmentCard.storageMode, .syncedPayload)
        XCTAssertEqual(attachmentCard.availability, .synced)

        let dropped = await store._deleteWorkMaterialBlobRowsForTesting(materialID: attachmentCard.id)
        XCTAssertEqual(dropped, 1)
        let damagedValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let damaged = try XCTUnwrap(
            try XCTUnwrap(damagedValue).materials.first { $0.id == attachmentCard.id }
        )
        XCTAssertEqual(damaged.availability, .syncedPending)
        XCTAssertFalse(damaged.hasPayload)

        let receipt = try await store.captureMessageToWork(message, conversationID: conversation.id)

        XCTAssertTrue(receipt.wasAlreadyCaptured)
        XCTAssertEqual(receipt.addedMaterialCount, 0,
                       "a repaired card was already on the desk, so nothing was added")
        XCTAssertEqual(receipt.referencedOnlyMaterialCount, 0)
        XCTAssertEqual(receipt.failedMaterialCount, 0)

        let repairedValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let deskAfter = try XCTUnwrap(repairedValue)
        XCTAssertEqual(deskAfter.materials.count, 2, "the repair is the same card, not a second one")
        let repaired = try XCTUnwrap(deskAfter.materials.first { $0.id == attachmentCard.id })
        XCTAssertEqual(repaired.availability, .synced)
        let restored = try await store.loadWorkMaterialPayload(id: attachmentCard.id)
        XCTAssertEqual(restored, payload)
        let rows = await store._workMaterialRowsForTesting(id: attachmentCard.id)
        XCTAssertEqual(rows.count, 1)
    }

    // MARK: - Upgrade from a pre-desk build

    /// A build before the single desk minted one Work item per captured turn
    /// and hung the turn and its attachments off it. Those rows are kept, so a
    /// re-capture meets its own material ids under an owner that is not the
    /// desk: it has to adopt them, because reporting a failure would leave the
    /// person with a turn that can never be captured again.
    func testATurnCapturedByAnOlderBuildIsAdoptedOntoTheDeskRatherThanFailing() async throws {
        let store = ConversationStore(inMemory: true)
        let conversation = try await store.createConversation(backend: "hermes")
        let payload = Data("the attachment the older build copied".utf8)
        let message = try await store.appendMessage(
            role: "user",
            text: "Keep this turn",
            conversationID: conversation.id,
            sourceDevice: "test",
            attachments: [
                AttachmentDraft(
                    mimeType: "text/plain",
                    filename: "source.txt",
                    data: payload,
                    thumbnailData: nil,
                    width: 0,
                    height: 0,
                    byteSize: payload.count,
                    sequence: 0
                )
            ]
        )
        // The PERSISTED attachment identity — the record `appendMessage` hands
        // back mints its own, and the capture lane reads the stored rows.
        let localPayloads = try await store.loadLocalAttachmentPayloads(for: message.id)
        let attachmentID = try XCTUnwrap(localPayloads.keys.first)
        // Exactly what the pre-desk lane wrote: an item named by the turn, with
        // the turn and its attachment as materials under it.
        _ = try await store.createWorkItem(
            WorkItemDraft(
                id: message.id,
                captureEnvelopeID: message.id,
                content: WorkItemContent(title: "Keep this turn")
            )
        )
        _ = try await store.addWorkMaterial(
            WorkMaterialDraft(
                id: message.id,
                kind: .note,
                title: "Chat message",
                textContent: "Keep this turn",
                storageMode: .metadataOnly
            ),
            to: message.id
        )
        _ = try await store.addWorkMaterial(
            WorkMaterialDraft(
                id: attachmentID,
                kind: .file,
                title: "source.txt",
                filename: "source.txt",
                mimeType: "text/plain",
                payload: payload
            ),
            to: message.id
        )

        let receipt = try await store.captureMessageToWork(message, conversationID: conversation.id)

        XCTAssertEqual(receipt.failedMaterialCount, 0,
                       "a card an older build parked elsewhere is adopted, never reported as failed")
        XCTAssertEqual(receipt.addedMaterialCount, 2)
        XCTAssertEqual(receipt.itemID, Constants.workboardDeskItemID)
        XCTAssertFalse(receipt.wasAlreadyCaptured, "the desk itself held neither card")

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(Set(desk.materials.map(\.id)), [message.id, attachmentID])
        let turnRows = await store._workMaterialRowsForTesting(id: message.id)
        XCTAssertEqual(turnRows.count, 1, "adoption moves the row; it never publishes a second")
        let carried = try await store.loadWorkMaterialPayload(id: attachmentID)
        XCTAssertEqual(carried, payload, "an adopted attachment keeps the bytes it already had")

        let legacyValue = try await store.fetchWorkItem(id: message.id)
        let legacy = try XCTUnwrap(legacyValue, "the item the older build minted is never deleted")
        XCTAssertTrue(legacy.materials.isEmpty)
    }
}
