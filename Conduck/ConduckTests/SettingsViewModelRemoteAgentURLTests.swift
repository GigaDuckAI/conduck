// SPDX-License-Identifier: Apache-2.0

// Conduck
// SettingsViewModelRemoteAgentURLTests.swift
//
// The Personal AI gateway URL must be
// `https://` only; `http://` is rejected client-side at Settings save so the
// bearer token can never leave the device in cleartext.
//
// These tests exercise the URL guard in `validateRemoteAgent` (validate-only;
// Save is the separate commit point) WITHOUT reaching the live network probe:
// an invalid (http) URL is rejected at the guard, and a valid (https) URL with
// an empty token is rejected at the *token* guard — proving the https URL
// itself passed validation without requiring a reachable gateway.
//
// Two further tests cover the Save/Cancel split: `saveRemoteAgent` commits a
// KEYLESS gateway with no prior Test (URL + auth scheme land in the App Group /
// KVS, no Keychain dependency on the unsigned host), and `cancelRemoteAgentEdit`
// drops a never-saved custom draft. (The bearer-token Save commit now FAILS
// CLOSED on a Keychain write failure — a signed-build gate.)
//
// Custom-gateways: the VM's per-backend dicts + methods are re-keyed to
// `RemoteAgentRef`; these tests use built-in refs (`.builtin(.openclaw)` /
// `.builtin(.hermes)`) for the guard/isolation/pointer assertions and a minted
// custom draft for the Save/Cancel assertions.

import XCTest
@testable import Conduck

@MainActor
final class SettingsViewModelRemoteAgentURLTests: XCTestCase {

    /// The exact message surfaced when the URL fails validation. Kept here as
    /// the contract these tests assert against; if the source string changes,
    /// update both in lockstep.
    private let urlInvalidMessage = String(localized: "Enter the full gateway URL including https://.")
    /// A plain-http address toward a DOTTED NAME is still refused — the URL guard
    /// fires exactly as before — but it now earns copy that names the real
    /// constraint and both fixes rather than the generic "include https://"
    /// prompt (which would be false: iOS accepts plain http toward a LOCAL
    /// address, so "always use https" is not the rule the platform applies).
    private let plainHTTPRemoteMessage = SettingsViewModel.plainHTTPRemoteMessage

    private let openclaw: RemoteAgentRef = .builtin(.openclaw)
    private let hermes: RemoteAgentRef = .builtin(.hermes)

    /// `http://` toward a DOTTED NAME must be rejected at the URL guard — the
    /// token would otherwise travel in cleartext, and iOS refuses the request
    /// before any connect anyway.
    func testHTTPSchemeRejected() async {
        let vm = SettingsViewModel()
        await vm.validateRemoteAgent(
            ref: openclaw,
            url: "http://gateway.example.test:18789",
            token: "tok_live_abc123",
            fingerprint: nil
        )
        XCTAssertEqual(
            vm.remoteAgentRowState(for: openclaw),
            .invalid(message: plainHTTPRemoteMessage),
            "http:// toward a name must be rejected at the URL guard, with copy that names the fix."
        )
    }

    /// The carve-out, at the same guard: plain http toward an address only the
    /// local network can reach PASSES. Fed an empty token so the failure comes
    /// from the token guard — proving the URL itself was accepted without
    /// reaching the network.
    func testPlainHTTPToALocalAddressPassesTheURLGuard() async {
        let vm = SettingsViewModel()
        await vm.validateRemoteAgent(
            ref: openclaw,
            url: "http://192.168.1.10:11434",
            token: "   ",
            fingerprint: nil
        )
        guard case .invalid(let message) = vm.remoteAgentRowState(for: openclaw) else {
            return XCTFail("Expected an .invalid state from the empty-token guard, got \(vm.remoteAgentRowState(for: openclaw)).")
        }
        XCTAssertNotEqual(message, urlInvalidMessage)
        XCTAssertNotEqual(message, plainHTTPRemoteMessage,
                          "A LAN address must pass the URL guard — the failure has to come from the token guard.")
    }

    /// And a saved fingerprint paired with that same local http address is
    /// refused as a TUPLE, with its own copy: nothing hands over a certificate,
    /// so the pin could never be compared.
    func testPinOnAPlainHTTPAddressIsRefusedAtTheGuard() async {
        let vm = SettingsViewModel()
        await vm.validateRemoteAgent(
            ref: openclaw,
            url: "http://192.168.1.10:11434",
            token: "tok_live_abc123",
            fingerprint: String(repeating: "ab", count: 32)
        )
        XCTAssertEqual(
            vm.remoteAgentRowState(for: openclaw),
            .invalid(message: SettingsViewModel.pinOnPlainHTTPMessage),
            "Honouring the address and silently dropping the pin is the one forbidden outcome."
        )
    }

    /// `https://` URLs must pass the URL guard. We feed an EMPTY token so the
    /// method fails at the *token* guard instead — proving the https URL itself
    /// was accepted (it did not produce the URL-invalid message and did not
    /// reach the network probe).
    func testHTTPSchemeAcceptedAtURLGuard() async {
        let vm = SettingsViewModel()
        await vm.validateRemoteAgent(
            ref: openclaw,
            url: "https://gateway.example.test:18789",
            token: "   ",  // whitespace-only → fails the token guard, not the URL guard
            fingerprint: nil
        )
        guard case .invalid(let message) = vm.remoteAgentRowState(for: openclaw) else {
            return XCTFail("Expected an .invalid state from the empty-token guard, got \(vm.remoteAgentRowState(for: openclaw)).")
        }
        XCTAssertNotEqual(
            message,
            urlInvalidMessage,
            "An https:// URL must pass the URL guard — the failure should come from the empty-token guard, not the URL guard."
        )
    }

    // MARK: - Per-ref validation-state isolation

    /// A failed save on ONE ref must not mutate the OTHER ref's validation-state
    /// dict entry. Drives both through the URL guard (no network): an http://
    /// URL fails OpenClaw at the guard while Hermes is never touched and must
    /// stay `.unset`.
    func testPerBackendValidationStateIsolated() async {
        let vm = SettingsViewModel()
        await vm.validateRemoteAgent(
            ref: openclaw,
            url: "http://gateway.example.test:18789",
            token: "tok_live_abc123",
            fingerprint: nil
        )
        XCTAssertEqual(
            vm.remoteAgentRowState(for: openclaw),
            .invalid(message: plainHTTPRemoteMessage),
            "OpenClaw should hold the URL-guard failure."
        )
        XCTAssertEqual(
            vm.remoteAgentRowState(for: hermes),
            .unset,
            "Saving OpenClaw must not mutate Hermes's per-ref validation state (dict isolation)."
        )
    }

    // MARK: - Refined pointer-clear rule (pure helper)

    /// The active-conversation pointer is GLOBAL but per-ref edits must clear it
    /// ONLY when the active conversation is bound to the changed ref. Driven
    /// through the pure `shouldClearActivePointer` helper so the decision is
    /// exercised without the network-bound save path.
    func testPointerClearedWhenActiveConvBoundToChangedBackend() {
        XCTAssertTrue(
            SettingsViewModel.shouldClearActivePointer(
                activeConvBackend: RemoteAgentRef.builtin(.openclaw).rawString,
                changedRef: .builtin(.openclaw)
            ),
            "Active conversation bound to the changed ref → pointer must be cleared."
        )
    }

    func testPointerNotClearedWhenActiveConvBoundToDifferentBackend() {
        XCTAssertFalse(
            SettingsViewModel.shouldClearActivePointer(
                activeConvBackend: RemoteAgentRef.builtin(.hermes).rawString,
                changedRef: .builtin(.openclaw)
            ),
            "Active conversation bound to a DIFFERENT ref → pointer must be left alone."
        )
    }

    func testPointerNotClearedWhenNoActiveConversation() {
        XCTAssertFalse(
            SettingsViewModel.shouldClearActivePointer(
                activeConvBackend: nil,
                changedRef: .builtin(.openclaw)
            ),
            "No active conversation → nothing to clear."
        )
    }

    // MARK: - Save/Cancel split (buffer-until-Save)

    /// Save is the SINGLE commit point and commits even with NO prior Test. Here
    /// a KEYLESS (`.none`) custom gateway with a name + https URL commits on Save
    /// alone — no token, so NO Keychain write, so the commit runs on the unsigned
    /// host. (The bearer-token commit now FAILS CLOSED if its Keychain write
    /// fails — a signed-build gate, covered by `SettingsManagerRemoteAgentTests`.)
    /// URL + auth scheme land in the App Group / KVS (both testable here).
    func testSaveCommitsKeylessGatewayWithoutTest() async {
        let vm = SettingsViewModel()
        // Drain the init-load so a later async reload can't wipe the draft.
        await vm.loadSettings()
        await Task.yield()
        guard let id = vm.newCustomGatewayDraftID() else {
            return XCTFail("Expected a fresh VM to mint a custom-gateway draft below the cap.")
        }
        let ref = RemoteAgentRef.custom(id)
        vm.remoteAgentURLStrings[ref] = "https://gw.example.test"
        // Keyless: no token required → no Keychain dependency on the unsigned host.
        vm.setRemoteAgentAuthSchemeBuffer(.none, for: ref)

        let ok = await vm.saveRemoteAgent(ref: ref, name: "QA gateway", stagedToken: .stored)
        XCTAssertTrue(ok, "A named custom KEYLESS gateway with an https URL must commit on Save with no prior Test.")

        let storedURL = await SettingsManager.shared.getRemoteAgentURL(for: ref)
        XCTAssertEqual(storedURL?.absoluteString, "https://gw.example.test",
                       "Save must persist the URL to the store without a Test.")
        let scheme = await SettingsManager.shared.getRemoteAgentAuthScheme(for: ref)
        XCTAssertEqual(scheme, .none, "Save must persist the explicit keyless auth scheme.")

        // Cleanup — remove the roster entry + per-ref slots.
        await vm.clearRemoteAgent(for: ref)
    }

    /// Model identifiers are opaque strings owned by the selected server.
    /// Save trims only surrounding whitespace and must not silently truncate a
    /// long LiteLLM route or Hugging Face-style repository path.
    func testManualSavePreservesLongModelIdentifierExactly() async {
        let vm = SettingsViewModel()
        await vm.loadSettings()
        await Task.yield()
        guard let id = vm.newCustomGatewayDraftID() else {
            return XCTFail("Expected a fresh VM to mint a custom-gateway draft below the cap.")
        }
        let ref = RemoteAgentRef.custom(id)
        let model = "router/team/" + String(repeating: "long-model-segment-", count: 8)
        vm.remoteAgentURLStrings[ref] = "https://gw.example.test"
        vm.remoteAgentModelStrings[ref] = "  \(model)  "
        vm.setRemoteAgentAuthSchemeBuffer(.none, for: ref)

        let ok = await vm.saveRemoteAgent(ref: ref, name: "Long model", stagedToken: .stored)
        XCTAssertTrue(ok)

        let roster = await SettingsManager.shared.customGateway(id: id)
        XCTAssertEqual(roster?.model, model)
        XCTAssertGreaterThan(model.count, 100, "The fixture must cross the retired cap.")

        await vm.clearRemoteAgent(for: ref)
    }

    /// Cancel DROPS a never-saved draft: the in-memory roster row is removed and
    /// nothing reaches the store. Cancel keys off the store as the sole authority
    /// (a draft never reached it), so this is correct however the editor is left
    /// (Cancel button, swipe-back, or the macOS native back chevron).
    func testCancelDropsNeverSavedGatewayDraft() async {
        let vm = SettingsViewModel()
        await vm.loadSettings()
        await Task.yield()
        guard let id = vm.newCustomGatewayDraftID() else {
            return XCTFail("Expected a fresh VM to mint a custom-gateway draft below the cap.")
        }
        let ref = RemoteAgentRef.custom(id)
        vm.remoteAgentURLStrings[ref] = "https://typed-but-not-saved.example.test"
        XCTAssertTrue(vm.customGateways.contains { $0.id == id },
                      "Precondition: the minted draft must be present before Cancel.")

        await vm.cancelRemoteAgentEdit(ref: ref)

        XCTAssertFalse(vm.customGateways.contains { $0.id == id },
                       "Cancelling a never-saved draft must drop its in-memory roster row.")
        let storedURL = await SettingsManager.shared.getRemoteAgentURL(for: ref)
        XCTAssertNil(storedURL, "A never-saved draft must leave nothing in the store.")
    }
}
