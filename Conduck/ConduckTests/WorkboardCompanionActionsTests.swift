// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardCompanionActionsTests.swift
//
// A folded card is ONE card made of TWO materials, and every route off it has to
// know which half it is talking about.
//
// The failures these hold are all the same shape — a route that reaches only the
// board's top-level cards silently loses the recording the moment it folds:
//
// - Delete: one card, one Delete, but two materials must go under ONE
//   compare-and-swap. Two single deletes would leave the recording standing,
//   because the first advances the revision the second is holding.
// - Open / Share / Reattach: each acts on ONE member and validates only that
//   member. Handing them the picture while the menu row says "Recording" is the
//   defect worth a test of its own.
// - Reattach and a stale tap additionally RESOLVE an id against the board, and a
//   companion is not one of `materials`.
//
// The order plumbing lives in `WorkboardOrderingTests`; the fold rule itself in
// `WorkboardCompanionFoldTests`. This file is about what the board DOES with a
// fold once it has one.

import XCTest
@testable import Conduck

@MainActor
final class WorkboardCompanionActionsTests: XCTestCase {
    private enum TestError: Error, Equatable { case refused, unexpectedCall }

    private final class BoardHarness {
        var desk: WorkboardItemSnapshot
        var groupRemovals: [(revision: Int64, parentID: UUID, childID: UUID)] = []
        var singleRemovals: [(revision: Int64, materialID: UUID)] = []
        var replacements: [(revision: Int64, materialID: UUID)] = []
        var groupRemovalFails = false

        init(desk: WorkboardItemSnapshot) {
            self.desk = desk
        }
    }

    // MARK: - Delete

    /// The founder's card: one Delete, both materials, one revision.
    ///
    /// Negative control: routing a folded card through `removeMaterialFromBoard`
    /// records a single removal and no group removal — both assertions fail.
    func testAFoldedCardsDeleteRemovesBothMembersUnderOneRevision() async {
        let recording = card(kind: .audio, name: "Ship the review")
        let picture = folded(card(kind: .image, name: "screenshot.jpg"), around: recording)
        let harness = BoardHarness(desk: desk([picture], revision: 7))
        let viewModel = await makeViewModelShowingDesk(harness)

        let removed = await viewModel.removeGroupFromBoard(
            parentID: picture.id,
            childID: recording.id
        )

        XCTAssertTrue(removed)
        XCTAssertEqual(harness.groupRemovals.count, 1)
        XCTAssertEqual(harness.groupRemovals.first?.parentID, picture.id)
        XCTAssertEqual(harness.groupRemovals.first?.childID, recording.id)
        XCTAssertEqual(
            harness.groupRemovals.first?.revision, 7,
            "the group delete carries the desk revision the person was looking at"
        )
        XCTAssertTrue(
            harness.singleRemovals.isEmpty,
            "a folded card must never be taken apart by two single deletes"
        )
        XCTAssertEqual(viewModel.desk?.materials.isEmpty, true)
    }

    /// The board passes the companion it DREW. A delete that re-resolved the
    /// fold at confirmation time could remove a recording the person never saw
    /// on that card — so the id travels through unchanged, and the store, which
    /// owns pair validation, is what refuses a fold a sync has since undone.
    ///
    /// Negative control: an implementation reading `companion.id` off the
    /// current desk instead of its argument passes `current.id` here and fails.
    func testTheDeleteCarriesTheCompanionTheBoardDrewRatherThanTheCurrentOne() async {
        let current = card(kind: .audio, name: "Newer recording")
        let displayed = card(kind: .audio, name: "The one on screen")
        let picture = folded(card(kind: .image, name: "screenshot.jpg"), around: current)
        let harness = BoardHarness(desk: desk([picture], revision: 3))
        harness.groupRemovalFails = true
        let viewModel = await makeViewModelShowingDesk(harness)

        let removed = await viewModel.removeGroupFromBoard(
            parentID: picture.id,
            childID: displayed.id
        )

        XCTAssertFalse(removed)
        XCTAssertEqual(harness.groupRemovals.first?.childID, displayed.id)
        XCTAssertNotEqual(harness.groupRemovals.first?.childID, current.id)
        XCTAssertNotNil(viewModel.notice, "a refused pair is explained, not swallowed")
        XCTAssertEqual(
            viewModel.desk?.materials.map(\.id), [picture.id],
            "a refused delete leaves the card standing"
        )
    }

    /// A card with nothing folded into it keeps the single-material delete, so
    /// the group mutation stays the exception it was added as.
    func testAStandaloneCardStillDeletesAsOneMaterial() async {
        let note = card(kind: .note, name: "typed")
        let harness = BoardHarness(desk: desk([note], revision: 4))
        let viewModel = await makeViewModelShowingDesk(harness)

        let removed = await viewModel.removeMaterialFromBoard(note.id)

        XCTAssertTrue(removed)
        XCTAssertEqual(harness.singleRemovals.map(\.materialID), [note.id])
        XCTAssertTrue(harness.groupRemovals.isEmpty)
    }

    /// A picture the board no longer carries reaches no store mutation at all —
    /// the same refusal `removeMaterialFromBoard` makes for a vanished card.
    func testAGroupDeleteForAPictureTheBoardNoLongerHoldsReachesNoStore() async {
        let recording = card(kind: .audio, name: "Ship the review")
        let picture = folded(card(kind: .image, name: "screenshot.jpg"), around: recording)
        let harness = BoardHarness(desk: desk([card(kind: .note, name: "typed")], revision: 2))
        let viewModel = await makeViewModelShowingDesk(harness)

        let removed = await viewModel.removeGroupFromBoard(
            parentID: picture.id,
            childID: recording.id
        )

        XCTAssertFalse(removed)
        XCTAssertTrue(harness.groupRemovals.isEmpty)
        XCTAssertNil(viewModel.notice)
    }

    // MARK: - Reattach

    /// Repairing the recording's bytes is the one route a folded recording would
    /// lose outright: it is not one of the board's cards, so a top-level-only
    /// membership check refuses it before the picker's file is ever read.
    ///
    /// Negative control: with the check restricted to `current.materials` the
    /// replacement never runs and a capture failure is shown instead.
    func testReattachReachesARecordingDrawnInsideItsPicture() async throws {
        let recording = card(kind: .audio, name: "Ship the review")
        let picture = folded(card(kind: .image, name: "screenshot.jpg"), around: recording)
        let harness = BoardHarness(desk: desk([picture], revision: 9))
        let viewModel = await makeViewModelShowingDesk(harness)
        let companion = try XCTUnwrap(viewModel.desk?.materials.first?.companion)

        await viewModel.reattachMaterial(
            companion.material,
            with: WorkboardMaterialImport(
                kind: .audio,
                name: "words.m4a",
                mimeType: "audio/m4a"
            )
        )

        XCTAssertEqual(harness.replacements.map(\.materialID), [recording.id])
        XCTAssertEqual(
            harness.replacements.first?.revision, 9,
            "the repair CASes on the desk revision, exactly as a card's own repair does"
        )
        XCTAssertNil(viewModel.notice, "a successful repair explains nothing")
        XCTAssertNotNil(viewModel.workspaceStatus)
    }

    /// The membership check widened, it did not disappear: an id the board
    /// carries neither as a card nor as a companion still writes nothing.
    func testReattachStillRefusesAnIdTheBoardCarriesNeither() async {
        let recording = card(kind: .audio, name: "Ship the review")
        let picture = folded(card(kind: .image, name: "screenshot.jpg"), around: recording)
        let harness = BoardHarness(desk: desk([picture], revision: 9))
        let viewModel = await makeViewModelShowingDesk(harness)

        await viewModel.reattachMaterial(
            card(kind: .audio, name: "Somebody else’s recording"),
            with: WorkboardMaterialImport(kind: .audio, name: "words.m4a")
        )

        XCTAssertTrue(harness.replacements.isEmpty)
        XCTAssertEqual(viewModel.notice?.kind, .error)
    }

    // MARK: - Open (the stale-tap resolver)

    /// `currentDeskCard` answers for the card that EXISTS, and a folded
    /// recording exists as a companion. Without this, Open Recording always took
    /// the stale-snapshot fallback — the one path that cannot answer for a card
    /// the desk has since refused.
    ///
    /// Negative control: with the top-level-only lookup restored, the resolved
    /// card is the tapped value and its availability is the stale `.available`.
    func testTheStaleTapResolverFindsACompanionAndKeepsItsAbsentCardFallback() {
        let recording = card(kind: .audio, name: "Ship the review")
        var arrived = recording
        arrived.availability = .syncPending
        let picture = folded(card(kind: .image, name: "screenshot.jpg"), around: arrived)

        let resolved = PersonalWorkbenchRouter.currentDeskCard(in: [picture], for: recording)
        XCTAssertEqual(resolved.id, recording.id)
        XCTAssertEqual(
            resolved.availability, .syncPending,
            "the desk wins over the snapshot the gesture carried"
        )
        XCTAssertNil(resolved.companion, "a companion resolves as a card of its own")

        let absent = card(kind: .file, name: "gone.pdf")
        XCTAssertEqual(
            PersonalWorkbenchRouter.currentDeskCard(in: [picture], for: absent).id,
            absent.id,
            "a board reloaded underneath the gesture must not become a dead tap"
        )
    }

    // MARK: - Per-component routing

    /// Every route on a folded card is handed the RECORDING, never the picture.
    /// The failure this prevents is a menu row that says "Recording" and shares
    /// the screenshot.
    ///
    /// Negative control: binding the closures to `material` instead of
    /// `companion.material` makes all three assertions read the picture's id.
    func testTheCompanionRoutesActOnTheRecordingAndNeverOnThePicture() throws {
        let recording = card(kind: .audio, name: "Ship the review")
        let picture = folded(card(kind: .image, name: "screenshot.jpg"), around: recording)
        var opened: [UUID] = []
        var shared: [UUID] = []
        var reattached: [UUID] = []

        let routes = try XCTUnwrap(WorkboardCompanionRouting.actions(
            for: picture,
            onOpen: { opened.append($0.id) },
            onShare: { shared.append($0.id) },
            onReattach: { reattached.append($0.id) }
        ))
        routes.open()
        routes.share()
        routes.reattach()

        XCTAssertEqual(opened, [recording.id])
        XCTAssertEqual(shared, [recording.id])
        XCTAssertEqual(reattached, [recording.id])
    }

    /// A card with nothing folded into it offers no companion routes, so a card
    /// view cannot draw a band for a recording that is not there.
    func testACardWithoutACompanionOffersNoCompanionRoutes() {
        XCTAssertNil(
            WorkboardCompanionRouting.actions(
                for: card(kind: .image, name: "screenshot.jpg"),
                onOpen: { _ in XCTFail("no companion, no route") },
                onShare: { _ in XCTFail("no companion, no route") },
                onReattach: { _ in XCTFail("no companion, no route") }
            )
        )
    }

    // MARK: - Member lookup and order expansion

    func testDeskMemberLookupFindsCardsAndCompanionsAndNothingElse() {
        let recording = card(kind: .audio, name: "Ship the review")
        let picture = folded(card(kind: .image, name: "screenshot.jpg"), around: recording)
        let note = card(kind: .note, name: "typed")
        let cards = [note, picture]

        XCTAssertEqual(WorkboardDeskMember.find(note.id, among: cards)?.id, note.id)
        XCTAssertEqual(WorkboardDeskMember.find(picture.id, among: cards)?.id, picture.id)
        XCTAssertEqual(WorkboardDeskMember.find(recording.id, among: cards)?.id, recording.id)
        XCTAssertEqual(
            WorkboardDeskMember.find(recording.id, among: cards)?.kind, .audio,
            "the companion comes back as itself, not as the card it was drawn in"
        )
        XCTAssertNil(WorkboardDeskMember.find(UUID(), among: cards))
    }

    /// The store rewrites dense ranks from a permutation holding every logical id
    /// exactly once, so the displayed order has to grow back into the stored one
    /// before it is sent — with the pair adjacent, or the rewrite would leave
    /// another card between a picture and its recording.
    ///
    /// Negative control: returning the displayed ids unchanged drops the
    /// recording and the first assertion fails.
    func testExpandedOrderNamesEveryStoredMaterialExactlyOnceWithThePairAdjacent() {
        let recording = card(kind: .audio, name: "Ship the review")
        let picture = folded(card(kind: .image, name: "screenshot.jpg"), around: recording)
        let first = card(kind: .note, name: "first")
        let last = card(kind: .link, name: "last")
        let cards = [first, picture, last]

        let expanded = WorkboardDeskMember.expandedOrder(
            [last.id, picture.id, first.id],
            among: cards
        )

        XCTAssertEqual(expanded, [last.id, picture.id, recording.id, first.id])
        XCTAssertEqual(Set(expanded).count, expanded.count, "every id exactly once")
        XCTAssertEqual(
            WorkboardDeskMember.expandedOrder([last.id, first.id], among: [first, last]),
            [last.id, first.id],
            "a board with nothing folded is left alone"
        )
    }

    // MARK: - Both layouts

    /// SOURCE GUARD. The board draws three card families — the mosaic's source
    /// card, its audio card and the list row — and each must receive the WHOLE
    /// card snapshot, companion included. The two families that can DRAW a
    /// companion must additionally receive the routes for it, bound from one
    /// place: a layout that got the companion without its routes would show a
    /// recording it cannot open or share.
    ///
    /// This is an ABSENCE over a view no unit test can instantiate. Asserting it
    /// in text is what keeps the tiles layout and the list layout from drifting
    /// apart as either one is edited.
    ///
    /// The audio card is deliberately NOT given companion routes: the fold
    /// refuses chains, so a recording never carries one.
    func testBothLayoutsReceiveTheCardAndItsCompanionRoutes() throws {
        let path = "Conduck/Views/Workboard/WorkboardCaptureCanvas.swift"
        let source = try RefusalLaneSource.source(at: path)
        let dispatch = try RefusalLaneSource.body(ofFunction: "card", in: source, path: path)

        XCTAssertTrue(
            dispatch.contains("WorkboardCompanionRouting.actions("),
            """
            The companion routes are bound ONCE per card, so the two families \
            that can draw one cannot disagree about which material they act on.
            """
        )
        for family in [
            "WorkboardMaterialListRow(",
            "WorkboardAudioCardView(",
            "WorkboardSourceCard("
        ] {
            let call = try argumentList(after: family, in: dispatch)
            XCTAssertTrue(
                call.contains("material: material"),
                "\(family) must be handed the whole card, or its companion is dropped"
            )
        }
        for family in ["WorkboardMaterialListRow(", "WorkboardSourceCard("] {
            let call = try argumentList(after: family, in: dispatch)
            XCTAssertTrue(
                call.contains("onOpenCompanion: companionRoutes?.open"),
                "\(family) draws a companion, so it must be able to open it"
            )
            XCTAssertTrue(
                call.contains("onShareCompanion: companionRoutes?.share"),
                "\(family) draws a companion, so it must be able to share it"
            )
            XCTAssertTrue(
                call.contains("onReattachCompanion: companionRoutes?.reattach"),
                """
                \(family) must repair the RECORDING through its own route — the \
                card's Reattach replaces the picture.
                """
            )
        }
    }

    /// SOURCE GUARD. The board's own `remove(_:)` is the only caller that can
    /// tell a folded card from a standalone one, and it is a `Task` inside a
    /// confirmation dialog — no unit test can reach it. What it must never do is
    /// route a folded card through the single-material delete, which would leave
    /// the recording standing as a card nobody asked to keep.
    ///
    /// Negative control: with the branch replaced by the single delete, the
    /// first two assertions fail.
    func testAFoldedCardsDeleteRoutesToTheGroupMutation() throws {
        let path = "Conduck/Views/Workboard/WorkboardCaptureCanvas.swift"
        let source = try RefusalLaneSource.source(at: path)
        let removal = try RefusalLaneSource.body(ofFunction: "remove", in: source, path: path)

        XCTAssertTrue(
            removal.contains("material.companion"),
            "the delete branches on whether the card draws a companion"
        )
        XCTAssertTrue(
            removal.contains("viewModel.removeGroupFromBoard("),
            "a folded card's Delete removes both materials under one revision"
        )
        XCTAssertTrue(
            removal.contains("viewModel.removeMaterialFromBoard("),
            "a standalone card still deletes as one material"
        )
    }

    // MARK: - Fixtures

    private func card(
        kind: WorkboardMaterialKind,
        name: String
    ) -> WorkboardMaterialSnapshot {
        WorkboardMaterialSnapshot(kind: kind, name: name)
    }

    /// A picture as the fold would have handed it to the board: the recording
    /// drawn inside it, and the recording absent from the desk's own cards.
    private func folded(
        _ picture: WorkboardMaterialSnapshot,
        around recording: WorkboardMaterialSnapshot
    ) -> WorkboardMaterialSnapshot {
        var linked = recording
        linked.attachedToMaterialID = picture.id
        var parent = picture
        parent.companion = WorkboardCompanionSnapshot(linked)
        return parent
    }

    private func desk(
        _ materials: [WorkboardMaterialSnapshot],
        revision: Int64
    ) -> WorkboardItemSnapshot {
        WorkboardItemSnapshot(
            id: Constants.workboardDeskItemID,
            materials: materials,
            revision: revision
        )
    }

    /// The parenthesised argument list of one call, so an assertion about
    /// `WorkboardSourceCard(` cannot be satisfied by a neighbouring call's
    /// arguments.
    private func argumentList(after token: String, in source: String) throws -> String {
        let anchor = try XCTUnwrap(
            source.range(of: token),
            "no `\(token)` in the card dispatch — update this guard"
        )
        var index = anchor.upperBound
        let start = index
        var depth = 1
        while index < source.endIndex, depth > 0 {
            if source[index] == "(" { depth += 1 }
            if source[index] == ")" { depth -= 1 }
            index = source.index(after: index)
        }
        return String(source[start..<index])
    }

    /// The desk the person is looking at, seeded through the real load path.
    private func makeViewModelShowingDesk(_ harness: BoardHarness) async -> WorkboardViewModel {
        let viewModel = WorkboardViewModel(dependencies: WorkboardViewModel.Dependencies(
            loadDesk: { [harness] in harness.desk },
            importMaterial: { _, _, _ in throw TestError.unexpectedCall },
            removeMaterial: { [harness] revision, materialID in
                harness.singleRemovals.append((revision: revision, materialID: materialID))
                harness.desk = WorkboardItemSnapshot(
                    id: harness.desk.id,
                    materials: harness.desk.materials.filter { $0.id != materialID },
                    revision: harness.desk.revision + 1
                )
                return harness.desk
            },
            removeMaterialGroup: { [harness] revision, parentID, childID in
                harness.groupRemovals.append(
                    (revision: revision, parentID: parentID, childID: childID)
                )
                if harness.groupRemovalFails { throw TestError.refused }
                harness.desk = WorkboardItemSnapshot(
                    id: harness.desk.id,
                    materials: harness.desk.materials.filter { $0.id != parentID },
                    revision: harness.desk.revision + 1
                )
                return harness.desk
            },
            replaceMaterial: { [harness] revision, materialID, _, onProgress in
                harness.replacements.append((revision: revision, materialID: materialID))
                onProgress(1)
                harness.desk = WorkboardItemSnapshot(
                    id: harness.desk.id,
                    materials: harness.desk.materials,
                    revision: harness.desk.revision + 1
                )
                return harness.desk
            },
            openMaterial: { _ in }
        ))
        await viewModel.load()
        return viewModel
    }
}
