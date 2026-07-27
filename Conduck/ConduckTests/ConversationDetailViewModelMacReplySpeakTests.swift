// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationDetailViewModelMacReplySpeakTests.swift
//
// Coverage for the macOS-only PER-SEND speak-on-arrival gate (`speaksReply` —
// the quick-lane "speak replies" toggle). We bypass the full converse
// round-trip (which would require a live gateway + configured Keychain token +
// real STT keys) and drive the extracted internal helper
// `dispatchReplySpeakIfNeeded(reply:speaks:)` directly. The helper is the
// exact code path `sendUserTurn` + `retry` execute on the macOS success
// branch, so asserting on it is equivalent to asserting on the production
// gate without the network seam — mirrors
// `ConversationDetailViewModelMacReplyBannerTests` exactly.
//
// The closure-spy seam is `ConversationDetailViewModel.replySpeaker` —
// substituted with a counter; production never reassigns it (the production
// wiring is `ReplyVoice.shared.cancel()` + `speak(sanitize: true)`).

#if os(macOS)

import XCTest
@testable import Conduck

@MainActor
final class ConversationDetailViewModelMacReplySpeakTests: XCTestCase {

    // MARK: - Gate honoured

    func testSpeaksFalseSkipsSpeaker() async {
        var spyCount = 0
        let vm = ConversationDetailViewModel(conversationID: UUID())
        vm.replySpeaker = { _ in
            spyCount += 1
        }

        await vm.dispatchReplySpeakIfNeeded(reply: "agent says hi", speaks: false)
        XCTAssertEqual(spyCount, 0,
                       "speaks=false must short-circuit before the speaker.")
    }

    func testSpeaksTrueInvokesSpeakerOnceWithRawReply() async {
        var spyCount = 0
        var capturedReply: String?
        let vm = ConversationDetailViewModel(conversationID: UUID())
        vm.replySpeaker = { reply in
            spyCount += 1
            capturedReply = reply
        }

        await vm.dispatchReplySpeakIfNeeded(reply: "**bold** agent reply", speaks: true)
        XCTAssertEqual(spyCount, 1,
                       "speaks=true must call the speaker exactly once.")
        XCTAssertEqual(capturedReply, "**bold** agent reply",
                       "The RAW reply must pass through unmodified — sanitization "
                       + "happens INSIDE ReplyVoice.speak(sanitize: true), never "
                       + "pre-applied by the VM.")
    }

    // MARK: - Default (compile-level)

    /// Compile-level guarantee that `sendUserTurn`'s `speaksReply` parameter is
    /// DEFAULTED: the pre-existing call shape (no `speaksReply:` label — every
    /// main-window / in-app / iOS call site) must keep compiling unchanged, so
    /// the window lane stays silent without edits (hard rule: it NEVER speaks).
    /// The closure is type-checked but never invoked — invoking would fire a
    /// real store append + gateway round-trip; the compiler enforcing the
    /// argument shape IS the assertion.
    func testSendUserTurnCompilesWithoutSpeaksReplyArgument() {
        let vm = ConversationDetailViewModel(conversationID: UUID())
        let preExistingShape: @MainActor (String) async -> Void = { text in
            await vm.sendUserTurn(
                text,
                modality: .text,
                attachments: [],
                stampsQuickPointer: false
            )
        }
        XCTAssertNotNil(preExistingShape)
    }
}

#endif
