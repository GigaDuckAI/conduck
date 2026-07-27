// SPDX-License-Identifier: Apache-2.0

// Conduck
// SettingsViewModelGatewayValidationTests.swift
//
// The gateway editor's "Connected" row is an HONESTY claim: it may only appear
// when a live probe passed against the EXACT tuple (URL, token, auth scheme,
// cert pin) currently on screen. Three ways it used to lie — a user edit after a
// pass, a probe that lands after the user moved on, and a storage reload that
// swaps the buffers underneath the mark — plus the two ways a probe's verdict
// got lost on the way to the user (a swallowed error message, and a base URL
// that silently double-appends `/v1/chat/completions`).
//
// Everything that CAN be tested purely is: `normalizedGatewayBaseURL` and
// `friendlyGatewayMessage` are `static` + side-effect-free, so they need no VM,
// no App-Group/KVS wipe, and no network. The two stateful cases (edit-invalidates,
// stale-probe-discarded) drive the VM but stay off the Keychain (keyless refs)
// and off the network's happy path (a refused localhost port fails immediately).

import XCTest
@testable import Conduck

@MainActor
final class SettingsViewModelGatewayValidationTests: XCTestCase {

    private let openclaw: RemoteAgentRef = .builtin(.openclaw)

    // MARK: - Base-URL normalisation (pure)

    private func normalized(_ raw: String) -> String {
        guard let url = URL(string: raw) else {
            XCTFail("Test input is not a URL: \(raw)")
            return ""
        }
        return SettingsViewModel.normalizedGatewayBaseURL(url).absoluteString
    }

    /// A pasted full chat endpoint is the commonest bad input — the docs the user
    /// copied from name it, and the client appends the same suffix again.
    func testStripsTerminalChatCompletionsPath() {
        XCTAssertEqual(normalized("https://gw.example.test/v1/chat/completions"), "https://gw.example.test")
    }

    func testStripsTerminalModelsPath() {
        XCTAssertEqual(normalized("https://gw.example.test/v1/models"), "https://gw.example.test")
    }

    func testStripsTerminalV1Path() {
        XCTAssertEqual(normalized("https://gw.example.test/v1"), "https://gw.example.test")
    }

    func testStripsTrailingSlash() {
        XCTAssertEqual(normalized("https://gw.example.test/"), "https://gw.example.test")
        XCTAssertEqual(normalized("https://gw.example.test/v1/"), "https://gw.example.test")
    }

    /// A legitimate path PREFIX (a gateway mounted under a sub-path) must survive
    /// — stripping it would point every request at the wrong server root.
    func testPreservesLegitimatePathPrefix() {
        XCTAssertEqual(normalized("https://gw.example.test/openclaw"), "https://gw.example.test/openclaw")
    }

    func testStripsV1FromBeneathAPathPrefix() {
        XCTAssertEqual(normalized("https://gw.example.test/openclaw/v1"), "https://gw.example.test/openclaw")
        XCTAssertEqual(
            normalized("https://gw.example.test/openclaw/v1/chat/completions"),
            "https://gw.example.test/openclaw"
        )
    }

    /// Self-hosted gateways live on a non-standard port far more often than not.
    func testPreservesPort() {
        XCTAssertEqual(normalized("https://gw.example.test:18789/v1"), "https://gw.example.test:18789")
        XCTAssertEqual(normalized("https://gw.example.test:18789"), "https://gw.example.test:18789")
    }

    /// A host or path segment that merely CONTAINS the token is not the token.
    func testDoesNotStripNonTerminalOrPartialMatches() {
        XCTAssertEqual(normalized("https://v1.example.test"), "https://v1.example.test")
        XCTAssertEqual(normalized("https://gw.example.test/v1/models/extra"), "https://gw.example.test/v1/models/extra")
        XCTAssertEqual(normalized("https://gw.example.test/apiv1"), "https://gw.example.test/apiv1")
    }

    /// Query + fragment are meaningless on a base URL the client extends — they'd
    /// land BEFORE the appended path and produce an invalid request URL.
    func testDropsQueryAndFragment() {
        XCTAssertEqual(normalized("https://gw.example.test/v1?key=abc#frag"), "https://gw.example.test")
    }

    // MARK: - Error mapping (pure)

    private var genericMessage: String { String(localized: "Unexpected error. Try again.") }

    /// The three misconfigured-but-reachable gateway failures are the whole point
    /// of the diagnosis work — a generic shrug here throws the diagnosis away.
    func testNewGatewayErrorsAreNotSwallowedByTheGenericMessage() throws {
        for error in [AppError.remoteAgentEndpointUnexpectedResponse,
                      .remoteAgentEndpointNotFound,
                      .remoteAgentModelRequired] {
            let message = SettingsViewModel.friendlyGatewayMessage(for: error)
            let remedy = try XCTUnwrap(error.recoverySuggestion)
            XCTAssertNotEqual(message, genericMessage,
                              "\(error) must surface its own remedy, not the generic fallback.")
            XCTAssertEqual(message, remedy,
                           "\(error) must surface its recovery suggestion verbatim.")
        }
    }

    /// The `default:` arm falls back to the error's OWN description, so a failure
    /// the curated list never heard of still says something true.
    func testUncuratedErrorFallsBackToItsDescription() throws {
        let message = SettingsViewModel.friendlyGatewayMessage(for: .remoteAgentNotConfigured)
        let description = try XCTUnwrap(AppError.remoteAgentNotConfigured.errorDescription)
        XCTAssertEqual(message, description)
        XCTAssertNotEqual(message, genericMessage)
    }

    /// The fallback must never become a leak: `.apiFailure` carries raw server
    /// text, and its `errorDescription` is a curated string that drops it.
    func testFallbackNeverEchoesAServerPayload() {
        let message = SettingsViewModel.friendlyGatewayMessage(
            for: .apiFailure(message: "token sk-live-should-never-render")
        )
        XCTAssertFalse(message.contains("sk-live-should-never-render"),
                       "The description fallback must never echo an associated payload.")
    }

    // MARK: - Hosted vs self-hosted remedies

    /// A hosted provider is a service the user does NOT operate. Self-hosted
    /// remedies ("your gateway", "check the gateway logs") don't merely fail to
    /// help — they describe a machine that does not exist. And "Open Settings" is
    /// wrong on EVERY surface this mapper feeds: the token field is already on
    /// screen in both the editor and guided setup.
    func testHostedAuthFailureNeverGivesSelfHostedAdvice() {
        let message = SettingsViewModel.friendlyGatewayMessage(
            for: .remoteAgentAuthFailed, category: .hostedModel
        )
        for forbidden in ["gateway", "Open Settings", "bearer token"] {
            XCTAssertFalse(message.localizedCaseInsensitiveContains(forbidden),
                           "Hosted auth failure must not say “\(forbidden)”. Got: \(message)")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("API key"),
                      "Hosted auth failure must name what the user actually pasted.")
    }

    /// The self-hosted lane keeps its gateway vocabulary, but loses the misplaced
    /// "Open Settings" — the user is standing in the editor already.
    func testSelfHostedAuthFailureDropsTheOpenSettingsInstruction() {
        let message = SettingsViewModel.friendlyGatewayMessage(
            for: .remoteAgentAuthFailed, category: .selfHostedAgent
        )
        XCTAssertFalse(message.localizedCaseInsensitiveContains("Open Settings"),
                       "The field is already on screen. Got: \(message)")
        XCTAssertTrue(message.localizedCaseInsensitiveContains("token"),
                      "Self-hosted lane still speaks in tokens. Got: \(message)")
    }

    /// A truncated paste is the commonest cause of a 401 on a hosted lane. The hint
    /// must name the shape so the user checks the CLIPBOARD, not the dashboard.
    func testHostedAuthFailureFlagsAMalformedKey() {
        let message = SettingsViewModel.friendlyGatewayMessage(
            for: .remoteAgentAuthFailed, category: .hostedModel, keyShapeLooksWrong: true
        )
        XCTAssertTrue(message.contains("sk-or-"),
                      "A shape hint that doesn't name the shape is not a hint. Got: \(message)")
    }

    /// The hint is ADVISORY. It rides an already-failed probe and must never be the
    /// message on its own — a well-shaped key that a provider rejects gets the plain
    /// remedy, and (critically) the hint never appears on a SUCCESS.
    func testKeyShapeHintOnlyRidesAnAuthFailure() {
        let wellShaped = SettingsViewModel.friendlyGatewayMessage(
            for: .remoteAgentAuthFailed, category: .hostedModel, keyShapeLooksWrong: false
        )
        XCTAssertFalse(wellShaped.contains("sk-or-"),
                       "A correctly-shaped key must not be accused of being malformed.")

        // A non-auth failure ignores the flag entirely — a bad shape is irrelevant
        // when the provider never got to check the key.
        let unreachable = SettingsViewModel.friendlyGatewayMessage(
            for: .remoteAgentUnreachable, category: .hostedModel, keyShapeLooksWrong: true
        )
        XCTAssertFalse(unreachable.contains("sk-or-"),
                       "An unreachable provider says nothing about key shape. Got: \(unreachable)")
    }

    /// The hosted lane cannot be told to check a server it doesn't run.
    func testHostedTransportAndServerFailuresAreProviderShaped() {
        let unreachable = SettingsViewModel.friendlyGatewayMessage(
            for: .remoteAgentUnreachable, category: .hostedModel
        )
        XCTAssertFalse(unreachable.localizedCaseInsensitiveContains("gateway is running"),
                       "Nothing for the user to start. Got: \(unreachable)")

        let serverError = SettingsViewModel.friendlyGatewayMessage(
            for: .remoteAgentServerError, category: .hostedModel
        )
        XCTAssertFalse(serverError.localizedCaseInsensitiveContains("gateway logs"),
                       "The user cannot read OpenRouter's logs. Got: \(serverError)")

        // …while the self-hosted lane keeps exactly that advice, because there it
        // is the correct and actionable thing to do.
        let selfHosted = SettingsViewModel.friendlyGatewayMessage(
            for: .remoteAgentServerError, category: .selfHostedAgent
        )
        XCTAssertTrue(selfHosted.localizedCaseInsensitiveContains("gateway logs"))
    }

    /// 429 is routine on a hosted lane's free models. Its bare `errorDescription`
    /// states the symptom and withholds the fix; the remedy carries the wait.
    func testRateLimitAndCreditFailuresSurfaceTheirRemedy() throws {
        for error in [AppError.remoteAgentRateLimited, .remoteAgentOutOfCredits] {
            let message = SettingsViewModel.friendlyGatewayMessage(for: error, category: .hostedModel)
            let remedy = try XCTUnwrap(error.recoverySuggestion)
            XCTAssertEqual(message, remedy,
                           "\(error) must surface its remedy, not the symptom-only description.")
            XCTAssertNotEqual(message, error.errorDescription)
        }
    }

    // MARK: - Stale green — every user edit retracts the live verdict

    func testURLEditClearsLiveValidation() {
        let vm = SettingsViewModel()
        vm.remoteAgentLiveValidated.insert(openclaw)
        vm.remoteAgentLastErrorCodes[openclaw] = AppError.remoteAgentEndpointNotFound.errorCode

        vm.setRemoteAgentURLBuffer("https://edited.example.test", for: openclaw)

        XCTAssertFalse(vm.remoteAgentLiveValidated.contains(openclaw),
                       "Editing the URL must retract a verdict earned by a DIFFERENT URL.")
        XCTAssertNil(vm.remoteAgentLastErrorCodes[openclaw],
                     "The remedy for the previous failure must not outlive the config that caused it.")
    }

    func testCertFingerprintEditClearsLiveValidation() {
        let vm = SettingsViewModel()
        vm.remoteAgentLiveValidated.insert(openclaw)
        vm.setRemoteAgentCertFingerprintBuffer("aa:bb", for: openclaw)
        XCTAssertFalse(vm.remoteAgentLiveValidated.contains(openclaw))
    }

    func testAuthSchemeToggleClearsLiveValidation() {
        let vm = SettingsViewModel()
        vm.remoteAgentLiveValidated.insert(openclaw)
        vm.setRemoteAgentAuthSchemeBuffer(.none, for: openclaw)
        XCTAssertFalse(vm.remoteAgentLiveValidated.contains(openclaw))
    }

    /// The token is the entry sheet's private draft — the VM only hears about it
    /// on COMMIT, which is exactly when the previous verdict stops being true.
    func testSecretCommitClearsLiveValidation() {
        let vm = SettingsViewModel()
        vm.remoteAgentLiveValidated.insert(openclaw)
        vm.noteRemoteAgentSecretEdited(for: openclaw)
        XCTAssertFalse(vm.remoteAgentLiveValidated.contains(openclaw))
    }

    /// A no-op write (SwiftUI re-emits a binding with an unchanged value) must NOT
    /// retract a verdict — otherwise a passing test would flicker off on re-render.
    func testUnchangedURLWriteKeepsLiveValidation() {
        let vm = SettingsViewModel()
        vm.setRemoteAgentURLBuffer("https://gw.example.test", for: openclaw)
        vm.remoteAgentLiveValidated.insert(openclaw)

        vm.setRemoteAgentURLBuffer("https://gw.example.test", for: openclaw)

        XCTAssertTrue(vm.remoteAgentLiveValidated.contains(openclaw),
                      "An identical re-write is not an edit.")
    }

    // MARK: - The in-flight race

    /// A probe that was overtaken by a user edit must apply NOTHING — not its
    /// verdict, not its error code, and (the subtle half) not its stale URL
    /// write-back over what the user has since typed. Driven against a refused
    /// localhost port so the probe fails immediately without a network wait.
    func testProbeResultDiscardedWhenUserEditsMidFlight() async {
        let vm = SettingsViewModel()
        // Drain the init-load — an async reload landing mid-test would replace the
        // buffers from storage and confound what the probe did or didn't write.
        await vm.loadSettings()
        await Task.yield()
        let probe = Task {
            await vm.validateRemoteAgent(
                ref: openclaw,
                url: "https://127.0.0.1:1",
                token: "tok_stale",
                fingerprint: nil
            )
        }
        // Suspend until the probe is actually on the wire (`.checking`), so the
        // edit below lands mid-flight rather than before the probe starts.
        while vm.remoteAgentRowState(for: openclaw) != .checking {
            await Task.yield()
        }

        vm.setRemoteAgentURLBuffer("https://typed-after.example.test", for: openclaw)
        await probe.value

        XCTAssertEqual(vm.remoteAgentURLStrings[openclaw], "https://typed-after.example.test",
                       "The superseded probe must not write its stale URL back over the user's typing.")
        XCTAssertNil(vm.remoteAgentLastErrorCodes[openclaw],
                     "The superseded probe's failure describes a config the user has already moved past.")
        XCTAssertFalse(vm.remoteAgentLiveValidated.contains(openclaw))
        XCTAssertNotEqual(vm.remoteAgentRowState(for: openclaw), .checking,
                          "A dropped verdict must still release the spinner it put on screen.")
    }
}
