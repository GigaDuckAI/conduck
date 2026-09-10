// SPDX-License-Identifier: Apache-2.0

// Deterministic contracts behind the spatial handle. A narrow card must leave
// room to drag, and Escape must suppress the rest of the same physical gesture
// rather than allowing a later update to commit the cancelled move. Keyboard
// shortcuts remain local and must not consume application-level modifiers.

import XCTest
import SwiftUI
@testable import Conduck

final class WorkDeskCardInteractionTests: XCTestCase {
    func testNarrowHeadersReserveACompleteGripBeforeAddingButtons() {
        let widths: [CGFloat] = [44, 81.2, 87.9, 88, 131.9, 132, 139.2, 232]
        for width in widths {
            let controls = (WorkDeskCardHeaderPolicy.showsSelection(width: width) ? 1 : 0)
                + (WorkDeskCardHeaderPolicy.showsPin(width: width) ? 1 : 0)
            let remaining = width - CGFloat(controls) * WorkDeskCardHeaderPolicy.targetSize
            XCTAssertGreaterThanOrEqual(remaining, 44, "No full grip remains at width \(width)")
        }
        XCTAssertFalse(WorkDeskCardHeaderPolicy.showsSelection(width: 81.2))
        XCTAssertFalse(WorkDeskCardHeaderPolicy.showsPin(width: 131.9))
        XCTAssertTrue(WorkDeskCardHeaderPolicy.showsPin(width: 132))
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
