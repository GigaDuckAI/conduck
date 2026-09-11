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

    /// Spoken words carry their own glyph and the desk's amber. `waveform` is
    /// reserved for the kinds that draw a transport, so the glyph never offers
    /// playback for a card with no recording behind it; and the tint stays amber
    /// because the blue is the link lane's alone.
    func testSpokenWordsCarryTheirOwnGlyphAndTheDesksAmber() {
        let spoken = material(kind: .transcript, name: "Ship the review before Friday")

        XCTAssertEqual(
            WorkboardMaterialIcon.symbol(for: spoken),
            WorkboardMaterialKind.transcript.systemImage
        )
        XCTAssertEqual(WorkboardMaterialKind.transcript.systemImage, "text.quote")
        XCTAssertEqual(WorkboardMaterialIcon.tint(for: spoken), AppColors.brandAmber)

        XCTAssertNotEqual(
            WorkboardMaterialKind.transcript.systemImage,
            WorkboardMaterialKind.audio.systemImage,
            "a card with nothing to play must not wear the transport's glyph"
        )
        XCTAssertNotEqual(
            WorkboardMaterialKind.transcript.systemImage,
            WorkboardMaterialKind.note.systemImage,
            "spoken and typed are different things to be told you are looking at"
        )
        XCTAssertNotEqual(
            String(localized: WorkboardMaterialKind.transcript.title),
            String(localized: WorkboardMaterialKind.note.title)
        )
        XCTAssertEqual(String(localized: WorkboardMaterialKind.transcript.title), "Spoken note")
    }

    /// A card that spends its whole tile on the photo hands VoiceOver no photo
    /// at all, so the words ARE the card there: the label has to keep naming the
    /// kind, the name and the availability it is in. The label is composed apart
    /// from the tile precisely so this can be asserted — nothing about the
    /// artwork mode reaches it.
    func testAnImageForwardCardStillSpeaksItsKindNameAndAvailability() {
        let photo = WorkboardMaterialSnapshot(
            kind: .image,
            name: "Whiteboard 3",
            thumbnailData: Data([0x01, 0x02]),
            availability: .syncPending,
            cardSize: .large
        )
        XCTAssertEqual(
            WorkboardCardArtworkMode.resolve(
                kind: photo.kind,
                hasThumbnail: photo.thumbnailData != nil,
                footprint: photo.cardSize
            ),
            .imageForward
        )

        let spoken = WorkboardCardAccessibility.summary(
            material: photo,
            boardPosition: 2,
            boardCount: 5
        )

        XCTAssertTrue(spoken.contains(String(localized: WorkboardMaterialKind.image.title)))
        XCTAssertTrue(spoken.contains("Whiteboard 3"))
        XCTAssertTrue(spoken.contains(String(localized: WorkboardCardAccessibility.availabilityLabel(
            for: .syncPending
        ))))
        XCTAssertTrue(spoken.contains(
            WorkboardCardAccessibility.boardPositionLabel(position: 2, count: 5)
        ))

        // Losing the picture must not lose the words: the same card without
        // preview bytes says exactly the same thing.
        var withoutThumbnail = photo
        withoutThumbnail.thumbnailData = nil
        XCTAssertEqual(
            WorkboardCardArtworkMode.resolve(
                kind: withoutThumbnail.kind,
                hasThumbnail: false,
                footprint: withoutThumbnail.cardSize
            ),
            .inline
        )
        XCTAssertEqual(
            WorkboardCardAccessibility.summary(
                material: withoutThumbnail,
                boardPosition: 2,
                boardCount: 5
            ),
            spoken
        )
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
