// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationDetailViewModelPopoverReplyTests.swift
//
// Coverage for the macOS-only PER-SEND popover-surfacing gate
// (`surfacesInPopover` — the quick/hotkey lane's claim on the menu-bar
// popover's reply slot). We bypass the full converse round-trip (which would
// require a live gateway + configured Keychain token + real STT keys) and drive
// the extracted internal helper `recordPopoverReplyIfNeeded(agentReply:
// surfaces:)` directly. The helper is the EXACT code path `sendUserTurn` +
// `retry` execute on the macOS success branch, so asserting on it is equivalent
// to asserting on the production gate without the network seam — mirrors
// `ConversationDetailViewModelMacReplySpeakTests` exactly.
//
// The property under test is `ConversationDetailViewModel.lastPopoverReply`:
// the menu-bar popover renders exactly this record, so a reply that never sets
// it (a window-typed turn, or an iPhone/Watch reply synced into this shared
// registry VM's conversation) never populates the popover.

#if os(macOS)

import XCTest
@testable import Conduck

@MainActor
final class ConversationDetailViewModelPopoverReplyTests: XCTestCase {

    /// A minimal agent-reply record — the shape `completeAgentTurn` returns.
    private func agentReply(_ text: String = "agent reply") -> MessageRecord {
        MessageRecord(
            id: UUID(),
            role: "agent",
            text: text,
            createdAt: Date(),
            sourceDevice: "mac"
        )
    }

    // MARK: - Gate honoured

    func testSurfacesFalseLeavesReplyNil() {
        let vm = ConversationDetailViewModel(conversationID: UUID())
        vm.recordPopoverReplyIfNeeded(agentReply: agentReply(), surfaces: false)
        XCTAssertNil(vm.lastPopoverReply,
                     "surfaces=false (window/in-app/synced reply) must NOT claim "
                     + "the popover reply slot.")
    }

    func testSurfacesTrueSetsReply() {
        let vm = ConversationDetailViewModel(conversationID: UUID())
        let reply = agentReply("quick answer")
        vm.recordPopoverReplyIfNeeded(agentReply: reply, surfaces: true)
        XCTAssertEqual(vm.lastPopoverReply, reply,
                       "A quick/hotkey-lane reply must be retained as the "
                       + "popover reply.")
    }

    // MARK: - Store-failure guard

    func testNilReplyLeavesPriorReplyUntouched() {
        let vm = ConversationDetailViewModel(conversationID: UUID())
        let first = agentReply("first")
        vm.recordPopoverReplyIfNeeded(agentReply: first, surfaces: true)
        // A later quick send whose `completeAgentTurn` returned nil (store
        // failure) must not wipe the last genuine quick reply.
        vm.recordPopoverReplyIfNeeded(agentReply: nil, surfaces: true)
        XCTAssertEqual(vm.lastPopoverReply, first,
                       "A nil reply (store failure) must leave the retained "
                       + "reply in place, not clear it.")
    }

    // MARK: - Replacement

    func testSecondQuickReplyReplacesReply() {
        let vm = ConversationDetailViewModel(conversationID: UUID())
        let first = agentReply("first")
        let second = agentReply("second")
        vm.recordPopoverReplyIfNeeded(agentReply: first, surfaces: true)
        vm.recordPopoverReplyIfNeeded(agentReply: second, surfaces: true)
        XCTAssertEqual(vm.lastPopoverReply, second,
                       "Each successful quick-lane reply replaces the retained "
                       + "popover reply.")
    }

    // MARK: - Interleaved window send does not disturb the reply

    func testWindowSendBetweenQuickRepliesDoesNotOverwrite() {
        // The registry shares ONE VM between the popover (quick) and main window
        // lanes for the same conversation. A window turn (surfaces=false)
        // landing between two quick replies must not touch the retained reply.
        let vm = ConversationDetailViewModel(conversationID: UUID())
        let quickReply = agentReply("quick")
        vm.recordPopoverReplyIfNeeded(agentReply: quickReply, surfaces: true)
        vm.recordPopoverReplyIfNeeded(agentReply: agentReply("window"), surfaces: false)
        XCTAssertEqual(vm.lastPopoverReply, quickReply,
                       "A window-lane reply on the shared VM must not overwrite "
                       + "the quick-lane popover reply.")
    }
}

#endif
