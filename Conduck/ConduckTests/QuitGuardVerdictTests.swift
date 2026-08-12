// SPDX-License-Identifier: Apache-2.0

// Conduck
// QuitGuardVerdictTests.swift
//
// The macOS quit guard's DECISION and its WORDING, asserted without driving
// AppKit modality — which is the whole reason `QuitGuard.verdict` is pure.
//
// What these lock:
//   • the non-nagging rules — nothing in flight quits silently, and a system
//     power-off quits silently even mid-turn (a modal panel would stall the
//     logout until macOS times the app out);
//   • the three copy shapes, and that thread metadata is only used when exactly
//     ONE conversation is live;
//   • the body's deliberate silence about the message being saved.
//
// `#if os(macOS)` because `QuitGuard` is — the guard exists for the one platform
// whose converse hop is a foreground URLSession.

#if os(macOS)

import XCTest
@testable import Conduck

@MainActor
final class QuitGuardVerdictTests: XCTestCase {

    // MARK: - Quit silently

    func testNothingInFlightQuitsWithNoUI() {
        XCTAssertEqual(
            QuitGuard.verdict(
                liveCount: 0,
                singleThreadTitle: "Kitchen renovation",
                singleGatewayName: "OpenClaw",
                powerOffInProgress: false
            ),
            .quitNow
        )
    }

    func testPowerOffQuitsEvenWithLiveTurns() {
        // R9: a modal panel during logout/restart blocks the whole sequence
        // until macOS times the app out, and nobody is there to answer it.
        XCTAssertEqual(
            QuitGuard.verdict(
                liveCount: 3,
                singleThreadTitle: nil,
                singleGatewayName: nil,
                powerOffInProgress: true
            ),
            .quitNow
        )
    }

    func testNegativeLiveCountIsTreatedAsIdle() {
        XCTAssertEqual(
            QuitGuard.verdict(
                liveCount: -1,
                singleThreadTitle: nil,
                singleGatewayName: nil,
                powerOffInProgress: false
            ),
            .quitNow
        )
    }

    // MARK: - Ask

    private func prompt(
        liveCount: Int,
        title: String?,
        gateway: String?
    ) -> QuitGuard.Prompt? {
        guard case .ask(let prompt) = QuitGuard.verdict(
            liveCount: liveCount,
            singleThreadTitle: title,
            singleGatewayName: gateway,
            powerOffInProgress: false
        ) else { return nil }
        return prompt
    }

    func testSingleKnownThreadNamesGatewayAndTitle() throws {
        let prompt = try XCTUnwrap(prompt(liveCount: 1, title: "Kitchen renovation", gateway: "OpenClaw"))
        XCTAssertEqual(prompt.messageText, "OpenClaw is still working on “Kitchen renovation”")
    }

    func testSingleUnknownThreadFallsBackToTheGenericLine() throws {
        let noTitle = try XCTUnwrap(prompt(liveCount: 1, title: nil, gateway: "OpenClaw"))
        XCTAssertEqual(noTitle.messageText, "Your personal AI is still answering")

        let noGateway = try XCTUnwrap(prompt(liveCount: 1, title: "Kitchen renovation", gateway: nil))
        XCTAssertEqual(noGateway.messageText, "Your personal AI is still answering")
    }

    func testBlankMetadataIsNotAName() throws {
        // A whitespace-only title would render as `… working on “  ”`.
        let prompt = try XCTUnwrap(prompt(liveCount: 1, title: "   ", gateway: "OpenClaw"))
        XCTAssertNil(prompt.threadTitle)
        XCTAssertEqual(prompt.messageText, "Your personal AI is still answering")
    }

    func testMultipleLiveTurnsDropThreadMetadata() throws {
        // Naming ONE thread while two are live would be a lie about the second.
        let prompt = try XCTUnwrap(prompt(liveCount: 2, title: "Kitchen renovation", gateway: "OpenClaw"))
        XCTAssertNil(prompt.threadTitle)
        XCTAssertNil(prompt.gatewayName)
        XCTAssertEqual(prompt.messageText, "2 conversations are still waiting on answers")
    }

    // MARK: - Copy

    func testBodyPromisesNothingAboutTheMessageBeingSaved() throws {
        // Deliberate: the user turn IS durable, but the REPLY is what quitting
        // destroys — a reassurance here would make the alert feel dismissible.
        let prompt = try XCTUnwrap(prompt(liveCount: 1, title: nil, gateway: nil))
        XCTAssertEqual(
            prompt.informativeText,
            "Quitting now ends the request. The answer can't be recovered — you'd have to ask again."
        )
        XCTAssertFalse(prompt.informativeText.lowercased().contains("saved"))
    }

    func testButtonTitles() throws {
        let prompt = try XCTUnwrap(prompt(liveCount: 1, title: nil, gateway: nil))
        XCTAssertEqual(prompt.quitButtonTitle, "Quit Anyway")
        XCTAssertEqual(prompt.keepWaitingButtonTitle, "Keep Waiting")
    }

    // MARK: - Registry integration

    func testAskFollowsTheRegistrysLiveCount() {
        InFlightTurnRegistry._resetForTesting()
        let id = UUID()
        let token = InFlightTurnRegistry.shared.noteBegan(id, lane: .viewModel, isCancellable: true)

        // `liveCount` reads the real wall clock, so the claim must be minted at
        // real "now" — which `noteBegan`'s default argument does.
        XCTAssertEqual(InFlightTurnRegistry.shared.liveCount, 1)
        guard case .ask = QuitGuard.verdict(
            liveCount: InFlightTurnRegistry.shared.liveCount,
            singleThreadTitle: nil,
            singleGatewayName: nil,
            powerOffInProgress: false
        ) else { return XCTFail("a live claim must ask before quitting") }

        // The mid-modal auto-resolve reads exactly this: the last claim released
        // means the only reason to stop the user has evaporated.
        InFlightTurnRegistry.shared.noteEnded(token)
        XCTAssertEqual(InFlightTurnRegistry.shared.liveCount, 0)
        XCTAssertEqual(
            QuitGuard.verdict(
                liveCount: InFlightTurnRegistry.shared.liveCount,
                singleThreadTitle: nil,
                singleGatewayName: nil,
                powerOffInProgress: false
            ),
            .quitNow
        )
        InFlightTurnRegistry._resetForTesting()
    }
}

#endif
