// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardOpenPathTests.swift
//
// Source bytes still gate native preview, sharing and playback. Material
// details are independently available so a pending or missing file's notes
// can be read and edited without opening a thumbnail as the original file.

import UniformTypeIdentifiers
import XCTest
@testable import Conduck

@MainActor
final class WorkboardOpenPathTests: XCTestCase {

    // MARK: - Metadata and source-byte permissions

    func testDetailsAreAvailableWhileSourceActionsRemainGated() {
        let rows: [(WorkboardMaterialAvailability, Set<WorkboardCardAction>)] = [
            (.available, [.details, .open, .play]),
            (.localOnly, [.details, .open, .play]),
            (.unavailableOnThisDevice, [.details, .reattach]),
            (.syncPending, [.details])
        ]
        for (availability, expected) in rows {
            XCTAssertEqual(WorkboardCardActionPolicy.actions(for: availability), expected)
            XCTAssertEqual(WorkboardCardActionPolicy.primaryAction(for: availability), .details)
            var opened = 0
            var reattached = 0
            WorkboardCardActionPolicy.performPrimaryAction(
                for: availability, open: { opened += 1 }, reattach: { reattached += 1 }
            )
            XCTAssertEqual(opened, 1, "Every material opens its notes and details")
            XCTAssertEqual(reattached, 0, "Opening details never asks to replace a file")
            XCTAssertEqual(WorkboardCardActionPolicy.allows(.open, when: availability), availability.isAvailable)
            XCTAssertEqual(WorkboardCardActionPolicy.allows(.play, when: availability), availability.isAvailable)
        }
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

        await router.openOriginal(pending)
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
        await router.openOriginal(missing)
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

        await router.openOriginal(note)

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

            await router.openOriginal(photo)

            XCTAssertNil(router.previewNotice, "\(availability) opens without explanation")
            let presentation = try XCTUnwrap(router.materialPresentation)
            guard case .imageGallery(let gallery) = presentation.content else {
                return XCTFail("an image card presents as a gallery on the \(availability) lane")
            }
            XCTAssertEqual(gallery.pages.map(\.id), [photo.id])
            XCTAssertEqual(gallery.startIndex, 0)
            XCTAssertNil(
                router.filePreview.previewURL,
                "a picture is never handed to Quick Look, so no disposable copy is made for it"
            )
        }
    }

    /// The tap carried a snapshot; the desk moved before the presentation ran.
    ///
    /// `present` is scheduled from the gesture rather than run inside it, so a
    /// peer's reattach can land in between and put the card back on `.syncPending`
    /// while its replacement bytes travel. The gate has to answer for the card
    /// the desk holds NOW — with the stale snapshot it passes, and the gallery
    /// then shows the card's thumbnail as though the picture had arrived.
    func testAStaleReadableTapIsRefusedWhenTheDeskCardIsNoLongerReadable() async throws {
        let router = PersonalWorkbenchRouter()
        let cardID = UUID()
        // What the gesture captured: readable, with a preview.
        let tapped = WorkboardMaterialSnapshot(
            id: cardID,
            kind: .image,
            name: "Kitchen sketch",
            mimeType: "image/jpeg",
            thumbnailData: Data([0xFF, 0xD8, 0xFF, 0xE0]),
            availability: .available
        )
        // What the desk holds by the time the presentation runs.
        let refreshed = WorkboardMaterialSnapshot(
            id: cardID,
            kind: .image,
            name: "Kitchen sketch",
            mimeType: "image/jpeg",
            thumbnailData: Data([0xFF, 0xD8, 0xFF, 0xE0]),
            availability: .syncPending
        )
        router.deskMaterials = { [
            WorkboardMaterialSnapshot(kind: .image, name: "Photo 1", availability: .available),
            refreshed
        ] }

        await router.openOriginal(tapped)

        XCTAssertNil(
            router.materialPresentation,
            "the desk's own verdict decides, not the snapshot the tap carried"
        )
        let message = try XCTUnwrap(
            router.previewNotice?.message,
            "the refusal is explained, and with the CURRENT state's words"
        )
        XCTAssertFalse(message.isEmpty)
    }

    /// The positive control for the same resolution: a tap whose card the desk
    /// no longer carries at all still opens. A board that reloaded underneath
    /// the gesture must not turn into a dead tap on a card that is on screen.
    func testATapOnACardTheDeskNoLongerCarriesStillOpens() async throws {
        let router = PersonalWorkbenchRouter()
        let photo = WorkboardMaterialSnapshot(
            kind: .image,
            name: "Photo 9",
            mimeType: "image/jpeg",
            availability: .available
        )
        router.deskMaterials = { [
            WorkboardMaterialSnapshot(kind: .image, name: "Photo 1", availability: .available)
        ] }

        await router.openOriginal(photo)

        XCTAssertNil(router.previewNotice)
        let presentation = try XCTUnwrap(router.materialPresentation)
        guard case .imageGallery(let gallery) = presentation.content else {
            return XCTFail("an image card presents as a gallery")
        }
        XCTAssertEqual(
            gallery.pages.map(\.id), [photo.id], "it opens alone, on the card that was tapped"
        )
        XCTAssertEqual(gallery.startIndex, 0)
    }

    // MARK: - Links

    /// A link card opens the address, and opens it in the browser. There is no
    /// sheet: the card's whole content IS the URL, so a preview of it could
    /// only restate the address and offer the button the click already meant.
    func testALinkCardOpensItsAddressAndRaisesNoSheet() async throws {
        let router = PersonalWorkbenchRouter()
        var opened: [URL] = []
        router.openExternalURL = { opened.append($0) }
        let link = WorkboardMaterialSnapshot(
            kind: .link,
            name: "example.com",
            urlString: "https://example.com/a-page",
            availability: .available
        )

        await router.openOriginal(link)

        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.com/a-page"])
        XCTAssertNil(router.materialPresentation, "the browser is the surface, not a sheet of ours")
        XCTAssertNil(router.previewNotice)
        XCTAssertNil(router.filePreview.previewURL)
    }

    /// The availability gate still answers first. A link whose card the desk
    /// has moved to an unreadable state opens nothing at all — the gate is one
    /// rule for every kind, and the direct route must not become the way around
    /// it.
    func testALinkOnAnUnreadableCardOpensNothing() async throws {
        for refused in [
            WorkboardMaterialAvailability.syncPending,
            .unavailableOnThisDevice
        ] {
            let router = PersonalWorkbenchRouter()
            var opened: [URL] = []
            router.openExternalURL = { opened.append($0) }
            let link = WorkboardMaterialSnapshot(
                kind: .link,
                name: "example.com",
                urlString: "https://example.com/a-page",
                availability: refused
            )

            await router.openOriginal(link)

            XCTAssertTrue(opened.isEmpty, "\(refused) reaches no browser")
            XCTAssertNil(router.materialPresentation)
            XCTAssertNotNil(router.previewNotice, "and says why rather than failing silently")
        }
    }

    /// A link card with nothing to open is a refusal, not a browser launch.
    func testALinkCardWithNoAddressIsRefused() async throws {
        let router = PersonalWorkbenchRouter()
        var opened: [URL] = []
        router.openExternalURL = { opened.append($0) }

        await router.openOriginal(WorkboardMaterialSnapshot(
            kind: .link,
            name: "Broken",
            urlString: nil,
            availability: .available
        ))

        XCTAssertTrue(opened.isEmpty)
        XCTAssertNotNil(router.previewNotice)
    }

    // MARK: - What the preview copy is called

    /// A card's name is a TITLE — a recording's is "Voice note" — while Quick
    /// Look, the share sheet and every receiving app decide what a file is from
    /// its extension alone. A disposable copy must therefore be named for the
    /// bytes it holds, not for the card it came from.
    ///
    /// The naming lives on `WorkMaterialExportSnapshot`, which is what BOTH the
    /// preview lane and the share lane copy through — the parity these rows pin
    /// only means something because there is one implementation to pin.
    func testAPreviewCopyIsNamedWithAnExtensionItsBytesActuallyClaim() throws {
        let recording = WorkMaterialExportSnapshot.filename(
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
            WorkMaterialExportSnapshot.filename(displayName: "rows.csv", mimeType: "text/csv"),
            "rows.csv"
        )
        // A title that merely ENDS like a filename states nothing, so the bytes
        // still get to name themselves.
        XCTAssertEqual(
            WorkMaterialExportSnapshot.filename(
                displayName: "Meeting v1.2",
                mimeType: "application/pdf"
            ),
            "Meeting v1.2.pdf"
        )
        // Nothing to derive from is still better than a guess.
        XCTAssertEqual(
            WorkMaterialExportSnapshot.filename(displayName: "Voice note", mimeType: nil),
            "Voice note"
        )
    }

    /// The folded sheet deliberately KEEPS a companion whose bytes have not
    /// landed — the band names the recording and says what it is waiting for —
    /// but it must not also offer VoiceOver a Play that returns the instant it
    /// is invoked. A rotor action that does nothing and reports nothing is the
    /// one refusal a screen-reader user cannot detect, and it is worse than no
    /// action at all: the person is told playback exists and then gets silence.
    ///
    /// A source check because the defect is a modifier on a private SwiftUI
    /// view; what it holds is that the action is BEHIND the same readability
    /// gate `play()` returns on, so the two cannot drift apart.
    func testAnUnplayableFoldedRecordingOffersNoPlaybackAction() throws {
        let source = try RefusalLaneSource.source(
            at: "Conduck/Views/Workboard/PersonalWorkbenchView.swift"
        )
        let band = try XCTUnwrap(
            source.range(of: "private struct WorkboardGalleryCompanionBand"),
            "the folded card's bottom band must still be where this rule lives"
        )
        let tail = String(source[band.upperBound...])
        // Bounded at the next top-level declaration, so a rule that moved out
        // of this view cannot be satisfied by a match somewhere else.
        let body = tail.range(of: "\nprivate struct ").map { String(tail[..<$0.lowerBound]) } ?? tail

        XCTAssertFalse(
            body.contains("accessibilityAction(named:"),
            "the unconditional installer is what advertised a Play that did nothing"
        )
        let gate = try XCTUnwrap(
            body.range(of: "accessibilityActions {"),
            """
            The playback action must be declared CONDITIONALLY.             `accessibilityAction(named:)` installs unconditionally, which is             how an unreadable recording ended up advertising a Play that             silently returned.
            """
        )
        let gated = String(body[gate.upperBound...].prefix(240))
        XCTAssertTrue(
            gated.contains("if isPlayable"),
            "the action is offered only where the recording's own bytes permit it"
        )
        XCTAssertTrue(
            body.contains("WorkboardCardActionPolicy.allows(.play, when: companion.availability)"),
            """
            And the gate is the POLICY's answer for the recording, never the             picture's readability — a readable picture can be folded with a             recording that is still arriving.
            """
        )
    }

    /// The same band opened over a picture whose companion is WORDS. There is no
    /// clip, so the sheet draws no transport, no availability chip and no
    /// progress track — a control that fails on every tap, a sentence about
    /// bytes that were never coming, and a bar that can never move — and it
    /// spends that height on the text instead, because the sheet is where the
    /// whole note is meant to be readable.
    ///
    /// A source check for the same reason the case above is one: the rules live
    /// as modifiers and subviews inside a private SwiftUI view.
    ///
    /// Negative control: leaving the transport unconditional puts a dead 40pt
    /// Play button on every words-only sheet — the branch count is 0 or 1 and
    /// this fails.
    func testAWordsOnlyCompanionOpensAsTextWithNoTransport() throws {
        let source = try RefusalLaneSource.source(
            at: "Conduck/Views/Workboard/PersonalWorkbenchView.swift"
        )
        let band = try XCTUnwrap(
            source.range(of: "private struct WorkboardGalleryCompanionBand"),
            "the folded card's bottom band must still be where this rule lives"
        )
        let tail = String(source[band.upperBound...])
        let body = tail.range(of: "\nprivate struct ").map { String(tail[..<$0.lowerBound]) } ?? tail

        XCTAssertEqual(
            body.components(separatedBy: "if companion.kind == .audio {").count - 1, 2,
            "the transport and the progress track are each drawn only for a recording"
        )
        XCTAssertTrue(
            body.contains("guard companion.kind == .audio, !isPlayable else { return nil }"),
            "the availability chip is about bytes, so words draw none"
        )
        // Playback is refused at the SAME gate the rotor action is offered
        // behind, so a words-only companion advertises nothing it cannot do.
        let playable = try XCTUnwrap(
            body.range(of: "private var isPlayable: Bool {"),
            "no `isPlayable` — update this guard"
        )
        let gate = String(body[playable.upperBound...].prefix(200))
        XCTAssertTrue(gate.contains("companion.kind == .audio"), gate)
        XCTAssertTrue(
            gate.contains("WorkboardCardActionPolicy.allows(.play, when: companion.availability)"),
            gate
        )

        // And the words get the height the transport gave up: a fixed two-line
        // clamp here would truncate the very thing the picture was opened for.
        XCTAssertTrue(body.contains("lineLimit(transcriptLineLimit)"), body)
        XCTAssertTrue(
            body.contains("companion.kind == .audio ? 2 : 8"),
            "a recording's band captions the clip; a words-only band IS the note"
        )
    }
}
