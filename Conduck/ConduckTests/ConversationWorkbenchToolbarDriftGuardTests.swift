// SPDX-License-Identifier: Apache-2.0
// Conduck
// ConversationWorkbenchToolbarDriftGuardTests.swift
//
// SOURCE DRIFT GUARD over the Chats-side host of the iPad section switch:
// `ConversationLibraryView.sectionControlHost`.
//
// The switch is the only way back to Work from Chats on iPad, and whether it
// renders at all — and where — is decided by four structural facts, none of
// which a behavioural test can reach:
//
//   1. REACHABILITY. The host hangs off `detailColumn`, so the split view's
//      `detail:` closure has to mount `detailColumn`. Mounted anywhere else the
//      host leaves the tree and Chats becomes a one-way trip.
//   2. THE GATE. The control renders exactly when a shell puts a router in the
//      environment: the wide iPad shell injects one into both mounted layers,
//      the iPhone `TabView` injects none. Dropping `let model =
//      personalWorkbenchModel` therefore breaks no build — it draws the control
//      on the phone, on top of the tab bar that already switches sections.
//   3. TRAILING POSITION. Toolbar items are collected in view-tree order and a
//      parent's item lands BEFORE a descendant's in the same placement.
//      `ConversationThreadView`, inside `threadContent`, declares "Copy
//      conversation" as a `.primaryAction` whenever the open thread has
//      messages. Only as the LAST sibling of the detail `ZStack` does this
//      control stay trailing-most; declared earlier it slides sideways by
//      Copy's width every time a thread empties or takes its first turn.
//   4. SINGULARITY. One `WorkbenchSectionToolbarItem` per bar. A second host
//      compiles and ships two capsules.
//
// A guard and not review, because all four are properties of how the file is
// WRITTEN: a moved sibling, a dropped `let`, or a copied host all compile, all
// read as ordinary SwiftUI plumbing in a diff, and none of them fails a test
// that can only call into values. Assertions run over the file's text with
// comments stripped and scoped to one declaration's closure
// (`RefusalLaneSource`). A guard that fails because the shape legitimately
// changed is a guard to update, not a bug to route around.

import XCTest

final class ConversationWorkbenchToolbarDriftGuardTests: XCTestCase {

    private static let path = "Conduck/Views/Conversation/ConversationLibraryView.swift"

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// Text at brace-depth zero — a closure's OWN siblings, every nested body
    /// dropped. Position among siblings is the whole property here, and an
    /// unscoped search finds `sectionControlHost` in any nested closure just as
    /// happily as in the one place it belongs.
    private func topLevel(of closure: String) -> String {
        var out = ""
        var depth = 0
        for character in closure {
            if character == "{" { depth += 1; continue }
            if character == "}" { depth = max(0, depth - 1); continue }
            if depth == 0 { out.append(character) }
        }
        return out
    }

    func testSectionHostIsTheLastGatedDetailSibling() throws {
        let source = try RefusalLaneSource.source(at: Self.path)

        // 1 — reachable: the split view's detail column is the host's ancestor.
        let body = try RefusalLaneSource.trailingClosure(
            after: "var body: some View",
            in: source,
            path: Self.path
        )
        let detail = try RefusalLaneSource.trailingClosure(
            after: "} detail:",
            in: body,
            path: Self.path
        )
        XCTAssertTrue(
            detail.contains("detailColumn"),
            "The split view's `detail:` closure no longer mounts `detailColumn`. The Chats-side "
            + "section control hangs off that column, so anything else mounted here takes the only "
            + "route back to Work off the screen and strands the user in Chats."
        )

        // 3 — last sibling of the detail ZStack, after the thread and the
        //     shortcuts, with nothing declared behind it.
        let detailColumn = try RefusalLaneSource.trailingClosure(
            after: "private var detailColumn: some View",
            in: source,
            path: Self.path
        )
        let stack = try RefusalLaneSource.trailingClosure(
            after: "ZStack",
            in: detailColumn,
            path: Self.path
        )
        let siblings = topLevel(of: stack)

        // 4 — exactly one host, and a direct sibling of this ZStack rather than
        //     something buried in a nested body.
        XCTAssertEqual(
            occurrences(of: "sectionControlHost", in: stack), 1,
            "`sectionControlHost` is mounted a number of times other than once in the detail "
            + "column. Two hosts put two Chats | Work capsules in the same bar; none leaves Work "
            + "unreachable from Chats."
        )
        XCTAssertEqual(
            occurrences(of: "sectionControlHost", in: siblings), 1,
            "`sectionControlHost` is no longer a direct sibling in the detail `ZStack`. Nested "
            + "inside another container it is collected in that container's order, which is the "
            + "one thing its position exists to control."
        )

        let threadAt = try XCTUnwrap(
            stack.range(of: "threadContent")?.lowerBound,
            "The detail column no longer mounts `threadContent`, so the section control is ordered "
            + "against a thread that is not there."
        )
        let shortcutsAt = try XCTUnwrap(
            stack.range(of: "keyboardShortcuts")?.lowerBound,
            "The detail column no longer mounts `keyboardShortcuts`, so the section control is "
            + "ordered against a sibling that is not there."
        )
        let hostAt = try XCTUnwrap(
            stack.range(of: "sectionControlHost")?.lowerBound,
            "The detail column no longer mounts `sectionControlHost`, so Chats has no way back to "
            + "Work on iPad."
        )
        XCTAssertLessThan(
            threadAt, hostAt,
            "`sectionControlHost` is declared before `threadContent`. Toolbar items are collected "
            + "in view-tree order, so an item declared ahead of the thread sits LEFT of the "
            + "\"Copy conversation\" `.primaryAction` that `ConversationThreadView` adds whenever a "
            + "thread has messages — and the switch then jumps sideways by Copy's width as threads "
            + "open and empty."
        )
        XCTAssertLessThan(
            shortcutsAt, hostAt,
            "`sectionControlHost` is declared before `keyboardShortcuts`. It has to be the LAST "
            + "sibling for the control to stay trailing-most in the detail bar."
        )

        let afterHost = try XCTUnwrap(
            siblings.range(of: "sectionControlHost")?.upperBound,
            "`sectionControlHost` is not among the detail `ZStack`'s own siblings."
        )
        let tail = String(siblings[afterHost...])
        XCTAssertTrue(
            tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "Something is declared after `sectionControlHost` in the detail `ZStack`: \(tail). A "
            + "later sibling — above all a later `.toolbar` — is collected AFTER this control and "
            + "takes the trailing-most slot the switch owns. The `ZStack`'s own ancestor toolbar "
            + "(compose, principal title) stays permitted; it sits outside this closure."
        )

        // 2 — the gate: active destination AND a router in the environment.
        let host = try RefusalLaneSource.trailingClosure(
            after: "private var sectionControlHost: some View",
            in: source,
            path: Self.path
        )
        XCTAssertTrue(
            host.contains("workbenchDestinationIsActive"),
            "`sectionControlHost` no longer gates on `workbenchDestinationIsActive`, so it declares "
            + "toolbar chrome into a bar that belongs to another destination."
        )
        XCTAssertTrue(
            host.contains("let model = personalWorkbenchModel"),
            "`sectionControlHost` no longer gates on a non-nil `personalWorkbenchModel`. That "
            + "binding IS the platform gate: the wide iPad shell injects a router into both mounted "
            + "layers and the iPhone `TabView` injects none, so an ungated host draws a second "
            + "section switch on the phone, above the tab bar that already switches sections."
        )

        let gated = try RefusalLaneSource.trailingClosure(
            after: "if workbenchDestinationIsActive, let model = personalWorkbenchModel",
            in: host,
            path: Self.path
        )
        XCTAssertEqual(
            occurrences(of: ".toolbar", in: gated), 1,
            "The gated arm of `sectionControlHost` declares a number of toolbars other than one. "
            + "One gate, one bar item: the host exists only to carry it."
        )
        XCTAssertTrue(
            gated.contains("Color.clear") && gated.contains("frame(width: 0, height: 0)"),
            "The host is no longer a zero-size `Color.clear`. It is a position in the view tree, "
            + "not a view anyone sees; anything with a size lays out over the thread it is stacked "
            + "on."
        )
        XCTAssertTrue(
            gated.contains("WorkbenchSectionToolbarItem(model: model)"),
            "The gated arm no longer declares `WorkbenchSectionToolbarItem(model: model)`. The "
            + "shared item is what keeps the iPad's two bars and the Mac's window drawing the same "
            + "control."
        )

        XCTAssertEqual(
            occurrences(of: "WorkbenchSectionToolbarItem(", in: source), 1,
            "This file invokes `WorkbenchSectionToolbarItem` a number of times other than once. A "
            + "second invocation ships two Chats | Work capsules in one bar."
        )
    }
}
