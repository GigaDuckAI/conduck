// Conduck
// ConversationDetailViewModelInitialLoadTests.swift
//
// Coverage for `hasLoadedInitialMessages` — the monotonic gate that keeps
// `ConversationThreadView`'s empty-state mascot from flashing on conversation
// switch. Every switch mints a fresh VM whose `messages` starts `[]` and
// fills via the init-scheduled async `reload()`; the first body render can
// land in that gap, so the mascot must be gated on "first load completed",
// not on `messages.isEmpty` alone (nor on `isLoading`, which is false until
// the reload Task actually runs).
//
// Construction mirrors `ConversationDetailViewModelMacReplySpeakTests`:
// direct `@MainActor` init with a random UUID — the store fetch for an
// unknown conversation returns `[]`, which is exactly the "genuinely empty
// thread" shape the gate must eventually let through.

import XCTest
@testable import Conduck

@MainActor
final class ConversationDetailViewModelInitialLoadTests: XCTestCase {

    /// The exact first-render race: init schedules `reload()` in a Task, but
    /// the first body evaluation happens before it runs. The flag must be
    /// false synchronously after init so the mascot stays hidden.
    func testFlagIsFalseSynchronouslyAfterInit() {
        let vm = ConversationDetailViewModel(conversationID: UUID())
        XCTAssertFalse(vm.hasLoadedInitialMessages,
                       "A freshly minted VM must not show the empty-state "
                       + "mascot before its initial fetch lands.")
    }

    /// A genuinely empty thread must still surface the mascot once the first
    /// load completes — the gate suppresses the pre-load flash, not the
    /// legitimate empty state.
    func testFlagFlipsTrueAfterReloadEvenWhenThreadIsEmpty() async {
        let vm = ConversationDetailViewModel(conversationID: UUID())
        await vm.reload()
        XCTAssertTrue(vm.hasLoadedInitialMessages,
                      "First reload() (even one returning zero messages) must "
                      + "flip the gate so the empty-state mascot can appear.")
        XCTAssertTrue(vm.messages.isEmpty,
                      "Unknown conversation ID must fetch as an empty thread.")
    }
}
