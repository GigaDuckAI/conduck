// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkCaptureDrainerTests.swift
//
// End-to-end coverage for App-Group captures reaching the single Work desk:
// every envelope's note becomes a card, attachments land beside it, a named
// target is ignored rather than resolved, replay never doubles a material, and
// the queue is consumed only after everything the capture wrote reads back. The
// drainer has no transport dependency, and every assertion stays inside
// in-memory Core Data + temp files.

import XCTest
@testable import Conduck

final class WorkCaptureDrainerTests: XCTestCase {
    private var root: URL!

    /// Every store here mints a vault directory of its own that nothing else
    /// removes, and the attachment cases write real payload leaves into them;
    /// the fixture empties them when the class is done. No case leaves a task
    /// running, so teardown cannot race a vault operation.
    private let isolated = IsolatedWorkStores()

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-work-drainer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        await isolated.cleanUp()
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        try await super.tearDown()
    }

    // MARK: - Everything lands on the desk

    /// The desk is created by the capture itself. A menu-bar or GigaAction
    /// envelope carries no target and the store holds nothing at all, and the
    /// note still has to become a visible card: it is the whole capture.
    func testTheFirstTargetlessCaptureBecomesAMaterialOnAFreshDesk() async throws {
        let store = isolated.make()
        let before = try await store.fetchWorkItems()
        XCTAssertTrue(before.isEmpty, "nothing exists before the first capture")

        let envelope = WorkCaptureEnvelope(
            note: "Ask the harbour office about the winter timetable",
            source: .app,
            entries: []
        )
        try publish(envelope)

        let report = try await makeDrainer(store: store).drainAvailableCaptures()
        let desk = try await unwrapDesk(store)

        XCTAssertEqual(report.importedCaptureCount, 1)
        XCTAssertEqual(report.importedMaterialCount, 1,
                       "the note of a targetless capture is a material, not a discarded label")
        XCTAssertEqual(desk.id, Constants.workboardDeskItemID)
        XCTAssertEqual(desk.materials.count, 1)
        let note = try XCTUnwrap(desk.materials.first)
        XCTAssertEqual(note.id, envelope.id)
        XCTAssertEqual(note.kind, .note)
        XCTAssertEqual(note.title, "Share note")
        XCTAssertEqual(note.textContent, "Ask the harbour office about the winter timetable")
    }

    /// Two targetless captures from different surfaces converge on one desk
    /// rather than each minting a board of their own.
    func testCapturesFromDifferentSurfacesShareTheOneDesk() async throws {
        let store = isolated.make()
        let fromShareSheet = WorkCaptureEnvelope(
            note: "From the share sheet",
            source: .shareExtension,
            entries: []
        )
        let fromTheApp = WorkCaptureEnvelope(note: "From the menu bar", source: .app, entries: [])
        try publish(fromShareSheet)
        try publish(fromTheApp)

        _ = try await makeDrainer(store: store).drainAvailableCaptures()

        let items = try await store.fetchWorkItems()
        XCTAssertEqual(items.map(\.id), [Constants.workboardDeskItemID])
        let desk = try XCTUnwrap(items.first)
        XCTAssertEqual(Set(desk.materials.map(\.id)), [fromShareSheet.id, fromTheApp.id])
    }

    /// The note and every attachment are cards side by side, and the file's
    /// bytes are readable from the desk once the queue copy is gone. A payload
    /// this small is within the sync ceiling, so it rides private CloudKit
    /// rather than staying in the device-local vault.
    func testTheNoteAndEveryAttachmentLandOnTheDeskTogether() async throws {
        let store = isolated.make()
        let payload = Data("the shared screenshot".utf8)
        let imageID = UUID()
        let textID = UUID()
        let envelope = WorkCaptureEnvelope(
            note: "Compare this with the current plan",
            source: .shareExtension,
            entries: [
                .init(id: textID, kind: .text, sequence: 0, text: "Source excerpt"),
                .init(
                    id: imageID,
                    kind: .image,
                    sequence: 1,
                    relativePath: "payload-000.png",
                    displayName: "IMG.png",
                    mimeType: "image/png",
                    byteCount: Int64(payload.count)
                ),
            ]
        )
        try publish(envelope, payloads: ["payload-000.png": payload])

        let report = try await makeDrainer(store: store).drainAvailableCaptures()
        let desk = try await unwrapDesk(store)

        XCTAssertEqual(report.importedMaterialCount, 3)
        XCTAssertEqual(Set(desk.materials.map(\.id)), [envelope.id, textID, imageID])
        XCTAssertEqual(desk.materials.map(\.sequence), [0, 1, 2],
                       "the desk ranks the note first, then the entries in captured order")
        let image = try XCTUnwrap(desk.materials.first { $0.id == imageID })
        XCTAssertEqual(image.kind, .image)
        XCTAssertEqual(image.availability, .synced)
        let storedBytes = try await store.loadWorkMaterialPayload(id: imageID)
        XCTAssertEqual(storedBytes, payload)
    }

    /// `targetWorkItemID` survives in the envelope because the share extension
    /// cannot be taught the desk from its sandbox, but nothing honours it: an
    /// item that still exists is left exactly as it was.
    func testANamedTargetIsIgnoredAndLeftUntouched() async throws {
        let store = isolated.make()
        let other = try await store.createWorkItem(WorkItemDraft(content: WorkItemContent(
            title: "Launch",
            objective: "Prepare the launch plan",
            context: "Original context"
        )))
        let envelope = WorkCaptureEnvelope(
            note: "Please compare this with the current plan",
            source: .shareExtension,
            targetWorkItemID: other.id,
            entries: [.init(kind: .url, sequence: 0, text: "https://example.com/source")]
        )
        try publish(envelope)

        _ = try await makeDrainer(store: store).drainAvailableCaptures()
        let untouchedValue = try await store.fetchWorkItem(id: other.id)
        let untouched = try XCTUnwrap(untouchedValue)
        let desk = try await unwrapDesk(store)

        XCTAssertTrue(untouched.materials.isEmpty,
                      "a capture never appends to a named item; Work is one desk")
        XCTAssertEqual(untouched.content.title, "Launch")
        XCTAssertEqual(untouched.content.objective, "Prepare the launch plan")
        XCTAssertEqual(untouched.content.context, "Original context")
        XCTAssertEqual(desk.materials.count, 2)
        XCTAssertTrue(desk.materials.contains { $0.textContent == "Please compare this with the current plan" })
        XCTAssertTrue(desk.materials.contains { $0.urlString == "https://example.com/source" })
    }

    /// A target the store has never held is not a special case: the capture
    /// takes the one path every capture takes, and no item is minted to carry
    /// the envelope.
    func testAnUnknownTargetStillLandsOnTheDesk() async throws {
        let store = isolated.make()
        let envelope = WorkCaptureEnvelope(
            note: "Keep this idea",
            source: .shareExtension,
            targetWorkItemID: UUID(),
            entries: []
        )
        try publish(envelope)

        _ = try await makeDrainer(store: store).drainAvailableCaptures()
        let desk = try await unwrapDesk(store)
        let mintedByEnvelope = try await store.fetchWorkItem(captureEnvelopeID: envelope.id)

        XCTAssertEqual(desk.materials.map(\.textContent), ["Keep this idea"])
        XCTAssertNil(mintedByEnvelope,
                     "the drainer resolves the desk; it never mints an item for an envelope")
        let items = try await store.fetchWorkItems()
        XCTAssertEqual(items.map(\.id), [Constants.workboardDeskItemID])
    }

    // MARK: - Replay

    func testReplayingTheSameEnvelopeYieldsOneMaterialSet() async throws {
        let store = isolated.make()
        let entryID = UUID()
        let envelope = WorkCaptureEnvelope(
            note: "Append once",
            source: .shareExtension,
            entries: [.init(id: entryID, kind: .text, sequence: 0, text: "One source")]
        )

        try publish(envelope)
        let drainer = makeDrainer(store: store)
        let first = try await drainer.drainAvailableCaptures()
        try publish(envelope)
        let replay = try await drainer.drainAvailableCaptures()
        let desk = try await unwrapDesk(store)

        XCTAssertEqual(first.importedCaptureCount, 1)
        XCTAssertEqual(first.replayedCaptureCount, 0)
        XCTAssertEqual(replay.replayedCaptureCount, 1,
                       "a capture whose ids are already on the desk is reported as a replay")
        XCTAssertEqual(replay.importedCaptureCount, 0)
        XCTAssertEqual(Set(desk.materials.map(\.id)), [envelope.id, entryID])
        XCTAssertEqual(desk.materials.count, 2, "replay repairs the same cards, it never adds more")
    }

    /// The upgrade shape a build before the single desk left behind when the
    /// person picked a destination: the drain appended straight onto the item
    /// they chose and wrote nothing on that owner row, so the envelope id names
    /// nothing there. Only the envelope's own target accounts for those rows,
    /// which is why the drainer carries a target it never honours as a
    /// destination — without it the replay is refused on every attempt for ever
    /// and the capture can never be acknowledged.
    func testAPartiallyDrainedTargetedCaptureReplaysOntoTheDesk() async throws {
        let store = isolated.make()
        let entryID = UUID()
        let chosen = try await store.createWorkItem(WorkItemDraft(content: WorkItemContent(
            title: "Launch",
            objective: "Prepare the launch plan"
        )))
        // What the pre-desk drain wrote: the entry's own id, under the item the
        // person selected, with the owner row left as it was.
        _ = try await store.addWorkMaterial(
            WorkMaterialDraft(
                id: entryID,
                kind: .note,
                title: "Shared text",
                textContent: "One source",
                storageMode: .metadataOnly
            ),
            to: chosen.id
        )
        let envelope = WorkCaptureEnvelope(
            note: "Compare this with the plan",
            source: .shareExtension,
            targetWorkItemID: chosen.id,
            entries: [.init(id: entryID, kind: .text, sequence: 0, text: "One source")]
        )
        try publish(envelope)

        let report = try await makeDrainer(store: store).drainAvailableCaptures()

        XCTAssertEqual(report.replayedCaptureCount + report.importedCaptureCount, 1,
                       "the replay completes rather than being refused")
        let desk = try await unwrapDesk(store)
        XCTAssertEqual(Set(desk.materials.map(\.id)), [envelope.id, entryID],
                       "the stranded card is re-homed onto the desk beside the note")
        let leftBehindValue = try await store.fetchWorkItem(id: chosen.id)
        let leftBehind = try XCTUnwrap(leftBehindValue)
        XCTAssertTrue(leftBehind.materials.isEmpty,
                      "and it is re-homed, not copied")
        let pending = try await WorkCaptureInbox(baseURL: root).pendingCount()
        XCTAssertEqual(pending, 0, "a capture that can never adopt can never be acknowledged")
    }

    func testNoteIdentityNeverMasksAnEntryThatUsesTheEnvelopeID() async throws {
        let store = isolated.make()
        let envelopeID = UUID()
        let envelope = WorkCaptureEnvelope(
            id: envelopeID,
            note: "Visible note",
            source: .shareExtension,
            entries: [
                .init(id: envelopeID, kind: .text, sequence: 0, text: "Distinct source")
            ]
        )
        try publish(envelope)

        _ = try await makeDrainer(store: store).drainAvailableCaptures()
        let desk = try await unwrapDesk(store)

        XCTAssertEqual(desk.materials.count, 2)
        XCTAssertTrue(desk.materials.contains { $0.textContent == "Visible note" })
        XCTAssertTrue(desk.materials.contains { $0.textContent == "Distinct source" })
        XCTAssertEqual(Set(desk.materials.map(\.id)).count, 2)
    }

    // MARK: - Acknowledgement follows the write

    /// Acknowledgement is the only thing that deletes a capture's bytes, so it
    /// runs after — never before — the materials read back out of the store.
    func testTheQueueIsConsumedOnlyOnceTheMaterialsReadBackFromTheStore() async throws {
        let store = isolated.make()
        let payload = Data("bytes the queue may only drop afterwards".utf8)
        let envelope = WorkCaptureEnvelope(
            note: "With an attachment",
            source: .shareExtension,
            entries: [
                .init(
                    kind: .file,
                    sequence: 0,
                    relativePath: "payload-000.bin",
                    displayName: "notes.bin",
                    mimeType: "application/octet-stream",
                    byteCount: Int64(payload.count)
                )
            ]
        )
        try publish(envelope, payloads: ["payload-000.bin": payload])

        let inbox = WorkCaptureInbox(baseURL: root)
        let drainer = WorkCaptureDrainer(inbox: inbox, store: store, sourceDevice: "test-device")
        _ = try await drainer.drainAvailableCaptures()

        let desk = try await unwrapDesk(store)
        let entry = try XCTUnwrap(envelope.entries.first)
        XCTAssertEqual(Set(desk.materials.map(\.id)), [envelope.id, entry.id],
                       "every material the capture wrote reads back before the claim is consumed")
        let pending = try await inbox.pendingCount()
        XCTAssertEqual(pending, 0, "a durable import consumes its claim")
        let queueDirectory = root.appendingPathComponent(envelope.id.uuidString, isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: queueDirectory.path),
                       "acknowledgement removes the queue copy of the bytes")
        let fileBytes = try await store.loadWorkMaterialPayload(id: entry.id)
        XCTAssertEqual(fileBytes, payload, "the desk holds the bytes the queue gave up")
    }

    /// The drainer's byte-preserving promise: a persistence failure must put the
    /// claim BACK (`release`) rather than consume it (`acknowledge`), because the
    /// extension already moved the only copy of the payload into the queue.
    /// Swapping those two calls destroys a person's shared file on any transient
    /// write failure, and every other test here takes a path that succeeds.
    func testAPersistenceFailureReleasesTheClaimAndPreservesItsPayload() async throws {
        let store = isolated.make()

        let payload = Data("shared bytes that must survive".utf8)
        let unreadable = Data("bytes the store cannot read".utf8)
        let imageID = UUID()
        let envelope = WorkCaptureEnvelope(
            source: .shareExtension,
            entries: [
                .init(
                    id: imageID,
                    kind: .image,
                    sequence: 0,
                    relativePath: "payload-000.png",
                    displayName: "IMG.png",
                    mimeType: "image/png",
                    byteCount: Int64(payload.count)
                ),
                .init(
                    id: UUID(),
                    kind: .file,
                    sequence: 1,
                    relativePath: "payload-001.bin",
                    displayName: "REPORT.bin",
                    mimeType: "application/octet-stream",
                    byteCount: Int64(unreadable.count)
                ),
            ]
        )
        try publish(
            envelope,
            payloads: ["payload-000.png": payload, "payload-001.bin": unreadable]
        )
        // The inbox validator only STATS a leaf, so a mode-0 regular file passes
        // validation and fails where the bytes are actually read — a mid-import
        // write failure produced through the public API, with no store seam and
        // nothing a replay could mistake for a legitimate card.
        let queuedDirectory = root.appendingPathComponent(
            envelope.id.uuidString,
            isDirectory: true
        )
        let unreadableLeaf = queuedDirectory
            .appendingPathComponent("payload-001.bin", isDirectory: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0],
            ofItemAtPath: unreadableLeaf.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: unreadableLeaf.path
            )
        }

        let inbox = WorkCaptureInbox(baseURL: root)
        let drainer = WorkCaptureDrainer(inbox: inbox, store: store, sourceDevice: "test-device")
        do {
            _ = try await drainer.drainAvailableCaptures()
            XCTFail("An entry whose bytes cannot be read must fail the import")
        } catch {
            // Which error the store raised is not the subject; that the claim
            // went back rather than being consumed is.
        }

        let pending = try await inbox.pendingCount()
        XCTAssertEqual(pending, 1, "a failed import must return the capture to the queue, not consume it")
        let desk = try await unwrapDesk(store)
        XCTAssertEqual(desk.materials.map(\.id), [imageID],
                       "the card written before the failure stays; replay repairs the rest")
        let restored = root
            .appendingPathComponent(envelope.id.uuidString, isDirectory: true)
            .appendingPathComponent("payload-000.png", isDirectory: false)
        let restoredBytes = try Data(contentsOf: restored)
        XCTAssertEqual(restoredBytes, payload,
                       "the queue holds the only copy of a shared file until the import commits")
    }

    // MARK: - Helpers

    private func unwrapDesk(_ store: ConversationStore) async throws -> WorkItemRecord {
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        return try XCTUnwrap(deskValue, "every capture resolves the one desk")
    }

    private func makeDrainer(store: ConversationStore) -> WorkCaptureDrainer {
        WorkCaptureDrainer(
            inbox: WorkCaptureInbox(baseURL: root),
            store: store,
            sourceDevice: "test-device"
        )
    }

    private func publish(
        _ envelope: WorkCaptureEnvelope,
        payloads: [String: Data] = [:]
    ) throws {
        let directory = root.appendingPathComponent(envelope.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        for (relativePath, bytes) in payloads {
            try bytes.write(
                to: directory.appendingPathComponent(relativePath, isDirectory: false),
                options: .atomic
            )
        }
        try envelope.encoded().write(
            to: directory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
    }
}
