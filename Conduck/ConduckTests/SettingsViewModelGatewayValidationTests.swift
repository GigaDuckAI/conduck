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

    /// Stand-in instance names. The editor is always editing ONE named AI, so
    /// every call below supplies the name it would have on screen — a hosted
    /// built-in's registry literal, or a self-hosted gateway's own label.
    private static let hostedName = "OpenRouter"
    private static let selfHostedName = "OpenClaw"

    /// The capability snapshots the editor hands the mapper, RESOLVED from a ref
    /// exactly as `validateRemoteAgent` does. Not hand-built: a snapshot
    /// assembled here could drift from the descriptors and would then prove the
    /// mapper right about a lane that does not exist.
    ///
    /// `selfHostedContext` is `.custom` rather than a built-in, because a custom
    /// is the self-hosted shape that HAS a model field — the same shape
    /// `RemoteAgentFailureContext.neutral` carries, so the assertions below that
    /// compare against the parameterless `recoverySuggestion` stay exact.
    /// `testModelHiddenLanesGetNoModelImperativeFromTheEditor` covers the other
    /// self-hosted shape, where the field is hidden.
    private static let hostedContext = RemoteAgentFailureContext.resolve(.builtin(.openrouter))
    private static let selfHostedContext = RemoteAgentFailureContext.custom

    /// The three misconfigured-but-reachable gateway failures are the whole point
    /// of the diagnosis work — a generic shrug here throws the diagnosis away.
    func testNewGatewayErrorsAreNotSwallowedByTheGenericMessage() throws {
        for error in [AppError.remoteAgentEndpointUnexpectedResponse,
                      .remoteAgentEndpointNotFound,
                      .remoteAgentModelRequired] {
            let message = SettingsViewModel.friendlyGatewayMessage(
                for: error, named: Self.selfHostedName, context: Self.selfHostedContext
            )
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
        let message = SettingsViewModel.friendlyGatewayMessage(
            for: .remoteAgentNotConfigured, named: Self.selfHostedName,
            context: Self.selfHostedContext
        )
        let description = try XCTUnwrap(AppError.remoteAgentNotConfigured.errorDescription)
        XCTAssertEqual(message, description)
        XCTAssertNotEqual(message, genericMessage)
    }

    /// The fallback must never become a leak: `.apiFailure` carries raw server
    /// text, and its `errorDescription` is a curated string that drops it.
    func testFallbackNeverEchoesAServerPayload() {
        let message = SettingsViewModel.friendlyGatewayMessage(
            for: .apiFailure(message: "token sk-live-should-never-render"),
            named: Self.selfHostedName,
            context: Self.selfHostedContext
        )
        XCTAssertFalse(message.contains("sk-live-should-never-render"),
                       "The description fallback must never echo an associated payload.")
    }

    // MARK: - The connection test is not a converse turn

    /// Every condition the editor answers with its OWN wording: unreachable,
    /// timeout, server error, unexpected response, refused credential — the five
    /// whose shared, converse-turn copy carries assumptions that are FALSE on
    /// this screen. Eight cases rather than five, because the generic transport
    /// errors alias onto the first two. The rest of the taxonomy delegates on
    /// purpose, and `testNewGatewayErrorsAreNotSwallowedByTheGenericMessage`
    /// above is what holds that delegation in place.
    private static let editorScopedErrors: [AppError] = [
        .remoteAgentUnreachable,
        .noInternetConnection,
        .networkError(URLError(.notConnectedToInternet)),
        .remoteAgentTimeout,
        .requestTimeout,
        .remoteAgentServerError,
        .remoteAgentInvalidResponse,
        .remoteAgentAuthFailed,
    ]

    /// Claims that are true of a CONVERSE TURN and false of this screen's probe.
    ///
    /// `validateRemoteAgent` sends a read-only GET for the model list (`/v1/key`
    /// on the hosted lane). It is idempotent, it costs nothing, it runs no tools,
    /// and its verdict is definitive about arrival — finding out whether the
    /// request arrives is the whole reason the button exists. So a warning about
    /// repeated work, spend, tool side effects or uncertain delivery is not merely
    /// unhelpful here: it argues against the one action the screen invites.
    private static let converseTurnOnlyClaims = [
        "repeat the work",
        "the cost",
        "could run tools",
        "can't tell whether the request arrived",
        "may still be working",
    ]

    func testEditorCopyMakesNoConverseTurnClaim() {
        for error in Self.editorScopedErrors {
            for (context, name) in [(Self.selfHostedContext, Self.selfHostedName),
                                     (Self.hostedContext, Self.hostedName)] {
                let message = SettingsViewModel.friendlyGatewayMessage(
                    for: error, named: name, context: context
                )
                for claim in Self.converseTurnOnlyClaims {
                    XCTAssertFalse(
                        message.localizedCaseInsensitiveContains(claim),
                        """
                        Code \(error.errorCode) says “\(claim)” on the \(context.category) connection test. \
                        The probe is a read-only model-list GET: it repeats no work, spends nothing, \
                        runs no tools, and its result IS definitive about arrival. Got: \(message)
                        """
                    )
                }
            }
        }
    }

    /// The editor is editing ONE named AI, and its copy says which. A message
    /// that de-names the instance was the regression that came with delegating
    /// this screen to the lane-agnostic layer: "Couldn't reach OpenRouter" became
    /// "Check your internet connection", which could be about anything.
    func testEditorCopyNamesTheInstanceItIsEditing() {
        for error in Self.editorScopedErrors {
            for (context, name) in [(Self.selfHostedContext, Self.selfHostedName),
                                     (Self.hostedContext, Self.hostedName)] {
                let message = SettingsViewModel.friendlyGatewayMessage(
                    for: error, named: name, context: context
                )
                XCTAssertTrue(
                    message.contains(name),
                    """
                    Code \(error.errorCode) on the \(context.category) lane doesn't name the AI being \
                    edited. Got: \(message)
                    """
                )
            }
        }
    }

    /// Non-vacuity for the two rules above: the name is INTERPOLATED, not a
    /// coincidence of the stand-in strings. A second name must move the copy.
    func testEditorCopyTracksTheNameItIsGiven() {
        let first = SettingsViewModel.friendlyGatewayMessage(
            for: .remoteAgentUnreachable, named: "hermes-vps-01", context: Self.selfHostedContext
        )
        let second = SettingsViewModel.friendlyGatewayMessage(
            for: .remoteAgentUnreachable, named: "ollama-desk", context: Self.selfHostedContext
        )
        XCTAssertNotEqual(first, second, "The instance name must be interpolated, not decorative.")
        XCTAssertTrue(first.contains("hermes-vps-01"))
        XCTAssertTrue(second.contains("ollama-desk"))
    }

    // MARK: - Hosted vs self-hosted remedies

    /// A hosted provider is a service the user does NOT operate. Self-hosted
    /// remedies ("your gateway", "check the gateway logs") don't merely fail to
    /// help — they describe a machine that does not exist. And "Open Settings" is
    /// wrong on EVERY surface this mapper feeds: the token field is already on
    /// screen in both the editor and guided setup.
    func testHostedAuthFailureNeverGivesSelfHostedAdvice() {
        let message = SettingsViewModel.friendlyGatewayMessage(
            for: .remoteAgentAuthFailed, named: Self.hostedName, context: Self.hostedContext
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
    ///
    /// It says "key", never "token": user-facing secrets vocabulary is exactly two
    /// words — "key" for the chat/API secret on both lanes, "password" for the file
    /// lane. The wire keys named `token` and `credential` are untouched; this is
    /// only what a human reads. A keyless gateway's owner sent hunting for a
    /// "bearer token" is looking for something they deliberately do not have.
    func testSelfHostedAuthFailureDropsTheOpenSettingsInstruction() {
        let message = SettingsViewModel.friendlyGatewayMessage(
            for: .remoteAgentAuthFailed, named: Self.selfHostedName, context: Self.selfHostedContext
        )
        XCTAssertFalse(message.localizedCaseInsensitiveContains("Open Settings"),
                       "The field is already on screen. Got: \(message)")
        XCTAssertTrue(message.localizedCaseInsensitiveContains("key"),
                      "Self-hosted lane still names the secret the user pasted. Got: \(message)")
        XCTAssertFalse(message.localizedCaseInsensitiveContains("bearer token"),
                       "“bearer token” is retired from user-facing copy. Got: \(message)")
    }

    /// A truncated paste is the commonest cause of a 401 on a hosted lane. The hint
    /// must name the shape so the user checks the CLIPBOARD, not the dashboard.
    func testHostedAuthFailureFlagsAMalformedKey() {
        let message = SettingsViewModel.friendlyGatewayMessage(
            for: .remoteAgentAuthFailed, named: Self.hostedName,
            context: Self.hostedContext, keyShapeLooksWrong: true
        )
        XCTAssertTrue(message.contains("sk-or-"),
                      "A shape hint that doesn't name the shape is not a hint. Got: \(message)")
    }

    /// The hint is ADVISORY. It rides an already-failed probe and must never be the
    /// message on its own — a well-shaped key that a provider rejects gets the plain
    /// remedy, and (critically) the hint never appears on a SUCCESS.
    func testKeyShapeHintOnlyRidesAnAuthFailure() {
        let wellShaped = SettingsViewModel.friendlyGatewayMessage(
            for: .remoteAgentAuthFailed, named: Self.hostedName,
            context: Self.hostedContext, keyShapeLooksWrong: false
        )
        XCTAssertFalse(wellShaped.contains("sk-or-"),
                       "A correctly-shaped key must not be accused of being malformed.")

        // A non-auth failure ignores the flag entirely — a bad shape is irrelevant
        // when the provider never got to check the key.
        let unreachable = SettingsViewModel.friendlyGatewayMessage(
            for: .remoteAgentUnreachable, named: Self.hostedName,
            context: Self.hostedContext, keyShapeLooksWrong: true
        )
        XCTAssertFalse(unreachable.contains("sk-or-"),
                       "An unreachable provider says nothing about key shape. Got: \(unreachable)")
    }

    /// The hosted lane cannot be told to check a server it doesn't run.
    func testHostedTransportAndServerFailuresAreProviderShaped() {
        let unreachable = SettingsViewModel.friendlyGatewayMessage(
            for: .remoteAgentUnreachable, named: Self.hostedName, context: Self.hostedContext
        )
        XCTAssertFalse(unreachable.localizedCaseInsensitiveContains("gateway is running"),
                       "Nothing for the user to start. Got: \(unreachable)")

        let serverError = SettingsViewModel.friendlyGatewayMessage(
            for: .remoteAgentServerError, named: Self.hostedName, context: Self.hostedContext
        )
        XCTAssertFalse(serverError.localizedCaseInsensitiveContains("gateway logs"),
                       "The user cannot read OpenRouter's logs. Got: \(serverError)")

        // …while the self-hosted lane keeps exactly that advice, because there it
        // is the correct and actionable thing to do.
        let selfHosted = SettingsViewModel.friendlyGatewayMessage(
            for: .remoteAgentServerError, named: Self.selfHostedName, context: Self.selfHostedContext
        )
        XCTAssertTrue(selfHosted.localizedCaseInsensitiveContains("gateway logs"))
    }

    // MARK: - The editor dispatches on capability, not on the lane flag

    /// The delegated model arms must follow `RemoteAgentModelPolicy`, and the
    /// editor must hand them a context RESOLVED FROM THE REF to make that
    /// possible. Deriving one from `category` alone reads "self-hosted" as "has a
    /// model field", which is true of a custom and FALSE of OpenClaw and Hermes —
    /// both declare `model == .unsupported` and Conduck hides the field. The
    /// symptom was "Check the model name in Settings, or pick a different one."
    /// rendered in the editor of a gateway that shows no model, which is the
    /// inversion `RemoteAgentFailureContext`'s header exists to warn about.
    func testModelHiddenLanesGetNoModelImperativeFromTheEditor() {
        let modelChangeImperatives = [
            "pick a different", "pick a model", "switch to a model",
            "a different model", "the model name in settings", "set a model"
        ]
        for backend in [RemoteAgentBackend.openclaw, .hermes] {
            let context = RemoteAgentFailureContext.resolve(.builtin(backend))
            XCTAssertFalse(context.userCanChooseModel,
                           "\(backend) stopped reporting a hidden model field — this rule is now hollow.")
            for error in [AppError.remoteAgentModelUnavailable,
                          .remoteAgentContextTooLong,
                          .remoteAgentModelRequired] {
                let message = SettingsViewModel.friendlyGatewayMessage(
                    for: error, named: Self.selfHostedName, context: context
                )
                for phrase in modelChangeImperatives {
                    XCTAssertFalse(
                        message.localizedCaseInsensitiveContains(phrase),
                        """
                        Code \(error.errorCode) says “\(phrase)” in the \(backend) editor, which shows \
                        no model field. Got: \(message)
                        """
                    )
                }
            }
        }
    }

    /// Non-vacuity for the rule above, and the half a lane flag gets right: where
    /// Conduck DOES show a model field, the same codes must still point at it. A
    /// fix that simply deleted the model wording everywhere would pass the rule
    /// above and strand the reader who has the control.
    func testModelVisibleLanesStillPointAtTheModelField() {
        for ref in [RemoteAgentRef.builtin(.openrouter), .custom(UUID())] {
            let context = RemoteAgentFailureContext.resolve(ref)
            XCTAssertTrue(context.userCanChooseModel)
            let message = SettingsViewModel.friendlyGatewayMessage(
                for: .remoteAgentModelUnavailable, named: Self.hostedName, context: context
            )
            XCTAssertTrue(message.localizedCaseInsensitiveContains("model"),
                          "\(ref) shows a model field — 55 must point at it. Got: \(message)")
        }
    }

    /// 402 and 429 are both routine on a hosted lane's free models. Each bare
    /// `errorDescription` states the symptom and withholds the fix, so the editor
    /// renders the remedy instead — and the remedy has to BE one. A code with no
    /// `recoverySuggestion` arm still returns non-nil (the generic "Try again."
    /// fallback), so `XCTUnwrap` alone cannot tell a real remedy from a missing
    /// one: this editor renders that string as its WHOLE message, which tells a
    /// user out of credit to retry a request their provider refuses identically
    /// every time. Hence the explicit comparison against the fallback.
    func testRateLimitAndCreditFailuresSurfaceTheirRemedy() throws {
        // `.audioMissingData` has no recovery arm, so its suggestion IS the
        // generic fallback — the value neither error below may equal.
        let genericFallback = AppError.audioMissingData.recoverySuggestion

        for error in [AppError.remoteAgentRateLimited, .remoteAgentOutOfCredits] {
            let message = SettingsViewModel.friendlyGatewayMessage(
                for: error, named: Self.hostedName, context: Self.hostedContext
            )
            let remedy = try XCTUnwrap(error.recoverySuggestion)
            XCTAssertEqual(message, remedy,
                           "\(error) must surface its remedy, not the symptom-only description.")
            XCTAssertNotEqual(message, error.errorDescription)
            XCTAssertNotEqual(message, genericFallback,
                              "\(error) must ship a real remedy — the generic fallback leaves the editor saying only \"Try again.\"")
        }

        // Each remedy names the thing that actually has to change: a balance for
        // 402, elapsed time for 429.
        let credits = SettingsViewModel.friendlyGatewayMessage(
            for: .remoteAgentOutOfCredits, named: Self.hostedName, context: Self.hostedContext
        )
        XCTAssertTrue(credits.localizedCaseInsensitiveContains("credit"),
                      "402's editor message must name the credit the user has to add. Got: \(credits)")
        let rateLimited = SettingsViewModel.friendlyGatewayMessage(
            for: .remoteAgentRateLimited, named: Self.hostedName, context: Self.hostedContext
        )
        XCTAssertTrue(rateLimited.localizedCaseInsensitiveContains("wait"),
                      "429's editor message must tell the user to wait it out. Got: \(rateLimited)")
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
