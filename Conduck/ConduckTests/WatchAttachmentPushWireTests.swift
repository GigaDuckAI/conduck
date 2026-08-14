// SPDX-License-Identifier: Apache-2.0

// Conduck
// WatchAttachmentPushWireTests.swift
//
// Locks the WIRE half of the phone→wrist agent-file courier: what may leave the
// phone, and what an arriving payload is allowed to do to a wrist.
//
// The courier exists because the wrist structurally cannot discover a file the
// agent produced — it holds no file-server credential, so it can neither list a
// reply's output folder nor probe one. The iPhone discovers the file, attaches
// it, and ships the row's METADATA over WatchConnectivity; CloudKit mirroring of
// the real row follows minutes later. Two properties therefore have to hold on
// this wire and nowhere else:
//
//   1. PRIVACY — the payload is a strict allowlist. No file bytes, no preview or
//      thumbnail bytes, no file-server URL, no credential. `testEnvelopeCarries…`
//      pins the exact key set so a future field cannot ride along unnoticed, and
//      the byte-shaped assertion catches the specific mistake of "just include
//      the preview so the wrist can render it".
//   2. TOLERANCE — the two builds ship independently. A newer phone's extra keys
//      must be ignored, a missing optional must default, and one malformed item
//      must not cost the user the OTHER files in the same batch. An unrecognized
//      kind must decode to nothing at all, which is how an older wrist (which
//      routes unknown payloads into the key-driven settings decoder) already
//      no-ops on a courier batch.
//
// `AttachedFileCourierWire` is declared in the cross-target `ConversationStore.swift`
// and compiled into BOTH the app and the Watch app, so there is one declaration
// and a rename is a compile error — unlike the relay's `Wire` enum, which is a
// literal duplicate across single-target files and needs a source-reading drift
// guard. These run in the MAIN iOS suite (no ConduckWatchTests pbxproj churn).
//
// Deterministic + headless: no WCSession, no Core Data, no network.

import XCTest
@testable import Conduck

final class WatchAttachmentPushWireTests: XCTestCase {

    // MARK: - Fixtures

    private func makeDescriptor(
        conversationID: UUID = UUID(),
        messageID: UUID = UUID(),
        attachmentID: UUID = UUID(),
        storedKey: String = "a1b2c3__report.csv",
        filename: String? = "report.csv",
        mimeType: String = "text/csv",
        byteSize: Int = 4096,
        sequence: Int = 3,
        previewKind: String? = nil,
        createdAt: Date = Date(timeIntervalSinceReferenceDate: 700_000)
    ) -> AttachedFileDescriptor {
        AttachedFileDescriptor(
            conversationID: conversationID,
            messageID: messageID,
            attachmentID: attachmentID,
            storedKey: storedKey,
            filename: filename,
            mimeType: mimeType,
            byteSize: byteSize,
            sequence: sequence,
            previewKind: previewKind,
            createdAt: createdAt
        )
    }

    // MARK: - Round trip

    func testEnvelopeRoundTripsEveryField() throws {
        let descriptor = makeDescriptor(previewKind: "text")
        let envelopes = AttachedFileCourierWire.envelopes(for: [descriptor])
        XCTAssertEqual(envelopes.count, 1)

        let decoded = AttachedFileCourierWire.decode(try XCTUnwrap(envelopes.first))
        XCTAssertEqual(decoded, [descriptor],
                       "A descriptor must survive the wire byte-for-byte — the wrist renders these values directly.")
    }

    func testOptionalFieldsSurviveAsNil() throws {
        let descriptor = makeDescriptor(filename: nil, previewKind: nil)
        let envelope = try XCTUnwrap(AttachedFileCourierWire.envelopes(for: [descriptor]).first)
        XCTAssertEqual(AttachedFileCourierWire.decode(envelope), [descriptor])
    }

    func testEmptyInputProducesNoEnvelopes() {
        XCTAssertTrue(AttachedFileCourierWire.envelopes(for: []).isEmpty,
                      "Nothing attached means nothing to courier — an empty envelope is pure radio cost.")
    }

    // MARK: - Privacy: the payload is an allowlist

    func testEnvelopeCarriesOnlyTheAllowlistedKeys() throws {
        let descriptor = makeDescriptor(previewKind: "text")
        let envelope = try XCTUnwrap(AttachedFileCourierWire.envelopes(for: [descriptor]).first)

        XCTAssertEqual(
            Set(envelope.keys),
            [
                AttachedFileCourierWire.kindKey,
                AttachedFileCourierWire.versionKey,
                AttachedFileCourierWire.operationKey,
                AttachedFileCourierWire.itemsKey
            ],
            "The envelope grew a top-level key. Every key on this wire crosses to a device that must never gain file-server reach — justify it before widening this set."
        )

        let items = try XCTUnwrap(envelope[AttachedFileCourierWire.itemsKey] as? [[String: Any]])
        XCTAssertEqual(
            Set(try XCTUnwrap(items.first).keys),
            [
                AttachedFileCourierWire.conversationIDKey,
                AttachedFileCourierWire.messageIDKey,
                AttachedFileCourierWire.attachmentIDKey,
                AttachedFileCourierWire.storedKeyKey,
                AttachedFileCourierWire.filenameKey,
                AttachedFileCourierWire.mimeTypeKey,
                AttachedFileCourierWire.byteSizeKey,
                AttachedFileCourierWire.sequenceKey,
                AttachedFileCourierWire.previewKindKey,
                AttachedFileCourierWire.createdAtKey
            ],
            "The per-item payload grew a field. This is the allowlist of what the phone tells the wrist about a file — bytes, previews, thumbnails, server URLs and credentials are all deliberately absent."
        )
    }

    /// THE OTHER BRANCH of the same allowlist. `item(for:)` puts `filename` and
    /// `previewKind` CONDITIONALLY, so the maximal fixture above only ever
    /// exercises the present-path — a key emitted on the ABSENT path (a "why it
    /// was omitted" marker, a placeholder, a fallback blob) would be invisible to
    /// it and ride to the wrist unpinned. Set equality against the bare required
    /// shape closes that: with every optional nil, these eight keys are the whole
    /// payload and nothing may join them.
    func testEnvelopeWithNoOptionalsCarriesOnlyTheRequiredKeys() throws {
        let descriptor = makeDescriptor(filename: nil, previewKind: nil)
        let envelope = try XCTUnwrap(AttachedFileCourierWire.envelopes(for: [descriptor]).first)
        let items = try XCTUnwrap(envelope[AttachedFileCourierWire.itemsKey] as? [[String: Any]])

        XCTAssertEqual(
            Set(try XCTUnwrap(items.first).keys),
            [
                AttachedFileCourierWire.conversationIDKey,
                AttachedFileCourierWire.messageIDKey,
                AttachedFileCourierWire.attachmentIDKey,
                AttachedFileCourierWire.storedKeyKey,
                AttachedFileCourierWire.mimeTypeKey,
                AttachedFileCourierWire.byteSizeKey,
                AttachedFileCourierWire.sequenceKey,
                AttachedFileCourierWire.createdAtKey
            ],
            "An item with no optional fields grew a key. A field that rides only when something else is ABSENT still crosses to a device that must never gain file-server reach — justify it before widening this set."
        )
    }

    func testNoValueOnTheWireIsByteShaped() throws {
        let descriptor = makeDescriptor()
        let envelope = try XCTUnwrap(AttachedFileCourierWire.envelopes(for: [descriptor]).first)
        let items = try XCTUnwrap(envelope[AttachedFileCourierWire.itemsKey] as? [[String: Any]])
        for value in try XCTUnwrap(items.first).values {
            XCTAssertFalse(value is Data,
                           "A `Data` value reached the courier wire. File bytes, thumbnails and preview blobs must never leave the phone on this channel — the wrist gets something to draw, never something to open.")
        }
    }

    func testPayloadIsPropertyListCleanSoWatchConnectivityAccepts() throws {
        // WCSession validates against the property-list types at send time and
        // throws on anything else, which would drop the whole batch at runtime
        // with no compile-time signal.
        let envelope = try XCTUnwrap(AttachedFileCourierWire.envelopes(for: [makeDescriptor(previewKind: "text")]).first)
        XCTAssertTrue(PropertyListSerialization.propertyList(envelope, isValidFor: .binary),
                      "The courier envelope is not property-list clean — WCSession would reject it at send time.")
    }

    // MARK: - Tolerance

    func testUnknownKeysAreIgnored() throws {
        let descriptor = makeDescriptor()
        var envelope = try XCTUnwrap(AttachedFileCourierWire.envelopes(for: [descriptor]).first)
        envelope["somethingANewerPhoneAdded"] = "whatever"
        var items = try XCTUnwrap(envelope[AttachedFileCourierWire.itemsKey] as? [[String: Any]])
        items[0]["alsoNew"] = 42
        envelope[AttachedFileCourierWire.itemsKey] = items

        XCTAssertEqual(AttachedFileCourierWire.decode(envelope), [descriptor],
                       "A newer phone's extra keys must decode away, not strand the wrist on the CloudKit path.")
    }

    func testOneMalformedItemDoesNotCostTheBatch() throws {
        let good = makeDescriptor(storedKey: "k1__a.txt")
        let alsoGood = makeDescriptor(storedKey: "k2__b.txt")
        var envelope = try XCTUnwrap(AttachedFileCourierWire.envelopes(for: [good, alsoGood]).first)
        var items = try XCTUnwrap(envelope[AttachedFileCourierWire.itemsKey] as? [[String: Any]])
        items.insert(["garbage": true], at: 1)
        items.append([AttachedFileCourierWire.messageIDKey: "not-a-uuid"])
        envelope[AttachedFileCourierWire.itemsKey] = items

        XCTAssertEqual(AttachedFileCourierWire.decode(envelope), [good, alsoGood],
                       "A malformed item must be dropped alone — the other items are files the user is waiting to see.")
    }

    func testItemWithoutAStoredKeyIsDropped() {
        let item: [String: Any] = [
            AttachedFileCourierWire.conversationIDKey: UUID().uuidString,
            AttachedFileCourierWire.messageIDKey: UUID().uuidString,
            AttachedFileCourierWire.attachmentIDKey: UUID().uuidString,
            AttachedFileCourierWire.storedKeyKey: ""
        ]
        XCTAssertNil(AttachedFileCourierWire.descriptor(fromItem: item),
                     "An unkeyed row could never be matched against the CloudKit row that supersedes it, so it could never retire — refuse it at the door.")
    }

    func testMissingOptionalFieldsFallBackRatherThanFailing() throws {
        let item: [String: Any] = [
            AttachedFileCourierWire.conversationIDKey: UUID().uuidString,
            AttachedFileCourierWire.messageIDKey: UUID().uuidString,
            AttachedFileCourierWire.attachmentIDKey: UUID().uuidString,
            AttachedFileCourierWire.storedKeyKey: "k__x.bin"
        ]
        let decoded = try XCTUnwrap(AttachedFileCourierWire.descriptor(fromItem: item))
        XCTAssertEqual(decoded.mimeType, AttachedFileCourierWire.defaultMIMEType)
        XCTAssertEqual(decoded.byteSize, 0)
        XCTAssertEqual(decoded.sequence, 0)
        XCTAssertNil(decoded.filename)
        XCTAssertNil(decoded.previewKind)
        XCTAssertEqual(decoded.createdAt, Date(timeIntervalSinceReferenceDate: 0),
                       "A missing timestamp must pin to a CONSTANT, never `Date()` — a per-merge value would make every refresh pass unequal and repaint the thread forever.")
    }

    func testWrongKindDecodesToNothing() throws {
        var envelope = try XCTUnwrap(AttachedFileCourierWire.envelopes(for: [makeDescriptor()]).first)
        envelope[AttachedFileCourierWire.kindKey] = "apple-speech-relay-reply"
        XCTAssertTrue(AttachedFileCourierWire.decode(envelope).isEmpty,
                      "A payload of another kind must decode to nothing so the receiver falls through to its real handler.")
    }

    func testUnknownOperationIsDroppedRatherThanTreatedAsUpsert() throws {
        var envelope = try XCTUnwrap(AttachedFileCourierWire.envelopes(for: [makeDescriptor()]).first)
        envelope[AttachedFileCourierWire.operationKey] = "tombstone"
        XCTAssertTrue(AttachedFileCourierWire.decode(envelope).isEmpty,
                      "A future operation misread as an upsert would resurrect a row the phone deleted — dropping is the safe direction.")
    }

    func testMissingOperationIsReadAsUpsert() throws {
        var envelope = try XCTUnwrap(AttachedFileCourierWire.envelopes(for: [makeDescriptor()]).first)
        envelope.removeValue(forKey: AttachedFileCourierWire.operationKey)
        XCTAssertEqual(AttachedFileCourierWire.decode(envelope).count, 1,
                       "V1 is upsert-only; an absent operation is the V1 shape and must still deliver.")
    }

    // MARK: - Batching

    func testOversizedBatchSplitsIntoSeveralEnvelopes() {
        let cap = AttachedFileCourierWire.maxItemsPerEnvelope
        let descriptors = (0..<(cap * 2 + 1)).map { makeDescriptor(storedKey: "k\($0)__f.txt") }
        let envelopes = AttachedFileCourierWire.envelopes(for: descriptors)

        XCTAssertEqual(envelopes.count, 3,
                       "A pathological scan must send several small envelopes — one oversized payload the OS rejects loses EVERY row rather than delaying some.")
        XCTAssertEqual(envelopes.flatMap { AttachedFileCourierWire.decode($0) }, descriptors,
                       "Splitting must preserve every descriptor and their order.")
    }
}
