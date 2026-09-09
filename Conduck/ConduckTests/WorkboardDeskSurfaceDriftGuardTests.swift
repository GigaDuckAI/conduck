// SPDX-License-Identifier: Apache-2.0
// Conduck
// WorkboardDeskSurfaceDriftGuardTests.swift
//
// SOURCE DRIFT GUARD over two rules about the Work desk that no behavioural
// test can hold: who is allowed to load the board, and which platform compiles
// the board's in-band arrangement row.
//
// Rule 1 — `WorkCaptureRefreshCoordinator` is the board's SOLE load owner.
//
// Every reload — launch, foreground, capture drain, Chat mutation, deep link —
// passes its visibility gate and its serialization, so a caller reaching for
// `workboardViewModel.load()` directly opens a second reload path that can
// double-load or race the pass already in flight. That is an ABSENCE over a
// whole file: a behavioural test can show that one particular action loads
// once, never that no other path exists. The coordinator's own behaviour is
// covered behaviourally by `WorkCaptureRefreshCoordinatorTests`, and what the
// deep link does with it by `WorkboardDeskPresentationTests`.
//
// Rule 2 — the Tiles / List picker and the "Drag to reorder" hint are macOS-only,
// and the board reads its layout from the view model rather than from state of
// its own. On iOS that choice lives in Work's toolbar menu, so cards start at
// the top of the pane instead of below a control band; the Mac keeps the in-band
// row because its window has the width and its bar belongs to the window shell.
// Both halves are ABSENCES a running board cannot show: an in-band picker that
// returned to iOS renders fine, and a board holding its own `layoutMode` also
// renders fine — it just stops answering the toolbar and stops surviving a
// relaunch.
//
// Assertions run over the file's text with comments stripped and compilation
// directives intact (`RefusalLaneSource`). Platform ownership is read by EXACT
// SPELLING through `WorkboardSourceDirectives.ownership(of:)`, never by
// substring: `os(macOS) || os(iOS)` contains the Mac token while shipping the
// row to the phone, so a condition the reader cannot recognise is refused rather
// than assumed. A guard that fails because the shape legitimately changed is a
// guard to update, not a bug to route around.

import XCTest

final class WorkboardDeskSurfaceDriftGuardTests: XCTestCase {

    private static let shellPath = "Conduck/Views/Workboard/PersonalWorkbenchView.swift"
    private static let boardPath = "Conduck/Views/Workboard/WorkboardCaptureCanvas.swift"

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

    /// The in-band arrangement row stays on the Mac, and the cards read the
    /// layout the view model owns.
    func testArrangementControlsRemainMacOnlyAndUseModelLayout() throws {
        let source = try RefusalLaneSource.source(at: Self.boardPath)
        let board = try RefusalLaneSource.trailingClosure(
            after: "private struct WorkboardMaterialBoard: View",
            in: source,
            path: Self.boardPath
        )
        let body = try RefusalLaneSource.trailingClosure(
            after: "var body: some View",
            in: board,
            path: Self.boardPath
        )
        let column = try RefusalLaneSource.trailingClosure(
            after: "VStack(alignment: .leading, spacing: 16)",
            in: body,
            path: Self.boardPath
        )

        let mount = try XCTUnwrap(
            WorkboardSourceDirectives.enclosingConditions(of: "arrangementControls", in: column),
            """
            The board's column no longer mounts `arrangementControls`, so the Mac lost the in-band \
            Tiles / List picker and the "Drag to reorder" hint — the only place either lives on a \
            window whose bar belongs to the shell.
            """
        )
        XCTAssertEqual(
            WorkboardSourceDirectives.ownership(of: mount), .exclusive(.macOS),
            """
            The board mounts `arrangementControls` under something other than a bare `#if os(macOS)`. \
            Widened, negated or nested under a further flag, that row returns to iPhone and iPad, \
            where it would sit between the pane's top inset and the first card — restating a choice \
            Work's toolbar menu already owns and pushing every card down the scrolling band. A \
            condition this guard cannot read is refused rather than assumed.
            """
        )

        let cards = try XCTUnwrap(
            WorkboardSourceDirectives.enclosingConditions(of: "boardContent", in: column),
            "The board's column no longer mounts `boardContent` — the cards themselves are gone."
        )
        XCTAssertEqual(
            WorkboardSourceDirectives.ownership(of: cards), .unconditional,
            """
            `boardContent` is now behind a compilation condition. The cards are the desk on every \
            platform; only the control row above them is Mac-only.
            """
        )

        for declaration in [
            "private var arrangementControls: some View",
            "private var arrangeHint: some View",
            "private var layoutPicker: some View"
        ] {
            let conditions = try XCTUnwrap(
                WorkboardSourceDirectives.enclosingConditions(of: declaration, in: board),
                "`\(declaration)` is gone, so the Mac's in-band arrangement row cannot be built."
            )
            XCTAssertEqual(
                WorkboardSourceDirectives.ownership(of: conditions), .exclusive(.macOS),
                """
                `\(declaration)` no longer compiles under a bare `#if os(macOS)`. These three helpers \
                exist only for the Mac's in-band row, so a widened or negated condition ships an \
                iOS-visible copy — a second, competing control for the same preference. A condition \
                this guard cannot read is refused rather than assumed.
                """
            )
        }

        let picker = try RefusalLaneSource.trailingClosure(
            after: "private var layoutPicker: some View",
            in: board,
            path: Self.boardPath
        )
        XCTAssertTrue(
            picker.contains("Picker(selection: $viewModel.layoutMode)"),
            """
            The Mac's in-band picker no longer writes through to `WorkboardViewModel.layoutMode`, so \
            the window's own control and Work's toolbar menu would drive two different preferences.
            """
        )

        let content = try RefusalLaneSource.trailingClosure(
            after: "private var boardContent: some View",
            in: board,
            path: Self.boardPath
        )
        XCTAssertTrue(
            content.contains("viewModel.layoutMode"),
            """
            The cards no longer read `viewModel.layoutMode`, so whichever control changed it changed \
            nothing the person can see.
            """
        )
        XCTAssertFalse(
            board.contains("@State private var layoutMode"),
            """
            The board holds its own layout state again. A mode chosen in Work's toolbar menu — the \
            only picker iOS has — would never reach the cards, and the choice would not survive a \
            relaunch: persistence rides the view model's property.
            """
        )
    }
}
