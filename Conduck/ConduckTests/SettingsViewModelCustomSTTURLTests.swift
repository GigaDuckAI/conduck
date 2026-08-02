// SPDX-License-Identifier: Apache-2.0

// Conduck
// SettingsViewModelCustomSTTURLTests.swift
//
// Custom-STT V1.x. The BYO custom STT endpoint URL must be
// `https://` only; `http://` is rejected client-side at Settings save (REUSED
// verbatim from the gateway's URL guard) so the bearer key can never leave
// the device in cleartext.
//
// Mirrors `SettingsViewModelRemoteAgentURLTests`: these exercise the URL guard
// in `validateCustomSTT` (validate-only; Save is the separate commit point)
// WITHOUT reaching the live Test suite — an invalid (http) URL is rejected at
// the URL guard, and a valid (https) URL with an empty key (under .bearer auth)
// is rejected at the *key* guard, proving the https URL itself passed validation
// without requiring a reachable server. Two further tests cover the new
// Save/Cancel split: Save commits a keyless endpoint with no prior Test, and
// Cancel drops a never-saved draft.

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
            .invalid(message: urlInvalidMessage),
            "http:// must be rejected at the URL guard — the key would otherwise leave the device in cleartext."
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
