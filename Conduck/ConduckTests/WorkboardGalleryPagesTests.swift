// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardGalleryPagesTests.swift
//
// What a tap on ONE picture opens. Work's gallery is the desk's pictures, not
// the tapped card alone, so the page list is a projection of the board and has
// exactly three things to get right: which cards are in it, what order they are
// in, and where the tap landed.
//
// The failure these hold shut is a silent one. A page list built without the
// availability gate shows a syncing card's thumbnail as though the picture had
// arrived; a start index computed against the UNFILTERED desk points at the
// wrong picture the moment one card is filtered out — and both look perfectly
// fine until the person swipes.

import XCTest
@testable import Conduck

@MainActor
final class WorkboardGalleryPagesTests: XCTestCase {

    private func image(
        _ name: String,
        availability: WorkboardMaterialAvailability = .available,
        thumbnail: Data? = nil,
        byteCount: Int64? = nil
    ) -> WorkboardMaterialSnapshot {
        WorkboardMaterialSnapshot(
            kind: .image,
            name: name,
            mimeType: "image/jpeg",
            thumbnailData: thumbnail,
            byteCount: byteCount,
            availability: availability
        )
    }

    // MARK: - Which cards are pages

    /// Only pictures, and only pictures this device can actually read. A note,
    /// a link, a PDF and a recording are not things a picture gallery can page
    /// onto.
    func testOnlyOpenableImageCardsBecomePages() {
        let photo = image("Photo 1")
        let desk: [WorkboardMaterialSnapshot] = [
            WorkboardMaterialSnapshot(kind: .note, name: "Thought"),
            photo,
            WorkboardMaterialSnapshot(kind: .link, name: "example.com"),
            WorkboardMaterialSnapshot(kind: .file, name: "Contract.pdf"),
            WorkboardMaterialSnapshot(kind: .audio, name: "Voice note")
        ]

        let selection = PersonalWorkbenchRouter.gallerySelection(desk: desk, tapped: photo)

        XCTAssertEqual(selection.pages.map(\.id), [photo.id])
    }

    /// The gate is the SAME one the tap passed. A card whose bytes are still
    /// arriving carries a thumbnail, and a gallery that paged onto it would
    /// present that thumbnail as the picture itself.
    func testACardWhoseBytesAreNotReadableHereIsNeverAPage() {
        let first = image("Photo 1")
        let waiting = image("Photo 2", availability: .syncPending, thumbnail: Data([0x89, 0x50]))
        let gone = image("Photo 3", availability: .unavailableOnThisDevice)
        let last = image("Photo 4")

        let selection = PersonalWorkbenchRouter.gallerySelection(
            desk: [first, waiting, gone, last],
            tapped: last
        )

        XCTAssertEqual(selection.pages.map(\.id), [first.id, last.id])
        XCTAssertEqual(
            selection.startIndex,
            1,
            "the index counts the pages that exist, not the cards on the desk"
        )
    }

    /// A picture too large to sync lives in the device-local vault and carries
    /// no persisted preview. It is still a picture, and the lane it is stored on
    /// is not a reason to route it elsewhere.
    func testAVaultLanePictureIsAPageLikeAnyOther() {
        let synced = image("Photo 1", thumbnail: Data([0xFF, 0xD8]))
        let vault = image("Photo 2", availability: .localOnly, byteCount: 41_000_000)

        let selection = PersonalWorkbenchRouter.gallerySelection(
            desk: [synced, vault],
            tapped: vault
        )

        XCTAssertEqual(selection.pages.map(\.id), [synced.id, vault.id])
        XCTAssertEqual(selection.startIndex, 1)
        XCTAssertNil(
            selection.pages[1].thumbnailData,
            "a vault card has no persisted preview; the gallery loads its original instead"
        )
    }

    // MARK: - Order and where the tap landed

    /// Board order, not sorted, not deduplicated, not reordered by the tap. The
    /// desk's order is one the person arranged by hand.
    func testPagesKeepBoardOrderAndTheStartIndexPointsAtTheTappedCard() {
        let cards = (1...5).map { image("Photo \($0)") }

        for (position, tapped) in cards.enumerated() {
            let selection = PersonalWorkbenchRouter.gallerySelection(desk: cards, tapped: tapped)
            XCTAssertEqual(selection.pages.map(\.id), cards.map(\.id), "board order survives every tap")
            XCTAssertEqual(selection.startIndex, position)
            XCTAssertEqual(selection.pages[selection.startIndex].id, tapped.id)
        }
    }

    /// The board reloaded underneath the gesture and the tapped card is not in
    /// the desk the router read. The tap still opens the picture the person is
    /// looking at — refusing it would turn a stale read into a dead tap.
    func testATappedCardMissingFromTheDeskStillOpensAlone() {
        let onScreen = image("Photo 9")
        let refreshedDesk = (1...3).map { image("Photo \($0)") }

        let selection = PersonalWorkbenchRouter.gallerySelection(
            desk: refreshedDesk,
            tapped: onScreen
        )

        XCTAssertEqual(selection.pages.map(\.id), [onScreen.id])
        XCTAssertEqual(selection.startIndex, 0)

        // Same rule when there is no desk to read at all.
        let empty = PersonalWorkbenchRouter.gallerySelection(desk: [], tapped: onScreen)
        XCTAssertEqual(empty.pages.map(\.id), [onScreen.id])
        XCTAssertEqual(empty.startIndex, 0)
    }

    // MARK: - Which card the tap actually stands for

    /// The desk wins over the snapshot the gesture carried. Presentation runs
    /// after the tap, so a peer's reattach can move the card in between, and the
    /// availability that decides what happens must be the current one.
    func testTheDesksOwnCardAnswersForATapTakenBeforeItChanged() {
        let cardID = UUID()
        let tapped = WorkboardMaterialSnapshot(
            id: cardID, kind: .image, name: "Sketch", availability: .available
        )
        let refreshed = WorkboardMaterialSnapshot(
            id: cardID, kind: .image, name: "Sketch", availability: .syncPending
        )

        let resolved = PersonalWorkbenchRouter.currentDeskCard(
            in: [image("Photo 1"), refreshed],
            for: tapped
        )

        XCTAssertEqual(resolved.availability, .syncPending,
                       "the card the desk holds is the one the gate answers for")
    }

    /// And the card the desk no longer carries stays itself, so a board that
    /// reloaded underneath the gesture never turns into a dead tap.
    func testATapOnACardTheDeskNoLongerCarriesResolvesToItself() {
        let tapped = image("Photo 9")

        XCTAssertEqual(
            PersonalWorkbenchRouter.currentDeskCard(in: (1...3).map { image("Photo \($0)") }, for: tapped).id,
            tapped.id
        )
        XCTAssertEqual(
            PersonalWorkbenchRouter.currentDeskCard(in: [], for: tapped).id,
            tapped.id
        )
    }

    // MARK: - The recording folded into a page

    private func recording(
        _ name: String,
        availability: WorkboardMaterialAvailability = .available,
        transcript: String? = nil,
        attachedTo picture: UUID
    ) -> WorkboardCompanionSnapshot {
        WorkboardCompanionSnapshot(WorkboardMaterialSnapshot(
            kind: .audio,
            name: name,
            textContent: transcript,
            mimeType: "audio/mp4",
            availability: availability,
            attachedToMaterialID: picture
        ))
    }

    /// A folded card opens as ONE sheet, so the recording has to travel with
    /// the page rather than being left on the desk behind it. Keyed by the
    /// PICTURE's id, which is what the gallery's cursor names.
    func testAFoldedPicturesRecordingTravelsWithItsPage() {
        let plain = image("Photo 1")
        var folded = image("Screenshot")
        folded.companion = recording("Voice note", transcript: "check the lease", attachedTo: folded.id)

        let selection = PersonalWorkbenchRouter.gallerySelection(
            desk: [plain, folded],
            tapped: plain
        )

        XCTAssertEqual(selection.pages.map(\.id), [plain.id, folded.id])
        XCTAssertEqual(
            selection.companion(forPage: folded.id)?.name,
            "Voice note",
            "the page the cursor lands on answers with its own recording"
        )
        XCTAssertNil(
            selection.companion(forPage: plain.id),
            "a picture nothing was recorded with carries no transport"
        )
        XCTAssertNil(selection.companion(forPage: nil))
    }

    /// The recording's readability is not the picture's. A picture whose bytes
    /// are here can be folded with a recording whose bytes are still arriving,
    /// and the band that says so is better than one that vanishes.
    func testARecordingWhoseBytesAreNotHereStillTravelsWithItsPicture() {
        var folded = image("Screenshot")
        folded.companion = recording("Voice note", availability: .syncPending, attachedTo: folded.id)

        let selection = PersonalWorkbenchRouter.gallerySelection(desk: [folded], tapped: folded)

        XCTAssertEqual(selection.companion(forPage: folded.id)?.availability, .syncPending)
        XCTAssertFalse(
            WorkboardCardActionPolicy.allows(.play, when: .syncPending),
            "and the band asks the recording's own state for permission to play"
        )
    }

    /// The map is built from the pages that ACTUALLY open, so the lone-card
    /// fallback keeps its recording: a board that reloaded underneath the
    /// gesture must not open the picture stripped of half of what it is.
    func testTheLoneCardFallbackKeepsItsRecording() {
        var folded = image("Screenshot")
        folded.companion = recording("Voice note", attachedTo: folded.id)

        let selection = PersonalWorkbenchRouter.gallerySelection(
            desk: (1...3).map { image("Photo \($0)") },
            tapped: folded
        )

        XCTAssertEqual(selection.pages.map(\.id), [folded.id])
        XCTAssertEqual(selection.companion(forPage: folded.id)?.name, "Voice note")
    }

    // MARK: - What one page carries

    /// The label VoiceOver speaks is the card's own name — the words the person
    /// reads on the desk — and never a position, which the gallery's own page
    /// control already conveys.
    func testAPageCarriesTheCardsNameAndItsPreviewBytes() {
        let thumbnail = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let card = image("Kitchen sketch", thumbnail: thumbnail)

        let page = PersonalWorkbenchRouter.galleryPage(for: card)

        XCTAssertEqual(page.id, card.id, "the id is the key the loader resolves the original with")
        XCTAssertEqual(page.thumbnailData, thumbnail)
        XCTAssertEqual(page.accessibilityLabel, "Kitchen sketch")
        XCTAssertEqual(
            page.title,
            "Kitchen sketch",
            "the header names the card exactly as the desk does"
        )
    }
}
