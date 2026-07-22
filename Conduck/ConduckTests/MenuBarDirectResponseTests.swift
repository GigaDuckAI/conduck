// Conduck
// MenuBarDirectResponseTests.swift
//
// The popover's "a response continues the visible reply" rule
// (`MenuBarCoordinator.armQuickCapture`'s direct-response freeze) and the
// header "New chat" reset (`startNewQuickChat`):
//   - an in-popover response FREEZES `.automatic(existing: visibleThread)`
//     synchronously — no TTL re-resolve — so words land in the reply on screen,
//   - a CLOSED popover (retained reply, but not visible) falls back to the cold
//     TTL policy — no force-continue,
//   - a read-only shared-reply OVERRIDE glance is a different thread — the guard
//     does not fire and the override is dropped by the new capture,
//   - a stale resolver from a PRIOR arm cannot clobber the freeze (the
//     `armGeneration` write-guard),
//   - `startNewQuickChat` clears the quick lane / visible marker / override and
//     arms a fresh `.explicitNew(nil)` that survives to the next capture.
//
// Every coordinator injects an isolated `ConversationStore(inMemory: true)` via
// the store seam (the unsigned test host CRASHES on the shared CloudKit
// container's first touch — no iCloud entitlement). These tests assert
// COORDINATOR state only (the frozen snapshot / lane fields); the mint-and-send
// tail through `vm.sendUserTurn` hits the shared store and is signed-run + QA
// territory. `@MainActor` because the coordinator requires it.

#if os(macOS)

import XCTest
@testable import Conduck

@MainActor
final class MenuBarDirectResponseTests: XCTestCase {

    private func makeCoordinator() -> (MenuBarCoordinator, ConversationStore) {
        let store = ConversationStore(inMemory: true)
        return (MenuBarCoordinator(conversationStore: store), store)
    }

    /// A minimal agent-reply record — the shape the popover retains in
    /// `lastPopoverReply`.
    private func agentReply(_ text: String = "agent reply") -> MessageRecord {
        MessageRecord(id: UUID(), role: "agent", text: text,
                      createdAt: Date(), sourceDevice: "mac")
    }

    /// Put the popover in the "open, idle, showing THIS quick thread's settled
    /// reply" state the direct-response freeze keys on.
    private func showReply(_ coordinator: MenuBarCoordinator, on id: UUID) {
        coordinator.bindQuickViewModel(to: id)
        coordinator.quickViewModel?.lastPopoverReply = agentReply()
        coordinator.setPopoverVisibleConversation(id)
    }

    // MARK: - A popover response continues the visible reply

    func testPopoverResponseContinuesVisibleReply() async throws {
        let (coordinator, store) = makeCoordinator()
        let convo = try await store.createConversation(backend: "openclaw")
        showReply(coordinator, on: convo.id)

        coordinator.armQuickCapture()

        // The freeze is SYNCHRONOUS (no re-resolve), so it holds immediately —
        // and would hold even if the TTL pointer had lapsed to "new chat".
        XCTAssertTrue(coordinator.quickDestinationLatched,
                      "Arming freezes the destination for the capture.")
        guard case .automatic(existing: .some(let id)) =
                coordinator.quickDestination?.destination else {
            return XCTFail("A popover response must freeze .automatic(existing:) on the visible thread.")
        }
        XCTAssertEqual(id, convo.id,
                       "The response continues the thread whose reply is on screen.")
    }

    // MARK: - A closed popover follows the cold TTL policy

    func testClosedPopoverDoesNotForceContinueRetainedReply() async throws {
        let (coordinator, store) = makeCoordinator()
        let convo = try await store.createConversation(backend: "openclaw")
        coordinator.bindQuickViewModel(to: convo.id)
        coordinator.quickViewModel?.lastPopoverReply = agentReply()
        // Popover CLOSED — the reply is retained on the VM, but nothing visible.
        coordinator.setPopoverVisibleConversation(nil)

        coordinator.armQuickCapture()

        // The guard must NOT fire: a cold capture re-resolves the TTL policy
        // ASYNC, so there is no SYNCHRONOUS freeze onto the retained thread. (The
        // direct-response freeze is the only synchronous force-continue path.)
        if case .automatic(existing: .some(let id)) =
            coordinator.quickDestination?.destination, id == convo.id {
            XCTFail("A closed popover must not force-continue the retained reply's thread.")
        }
    }

    // MARK: - A read-only override glance is a different thread

    func testOverrideVisibleReplyDoesNotForceContinueAndIsCleared() async throws {
        let (coordinator, store) = makeCoordinator()
        let quickConvo = try await store.createConversation(backend: "openclaw")
        let otherConvo = try await store.createConversation(backend: "openclaw")
        showReply(coordinator, on: quickConvo.id)
        // A dot-click peek at another thread's reply takes over the display.
        coordinator.setPopoverOverride(to: otherConvo.id)

        coordinator.armQuickCapture()

        // The override makes this NOT an in-popover response to the quick thread,
        // so the guard must not force-continue it.
        if case .automatic(existing: .some(let id)) =
            coordinator.quickDestination?.destination, id == quickConvo.id {
            XCTFail("An override glance must not force-continue the quick lane's thread.")
        }
        // A new capture always shows the quick lane — the override is dropped.
        XCTAssertNil(coordinator.popoverOverrideViewModel,
                     "Arming a capture drops the read-only shared-reply override.")
    }

    // MARK: - A stale resolver can't clobber the freeze (armGeneration guard)

    func testStaleResolverCannotClobberDirectResponseFreeze() async throws {
        let (coordinator, store) = makeCoordinator()
        let convo = try await store.createConversation(backend: "openclaw")
        showReply(coordinator, on: convo.id)

        // A background automatic re-resolve is put in flight: it passes the
        // (not-yet-latched) refresh guard, captures the CURRENT generation, then
        // suspends at its first actor hop. `convo` is never the stamped quick
        // pointer, so this resolve would land `.automatic(existing: nil)`.
        let background = Task { await coordinator.refreshQuickDestination() }
        await Task.yield()   // let it enter the resolve and suspend mid-flight

        // The direct-response arm freezes `.automatic(existing: convo)` and bumps
        // the generation — making the in-flight resolve stale.
        coordinator.armQuickCapture()
        guard case .automatic(existing: .some(let armedID)) =
                coordinator.quickDestination?.destination, armedID == convo.id else {
            return XCTFail("Precondition: the arm must freeze the visible thread.")
        }

        // Let the stale resolve run to completion — its generation-guarded write
        // must be rejected, so the freeze survives.
        await background.value
        guard case .automatic(existing: .some(let id)) =
                coordinator.quickDestination?.destination else {
            return XCTFail("A stale resolver clobbered the freeze (lost the continuation).")
        }
        XCTAssertEqual(id, convo.id,
                       "The armGeneration guard must reject a superseded resolver's write.")
    }

    // MARK: - New chat resets the lane and arms a fresh chat

    func testStartNewQuickChatClearsLaneAndArmsFreshChat() async throws {
        let (coordinator, store) = makeCoordinator()
        let convo = try await store.createConversation(backend: "openclaw")
        showReply(coordinator, on: convo.id)

        coordinator.startNewQuickChat()

        XCTAssertNil(coordinator.quickViewModel,
                     "New chat clears the quick lane so the popover falls to the empty state.")
        XCTAssertNil(coordinator.popoverVisibleConversationID,
                     "New chat clears the visible-thread marker (so the next capture is cold).")
        XCTAssertNil(coordinator.popoverOverrideViewModel,
                     "New chat drops any read-only override defensively.")
        guard case .explicitNew(let ref) = coordinator.quickDestination?.destination else {
            return XCTFail("New chat arms an explicit fresh chat.")
        }
        XCTAssertNil(ref, "The fresh chat mints on the persisted default (no carried gateway).")

        // The explicit-new pick SURVIVES the next capture (it doesn't latch, so
        // the self-heal won't wipe it) — the next words mint a brand-new chat.
        coordinator.armQuickCapture()
        guard case .explicitNew = coordinator.quickDestination?.destination else {
            return XCTFail("The New-chat pick must survive to the next capture (mint a fresh conversation).")
        }
    }

    /// New chat is SETTLED-ONLY: a no-op while a turn is in flight, so it can't
    /// yank a thread out from under an awaiting reply.
    func testStartNewQuickChatIsNoOpWhileAwaitingReply() async throws {
        let (coordinator, store) = makeCoordinator()
        let convo = try await store.createConversation(backend: "openclaw")
        showReply(coordinator, on: convo.id)
        coordinator.quickViewModel?.isAwaitingReply = true

        coordinator.startNewQuickChat()

        XCTAssertNotNil(coordinator.quickViewModel,
                        "New chat must not clear the lane while a reply is in flight.")
        XCTAssertEqual(coordinator.popoverVisibleConversationID, convo.id,
                       "The visible-thread marker must survive the guarded no-op.")
    }
}
#endif
