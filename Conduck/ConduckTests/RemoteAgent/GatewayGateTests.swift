// SPDX-License-Identifier: Apache-2.0

// Conduck
// GatewayGateTests.swift
//
// Which surface may open, given a roster. Pure input → output, and the reason the
// predicates live outside their call sites at all: the macOS half of this decision
// is written in `MenuBarCoordinator`, which is `#if os(macOS)` and therefore never
// compiled — let alone run — by the authoritative iOS-Simulator suite. The window
// gated on the wrong one of these two questions for as long as that was true.
//
// SCOPE WARNING: these lock the PREDICATES, not the wiring. They cannot catch a
// surface asking the wrong question — only that each question keeps its meaning.
// The wiring is held by the doc comments at the four call sites (`MainWindowView`
// ×2, `DictationPopoverView` ×2) and by `MenuBarCoordinator.refreshConfiguredFlag`
// sampling both from one snapshot turn.

import XCTest
@testable import Conduck

final class GatewayGateTests: XCTestCase {

    private let openclaw = RemoteAgentRef.builtin(.openclaw)
    private let hermes = RemoteAgentRef.builtin(.hermes)
    private let custom = RemoteAgentRef.custom(UUID())

    // MARK: - canSendAnywhere — the question the picker-bearing surfaces ask

    func testNothingConfiguredCannotSend() {
        XCTAssertFalse(GatewayGate.canSendAnywhere(configured: []),
                       "The beginner empty state belongs to this state and only this state.")
    }

    func testOneConfiguredGatewayCanSend() {
        XCTAssertTrue(GatewayGate.canSendAnywhere(configured: [hermes]))
    }

    /// THE REGRESSION, as one assertion pair. The Mac window rendered "Bring your
    /// own AI" on a device with five verified gateways because it asked the quick
    /// lane's question — the stored default was a built-in a peer device had
    /// forgotten, which `defaultRemoteAgentRef()` honours on purpose. The two
    /// answers MUST be allowed to disagree here; the bug was one surface reading
    /// the other's.
    func testAConfiguredRosterCanSendEvenWhenTheDefaultCannot() {
        let configured = [hermes, custom]

        XCTAssertTrue(GatewayGate.canSendAnywhere(configured: configured),
                      "Five working gateways is not 'no AI configured', whatever the default says.")
        XCTAssertFalse(GatewayGate.isQuickCaptureReady(configured: configured, defaultRef: openclaw),
                       "…and the quick lane, which has no picker, still cannot send.")
    }

    // MARK: - isQuickCaptureReady — the question the menu-bar popover asks

    func testQuickCaptureReadyWhenTheDefaultIsConfigured() {
        XCTAssertTrue(GatewayGate.isQuickCaptureReady(
            configured: [openclaw, hermes],
            defaultRef: openclaw
        ))
    }

    func testQuickCaptureNotReadyWhenTheDefaultIsMissingFromTheRoster() {
        XCTAssertFalse(GatewayGate.isQuickCaptureReady(
            configured: [hermes],
            defaultRef: openclaw
        ), "A hotkey capture mints on the DEFAULT (Decision F), so a healthy sibling doesn't help it.")
    }

    func testQuickCaptureNotReadyWithNothingConfigured() {
        XCTAssertFalse(GatewayGate.isQuickCaptureReady(configured: [], defaultRef: openclaw))
    }

    /// A custom default is as valid as a built-in one — the popover gate must not
    /// quietly become built-ins-only.
    func testCustomDefaultCountsAsReady() {
        XCTAssertTrue(GatewayGate.isQuickCaptureReady(configured: [custom], defaultRef: custom))
    }

    /// The ordering property the two flags are consumed under: quick-capture
    /// readiness is strictly stronger, so the popover can never be live while the
    /// window is showing the setup screen. If this ever inverts, the popover would
    /// invite a capture on a device the window says has no AI.
    func testReadinessImpliesSendability() {
        for configured in [[], [openclaw], [hermes, custom], [openclaw, hermes, custom]] {
            for defaultRef in [openclaw, hermes, custom] {
                if GatewayGate.isQuickCaptureReady(configured: configured, defaultRef: defaultRef) {
                    XCTAssertTrue(GatewayGate.canSendAnywhere(configured: configured),
                                  "Ready implies sendable — configured: \(configured), default: \(defaultRef)")
                }
            }
        }
    }
}
