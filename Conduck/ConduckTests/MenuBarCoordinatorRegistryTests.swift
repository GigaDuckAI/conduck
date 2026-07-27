// SPDX-License-Identifier: Apache-2.0

// Conduck
// MenuBarCoordinatorRegistryTests.swift
//
// The VM registry's identity + retention contract (the popover/window lane
// split, session-continuation redesign):
//   - `viewModel(for:)` is reuse-or-mint: the SAME instance per conversation
//     id. Identity is the whole point — a re-mint would double-observe
//     `.conversationsDidChange`, render a dead spinner, and open a
//     double-send window while the old in-flight `Task` still runs.
//   - The two lanes (`quickViewModel` / `windowViewModel`) bound to the same
//     id share that ONE instance (one spinner, one in-flight guard).
//   - The sweep drops orphans (no lane references them, not mid-turn) but
//     RETAINS lane-referenced and `isAwaitingReply` VMs.
//
// Store-light: conversation ids are bare minted UUIDs — `viewModel(for:)`
// never validates them against the store, and the VM's background `reload()`
// simply finds no messages (same construction as
// `ConversationDetailViewModelMacReplyArrivedTests`). Unsigned-safe: nothing
// here awaits a Keychain-backed path; the coordinator's launch tasks run in
// the background and are irrelevant to the synchronous registry behavior
// under test. `@MainActor` because the coordinator requires it.

#if os(macOS)

import XCTest
@testable import Conduck

@MainActor
final class MenuBarCoordinatorRegistryTests: XCTestCase {

    // MARK: - Reuse-or-mint identity

    func testViewModelForIDReturnsSameInstance() {
        let coordinator = MenuBarCoordinator()
        let id = UUID()
        let first = coordinator.viewModel(for: id)
        let second = coordinator.viewModel(for: id)
        XCTAssertTrue(first === second,
                      "Same id must reattach the SAME VM instance (a re-mint loses the in-flight state machine).")
    }

    func testDifferentIDsGetDifferentInstances() {
        let coordinator = MenuBarCoordinator()
        let a = coordinator.viewModel(for: UUID())
        let b = coordinator.viewModel(for: UUID())
        XCTAssertFalse(a === b)
    }

    // MARK: - Reply-arrived unread dot

    func testNoteReplyArrivedMarksThreadUnreadWhenNotVisibleInPopover() {
        let coordinator = MenuBarCoordinator()
        let id = UUID()
        XCTAssertFalse(coordinator.hasUnreadReply)
        coordinator.noteReplyArrived(id)
        XCTAssertTrue(coordinator.hasUnreadReply)
        XCTAssertTrue(coordinator.unreadReplyConversationIDs.contains(id))
    }

    func testNoteReplyArrivedSkipsThreadCurrentlyVisibleInPopover() {
        let coordinator = MenuBarCoordinator()
        let id = UUID()
        coordinator.setPopoverVisibleConversation(id)   // popover is showing it
        coordinator.noteReplyArrived(id)
        XCTAssertFalse(coordinator.hasUnreadReply,
                       "A reply for the thread the popover is showing must NOT raise the dot — the user sees it.")
    }

    func testClearUnreadRemovesTheMark() {
        let coordinator = MenuBarCoordinator()
        let id = UUID()
        coordinator.noteReplyArrived(id)
        XCTAssertTrue(coordinator.hasUnreadReply)
        coordinator.clearUnread(id)
        XCTAssertFalse(coordinator.hasUnreadReply)
    }

    func testSetPopoverVisibleConversationClearsThatThreadsUnread() {
        let coordinator = MenuBarCoordinator()
        let id = UUID()
        coordinator.noteReplyArrived(id)         // marked while popover closed
        XCTAssertTrue(coordinator.hasUnreadReply)
        coordinator.setPopoverVisibleConversation(id)   // user opens onto it
        XCTAssertFalse(coordinator.hasUnreadReply,
                       "Opening the popover onto a thread clears its unread dot.")
    }

    func testOpenConversationClearsUnread() {
        let coordinator = MenuBarCoordinator()
        let id = UUID()
        coordinator.noteReplyArrived(id)
        coordinator.openConversation(id)         // window navigates to it
        XCTAssertFalse(coordinator.unreadReplyConversationIDs.contains(id))
    }

    func testMultipleUnreadThreadsCoalesceToOneDot() {
        let coordinator = MenuBarCoordinator()
        coordinator.noteReplyArrived(UUID())
        coordinator.noteReplyArrived(UUID())
        XCTAssertEqual(coordinator.unreadReplyConversationIDs.count, 2)
        XCTAssertTrue(coordinator.hasUnreadReply,
                      "Any non-empty unread set shows ONE dot (count is not surfaced).")
    }

    // MARK: - Window-visible pin (active main window showing the thread)

    func testNoteReplyArrivedSkipsThreadCurrentlyVisibleInActiveWindow() {
        let coordinator = MenuBarCoordinator()
        let id = UUID()
        coordinator.setWindowVisibleConversation(id)   // active window shows it
        coordinator.noteReplyArrived(id)
        XCTAssertFalse(coordinator.hasUnreadReply,
                       "A reply for the thread the ACTIVE window is showing must NOT raise the dot — the user is watching it land.")
    }

    func testNoteReplyArrivedMarksOtherThreadWhileWindowShowsOne() {
        let coordinator = MenuBarCoordinator()
        let visible = UUID(); let other = UUID()
        coordinator.setWindowVisibleConversation(visible)
        coordinator.noteReplyArrived(other)
        XCTAssertTrue(coordinator.unreadReplyConversationIDs.contains(other),
                      "The window pin suppresses only ITS thread — a reply elsewhere still raises the dot.")
    }

    func testNoteFailureSkipsThreadCurrentlyVisibleInActiveWindow() {
        let coordinator = MenuBarCoordinator()
        let id = UUID()
        coordinator.setWindowVisibleConversation(id)
        coordinator.noteFailure(id)
        XCTAssertFalse(coordinator.hasFailure,
                       "A failure for the visible thread shows its inline failed bubble — no red dot.")
    }

    func testSetWindowVisibleConversationClearsExistingMarks() {
        let coordinator = MenuBarCoordinator()
        let id = UUID()
        coordinator.noteReplyArrived(id)     // raised while the user was away
        coordinator.noteFailure(id)
        coordinator.setWindowVisibleConversation(id)   // cmd-tab back onto it
        XCTAssertFalse(coordinator.hasUnreadReply,
                       "Re-activating the window on the reply's thread clears its unread dot.")
        XCTAssertFalse(coordinator.hasFailure,
                       "…and its failure dot (clear-site parity).")
    }

    func testWindowDeactivationLetsRepliesRaiseTheDotAgain() {
        let coordinator = MenuBarCoordinator()
        let id = UUID()
        coordinator.setWindowVisibleConversation(id)
        coordinator.setWindowVisibleConversation(nil)   // app resigned active
        coordinator.noteReplyArrived(id)
        XCTAssertTrue(coordinator.hasUnreadReply,
                      "With the window inactive the thread is no longer 'being watched' — the dot must raise.")
    }

    func testClearWindowVisibleIfCurrentIgnoresStaleThread() {
        let coordinator = MenuBarCoordinator()
        let old = UUID(); let new = UUID()
        // Sidebar switch: the NEW thread's reporter can mount before the OLD
        // one's .onDisappear runs — the stale clear must not wipe the fresh pin.
        coordinator.setWindowVisibleConversation(new)
        coordinator.clearWindowVisibleConversation(ifCurrent: old)
        coordinator.noteReplyArrived(new)
        XCTAssertFalse(coordinator.hasUnreadReply,
                       "The stale thread's unmount clear must not drop the NEW thread's pin.")
        // The matching clear DOES drop it.
        coordinator.clearWindowVisibleConversation(ifCurrent: new)
        coordinator.noteReplyArrived(new)
        XCTAssertTrue(coordinator.hasUnreadReply)
    }

    // MARK: - Ordered unread (most-recent wins)

    func testMostRecentUnreadReturnsLatestArrival() {
        let coordinator = MenuBarCoordinator()
        let a = UUID(); let b = UUID()
        coordinator.noteReplyArrived(a)
        coordinator.noteReplyArrived(b)
        XCTAssertEqual(coordinator.mostRecentUnreadConversationID, b,
                       "A dot-click opens the freshest reply — last arrival wins.")
    }

    func testRenotingMovesThreadToMostRecent() {
        let coordinator = MenuBarCoordinator()
        let a = UUID(); let b = UUID()
        coordinator.noteReplyArrived(a)
        coordinator.noteReplyArrived(b)
        coordinator.noteReplyArrived(a)   // a's thread gets a newer reply
        XCTAssertEqual(coordinator.mostRecentUnreadConversationID, a,
                       "A fresh reply for an already-unread thread refreshes its recency.")
        XCTAssertEqual(coordinator.unreadReplyConversationIDs.count, 2,
                       "Re-noting the same thread must not duplicate it.")
    }

    func testClearingOneUnreadLeavesTheDotForOthers() {
        let coordinator = MenuBarCoordinator()
        let a = UUID(); let b = UUID()
        coordinator.noteReplyArrived(a)
        coordinator.noteReplyArrived(b)
        coordinator.clearUnread(b)
        XCTAssertTrue(coordinator.hasUnreadReply,
                      "Clearing one unread must leave the dot lit while another remains.")
        XCTAssertEqual(coordinator.mostRecentUnreadConversationID, a)
    }

    func testRemoteAgentTurnDidCompleteMarksUnread() async {
        // The share / background reply path raises the dot via
        // `.remoteAgentTurnDidComplete` (the in-app path uses
        // `.conversationReplyArrived`). The observer is queued on .main, so a
        // trailing main-queue hop (FIFO ordering) guarantees it ran before we
        // assert — no arbitrary sleep.
        let coordinator = MenuBarCoordinator()
        let id = UUID()
        NotificationCenter.default.post(
            name: .remoteAgentTurnDidComplete,
            object: nil,
            userInfo: [NotificationDeepLink.conversationIDKey: id.uuidString]
        )
        let hopped = XCTestExpectation(description: "main-queue hop after the observer")
        DispatchQueue.main.async { hopped.fulfill() }
        await fulfillment(of: [hopped], timeout: 1.0)
        XCTAssertTrue(coordinator.unreadReplyConversationIDs.contains(id),
                      "A background/share reply completion must raise the unread dot.")
        // Keep the coordinator alive until after the async observer ran.
        withExtendedLifetime(coordinator) {}
    }

    // MARK: - Popover display override (read-only shared-reply glance)

    func testDisplayedPopoverViewModelFallsBackToQuickLane() {
        let coordinator = MenuBarCoordinator()
        let quickID = UUID()
        coordinator.bindQuickViewModel(to: quickID)
        XCTAssertTrue(coordinator.displayedPopoverViewModel === coordinator.quickViewModel,
                      "With no override set, the popover displays the quick lane.")
        XCTAssertEqual(coordinator.displayedPopoverConversationID, quickID)
    }

    func testPopoverOverrideTakesPrecedenceOverQuickLane() {
        let coordinator = MenuBarCoordinator()
        coordinator.bindQuickViewModel(to: UUID())
        let shareID = UUID()
        coordinator.setPopoverOverride(to: shareID)
        XCTAssertEqual(coordinator.displayedPopoverConversationID, shareID,
                       "An override (a shared reply) is what the popover displays.")
        XCTAssertTrue(coordinator.displayedPopoverViewModel === coordinator.popoverOverrideViewModel)
    }

    func testClearPopoverOverrideRestoresQuickLane() {
        let coordinator = MenuBarCoordinator()
        let quickID = UUID()
        coordinator.bindQuickViewModel(to: quickID)
        coordinator.setPopoverOverride(to: UUID())
        coordinator.clearPopoverOverride()
        XCTAssertNil(coordinator.popoverOverrideViewModel)
        XCTAssertEqual(coordinator.displayedPopoverConversationID, quickID,
                       "Clearing the override returns the popover to the quick lane.")
    }

    func testSweepRetainsOverrideVM() {
        let coordinator = MenuBarCoordinator()
        let overrideID = UUID()
        coordinator.setPopoverOverride(to: overrideID)
        let overrideVM = coordinator.popoverOverrideViewModel
        // A quick-lane rebind triggers a sweep; the override lane still
        // references its VM → it must survive (else the displayed shared reply
        // would re-mint to a dead-spinner duplicate).
        coordinator.bindQuickViewModel(to: UUID())
        XCTAssertTrue(coordinator.viewModel(for: overrideID) === overrideVM,
                      "A displayed override VM must survive sweeps triggered by other lanes.")
    }

    // MARK: - Lanes share one instance per id

    func testBothLanesOnSameIDShareOneInstance() {
        let coordinator = MenuBarCoordinator()
        let id = UUID()
        coordinator.bindQuickViewModel(to: id)
        coordinator.bindWindowViewModel(to: id)
        XCTAssertNotNil(coordinator.quickViewModel)
        XCTAssertTrue(coordinator.quickViewModel === coordinator.windowViewModel,
                      "Same-conversation dual display (popover + window) must share ONE VM — one spinner, one in-flight guard.")
    }

    func testLanesOnDifferentIDsAreIndependent() {
        let coordinator = MenuBarCoordinator()
        let quickID = UUID()
        let windowID = UUID()
        coordinator.bindQuickViewModel(to: quickID)
        coordinator.bindWindowViewModel(to: windowID)
        XCTAssertEqual(coordinator.quickViewModel?.conversationID, quickID)
        XCTAssertEqual(coordinator.windowViewModel?.conversationID, windowID)
        XCTAssertFalse(coordinator.quickViewModel === coordinator.windowViewModel)
    }

    func testRebindToSameIDPreservesInstance() {
        let coordinator = MenuBarCoordinator()
        let id = UUID()
        coordinator.bindQuickViewModel(to: id)
        let original = coordinator.quickViewModel
        coordinator.bindQuickViewModel(to: id)
        XCTAssertTrue(coordinator.quickViewModel === original,
                      "Re-binding the same id is a no-op on identity (preserves the in-flight state machine).")
    }

    // MARK: - Sweep: drop orphans, retain lane-referenced + mid-turn VMs

    func testSweepDropsOrphanedVM() {
        let coordinator = MenuBarCoordinator()
        let orphanID = UUID()
        coordinator.bindQuickViewModel(to: orphanID)
        let orphan = coordinator.quickViewModel
        // Rebinding the lane elsewhere sweeps: the old VM has no lane and no
        // in-flight turn → dropped. A later request for the same id mints a
        // FRESH instance, proving the registry released the orphan.
        coordinator.bindQuickViewModel(to: UUID())
        let reminted = coordinator.viewModel(for: orphanID)
        XCTAssertFalse(reminted === orphan,
                       "An idle, lane-less VM must be swept — otherwise the registry grows unbounded.")
    }

    func testSweepRetainsOtherLanesVM() {
        let coordinator = MenuBarCoordinator()
        let windowID = UUID()
        coordinator.bindWindowViewModel(to: windowID)
        let windowVM = coordinator.windowViewModel
        // A quick-lane rebind sweeps, but the window lane still references its
        // VM → it must survive.
        coordinator.bindQuickViewModel(to: UUID())
        XCTAssertTrue(coordinator.viewModel(for: windowID) === windowVM,
                      "A lane-referenced VM must survive sweeps triggered by the OTHER lane.")
    }

    func testSweepRetainsAwaitingReplyVM() {
        let coordinator = MenuBarCoordinator()
        let midTurnID = UUID()
        coordinator.bindWindowViewModel(to: midTurnID)
        let midTurnVM = coordinator.windowViewModel
        // Simulate an in-flight agent turn, then navigate the window away —
        // the registry must keep the mid-turn VM reachable so navigating BACK
        // reattaches the live state machine (the registry's raison d'être).
        midTurnVM?.isAwaitingReply = true
        coordinator.bindWindowViewModel(to: UUID())
        XCTAssertTrue(coordinator.viewModel(for: midTurnID) === midTurnVM,
                      "A mid-turn VM must survive losing its lane — re-minting would orphan the in-flight Task's UI.")
    }

    // MARK: - startNewWindowConversation clears the window lane ONLY

    func testStartNewWindowConversationLeavesQuickLaneUntouched() {
        let coordinator = MenuBarCoordinator()
        let quickID = UUID()
        coordinator.bindQuickViewModel(to: quickID)
        coordinator.bindWindowViewModel(to: UUID())
        coordinator.startNewWindowConversation()
        XCTAssertNil(coordinator.windowViewModel,
                     "New-window-conversation must clear the window lane (empty state).")
        XCTAssertEqual(coordinator.quickViewModel?.conversationID, quickID,
                       "An explicit window action must never touch the quick lane.")
    }
}

#endif
