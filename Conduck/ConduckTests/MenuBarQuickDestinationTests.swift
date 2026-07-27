// SPDX-License-Identifier: Apache-2.0

// Conduck
// MenuBarQuickDestinationTests.swift
//
// MenuBarCoordinator's pure-logic destination guards — the synchronous,
// headless-reachable correctness backstops that protect the quick-capture
// snapshot from being silently retargeted out from under an in-flight turn:
//
//   - `selectQuickDestination` BACKSTOP: a late picker tap must NOT retarget a
//     turn already consuming the snapshot (the display-one/send-another guard).
//     Once the bound quick VM is awaiting a reply, the snapshot is frozen —
//     a stray selection is a no-op (the destination is unchanged).
//   - `selectQuickDestination` while idle still mutates (control case — proves
//     the backstop above isn't a tautology that blocks everything).
//   - `armQuickCapture` SELF-HEAL: a stale latch left by an abandoned error
//     turn (clicked away while `.error`, no reset ran) must be released on the
//     next arm — the dead turn's one-shot explicit pick is dropped and the
//     destination re-resolves as automatic, so a fresh capture hours later
//     can't consume it. The recovery-context exemption (a stashed turn) is
//     verified to KEEP its pick (Retry-into-frozen-destination contract).
//   - `quickGatewayDisplayName(forBackendRaw:)`: an unparseable raw falls back
//     to the default gateway name (defensive ladder); a valid built-in raw
//     resolves to that built-in's locked display name.
//
// Builds on the established coordinator harness (in-memory store seam; the
// unsigned test host CRASHES on the shared CloudKit container's first touch).
// Paths that reach `vm.sendUserTurn` (whose optimistic append hits the SHARED
// store inside the VM) are NOT driven — that send tail is signed-run + QA
// territory. `dictationService.state` is `private(set)` and only flips to
// `.processing` via a live AVAudioEngine capture, so the `.processing` arm of
// the `selectQuickDestination` guard is exercised via the headless-reachable
// `isAwaitingReply` / `turnStarting` arms instead. `@MainActor` because the
// coordinator requires it.

#if os(macOS)

import XCTest
@testable import Conduck

@MainActor
final class MenuBarQuickDestinationTests: XCTestCase {

    /// Coordinator + its isolated in-memory store, mirroring the sibling
    /// quick-typed harness (the shared CloudKit store would crash the unsigned
    /// host on first touch).
    private func makeCoordinator() -> (MenuBarCoordinator, ConversationStore) {
        let store = ConversationStore(inMemory: true)
        return (MenuBarCoordinator(conversationStore: store), store)
    }

    private func explicitConversationID(_ coordinator: MenuBarCoordinator) -> UUID? {
        if case .explicitConversation(let id) = coordinator.quickDestination?.destination {
            return id
        }
        return nil
    }

    // MARK: - selectQuickDestination correctness backstop

    /// Once the bound quick VM is awaiting a reply, the turn is CONSUMING the
    /// frozen snapshot — a late picker tap must be a no-op (the destination is
    /// unchanged). This is the display-one/send-another correctness backstop:
    /// the popover disables the control there too, but the guard is what makes
    /// it correct even if a tap slips through.
    func testSelectIsNoOpWhileBoundQuickVMAwaitsReply() {
        let (coordinator, _) = makeCoordinator()
        let firstPick = UUID()
        coordinator.selectQuickDestination(.explicitConversation(firstPick))
        XCTAssertEqual(explicitConversationID(coordinator), firstPick,
                       "Sanity: an idle pick must take effect (otherwise the backstop test below is vacuous).")

        // The bound quick lane goes mid-turn — the snapshot is now being
        // consumed by the send.
        coordinator.bindQuickViewModel(to: UUID())
        coordinator.quickViewModel?.isAwaitingReply = true

        let lateRetarget = UUID()
        coordinator.selectQuickDestination(.explicitConversation(lateRetarget))
        XCTAssertEqual(explicitConversationID(coordinator), firstPick,
                       "A late selection must NOT retarget a turn already consuming the snapshot.")
        XCTAssertNotEqual(explicitConversationID(coordinator), lateRetarget,
                          "display==send: the consuming turn keeps the destination the popover showed at capture time.")
    }

    /// The `turnStarting` arm of the same guard (the async gap between STT
    /// finishing and the send Task claiming `isAwaitingReply`). A tap in that
    /// window must also be a no-op.
    func testSelectIsNoOpWhileTurnStarting() {
        let (coordinator, _) = makeCoordinator()
        let firstPick = UUID()
        coordinator.selectQuickDestination(.explicitConversation(firstPick))

        // Drive `turnStarting = true` through the documented synchronous press
        // contract (no private mutation): a typed send aimed at the picked
        // destination claims the gap-bridge before any await.
        coordinator.quickDraft = "consuming the snapshot"
        coordinator.sendQuickTypedDraft()
        XCTAssertTrue(coordinator.turnStarting,
                      "Sanity: the press contract claims the gap-bridge synchronously.")

        let lateRetarget = UUID()
        coordinator.selectQuickDestination(.explicitConversation(lateRetarget))
        XCTAssertNotEqual(explicitConversationID(coordinator), lateRetarget,
                          "A tap during the transcribing→answering gap must not retarget the consuming turn.")
    }

    /// Control: while fully idle the picker freely mutates the snapshot — the
    /// guard only blocks DURING a consuming turn. Proves the no-op tests above
    /// pin the guard, not a coordinator that ignores all selections.
    func testSelectMutatesSnapshotWhileIdle() {
        let (coordinator, _) = makeCoordinator()
        let a = UUID()
        coordinator.selectQuickDestination(.explicitConversation(a))
        XCTAssertEqual(explicitConversationID(coordinator), a)
        let b = UUID()
        coordinator.selectQuickDestination(.explicitConversation(b))
        XCTAssertEqual(explicitConversationID(coordinator), b,
                       "Re-picking while idle replaces the snapshot in place (mid-recording retarget is allowed).")
    }

    // MARK: - armQuickCapture self-heal (stale latch from an abandoned error turn)

    /// A latch left over from an abandoned error turn — no pending image, no
    /// stashed turn — must be released on the next arm: the dead turn's
    /// one-shot explicit pick is dropped (re-resolved as automatic) so a fresh
    /// capture can't consume it hours later.
    func testReArmSelfHealsStaleLatchFromAbandonedExplicitPick() {
        let (coordinator, _) = makeCoordinator()
        // First arm freezes an explicit pick (latched).
        let abandonedPick = UUID()
        coordinator.selectQuickDestination(.explicitConversation(abandonedPick))
        coordinator.armQuickCapture()
        XCTAssertTrue(coordinator.quickDestinationLatched,
                      "Sanity: arming latches the destination.")
        XCTAssertEqual(explicitConversationID(coordinator), abandonedPick,
                       "Sanity: the explicit pick rides the first arm verbatim.")

        // The turn is abandoned (popover clicked away while in error) but no
        // reset ran — the latch + pick are now stale. No recovery context:
        XCTAssertNil(coordinator.pendingCaptureImage)
        XCTAssertFalse(coordinator.hasPendingFailedTurn)

        // Re-arm: the self-heal must drop the dead pick.
        coordinator.armQuickCapture()
        XCTAssertNil(explicitConversationID(coordinator),
                     "A re-arm with no recovery context must release the abandoned turn's explicit pick.")
        if case .explicitNew = coordinator.quickDestination?.destination {
            XCTFail("The stale explicit pick must be cleared, not swapped for another explicit destination.")
        }
    }

    /// The recovery-context exemption: an arm that CONTINUES a stranded turn
    /// (a stashed transcript) must KEEP the latched pick — Retry-Voice replays
    /// into the exact destination the error copy promised, so the self-heal
    /// must NOT fire here.
    func testReArmKeepsExplicitPickWhenContinuingAStrandedTurn() async {
        let (coordinator, _) = makeCoordinator()
        // Aim at a nonexistent thread and send a voice turn — the deleted
        // explicit destination strands the turn (stash + snapshot kept latched,
        // repointed to .explicitNew per the error-copy promise).
        coordinator.selectQuickDestination(.explicitConversation(UUID()))
        await coordinator.handleTranscript("words worth keeping")

        XCTAssertTrue(coordinator.hasPendingFailedTurn,
                      "Sanity: a deleted explicit destination strands the turn.")
        XCTAssertTrue(coordinator.quickDestinationLatched,
                      "Sanity: a stash-error keeps the snapshot latched.")
        guard case .explicitNew = coordinator.quickDestination?.destination else {
            return XCTFail("Sanity: the stranded snapshot is repointed to .explicitNew.")
        }

        // Re-arm to CONTINUE the stranded turn: the self-heal is exempt because
        // a stash exists, so the .explicitNew destination must survive.
        coordinator.armQuickCapture()
        if case .explicitNew = coordinator.quickDestination?.destination {
            // Correct: the Retry destination is preserved across the re-arm.
        } else {
            XCTFail("A re-arm that continues a stranded turn must KEEP the latched destination (Retry-into-frozen contract).")
        }
    }

    // MARK: - quickGatewayDisplayName(forBackendRaw:) fallback ladder

    /// An unparseable backend raw (`RemoteAgentRef(rawString:)` returns nil)
    /// falls back to the default-gateway name — the defensive ladder for a
    /// corrupt / future-unknown stored `Conversation.backend`.
    func testGatewayDisplayNameForUnparseableRawFallsBackToDefault() {
        let (coordinator, _) = makeCoordinator()
        XCTAssertEqual(coordinator.quickGatewayDisplayName(forBackendRaw: "not-a-real-backend"),
                       coordinator.quickDefaultGatewayName,
                       "An unparseable raw must fall back to the default gateway name, never a crash or empty string.")
    }

    /// A valid built-in raw resolves to that built-in's LOCKED display name.
    /// Pinned to hardcoded literals — `RemoteAgentBackend.{openclaw,hermes}`
    /// raw values are persisted in `Conversation.backend`; a rename of either
    /// the raw value or the display name must fail this test.
    func testGatewayDisplayNameForBuiltinRawResolvesLockedName() {
        let (coordinator, _) = makeCoordinator()
        XCTAssertEqual(coordinator.quickGatewayDisplayName(forBackendRaw: "openclaw"), "OpenClaw",
                       "The locked 'openclaw' raw must resolve to the locked 'OpenClaw' display name.")
        XCTAssertEqual(coordinator.quickGatewayDisplayName(forBackendRaw: "hermes"), "Hermes",
                       "The locked 'hermes' raw must resolve to the locked 'Hermes' display name.")
    }
}

#endif
