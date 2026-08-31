// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkCaptureDrainerTests.swift
//
// End-to-end coverage for Share Extension captures targeting existing Work:
// open-target append, visible note preservation, stale-target fallback, and
// deterministic replay after a crash boundary. The drainer has no transport
// dependency, and every assertion stays inside in-memory Core Data + temp files.

import XCTest
@testable import Conduck

final class WorkCaptureDrainerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-work-drainer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        try super.tearDownWithError()
    }

    func testOpenTargetReceivesVisibleNoteAndMaterialsWithoutChangingBriefOrDispatching() async throws {
        let store = ConversationStore(inMemory: true)
        let target = try await store.createWorkItem(WorkItemDraft(content: WorkItemContent(
            title: "Launch",
            objective: "Prepare the launch plan",
            context: "Original context"
        )))
        let envelope = WorkCaptureEnvelope(
            note: "Please compare this with the current plan",
            source: .shareExtension,
            targetWorkItemID: target.id,
            entries: [
                .init(kind: .text, sequence: 0, text: "Source excerpt"),
                .init(kind: .url, sequence: 1, text: "https://example.com/source"),
            ]
        )
        try publish(envelope)

        let report = try await makeDrainer(store: store).drainAvailableCaptures()
        let updatedValue = try await store.fetchWorkItem(id: target.id)
        let updated = try XCTUnwrap(updatedValue)

        XCTAssertEqual(report.importedCaptureCount, 1)
        XCTAssertEqual(report.importedMaterialCount, 3)
        XCTAssertEqual(updated.content.title, "Launch")
        XCTAssertEqual(updated.content.objective, "Prepare the launch plan")
        XCTAssertEqual(updated.content.context, "Original context")
        XCTAssertEqual(updated.materials.count, 3)
        XCTAssertTrue(updated.materials.contains {
            $0.kind == .note
                && $0.title == "Share note"
                && $0.textContent == "Please compare this with the current plan"
        })
        XCTAssertTrue(updated.dispatches.isEmpty, "capture ingress must never create a dispatch")
        let captureItem = try await store.fetchWorkItem(captureEnvelopeID: envelope.id)
        XCTAssertNil(captureItem)
    }

    func testReplayedAppendUsesSameTargetAndNeverDuplicatesAnyMaterial() async throws {
        let store = ConversationStore(inMemory: true)
        let target = try await store.createWorkItem(
            WorkItemDraft(content: WorkItemContent(title: "Existing Work"))
        )
        let entryID = UUID()
        let envelope = WorkCaptureEnvelope(
            note: "Append once",
            source: .shareExtension,
            targetWorkItemID: target.id,
            entries: [.init(id: entryID, kind: .text, sequence: 0, text: "One source")]
        )

        try publish(envelope)
        let drainer = makeDrainer(store: store)
        _ = try await drainer.drainAvailableCaptures()
        try publish(envelope)
        let replay = try await drainer.drainAvailableCaptures()
        let updatedValue = try await store.fetchWorkItem(id: target.id)
        let updated = try XCTUnwrap(updatedValue)

        XCTAssertEqual(replay.replayedCaptureCount, 1)
        XCTAssertEqual(Set(updated.materials.map(\.id)), [envelope.id, entryID])
        XCTAssertEqual(updated.materials.count, 2)
        XCTAssertTrue(updated.dispatches.isEmpty)
    }

    func testNoteIdentityNeverMasksAnEntryThatUsesTheEnvelopeID() async throws {
        let store = ConversationStore(inMemory: true)
        let target = try await store.createWorkItem(
            WorkItemDraft(content: WorkItemContent(title: "Collision-safe destination"))
        )
        let envelopeID = UUID()
        let envelope = WorkCaptureEnvelope(
            id: envelopeID,
            note: "Visible note",
            source: .shareExtension,
            targetWorkItemID: target.id,
            entries: [
                .init(id: envelopeID, kind: .text, sequence: 0, text: "Distinct source")
            ]
        )
        try publish(envelope)

        _ = try await makeDrainer(store: store).drainAvailableCaptures()
        let updatedValue = try await store.fetchWorkItem(id: target.id)
        let updated = try XCTUnwrap(updatedValue)

        XCTAssertEqual(updated.materials.count, 2)
        XCTAssertTrue(updated.materials.contains { $0.textContent == "Visible note" })
        XCTAssertTrue(updated.materials.contains { $0.textContent == "Distinct source" })
        XCTAssertEqual(Set(updated.materials.map(\.id)).count, 2)
    }

    func testMissingTargetFallsBackToClearlyExplainedNewDraft() async throws {
        let store = ConversationStore(inMemory: true)
        let envelope = WorkCaptureEnvelope(
            note: "Keep this idea",
            source: .shareExtension,
            targetWorkItemID: UUID(),
            entries: []
        )
        try publish(envelope)

        _ = try await makeDrainer(store: store).drainAvailableCaptures()
        let fallbackValue = try await store.fetchWorkItem(captureEnvelopeID: envelope.id)
        let fallback = try XCTUnwrap(fallbackValue)

        XCTAssertEqual(fallback.id, envelope.id)
        XCTAssertEqual(fallback.content.objective, "Keep this idea")
        XCTAssertTrue(fallback.content.context.contains("saved as a new draft"))
        XCTAssertTrue(fallback.dispatches.isEmpty)
    }

    func testDoneTargetFallsBackUnlessThisCaptureHadAlreadyStartedAppending() async throws {
        let store = ConversationStore(inMemory: true)
        let untouchedDone = try await store.createWorkItem(
            WorkItemDraft(content: WorkItemContent(title: "Done destination"))
        )
        _ = try await store.completeWorkItem(id: untouchedDone.id)
        let fallbackEnvelope = WorkCaptureEnvelope(
            note: "Late capture",
            source: .shareExtension,
            targetWorkItemID: untouchedDone.id,
            entries: []
        )
        try publish(fallbackEnvelope)
        _ = try await makeDrainer(store: store).drainAvailableCaptures()
        let fallback = try await store.fetchWorkItem(captureEnvelopeID: fallbackEnvelope.id)
        XCTAssertNotNil(fallback)

        // Simulate a crash after the deterministic note marker committed but
        // before the remaining entry and inbox acknowledgement. Completing the
        // target during that gap must not split one capture across two Work items.
        let startedTarget = try await store.createWorkItem(
            WorkItemDraft(content: WorkItemContent(title: "Started destination"))
        )
        let entryID = UUID()
        let replayEnvelope = WorkCaptureEnvelope(
            note: "Started note",
            source: .shareExtension,
            targetWorkItemID: startedTarget.id,
            entries: [.init(id: entryID, kind: .text, sequence: 0, text: "Remaining source")]
        )
        _ = try await store.addWorkMaterial(
            WorkMaterialDraft(
                id: replayEnvelope.id,
                kind: .note,
                title: "Share note",
                textContent: replayEnvelope.note,
                sequence: 0,
                storageMode: .metadataOnly
            ),
            to: startedTarget.id
        )
        _ = try await store.completeWorkItem(id: startedTarget.id)
        try publish(replayEnvelope)

        let report = try await makeDrainer(store: store).drainAvailableCaptures()
        let continuedValue = try await store.fetchWorkItem(id: startedTarget.id)
        let continued = try XCTUnwrap(continuedValue)
        let replayFallback = try await store.fetchWorkItem(captureEnvelopeID: replayEnvelope.id)

        XCTAssertEqual(report.replayedCaptureCount, 1)
        XCTAssertEqual(Set(continued.materials.map(\.id)), [replayEnvelope.id, entryID])
        XCTAssertNil(replayFallback)
        XCTAssertEqual(continued.state, .done, "capture append must not reopen human-completed Work")
    }

    /// The drainer's byte-preserving promise: a persistence failure must put the
    /// claim BACK (`release`) rather than consume it (`acknowledge`), because the
    /// extension already moved the only copy of the payload into the queue.
    /// Swapping those two calls destroys a person's shared file on any transient
    /// write failure, and every other test here takes a path that succeeds.
    func testAPersistenceFailureReleasesTheClaimAndPreservesItsPayload() async throws {
        let store = ConversationStore(inMemory: true)
        let otherOwner = try await store.createWorkItem(
            WorkItemDraft(content: WorkItemContent(title: "Already owns the identity"))
        )
        let target = try await store.createWorkItem(
            WorkItemDraft(content: WorkItemContent(title: "Capture destination"))
        )
        // A material ID may belong to exactly one item, so reusing it as an
        // envelope entry ID makes the second write fail through the public API
        // with no store seam.
        let collidingID = UUID()
        _ = try await store.addWorkMaterial(
            WorkMaterialDraft(
                id: collidingID,
                kind: .note,
                title: "Prior material",
                textContent: "owned elsewhere",
                sequence: 0,
                storageMode: .metadataOnly
            ),
            to: otherOwner.id
        )

        let payload = Data("shared bytes that must survive".utf8)
        let envelope = WorkCaptureEnvelope(
            source: .shareExtension,
            targetWorkItemID: target.id,
            entries: [
                .init(
                    kind: .image,
                    sequence: 0,
                    relativePath: "payload-000.png",
                    displayName: "IMG.png",
                    mimeType: "image/png",
                    byteCount: Int64(payload.count)
                ),
                .init(id: collidingID, kind: .text, sequence: 1, text: "the write that fails"),
            ]
        )
        try publish(envelope, payloads: ["payload-000.png": payload])

        let inbox = WorkCaptureInbox(baseURL: root)
        let drainer = WorkCaptureDrainer(inbox: inbox, store: store, sourceDevice: "test-device")
        do {
            _ = try await drainer.drainAvailableCaptures()
            XCTFail("A material owned by another Work item must fail the import")
        } catch {
            XCTAssertEqual(error as? WorkboardStoreError, .invalidMaterialOwner)
        }

        let pending = try await inbox.pendingCount()
        XCTAssertEqual(pending, 1, "a failed import must return the capture to the queue, not consume it")
        let restored = root
            .appendingPathComponent(envelope.id.uuidString, isDirectory: true)
            .appendingPathComponent("payload-000.png", isDirectory: false)
        let restoredBytes = try Data(contentsOf: restored)
        XCTAssertEqual(restoredBytes, payload,
                       "the queue holds the only copy of a shared file until the import commits")
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
