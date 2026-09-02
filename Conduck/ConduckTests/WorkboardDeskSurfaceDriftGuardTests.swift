// SPDX-License-Identifier: Apache-2.0
// Conduck
// WorkboardDeskSurfaceDriftGuardTests.swift
//
// SOURCE DRIFT GUARD over the one rule about the Work shell that no behavioural
// test can hold: `WorkCaptureRefreshCoordinator` is the board's SOLE load owner.
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
// Assertions run over the file's text with comments stripped
// (`RefusalLaneSource`). A guard that fails because the shape legitimately
// changed is a guard to update, not a bug to route around.

import XCTest

final class WorkboardDeskSurfaceDriftGuardTests: XCTestCase {

    private static let shellPath = "Conduck/Views/Workboard/PersonalWorkbenchView.swift"

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
