// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardCardFacePolicyTests.swift
//
// A Work card says each thing ONCE. These are the rules behind that, asserted
// as pure logic because the alternative is reading a rendered tile: the tile,
// the list row and the spoken label all build themselves from this policy, so a
// rule proved here is a rule all three obey.
//
// The three duplications this replaced, each of which shipped: a note's title
// is its own first line, so the tile drew "hi" over "hi"; the accessibility
// builder appended the name and then the whole body, so VoiceOver read the same
// sentence twice; and the projection folds an availability sentence into
// `detail`, which the card then drew a second time beside its availability
// glyph.

import XCTest
@testable import Conduck

@MainActor
final class WorkboardCardFacePolicyTests: XCTestCase {

    private func note(
        name: String,
        text: String?,
        availability: WorkboardMaterialAvailability = .available
    ) -> WorkboardMaterialSnapshot {
        WorkboardMaterialSnapshot(
            kind: .note,
            name: name,
            textContent: text,
            availability: availability
        )
    }

    // MARK: - The heading a body already says

    /// The screenshot case: a one-line note titled with that same line.
    func testAHeadingEqualToTheBodyIsSuppressedAndTheBodySurvives() {
        let face = WorkboardCardFacePolicy.face(for: note(name: "hi", text: "hi"))
        XCTAssertNil(face.heading, "the tile drew the same word twice")
        XCTAssertEqual(face.excerpt, "hi", "the note's only sentence must never be the thing dropped")
        XCTAssertEqual(face.leadLine, "hi", "a suppressed heading leaves the body to lead")
        XCTAssertNil(face.trailingExcerpt, "and nothing under it to repeat it")
    }

    /// Equality alone misses the longer note: capture cuts the first line at 72
    /// characters, so the title is a PREFIX of a body that runs on.
    func testAHeadingEqualToTheGeneratedSeventyTwoCharacterPrefixIsSuppressed() {
        let body = String(repeating: "a", count: 90) + "\nand a second line"
        let generated = WorkboardWorkspaceCaptureLogic.title(for: body)
        XCTAssertEqual(generated.count, 72, "the capture rule this policy mirrors")

        let face = WorkboardCardFacePolicy.face(for: note(name: generated, text: body))
        XCTAssertNil(face.heading)
        XCTAssertEqual(face.excerpt, body, "the body keeps every word, including its lead line")
    }

    /// A multi-line note titled with its own first line is the same defect.
    func testAHeadingEqualToTheBodysFirstLineIsSuppressed() {
        let body = "Ask the harbour office\nabout the winter timetable"
        let face = WorkboardCardFacePolicy.face(for: note(name: "Ask the harbour office", text: body))
        XCTAssertNil(face.heading)
        XCTAssertEqual(face.excerpt, body)
    }

    /// The rule stops exactly where the title starts carrying information the
    /// body does not. A chat-captured note is titled by its provenance, and the
    /// record does not store why a title exists — so it is kept.
    func testAnIndependentlyMeaningfulTitleIsKept() {
        let face = WorkboardCardFacePolicy.face(
            for: note(name: "Chat response", text: "Ask the harbour office about the timetable")
        )
        XCTAssertEqual(face.heading, "Chat response")
        XCTAssertEqual(face.excerpt, "Ask the harbour office about the timetable")
        XCTAssertEqual(face.leadLine, "Chat response")
        XCTAssertEqual(face.trailingExcerpt, "Ask the harbour office about the timetable")
    }

    /// The one generic title the desk wrote for itself. It names the ROUTE, not
    /// the content, so a card carrying it says nothing its body does not — and
    /// it is suppressed at DISPLAY, never rewritten in the store.
    func testTheLegacyShareNoteTitleIsSuppressedAtDisplay() {
        let legacy = String(localized: "workboard.capture.note", defaultValue: "Share note")
        let face = WorkboardCardFacePolicy.face(for: note(name: legacy, text: "Compare with the current plan"))
        XCTAssertNil(face.heading)
        XCTAssertEqual(face.excerpt, "Compare with the current plan")
    }

    /// A generic title with nothing under it still has to draw something: the
    /// suppression removes a repeat, not the card's only words.
    func testAGenericTitleWithNoBodyIsKeptRatherThanLeavingABlankCard() {
        let legacy = String(localized: "workboard.capture.note", defaultValue: "Share note")
        let face = WorkboardCardFacePolicy.face(for: note(name: legacy, text: nil))
        XCTAssertEqual(face.heading, legacy)
        XCTAssertNil(face.excerpt)
    }

    // MARK: - The recording

    /// A recording's title IS its transcript's lead line — the publication lane
    /// writes it there — so a voice note duplicates itself exactly as a typed
    /// note does, and the transcript is what carries the card.
    ///
    /// The fixture's name comes from the production helper on purpose: an
    /// arbitrary shorter prefix is NOT a title the desk ever writes, and
    /// hand-typing one would assert against a card that cannot exist.
    func testAVoiceNoteLeadsWithItsTranscriptRatherThanRepeatingItsName() {
        let transcript = "Ship the review before Friday\nthen look at the winter timetable"
        let name = WorkVoiceCaptureCoordinator.title(forTranscript: transcript)
        XCTAssertEqual(name, "Ship the review before Friday", "the name the publication lane writes")

        let recording = WorkboardMaterialSnapshot(kind: .audio, name: name, textContent: transcript)
        let face = WorkboardCardFacePolicy.face(for: recording)
        XCTAssertNil(face.heading)
        XCTAssertEqual(face.excerpt, transcript)
    }

    /// A spoken note leads with its words rather than repeating its name. Its
    /// title is the same generated lead line, written by the same publication
    /// lane, so the suppression rule that fixes a typed note and a recording has
    /// to fix this shape too — otherwise the one card the voice lanes now write
    /// is the one card that says its first line twice.
    func testASpokenNoteLeadsWithItsWordsRatherThanRepeatingItsName() {
        let words = "Ship the review before Friday\nthen look at the winter timetable"
        let name = WorkVoiceCaptureCoordinator.title(forTranscript: words)
        XCTAssertEqual(name, "Ship the review before Friday", "the name the publication lane writes")

        let spoken = WorkboardMaterialSnapshot(kind: .transcript, name: name, textContent: words)
        let face = WorkboardCardFacePolicy.face(for: spoken)
        XCTAssertNil(face.heading)
        XCTAssertEqual(face.excerpt, words)
        XCTAssertTrue(face.showsAge, "when the words were spoken is part of what the card says")
    }

    /// The same boundary the recording has: a title nothing generated is the
    /// person's own row and survives, however much of the body it repeats.
    func testASpokenNoteKeepsATitleTheCaptureLaneDidNotGenerate() {
        let body = "Ship the review before Friday, then look at the winter timetable"
        let spoken = WorkboardMaterialSnapshot(
            kind: .transcript,
            name: "Ship the review",
            textContent: body
        )
        let face = WorkboardCardFacePolicy.face(for: spoken)
        XCTAssertEqual(face.heading, "Ship the review")
        XCTAssertEqual(face.excerpt, body)
    }

    /// The boundary the other way: a name that is SOME prefix of the body but
    /// not the one capture generates is a title somebody chose, so it stays.
    /// Suppression mirrors a known capture rule; it is not a substring test.
    func testAnArbitraryShorterPrefixOfTheBodyIsKeptAsATitle() {
        let body = "Ship the review before Friday, then look at the winter timetable"
        let face = WorkboardCardFacePolicy.face(for: note(name: "Ship the review", text: body))
        XCTAssertEqual(face.heading, "Ship the review")
        XCTAssertEqual(face.excerpt, body)
    }

    /// `title(for:)` cuts the lead line at 72 characters without re-trimming,
    /// so a line whose 72nd character is a space is STORED with that space.
    /// Both sides normalise, or the card keeps a heading and a body that differ
    /// by one invisible character.
    func testAGeneratedTitleEndingInWhitespaceStillMatchesItsBody() {
        let body = String(repeating: "a", count: 71) + " and the rest of the line"
        let generated = WorkboardWorkspaceCaptureLogic.title(for: body)
        XCTAssertEqual(generated.count, 72)
        XCTAssertTrue(generated.hasSuffix(" "), "the cut lands on the space this test exists for")

        let face = WorkboardCardFacePolicy.face(for: note(name: generated, text: body))
        XCTAssertNil(face.heading, "a trailing space is not a difference a person can see")
        XCTAssertEqual(face.excerpt, body)

        let recording = WorkboardMaterialSnapshot(kind: .audio, name: generated, textContent: body)
        XCTAssertNil(WorkboardCardFacePolicy.face(for: recording).heading, "same rule for a clip")
    }

    /// With no words there is nothing to lead with but the name — plus the
    /// capture time, which is the one other thing the record actually holds. A
    /// length is NOT: nothing measures a clip until it is decoded.
    func testAnUntranscribedRecordingKeepsItsNameAndItsCaptureTime() {
        let recording = WorkboardMaterialSnapshot(kind: .audio, name: "Voice note", byteCount: 48_000)
        let face = WorkboardCardFacePolicy.face(for: recording)
        XCTAssertEqual(face.heading, "Voice note")
        XCTAssertNil(face.excerpt)
        XCTAssertTrue(face.showsAge)
        XCTAssertNil(face.meta, "a recording's card states no size and no duration")
    }

    // MARK: - Link

    /// Title primary, host always kept, and a path excerpt only where it says
    /// which page this is.
    func testALinkKeepsItsHostBesideAMeaningfulTitle() {
        let link = WorkboardMaterialSnapshot(
            kind: .link,
            name: "Winter timetable",
            urlString: "https://example.com/travel/winter?year=2026"
        )
        let face = WorkboardCardFacePolicy.face(for: link)
        XCTAssertEqual(face.heading, "Winter timetable")
        XCTAssertEqual(face.identity, "example.com")
        XCTAssertEqual(face.excerpt, "/travel/winter?year=2026")
    }

    /// A name the projection derived FROM the URL is not a title, so the host
    /// leads — and it is then not repeated underneath.
    func testALinkNamedAfterItsHostSaysTheHostOnce() {
        let link = WorkboardMaterialSnapshot(
            kind: .link,
            name: "example.com",
            urlString: "https://example.com"
        )
        let face = WorkboardCardFacePolicy.face(for: link)
        XCTAssertEqual(face.heading, "example.com")
        XCTAssertNil(face.identity)
        XCTAssertNil(face.excerpt, "a bare host has no path that distinguishes anything")
    }

    /// A root path distinguishes nothing, so it draws nothing rather than a
    /// decorative slash under the host that already said it.
    func testARootPathIsNotAnExcerpt() {
        let link = WorkboardMaterialSnapshot(
            kind: .link,
            name: "Example",
            urlString: "https://example.com/"
        )
        XCTAssertNil(WorkboardCardFacePolicy.face(for: link).excerpt)
    }

    /// A client-routed app puts its whole route after the "#". Two such cards
    /// on one host, sharing a title, would otherwise draw one identical face
    /// and speak one identical label for two different pages.
    func testAFragmentRouteIsWhatDistinguishesTwoLinksOnOneHost() {
        func face(_ url: String) -> WorkboardCardFace {
            WorkboardCardFacePolicy.face(
                for: WorkboardMaterialSnapshot(kind: .link, name: "Mail", urlString: url)
            )
        }
        let inbox = face("https://example.com/#/inbox")
        let archive = face("https://example.com/#/archive")
        XCTAssertEqual(inbox.excerpt, "#/inbox")
        XCTAssertEqual(archive.excerpt, "#/archive")
        XCTAssertNotEqual(inbox.spokenParts, archive.spokenParts, "two routes, two spoken labels")
    }

    /// An explicit port is part of WHICH destination this is. Two local
    /// services differ in nothing else, so a face that dropped it drew — and
    /// spoke — one card for both.
    func testAnExplicitPortDistinguishesTwoLinksOnOneHost() {
        func face(_ url: String) -> WorkboardCardFace {
            WorkboardCardFacePolicy.face(
                for: WorkboardMaterialSnapshot(kind: .link, name: "localhost", urlString: url)
            )
        }
        let web = face("http://localhost:3000/")
        let api = face("http://localhost:8080/")
        XCTAssertEqual(web.heading, "localhost:3000")
        XCTAssertEqual(api.heading, "localhost:8080")
        XCTAssertNotEqual(web.spokenParts, api.spokenParts, "two ports, two spoken labels")
    }

    /// The repository names a link after its BARE host, so that name is still a
    /// derived one once the face has put the port back on: it must not be
    /// promoted to a title and then repeated as identity underneath.
    func testAPortedLinkNamedAfterItsHostStillSaysTheHostOnce() {
        let link = WorkboardMaterialSnapshot(
            kind: .link,
            name: "localhost",
            urlString: "http://localhost:3000/dashboard"
        )
        let face = WorkboardCardFacePolicy.face(for: link)
        XCTAssertEqual(face.heading, "localhost:3000")
        XCTAssertNil(face.identity)
        XCTAssertEqual(face.excerpt, "/dashboard")
    }

    /// A titled link keeps the ported host as its identity, exactly as an
    /// ordinary one keeps the bare host.
    func testATitledLinkKeepsItsPortedHostAsIdentity() {
        let link = WorkboardMaterialSnapshot(
            kind: .link,
            name: "Local dashboard",
            urlString: "http://localhost:8080/status"
        )
        let face = WorkboardCardFacePolicy.face(for: link)
        XCTAssertEqual(face.heading, "Local dashboard")
        XCTAssertEqual(face.identity, "localhost:8080")
    }

    /// Only a port the address actually states. An ordinary `https://` link
    /// carries none, so nothing about it changes.
    func testAnImplicitPortIsNeverInvented() {
        XCTAssertEqual(
            WorkboardCardFacePolicy.hostLabel(of: URLComponents(string: "https://example.com/a")),
            "example.com"
        )
        XCTAssertEqual(
            WorkboardCardFacePolicy.hostLabel(of: URLComponents(string: "https://example.com:8443/a")),
            "example.com:8443"
        )
        XCTAssertNil(WorkboardCardFacePolicy.hostLabel(of: URLComponents(string: "notaurl")))
    }

    /// The fragment lands AFTER the query, in the order the address reads.
    func testAFragmentFollowsTheQueryInTheExcerpt() {
        let link = WorkboardMaterialSnapshot(
            kind: .link,
            name: "Winter timetable",
            urlString: "https://example.com/travel?year=2026#platform"
        )
        XCTAssertEqual(WorkboardCardFacePolicy.face(for: link).excerpt, "/travel?year=2026#platform")
    }

    // MARK: - File and image

    /// The filename is the identity, its extension is the part that must
    /// survive truncation, and type and size go in the demoted row beneath.
    func testAFileLeadsWithItsFilenameAndProtectsTheExtension() {
        let file = WorkboardMaterialSnapshot(
            kind: .file,
            name: "Q4 board pack final.pdf",
            byteCount: 2_400_000
        )
        let face = WorkboardCardFacePolicy.face(for: file)
        XCTAssertEqual(face.heading, "Q4 board pack final.pdf")
        XCTAssertTrue(face.headingProtectsExtension)
        let size = ByteCountFormatter.string(fromByteCount: 2_400_000, countStyle: .file)
        XCTAssertEqual(face.meta, "PDF • \(size)")
    }

    /// A picture's identifying name is always visible; its size and age are the
    /// least of what it says and wait for the pointer.
    func testAPicturesNameStaysAndItsSizeAndAgeAreDemoted() {
        let picture = WorkboardMaterialSnapshot(
            kind: .image,
            name: "Whiteboard 3",
            byteCount: 5_500_000
        )
        let face = WorkboardCardFacePolicy.face(for: picture)
        XCTAssertEqual(face.heading, "Whiteboard 3")
        XCTAssertTrue(face.metaWaitsForPointer)
        XCTAssertEqual(
            face.meta,
            ByteCountFormatter.string(fromByteCount: 5_500_000, countStyle: .file)
        )
    }

    // MARK: - The third duplication: detail carries availability and size

    /// `WorkboardLiveRepository.materialDetail` joins a caption, an availability
    /// sentence and a size fallback into one field. The card draws availability
    /// and size itself, so the face takes only the caption — otherwise a syncing
    /// picture states "Waiting for iCloud" twice on one tile.
    func testTheAvailabilitySentenceAndTheSizeAreStrippedOutOfTheCaption() throws {
        let availability = String(
            localized: "workboard.material.syncPending",
            defaultValue: "Waiting for iCloud…"
        )
        let size = ByteCountFormatter.string(fromByteCount: 5_500_000, countStyle: .file)
        let picture = WorkboardMaterialSnapshot(
            kind: .image,
            name: "Whiteboard 3",
            detail: "From a conversation • \(availability) • \(size)",
            byteCount: 5_500_000,
            availability: .syncPending
        )
        let face = WorkboardCardFacePolicy.face(for: picture)
        XCTAssertEqual(face.excerpt, "From a conversation")
        XCTAssertEqual(String(localized: try XCTUnwrap(face.availability)), availability)
    }

    /// A detail that was ONLY the availability sentence leaves no caption at
    /// all, rather than an empty line the card reserves space for.
    func testADetailThatIsOnlyAnAvailabilitySentenceLeavesNoCaption() {
        let availability = String(
            localized: "workboard.material.localOnly",
            defaultValue: "Available on this device"
        )
        XCTAssertNil(WorkboardCardFacePolicy.caption(from: availability, byteCount: nil))
    }

    // MARK: - Availability

    /// Waiting bytes get a SENTENCE and not only a glyph: a syncing card
    /// refuses the tap, and a 12-point symbol was the entire explanation a
    /// sighted person got for a click that did nothing.
    func testASyncingCardStatesThatItIsWaitingForICloud() throws {
        let face = WorkboardCardFacePolicy.face(
            for: note(name: "Idea", text: "Something", availability: .syncPending)
        )
        let label = try XCTUnwrap(face.availability)
        XCTAssertEqual(
            String(localized: label),
            String(localized: "workboard.material.syncPending", defaultValue: "Waiting for iCloud…")
        )
        XCTAssertEqual(
            WorkboardCardFacePolicy.availabilityGlyphName(for: .syncPending),
            "icloud.and.arrow.down"
        )
    }

    /// A card whose bytes are right here says nothing about them.
    func testAnAvailableCardCarriesNoAvailabilitySentence() {
        XCTAssertNil(WorkboardCardFacePolicy.availabilityLabel(for: .available))
        XCTAssertNil(WorkboardCardFacePolicy.face(for: note(name: "Idea", text: "Body")).availability)
    }

    /// Local-only bytes are not an error and must not wear one: they are
    /// readable right here, and the sentence exists to explain the card's
    /// absence on the person's OTHER device.
    func testLocalOnlyDoesNotWearTheShapeOfAnError() {
        XCTAssertNotEqual(
            WorkboardCardFacePolicy.availabilityTint(for: .localOnly),
            WorkboardCardFacePolicy.availabilityTint(for: .unavailableOnThisDevice)
        )
        XCTAssertNotEqual(
            WorkboardCardFacePolicy.availabilityGlyphName(for: .localOnly),
            WorkboardCardFacePolicy.availabilityGlyphName(for: .unavailableOnThisDevice)
        )
    }

    // MARK: - One face, three surfaces

    /// The spoken parts ARE the drawn slots. This is the property the whole
    /// policy exists for: a card cannot say something it does not show, and it
    /// cannot say any slot twice.
    func testWhatTheCardSpeaksIsExactlyWhatItShowsAndNeverTwice() {
        let link = WorkboardMaterialSnapshot(
            kind: .link,
            name: "Winter timetable",
            urlString: "https://example.com/travel/winter"
        )
        let face = WorkboardCardFacePolicy.face(for: link)
        XCTAssertEqual(face.spokenParts, ["Winter timetable", "example.com", "/travel/winter"])
        XCTAssertEqual(Set(face.spokenParts).count, face.spokenParts.count)
    }

    /// The suppressed heading reaches the spoken label too — the label is built
    /// from the same face, so a note cannot be read out and then read out again.
    func testTheSpokenCardDoesNotRepeatASuppressedHeading() {
        let summary = WorkboardCardAccessibility.summary(
            material: note(name: "hi", text: "hi"),
            boardPosition: 1,
            boardCount: 2
        )
        let occurrences = summary.components(separatedBy: "hi").count - 1
        XCTAssertEqual(occurrences, 1, summary)
    }

    /// A face is only one face if every surface DRAWS every slot it fills. The
    /// spoken label reads `identity` through `spokenParts` and the tile draws
    /// it, so a row that skipped it would be the single place a titled link
    /// never says which site it is on — the exact disagreement this policy
    /// replaced, reintroduced on one surface.
    func testEverySurfaceThatDrawsAFaceDrawsItsIdentitySlot() throws {
        for path in [
            "Conduck/Views/Workboard/WorkboardCaptureCanvas.swift",
            "Conduck/Views/Workboard/WorkboardMaterialListRow.swift"
        ] {
            let source = try RefusalLaneSource.source(at: path)
            XCTAssertTrue(
                source.contains("face.identity"),
                "\(path) fills the identity slot but never draws it"
            )
        }
    }

    /// Whitespace is absence everywhere, so no surface has to decide separately
    /// whether a blank title counts as one.
    func testABlankSlotIsAbsentRatherThanEmpty() {
        let face = WorkboardCardFacePolicy.face(for: note(name: "   ", text: "  \n "))
        XCTAssertNil(face.heading)
        XCTAssertNil(face.excerpt)
        XCTAssertNil(face.leadLine)
        XCTAssertTrue(face.spokenParts.isEmpty)
    }
}
