// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardMaterialPresentationTests.swift
//
// Work and Chat describe the same file once. These tests hold the two shared
// presentation seams: material glyphs/tints come from Chat's AttachmentChipStyle
// (without dragging images into a text-file mapping), and the oversized-material
// soft-confirm builds one message for every import route.

import SwiftUI
import XCTest
@testable import Conduck

@MainActor
final class WorkboardMaterialPresentationTests: XCTestCase {
    private func material(
        kind: WorkboardMaterialKind,
        name: String,
        mimeType: String? = nil
    ) -> WorkboardMaterialSnapshot {
        WorkboardMaterialSnapshot(kind: kind, name: name, mimeType: mimeType)
    }

    func testFileGlyphsMatchChatsSharedTypeMapping() {
        let csv = material(kind: .file, name: "rows.csv", mimeType: "text/csv")
        let json = material(kind: .file, name: "config.json", mimeType: "application/json")
        let source = material(kind: .file, name: "Main.swift", mimeType: "text/plain")

        XCTAssertEqual(WorkboardMaterialIcon.symbol(for: csv), AttachmentChipStyle.symbol(forExtension: "csv"))
        XCTAssertEqual(WorkboardMaterialIcon.symbol(for: json), AttachmentChipStyle.symbol(forExtension: "json"))
        XCTAssertEqual(WorkboardMaterialIcon.symbol(for: source), AttachmentChipStyle.symbol(forExtension: "swift"))
        XCTAssertEqual(WorkboardMaterialIcon.tint(for: csv), AttachmentChipStyle.tint(forExtension: "csv"))

        // The three must stay distinguishable from each other — the whole point
        // of routing Work through the shared mapping.
        XCTAssertNotEqual(WorkboardMaterialIcon.symbol(for: csv), WorkboardMaterialIcon.symbol(for: json))
        XCTAssertNotEqual(WorkboardMaterialIcon.symbol(for: json), WorkboardMaterialIcon.symbol(for: source))
    }

    func testFileWithoutMimeTypeStillUsesItsExtension() {
        let csv = material(kind: .file, name: "rows.csv")
        XCTAssertEqual(WorkboardMaterialIcon.symbol(for: csv), AttachmentChipStyle.symbol(forExtension: "csv"))

        let unnamed = material(kind: .file, name: "Attachment")
        XCTAssertEqual(WorkboardMaterialIcon.symbol(for: unnamed), WorkboardMaterialKind.file.systemImage)
        XCTAssertEqual(WorkboardMaterialIcon.tint(for: unnamed), AppColors.brandAmber)
    }

    func testImagesLinksAndNotesKeepTheirOwnGlyph() {
        let image = material(kind: .image, name: "Photo 1", mimeType: "image/png")
        let link = material(kind: .link, name: "example.com")
        let note = material(kind: .note, name: "Thought")

        XCTAssertEqual(WorkboardMaterialIcon.symbol(for: image), WorkboardMaterialKind.image.systemImage)
        XCTAssertEqual(WorkboardMaterialIcon.tint(for: image), AppColors.brandAmber)
        XCTAssertEqual(WorkboardMaterialIcon.symbol(for: link), WorkboardMaterialKind.link.systemImage)
        XCTAssertEqual(WorkboardMaterialIcon.tint(for: link), AppColors.guidedSetupBlue)
        XCTAssertEqual(WorkboardMaterialIcon.symbol(for: note), WorkboardMaterialKind.note.systemImage)
    }

    func testLargeImportMessageNamesTheTotalSizeAndSeparatesSingularFromPlural() {
        let single = StubLargeImportConfirmation(largeItemByteCounts: [40_000_000])
        let multiple = StubLargeImportConfirmation(largeItemByteCounts: [40_000_000, 20_000_000])

        let singleSize = ByteCountFormatter.string(fromByteCount: 40_000_000, countStyle: .file)
        let multipleSize = ByteCountFormatter.string(fromByteCount: 60_000_000, countStyle: .file)

        XCTAssertTrue(single.largeImportMessage.contains(singleSize))
        XCTAssertTrue(multiple.largeImportMessage.contains(multipleSize))
        XCTAssertNotEqual(single.largeImportMessage, multiple.largeImportMessage)
    }
}

private struct StubLargeImportConfirmation: WorkboardLargeImportConfirming {
    let id = UUID()
    let largeItemByteCounts: [Int64]
}
