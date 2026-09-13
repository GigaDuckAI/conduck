// SPDX-License-Identifier: Apache-2.0

// Conduck
// ChatsProjectThreadHostDriftGuardTests.swift
//
// Structural guard for the three Chats hosts that show a project thread —
// the phone shell, the iPad library, the Mac window — and the Work route they
// call. What a view wiring test can pin cheaply: every host keeps ONE project
// context current, feeds the thread's `allowsNewAttempts` from it, gates its
// send entry point on it, and draws the header line; the Mac keeps its
// composer mounted under the lock (staged attachments live in that view);
// the route loads before it selects, in the order that survives the
// workspace's own reconcile, and never introduces the tour.

import XCTest
@testable import Conduck

final class ChatsProjectThreadHostDriftGuardTests: XCTestCase {
    private static let phone = "Conduck/ContentView.swift"
    private static let library = "Conduck/Views/Conversation/ConversationLibraryView.swift"
    private static let window = "Conduck/Views/Conversation/MainWindowView.swift"
    private static let workbench = "Conduck/Views/Workboard/PersonalWorkbenchView.swift"

    func testEveryHostDrawsTheHeaderAndFeedsTheThreadFromOneContext() throws {
        for path in [Self.phone, Self.library, Self.window] {
            let source = try RefusalLaneSource.source(at: path)
            XCTAssertTrue(source.contains("ConversationProjectHeaderLine("), "\(path) draws no project header")
            XCTAssertTrue(source.contains("allowsNewAttempts: projectContext.allowsNewTurns("),
                          "\(path) mounts a thread whose Retry chips ignore the project lock")
        }
        // ONE context per shell: the phone mints it and the library borrows it.
        let phone = try RefusalLaneSource.source(at: Self.phone)
        let library = try RefusalLaneSource.source(at: Self.library)
        let window = try RefusalLaneSource.source(at: Self.window)
        XCTAssertTrue(phone.contains("@State private var projectContext = ConversationProjectContext()"))
        XCTAssertTrue(window.contains("@State private var projectContext = ConversationProjectContext()"))
        XCTAssertFalse(library.contains("ConversationProjectContext()"), "the iPad library must borrow the shell's context, not mint a second one")
        XCTAssertTrue(library.contains("let projectContext: ConversationProjectContext"))
        XCTAssertTrue(phone.contains("projectContext: projectContext,"), "the phone shell hands its context to the library")
        XCTAssertTrue(phone.contains(".projectContextRefresh(projectContext"))
        XCTAssertTrue(window.contains(".projectContextRefresh("))
    }

    func testEverySendEntryPointRefusesARefusedProjectThread() throws {
        let phone = try RefusalLaneSource.source(at: Self.phone)
        let sendTurn = try RefusalLaneSource.body(ofFunction: "sendTurn", in: phone, path: Self.phone)
        let phoneGate = try XCTUnwrap(sendTurn.range(of: "projectContext.refusal(for: target)"))
        let ownership = try XCTUnwrap(sendTurn.range(of: "ComposerDispatchOwnership.matches("))
        XCTAssertLessThan(phoneGate.lowerBound, ownership.lowerBound, "the project refuses before any mint or upload")

        let library = try RefusalLaneSource.source(at: Self.library)
        let draft = try RefusalLaneSource.body(ofFunction: "sendCurrentDraft", in: library, path: Self.library)
        XCTAssertTrue(draft.contains("projectContext.refusal(for: selectedConversationID)"),
                      "⌘Return is not a way around the locked bar")

        let window = try RefusalLaneSource.source(at: Self.window)
        let typed = try RefusalLaneSource.body(ofFunction: "sendTypedText", in: window, path: Self.window)
        XCTAssertTrue(typed.contains("projectContext.refusal(for: target)"))
        XCTAssertTrue(typed.contains("setSendNotice(ProjectActivityRefusalCopy(refusal).sentence)"))
    }

    func testTheMacKeepsItsComposerMountedUnderTheLock() throws {
        let window = try RefusalLaneSource.source(at: Self.window)
        let activeChat = try RefusalLaneSource.body(ofFunction: "activeChat", in: window, path: Self.window)
        let notice = try XCTUnwrap(activeChat.range(of: "ProjectActivityLockNotice("))
        let composer = try XCTUnwrap(activeChat.range(of: "MessageComposerBar("))
        XCTAssertLessThan(notice.lowerBound, composer.lowerBound, "the notice sits above the composer")
        XCTAssertFalse(activeChat.contains("LockedComposerBar"),
                       "swapping the Mac composer out would tear down its staged attachments")
    }

    func testTheRouteLoadsBeforeItSelectsAndNeverIntroducesTheTour() throws {
        let source = try RefusalLaneSource.source(at: Self.workbench)
        let reveal = try RefusalLaneSource.trailingClosure(after: "router.showConversationInWork =", in: source, path: Self.workbench)
        var cursor = reveal.startIndex
        // `stillWanted()` folds the reveal token AND the person's own navigation
        // inside Work (scope / selected thread unchanged since the reveal began).
        for step in ["beginWorkReveal()", "prepareForFirstPresentation()", "guard stillWanted()", "organization.reload()",
                     "reloadProjectActivity()", "guard stillWanted()", "organization.project(id: projectID) != nil",
                     "selectConversation(conversationID, projectID: projectID)"] {
            let found = try XCTUnwrap(reveal.range(of: step, options: [], range: cursor..<reveal.endIndex),
                                      "`\(step)` is missing or out of order in the reveal")
            cursor = found.upperBound
        }
        XCTAssertFalse(reveal.contains("selectDestination("), "a route sets the destination directly; only the section control introduces the tour")
        XCTAssertTrue(reveal.contains("fetchConversation(id: conversationID)"),
                      "the thread's project must come from the store when the workspace list has not published yet")
        XCTAssertTrue(reveal.contains(".showWorkboard"), "the Mac opens no window from a router poke alone")

        let refusal = try RefusalLaneSource.trailingClosure(after: "router.showWorkForRefusal =", in: source, path: Self.workbench)
        XCTAssertTrue(refusal.contains("guard stillWanted()"), "the refusal route yields to navigation the same way")
        XCTAssertTrue(refusal.contains("selectScope(.project(projectID))"))
        XCTAssertTrue(refusal.contains("projectSelectionRequested = true"))
        XCTAssertFalse(refusal.contains("selectConversation("), "a refusal route reveals the place to fix it, not a thread")
    }

    @MainActor
    func testARevealTokenIsRetiredByALaterRevealOrByLeavingWork() {
        let router = PersonalWorkbenchRouter()
        let first = router.beginWorkReveal()
        XCTAssertEqual(router.destination, .work)
        XCTAssertTrue(router.workRevealIsCurrent(first))
        let second = router.beginWorkReveal()
        XCTAssertFalse(router.workRevealIsCurrent(first))
        XCTAssertTrue(router.workRevealIsCurrent(second))
        router.destination = .chats
        XCTAssertFalse(router.workRevealIsCurrent(second), "leaving Work retires a reveal still loading")
        XCTAssertFalse(router.canShowInWork, "a shell without a desk draws no dead control")
    }
}
