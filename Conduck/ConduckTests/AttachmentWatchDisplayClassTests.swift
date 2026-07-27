// SPDX-License-Identifier: Apache-2.0

// Conduck
// AttachmentWatchDisplayClassTests.swift
//
// Pins the pure `AttachmentRecord.watchDisplayClass` classifier that drives the
// Watch thread's per-attachment rendering (`WatchConversationThreadView`) — the
// only viewer gate on the wrist. `AttachmentRecord` is an app-target member, so
// these run in the MAIN iOS suite (no ConduckWatchTests pbxproj churn).
//
// The load-bearing case is the DOUBLE-PLACEHOLDER regression: a server-reference
// image is BOTH `isImage` and `isServerFile`; it MUST classify `.serverPlaceholder`
// (order: server first) so it never renders an image fallback AND a stray file
// marker. The boundary case pins the ≤-ceiling inclusivity.

import XCTest
@testable import Conduck

final class AttachmentWatchDisplayClassTests: XCTestCase {

    private let ceiling = AttachmentRecord.watchViewableTextByteCeiling

    /// Builds an `AttachmentRecord` with just the fields the classifier reads;
    /// everything else is inert.
    private func makeAttachment(
        mimeType: String,
        extractedText: String?,
        isServerReference: Bool = false,
        thumbnailData: Data? = nil,
        previewKind: String? = nil
    ) -> AttachmentRecord {
        AttachmentRecord(
            id: UUID(),
            mimeType: mimeType,
            filename: "sample",
            thumbnailData: thumbnailData,
            extractedText: extractedText,
            width: 0,
            height: 0,
            byteSize: 0,
            sequence: 0,
            createdAt: Date(),
            isServerReference: isServerReference,
            storedKey: isServerReference ? "abc__sample" : nil,
            previewKind: previewKind
        )
    }

    func testInlineTextUnderCeilingIsViewable() {
        let a = makeAttachment(mimeType: "text/plain", extractedText: "hello, wrist")
        XCTAssertEqual(AttachmentRecord.watchDisplayClass(for: a), .viewableText)
    }

    func testInlineTextOverCeilingIsOversized() {
        let big = String(repeating: "a", count: ceiling + 1)   // ASCII → utf8.count == length
        let a = makeAttachment(mimeType: "text/plain", extractedText: big)
        XCTAssertEqual(AttachmentRecord.watchDisplayClass(for: a), .oversizedText)
    }

    func testTextWithNilExtractedTextIsFilePlaceholder() {
        // Partially-synced text row: `isText` but content hasn't arrived yet.
        let a = makeAttachment(mimeType: "text/markdown", extractedText: nil)
        XCTAssertEqual(AttachmentRecord.watchDisplayClass(for: a), .filePlaceholder)
    }

    func testPlainImageIsThumbnail() {
        let a = makeAttachment(mimeType: "image/jpeg", extractedText: nil)
        XCTAssertEqual(AttachmentRecord.watchDisplayClass(for: a), .imageThumbnail)
    }

    /// Regression lock: a server-reference IMAGE (isImage AND isServerFile) must
    /// classify server-first — otherwise it renders an image fallback AND a stray
    /// "[File attached]" marker (the latent double-placeholder bug).
    func testServerReferenceImageIsServerPlaceholder() {
        let a = makeAttachment(mimeType: "image/png", extractedText: nil, isServerReference: true)
        XCTAssertTrue(a.isImage)
        XCTAssertTrue(a.isServerFile)
        XCTAssertEqual(AttachmentRecord.watchDisplayClass(for: a), .serverPlaceholder)
    }

    func testServerReferenceNonImageIsServerPlaceholder() {
        let a = makeAttachment(mimeType: "application/pdf", extractedText: nil, isServerReference: true)
        XCTAssertEqual(AttachmentRecord.watchDisplayClass(for: a), .serverPlaceholder)
    }

    // MARK: - Server-reference PREVIEWS (model v6)

    /// A server reference that has synced an image thumbnail is now wrist-
    /// renderable as an image (not a passive placeholder).
    func testServerReferenceWithThumbnailIsImageThumbnail() {
        let a = makeAttachment(
            mimeType: "image/png", extractedText: nil,
            isServerReference: true, thumbnailData: Data([0xFF, 0xD8])
        )
        XCTAssertEqual(AttachmentRecord.watchDisplayClass(for: a), .imageThumbnail)
    }

    /// A server reference that has synced a text preview (`previewKind == "text"`)
    /// classifies as viewable text.
    func testServerReferenceWithTextPreviewIsViewableText() {
        let a = makeAttachment(
            mimeType: "application/json", extractedText: nil,
            isServerReference: true, previewKind: "text"
        )
        XCTAssertTrue(a.hasTextPreview)
        XCTAssertEqual(AttachmentRecord.watchDisplayClass(for: a), .viewableText)
    }

    /// Thumbnail is ordered FIRST — a server ref carrying BOTH a thumbnail and a
    /// text preview renders as an image, never a text row.
    func testServerReferenceWithBothPrefersThumbnail() {
        let a = makeAttachment(
            mimeType: "image/png", extractedText: nil,
            isServerReference: true, thumbnailData: Data([0xFF, 0xD8]), previewKind: "text"
        )
        XCTAssertEqual(AttachmentRecord.watchDisplayClass(for: a), .imageThumbnail)
    }

    /// A server ref with neither a thumbnail nor a text preview stays passive.
    func testServerReferenceWithNeitherIsServerPlaceholder() {
        let a = makeAttachment(mimeType: "application/pdf", extractedText: nil, isServerReference: true)
        XCTAssertFalse(a.hasTextPreview)
        XCTAssertEqual(AttachmentRecord.watchDisplayClass(for: a), .serverPlaceholder)
    }

    /// `hasTextPreview` is server-reference-only: an INLINE text file (previewKind
    /// would never be set on it) keeps its existing content-availability behavior.
    func testNonServerTextAttachmentBehaviorUnchanged() {
        let a = makeAttachment(mimeType: "text/plain", extractedText: "inline body")
        XCTAssertFalse(a.hasTextPreview, "an inline text file is not a server-reference preview")
        XCTAssertEqual(AttachmentRecord.watchDisplayClass(for: a), .viewableText)
    }

    // MARK: - isPreviewableTextFilename allowlist

    func testPreviewableTextFilenameAcceptsTextTypes() {
        XCTAssertTrue(AttachmentRecord.isPreviewableTextFilename("notes.txt"))
        XCTAssertTrue(AttachmentRecord.isPreviewableTextFilename("README.md"))
        XCTAssertTrue(AttachmentRecord.isPreviewableTextFilename("data.json"))
        XCTAssertTrue(AttachmentRecord.isPreviewableTextFilename("table.csv"))
        XCTAssertTrue(AttachmentRecord.isPreviewableTextFilename("Main.swift"))
    }

    func testPreviewableTextFilenameAcceptsSourceCode() {
        XCTAssertTrue(AttachmentRecord.isPreviewableTextFilename("script.py"))
        XCTAssertTrue(AttachmentRecord.isPreviewableTextFilename("app.js"))
        XCTAssertTrue(AttachmentRecord.isPreviewableTextFilename("model.ts"))
        XCTAssertTrue(AttachmentRecord.isPreviewableTextFilename("build.sh"))
        XCTAssertTrue(AttachmentRecord.isPreviewableTextFilename("query.sql"))
    }

    func testPreviewableTextFilenameRejectsBinaryAndImage() {
        for name in ["photo.png", "report.pdf", "bundle.zip", "sound.mp3",
                     "img.jpeg", "sheet.xlsx", "vector.svg", "cols.parquet"] {
            XCTAssertFalse(AttachmentRecord.isPreviewableTextFilename(name),
                           "\(name) is not a previewable text type")
        }
    }

    func testPreviewableTextFilenameIsCaseInsensitive() {
        XCTAssertTrue(AttachmentRecord.isPreviewableTextFilename("DATA.JSON"))
        XCTAssertTrue(AttachmentRecord.isPreviewableTextFilename("Notes.TXT"))
        XCTAssertFalse(AttachmentRecord.isPreviewableTextFilename("PHOTO.PNG"))
    }

    func testPreviewableTextFilenameRejectsNoExtension() {
        XCTAssertFalse(AttachmentRecord.isPreviewableTextFilename("Makefile"))
        XCTAssertFalse(AttachmentRecord.isPreviewableTextFilename("trailingdot."))
        XCTAssertFalse(AttachmentRecord.isPreviewableTextFilename(""))
    }

    /// Exactly at the ceiling is viewable (the split is `≤`), not oversized.
    func testTextExactlyAtCeilingIsViewable() {
        let exact = String(repeating: "a", count: ceiling)     // ASCII → utf8.count == ceiling
        let a = makeAttachment(mimeType: "text/plain", extractedText: exact)
        XCTAssertEqual(exact.utf8.count, ceiling)
        XCTAssertEqual(AttachmentRecord.watchDisplayClass(for: a), .viewableText)
    }
}
