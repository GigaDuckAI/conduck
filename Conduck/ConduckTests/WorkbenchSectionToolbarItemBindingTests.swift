// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkbenchSectionToolbarItemBindingTests.swift
//
// The two-way seam behind the Chats | Work control, driven directly.
//
// `WorkbenchSectionToolbarItem` is `ToolbarContent`: its body is an opaque type
// no test can mount, so every claim about the control's wiring has to be made
// about a value instead. `selectionBinding(for:)` is that value, and both of its
// halves fail SILENTLY when wrong. A `get` that captured a copy of the
// destination leaves the highlighted half stuck on the section the user just
// left; a `set` that wrote anywhere but the router makes the whole control a
// decoration — tappable, highlighted, and connected to nothing. Neither shows up
// in a compiler error, in the source guard, or in any other suite.
//
// The router is the real one, not a double: the property under test is that the
// binding reaches THIS object's `destination`, which a stand-in could not
// demonstrate. The sibling source guard
// (`WorkbenchShellDriftGuardTests.testSectionToolbarItemUsesTheTestedBindingInItsPrimaryAction`)
// is what holds the toolbar to the binding tested here — without it this file
// could keep passing on a helper the shipped item no longer calls.

import SwiftUI
import XCTest
@testable import Conduck

@MainActor
final class WorkbenchSectionToolbarItemBindingTests: XCTestCase {

    func testSelectionBindingReadsAndWritesTheRouter() {
        let router = PersonalWorkbenchRouter()
        // Taken ONCE, then used for every read below: a binding rebuilt between
        // assertions would read the router freshly each time and hide exactly
        // the staleness this test exists to catch.
        let binding = WorkbenchSectionToolbarItem.selectionBinding(for: router)

        XCTAssertEqual(
            binding.wrappedValue, .chats,
            "The control opens on something other than Chats. Chat is mounted first on purpose, so "
            + "the switch has to agree with the section actually on screen at launch."
        )

        // A change the control did not make: a deep link, a Handoff, a capture
        // arriving in Work. The same binding has to see it.
        router.destination = .work
        XCTAssertEqual(
            binding.wrappedValue, .work,
            "The binding did not follow a destination changed elsewhere, so it reads a stale copy. "
            + "The highlighted half would stay on Chats while Work is the section on screen."
        )

        router.destination = .chats
        XCTAssertEqual(
            binding.wrappedValue, .chats,
            "The binding followed the router in one direction only. It has to read the router live, "
            + "not latch the first value it saw."
        )

        // …and the other direction: a tap on a segment.
        binding.wrappedValue = .work
        XCTAssertEqual(
            router.destination, .work,
            "Writing Work through the binding did not reach the router, so tapping Work highlights "
            + "the segment and moves nothing — the control becomes a decoration."
        )

        binding.wrappedValue = .chats
        XCTAssertEqual(
            router.destination, .chats,
            "Writing Chats through the binding did not reach the router. Work would be a one-way "
            + "trip: the user gets in and the control cannot bring them back."
        )
    }
}
