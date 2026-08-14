// SPDX-License-Identifier: Apache-2.0

// Conduck
// WatchAttachmentPushOverlayTests.swift
//
// Locks the CONVERGENCE half of the phone→wrist agent-file courier: the promise
// that a couriered file row and the CloudKit row that supersedes it resolve to
// exactly ONE row on the wrist, no matter which arrives first.
//
// The design under test is an overlay, not a local write, and the reason is the
// whole reason these tests exist. The wrist's Core Data store is CloudKit-
// mirrored too, and Core Data + CloudKit mirroring does NOT unique on an `id`
// attribute — so a wrist-inserted `Attachment` row would export as its own
// CKRecord and sit permanently beside the iPhone's on every device the user
// owns. Instead the couriered metadata lives in `AttachedFileInboxState` beside
// the store, and `AgentFileOverlay.merge` folds it into fetched snapshots at
// READ time, retiring an entry in the same pass that first sees its real row.
// Nothing is written to the synced store, so no duplicate can be created in
// either direction.
//
// The cases that matter, and what breaks if each regresses:
//   • courier first  → the row shows in about a second, then hands over silently
//   • CloudKit first → the entry is retired unrendered; a duplicate chip never appears
//   • partial import → a mirrored row whose `storedKey` has not landed is still
//     matched, by attachment id, or the user sees the file twice
//   • message absent → the entry is neither rendered NOR retired; the courier can
//     legitimately outrun the message's own import, and "not here yet" must not
//     be read as "already landed"
//   • re-delivery    → the courier deliberately sends every batch twice (queued +
//     interactive); the second copy must change nothing, or the wrist repaints
//     on every duplicate
//   • stability      → merging twice must produce EQUAL records, or the view
//     model's equality skip never fires and the thread repaints forever
//
// `AttachedFileDescriptor` / `AttachedFileInboxState` / `AgentFileOverlay` are
// declared in the cross-target `ConversationStore.swift`, so these run in the
// MAIN iOS suite against the same code the Watch app compiles (no
// ConduckWatchTests pbxproj churn).
//
// Deterministic + headless: no WCSession, no Core Data, no network, no clock
// dependence (every time is injected).

import XCTest
@testable import Conduck

final class WatchAttachmentPushOverlayTests: XCTestCase {

    // MARK: - Fixtures

    private let conversationID = UUID()
    private let messageID = UUID()
    private let epoch = Date(timeIntervalSinceReferenceDate: 800_000)

    private func makeDescriptor(
        messageID: UUID? = nil,
        attachmentID: UUID = UUID(),
        storedKey: String = "out-9f/a1__report.csv",
        filename: String? = "report.csv",
        sequence: Int = 0,
        conversationID: UUID? = nil
    ) -> AttachedFileDescriptor {
        AttachedFileDescriptor(
            conversationID: conversationID ?? self.conversationID,
            messageID: messageID ?? self.messageID,
            attachmentID: attachmentID,
            storedKey: storedKey,
            filename: filename,
            mimeType: "text/csv",
            byteSize: 2048,
            sequence: sequence,
            previewKind: nil,
            createdAt: epoch
        )
    }

    /// The wrist's own reply turn: real text, no attachments — exactly what a
    /// Watch-originated turn looks like before any device has scanned its output
    /// folder.
    private func makeReply(attachments: [AttachmentRecord] = []) -> MessageRecord {
        MessageRecord(
            id: messageID,
            role: "agent",
            text: "Done — the summary is written.",
            createdAt: epoch,
            sourceDevice: "watch",
            outputScanDone: false,
            outputScanLaneID: String(repeating: "ab", count: 32),
            attachments: attachments
        )
    }

    /// The authoritative row as it arrives through CloudKit mirroring.
    private func mirroredRow(
        from descriptor: AttachedFileDescriptor,
        storedKey: String? = nil,
        id: UUID? = nil
    ) -> AttachmentRecord {
        AttachmentRecord(
            id: id ?? descriptor.attachmentID,
            mimeType: descriptor.mimeType,
            filename: descriptor.filename,
            thumbnailData: nil,
            extractedText: nil,
            width: 0,
            height: 0,
            byteSize: descriptor.byteSize,
            sequence: descriptor.sequence,
            createdAt: descriptor.createdAt,
            isServerReference: true,
            storedKey: storedKey ?? descriptor.storedKey,
            previewKind: nil
        )
    }

    private func inbox(_ descriptors: [AttachedFileDescriptor]) -> AttachedFileInboxState {
        var state = AttachedFileInboxState()
        state.ingest(descriptors, now: epoch)
        return state
    }

    // MARK: - The synthesized row

    func testSynthesizedRowIsDisplayOnlyAndCarriesNoBytes() {
        let record = AgentFileOverlay.synthesizedRecord(from: makeDescriptor())

        XCTAssertTrue(record.isServerReference)
        XCTAssertNil(record.thumbnailData)
        XCTAssertNil(record.extractedText)
        XCTAssertNil(record.previewKind,
                     "A `previewKind` would classify the row `.viewableText` and make it TAPPABLE into the text viewer — which resolves its content out of Core Data, where an overlay row does not exist, so the tap would land on \"no longer available\".")
    }

    func testSynthesizedRowClassifiesAsThePassiveServerPlaceholder() {
        let record = AgentFileOverlay.synthesizedRecord(from: makeDescriptor())
        XCTAssertEqual(AttachmentRecord.watchDisplayClass(for: record), .serverPlaceholder,
                       "The wrist has no download path and the courier carries no bytes — the honest row is the passive marker.")
    }

    func testSynthesizedRowIsAPureFunctionOfItsDescriptor() {
        let descriptor = makeDescriptor()
        XCTAssertEqual(AgentFileOverlay.synthesizedRecord(from: descriptor),
                       AgentFileOverlay.synthesizedRecord(from: descriptor),
                       "Two synthesized rows from one descriptor must be EQUAL, or every refresh pass looks like a change and the thread repaints forever.")
    }

    func testSynthesizedRowKeepsThePhoneMintedIdentity() {
        let descriptor = makeDescriptor()
        let record = AgentFileOverlay.synthesizedRecord(from: descriptor)
        XCTAssertEqual(record.id, descriptor.attachmentID,
                       "Carrying the phone's own attachment id keeps SwiftUI's ForEach identity continuous when the mirrored row takes over, so the row does not visibly pop.")
        XCTAssertEqual(record.createdAt, descriptor.createdAt,
                       "`createdAt` is part of AttachmentRecord equality; re-synthesizing it per merge would make every pass unequal.")
    }

    // MARK: - Courier first (the whole point)

    func testCourierFirstRendersTheRowImmediately() {
        let descriptor = makeDescriptor()
        let outcome = AgentFileOverlay.merge(inbox([descriptor]).entries, into: [makeReply()])

        XCTAssertEqual(outcome.messages.first?.attachments.count, 1,
                       "This is the entire feature: a file row on the wrist without waiting for CloudKit.")
        XCTAssertEqual(outcome.messages.first?.attachments.first?.storedKey, descriptor.storedKey)
        XCTAssertTrue(outcome.resolved.isEmpty,
                      "Nothing has landed yet, so nothing may be retired.")
    }

    func testMergedMessageDiffersByValueSoTheRefreshSkipDoesNotSwallowIt() {
        let plain = makeReply()
        let merged = AgentFileOverlay.merge(inbox([makeDescriptor()]).entries, into: [plain]).messages
        XCTAssertNotEqual(merged, [plain],
                          "`refreshThread` assigns only on inequality — if the merged thread compared equal, the notification would refresh and the row would still not appear.")
    }

    func testMergePreservesEveryOtherFieldOfTheTurn() {
        let plain = makeReply()
        let merged = try? XCTUnwrap(AgentFileOverlay.merge(inbox([makeDescriptor()]).entries, into: [plain]).messages.first)
        XCTAssertEqual(merged?.text, plain.text)
        XCTAssertEqual(merged?.outputScanDone, plain.outputScanDone)
        XCTAssertEqual(merged?.outputScanLaneID, plain.outputScanLaneID,
                       "The overlay adds a row; it must not disturb the scan provenance a capable device relies on.")
    }

    // MARK: - CloudKit first, and the handover

    func testCloudKitFirstNeverRendersTheOverlayRow() {
        let descriptor = makeDescriptor()
        let alreadyThere = makeReply(attachments: [mirroredRow(from: descriptor)])

        let outcome = AgentFileOverlay.merge(inbox([descriptor]).entries, into: [alreadyThere])

        XCTAssertEqual(outcome.messages, [alreadyThere],
                       "The authoritative row is already on screen — the courier's copy must not double it.")
        XCTAssertEqual(outcome.resolved, [descriptor.attachmentID],
                       "And the entry must be reported for pruning, or it re-checks forever.")
    }

    func testHandoverRetiresTheEntryWhenTheMirroredRowArrives() {
        let descriptor = makeDescriptor()
        var state = inbox([descriptor])

        // Pass 1: courier only.
        XCTAssertEqual(AgentFileOverlay.merge(state.entries, into: [makeReply()]).messages.first?.attachments.count, 1)

        // Pass 2: CloudKit has delivered.
        let landed = [makeReply(attachments: [mirroredRow(from: descriptor)])]
        let outcome = AgentFileOverlay.merge(state.entries, into: landed)
        XCTAssertTrue(state.remove(attachmentIDs: outcome.resolved))
        XCTAssertEqual(outcome.messages.first?.attachments.count, 1,
                       "One file, one row — the couriered row and the mirrored row must never coexist.")
        XCTAssertTrue(state.entries.isEmpty)

        // Pass 3: steady state, entry gone, nothing changes.
        XCTAssertEqual(AgentFileOverlay.merge(state.entries, into: landed).messages, landed)
    }

    func testDifferentDeviceMintedTheRowSoTheStoredKeyIsWhatMatches() {
        // A second capable device ran the same retro scan and minted its OWN
        // attachment UUID for the same file. The stored key is the only thing
        // both rows agree on.
        let descriptor = makeDescriptor()
        let foreign = mirroredRow(from: descriptor, id: UUID())
        let outcome = AgentFileOverlay.merge(inbox([descriptor]).entries, into: [makeReply(attachments: [foreign])])

        XCTAssertEqual(outcome.messages.first?.attachments.count, 1)
        XCTAssertEqual(outcome.resolved, [descriptor.attachmentID])
    }

    func testPartiallyMirroredRowIsMatchedByAttachmentID() {
        // CloudKit mirrors attributes independently; a row can arrive before its
        // `storedKey` does. Matching on the key alone would miss it and the user
        // would briefly see the file twice.
        let descriptor = makeDescriptor()
        let partial = mirroredRow(from: descriptor, storedKey: nil)
        let outcome = AgentFileOverlay.merge(inbox([descriptor]).entries, into: [makeReply(attachments: [partial])])

        XCTAssertEqual(outcome.messages.first?.attachments.count, 1,
                       "A half-imported row still proves the authoritative row is here — the overlay must stand down.")
        XCTAssertEqual(outcome.resolved, [descriptor.attachmentID])
    }

    // MARK: - Message not here yet

    func testEntryForAnAbsentMessageIsNeitherRenderedNorRetired() {
        let orphan = makeDescriptor(messageID: UUID())
        let outcome = AgentFileOverlay.merge(inbox([orphan]).entries, into: [makeReply()])

        XCTAssertEqual(outcome.messages.first?.attachments.count, 0)
        XCTAssertTrue(outcome.resolved.isEmpty,
                      "The courier can outrun the MESSAGE's own CloudKit import — \"not here yet\" must never be read as \"already landed\", or the row is lost for good.")
    }

    // MARK: - Ordering

    func testOverlayRowSortsIntoTheSequenceThePhonePersisted() {
        let first = makeDescriptor(attachmentID: UUID(), storedKey: "out-9f/a__a.txt", sequence: 0)
        let third = makeDescriptor(attachmentID: UUID(), storedKey: "out-9f/c__c.txt", sequence: 2)
        let existing = mirroredRow(from: makeDescriptor(storedKey: "out-9f/b__b.txt", sequence: 1))

        let merged = AgentFileOverlay.merge(inbox([third, first]).entries, into: [makeReply(attachments: [existing])])

        XCTAssertEqual(merged.messages.first?.attachments.map(\.sequence), [0, 1, 2],
                       "Carrying the phone's PERSISTED sequence is what makes the handover reorder nothing.")
    }

    // MARK: - Inbox state

    func testReDeliveryOfTheSameBatchChangesNothing() {
        let descriptors = [makeDescriptor(), makeDescriptor(attachmentID: UUID(), storedKey: "out-9f/b__b.txt")]
        var state = AttachedFileInboxState()

        XCTAssertTrue(state.ingest(descriptors, now: epoch))
        XCTAssertFalse(state.ingest(descriptors, now: epoch.addingTimeInterval(1)),
                       "The courier sends every batch on BOTH channels. The second copy must cost no post, no store fetch, and no repaint.")
        XCTAssertEqual(state.entries.count, 2)
    }

    func testASecondDevicesUUIDForTheSameFileDoesNotCreateASecondEntry() {
        let first = makeDescriptor(attachmentID: UUID())
        let second = makeDescriptor(attachmentID: UUID())   // same message + stored key
        var state = AttachedFileInboxState()
        state.ingest([first], now: epoch)
        state.ingest([second], now: epoch)

        XCTAssertEqual(state.entries.count, 1,
                       "Entry identity is (message, stored key) — two devices minting different UUIDs for one file must still show the user one row.")
    }

    func testRefreshedMetadataReplacesTheEntryWithoutExtendingItsAge() {
        let original = makeDescriptor(filename: "report.csv")
        let renamed = AttachedFileDescriptor(
            conversationID: original.conversationID,
            messageID: original.messageID,
            attachmentID: original.attachmentID,
            storedKey: original.storedKey,
            filename: "report-final.csv",
            mimeType: original.mimeType,
            byteSize: original.byteSize,
            sequence: original.sequence,
            previewKind: original.previewKind,
            createdAt: original.createdAt
        )
        var state = AttachedFileInboxState()
        state.ingest([original], now: epoch)
        XCTAssertTrue(state.ingest([renamed], now: epoch.addingTimeInterval(3600)))

        XCTAssertEqual(state.entries.first?.descriptor, renamed)
        XCTAssertEqual(state.entries.first?.receivedAt, epoch,
                       "Keeping the ORIGINAL receipt time stops a re-push from indefinitely extending the age bound.")
    }

    func testEntriesPastTheAgeBoundAreDropped() {
        var state = AttachedFileInboxState()
        state.ingest([makeDescriptor()], now: epoch)
        let later = epoch.addingTimeInterval(AttachedFileInboxState.maxEntryAge + 1)

        XCTAssertTrue(state.purgeExpired(now: later))
        XCTAssertTrue(state.entries.isEmpty,
                      "If the authoritative row never syncs, the overlay row must eventually disappear rather than become a permanent phantom.")
    }

    func testInboxIsBoundedAndEvictsOldestFirst() {
        var state = AttachedFileInboxState()
        let overflow = AttachedFileInboxState.maxEntries + 5
        for index in 0..<overflow {
            state.ingest(
                [makeDescriptor(messageID: UUID(), storedKey: "out-9f/\(index)__f.txt")],
                now: epoch.addingTimeInterval(Double(index))
            )
        }
        XCTAssertEqual(state.entries.count, AttachedFileInboxState.maxEntries)
        XCTAssertEqual(state.entries.first?.receivedAt, epoch.addingTimeInterval(5),
                       "Oldest first — the newest couriered file is the one the user is most likely still looking at.")
    }

    func testPurgingAConversationDropsItsEntries() {
        let mine = makeDescriptor()
        let other = makeDescriptor(messageID: UUID(), storedKey: "out-aa/z__z.txt", conversationID: UUID())
        var state = inbox([mine, other])

        XCTAssertTrue(state.purgeConversation(conversationID))
        XCTAssertEqual(state.entries.map(\.descriptor), [other],
                       "Entries for a deleted thread can never be proven landed — without an explicit purge they sit invisible until the age bound.")
    }

    func testEmptyInboxMergeIsTheIdentity() {
        let messages = [makeReply()]
        let outcome = AgentFileOverlay.merge([], into: messages)
        XCTAssertEqual(outcome.messages, messages)
        XCTAssertTrue(outcome.resolved.isEmpty)
    }

    func testStatePersistsAcrossAnEncodeDecodeRound() throws {
        let state = inbox([makeDescriptor()])
        let decoded = try JSONDecoder().decode(
            AttachedFileInboxState.self,
            from: try JSONEncoder().encode(state)
        )
        XCTAssertEqual(decoded, state,
                       "The inbox is persisted because a courier can arrive while the app is backgrounded — an in-memory cache would drop exactly the row it exists to deliver.")
    }

    // MARK: - Render dedupe interaction

    func testRenderDedupeLeavesASingleRowThroughTheHandover() {
        let descriptor = makeDescriptor()
        let merged = AgentFileOverlay.merge(
            inbox([descriptor]).entries,
            into: [makeReply(attachments: [mirroredRow(from: descriptor)])]
        ).messages

        let serverFiles = MessageRowFormatters.dedupedServerFiles(
            (merged.first?.attachments ?? []).filter(\.isServerFile)
        )
        XCTAssertEqual(serverFiles.count, 1,
                       "The bubble's own belt-and-braces dedupe must agree with the overlay: one file, one chip.")
    }
}
