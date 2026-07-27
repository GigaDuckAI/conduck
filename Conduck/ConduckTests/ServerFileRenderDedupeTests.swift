// SPDX-License-Identifier: Apache-2.0

// Conduck
// ServerFileRenderDedupeTests.swift
//
// Locks `MessageRowFormatters.dedupedServerFiles(_:)` — the render-layer guard
// that stops duplicate download chips when two devices' near-simultaneous retro
// output scans merge duplicate rows for one storedKey (CloudKit has no
// distributed compare-and-set). Selection per key: a preview-bearing row
// (thumbnail or synced preview kind) beats a preview-less row; ties break to the
// lowest sequence; nil-storedKey rows are never collapsed. Also pins the iOS
// thread's image-gallery exclusion of server-reference images.
//
// Deterministic + headless: synthetic records only.

import XCTest
@testable import Conduck

final class ServerFileRenderDedupeTests: XCTestCase {

    private func serverFile(_ storedKey: String?, sequence: Int) -> AttachmentRecord {
        AttachmentRecord(
            id: UUID(),
            mimeType: "application/pdf",
            filename: storedKey,
            thumbnailData: nil,
            extractedText: nil,
            width: 0,
            height: 0,
            byteSize: 0,
            sequence: sequence,
            createdAt: Date(timeIntervalSince1970: 0),
            isServerReference: true,
            storedKey: storedKey
        )
    }

    /// A server-file row carrying a usable preview (`previewKind == "text"`) — the
    /// preferred survivor over a preview-less duplicate for the same key.
    private func serverFileWithPreview(_ storedKey: String, sequence: Int) -> AttachmentRecord {
        AttachmentRecord(
            id: UUID(),
            mimeType: "application/json",
            filename: storedKey,
            thumbnailData: nil,
            extractedText: nil,
            width: 0,
            height: 0,
            byteSize: 0,
            sequence: sequence,
            createdAt: Date(timeIntervalSince1970: 0),
            isServerReference: true,
            storedKey: storedKey,
            previewKind: "text"
        )
    }

    func testKeepsLowestSequenceOccurrencePerKey() {
        let input = [
            serverFile("a.pdf", sequence: 2),
            serverFile("a.pdf", sequence: 0),   // duplicate key, lower sequence — kept
            serverFile("b.pdf", sequence: 1)
        ]
        let out = MessageRowFormatters.dedupedServerFiles(input)
        XCTAssertEqual(out.map(\.storedKey), ["a.pdf", "b.pdf"], "ordered by sequence, one row per key")
        XCTAssertEqual(out.first { $0.storedKey == "a.pdf" }?.sequence, 0,
                       "the lowest-sequence occurrence survives")
    }

    func testNilStoredKeyRowsNeverCollapse() {
        let input = [
            serverFile(nil, sequence: 0),
            serverFile(nil, sequence: 1),
            serverFile("a.pdf", sequence: 2)
        ]
        let out = MessageRowFormatters.dedupedServerFiles(input)
        XCTAssertEqual(out.count, 3, "nil-storedKey rows have no key to dedupe on and are all kept")
    }

    func testNoDuplicatesIsIdentityOrdered() {
        let input = [
            serverFile("b.pdf", sequence: 1),
            serverFile("a.pdf", sequence: 0)
        ]
        let out = MessageRowFormatters.dedupedServerFiles(input)
        XCTAssertEqual(out.map(\.storedKey), ["a.pdf", "b.pdf"], "sorted by sequence, nothing dropped")
    }

    // MARK: - Preview-preference policy

    func testPreviewBearingRowWinsOverLowerSequencePreviewLess() {
        let input = [
            serverFile("a.pdf", sequence: 0),             // lower sequence, no preview
            serverFileWithPreview("a.pdf", sequence: 2)   // higher sequence, HAS preview — kept
        ]
        let out = MessageRowFormatters.dedupedServerFiles(input)
        XCTAssertEqual(out.count, 1, "one row per key")
        XCTAssertEqual(out.first?.sequence, 2,
                       "the preview-bearing row wins even at a higher sequence")
        XCTAssertEqual(out.first?.previewKind, "text")
    }

    func testEqualPreviewStatusBreaksToLowestSequence() {
        // Both preview-less → lowest sequence survives (unchanged tie-break).
        let previewLess = MessageRowFormatters.dedupedServerFiles([
            serverFile("a.pdf", sequence: 2),
            serverFile("a.pdf", sequence: 0)
        ])
        XCTAssertEqual(previewLess.first?.sequence, 0)
        // Both preview-bearing → lowest sequence survives too.
        let bothPreview = MessageRowFormatters.dedupedServerFiles([
            serverFileWithPreview("b.pdf", sequence: 3),
            serverFileWithPreview("b.pdf", sequence: 1)
        ])
        XCTAssertEqual(bothPreview.count, 1)
        XCTAssertEqual(bothPreview.first?.sequence, 1,
                       "equal preview status ties break to the lowest sequence")
    }

    func testThumbnailAlsoCountsAsPreview() {
        let withThumb = AttachmentRecord(
            id: UUID(), mimeType: "image/png", filename: "c.png",
            thumbnailData: Data([0xFF, 0xD8]), extractedText: nil,
            width: 0, height: 0, byteSize: 0, sequence: 4,
            createdAt: Date(timeIntervalSince1970: 0),
            isServerReference: true, storedKey: "c.png"
        )
        let out = MessageRowFormatters.dedupedServerFiles([
            serverFile("c.png", sequence: 1),   // no preview, lower sequence
            withThumb                            // thumbnail preview, higher sequence — kept
        ])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.sequence, 4, "a thumbnail counts as a usable preview")
    }

    // MARK: - iOS thread image-gallery exclusion (regression)

    /// A server-reference IMAGE now carries `thumbnailData` and can carry an image
    /// `mimeType`, so `isImage` alone is TRUE for it. The iOS thread's image grid
    /// + fullscreen gallery filter on `isImage && !isServerFile` (whose lazy
    /// loader faults local bytes a server ref lacks) — this pins that a server-ref
    /// image is EXCLUDED from that set and instead rides the server-file
    /// (download-chip) set.
    func testServerReferenceImageExcludedFromInlineImageGallery() {
        let inlineImage = AttachmentRecord(
            id: UUID(), mimeType: "image/jpeg", filename: nil,
            thumbnailData: Data([0xFF, 0xD8]), extractedText: nil,
            width: 0, height: 0, byteSize: 0, sequence: 0,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let serverImage = AttachmentRecord(
            id: UUID(), mimeType: "image/png", filename: "out.png",
            thumbnailData: Data([0xFF, 0xD8]), extractedText: nil,
            width: 0, height: 0, byteSize: 0, sequence: 1,
            createdAt: Date(timeIntervalSince1970: 0),
            isServerReference: true, storedKey: "out.png"
        )
        let all = [inlineImage, serverImage]
        XCTAssertTrue(serverImage.isImage, "a server-ref image satisfies isImage on its own")
        XCTAssertTrue(serverImage.isServerFile)

        let galleryImages = all.filter { $0.isImage && !$0.isServerFile }
        XCTAssertEqual(galleryImages.map(\.id), [inlineImage.id],
                       "only the inline image enters the grid/fullscreen gallery")
        let serverFiles = all.filter { $0.isServerFile }
        XCTAssertEqual(serverFiles.map(\.id), [serverImage.id],
                       "the server-ref image rides the download-chip set instead")
    }
}
