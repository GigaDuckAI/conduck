// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardOpenPathTests.swift
//
// The one rule every desk card obeys before anything is opened, played, shared
// or repaired: what a card offers is decided by what its bytes actually are on
// THIS device, and it is decided in one place.
//
// The two states that are not "readable bytes here" are the whole subject. A
// card whose bytes are gone may be repaired and nothing else; a card whose bytes
// are still arriving through the person's own iCloud may do NOTHING — opening it
// would present a thumbnail in place of the material, and offering to reattach
// it would ask for work that is already happening. These tests hold both the
// policy that says so and the two places that must not be able to disagree with
// it: the board card's tap funnel and the preview router.

import UniformTypeIdentifiers
import XCTest
@testable import Conduck

@MainActor
final class WorkboardOpenPathTests: XCTestCase {

    // MARK: - The policy

    /// Every availability state, and the exact set of things it permits. The
    /// policy's own switch is exhaustive, so a new state cannot be added without
    /// deciding this; these rows pin what the four existing ones decided.
    func testEveryAvailabilityStateMapsToItsOwnActionSet() {
        XCTAssertEqual(
            WorkboardCardActionPolicy.actions(for: .available),
            [.open, .play],
            "bytes that are readable here permit both verbs"
        )
        XCTAssertEqual(
            WorkboardCardActionPolicy.actions(for: .localOnly),
            [.open, .play],
            "bytes that never left the device are still bytes this device can read"
        )
        XCTAssertEqual(
            WorkboardCardActionPolicy.actions(for: .unavailableOnThisDevice),
            [.reattach],
            "bytes only the person can bring back permit the repair and nothing else"
        )
        XCTAssertEqual(
            WorkboardCardActionPolicy.actions(for: .syncPending),
            [],
            "bytes still arriving permit nothing: there is nothing to open and nothing to repair"
        )

        XCTAssertEqual(WorkboardCardActionPolicy.primaryAction(for: .available), .open)
        XCTAssertEqual(WorkboardCardActionPolicy.primaryAction(for: .localOnly), .open)
        XCTAssertEqual(
            WorkboardCardActionPolicy.primaryAction(for: .unavailableOnThisDevice),
            .reattach
        )
        XCTAssertNil(
            WorkboardCardActionPolicy.primaryAction(for: .syncPending),
            "a waiting card is not a control at all"
        )

        // Playback is a permission, never a tile's verb: an audio card owns its
        // own transport and asks for the permission rather than being routed.
        XCTAssertTrue(WorkboardCardActionPolicy.allows(.play, when: .available))
        XCTAssertTrue(WorkboardCardActionPolicy.allows(.play, when: .localOnly))
        XCTAssertFalse(WorkboardCardActionPolicy.allows(.play, when: .unavailableOnThisDevice))
        XCTAssertFalse(WorkboardCardActionPolicy.allows(.play, when: .syncPending))
    }

    /// The tap funnel the desk canvas drives. A waiting card must reach neither
    /// the preview router nor the file importer — before this rule existed it
    /// reached the router, which opened the card's thumbnail in place of the
    /// image it stands for.
    func testASyncPendingCardInvokesNeitherOpenPlayNorReattach() {
        var opened = 0
        var reattached = 0

        WorkboardCardActionPolicy.performPrimaryAction(
            for: .syncPending,
            open: { opened += 1 },
            reattach: { reattached += 1 }
        )

        XCTAssertEqual(opened, 0, "a waiting card never reaches the preview router")
        XCTAssertEqual(reattached, 0, "and is never offered a repair it does not need")
        XCTAssertFalse(WorkboardCardActionPolicy.allows(.play, when: .syncPending))
    }

    func testAReadableCardOnlyOpensAndAMissingOneOnlyRepairs() {
        for readable in [WorkboardMaterialAvailability.available, .localOnly] {
            var opened = 0
            var reattached = 0
            WorkboardCardActionPolicy.performPrimaryAction(
                for: readable,
                open: { opened += 1 },
                reattach: { reattached += 1 }
            )
            XCTAssertEqual(opened, 1, "\(readable) opens")
            XCTAssertEqual(reattached, 0, "\(readable) is not damaged, so it is never repaired")
        }

        var opened = 0
        var reattached = 0
        WorkboardCardActionPolicy.performPrimaryAction(
            for: .unavailableOnThisDevice,
            open: { opened += 1 },
            reattach: { reattached += 1 }
        )
        XCTAssertEqual(reattached, 1, "bytes that are gone are repaired")
        XCTAssertEqual(opened, 0, "and never opened, because there is nothing behind the card")
    }

    // MARK: - The router boundary

    /// Opening, previewing, sharing and playing all run through one presenter,
    /// so the gate lives there too: a caller that skipped the card's own gate
    /// must still be refused, and refused with copy that matches the state.
    func testTheRouterRefusesACardWhoseBytesAreNotReadableHere() async throws {
        let router = PersonalWorkbenchRouter()

        // A pending image carries a thumbnail. That thumbnail is a preview of
        // the material, never the material: presenting it would tell a person
        // their picture had arrived.
        let pending = WorkboardMaterialSnapshot(
            kind: .image,
            name: "Screenshot",
            mimeType: "image/png",
            thumbnailData: Data([0x89, 0x50, 0x4E, 0x47]),
            availability: .syncPending
        )
        // The desk it sits on is full of openable pictures. A waiting card must
        // not ride into the gallery on its neighbours' readability.
        router.deskMaterials = { [
            WorkboardMaterialSnapshot(kind: .image, name: "Photo 1", availability: .available),
            pending,
            WorkboardMaterialSnapshot(kind: .image, name: "Photo 2", availability: .available)
        ] }

        await router.present(pending)
        XCTAssertNil(router.materialPresentation, "a waiting card opens nothing")
        XCTAssertNil(
            router.filePreview.previewURL,
            "and never reaches Quick Look either"
        )
        let pendingMessage = try XCTUnwrap(
            router.previewNotice?.message,
            "a refusal says why rather than failing silently"
        )
        XCTAssertFalse(pendingMessage.isEmpty)

        let missing = WorkboardMaterialSnapshot(
            kind: .file,
            name: "Contract",
            mimeType: "application/pdf",
            availability: .unavailableOnThisDevice
        )
        await router.present(missing)
        XCTAssertNil(router.materialPresentation)
        XCTAssertNil(router.filePreview.previewURL)
        let missingMessage = try XCTUnwrap(router.previewNotice?.message)
        XCTAssertFalse(missingMessage.isEmpty)

        // The two refusals are different situations for a person: one asks for
        // the file back, the other asks for nothing at all. Sharing one sentence
        // is the defect — a card whose bytes are already on their way was being
        // told to reattach them.
        XCTAssertNotEqual(pendingMessage, missingMessage)
    }

    /// The positive control: the gate refuses states, not materials. Without
    /// this a guard that refused everything would pass every assertion above.
    func testTheRouterStillPresentsAReadableCard() async throws {
        let router = PersonalWorkbenchRouter()
        let note = WorkboardMaterialSnapshot(
            kind: .note,
            name: "Thought",
            textContent: "Ask about the lease",
            availability: .available
        )

        await router.present(note)

        XCTAssertNil(router.previewNotice, "a readable card explains nothing")
        let presentation = try XCTUnwrap(router.materialPresentation)
        XCTAssertEqual(presentation.title, "Thought")
        guard case .note(let text) = presentation.content else {
            return XCTFail("a note presents as a note")
        }
        XCTAssertEqual(text, "Ask about the lease")
    }

    /// An image is a GALLERY, whichever lane holds its bytes. The router reads
    /// no bytes to decide that — a card too large to sync used to fall into the
    /// file branch and open as a document, and the size of a picture is not a
    /// fact about what it is.
    func testAnImageCardOfEitherLanePresentsAsAGallery() async throws {
        for availability in [WorkboardMaterialAvailability.available, .localOnly] {
            let router = PersonalWorkbenchRouter()
            let photo = WorkboardMaterialSnapshot(
                kind: .image,
                name: "Photo 3",
                mimeType: "image/jpeg",
                byteCount: 41_000_000,
                availability: availability
            )
            router.deskMaterials = { [photo] }

            await router.present(photo)

            XCTAssertNil(router.previewNotice, "\(availability) opens without explanation")
            let presentation = try XCTUnwrap(router.materialPresentation)
            guard case .imageGallery(let pages, let startIndex) = presentation.content else {
                return XCTFail("an image card presents as a gallery on the \(availability) lane")
            }
            XCTAssertEqual(pages.map(\.id), [photo.id])
            XCTAssertEqual(startIndex, 0)
            XCTAssertNil(
                router.filePreview.previewURL,
                "a picture is never handed to Quick Look, so no disposable copy is made for it"
            )
        }
    }

    // MARK: - What the preview copy is called

    /// A card's name is a TITLE — a recording's is "Voice note" — while Quick
    /// Look, the share sheet and every receiving app decide what a file is from
    /// its extension alone. A disposable preview copy must therefore be named
    /// for the bytes it holds, not for the card it came from.
    func testAPreviewCopyIsNamedWithAnExtensionItsBytesActuallyClaim() throws {
        let recording = PersonalWorkbenchRouter.previewFilename(
            displayName: "Voice note",
            mimeType: "audio/mp4"
        )
        let recordingExtension = (recording as NSString).pathExtension
        XCTAssertFalse(
            recordingExtension.isEmpty,
            "a recording preview is never handed over as an extensionless file"
        )

        // The exact spelling belongs to the system's own type table, not to
        // this test: what must hold is that the extension is one the recorded
        // mime type claims, and that it names playable media.
        let audio = try XCTUnwrap(UTType(mimeType: "audio/mp4"))
        XCTAssertEqual(
            audio.tags[.filenameExtension]?.contains(recordingExtension),
            true
        )
        let resolved = try XCTUnwrap(UTType(filenameExtension: recordingExtension))
        XCTAssertTrue(resolved.conforms(to: .audiovisualContent))

        // A name that already states its type keeps it, extension and all.
        XCTAssertEqual(
            PersonalWorkbenchRouter.previewFilename(displayName: "rows.csv", mimeType: "text/csv"),
            "rows.csv"
        )
        // A title that merely ENDS like a filename states nothing, so the bytes
        // still get to name themselves.
        XCTAssertEqual(
            PersonalWorkbenchRouter.previewFilename(
                displayName: "Meeting v1.2",
                mimeType: "application/pdf"
            ),
            "Meeting v1.2.pdf"
        )
        // Nothing to derive from is still better than a guess.
        XCTAssertEqual(
            PersonalWorkbenchRouter.previewFilename(displayName: "Voice note", mimeType: nil),
            "Voice note"
        )
    }
}
