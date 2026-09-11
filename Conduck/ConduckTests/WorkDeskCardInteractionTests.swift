// SPDX-License-Identifier: Apache-2.0

// Deterministic contracts behind whole-object movement. Escape suppresses
// the rest of the same physical gesture
// rather than allowing a later update to commit the cancelled move. Keyboard
// shortcuts remain local and must not consume application-level modifiers.

import XCTest
import SwiftUI
@testable import Conduck

final class WorkDeskCardInteractionTests: XCTestCase {
    func testMaterialsProjectsAndOverviewShareTheWholeSurfaceDragOwner() throws {
        let source = try RefusalLaneSource.source(at: "Conduck/Views/Workboard/WorkDeskCanvas.swift")
        for method in ["materialCard", "projectPile"] {
            let body = try RefusalLaneSource.body(ofFunction: method, in: source, path: "WorkDeskCanvas.swift")
            let gesture = try XCTUnwrap(body.range(of: ".workDeskObjectDrag("))
            let position = try XCTUnwrap(body.range(of: ".position(x: frame.midX"))
            XCTAssertLessThan(gesture.lowerBound, position.lowerBound)
            XCTAssertTrue(body.contains("onLocation: recordDragPointer"))
        }
        let card = try RefusalLaneSource.source(at: "Conduck/Views/Workboard/WorkDeskCard.swift")
        XCTAssertTrue(card.contains(".highPriorityGesture("))
        XCTAssertTrue(card.contains("DragGesture(minimumDistance: 6, coordinateSpace: .named(coordinateSpace))"),
            "Taps must reach nested buttons until movement deliberately becomes a drag.")
        XCTAssertEqual(card.components(separatedBy: "DragGesture(").count - 1, 1,
            "Each object must keep one gesture owner across presentation modes.")
    }

    func testEscapeSuppressesUpdatesUntilTheHeldGestureReleases() {
        var state = WorkDeskGripDragState()
        XCTAssertTrue(state.beginUpdate())
        XCTAssertTrue(state.isActive)
        XCTAssertTrue(state.cancel())
        XCTAssertFalse(state.isActive)
        XCTAssertTrue(state.isSuppressed)

        XCTAssertFalse(state.beginUpdate(), "Pointer motion after Escape must not restart this drag.")
        XCTAssertFalse(state.cancel(), "Repeated Escape must not cancel twice.")
        XCTAssertFalse(state.release(), "A cancelled gesture must never commit at release.")
        XCTAssertFalse(state.isSuppressed)

        XCTAssertTrue(state.beginUpdate(), "The next physical gesture must work normally.")
        XCTAssertTrue(state.release())
    }

    func testNaturalReleaseCanCommitOnlyOnce() {
        var state = WorkDeskGripDragState()
        XCTAssertFalse(state.release())
        XCTAssertTrue(state.beginUpdate())
        XCTAssertTrue(state.beginUpdate())
        XCTAssertTrue(state.release())
        XCTAssertFalse(state.release(), "GestureState reset follows onEnded and must not finish twice.")
    }

    func testArrowKeysNudgeInTheExpectedDirection() {
        XCTAssertEqual(WorkDeskGripKeyboardPolicy.translation(for: .leftArrow, modifiers: []), CGSize(width: -32, height: 0))
        XCTAssertEqual(WorkDeskGripKeyboardPolicy.translation(for: .rightArrow, modifiers: []), CGSize(width: 32, height: 0))
        XCTAssertEqual(WorkDeskGripKeyboardPolicy.translation(for: .upArrow, modifiers: []), CGSize(width: 0, height: -32))
        XCTAssertEqual(WorkDeskGripKeyboardPolicy.translation(for: .downArrow, modifiers: [.shift]), CGSize(width: 0, height: 128))
    }

    func testApplicationShortcutsAndNonArrowKeysDoNotNudgeCards() {
        let shortcuts: [EventModifiers] = [.command, .control, .option, [.command, .shift]]
        for modifiers in shortcuts {
            XCTAssertNil(WorkDeskGripKeyboardPolicy.translation(for: .rightArrow, modifiers: modifiers))
        }
        XCTAssertNil(WorkDeskGripKeyboardPolicy.translation(for: .escape, modifiers: []))
        XCTAssertNil(WorkDeskGripKeyboardPolicy.translation(for: .return, modifiers: []))
    }
}
