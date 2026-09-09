// SPDX-License-Identifier: Apache-2.0
// Conduck
// KeyboardDismissalDriftGuardTests.swift
//
// SOURCE DRIFT GUARD over the one sanctioned tap-to-dismiss and the two
// surfaces that carry it: Chat's thread and Work's board.
//
// Three facts decide whether the keyboard can be put away on a short list, and
// none of them can fail anywhere else. (1) `dismissesKeyboardOnScrollOrTap()`
// carries all three pieces — always-on bounce (so `.interactively` has a pan to
// ride when the content is shorter than the viewport), the interactive
// dismissal mode, and a plain child-first tap — with the bounce and the tap
// compiled for iOS only, because always-on bounce rubber-bands a short thread
// on the Mac for no keyboard. (2) The tap is a PLAIN `.onTapGesture`: a
// high-priority or simultaneous gesture would steal or shadow every Button,
// link and card underneath it, and a window-wide `endEditing` cannot exclude
// them at all. (3) Each surface applies the modifier to its ScrollView BEFORE
// the `.safeAreaInset` that hosts its composer, so the text field sits outside
// the tap-bearing view — a field inside it would need two taps to focus and
// would lose focus to its own surroundings.
//
// These are SwiftUI expressions whose behaviour is decided by structure rather
// than by values a unit test could call into, so each invariant is asserted
// where it is written: over the file's text with comments stripped and
// compilation directives intact (`RefusalLaneSource`), scoped to one
// declaration's closure. Platform ownership is read by exact spelling through
// `WorkboardSourceDirectives`, never by substring. A guard that fails because
// the shape legitimately changed is a guard to update, not a bug to route
// around.

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

    /// All three pieces are present, and the two that change how a short list
    /// feels compile for iOS only.
    func testModifierCarriesAllThreePiecesAndGatesTheIOSOnes() throws {
        let source = try RefusalLaneSource.source(at: Self.modifierPath)
        let body = try RefusalLaneSource.body(
            ofFunction: "dismissesKeyboardOnScrollOrTap",
            in: source,
            path: Self.modifierPath
        )

        XCTAssertTrue(
            body.contains("scrollBounceBehavior(.always)"),
            "Without always-on bounce a scroll view shorter than the viewport never starts the pan that `.interactively` rides, and drag-to-dismiss silently does nothing on a one-message thread."
        )
        XCTAssertTrue(
            body.contains("scrollDismissesKeyboard(.interactively)"),
            "The modifier replaces the bare mode at both call sites, so it must still carry it."
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
    func testWorkDeskScrollViewUsesTheModifierBeforeTheComposerInset() throws {
        let source = try RefusalLaneSource.source(at: Self.deskPath)

        XCTAssertEqual(
            occurrences(of: Self.modifierCall, in: source), 1,
            "Work's desk must apply `dismissesKeyboardOnScrollOrTap()` exactly once, on its ScrollView."
        )
        XCTAssertEqual(
            occurrences(of: Self.bareMode, in: source), 0,
            "The bare mode is what the modifier replaces; a second copy is a drift back to drag-only."
        )

        let modifier = try XCTUnwrap(source.range(of: Self.modifierCall))
        let inset = try XCTUnwrap(
            source.range(of: ".safeAreaInset(edge: .bottom"),
            "No bottom `.safeAreaInset` in \(Self.deskPath) — the composer moved; update this guard."
        )
        XCTAssertLessThan(
            modifier.lowerBound, inset.lowerBound,
            "Applied after the inset, the modifier would wrap the composer too: the field would sit inside the tap-bearing view and need two taps to focus."
        )
    }
}
