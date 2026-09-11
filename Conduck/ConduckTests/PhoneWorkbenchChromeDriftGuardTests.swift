// SPDX-License-Identifier: Apache-2.0
// Conduck
// PhoneWorkbenchChromeDriftGuardTests.swift
//
// Source guards for the compact conversation bar. Conversations still opens a
// sheet and New Chat still starts a fresh conversation, with stable spoken and
// QA identities. Only iPhone moves New Chat beside Conversations; compact iPad
// keeps it trailing. The phone section trigger is the last content sibling so
// a populated thread's Copy action cannot push it away from the right edge.

import XCTest

final class PhoneWorkbenchChromeDriftGuardTests: XCTestCase {

    private static let path = "Conduck/ContentView.swift"

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private func topLevel(of closure: String) -> String {
        var result = ""
        var depth = 0
        for character in closure {
            if character == "{" { depth += 1; continue }
            if character == "}" { depth = max(0, depth - 1); continue }
            if depth == 0 { result.append(character) }
        }
        return result
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

    func testCompactChatToolbarContributesNoActionsWhileWorkIsActive() throws {
        let toolbar = try phoneToolbar()
        let active = try RefusalLaneSource.trailingClosure(
            after: "if workbenchDestinationIsActive", in: toolbar, path: Self.path
        )
        XCTAssertTrue(active.contains("toolbar.conversations"))
        XCTAssertTrue(active.contains("toolbar.newConversation"))
        XCTAssertFalse(topLevel(of: toolbar).contains("ToolbarItem"),
                       "Every compact Chat item must sit inside the active-destination branch")
    }

    /// One button in the leading slot opens the list, looks like the sidebar
    /// toggle, and keeps both of its accessibility names.
    func testConversationsButtonRetainsItsSheetActionAndAccessibilityIdentity() throws {
        let toolbar = try phoneToolbar()

        XCTAssertEqual(
            occurrences(of: "ToolbarItem(placement: .topBarLeading)", in: toolbar), 1,
            "Conversations must keep its unconditional leading slot; New Chat chooses its slot by platform."
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
            action.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t}"))
                .split(whereSeparator: \.isWhitespace).joined(separator: " "),
            "guard workbenchDestinationIsActive else { return } phoneWorkbenchRouter?.dismissPhoneSection(for: .chats) showingList = true",
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

    /// New Chat joins Conversations only when the phone navigation is present.
    func testNewConversationMovesLeadingOnlyOnPhoneAndRetainsItsAction() throws {
        let toolbar = try phoneToolbar()

        let placement = "ToolbarItem(placement: phoneWorkbenchRouter == nil ? .topBarTrailing : .topBarLeading)"
        XCTAssertEqual(
            occurrences(of: placement, in: toolbar), 1,
            "New Chat must be leading on iPhone and retain its trailing slot on compact iPad."
        )

        let newChat = try RefusalLaneSource.trailingClosure(
            after: placement,
            in: toolbar,
            path: Self.path
        )

        XCTAssertEqual(
            occurrences(of: "Button", in: newChat), 1,
            "The New Chat toolbar item no longer holds exactly one `Button`, so its action, glyph "
            + "and names can no longer be read as belonging to one control."
        )

        let action = try RefusalLaneSource.trailingClosure(
            after: "Button",
            in: newChat,
            path: Self.path
        )
        XCTAssertEqual(
            action.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t}"))
                .split(whereSeparator: \.isWhitespace).joined(separator: " "),
            "guard workbenchDestinationIsActive else { return } phoneWorkbenchRouter?.dismissPhoneSection(for: .chats) startNewConversation()",
            "The New Chat button no longer calls `startNewConversation()`. That call is the phone's "
            + "whole compose path — it clears the selection so the next turn mints a fresh thread."
        )

        let label = try RefusalLaneSource.trailingClosure(
            after: "} label:",
            in: newChat,
            path: Self.path
        )
        XCTAssertTrue(
            label.contains("Image(systemName: \"square.and.pencil\")"),
            "The New conversation button no longer draws `square.and.pencil`, the compose glyph the "
            + "iPad and Mac bars use for the same action."
        )

        XCTAssertTrue(
            newChat.contains(".accessibilityLabel(\"New conversation\")"),
            "The New conversation button must retain its spoken identity after changing placement."
        )
        XCTAssertTrue(
            newChat.contains(".accessibilityIdentifier(\"toolbar.newConversation\")"),
            "The New conversation button lost its `toolbar.newConversation` identifier — the "
            + "non-localized handle every UI probe uses to start a thread on the phone."
        )
    }

    func testPhoneSectionHostIsLastAndOnlyContributesToActiveChats() throws {
        let source = try RefusalLaneSource.source(at: Self.path)
        let phone = try RefusalLaneSource.trailingClosure(
            after: "private var phoneLayout: some View", in: source, path: Self.path
        )
        let navigation = try RefusalLaneSource.trailingClosure(
            after: "NavigationStack", in: phone, path: Self.path
        )
        let stack = try RefusalLaneSource.trailingClosure(
            after: "ZStack", in: navigation, path: Self.path
        )
        XCTAssertEqual(occurrences(of: "phoneSectionControlHost", in: stack), 1)
        let siblings = topLevel(of: stack)
        XCTAssertEqual(
            occurrences(of: "phoneSectionControlHost", in: siblings), 1,
            "The phone section host must be a direct sibling, after the subtree containing the thread."
        )
        let hostRange = try XCTUnwrap(stack.range(of: "phoneSectionControlHost"))
        let threadRange = try XCTUnwrap(stack.range(of: "threadContent"))
        XCTAssertLessThan(threadRange.lowerBound, hostRange.lowerBound)
        XCTAssertEqual(
            stack[hostRange.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " \n\t}")),
            "#endif",
            "The section host must be the final sibling after the thread's conditional Copy toolbar item."
        )

        let host = try RefusalLaneSource.trailingClosure(
            after: "private var phoneSectionControlHost: some View", in: source, path: Self.path
        )
        let active = try RefusalLaneSource.trailingClosure(
            after: "if let router = phoneWorkbenchRouter, router.destination == .chats",
            in: host, path: Self.path
        )
        XCTAssertEqual(occurrences(of: "PhoneWorkbenchSectionButton(", in: host), 1)
        XCTAssertTrue(active.contains("ToolbarItem(placement: .primaryAction)"))
        XCTAssertTrue(active.contains("PhoneWorkbenchSectionButton(router: router, destination: .chats)"))
        XCTAssertTrue(
            navigation.contains("PhoneWorkbenchSectionOverlay(router: router, destination: .chats)"),
            "The button must have a dropdown in the conversation root, including above the composer."
        )
    }

    func testCopyConversationDismissesThePhoneMenuBeforeCopying() throws {
        let path = "Conduck/Views/Conversation/ConversationThreadView.swift"
        let source = try RefusalLaneSource.source(at: path)
        let action = try RefusalLaneSource.trailingClosure(
            after: "private func copyAllTapped()", in: source, path: path
        )
        let dismissal = "phoneWorkbenchRouter?.dismissPhoneSection(for: .chats)"
        let dismissalAt = try XCTUnwrap(action.range(of: dismissal)?.lowerBound)
        let copyAt = try XCTUnwrap(action.range(of: "viewModel.copyEntireConversation()")?.lowerBound)
        XCTAssertLessThan(dismissalAt, copyAt, "Copy is outside the dropdown and must close it before acting.")
        let conditions = try XCTUnwrap(WorkboardSourceDirectives.enclosingConditions(of: dismissal, in: action))
        XCTAssertEqual(WorkboardSourceDirectives.ownership(of: conditions), .exclusive(.iOS))
    }
}
