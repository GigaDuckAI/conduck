// SPDX-License-Identifier: Apache-2.0
// Conduck
// PhoneWorkbenchChromeDriftGuardTests.swift
//
// SOURCE DRIFT GUARD over the iPhone chat bar in `ContentView.phoneLayout`:
// the leading Conversations button and the trailing New conversation button.
//
// The leading button carries a `sidebar.leading` glyph for family resemblance
// with the system sidebar toggle the iPad split view and the macOS window both
// pin leading-most — one app, one leading affordance across three shells. It is
// a RESEMBLANCE and not the same control: the phone has no second column, so
// this button presents the conversation list as a sheet. That gap between what
// the glyph looks like and what the button does is exactly what a later edit
// gets wrong, and each of the four facts it can get wrong is silent:
//
//   • the SHEET ACTION (`showingList = true`) — swap it for a sidebar toggle
//     the phone does not have and the button compiles and does nothing.
//   • the SPOKEN IDENTITY (`.accessibilityLabel("Conversations")`) — a label
//     renamed after the glyph announces "sidebar" for a control that opens a
//     list, which is the one description VoiceOver users get.
//   • the QA TARGET (`.accessibilityIdentifier("toolbar.conversations")`) —
//     non-localized on purpose; renaming it silently unhooks every UI probe
//     that reaches this button.
//   • PLACEMENT — Conversations leading, New conversation trailing. The two
//     swap without a compiler complaint.
//
// Asserting a glyph or an identifier anywhere in a 1,500-line file proves none
// of this: what matters is that ONE button in the leading slot combines all
// four. So every assertion is scoped to the single `ToolbarItem` it is about,
// over the file's text with comments stripped (`RefusalLaneSource`). A guard
// that fails because the chrome legitimately changed is a guard to update, not
// a bug to route around.

import XCTest

final class PhoneWorkbenchChromeDriftGuardTests: XCTestCase {

    private static let path = "Conduck/ContentView.swift"

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// The phone bar's toolbar closure — the one bar the compact shell declares.
    private func phoneToolbar() throws -> String {
        let source = try RefusalLaneSource.source(at: Self.path)
        let phone = try RefusalLaneSource.trailingClosure(
            after: "private var phoneLayout: some View",
            in: source,
            path: Self.path
        )
        let navigation = try RefusalLaneSource.trailingClosure(
            after: "NavigationStack",
            in: phone,
            path: Self.path
        )
        return try RefusalLaneSource.trailingClosure(
            after: ".toolbar",
            in: navigation,
            path: Self.path
        )
    }

    /// One button in the leading slot opens the list, looks like the sidebar
    /// toggle, and keeps both of its accessibility names.
    func testConversationsButtonRetainsItsSheetActionAndAccessibilityIdentity() throws {
        let toolbar = try phoneToolbar()

        XCTAssertEqual(
            occurrences(of: "ToolbarItem(placement: .topBarLeading)", in: toolbar), 1,
            "The phone bar declares a number of `.topBarLeading` items other than one. Conversations "
            + "is the phone's single leading affordance; a second item beside it is a leading edge "
            + "that no longer reads as the iPad's and the Mac's."
        )

        let leading = try RefusalLaneSource.trailingClosure(
            after: "ToolbarItem(placement: .topBarLeading)",
            in: toolbar,
            path: Self.path
        )

        XCTAssertEqual(
            occurrences(of: "Button", in: leading), 1,
            "The leading toolbar item no longer holds exactly one `Button`. This guard's point is "
            + "that ONE button carries the action, the glyph and both names; several buttons here "
            + "let those four facts drift apart while every individual assertion still passes."
        )

        let action = try RefusalLaneSource.trailingClosure(
            after: "Button",
            in: leading,
            path: Self.path
        )
        XCTAssertEqual(
            action.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t}")), "showingList = true",
            "The Conversations button no longer presents the conversation list. The phone has no "
            + "second column to reveal, so the sheet IS the destination — a button that toggles "
            + "anything else here compiles and leaves the user with no way to reach their threads."
        )

        let label = try RefusalLaneSource.trailingClosure(
            after: "} label:",
            in: leading,
            path: Self.path
        )
        XCTAssertTrue(
            label.contains("Image(systemName: \"sidebar.leading\")"),
            "The Conversations button no longer draws `sidebar.leading`. That glyph is what makes "
            + "the phone's leading affordance read as the same thing as the sidebar toggle the iPad "
            + "split view and the macOS window pin leading-most in their own bars."
        )

        XCTAssertTrue(
            leading.contains(".accessibilityLabel(\"Conversations\")"),
            "The Conversations button's spoken name changed. The label describes what the button "
            + "OPENS, not the glyph it borrows: a phone button announced as a sidebar toggle "
            + "promises a column this shell does not have."
        )
        XCTAssertTrue(
            leading.contains(".accessibilityIdentifier(\"toolbar.conversations\")"),
            "The Conversations button lost its `toolbar.conversations` identifier. It is "
            + "non-localized precisely so QA can address this button in any language; renaming it "
            + "unhooks every probe that reaches it, silently and without a build failure."
        )
    }

    /// New conversation stays the phone bar's one trailing action.
    func testNewConversationRemainsTrailing() throws {
        let toolbar = try phoneToolbar()

        XCTAssertEqual(
            occurrences(of: "ToolbarItem(placement: .topBarTrailing)", in: toolbar), 1,
            "The phone bar declares a number of `.topBarTrailing` items other than one. Settings "
            + "lives in the conversation-list footer and Clone is folded into the centered gateway "
            + "title, so New conversation is the trailing edge's sole action."
        )

        let trailing = try RefusalLaneSource.trailingClosure(
            after: "ToolbarItem(placement: .topBarTrailing)",
            in: toolbar,
            path: Self.path
        )

        XCTAssertEqual(
            occurrences(of: "Button", in: trailing), 1,
            "The trailing toolbar item no longer holds exactly one `Button`, so its action, glyph "
            + "and names can no longer be read as belonging to one control."
        )

        let action = try RefusalLaneSource.trailingClosure(
            after: "Button",
            in: trailing,
            path: Self.path
        )
        XCTAssertEqual(
            action.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t}")), "startNewConversation()",
            "The trailing button no longer calls `startNewConversation()`. That call is the phone's "
            + "whole compose path — it clears the selection so the next turn mints a fresh thread."
        )

        let label = try RefusalLaneSource.trailingClosure(
            after: "} label:",
            in: trailing,
            path: Self.path
        )
        XCTAssertTrue(
            label.contains("Image(systemName: \"square.and.pencil\")"),
            "The New conversation button no longer draws `square.and.pencil`, the compose glyph the "
            + "iPad and Mac bars use for the same action."
        )

        XCTAssertTrue(
            trailing.contains(".accessibilityLabel(\"New conversation\")"),
            "The New conversation button's spoken name changed, so the one action on the phone's "
            + "trailing edge announces itself as something else."
        )
        XCTAssertTrue(
            trailing.contains(".accessibilityIdentifier(\"toolbar.newConversation\")"),
            "The New conversation button lost its `toolbar.newConversation` identifier — the "
            + "non-localized handle every UI probe uses to start a thread on the phone."
        )
    }
}
