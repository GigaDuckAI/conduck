// SPDX-License-Identifier: Apache-2.0
// Conduck
// PhoneWorkbenchChromeDriftGuardTests.swift
//
// Source guards for the compact conversation bar. One leading button opens
// the Conversations sheet; the trailing edge holds the iPhone's Open Work
// flip button and then New conversation, in that order, so the compose glyph
// stays trailing-most on every compact shell and the bar keeps exactly one
// dropdown — the gateway title. The thread's Copy item never joins this bar:
// on the phone the whole-thread copy rides in each bubble's actions menu.

import XCTest

final class PhoneWorkbenchChromeDriftGuardTests: XCTestCase {

    private static let path = "Conduck/ContentView.swift"
    private static let threadPath = "Conduck/Views/Conversation/ConversationThreadView.swift"
    private static let menuPath = "Conduck/Views/Conversation/MessageActionButton.swift"
    private static let controlPath = "Conduck/Views/Workboard/PhoneWorkbenchSectionControl.swift"

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

    private func normalized(_ action: String) -> String {
        action.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t}"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
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
        XCTAssertTrue(active.contains("PhoneWorkbenchFlipButton("))
        XCTAssertFalse(topLevel(of: toolbar).contains("ToolbarItem"),
                       "Every compact Chat item must sit inside the active-destination branch")
    }

    /// One button in the leading slot opens the list, looks like the sidebar
    /// toggle, and keeps both of its accessibility names.
    func testConversationsButtonIsTheOnlyLeadingItemAndKeepsItsIdentity() throws {
        let toolbar = try phoneToolbar()

        XCTAssertEqual(
            occurrences(of: "ToolbarItem(placement: .topBarLeading)", in: toolbar), 1,
            "The leading slot holds exactly one item. A second leading button re-crowds the bar "
            + "this layout exists to relieve; New conversation is trailing on every compact shell."
        )
        XCTAssertFalse(
            toolbar.contains("? .topBarTrailing : .topBarLeading"),
            "New conversation no longer chooses its slot by shell — it is trailing everywhere."
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
            normalized(action),
            "guard workbenchDestinationIsActive else { return } showingList = true",
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

    /// Open Work is phone-only and declared before New conversation, so the
    /// compose glyph is trailing-most and the flip sits to its left.
    func testOpenWorkFlipIsPhoneOnlyAndSitsLeftOfNewConversation() throws {
        let toolbar = try phoneToolbar()
        let source = try RefusalLaneSource.source(at: Self.path)

        XCTAssertEqual(
            occurrences(of: "ToolbarItem(placement: .topBarTrailing)", in: toolbar), 2,
            "The trailing edge holds exactly two items: Open Work (phone only) and New conversation."
        )
        XCTAssertEqual(occurrences(of: "PhoneWorkbenchFlipButton(", in: toolbar), 1)

        let phone = try RefusalLaneSource.trailingClosure(
            after: "if let router = phoneWorkbenchRouter", in: toolbar, path: Self.path
        )
        XCTAssertTrue(
            phone.contains("ToolbarItem(placement: .topBarTrailing)"),
            "Open Work must be a trailing item of THIS bar — no zero-size host, no `.primaryAction`."
        )
        XCTAssertTrue(
            phone.contains("PhoneWorkbenchFlipButton(router: router, from: .chats)"),
            "The Chats bar's flip button must name Chats as the surface it belongs to; the button "
            + "opens the OTHER section, so a wrong `from:` sends the person to where they already are."
        )

        let flipAt = try XCTUnwrap(toolbar.range(of: "PhoneWorkbenchFlipButton(")?.lowerBound)
        let newChatAt = try XCTUnwrap(toolbar.range(of: "toolbar.newConversation")?.lowerBound)
        XCTAssertLessThan(
            flipAt, newChatAt,
            "Open Work must be declared before New conversation: trailing items lay out in "
            + "declaration order, and the compose glyph belongs at the very edge on every compact shell."
        )

        for retired in [
            "phoneSectionControlHost", "PhoneWorkbenchSectionOverlay",
            "PhoneWorkbenchSectionButton", "dismissPhoneSection",
        ] {
            XCTAssertFalse(
                source.contains(retired),
                "`\(retired)` is back in ContentView. The expandable section menu was retired with "
                + "the flip button; a second section control on the phone re-crowds the bar."
            )
        }
    }

    func testNewConversationIsTrailingAndRetainsItsAction() throws {
        let toolbar = try phoneToolbar()
        let afterFlip = try XCTUnwrap(toolbar.range(of: "PhoneWorkbenchFlipButton(")).upperBound
        let tail = String(toolbar[afterFlip...])
        let newChat = try RefusalLaneSource.trailingClosure(
            after: "ToolbarItem(placement: .topBarTrailing)",
            in: tail,
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
            normalized(action),
            "guard workbenchDestinationIsActive else { return } startNewConversation()",
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

    /// The flip button opens the OTHER section, says so, and routes through
    /// the one router path that arms the Work first-visit tour.
    func testFlipButtonHasDestinationSemanticsAndRoutesThroughSelectDestination() throws {
        let source = try RefusalLaneSource.source(at: Self.controlPath)
        let button = try RefusalLaneSource.trailingClosure(
            after: "struct PhoneWorkbenchFlipButton: View", in: source, path: Self.controlPath
        )

        XCTAssertTrue(
            button.contains("router.selectDestination(target)"),
            "The flip must route through `selectDestination`. It is the only path that arms the "
            + "Work first-visit tour; a bare assignment is what deep links use to skip it."
        )
        XCTAssertFalse(
            button.contains("destination = "),
            "The flip button assigns the destination directly, bypassing the tour."
        )
        XCTAssertTrue(
            button.contains("guard router.destination == from else { return }"),
            "A stale button from the departing surface must route nothing on the new one's behalf."
        )
        XCTAssertTrue(
            button.contains("KeyboardDismissal.dismissKeyboard()"),
            "The keyboard must be resigned before the surface changes underneath it."
        )
        XCTAssertTrue(button.contains("\"tray.full\""))
        XCTAssertTrue(button.contains("\"bubble.left.and.bubble.right\""))
        XCTAssertTrue(button.contains("\"workbench.phone.openWork\""))
        XCTAssertTrue(button.contains("\"workbench.phone.openChats\""))
        XCTAssertTrue(button.contains("defaultValue: \"Open Work\""))
        XCTAssertTrue(button.contains("defaultValue: \"Open Chats\""))

        let label = try RefusalLaneSource.trailingClosure(
            after: "} label:", in: button, path: Self.controlPath
        )
        XCTAssertTrue(label.contains("Image(systemName:"))
        XCTAssertFalse(
            label.contains("Text(") || label.contains("chevron"),
            "The flip is icon-only. A text label or chevron beside the gateway title puts two "
            + "dropdowns on the bar — the exact crowding this control replaced."
        )

        for retired in ["PhoneWorkbenchSectionOverlay", "PhoneWorkbenchSectionButton", "phoneSectionTitle"] {
            XCTAssertFalse(source.contains(retired), "`\(retired)` was retired with the section menu.")
        }
    }

    /// Copy conversation stays off the phone bar and rides in the bubble menu.
    func testCopyConversationStaysOffThePhoneBarAndRidesInTheBubbleMenu() throws {
        let thread = try RefusalLaneSource.source(at: Self.threadPath)

        XCTAssertTrue(
            thread.contains("if workbenchDestinationIsActive, showsCopyToolbarItem, !viewModel.messages.isEmpty {"),
            "The thread's Copy toolbar item must be gated on `showsCopyToolbarItem`, which is what "
            + "keeps a fifth control off the phone bar."
        )

        let gate = try RefusalLaneSource.trailingClosure(
            after: "private var showsCopyToolbarItem: Bool", in: thread, path: Self.threadPath
        )
        let phoneArm = "return phoneWorkbenchRouter == nil"
        XCTAssertTrue(gate.contains(phoneArm), "On iOS the Copy item shows only where no phone router exists.")
        XCTAssertTrue(gate.contains("return true"), "iPad's detail bar and the Mac window keep the Copy item.")
        let conditions = try XCTUnwrap(WorkboardSourceDirectives.enclosingConditions(of: phoneArm, in: gate))
        XCTAssertEqual(WorkboardSourceDirectives.ownership(of: conditions), .exclusive(.iOS))

        let copyAll = try RefusalLaneSource.trailingClosure(
            after: "private func copyAllTapped()", in: thread, path: Self.threadPath
        )
        XCTAssertTrue(copyAll.contains("viewModel.copyEntireConversation()"))
        XCTAssertFalse(copyAll.contains("phoneWorkbenchRouter"), "There is no phone menu left to dismiss.")

        XCTAssertTrue(
            thread.contains("onCopyConversation: bubbleCopyConversation,"),
            "Each bubble must receive the thread-level copy through the one typed property."
        )
        let bubbleCopy = try RefusalLaneSource.trailingClosure(
            after: "private var bubbleCopyConversation: (() -> Void)?", in: thread, path: Self.threadPath
        )
        XCTAssertTrue(
            bubbleCopy.contains("showsCopyToolbarItem ? nil : { copyAllTapped() }"),
            "Each bubble offers the whole-thread copy exactly where the bar does not — and nowhere else."
        )

        // The bubble must hand its menu the thread-level action AND acknowledge
        // it like a per-message copy; a `nil` here would silently remove the
        // phone's only whole-conversation copy without failing any other guard.
        XCTAssertTrue(
            thread.contains("onCopyConversation: menuCopyConversation"),
            "MessageBubble no longer forwards the thread-level copy to its actions menu."
        )
        let menuCopy = try RefusalLaneSource.trailingClosure(
            after: "private var menuCopyConversation: (() -> Void)?", in: thread, path: Self.threadPath
        )
        XCTAssertTrue(menuCopy.contains("guard let onCopyConversation else { return nil }"))
        XCTAssertTrue(menuCopy.contains("onCopyConversation()"), "The menu row must invoke the host's copy.")
        XCTAssertTrue(menuCopy.contains("acknowledgeCopy()"), "The menu row must flash the same checkmark.")

        let menu = try RefusalLaneSource.source(at: Self.menuPath)
        XCTAssertTrue(menu.contains("var onCopyConversation: (() -> Void)? = nil"))
        let row = try RefusalLaneSource.trailingClosure(
            after: "if let onCopyConversation", in: menu, path: Self.menuPath
        )
        XCTAssertTrue(row.contains("Divider()"), "The thread-level row is separated from the per-message rows.")
        XCTAssertTrue(row.contains("\"thread.copyAll.button\""))
        XCTAssertFalse(
            row.contains("\"doc.on.doc\""),
            "Copy conversation must not share Copy message's glyph — two look-alike copy rows read as one action twice."
        )
    }
}
