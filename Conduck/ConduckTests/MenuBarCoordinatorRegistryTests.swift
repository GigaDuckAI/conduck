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
// …plus the status item's two dots, which are DERIVED from stored conversation
// rows rather than accumulated from local turn-completion events. That is why
// these cases drive `MenuBarAttention` with hand-built rows instead of poking
// the coordinator with notifications: the interesting inputs — a view marker
// written on the iPad, an acknowledgement made on the wrist, a retry's new
// attempt id — never arrive as a local event at all, and a test that could only
// deliver them as one would be testing the mechanism this file exists to prove
// gone. The coordinator-level cases here cover the other half: which callbacks
// are allowed to claim the user is looking at a thread.
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

    /// The derivation folds in `ReadStateStore.shared`, whose ACCOUNT CUTOVER is
    /// process-wide rather than per-conversation: a cutover another suite left
    /// behind would read as "everything before this moment has been seen" and
    /// silently disarm every unseen case below. Fresh ids are not protection
    /// against it, so the store is reset instead.
    override func setUp() async throws {
        try await super.setUp()
        ReadStateStore._resetForTesting()
    }

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

    // MARK: - Attention derivation fixtures

    /// A picker row carrying an agent tail, i.e. one that CAN read as unseen.
    /// The tail envelope is built with the row's own `lastActivityAt` because the
    /// resolver accepts a projection only on exact equality — a row built any
    /// other way is stale by construction and would suppress the branch under
    /// test for the wrong reason.
    private func agentTailRow(
        id: UUID = UUID(),
        at lastActivityAt: Date,
        lastViewedAt: Date? = nil
    ) -> ConversationStore.RecentConversation {
        ConversationStore.RecentConversation(
            id: id,
            label: "row",
            lastActivityAt: lastActivityAt,
            backend: "openclaw",
            lastViewedAt: lastViewedAt,
            tailProjection: TailProjection.encoded(
                messageID: UUID(),
                createdAt: lastActivityAt,
                role: .agent
            )
        )
    }

    /// A picker row whose newest failed user turn IS its last activity — the only
    /// shape the resolver reports as `.failed`.
    private func failedRow(
        id: UUID = UUID(),
        at lastActivityAt: Date,
        attemptID: UUID?,
        seenAttemptID: UUID?
    ) -> ConversationStore.RecentConversation {
        ConversationStore.RecentConversation(
            id: id,
            label: "row",
            lastActivityAt: lastActivityAt,
            backend: "openclaw",
            newestFailed: FailedTurnProjection(
                messageID: UUID(),
                createdAt: lastActivityAt,
                deliveryAttemptID: attemptID
            ),
            failureSeenAttemptID: seenAttemptID
        )
    }

    // MARK: - The unread (yellow) dot, derived from stored rows

    func testUnseenAgentTailRaisesTheUnreadDot() {
        let now = Date()
        let row = agentTailRow(at: now)
        let attention = MenuBarAttention.derive(from: [row], now: now)
        XCTAssertEqual(attention.unreadConversationIDs, [row.id])
        XCTAssertEqual(attention.mostRecentUnread, row.id,
                       "A dot-click opens the freshest unseen thread.")
    }

    func testStoredViewMarkerClearsTheUnreadDot() {
        let now = Date()
        // The read arrived from another device: nothing local ever happened here,
        // and the dot must be dark anyway. This is the case an accumulated set
        // could not answer at all.
        let row = agentTailRow(at: now, lastViewedAt: now)
        let attention = MenuBarAttention.derive(from: [row], now: now)
        XCTAssertTrue(attention.unreadConversationIDs.isEmpty,
                      "A view marker imported from another device must retire this Mac's dot.")
        XCTAssertNil(attention.mostRecentUnread)
    }

    func testUserTailNeverReadsAsUnseen() {
        let now = Date()
        let row = ConversationStore.RecentConversation(
            id: UUID(),
            label: "row",
            lastActivityAt: now,
            backend: "openclaw",
            tailProjection: TailProjection.encoded(
                messageID: UUID(),
                createdAt: now,
                role: .user
            )
        )
        XCTAssertTrue(MenuBarAttention.derive(from: [row], now: now).unreadConversationIDs.isEmpty,
                      "Only an agent reply is something the user has not seen — their own message is not.")
    }

    func testMissingTailProjectionSuppressesTheUnreadDot() {
        let now = Date()
        let row = ConversationStore.RecentConversation(
            id: UUID(),
            label: "row",
            lastActivityAt: now,
            backend: "openclaw"
        )
        XCTAssertTrue(MenuBarAttention.derive(from: [row], now: now).unreadConversationIDs.isEmpty,
                      "No projection means NOT PROJECTED — a missing dot, never a guessed one.")
    }

    func testStaleTailProjectionSuppressesTheUnreadDot() {
        let now = Date()
        // An older build appended a reply, bumped `lastActivityAt` and left the
        // envelope describing the previous tail. The stamp is what exposes it.
        let row = ConversationStore.RecentConversation(
            id: UUID(),
            label: "row",
            lastActivityAt: now,
            backend: "openclaw",
            tailProjection: TailProjection.encoded(
                messageID: UUID(),
                createdAt: now.addingTimeInterval(-90),
                role: .agent
            )
        )
        XCTAssertTrue(MenuBarAttention.derive(from: [row], now: now).unreadConversationIDs.isEmpty,
                      "A projection that no longer describes the tail must not drive a dot.")
    }

    func testMultipleUnreadThreadsCoalesceToOneDot() {
        let now = Date()
        let attention = MenuBarAttention.derive(
            from: [agentTailRow(at: now), agentTailRow(at: now.addingTimeInterval(-60))],
            now: now
        )
        XCTAssertEqual(attention.unreadConversationIDs.count, 2)
        XCTAssertNotNil(attention.mostRecentUnread,
                        "Any non-empty unread set shows ONE dot (count is not surfaced).")
    }

    func testMostRecentUnreadIsDecidedByActivityNotArrayOrder() {
        let now = Date()
        let older = agentTailRow(at: now.addingTimeInterval(-600))
        let newer = agentTailRow(at: now)
        let attention = MenuBarAttention.derive(from: [newer, older], now: now)
        XCTAssertEqual(attention.mostRecentUnread, newer.id,
                       "Freshness is the account's `lastActivityAt`, not the order the rows were handed over.")
    }

    // MARK: - The failure (red) dot, derived from stored rows

    func testUnacknowledgedFailureRaisesTheFailureDot() {
        let now = Date()
        let row = failedRow(at: now, attemptID: UUID(), seenAttemptID: nil)
        let attention = MenuBarAttention.derive(from: [row], now: now)
        XCTAssertEqual(attention.failedConversationIDs, [row.id])
        XCTAssertEqual(attention.mostRecentFailure, row.id)
    }

    func testFailureAcknowledgedOnAnotherDeviceRetiresTheDot() {
        let now = Date()
        let attempt = UUID()
        let row = failedRow(at: now, attemptID: attempt, seenAttemptID: attempt)
        XCTAssertTrue(MenuBarAttention.derive(from: [row], now: now).failedConversationIDs.isEmpty,
                      "An acknowledgement made on the phone or the wrist must retire this Mac's red dot.")
    }

    func testAcknowledgementOfAnOtherAttemptLeavesTheDotLit() {
        let now = Date()
        // Retry mints a NEW attempt id and leaves the stored acknowledgement
        // alone, so the stored one simply stops matching.
        let row = failedRow(at: now, attemptID: UUID(), seenAttemptID: UUID())
        XCTAssertFalse(MenuBarAttention.derive(from: [row], now: now).failedConversationIDs.isEmpty,
                       "An acknowledgement naming a different attempt must not silence this one.")
    }

    func testFailureWithNoAttemptIdentityStaysLit() {
        let now = Date()
        let row = failedRow(at: now, attemptID: nil, seenAttemptID: UUID())
        XCTAssertFalse(MenuBarAttention.derive(from: [row], now: now).failedConversationIDs.isEmpty,
                       "A failure carrying no identity is not acknowledged by anything — the safe direction.")
    }

    func testSupersededFailureRaisesNoDot() {
        let now = Date()
        var row = failedRow(at: now.addingTimeInterval(-600), attemptID: UUID(), seenAttemptID: nil)
        row = ConversationStore.RecentConversation(
            id: row.id,
            label: row.label,
            lastActivityAt: now,               // a later turn moved the conversation on
            backend: row.backend,
            newestFailed: row.newestFailed
        )
        XCTAssertTrue(MenuBarAttention.derive(from: [row], now: now).failedConversationIDs.isEmpty,
                      "A failure that is no longer the last thing that happened is not what the row reports.")
    }

    func testNoRowsMeansNoDots() {
        let attention = MenuBarAttention.derive(from: [])
        XCTAssertTrue(attention.unreadConversationIDs.isEmpty)
        XCTAssertTrue(attention.failedConversationIDs.isEmpty)
        XCTAssertNil(attention.mostRecentUnread)
        XCTAssertNil(attention.mostRecentFailure)
    }

    func testFreshCoordinatorShowsNeitherDot() {
        let coordinator = MenuBarCoordinator()
        XCTAssertFalse(coordinator.hasUnreadReply)
        XCTAssertFalse(coordinator.hasFailure)
        XCTAssertNil(coordinator.mostRecentUnreadConversationID)
        XCTAssertNil(coordinator.mostRecentFailureConversationID)
    }

    // MARK: - Visibility pins (the settled-visibility callbacks)

    func testPopoverVisiblePinTracksTheDisplayedThread() {
        let coordinator = MenuBarCoordinator()
        let id = UUID()
        coordinator.setPopoverVisibleConversation(id)
        XCTAssertEqual(coordinator.popoverVisibleConversationID, id)
        coordinator.setPopoverVisibleConversation(nil)
        XCTAssertNil(coordinator.popoverVisibleConversationID,
                     "Closing the popover means nobody is looking at that thread any more.")
    }

    func testWindowVisiblePinTracksTheActiveWindowsThread() {
        let coordinator = MenuBarCoordinator()
        let id = UUID()
        coordinator.setWindowVisibleConversation(id)
        XCTAssertEqual(coordinator.windowVisibleConversationID, id)
        coordinator.setWindowVisibleConversation(nil)
        XCTAssertNil(coordinator.windowVisibleConversationID,
                     "A window that resigned active is no longer showing anything to anybody.")
    }

    func testClearWindowVisibleIfCurrentIgnoresStaleThread() {
        let coordinator = MenuBarCoordinator()
        let old = UUID(); let new = UUID()
        // Sidebar switch: the NEW thread's reporter can mount before the OLD
        // one's .onDisappear runs — the stale clear must not wipe the fresh pin.
        coordinator.setWindowVisibleConversation(new)
        coordinator.clearWindowVisibleConversation(ifCurrent: old)
        XCTAssertEqual(coordinator.windowVisibleConversationID, new,
                       "The stale thread's unmount clear must not drop the NEW thread's pin.")
        coordinator.clearWindowVisibleConversation(ifCurrent: new)
        XCTAssertNil(coordinator.windowVisibleConversationID,
                     "The matching clear DOES drop it.")
    }

    func testOpenConversationBindsTheLaneWithoutClaimingVisibility() {
        let coordinator = MenuBarCoordinator()
        let id = UUID()
        coordinator.openConversation(id)
        XCTAssertEqual(coordinator.windowViewModel?.conversationID, id,
                       "A deep-link / sidebar pick binds the WINDOW lane.")
        XCTAssertNil(coordinator.windowVisibleConversationID,
                     "Binding a lane is an intent to show a thread, never proof that anything is on screen — "
                     + "acknowledging here would retire an account-wide mark on every device for something nobody saw.")
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
