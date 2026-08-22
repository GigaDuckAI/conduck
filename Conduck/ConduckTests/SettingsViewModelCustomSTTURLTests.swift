// SPDX-License-Identifier: Apache-2.0

// Conduck
// SettingsViewModelCustomSTTURLTests.swift
//
// Custom-STT V1.x. The BYO custom voice endpoint URL runs the ONE
// `EndpointURLPolicy` rule every persisted endpoint runs: `https`, or plain
// `http` toward a host only the local network can reach, and never a
// `user:password@` address.
//
// Mirrors `SettingsViewModelRemoteAgentURLTests`: these exercise the URL guard
// in `validateCustomSTT` (validate-only; Save is the separate commit point)
// WITHOUT reaching the live Test suite — an inadmissible URL is rejected at the
// URL guard, and an admissible URL with an empty key (under .bearer auth) is
// rejected at the *key* guard, proving the URL itself passed validation without
// requiring a reachable server.
//
// THE THREE PATHS MUST TELL ONE STORY. Save, Test-with-a-typed-key
// (`validateCustomSTT`) and Test-with-a-stored-key (`retestCustomSTT`) all run
// the same gate and derive their copy from `customSTTURLRejectionMessage`, so a
// string one of them accepts can never be refused by another with a message
// telling the user to add `https://` to an address the app itself stored. Two
// further tests cover the Save/Cancel split: Save commits a keyless endpoint
// with no prior Test, and Cancel drops a never-saved draft.

import XCTest
@testable import Conduck

@MainActor
final class SettingsViewModelCustomSTTURLTests: XCTestCase {

    /// The exact message surfaced when the custom URL fails validation. Kept
    /// here as the contract; if the source string changes, update both.
    private let urlInvalidMessage = String(localized: "settings.stt.custom.url.invalid",
                                           defaultValue: "Enter the full endpoint URL including https://.")

    /// App Groups UserDefaults — same suite `SettingsManager` uses internally.
    private let defaults = TestStores.defaults

    /// A stable uuid for the named endpoint these tests configure. The
    /// VM keys all custom-STT state by uuid; a seeded in-memory roster record +
    /// a non-empty name pass the name guard so the URL/key guards can fire.
    private let uuid = UUID()

    override func setUp() async throws {
        try await super.setUp()
        // Clear the persisted per-uuid auth-scheme key so a stale `.none` can't
        // flip the VM's default away from `.bearer` (which would skip the key
        // guard the https-acceptance test relies on).
        defaults.removeObject(forKey: Constants.customSTTAuthSchemeKey(for: uuid))
    }

    override func tearDown() async throws {
        defaults.removeObject(forKey: Constants.customSTTAuthSchemeKey(for: uuid))
        try await super.tearDown()
    }

    /// Seed the VM with a named endpoint draft so the name + auth guards pass and
    /// the URL/key guards are the ones under test.
    @MainActor
    private func seed(_ vm: SettingsViewModel) {
        vm.customVoiceEndpoints.append(CustomVoiceEndpoint(id: uuid, name: "Test endpoint"))
        vm.customSTTAuthSchemes[uuid] = .bearer
    }

    /// `http://` URLs must be rejected at the URL guard — a bearer key must
    /// never travel in cleartext (reused verbatim from the gateway).
    func testHTTPSchemeRejected() async {
        let vm = SettingsViewModel()
        seed(vm)
        // Supply a key so we'd otherwise pass the key guard — proving the
        // rejection comes from the URL guard specifically.
        await vm.validateCustomSTT(
            for: uuid,
            url: "http://whisper.example.test:9000",
            key: "sk-custom-abc123",
            model: ""
        )
        XCTAssertEqual(
            vm.customSTTValidationStates[uuid],
            .invalid(message: SettingsViewModel.plainHTTPRemoteMessage),
            "http:// toward a DOTTED NAME must still be rejected at the URL guard — and it now names the real constraint instead of the generic https:// prompt, which would be false (iOS accepts plain http toward a LOCAL address)."
        )
    }

    /// `https://` URLs must pass the URL guard. Under `.bearer` auth we feed an
    /// EMPTY key so the method fails at the *key* guard instead — proving the
    /// https URL itself was accepted (it did not produce the URL-invalid message
    /// and did not reach the network Test suite).
    func testHTTPSSchemeAcceptedAtURLGuard() async {
        let vm = SettingsViewModel()
        seed(vm)
        await vm.validateCustomSTT(
            for: uuid,
            url: "https://whisper.example.test:9000",
            key: "   ",  // whitespace-only key → fails the .bearer key guard, not the URL guard
            model: ""
        )
        guard case .invalid(let message) = vm.customSTTValidationStates[uuid] else {
            return XCTFail("Expected an .invalid state from the empty-key guard, got \(String(describing: vm.customSTTValidationStates[uuid])).")
        }
        XCTAssertNotEqual(
            message,
            urlInvalidMessage,
            "An https:// URL must pass the URL guard — the failure should come from the empty-key guard, not the URL guard."
        )
    }

    /// The carve-out this lane exists to serve: `http://192.168.1.10:11434` is
    /// Ollama on the LAN, and the URL guard must pass it. Under `.bearer` auth we
    /// feed an empty key so the run stops at the KEY guard — which proves the URL
    /// was accepted without needing a reachable server.
    func testPlainHTTPLocalURLAcceptedAtURLGuard() async {
        let vm = SettingsViewModel()
        seed(vm)
        await vm.validateCustomSTT(for: uuid, url: "http://192.168.1.10:11434", key: "   ", model: "")
        guard case .invalid(let message) = vm.customSTTValidationStates[uuid] else {
            return XCTFail("Expected an .invalid state from the empty-key guard, got \(String(describing: vm.customSTTValidationStates[uuid])).")
        }
        XCTAssertNotEqual(message, urlInvalidMessage)
        XCTAssertNotEqual(message, SettingsViewModel.plainHTTPRemoteMessage,
                          "A private IPv4 literal over plain http is what the carve-out admits — refusing it here would make the lane unusable for Ollama.")
    }

    /// A saved fingerprint on a plain-http address can never be compared, so the
    /// TUPLE is refused before anything is tested or written — and it is refused
    /// with the named message, not the generic URL one.
    func testPinOnPlainHTTPRefusedAtValidate() async {
        let vm = SettingsViewModel()
        seed(vm)
        vm.customSTTCertFingerprints[uuid] = String(repeating: "ab", count: 32)
        await vm.validateCustomSTT(for: uuid, url: "http://192.168.1.10:11434", key: "sk-custom-abc123", model: "")
        XCTAssertEqual(
            vm.customSTTValidationStates[uuid],
            .invalid(message: SettingsViewModel.pinOnPlainHTTPMessage),
            "Honouring the address and quietly dropping the pin is the one forbidden outcome."
        )
    }

    /// `retestCustomSTT` is the Test path for an ALREADY-SAVED endpoint, and it
    /// must run the same gate as Save. A raw `scheme == "https"` test here told
    /// the user to add `https://` to a plain-http LAN address the app itself had
    /// stored — the two-stories-about-one-string failure the shared derivation
    /// exists to prevent. Under `.bearer` with no stored key the run stops at the
    /// stored-key guard, which is what proves the URL passed.
    func testRetestAcceptsAPlainHTTPLocalURL() async {
        let vm = SettingsViewModel()
        seed(vm)
        await vm.retestCustomSTT(for: uuid, url: "http://192.168.1.10:11434", model: "")
        guard case .invalid(let message) = vm.customSTTValidationStates[uuid] else {
            return XCTFail("Expected an .invalid state from the stored-key guard, got \(String(describing: vm.customSTTValidationStates[uuid])).")
        }
        XCTAssertNotEqual(message, urlInvalidMessage)
        XCTAssertNotEqual(message, SettingsViewModel.plainHTTPRemoteMessage)
    }

    /// And the refusal it DOES owe names the real constraint, exactly as the
    /// Save path's does.
    func testRetestRefusesAPlainHTTPRemoteURLWithTheNamedMessage() async {
        let vm = SettingsViewModel()
        seed(vm)
        await vm.retestCustomSTT(for: uuid, url: "http://whisper.example.test:9000", model: "")
        XCTAssertEqual(
            vm.customSTTValidationStates[uuid],
            .invalid(message: SettingsViewModel.plainHTTPRemoteMessage),
            "Test and Save must refuse the same string with the same words."
        )
    }

    /// An empty URL must also be rejected at the URL guard.
    func testEmptyURLRejected() async {
        let vm = SettingsViewModel()
        seed(vm)
        await vm.validateCustomSTT(for: uuid, url: "   ", key: "sk-custom-abc123", model: "")
        XCTAssertEqual(
            vm.customSTTValidationStates[uuid],
            .invalid(message: urlInvalidMessage),
            "An empty URL must be rejected at the URL guard."
        )
    }

    /// Save is the SINGLE commit point and commits even with NO prior Test: a
    /// keyless endpoint (`.none` auth) with a name + https URL persists on Save
    /// alone. Keyless avoids the Keychain (signing-gated on the unsigned sim);
    /// the URL persists to the App Group, which IS testable here.
    func testSaveCommitsKeylessEndpointWithoutTest() async {
        let saveUUID = UUID()
        let vm = SettingsViewModel()
        vm.customVoiceEndpoints.append(CustomVoiceEndpoint(id: saveUUID, name: "Keyless box"))
        // Explicit `STTAuthScheme.none` — bare `.none` in this optional-typed
        // dictionary subscript resolves to `Optional.none` (nil) and removes the
        // key, which would default auth back to `.bearer` and trip the key guard.
        vm.customSTTAuthSchemes[saveUUID] = STTAuthScheme.none
        vm.customSTTURLStrings[saveUUID] = "https://whisper.example.test"

        let ok = await vm.saveCustomVoiceEndpoint(for: saveUUID, pendingKey: "")
        XCTAssertTrue(ok, "A keyless endpoint with a name + https URL must commit on Save with no prior Test.")

        let storedURL = await SettingsManager.shared.getCustomSTTURL(for: saveUUID)
        XCTAssertEqual(storedURL?.absoluteString, "https://whisper.example.test",
                       "Save must persist the URL to the store without a Test.")

        // Cleanup — remove the roster entry + every per-uuid slot.
        await vm.clearCustomSTT(for: saveUUID)
    }

    /// Cancel DROPS a never-saved draft: the in-memory roster row is removed and
    /// nothing reaches the store. Cancel keys off the store as the sole authority
    /// (a draft never reached it), so this is correct however the editor is left
    /// (Cancel button, swipe-back, or the macOS native back chevron).
    func testCancelDropsNeverSavedDraft() async {
        let draftUUID = UUID()
        let vm = SettingsViewModel()
        // Drain the init-load so the seeded draft is genuinely present when
        // Cancel runs (otherwise the assertion could pass spuriously).
        await vm.loadSettings()
        await Task.yield()
        vm.customVoiceEndpoints.append(CustomVoiceEndpoint(id: draftUUID, name: "Draft box"))
        vm.customSTTURLStrings[draftUUID] = "https://typed-but-not-saved.example.test"
        XCTAssertTrue(vm.customVoiceEndpoints.contains { $0.id == draftUUID },
                      "Precondition: the seeded draft must be present before Cancel.")

        await vm.cancelCustomVoiceEndpointEdit(for: draftUUID)

        XCTAssertFalse(vm.customVoiceEndpoints.contains { $0.id == draftUUID },
                       "Cancelling a never-saved draft must drop its in-memory roster row.")
        let storedURL = await SettingsManager.shared.getCustomSTTURL(for: draftUUID)
        XCTAssertNil(storedURL, "A never-saved draft must leave nothing in the store.")
    }
}
