// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardBoardProjectionTests.swift
//
// The board's derived surface: what a returned snapshot is allowed to overwrite,
// what the search field actually filters on and when, and the two equivalences
// the views now assume instead of recomputing — the emptiness probe and the
// move affordance read off a card's index in its own shelf.

import XCTest
@testable import Conduck

@MainActor
final class WorkboardBoardProjectionTests: XCTestCase {
    private enum TestError: Error { case unexpectedCall }

    /// Lets a dependency closure act on the view model that owns it, which is
    /// only constructible after the dependencies exist.
    private final class BoardGate {
        var beforeReturning: (@MainActor () -> Void)?
        var receipt: WorkboardDispatchReceipt?
        var setStateResult: WorkboardItemSnapshot?
    }

    // MARK: - Late results never undo a newer read

    func testStaleDispatchReceiptCannotOverwriteANewerLoadedSnapshot() async {
        let itemID = UUID()
        let gate = BoardGate()
        let viewModel = makeViewModel(gate: gate)

        let prepared = item(id: itemID, title: "As sent", state: .waiting, revision: 10)
        let newer = item(id: itemID, title: "Reply arrived", state: .review, revision: 12)
        viewModel.items = [prepared]
        gate.receipt = WorkboardDispatchReceipt(
            item: item(id: itemID, title: "Receipt", state: .waiting, revision: 10),
            conversationID: UUID(),
            runID: UUID()
        )
        // The corrective reload lands while dispatch is still in flight.
        gate.beforeReturning = { viewModel.items = [newer] }

        await dispatch(itemID: itemID, on: viewModel)

        XCTAssertEqual(viewModel.item(withID: itemID)?.title, "Reply arrived")
        XCTAssertEqual(viewModel.item(withID: itemID)?.revision, 12)
    }

    func testReceiptAtTheSameRevisionStillWins() async {
        let itemID = UUID()
        let gate = BoardGate()
        let viewModel = makeViewModel(gate: gate)

        viewModel.items = [item(id: itemID, title: "Draft", state: .draft, revision: 10)]
        gate.receipt = WorkboardDispatchReceipt(
            item: item(id: itemID, title: "Draft", state: .waiting, revision: 10),
            conversationID: UUID(),
            runID: UUID()
        )

        await dispatch(itemID: itemID, on: viewModel)

        XCTAssertEqual(
            viewModel.item(withID: itemID)?.state,
            .waiting,
            "the receipt carries the claim the store cannot report yet"
        )
    }

    func testAnyOperationResultAtAnOlderRevisionIsDropped() async {
        let itemID = UUID()
        let gate = BoardGate()
        let viewModel = makeViewModel(gate: gate)

        let held = item(id: itemID, title: "Newer", state: .review, revision: 7)
        viewModel.items = [held]
        gate.setStateResult = item(id: itemID, title: "Older", state: .done, revision: 6)

        await viewModel.transition(held, to: .done)

        XCTAssertEqual(viewModel.item(withID: itemID)?.title, "Newer")
        XCTAssertEqual(viewModel.item(withID: itemID)?.state, .review)
    }

    // MARK: - Search

    func testSearchMatchesTheStoredCorpusAcrossMaterialsAndReplies() {
        let board = item(
            id: UUID(),
            title: "Quarterly plan",
            state: .draft,
            revision: 1,
            materials: [WorkboardMaterialSnapshot(
                kind: .note,
                name: "Pricing note",
                textContent: "Anchor at twenty"
            )],
            runs: [WorkboardRunSnapshot(
                state: .replied,
                gatewayRef: .builtin(.openclaw),
                gatewayName: "OpenClaw",
                sentPrompt: "Compare the launch plans",
                resultMarkdown: "Recommend the smaller launch"
            )]
        )
        let other = item(id: UUID(), title: "Unrelated", state: .draft, revision: 1)
        let items = [board, other]

        for needle in ["ANCHOR at twenty", "smaller launch", "compare the launch"] {
            XCTAssertEqual(
                WorkboardPresentationLogic.visibleItems(items, filter: .all, searchText: needle)
                    .map(\.id),
                [board.id],
                "\(needle) must reach the prebuilt corpus"
            )
        }
        XCTAssertTrue(WorkboardPresentationLogic.visibleItems(
            items,
            filter: .all,
            searchText: "nothing here"
        ).isEmpty)
    }

    func testEmptinessProbeAgreesWithTheFullDerivationWithoutBuildingIt() {
        let matching = item(
            id: UUID(),
            title: "Launch plan",
            state: .review,
            revision: 1,
            runs: [WorkboardRunSnapshot(
                state: .replied,
                gatewayRef: .builtin(.openclaw),
                gatewayName: "OpenClaw",
                sentPrompt: "Draft the note",
                resultMarkdown: "Here is the note"
            )]
        )
        let done = item(id: UUID(), title: "Closed", state: .done, revision: 1)
        let boards: [[WorkboardItemSnapshot]] = [[], [done], [matching, done]]

        for items in boards {
            for filter in WorkboardFilter.allCases {
                for needle in ["", "launch", "here is the note", "absent"] {
                    XCTAssertEqual(
                        WorkboardPresentationLogic.hasVisibleItems(
                            items,
                            filter: filter,
                            searchText: needle
                        ),
                        !WorkboardPresentationLogic.visibleItems(
                            items,
                            filter: filter,
                            searchText: needle
                        ).isEmpty,
                        "filter \(filter) needle \(needle)"
                    )
                }
            }
        }
    }

    func testTypingDefersTheAppliedNeedleWhileClearingAppliesAtOnce() async {
        let viewModel = makeViewModel(gate: BoardGate())
        viewModel.items = [item(id: UUID(), title: "Launch plan", state: .draft, revision: 1)]

        viewModel.updateSearchText("l")
        viewModel.updateSearchText("la")
        viewModel.updateSearchText("launch")

        XCTAssertEqual(viewModel.searchText, "launch")
        XCTAssertEqual(viewModel.appliedSearchText, "", "the board must not refilter mid-word")

        await waitUntil { viewModel.appliedSearchText == "launch" }
        XCTAssertEqual(viewModel.visibleItems.count, 1)

        viewModel.updateSearchText("")
        XCTAssertEqual(
            viewModel.appliedSearchText,
            "",
            "clearing is a navigation, not a narrowing — it must not wait"
        )
    }

    // MARK: - Move affordance

    func testNeighbourIndexAnswersExactlyWhatMovePlanningWould() {
        let items = [
            item(id: UUID(), title: "Pinned A", state: .draft, revision: 1, boardOrder: 0, isPinned: true),
            item(id: UUID(), title: "Pinned B", state: .review, revision: 1, boardOrder: 1, isPinned: true),
            item(id: UUID(), title: "First", state: .draft, revision: 1, boardOrder: 0),
            item(id: UUID(), title: "Second", state: .waiting, revision: 1, boardOrder: 1),
            item(id: UUID(), title: "Third", state: .review, revision: 1, boardOrder: 2)
        ]
        let strip = WorkboardPresentationLogic.projectStripItems(items, filter: .all, searchText: "")
        let visibleIDs = Set(strip.map(\.id))

        for shelf in [strip.filter(\.isPinned), strip.filter { !$0.isPinned }] {
            for (index, card) in shelf.enumerated() {
                XCTAssertEqual(
                    WorkboardBoardOrdering.request(
                        moving: card.id,
                        direction: .earlier,
                        in: items,
                        visibleItemIDs: visibleIDs
                    ) != nil,
                    index > 0,
                    "\(card.title) earlier"
                )
                XCTAssertEqual(
                    WorkboardBoardOrdering.request(
                        moving: card.id,
                        direction: .later,
                        in: items,
                        visibleItemIDs: visibleIDs
                    ) != nil,
                    index + 1 < shelf.count,
                    "\(card.title) later"
                )
            }
        }
    }

    // MARK: - Composer flag

    func testComposerFlagTracksNormalizedEmptinessRatherThanRawText() {
        let viewModel = makeViewModel(gate: BoardGate())
        let itemID = UUID()

        viewModel.setWorkspaceComposerDraft("   \n ", for: itemID)
        XCTAssertFalse(viewModel.hasComposerDraft(for: itemID), "whitespace is not a thought")

        viewModel.setWorkspaceComposerDraft("  a real thought ", for: itemID)
        XCTAssertTrue(viewModel.hasComposerDraft(for: itemID))

        viewModel.setWorkspaceComposerDraft("", for: itemID)
        XCTAssertFalse(viewModel.hasComposerDraft(for: itemID))
    }

    func testAbandoningAProvisionalCanvasClearsItsComposerFlag() {
        let viewModel = makeViewModel(gate: BoardGate())
        let provisionalID = viewModel.beginWorkspace()

        viewModel.setWorkspaceComposerDraft("half written", for: provisionalID)
        XCTAssertTrue(viewModel.hasComposerDraft(for: provisionalID))

        viewModel.cancelProvisionalWorkspace()

        XCTAssertFalse(viewModel.hasComposerDraft(for: provisionalID))
        XCTAssertEqual(viewModel.workspaceComposerDraft(for: provisionalID), "")
    }

    // MARK: - Lane order

    func testLaneOrderIsDerivedFromAttentionRank() {
        XCTAssertEqual(WorkItemState.attentionOrder, [.review, .waiting, .draft, .done])
        XCTAssertEqual(
            WorkItemState.attentionOrder.map(\.attentionRank),
            Array(0..<WorkItemState.allCases.count),
            "every lane must have a distinct, contiguous rank"
        )
    }

    // MARK: - Helpers

    private func dispatch(itemID: UUID, on viewModel: WorkboardViewModel) async {
        viewModel.gateways = [WorkboardGatewayChoice(
            ref: .builtin(.openclaw),
            name: "OpenClaw",
            detail: ""
        )]
        viewModel.selectedGatewayID = viewModel.gateways[0].id
        viewModel.preflightItemID = itemID
        await viewModel.dispatchPreflight()
    }

    /// `searchCorpus` is built inside the initializer, so materials and runs must
    /// be supplied here rather than assigned onto a finished snapshot.
    private func item(
        id: UUID,
        title: String,
        state: WorkItemState,
        revision: Int64,
        materials: [WorkboardMaterialSnapshot] = [],
        runs: [WorkboardRunSnapshot] = [],
        boardOrder: Int64? = nil,
        isPinned: Bool = false
    ) -> WorkboardItemSnapshot {
        WorkboardItemSnapshot(
            id: id,
            title: title,
            objective: title,
            state: state,
            materials: materials,
            runs: runs,
            isPinned: isPinned,
            createdAt: Date(timeIntervalSince1970: 0),
            modifiedAt: Date(timeIntervalSince1970: 0),
            boardOrder: boardOrder,
            revision: revision
        )
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for asynchronous board state", file: file, line: line)
    }

    private func makeViewModel(gate: BoardGate) -> WorkboardViewModel {
        WorkboardViewModel(dependencies: WorkboardViewModel.Dependencies(
            loadItems: { [] },
            loadGateways: { ([], []) },
            saveDraft: { _ in throw TestError.unexpectedCall },
            saveDraftAsCopy: { _ in throw TestError.unexpectedCall },
            importMaterial: { _, _, _, _ in throw TestError.unexpectedCall },
            removeMaterial: { _, _, _ in throw TestError.unexpectedCall },
            replaceMaterial: { _, _, _, _, _ in throw TestError.unexpectedCall },
            deleteItem: { _ in throw TestError.unexpectedCall },
            duplicateItem: { _ in throw TestError.unexpectedCall },
            reorderItems: { _ in throw TestError.unexpectedCall },
            setState: { [gate] _, _ in
                gate.beforeReturning?()
                guard let result = gate.setStateResult else { throw TestError.unexpectedCall }
                return result
            },
            acknowledgeRun: { _, _, _ in throw TestError.unexpectedCall },
            dispatch: { [gate] _ in
                gate.beforeReturning?()
                guard let receipt = gate.receipt else { throw TestError.unexpectedCall }
                return receipt
            },
            openConversation: { _ in },
            openMaterial: { _ in },
            openGatewaySettings: {}
        ))
    }
}
