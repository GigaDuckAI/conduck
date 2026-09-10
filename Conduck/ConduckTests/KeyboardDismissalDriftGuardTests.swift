// SPDX-License-Identifier: Apache-2.0
// Conduck
// KeyboardDismissalDriftGuardTests.swift
//
// Source integration guards for Chat and Work keyboard dismissal. In particular,
// a new Chat renders the host's empty state WITHOUT a ConversationThreadView,
// so guarding only the thread misses the first place a person types a draft.
// Keep the empty-state gestures after its full-size frame and keep composers
// outside all dismissal gestures. Scroll dismissal is immediate on iOS, and
// its tap hit region explicitly includes blank viewport space.
// These checks read source, not touch events or keyboard visibility. They catch
// omitted wiring and platform/placement drift; they do not replace device QA.

import XCTest

final class KeyboardDismissalDriftGuardTests: XCTestCase {

    private static let modifierPath = "Conduck/Views/Components/KeyboardDismissal.swift"
    private static let threadPath = "Conduck/Views/Conversation/ConversationThreadView.swift"
    private static let deskPath = "Conduck/Views/Workboard/WorkboardDetailView.swift"

    private static let modifierCall = ".dismissesKeyboardOnScrollOrTap()"
    private static let bareMode = ".scrollDismissesKeyboard("

    private func occurrences(of needle: String, in haystack: String) -> Int {
        var count = 0
        var index = haystack.startIndex
        while let found = haystack.range(of: needle, range: index..<haystack.endIndex) {
            count += 1
            index = found.upperBound
        }
        return count
    }

    private func ownership(of needle: String, in source: String, file: StaticString = #filePath, line: UInt = #line) throws -> WorkboardSourceDirectives.Ownership {
        let conditions = try XCTUnwrap(
            WorkboardSourceDirectives.enclosingConditions(of: needle, in: source),
            "`\(needle)` is absent from \(Self.modifierPath).",
            file: file,
            line: line
        )
        return WorkboardSourceDirectives.ownership(of: conditions)
    }

    // MARK: - The modifier

    /// Scroll-start dismissal and blank-space taps are iOS-only.
    func testModifierCarriesAllThreePiecesAndGatesTheIOSOnes() throws {
        let source = try RefusalLaneSource.source(at: Self.modifierPath)
        let body = try RefusalLaneSource.body(
            ofFunction: "dismissesKeyboardOnScrollOrTap",
            in: source,
            path: Self.modifierPath
        )

        XCTAssertTrue(
            body.contains("scrollBounceBehavior(.always)"),
            "Short threads and boards must still participate in scrolling."
        )
        XCTAssertTrue(
            body.contains("scrollDismissesKeyboard(.immediately)"),
            "Ordinary scrolling must dismiss without requiring a drag into the keyboard."
        )
        XCTAssertTrue(
            body.contains(".onTapGesture"),
            "Tap-empty-space dismissal is the half that works when the user does not think to drag."
        )

        XCTAssertEqual(
            try ownership(of: "scrollBounceBehavior(.always)", in: body),
            .exclusive(.iOS),
            "Always-on bounce rubber-bands a short thread on the Mac, a visible change for no keyboard."
        )
        XCTAssertEqual(
            try ownership(of: "scrollDismissesKeyboard(.immediately)", in: body),
            .exclusive(.iOS)
        )
        let hitShape = try XCTUnwrap(body.range(of: ".contentShape(Rectangle())"))
        let tap = try XCTUnwrap(body.range(of: ".onTapGesture"))
        XCTAssertLessThan(hitShape.lowerBound, tap.lowerBound,
                          "The tap's hit region must include the whole blank viewport.")
        XCTAssertEqual(try ownership(of: ".contentShape(Rectangle())", in: body), .exclusive(.iOS))
        XCTAssertEqual(
            try ownership(of: ".onTapGesture", in: body),
            .exclusive(.iOS),
            "The Mac has no software keyboard; a tap layer there is a side effect for nothing."
        )
        XCTAssertEqual(
            try ownership(of: "UIApplication", in: source),
            .exclusive(.iOS),
            "UIKit is an iOS import; the resign helper must not reach the Mac build."
        )
    }

    // MARK: - A Chat before its first send

    func testNewChatHostsDismissWithoutAMountedThread() throws {
        for path in ["Conduck/ContentView.swift", "Conduck/Views/Conversation/ConversationLibraryView.swift"] {
            let source = try RefusalLaneSource.source(at: path)
            let threadContent = try RefusalLaneSource.trailingClosure(
                after: "private var threadContent: some View", in: source, path: path
            )
            XCTAssertTrue(threadContent.contains("startEmptyState"))
            let emptyState = try RefusalLaneSource.trailingClosure(
                after: "private var startEmptyState: some View", in: source, path: path
            )
            let frame = try XCTUnwrap(emptyState.range(of: ".frame(maxWidth: .infinity, maxHeight: .infinity)"))
            let modifier = try XCTUnwrap(emptyState.range(of: ".dismissesKeyboardOnEmptySpaceInteraction()"),
                                         "New Chat must dismiss before any thread exists: \(path)")
            XCTAssertLessThan(frame.lowerBound, modifier.lowerBound,
                              "The gesture must cover the full empty area, not just the mascot and text.")
            XCTAssertFalse(emptyState.contains("Composer"), "The composer must remain outside this gesture.")
        }
    }

    func testNonScrollableEmptyStateHasItsOwnIOSOnlyDragAndTap() throws {
        let source = try RefusalLaneSource.source(at: Self.modifierPath)
        let body = try RefusalLaneSource.body(
            ofFunction: "dismissesKeyboardOnEmptySpaceInteraction", in: source, path: Self.modifierPath
        )
        for gesturePiece in ["contentShape(Rectangle())", ".onTapGesture", "DragGesture()", ".onChanged"] {
            XCTAssertEqual(try ownership(of: gesturePiece, in: body), .exclusive(.iOS))
        }
        XCTAssertFalse(body.contains("scrollDismissesKeyboard"),
                       "A scroll modifier cannot dismiss on drag when no ScrollView exists.")
    }

    /// The tap never outranks a child: no high-priority or simultaneous gesture,
    /// and no window-wide resign that cannot exclude Buttons.
    func testModifierNeverStealsChildTaps() throws {
        let source = try RefusalLaneSource.source(at: Self.modifierPath)
        for forbidden in ["highPriorityGesture", "simultaneousGesture", "endEditing(", "keyWindow"] {
            XCTAssertFalse(
                source.contains(forbidden),
                "`\(forbidden)` in \(Self.modifierPath) — the dismissal must stay a plain child-first tap that resigns the first responder, so cards, links and the composer's own taps keep winning."
            )
        }
    }

    // MARK: - Chat's thread

    /// The thread's ScrollView carries the modifier once, carries no bare mode,
    /// and hosts no composer: the field lives in the host's inset, outside the
    /// tap-bearing view.
    func testChatThreadScrollViewUsesTheModifier() throws {
        let source = try RefusalLaneSource.source(at: Self.threadPath)
        let scrollContent = try RefusalLaneSource.trailingClosure(
            after: "private var scrollContent: some View",
            in: source,
            path: Self.threadPath
        )

        XCTAssertEqual(
            occurrences(of: Self.modifierCall, in: scrollContent), 1,
            "Chat's thread must apply `dismissesKeyboardOnScrollOrTap()` exactly once, on the ScrollView in `scrollContent`."
        )
        XCTAssertEqual(
            occurrences(of: Self.bareMode, in: scrollContent), 0,
            "The bare mode is what the modifier replaces; a second copy is a drift back to drag-only."
        )

        let scrollView = try XCTUnwrap(scrollContent.range(of: "ScrollView {"), "No `ScrollView {` in `scrollContent`.")
        let modifier = try XCTUnwrap(scrollContent.range(of: Self.modifierCall))
        XCTAssertLessThan(
            scrollView.lowerBound, modifier.lowerBound,
            "The modifier belongs on the ScrollView, after its content."
        )

        XCTAssertFalse(
            scrollContent.contains("Composer"),
            "A composer inside `scrollContent` would sit inside the tap-bearing view and lose focus to its own surroundings; the hosts attach it as a `.safeAreaInset` for this reason."
        )
    }

    // MARK: - Work's board

    /// The desk's ScrollView carries the modifier once, carries no bare mode,
    /// and applies it BEFORE the inset that hosts the composer.
    func testWorkDeskDismissalStaysInsideSourcesAndOutsideComposer() throws {
        let host = try RefusalLaneSource.source(at: Self.deskPath)
        let sources = try RefusalLaneSource.source(at: "Conduck/Views/Workboard/WorkDeskSourceBoard.swift")
        let canvas = try RefusalLaneSource.source(at: "Conduck/Views/Workboard/WorkDeskCanvas.swift")
        XCTAssertTrue(host.contains(".safeAreaInset(edge: .bottom"))
        XCTAssertTrue(host.contains("mode: .composer"))
        XCTAssertFalse(host.contains(Self.modifierCall), "Dismissal belongs to source content, not the composer host.")
        XCTAssertTrue(sources.contains(Self.modifierCall), "The list must dismiss on scrolling and empty-space taps.")
        XCTAssertTrue(canvas.contains("KeyboardDismissal.dismissKeyboard()"), "Spatial pan/tap must dismiss the capture keyboard.")
        XCTAssertFalse(sources.contains("mode: .composer"))
        XCTAssertFalse(canvas.contains("mode: .composer"))
    }
}
