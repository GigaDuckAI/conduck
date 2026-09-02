// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardDeskPresentationTests.swift
//
// The two decisions the Work surface makes before it draws anything, held here
// rather than inside a `body` no test target can mount.
//
// (1) WHAT IS ON SCREEN. `WorkboardDeskPresentation` resolves the view model's
// load state into one of four surfaces. Work is ONE desk, so the resolver takes
// no id and hands one out; and the desk before its first capture is a state of
// the desk rather than a missing board, which is what keeps the pinned composer
// under it — a failed load is the case that draws no composer, and the two must
// never collapse into one "nothing here" arm.
//
// (2) WHERE A DEEP LINK LANDS. `WorkboardDeepLinkRoute` reveals the desk and
// then ASKS `WorkCaptureRefreshCoordinator` for the reload. The order is the
// behaviour: the coordinator defers a reload requested while Work is hidden, so
// a link that scheduled without revealing would land nothing — which this file
// demonstrates against the real coordinator before showing that the link's own
// pass arrives.

import XCTest
@testable import Conduck

@MainActor
final class WorkboardDeskPresentationTests: XCTestCase {

    // MARK: - Fixtures

    private func material(_ name: String) -> WorkboardMaterialSnapshot {
        WorkboardMaterialSnapshot(
            id: UUID(),
            kind: .note,
            name: name,
            createdAt: Date()
        )
    }

    private func desk(materials: [WorkboardMaterialSnapshot]) -> WorkboardItemSnapshot {
        WorkboardItemSnapshot(
            id: Constants.workboardDeskItemID,
            materials: materials,
            revision: 3
        )
    }

    /// Counts the coordinator's real refresh passes and lets a case wait for the
    /// next one. A reference type because the coordinator's closure escapes.
    @MainActor
    private final class RefreshLog {
        private(set) var count = 0
        var onRefresh: (() -> Void)?

        func record() {
            count += 1
            onRefresh?()
        }
    }

    // MARK: - What the desk surface draws

    /// The desk before its first capture is the DESK, at the compile-time
    /// identity every write addresses — not a missing board, and not a second
    /// one minted for the occasion.
    func testTheDeskBeforeItsFirstCardIsStillTheDeskAtTheFixedIdentity() {
        let presentation = WorkboardDeskPresentation.resolve(
            isLoading: false,
            loadError: nil,
            desk: nil
        )

        guard case .desk(let desk) = presentation else {
            return XCTFail("a desk with no row yet must still resolve to the desk surface")
        }
        XCTAssertEqual(
            desk.item.id, Constants.workboardDeskItemID,
            "the composer on an empty desk must write into the identity the first card lands on"
        )
        XCTAssertEqual(desk.board, .invitation)
        XCTAssertTrue(desk.item.materials.isEmpty)
    }

    func testADeskCarryingCardsDrawsTheBoardRatherThanTheInvitation() {
        let loaded = desk(materials: [material("A thought"), material("Another")])

        let presentation = WorkboardDeskPresentation.resolve(
            isLoading: false,
            loadError: nil,
            desk: loaded
        )

        XCTAssertEqual(presentation, .desk(WorkboardDeskPresentation.Desk(item: loaded)))
        guard case .desk(let desk) = presentation else { return XCTFail("expected the desk") }
        XCTAssertEqual(desk.board, .cards)
        XCTAssertEqual(desk.item.materials.map(\.name), ["A thought", "Another"])
    }

    /// Both draw an invitation-shaped panel, and they are different surfaces:
    /// only the desk case mounts the pinned composer, so collapsing them would
    /// silently make the first capture unreachable on a desk that opened fine.
    func testAnEmptyDeskAndAFailedLoadAreDifferentSurfaces() {
        let empty = WorkboardDeskPresentation.resolve(
            isLoading: false,
            loadError: nil,
            desk: nil
        )
        let failed = WorkboardDeskPresentation.resolve(
            isLoading: false,
            loadError: "the store would not open",
            desk: nil
        )

        XCTAssertEqual(
            empty,
            .desk(WorkboardDeskPresentation.Desk(item: WorkboardItemSnapshot(id: Constants.workboardDeskItemID)))
        )
        XCTAssertEqual(failed, .loadFailed(message: "the store would not open"))
        XCTAssertNotEqual(empty, failed)
    }

    /// A board already in hand stays on screen through a reload and through a
    /// reload that failed: the cards it shows are still the truth, and only the
    /// read went wrong.
    func testAWarmBoardSurvivesBothAReloadAndAFailedReload() {
        let loaded = desk(materials: [material("Kept")])

        XCTAssertEqual(
            WorkboardDeskPresentation.resolve(isLoading: true, loadError: nil, desk: loaded),
            .desk(WorkboardDeskPresentation.Desk(item: loaded))
        )
        XCTAssertEqual(
            WorkboardDeskPresentation.resolve(isLoading: false, loadError: "boom", desk: loaded),
            .desk(WorkboardDeskPresentation.Desk(item: loaded))
        )
        XCTAssertEqual(
            WorkboardDeskPresentation.resolve(isLoading: true, loadError: nil, desk: nil),
            .loading,
            "the first load has no board to keep, so it draws the opening state"
        )
    }

    // MARK: - Where a Work deep link lands

    /// The link takes no payload — the signature says so — reveals the desk, and
    /// asks for the reload rather than running one.
    func testAWorkDeepLinkRevealsTheDeskAndAsksForTheReload() {
        let router = PersonalWorkbenchRouter()
        let log = RefreshLog()
        let route = WorkboardDeepLinkRoute(router: router) { log.record() }

        router.destination = .chats
        route.open()

        XCTAssertEqual(router.destination, .work)
        XCTAssertEqual(log.count, 1, "the link must request exactly one reload")
    }

    /// …and revealing the desk FIRST is what makes that reload land. The real
    /// coordinator defers a reload requested while Work is hidden, which this
    /// case establishes in the middle block before the link's own pass arrives.
    func testTheDeepLinksReloadLandsBecauseTheDeskWasRevealedFirst() async throws {
        let router = PersonalWorkbenchRouter()
        let log = RefreshLog()
        let coordinator = WorkCaptureRefreshCoordinator(
            refreshDelay: .milliseconds(1),
            boardIsVisible: { router.destination == .work },
            drainCaptures: { true },
            refresh: { log.record() }
        )
        let route = WorkboardDeepLinkRoute(router: router) {
            coordinator.schedule(includeCaptureDrain: false)
        }

        // The FIRST pass runs hidden or not — it warms the board — so it proves
        // nothing on its own. Spend it here.
        let warmed = expectation(description: "the board's first pass")
        log.onRefresh = { warmed.fulfill() }
        coordinator.schedule(includeCaptureDrain: false)
        await fulfillment(of: [warmed], timeout: 2)
        XCTAssertEqual(log.count, 1)

        // A reload asked for while Work is hidden is DEFERRED.
        router.destination = .chats
        log.onRefresh = { XCTFail("a reload requested while Work is hidden must be deferred") }
        coordinator.schedule(includeCaptureDrain: false)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(log.count, 1)

        // So the link's pass landing is evidence that it revealed the desk.
        let landed = expectation(description: "the deep link's pass")
        log.onRefresh = { landed.fulfill() }
        route.open()
        await fulfillment(of: [landed], timeout: 2)

        XCTAssertEqual(log.count, 2)
        XCTAssertEqual(router.destination, .work)
    }
}
