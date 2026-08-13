// SPDX-License-Identifier: Apache-2.0

// Conduck
// ManualFileSearchProvenanceTests.swift
//
// Locks the ONE thing that keeps the manual name search from laundering a weak
// finding into a strong claim: a chip whose storedKey does not begin with the
// reply's own output-folder prefix is not that reply's output, and the thread
// must say so.
//
// WHY IT MATTERS. The automatic lane reads a folder minted for exactly one
// dispatch and named on the wire before the reply existed, so membership carries
// freshness and namespace evidence. The manual lane probes BARE names at the
// served root, where the same filename could have been sitting since last month,
// could belong to another conversation, or could be a file the user wrote
// themselves. Both mint identical `AttachmentDraft`s, and a chip that looked the
// same either way would present the second as the first.
//
// The discriminator is DERIVED AT RENDER TIME from the key and the row's own
// `outputBoxKey` — no schema, no flag, no second field to keep in step. `nil` on
// either side is the honest direction: unsupported claims read weaker, never
// stronger, so a row that synced ahead of its attribute hedges rather than
// overstates.
//
// Deterministic + headless: pure predicate, no network, no store.

import XCTest
@testable import Conduck

final class ManualFileSearchProvenanceTests: XCTestCase {

    private let box = "1F2E3D4C-5B6A-7890-ABCD-EF0123456789/out-\(String(repeating: "a", count: 32))"

    /// A key inside the folder this reply named is this reply's output.
    func testKeyInsideTheReplysOwnFolderIsItsOutput() {
        XCTAssertTrue(AttachmentRecord.isFromReplyOutputBox(
            storedKey: "\(box)/report.pdf", outputBoxKey: box))
    }

    /// A BARE name — what the manual root search always mints — can never be
    /// inside a two-segment folder, so it renders with the weaker caption by
    /// construction rather than by anyone remembering to set a flag.
    func testBareNameFromTheManualSearchIsNeverTheReplysOutput() {
        XCTAssertFalse(AttachmentRecord.isFromReplyOutputBox(
            storedKey: "report.pdf", outputBoxKey: box))
    }

    /// A key from a DIFFERENT dispatch's folder — an earlier turn in the same
    /// conversation, or a retry's abandoned attempt — is not this reply's output
    /// either. The nonce is what separates them.
    func testAnotherDispatchsFolderIsNotThisReplysOutput() {
        let other = "1F2E3D4C-5B6A-7890-ABCD-EF0123456789/out-\(String(repeating: "b", count: 32))"
        XCTAssertFalse(AttachmentRecord.isFromReplyOutputBox(
            storedKey: "\(other)/report.pdf", outputBoxKey: box))
    }

    /// A PREFIX that is not a path boundary must not count. Without the explicit
    /// separator, a sibling folder whose name merely starts with this one's would
    /// inherit its provenance.
    func testASiblingFolderSharingAPrefixDoesNotCount() {
        XCTAssertFalse(AttachmentRecord.isFromReplyOutputBox(
            storedKey: "\(box)-2/report.pdf", outputBoxKey: box),
            "the match has to end on a path separator, not on any shared prefix")
    }

    /// The folder itself, with no file under it, is not a file.
    func testTheFolderKeyItselfIsNotAnOutput() {
        XCTAssertFalse(AttachmentRecord.isFromReplyOutputBox(
            storedKey: box, outputBoxKey: box))
    }

    /// MISSING METADATA HEDGES. A row a device synced before its `outputBoxKey`
    /// arrived, an inbound upload chip, and a row with no key at all all read as
    /// "found on your file server" — the claim the app can support without it.
    func testMissingMetadataAlwaysReadsWeaker() {
        XCTAssertFalse(AttachmentRecord.isFromReplyOutputBox(
            storedKey: "\(box)/report.pdf", outputBoxKey: nil),
            "a row without its folder attribute cannot claim the file came from it")
        XCTAssertFalse(AttachmentRecord.isFromReplyOutputBox(
            storedKey: nil, outputBoxKey: box))
        XCTAssertFalse(AttachmentRecord.isFromReplyOutputBox(
            storedKey: nil, outputBoxKey: nil))
        XCTAssertFalse(AttachmentRecord.isFromReplyOutputBox(
            storedKey: "/report.pdf", outputBoxKey: ""),
            "an empty folder key must not make every key on the server this reply's output")
    }

    /// An INBOUND upload key — `<conversationID>/<8hex>__<name>` — sits in the
    /// conversation folder, not in any dispatch folder, so it can never be
    /// mistaken for an output even though it shares the first segment.
    func testAnInboundUploadKeyIsNotAnOutput() {
        XCTAssertFalse(AttachmentRecord.isFromReplyOutputBox(
            storedKey: "1F2E3D4C-5B6A-7890-ABCD-EF0123456789/a1b2c3d4__photo.jpg",
            outputBoxKey: box))
    }
}
