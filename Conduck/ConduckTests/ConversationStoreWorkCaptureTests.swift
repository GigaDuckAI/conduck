// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// ConversationStoreWorkCaptureTests.swift

import XCTest
@testable import Conduck

final class ConversationStoreWorkCaptureTests: XCTestCase {
    func testJustAppendedMessageCopiesLocalSourcesAndReferencesGatewayFiles() async throws {
        let store = ConversationStore(inMemory: true)
        let conversation = try await store.createConversation(backend: "hermes")
        let imageBytes = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let textBytes = Data("source notes".utf8)

        let image = AttachmentDraft(
            mimeType: "image/jpeg",
            filename: "diagram.jpg",
            data: imageBytes,
            thumbnailData: Data([0x01]),
            width: 10,
            height: 8,
            byteSize: imageBytes.count,
            sequence: 0
        )
        let text = AttachmentDraft(
            mimeType: "text/plain",
            filename: "notes.txt",
            data: textBytes,
            thumbnailData: nil,
            width: 0,
            height: 0,
            byteSize: textBytes.count,
            sequence: 1
        )
        var remote = AttachmentDraft(
            mimeType: "application/pdf",
            filename: "gateway-report.pdf",
            data: Data(),
            thumbnailData: nil,
            width: 0,
            height: 0,
            byteSize: 2_048,
            sequence: 2
        )
        remote.isServerReference = true
        remote.storedKey = "private-value-that-must-not-be-copied"

        // Deliberately pass the lightweight value returned by appendMessage.
        // Its attachment ids are not the persisted row ids, so capture must
        // resolve the authoritative turn itself before copying bytes.
        let appended = try await store.appendMessage(
            role: "user",
            text: "  Compare the evidence and recommend a direction.  ",
            conversationID: conversation.id,
            sourceDevice: "test",
            attachments: [image, text, remote]
        )
        let receipt = try await store.captureMessageToWork(
            appended,
            conversationID: conversation.id
        )
        XCTAssertEqual(receipt.itemID, Constants.workboardDeskItemID)
        let itemValue = try await store.fetchWorkItem(id: receipt.itemID)
        let item = try XCTUnwrap(itemValue)

        // The desk owns no brief: the turn's words are a card, not an objective,
        // and nothing about the conversation is written to the owner row.
        XCTAssertNil(item.captureEnvelopeID)
        XCTAssertEqual(item.content.title, "")
        XCTAssertEqual(item.content.objective, "")
        XCTAssertNil(item.content.preferredGatewayRef)
        XCTAssertEqual(item.state, .draft)
        XCTAssertEqual(receipt.addedMaterialCount, 4)
        XCTAssertEqual(receipt.referencedOnlyMaterialCount, 1)
        XCTAssertEqual(receipt.failedMaterialCount, 0)
        XCTAssertFalse(receipt.wasAlreadyCaptured)

        let turnMaterial = try XCTUnwrap(item.materials.first { $0.id == appended.id })
        let imageMaterial = try XCTUnwrap(item.materials.first { $0.filename == "diagram.jpg" })
        let textMaterial = try XCTUnwrap(item.materials.first { $0.filename == "notes.txt" })
        let remoteMaterial = try XCTUnwrap(item.materials.first { $0.title == "gateway-report.pdf" })
        let copiedImage = try await store.loadWorkMaterialPayload(id: imageMaterial.id)
        let copiedText = try await store.loadWorkMaterialPayload(id: textMaterial.id)

        XCTAssertEqual(turnMaterial.kind, .note)
        XCTAssertEqual(turnMaterial.textContent, "Compare the evidence and recommend a direction.")
        XCTAssertEqual(imageMaterial.kind, .image)
        XCTAssertEqual(textMaterial.kind, .file)
        XCTAssertEqual(copiedImage, imageBytes)
        XCTAssertEqual(copiedText, textBytes)
        XCTAssertEqual(remoteMaterial.kind, .note)
        XCTAssertEqual(remoteMaterial.storageMode, .metadataOnly)
        XCTAssertFalse(remoteMaterial.hasPayload)
        XCTAssertTrue(remoteMaterial.textContent?.contains("gateway-report.pdf") == true)
        XCTAssertFalse(remoteMaterial.textContent?.contains(remote.storedKey!) == true)
    }

    func testRepeatedAndConcurrentCaptureProduceOneItemAndOneMaterialSet() async throws {
        let store = ConversationStore(inMemory: true)
        let conversation = try await store.createConversation(backend: "openclaw")
        let payload = Data("one source".utf8)
        let message = try await store.appendMessage(
            role: "user",
            text: "Research this",
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

        let receipts = try await withThrowingTaskGroup(
            of: WorkMessageCaptureReceipt.self,
            returning: [WorkMessageCaptureReceipt].self
        ) { group in
            for _ in 0..<10 {
                group.addTask {
                    try await store.captureMessageToWork(message, conversationID: conversation.id)
                }
            }
            var values: [WorkMessageCaptureReceipt] = []
            for try await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(Set(receipts.map(\.itemID)), [Constants.workboardDeskItemID])
        XCTAssertEqual(receipts.filter { !$0.wasAlreadyCaptured }.count, 1)
        XCTAssertEqual(receipts.reduce(0) { $0 + $1.addedMaterialCount }, 2)
        let items = try await store.fetchWorkItems()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, Constants.workboardDeskItemID)
        XCTAssertEqual(items.first?.materials.count, 2)
    }

    func testZeroByteLocalFileRemainsARealAvailableSource() async throws {
        let store = ConversationStore(inMemory: true)
        let conversation = try await store.createConversation(backend: "hermes")
        let message = try await store.appendMessage(
            role: "user",
            text: "Explain this empty sentinel",
            conversationID: conversation.id,
            sourceDevice: "test",
            attachments: [
                AttachmentDraft(
                    mimeType: "text/plain",
                    filename: "empty.txt",
                    data: Data(),
                    thumbnailData: nil,
                    width: 0,
                    height: 0,
                    byteSize: 0,
                    sequence: 0
                )
            ]
        )

        let receipt = try await store.captureMessageToWork(message, conversationID: conversation.id)
        let itemValue = try await store.fetchWorkItem(id: receipt.itemID)
        let material = try XCTUnwrap(
            try XCTUnwrap(itemValue).materials.first { $0.filename == "empty.txt" }
        )
        let copied = try await store.loadWorkMaterialPayload(id: material.id)

        XCTAssertEqual(receipt.referencedOnlyMaterialCount, 0)
        XCTAssertEqual(material.kind, .file)
        XCTAssertEqual(material.availability, .availableLocally)
        XCTAssertEqual(copied, Data())
    }

    /// The chat composer caps nothing, so a pasted log is an ordinary user turn.
    /// Capture keeps every character of it on the card rather than failing the
    /// whole "Add to Work" on a length the person never saw — an agent reply of
    /// any size already succeeds this way.
    func testAnOversizedUserTurnIsCapturedAsAMaterialRatherThanRefused() async throws {
        let store = ConversationStore(inMemory: true)
        let conversation = try await store.createConversation(backend: "hermes")
        let pastedLog = "Line one of the log\n"
            + String(repeating: "x", count: WorkItemContentLimits.maximumFieldCharacters)
        let message = try await store.appendMessage(
            role: "user",
            text: pastedLog,
            conversationID: conversation.id,
            sourceDevice: "test"
        )

        let receipt = try await store.captureMessageToWork(message, conversationID: conversation.id)
        let itemValue = try await store.fetchWorkItem(id: receipt.itemID)
        let item = try XCTUnwrap(itemValue)

        XCTAssertEqual(receipt.addedMaterialCount, 1)
        XCTAssertEqual(receipt.failedMaterialCount, 0)
        XCTAssertEqual(item.content.objective, "")
        XCTAssertEqual(item.content.title, "")

        let material = try XCTUnwrap(item.materials.first)
        XCTAssertEqual(material.id, message.id)
        XCTAssertEqual(material.kind, .note)
        XCTAssertEqual(material.sequence, 0)
        XCTAssertEqual(material.textContent, pastedLog)
    }

    /// Both surfaces that render a capture/autosave failure print
    /// `error.localizedDescription` verbatim. Without `LocalizedError` that is
    /// the bridged NSError fallback, which names neither the cause nor the fix.
    func testTheContentBoundRefusalCarriesCopyAPersonCanActOn() {
        let copy = WorkboardStoreError.contentTooLong.localizedDescription

        XCTAssertFalse(
            copy.contains("couldn’t be completed") || copy.contains("WorkboardStoreError"),
            "The store bound must not surface as the bridged NSError fallback"
        )
        XCTAssertTrue(
            copy.localizedStandardContains("shorten"),
            "The refusal has to name the one action that clears it"
        )
    }
}
