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
        XCTAssertFalse(GatewayGate.isQuickCaptureReady(
            resolution: .brokenDefault(broken: openclaw, candidates: configured, pointerIsParked: false)
        ), "…and the quick lane, which has no picker, still cannot send.")
    }

    // MARK: - isQuickCaptureReady — the question the menu-bar popover asks
    //
    // The predicate takes the RESOLUTION, not a (configured, defaultRef) pair.
    // Set membership cannot express every state the pointer can be in: with no
    // default chosen the resolution projects to the built-in fallback, which may
    // itself be configured, so a membership test would answer "ready" for a
    // device whose next capture has nowhere honest to go.

    func testQuickCaptureReadyWhenTheDefaultIsConfigured() {
        XCTAssertTrue(GatewayGate.isQuickCaptureReady(resolution: .usable(openclaw)))
    }

    func testQuickCaptureNotReadyWhenTheDefaultIsMissingFromTheRoster() {
        XCTAssertFalse(GatewayGate.isQuickCaptureReady(
            resolution: .brokenDefault(broken: openclaw, candidates: [hermes], pointerIsParked: false)
        ), "A hotkey capture mints on the DEFAULT (Decision F), so a healthy sibling doesn't help it.")
    }

    func testQuickCaptureNotReadyWithNothingConfigured() {
        XCTAssertFalse(GatewayGate.isQuickCaptureReady(resolution: .nothingConfigured(pointer: openclaw)))
    }

    /// The state a membership test got WRONG, which is why the predicate moved to
    /// the resolution: nothing is chosen, several gateways work, and the shim ref
    /// lands on the built-in fallback that happens to be configured. "Ready" here
    /// would send a hotkey capture to a gateway the user never picked.
    func testQuickCaptureNotReadyWhenNoDefaultHasBeenChosen() {
        XCTAssertFalse(GatewayGate.isQuickCaptureReady(
            resolution: .selectionRequired(candidates: [.builtin(Constants.remoteAgentDefaultBackendDefault), hermes])
        ))
    }

    /// A Keychain blackout is not a refusal. The quick lane simply is not ready;
    /// nothing may be repaired or accused on this verdict.
    func testQuickCaptureNotReadyWhileTheReadingIsUnreliable() {
        XCTAssertFalse(GatewayGate.isQuickCaptureReady(resolution: .readingUnreliable(pointer: openclaw)))
    }

    /// A custom default is as valid as a built-in one — the popover gate must not
    /// quietly become built-ins-only.
    func testCustomDefaultCountsAsReady() {
        XCTAssertTrue(GatewayGate.isQuickCaptureReady(resolution: .usable(custom)))
    }

    /// The two repaired verdicts route: they persisted a pointer that IS a member
    /// of the configured set, so the quick lane may open on them.
    func testRepairedDefaultsCountAsReady() {
        XCTAssertTrue(GatewayGate.isQuickCaptureReady(
            resolution: .adopted(ref: hermes, replacing: openclaw)
        ))
        XCTAssertTrue(GatewayGate.isQuickCaptureReady(resolution: .bootstrapped(hermes)))
    }

    /// The ordering property the two flags are consumed under: quick-capture
    /// readiness is strictly stronger, so the popover can never be live while the
    /// window is showing the setup screen. If this ever inverts, the popover would
    /// invite a capture on a device the window says has no AI.
    ///
    /// Stated over the resolution, the property is: every verdict that can send
    /// carries a non-empty configured set by construction. The three sendable
    /// cases are exercised against the roster each of them implies.
    func testReadinessImpliesSendability() {
        let cases: [(DefaultGatewayResolution, [RemoteAgentRef])] = [
            (.usable(openclaw), [openclaw, hermes]),
            (.adopted(ref: hermes, replacing: openclaw), [hermes]),
            (.bootstrapped(custom), [custom]),
            (.brokenDefault(broken: openclaw, candidates: [hermes], pointerIsParked: false), [hermes]),
            (.selectionRequired(candidates: [openclaw, hermes]), [openclaw, hermes]),
            (.nothingConfigured(pointer: openclaw), []),
            (.readingUnreliable(pointer: openclaw), []),
            (.setupUnfinished(pointer: openclaw), [])
        ]
        for (resolution, configured) in cases where GatewayGate.isQuickCaptureReady(resolution: resolution) {
            XCTAssertTrue(GatewayGate.canSendAnywhere(configured: configured),
                          "Ready implies sendable — \(resolution)")
        }
    }
}
