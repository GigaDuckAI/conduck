// Conduck
// GuidedSetupPrimerTests.swift
//
// Coverage for the first-run gateway PRIMER wiring:
//   1. The pure entry-step decision (`GuidedGatewaySetupView.initialStep`) — the
//      primer precedes the chooser ONLY for an eligible unconfigured first-timer
//      (`showPrimer`), and a lane deep-link never shows it. Extracted as a pure
//      static so it's testable without a View or a live platform.
//   2. The phantom-default fix (`SettingsViewModel.defaultSelectorDisplayName`) —
//      "Not configured" when nothing is configured, else the default's name.

import XCTest
@testable import Conduck

final class GuidedSetupStartTests: XCTestCase {

    /// Eligible unconfigured first-timer (`showPrimer`) entering via the chooser
    /// lane (`nil`/`.later`) → the PRIMER precedes the chooser.
    func testPrimerShownForEligibleFirstTimer() {
        XCTAssertEqual(GuidedGatewaySetupView.initialStep(initialPath: nil, showPrimer: true), .primer)
        XCTAssertEqual(GuidedGatewaySetupView.initialStep(initialPath: .later, showPrimer: true), .primer)
    }

    /// Ineligible (primer already seen, OR a gateway already configured — both
    /// resolved by the caller into `showPrimer == false`) → straight to the chooser.
    func testChooserWhenPrimerNotEligible() {
        XCTAssertEqual(GuidedGatewaySetupView.initialStep(initialPath: nil, showPrimer: false), .chooser)
        XCTAssertEqual(GuidedGatewaySetupView.initialStep(initialPath: .later, showPrimer: false), .chooser)
    }

    /// A lane deep-link jumps straight to that lane and NEVER shows the primer or
    /// the chooser — regardless of `showPrimer`.
    func testLaneDeepLinksNeverShowPrimer() {
        XCTAssertEqual(GuidedGatewaySetupView.initialStep(initialPath: .selfHosted, showPrimer: true), .fork(.fullAgent))
        XCTAssertEqual(GuidedGatewaySetupView.initialStep(initialPath: .selfHosted, showPrimer: false), .fork(.fullAgent))
        XCTAssertEqual(GuidedGatewaySetupView.initialStep(initialPath: .hostedModel, showPrimer: true), .hostedModel)
        XCTAssertEqual(GuidedGatewaySetupView.initialStep(initialPath: .hostedModel, showPrimer: false), .hostedModel)
    }
}

@MainActor
final class DefaultSelectorDisplayNameTests: XCTestCase {

    /// The "Default for new chats" selector shows "Not configured" when the
    /// configured set is empty — NOT a phantom builtin default (e.g. "OpenClaw").
    /// The synchronous set + assert can't race the VM's async load task (both are
    /// MainActor-isolated; no `await` yields the actor mid-test).
    func testShowsNotConfiguredWhenNothingConfigured() {
        let vm = SettingsViewModel()
        vm.configuredRemoteAgentRefSet = []

        let notConfigured = String(localized: "settings.personalAI.default.notConfigured", defaultValue: "Not configured")
        XCTAssertEqual(vm.defaultSelectorDisplayName, notConfigured)
    }

    /// With at least one configured gateway the selector shows the default ref's
    /// real display name (i.e. it defers to `defaultRemoteAgentDisplayName`).
    func testShowsDefaultNameWhenConfigured() {
        let vm = SettingsViewModel()
        vm.configuredRemoteAgentRefSet = [.builtin(.openclaw)]

        XCTAssertEqual(vm.defaultSelectorDisplayName, vm.defaultRemoteAgentDisplayName)
        let notConfigured = String(localized: "settings.personalAI.default.notConfigured", defaultValue: "Not configured")
        XCTAssertNotEqual(vm.defaultSelectorDisplayName, notConfigured)
    }
}
