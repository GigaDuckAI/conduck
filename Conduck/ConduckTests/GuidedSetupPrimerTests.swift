// SPDX-License-Identifier: Apache-2.0

// Conduck
// GuidedSetupPrimerTests.swift
//
// Coverage for the guided-setup ENTRY wiring:
//   1. The pure entry-step decision (`GuidedGatewaySetupView.initialStep`) —
//      the primer precedes the chooser ONLY for an eligible unconfigured
//      first-timer (`showPrimer`), and a lane deep-link never shows it;
//      plus quick connect's setup-state branch, where an unconfigured CUSTOM
//      target enters its lane at the fork while a configured one keeps the
//      one-screen re-pair, and neither built-in target branches at all.
//      Extracted as a pure static so it's testable without a View or a live
//      platform.
//   2. The fork's gateway-name resolution (`GuidedGatewaySetupView.forkGatewayName`)
//      — which quick-connect targets name their gateway on the fork screen, and
//      (the case worth the test) which resolve to nil rather than a blank title.
//   3. The phantom-default fix (`SettingsViewModel.defaultSelectorDisplayName`) —
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

    /// Quick connect on a custom gateway that was NEVER set up enters the lane at
    /// its FORK — the screen that asks whether a setup code already exists. The
    /// command screen is the wrong door for half of who arrives (it is about
    /// CREATING a code), and the readiness screen re-asks a question a code already
    /// answers.
    func testUnconfiguredCustomQuickConnectStartsAtFork() {
        let path = GatewayPath.quickConnect(target: .custom(UUID()), needsSetup: true)
        XCTAssertEqual(GuidedGatewaySetupView.initialStep(initialPath: path, showPrimer: false), .fork(.custom))
        // Never the primer: a deep-link into a specific gateway is not a first-run
        // orientation, whatever the caller resolved `showPrimer` to.
        XCTAssertEqual(GuidedGatewaySetupView.initialStep(initialPath: path, showPrimer: true), .fork(.custom))
    }

    /// A CONFIGURED custom gateway keeps the one-screen re-pair: straight to the
    /// command. This is the half of quick connect whose promise is speed.
    func testConfiguredCustomQuickConnectStillStartsAtCommands() {
        let path = GatewayPath.quickConnect(target: .custom(UUID()), needsSetup: false)
        XCTAssertEqual(GuidedGatewaySetupView.initialStep(initialPath: path, showPrimer: false), .commands(.custom))
    }

    /// Built-in (OpenClaw / Hermes) quick connect is UNCHANGED by the custom-lane
    /// readiness routing — it opens on the command in either setup state. Its lane's
    /// readiness step is a single "Yes, it's running" CTA with no second answer, so
    /// entering there would add a screen without adding a decision.
    func testBuiltinQuickConnectIgnoresNeedsSetup() {
        for needsSetup in [true, false] {
            XCTAssertEqual(
                GuidedGatewaySetupView.initialStep(
                    initialPath: .quickConnect(target: .builtin(.openclaw), needsSetup: needsSetup),
                    showPrimer: false
                ),
                .commands(.fullAgent),
                "built-in quick connect must not branch on needsSetup (\(needsSetup))"
            )
        }
    }

    /// OpenRouter has no pairing lane at all, so a (never-constructed) hosted quick
    /// connect maps defensively to its own step — in BOTH setup states, so the new
    /// `needsSetup` branch can't route it to a meaningless command screen.
    func testHostedQuickConnectMapsToHostedStepRegardlessOfNeedsSetup() {
        for needsSetup in [true, false] {
            XCTAssertEqual(
                GuidedGatewaySetupView.initialStep(
                    initialPath: .quickConnect(target: .builtin(.openrouter), needsSetup: needsSetup),
                    showPrimer: false
                ),
                .hostedModel,
                "OpenRouter quick connect must never reach a command step (\(needsSetup))"
            )
        }
    }

    // MARK: - Fork gateway name (the deep-linked fork's title)

    /// A named custom target names itself on the fork, so the screen confirms WHICH
    /// gateway is being paired.
    func testForkNamesTheDeepLinkedCustomGateway() {
        let id = UUID()
        XCTAssertEqual(
            GuidedGatewaySetupView.forkGatewayName(
                initialPath: .quickConnect(target: .custom(id), needsSetup: true),
                customs: [CustomGateway(id: id, name: "LiteLLM")]
            ),
            "LiteLLM"
        )
    }

    /// THE regression this resolver exists for. A custom gateway minted by "+ Add
    /// custom gateway" and taken straight into Quick connect has a roster entry whose
    /// `name` is EMPTY — not missing — so any resolver keying off "is the entry
    /// there?" hands back "" and the fork renders the title "Connect ". nil instead,
    /// which falls back to the generic lane title.
    func testForkFallsBackForUnnamedDraft() {
        let id = UUID()
        for name in ["", "   "] {
            XCTAssertNil(
                GuidedGatewaySetupView.forkGatewayName(
                    initialPath: .quickConnect(target: .custom(id), needsSetup: true),
                    customs: [CustomGateway(id: id, name: name)]
                ),
                "an unnamed draft must not produce a blank title (name: \(name.debugDescription))"
            )
        }
    }

    /// A target with no roster entry at all resolves to nil, NOT to the generic
    /// "Custom gateway" label — "Connect Custom gateway" reads worse than the lane
    /// title it would replace.
    func testForkFallsBackWhenRosterEntryMissing() {
        XCTAssertNil(
            GuidedGatewaySetupView.forkGatewayName(
                initialPath: .quickConnect(target: .custom(UUID()), needsSetup: true),
                customs: []
            )
        )
    }

    /// Every non-custom entry keeps the lane title. Built-ins never reach the fork
    /// with a target (they enter on commands), and the chooser's fork has no gateway
    /// chosen yet — so there is nothing to name in any of these.
    func testForkNamesNothingForNonCustomEntries() {
        let paths: [GatewayPath?] = [
            nil,
            .later,
            .selfHosted,
            .hostedModel,
            .quickConnect(target: .builtin(.openclaw), needsSetup: true),
            .quickConnect(target: .builtin(.openrouter), needsSetup: false)
        ]
        for path in paths {
            XCTAssertNil(
                GuidedGatewaySetupView.forkGatewayName(
                    initialPath: path,
                    customs: [CustomGateway(id: UUID(), name: "LiteLLM")]
                )
            )
        }
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
