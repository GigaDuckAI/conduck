// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardCompanionFoldTests.swift
//
// One press of Capture to Work publishes two materials and the person expects
// ONE card. `WorkboardCompanionFold` is the whole of that expectation: which
// recording belongs inside which picture, which recording keeps its own card,
// and where the pair sits once it is one.
//
// The rule is small and every clause in it was bought with a real failure mode,
// so each is pinned separately here: the two candidate ids (the named one and
// the one collision escape), FIRST ELIGIBLE rather than first existing, an
// `.image` parent that names nothing itself, an `.audio` child, and — when two
// recordings name one picture — the lowest child id rather than the lowest rank,
// so a drag on an unrelated card cannot hand a screenshot a different voice.
//
// The invariant underneath all of them: nothing is discarded. Every material
// handed to the fold comes back, either as a card of its own or as exactly one
// picture's companion.

import Foundation
import XCTest
@testable import Conduck

final class WorkboardCompanionFoldTests: XCTestCase {

    /// The repository case below publishes real payloads, and every isolated
    /// store mints a vault directory nothing else removes.
    private let isolated = IsolatedWorkStores()

    override func tearDown() async throws {
        await isolated.cleanUp()
        try await super.tearDown()
    }

    // MARK: - The fold

    /// The founder's case: a screenshot and the words spoken over it are one
    /// card, and the recording is no longer a card of its own.
    ///
    /// Negative control: a fold that ignored the link (returned its input
    /// unchanged) leaves two cards and no companion — this fails.
    func testAPictureOnTheDeskTakesTheRecordingThatNamesItIntoOneCard() {
        let picture = card(kind: .image, name: "screenshot.jpg")
        let recording = card(kind: .audio, name: "Ship the review", attachedTo: picture.id)
        let unrelated = card(kind: .note, name: "typed")

        let folded = WorkboardCompanionFold.fold([picture, recording, unrelated])

        XCTAssertEqual(
            folded.displayed.map(\.id), [picture.id, unrelated.id],
            "the recording stopped being a card"
        )
        XCTAssertEqual(folded.hiddenChildIDs, [recording.id])
        XCTAssertEqual(folded.childByParent, [picture.id: recording.id])
        XCTAssertEqual(folded.displayed.first?.companion?.id, recording.id)
        XCTAssertNil(folded.displayed.last?.companion, "an unrelated card takes no companion")
        assertNothingDiscarded(from: [picture, recording, unrelated], folded)
    }

    /// The link is a promise about identity, not existence. A recording whose
    /// picture failed to publish — or has not synced yet — is a plain recording
    /// card, and the desk shows it rather than swallowing it.
    ///
    /// Negative control: resolving the link without checking that the picture is
    /// on the desk crashes or hides the recording — this fails.
    func testARecordingWhosePictureIsNotOnTheDeskKeepsItsOwnCard() {
        let recording = card(kind: .audio, name: "Ship the review", attachedTo: UUID())
        let other = card(kind: .image, name: "unrelated.jpg")

        let folded = WorkboardCompanionFold.fold([recording, other])

        XCTAssertEqual(folded.displayed.map(\.id), [recording.id, other.id])
        XCTAssertTrue(folded.hiddenChildIDs.isEmpty)
        XCTAssertTrue(folded.childByParent.isEmpty)
        XCTAssertTrue(folded.displayed.allSatisfy { $0.companion == nil })
    }

    /// A card of another kind standing at the named id is exactly WHY the
    /// picture escaped, so the search must step over it and look at the escape.
    ///
    /// Negative control: "first EXISTING candidate" stops at the note and leaves
    /// the escaped pair permanently two cards — this fails.
    func testAPictureUnderItsCollisionEscapeStillTakesItsRecording() {
        let namedID = UUID()
        let escapeID = WorkMaterialCollisionEscape.materialID(forCapture: namedID)
        let collision = card(namedID, kind: .note, name: "already here")
        let picture = card(escapeID, kind: .image, name: "screenshot.jpg")
        let recording = card(kind: .audio, name: "Ship the review", attachedTo: namedID)

        let folded = WorkboardCompanionFold.fold([collision, picture, recording])

        XCTAssertEqual(folded.childByParent, [escapeID: recording.id])
        XCTAssertEqual(folded.displayed.map(\.id), [namedID, escapeID])
        XCTAssertEqual(
            folded.displayed.first(where: { $0.id == escapeID })?.companion?.id, recording.id,
            "the picture that actually landed is the one that draws the words"
        )
        XCTAssertNil(
            folded.displayed.first(where: { $0.id == namedID })?.companion,
            "the card that caused the collision is not a parent"
        )
    }

    /// The other half of the same rule: stepping over the wrong-kind row must
    /// not invent a parent. With nothing behind the escape the recording stands.
    ///
    /// Negative control: falling back to the named row regardless of kind folds
    /// a recording into a note — this fails.
    func testAWrongKindRowAtTheNamedIdWithNothingBehindItLeavesTheRecordingStanding() {
        let namedID = UUID()
        let collision = card(namedID, kind: .note, name: "already here")
        let recording = card(kind: .audio, name: "Ship the review", attachedTo: namedID)

        let folded = WorkboardCompanionFold.fold([collision, recording])

        XCTAssertEqual(folded.displayed.map(\.id), [collision.id, recording.id])
        XCTAssertTrue(folded.hiddenChildIDs.isEmpty)
        XCTAssertTrue(folded.displayed.allSatisfy { $0.companion == nil })
    }

    /// Two recordings naming one picture: the lowest child id folds, the other
    /// keeps its card. The choice must be arrangement-independent — Codex's
    /// counterexample is a drag on an unrelated card silently swapping which
    /// recording the screenshot draws.
    ///
    /// Negative control: picking by rank (or by "first seen") answers `low` in
    /// one arrangement and `high` in the other — the second assertion fails.
    func testOnlyTheLowestRecordingIdFoldsAndTheArrangementCannotChangeThat() {
        let picture = card(kind: .image, name: "screenshot.jpg")
        let low = card(
            UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!,
            kind: .audio, name: "first words", attachedTo: picture.id
        )
        let high = card(
            UUID(uuidString: "00000000-0000-4000-8000-0000000000B1")!,
            kind: .audio, name: "later words", attachedTo: picture.id
        )

        let asPublished = WorkboardCompanionFold.fold([picture, low, high])
        XCTAssertEqual(asPublished.childByParent, [picture.id: low.id])
        XCTAssertEqual(asPublished.displayed.map(\.id), [picture.id, high.id])
        XCTAssertEqual(asPublished.displayed.first?.companion?.id, low.id)
        assertNothingDiscarded(from: [picture, low, high], asPublished)

        // The same desk, dragged. Nothing about which recording belongs to the
        // picture may move with it.
        let rearranged = WorkboardCompanionFold.fold([high, low, picture])
        XCTAssertEqual(
            rearranged.childByParent, [picture.id: low.id],
            "an unrelated reorder must not change the screenshot's companion"
        )
        XCTAssertEqual(rearranged.displayed.map(\.id), [high.id, picture.id])
    }

    /// A card is never its own companion.
    ///
    /// Negative control: dropping the `candidate != child` guard folds the card
    /// into itself, and the picture-kind check is all that hides it — this fails
    /// the moment the row is an image.
    func testACardThatNamesItselfIsNotItsOwnCompanion() {
        let selfNamingRecording = withID { id in
            card(id, kind: .audio, name: "Ship the review", attachedTo: id)
        }
        let selfNamingPicture = withID { id in
            card(id, kind: .image, name: "screenshot.jpg", attachedTo: id)
        }

        let folded = WorkboardCompanionFold.fold([selfNamingRecording, selfNamingPicture])

        XCTAssertEqual(
            folded.displayed.map(\.id), [selfNamingRecording.id, selfNamingPicture.id]
        )
        XCTAssertTrue(folded.hiddenChildIDs.isEmpty)
        XCTAssertTrue(folded.displayed.allSatisfy { $0.companion == nil })
    }

    /// The sharp edge of the same rule: a self-naming recording must not fold
    /// through the escape of its OWN id.
    ///
    /// `escape(C)` is not `C`, so a resolution that only skipped the
    /// self-referential candidate would walk straight on to the second one and
    /// hand the recording whatever picture happens to sit at that derived id —
    /// a picture no press of Capture to Work ever paired with it, since a
    /// capture's screenshot lands at `materialID(forCapture:)` and never at the
    /// escape of the recording's own id. Folding it there would also authorise
    /// the group delete to destroy both.
    ///
    /// Negative control: the second half links an ordinary recording to that
    /// same picture and it folds, so the standalone verdict above is about the
    /// self-link and not about the picture being ineligible.
    func testASelfNamingRecordingDoesNotFoldThroughTheEscapeOfItsOwnID() {
        let selfNamingID = UUID()
        let escapeOfItself = WorkMaterialCollisionEscape.materialID(forCapture: selfNamingID)
        let selfNaming = card(
            selfNamingID, kind: .audio, name: "Ship the review", attachedTo: selfNamingID
        )
        let unrelatedPicture = card(escapeOfItself, kind: .image, name: "screenshot.jpg")

        let folded = WorkboardCompanionFold.fold([selfNaming, unrelatedPicture])

        XCTAssertEqual(
            folded.displayed.map(\.id), [selfNamingID, escapeOfItself],
            "a recording that names itself keeps its own card"
        )
        XCTAssertTrue(folded.hiddenChildIDs.isEmpty)
        XCTAssertTrue(
            folded.displayed.allSatisfy { $0.companion == nil },
            "the escape of the child's own id is not the child's picture"
        )
        assertNothingDiscarded(from: [selfNaming, unrelatedPicture], folded)

        // NEGATIVE CONTROL: that picture is a perfectly good parent for a
        // recording that names IT.
        let honest = card(kind: .audio, name: "later words", attachedTo: escapeOfItself)
        let withHonest = WorkboardCompanionFold.fold([selfNaming, unrelatedPicture, honest])

        XCTAssertEqual(withHonest.childByParent, [escapeOfItself: honest.id])
        XCTAssertEqual(withHonest.displayed.map(\.id), [selfNamingID, escapeOfItself])
        XCTAssertNil(
            withHonest.displayed.first?.companion,
            "the self-naming recording is still standing on its own"
        )
    }

    /// A chain is not a fold: a picture that itself names a picture cannot be a
    /// parent, so the recording that named it keeps its card rather than being
    /// drawn two hops from where it belongs.
    ///
    /// Negative control: dropping the parent's own no-link condition folds the
    /// recording into the chained image — the standalone assertion fails.
    func testAPictureThatItselfNamesAPictureIsNotAParent() {
        let root = card(kind: .image, name: "root.jpg")
        let chained = card(kind: .image, name: "chained.jpg", attachedTo: root.id)
        let recording = card(kind: .audio, name: "Ship the review", attachedTo: chained.id)

        let folded = WorkboardCompanionFold.fold([root, chained, recording])

        XCTAssertEqual(folded.displayed.map(\.id), [root.id, chained.id, recording.id])
        XCTAssertTrue(folded.childByParent.isEmpty)
        XCTAssertTrue(folded.displayed.allSatisfy { $0.companion == nil })
    }

    /// Only a recording folds. Text mode stays two cards this iteration — a
    /// folded note would lose the full-text route its own card has — and a file
    /// or a link naming a picture is not a thing any lane writes.
    ///
    /// The recording is in the desk on purpose: without it the fold takes its
    /// no-linked-recording exit, and a broken child-kind rule would be hidden
    /// behind that exit rather than tested. The ids are fixed so the note sorts
    /// BELOW the recording — under a broken rule the note wins the fold, which
    /// is a deterministic failure rather than a one-in-four one.
    ///
    /// Negative control: dropping the child-kind check draws the note inside the
    /// picture and leaves the words standing alone — both assertions fail.
    func testOnlyARecordingFoldsAndATypedNoteKeepsItsOwnCard() {
        let picture = card(kind: .image, name: "screenshot.jpg")
        let note = card(
            UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            kind: .note, name: "Share note", attachedTo: picture.id
        )
        let file = card(
            UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
            kind: .file, name: "notes.pdf", attachedTo: picture.id
        )
        let link = card(
            UUID(uuidString: "00000000-0000-4000-8000-000000000003")!,
            kind: .link, name: "example.com", attachedTo: picture.id
        )
        let recording = card(
            UUID(uuidString: "00000000-0000-4000-8000-0000000000F0")!,
            kind: .audio, name: "Ship the review", attachedTo: picture.id
        )

        let folded = WorkboardCompanionFold.fold([picture, note, file, link, recording])

        XCTAssertEqual(folded.childByParent, [picture.id: recording.id])
        XCTAssertEqual(
            folded.displayed.map(\.id), [picture.id, note.id, file.id, link.id],
            "every kind but the recording keeps its own card"
        )
        XCTAssertEqual(folded.displayed.first?.companion?.id, recording.id)
        assertNothingDiscarded(from: [picture, note, file, link, recording], folded)
    }

    /// The pair sits where the PICTURE sat, including when the recording was
    /// published first — which is the ordinary order on the Shortcuts lane.
    ///
    /// Negative control: keeping the pair at the child's rank puts the card
    /// first and moves every other card down — the order assertion fails.
    func testTheFoldedPairSitsAtThePicturesRankEvenWhenTheRecordingCameFirst() {
        let first = card(kind: .note, name: "typed")
        let recording = card(kind: .audio, name: "Ship the review")
        let picture = card(kind: .image, name: "screenshot.jpg")
        let last = card(kind: .file, name: "notes.pdf")
        let linked = withCompanionLink(recording, to: picture.id)

        let folded = WorkboardCompanionFold.fold([first, linked, picture, last])

        XCTAssertEqual(
            folded.displayed.map(\.id), [first.id, picture.id, last.id],
            "the pair takes the picture's position, not the recording's"
        )
        XCTAssertEqual(folded.displayed[1].companion?.id, recording.id)
    }

    /// The companion carries the recording's WHOLE card, because Open, Share and
    /// Reattach are handed one material and revalidate it against the store: a
    /// companion missing its revision, mime type or availability would be shared
    /// under a revision that no longer exists, or offered for a payload this
    /// device cannot read.
    ///
    /// Negative control: a companion that carried only id and title fails to
    /// round-trip — every field assertion below fails.
    func testTheCompanionCarriesTheRecordingsWholeCard() throws {
        let picture = card(kind: .image, name: "screenshot.jpg")
        var recording = card(kind: .audio, name: "Ship the review", attachedTo: picture.id)
        recording.detail = "Available on this device"
        recording.textContent = "Ship the carrier review by Friday"
        recording.mimeType = "audio/m4a"
        recording.byteCount = 9_001
        recording.availability = .localOnly
        recording.sequence = 7
        recording.cardSize = .large
        recording.createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        recording.revision = 4_242

        let folded = WorkboardCompanionFold.fold([picture, recording])
        let companion = try XCTUnwrap(folded.displayed.first?.companion)

        XCTAssertEqual(companion.id, recording.id)
        XCTAssertEqual(companion.kind, .audio)
        XCTAssertEqual(companion.name, "Ship the review")
        XCTAssertEqual(companion.detail, "Available on this device")
        XCTAssertEqual(companion.textContent, "Ship the carrier review by Friday")
        XCTAssertEqual(companion.mimeType, "audio/m4a")
        XCTAssertEqual(companion.byteCount, 9_001)
        XCTAssertEqual(companion.availability, .localOnly)
        XCTAssertEqual(companion.sequence, 7)
        XCTAssertEqual(companion.cardSize, .large)
        XCTAssertEqual(companion.createdAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(companion.revision, 4_242)
        XCTAssertEqual(companion.attachedToMaterialID, picture.id)
        XCTAssertEqual(
            companion.material, recording,
            "the companion gives the recording back exactly as the board would have drawn it"
        )
        XCTAssertNil(
            companion.material.companion,
            "a companion never has a companion of its own"
        )
    }

    /// The desk without a single link must not pay for the rule, and must come
    /// back byte-identical.
    ///
    /// Negative control: a fold that rebuilt every card would still pass the id
    /// assertion, so this compares the values themselves.
    func testADeskWithNoLinkedRecordingIsReturnedUnchanged() {
        let cards = [
            card(kind: .image, name: "screenshot.jpg"),
            card(kind: .audio, name: "Ship the review"),
            card(kind: .note, name: "typed"),
        ]

        let folded = WorkboardCompanionFold.fold(cards)

        XCTAssertEqual(folded.displayed, cards)
        XCTAssertTrue(folded.hiddenChildIDs.isEmpty)
        XCTAssertTrue(folded.childByParent.isEmpty)
    }

    // MARK: - Through the live board build

    /// The same rule where it actually runs: a desk loaded through the live
    /// repository draws one card fewer than it stores, and the picture carries
    /// the recording the store linked to it.
    ///
    /// Negative control: with the fold removed from `snapshot(for:)` the load
    /// answers three cards and no companion — both assertions fail.
    @MainActor
    func testADeskLoadDrawsALinkedPairAsOneCard() async throws {
        let store = isolated.make()
        let inboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workboard-companion-fold-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: inboxURL) }

        let typed = try await store.upsertDeskMaterial(
            WorkMaterialDraft(kind: .note, title: "typed", textContent: "typed")
        )
        let picture = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                kind: .image, title: "screenshot.jpg", filename: "screenshot.jpg",
                mimeType: "image/jpeg", payload: Data("picture".utf8)
            )
        )
        let recording = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                kind: .audio, title: "Ship the review", filename: "words.m4a",
                mimeType: "audio/m4a", payload: Data("words".utf8),
                attachedToMaterialID: picture.id
            )
        )
        let storedValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let stored = try XCTUnwrap(storedValue)
        XCTAssertEqual(stored.materials.count, 3, "the premise: three materials are stored")

        let repository = WorkboardLiveRepository(
            store: store,
            captureInbox: WorkCaptureInbox(baseURL: inboxURL),
            openMaterial: { _ in }
        )
        let deskValue = try await repository.makeDependencies().loadDesk()
        let desk = try XCTUnwrap(deskValue)

        XCTAssertEqual(desk.materials.count, 2, "the pair is one card")
        XCTAssertEqual(desk.materials.map(\.id), [typed.id, picture.id])
        let companion = try XCTUnwrap(desk.materials.last?.companion)
        XCTAssertEqual(companion.id, recording.id)
        XCTAssertEqual(companion.kind, .audio)
        XCTAssertEqual(companion.name, "Ship the review")
        XCTAssertEqual(companion.mimeType, "audio/m4a")
        XCTAssertEqual(
            desk.materials.last?.attachedToMaterialID, nil,
            "a picture names nothing; the link belongs to the recording"
        )
        XCTAssertEqual(
            companion.attachedToMaterialID, picture.id,
            "the raw link is projected onto the card, unresolved"
        )
    }

    // MARK: - Fixtures

    private func card(
        _ id: UUID = UUID(),
        kind: WorkboardMaterialKind,
        name: String,
        attachedTo: UUID? = nil,
        sequence: Int = 0
    ) -> WorkboardMaterialSnapshot {
        WorkboardMaterialSnapshot(
            id: id,
            kind: kind,
            name: name,
            sequence: sequence,
            attachedToMaterialID: attachedTo
        )
    }

    /// A card whose link names its own id — buildable only by minting the id
    /// first.
    private func withID(
        _ make: (UUID) -> WorkboardMaterialSnapshot
    ) -> WorkboardMaterialSnapshot {
        make(UUID())
    }

    private func withCompanionLink(
        _ material: WorkboardMaterialSnapshot,
        to parentID: UUID
    ) -> WorkboardMaterialSnapshot {
        var linked = material
        linked.attachedToMaterialID = parentID
        return linked
    }

    /// Every material handed to the fold comes back: as a card, or as exactly
    /// one picture's companion. A rule that "resolved" a conflict by dropping a
    /// recording would lose a payload no other surface can reach.
    private func assertNothingDiscarded(
        from input: [WorkboardMaterialSnapshot],
        _ folded: WorkboardCompanionFold.Folded,
        line: UInt = #line
    ) {
        let companions = folded.displayed.compactMap(\.companion).map(\.id)
        XCTAssertEqual(
            Set(folded.displayed.map(\.id)).union(companions), Set(input.map(\.id)),
            "the fold dropped a material", line: line
        )
        XCTAssertEqual(
            Set(companions), folded.hiddenChildIDs,
            "a hidden recording that is nobody's companion is a lost card", line: line
        )
        XCTAssertEqual(companions.count, Set(companions).count, "one recording, one card", line: line)
    }
}
