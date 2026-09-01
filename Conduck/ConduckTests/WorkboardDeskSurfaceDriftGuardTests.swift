// SPDX-License-Identifier: Apache-2.0
// Conduck
// WorkboardDeskSurfaceDriftGuardTests.swift
//
// SOURCE DRIFT GUARD over the two rules that make Work one desk at the view
// layer. Both are invisible in a diff and neither can be reached from a unit
// test: `WorkboardDetailView` and `PersonalWorkbenchView` are SwiftUI views
// whose routing lives in a `body` and a private method.
//
// (1) The desk resolves NO item id. It reads the view model's desk directly and
// addresses `Constants.workboardDeskItemID`, so a surface that still carries an
// id can never point the desk at a second board — and a Work deep link resolves
// to that same desk whatever its payload says.
// (2) `WorkCaptureRefreshCoordinator` is the board's SOLE load owner. Every
// reload passes its visibility gate and its serialization, so a caller that
// reaches for `workboardViewModel.load()` directly opens a second reload path
// that can double-load or race the pass already in flight.
//
// Assertions run over the files' text with comments stripped
// (`RefusalLaneSource`). A guard that fails because the shape legitimately
// changed is a guard to update, not a bug to route around.

import XCTest

final class WorkboardDeskSurfaceDriftGuardTests: XCTestCase {

    private static let deskPath = "Conduck/Views/Workboard/WorkboardDetailView.swift"
    private static let shellPath = "Conduck/Views/Workboard/PersonalWorkbenchView.swift"

    /// The desk renders the view model's desk state at the fixed identity and
    /// looks nothing up by id.
    func testTheDeskRendersTheFixedIdentityAndResolvesNoItem() throws {
        let source = try RefusalLaneSource.source(at: Self.deskPath)

        XCTAssertTrue(
            source.contains("viewModel.desk"),
            "The desk must render from the view model's desk state."
        )
        XCTAssertTrue(
            source.contains("Constants.workboardDeskItemID"),
            "The desk before its first material must still address the fixed desk identity."
        )
        XCTAssertFalse(
            source.contains("item(withID:"),
            "The desk must not resolve a board by id — there is only one."
        )
        XCTAssertFalse(
            source.contains("let itemID"),
            "The desk must not take an item id from its host."
        )
    }

    /// The empty desk keeps a visible invitation and the pinned composer, so
    /// the first capture is reachable before any row exists.
    func testTheEmptyDeskShowsTheEmptyStateAndKeepsTheComposer() throws {
        let source = try RefusalLaneSource.source(at: Self.deskPath)

        XCTAssertTrue(
            source.contains("WorkboardEmptyState"),
            "An empty desk must draw the shared empty state, not nothing."
        )
        XCTAssertTrue(
            source.contains("mode: .composer"),
            "The pinned composer must survive on the empty desk."
        )
    }

    /// A Work deep link opens the desk and asks the refresh coordinator for the
    /// reload; it never selects and never loads on its own.
    func testEveryWorkDeepLinkResolvesToTheDeskThroughTheRefreshCoordinator() throws {
        let source = try RefusalLaneSource.source(at: Self.shellPath)
        let route = try RefusalLaneSource.body(
            ofFunction: "routeWorkboardDeepLink",
            in: source,
            path: Self.shellPath
        )

        XCTAssertTrue(
            route.contains("destination = .work"),
            "A Work deep link must reveal Work."
        )
        XCTAssertTrue(
            route.contains("scheduleRefresh("),
            "The deep link's reload must go through the refresh coordinator."
        )
        XCTAssertFalse(
            route.contains("workItemIDKey"),
            "Every Work deep link resolves to the one desk; the payload's id selects nothing."
        )
        XCTAssertFalse(
            route.contains("load()"),
            "The deep link must not open a second load path beside the coordinator."
        )
    }

    /// Nothing in the shell loads the board except the coordinator's own
    /// refresh closure.
    func testTheRefreshCoordinatorIsTheOnlyBoardLoadOwner() throws {
        let source = try RefusalLaneSource.source(at: Self.shellPath)

        XCTAssertEqual(
            source.components(separatedBy: "workboardViewModel.load()").count - 1,
            1,
            """
            `WorkCaptureRefreshCoordinator` owns every board load: the one \
            permitted call is its `refresh` closure. Route new reloads through \
            `scheduleRefresh(includeCaptureDrain:)` instead.
            """
        )
    }
}
