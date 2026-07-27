// SPDX-License-Identifier: Apache-2.0

// Conduck
// SettingsViewModelStagedTokenTests.swift
//
// The gateway editor's staged-token contract (`StagedRemoteAgentToken`): Save /
// Test Connection / cert Trust take a credential INTENT and resolve it VM-side
// (Keychain never touches a View). These tests drive the intent paths that
// resolve WITHOUT a live Keychain or network:
//   - `.reuseVoiceKey` with no saved voice key fails closed (field-actionable
//     message, nothing persisted, no probe fired) on Save, Test, and Trust.
//   - `.stored` maps to the leave-the-saved-token-alone path — a fresh bearer
//     config with no stored token fails the same guards the old empty
//     `pendingToken` did.
//   - `.typed` / keyless route into `validateRemoteAgent`'s guards (URL /
//     required-name), proving the probe path without reaching the network.
//
// Isolation mirrors `SettingsViewModelMakeDefaultTests`: wipe the per-ref
// slots in BOTH App-Group defaults and the KVS mirror, plus the voice-key +
// gateway-token Keychain slots (best-effort on the unsigned sim, where the
// clears are no-ops because nothing can be stored). Synthetic values only.

import XCTest
@testable import Conduck

@MainActor
final class SettingsViewModelStagedTokenTests: XCTestCase {

    private let defaults: UserDefaults = {
        UserDefaults(suiteName: Constants.appGroupID) ?? UserDefaults.standard
    }()

    private let openclaw: RemoteAgentRef = .builtin(.openclaw)
    private let openrouter: RemoteAgentRef = .builtin(.openrouter)

    /// The message every `.reuseVoiceKey` dead-end surfaces. Kept here as the
    /// contract these tests assert against; update in lockstep with the source.
    private let missingVoiceKeyMessage = String(
        localized: "settings.remoteAgent.reuse.missingVoiceKey",
        defaultValue: "The OpenRouter voice key isn't available. Paste an API key instead."
    )

    override func setUp() async throws {
        try await super.setUp()
        await wipeState()
    }

    override func tearDown() async throws {
        await wipeState()
        try await super.tearDown()
    }

    private func wipeState() async {
        try? await SettingsManager.shared.clearAPIKey(
            forPresetID: SettingsViewModel.openRouterVoiceSTTPresetID
        )
        for backend in RemoteAgentBackend.allCases {
            let ref = RemoteAgentRef.builtin(backend)
            for key in [
                Constants.remoteAgentURLKey(for: ref),
                Constants.remoteAgentCertFingerprintKey(for: ref),
                Constants.remoteAgentAuthSchemeKey(for: ref),
                Constants.remoteAgentModelKey(for: ref)
            ] {
                defaults.removeObject(forKey: key)
                NSUbiquitousKeyValueStore.default.removeObject(forKey: key)
            }
            try? await SettingsManager.shared.clearRemoteAgentToken(for: ref)
        }
    }

    private func makeVM() async -> SettingsViewModel {
        let vm = SettingsViewModel()
        await vm.loadSettings()
        await Task.yield()
        return vm
    }

    // MARK: - Save: .reuseVoiceKey with no voice key

    /// Staged reuse resolves at COMMIT time — with the voice key gone, Save
    /// must fail closed with the field-actionable message and persist nothing
    /// (the resolution guard runs before any store write).
    func testSaveReuseVoiceKeyMissing_failsClosedPersistsNothing() async {
        let vm = await makeVM()
        vm.editorHasUnsavedChanges = true
        vm.remoteAgentModelStrings[openrouter] = "openai/gpt-4o-mini"

        let ok = await vm.saveRemoteAgent(ref: openrouter, name: nil, stagedToken: .reuseVoiceKey)

        XCTAssertFalse(ok, "Save with a .reuseVoiceKey intent and no saved voice key must fail.")
        XCTAssertEqual(
            vm.remoteAgentRowState(for: openrouter),
            .invalid(message: missingVoiceKeyMessage),
            "The failure must tell the user to paste a key instead — not a generic error."
        )
        let stored = await SettingsManager.shared.hasStoredRemoteAgentSlots(for: openrouter)
        XCTAssertFalse(stored, "A failed reuse-save must leave no per-ref slots behind (nothing persisted on failure).")
    }

    // MARK: - Test Connection: intent routing without a network probe

    /// `.reuseVoiceKey` resolving to nothing must surface the same message as
    /// Save and fire NO probe (the state lands `.invalid`, never `.checking`).
    func testTestConnectionReuseVoiceKeyMissing_failsWithoutProbe() async {
        let vm = await makeVM()

        await vm.testRemoteAgent(ref: openrouter, stagedToken: .reuseVoiceKey, name: nil)

        XCTAssertEqual(
            vm.remoteAgentRowState(for: openrouter),
            .invalid(message: missingVoiceKeyMessage),
            "A missing voice key must dead-end BEFORE the probe — same message as Save."
        )
    }

    /// `.stored` with a bearer scheme and no saved token routes to the re-test
    /// guard ("no saved token"), not to a probe with an empty header.
    func testTestConnectionStoredWithoutSavedToken_failsAtRetestGuard() async {
        let vm = await makeVM()
        vm.remoteAgentURLStrings[openclaw] = "https://gw.example.test:18789"

        await vm.testRemoteAgent(ref: openclaw, stagedToken: .stored, name: nil)

        XCTAssertEqual(
            vm.remoteAgentRowState(for: openclaw),
            .invalid(message: String(localized: "No saved token to test. Paste your \("OpenClaw") token first.")),
            ".stored + bearer + nothing in Keychain must fail the re-test guard, never probe unauthenticated (fail closed)."
        )
    }

    /// `.typed` routes into `validateRemoteAgent` with the typed value — proven
    /// via the URL guard (an http:// URL is rejected before any network).
    func testTestConnectionTypedRoutesToValidate_urlGuardFires() async {
        let vm = await makeVM()
        vm.remoteAgentURLStrings[openclaw] = "http://gw.example.test:18789"

        await vm.testRemoteAgent(ref: openclaw, stagedToken: .typed("tok_live_abc123"), name: nil)

        XCTAssertEqual(
            vm.remoteAgentRowState(for: openclaw),
            .invalid(message: String(localized: "Enter the full gateway URL including https://.")),
            ".typed must reach validateRemoteAgent's URL guard, proving the probe path was taken."
        )
    }

    /// Keyless (`.none`) probes with NO token regardless of the staged intent,
    /// and routes through `validateRemoteAgent` so a fresh draft's required-name
    /// guard still fires.
    func testTestConnectionKeylessRoutesToValidate_nameGuardFires() async {
        let vm = await makeVM()
        guard let id = vm.newCustomGatewayDraftID() else {
            return XCTFail("Expected a fresh VM to mint a custom-gateway draft below the cap.")
        }
        let ref = RemoteAgentRef.custom(id)
        vm.remoteAgentURLStrings[ref] = "https://gw.example.test"
        vm.setRemoteAgentAuthSchemeBuffer(.none, for: ref)

        await vm.testRemoteAgent(ref: ref, stagedToken: .typed("must-be-ignored"), name: "")

        XCTAssertEqual(
            vm.remoteAgentRowState(for: ref),
            .invalid(message: String(localized: "remoteAgent.custom.name.required",
                                     defaultValue: "Give this gateway a name.")),
            "Keyless must route through validateRemoteAgent (name guard), ignoring any staged token."
        )
        await vm.cancelRemoteAgentEdit(ref: ref)
    }

    // MARK: - Save: .stored keeps the old empty-pendingToken guard semantics

    /// A FRESH bearer config saved with `.stored` (no typed token, no masked
    /// tail) must fail the token guard exactly as the old empty `pendingToken`
    /// path did.
    func testSaveStoredFreshBearerConfig_failsAtTokenGuard() async {
        let vm = await makeVM()
        vm.editorHasUnsavedChanges = true
        vm.remoteAgentURLStrings[openclaw] = "https://gw.example.test:18789"

        let ok = await vm.saveRemoteAgent(ref: openclaw, name: nil, stagedToken: .stored)

        XCTAssertFalse(ok, "A fresh bearer config with nothing stored and nothing typed must not commit.")
        XCTAssertEqual(
            vm.remoteAgentRowState(for: openclaw),
            .invalid(message: String(localized: "Paste your \("OpenClaw") bearer token.")),
            ".stored maps to the leave-token-alone path — with no stored token, the bearer guard must fire."
        )
    }

    // MARK: - Trust: staged intent + pending-fingerprint promote

    /// No pending fingerprint → Trust is a no-op under the new signature too.
    func testTrustWithoutPendingFingerprint_noOp() async {
        let vm = await makeVM()

        await vm.trustPresentedRemoteCert(ref: openclaw, stagedToken: .stored)

        XCTAssertEqual(vm.remoteAgentRowState(for: openclaw), .unset,
                       "Trust with nothing pending must not touch the validation state.")
    }

    /// Trust promotes the presented fingerprint into the pin buffer FIRST, so a
    /// `.reuseVoiceKey` dead-end still leaves the user's trust decision staged —
    /// pasting a key and re-testing then pins against the approved cert.
    func testTrustReuseVoiceKeyMissing_promotesFingerprintThenFailsClosed() async {
        let vm = await makeVM()
        let fp = String(repeating: "a", count: 64)
        vm.remoteAgentPendingUntrustedCert[openclaw] = fp

        await vm.trustPresentedRemoteCert(ref: openclaw, stagedToken: .reuseVoiceKey)

        XCTAssertEqual(vm.remoteAgentCertFingerprints[openclaw], fp,
                       "The presented fingerprint must be promoted into the editable pin buffer.")
        XCTAssertNil(vm.remoteAgentPendingUntrustedCert[openclaw],
                     "The pending TOFU banner must clear on Trust.")
        XCTAssertEqual(
            vm.remoteAgentRowState(for: openclaw),
            .invalid(message: missingVoiceKeyMessage),
            "A .reuseVoiceKey Trust with no voice key must fail closed with the field-actionable message, not probe."
        )
    }
}
