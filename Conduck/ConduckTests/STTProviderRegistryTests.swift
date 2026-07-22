// Conduck
// STTProviderRegistryTests.swift
//
// Multi-provider STT expansion. Registry-level invariants:
// ID uniqueness, Keychain account convention, display/wire registry parity,
// V2 model string currency, maskedTail helper behavior.
//
// The legacy Keychain account back-compat test is load-bearing — renaming
// or changing the formatter would orphan every existing Voxtral user's key.

import XCTest
@testable import Conduck

final class STTProviderRegistryTests: XCTestCase {

    // MARK: - Uniqueness

    func testAllRegistryIDsAreUnique() {
        let ids = STTProvider.allRegistered.map(\.id)
        let unique = Set(ids)
        // Count is 7: the 4 listed cloud providers (Mistral/OpenAI/ElevenLabs/
        // Gemini) + OpenRouter + Apple on-device + the `custom-openai` BYO
        // endpoint. Qwen stays UNLISTED. Display + wire registries are kept in
        // lockstep — see the parity test below.
        XCTAssertEqual(unique.count, 7, "Expected 7 unique provider IDs, got \(unique.count) (raw: \(ids))")
    }

    // MARK: - Keychain convention

    func testRegistryIDsMatchKeychainConvention() {
        for provider in STTProvider.allRegistered {
            let account = Constants.sttApiKeyKeychainAccount(for: provider.id)
            XCTAssertEqual(account, "stt.apiKey.\(provider.id)",
                           "Keychain account formatter must produce 'stt.apiKey.<id>' for \(provider.id)")
        }
    }

    func testFreshInstallDefaultIsAppleOnDevice() {
        // Fresh-install default is `"apple-on-device"` (iOS 26+ Apple as
        // default).
        // Existing installs keep their stored KVS value via the read-through
        // in `SettingsManager.getActivePresetID()` — this constant only
        // takes effect when KVS is empty.
        XCTAssertEqual(Constants.sttActivePresetIDDefault, "apple-on-device",
                       "Fresh-install default must be Apple on-device. A flip back to Voxtral would re-route every fresh install through a paid cloud provider.")
        XCTAssertEqual(STTProvider.appleOnDevice.id, Constants.sttActivePresetIDDefault,
                       "Apple on-device provider's ID must match the fresh-install default.")
    }

    /// LOAD-BEARING: legacy V1 Voxtral Keychain slot must subsume under the new
    /// formatter. Existing users' stored keys live at literal
    /// `"stt.apiKey.mistral-voxtral"`; changing this string orphans them.
    func testKeychainAccountForLegacyMistralIDIsBackCompat() {
        XCTAssertEqual(Constants.sttApiKeyKeychainAccount(for: "mistral-voxtral"),
                       "stt.apiKey.mistral-voxtral",
                       "BACK-COMPAT: legacy Voxtral Keychain account format must remain 'stt.apiKey.mistral-voxtral'.")
    }

    // MARK: - Display ↔ wire registry parity

    func testSTTProviderMetadataRegistryMatchesSTTProviderRegistry() {
        // Display metadata for
        // `apple-on-device` is present in `STTProviderRegistry.all`,
        // so display IDs and wire IDs must match exactly.
        let wireIDs = Set(STTProvider.allRegistered.map(\.id))
        let displayIDs = Set(STTProviderRegistry.all.map(\.id))
        XCTAssertEqual(displayIDs, wireIDs,
                       "Display registry and wire registry must list the same provider IDs. Drift = unrenderable provider in Settings OR display row with no wire backing.")
    }

    // MARK: - V2 model string currency

    func testVoxtralV2ModelStringIsCurrent() {
        XCTAssertEqual(STTProvider.mistralVoxtral.model, "voxtral-mini-2602",
                       "Voxtral model tag must be V2 (`voxtral-mini-2602`). Accidental revert to `2507` regresses users.")
    }

    // MARK: - Apple on-device registry entry

    func testAppleOnDeviceProviderIsRegistered() {
        // Wire-order: [mistral, openai, elevenlabs, gemini, openRouter, apple,
        // custom-openai] (Qwen unlisted). OpenRouter was inserted before Apple,
        // so Apple is now at index 5; `custom-openai` stays appended LAST. Total
        // count is 7. (UI display order comes from `STTProviderRegistry.all` /
        // `VoiceVendorRegistry`, not this array — parity is by SET, not order.)
        XCTAssertEqual(STTProvider.allRegistered.count, 7,
                       "Count is 7 (OpenRouter added; Qwen still unlisted).")
        XCTAssertEqual(STTProvider.allRegistered[5].id, "apple-on-device",
                       "Apple on-device sits at index 5 after OpenRouter was inserted ahead of it; custom-openai is appended after.")
    }

    // MARK: - Custom-STT V1.x — last provider (`custom-openai`)

    func testCustomOpenAIProviderIsRegisteredAsLastEntry() {
        XCTAssertEqual(STTProvider.allRegistered.count, 7,
                       "custom-openai is the last registered provider (count 7 with OpenRouter added, Qwen unlisted).")
        XCTAssertEqual(STTProvider.allRegistered.last?.id, "custom-openai",
                       "The BYO custom endpoint must be appended LAST in `allRegistered` (UI-display order).")
    }

    func testCustomOpenAILookupReturnsCustomNotFallback() {
        let resolved = STTProvider.lookup(id: "custom-openai")
        XCTAssertEqual(resolved.id, "custom-openai",
                       "lookup(id: \"custom-openai\") must return the custom registration, NOT the Mistral fallback. A miss means the entry was dropped from `allRegistered`.")
    }

    func testCustomOpenAIKeychainAccountFollowsLockedConvention() {
        // LOCKED: the custom endpoint's API key lives at literal
        // `stt.apiKey.custom-openai`. Changing the id (or the formatter)
        // orphans the user's stored key.
        XCTAssertEqual(Constants.sttApiKeyKeychainAccount(for: "custom-openai"),
                       "stt.apiKey.custom-openai",
                       "LOCKED: custom endpoint Keychain account must be 'stt.apiKey.custom-openai'.")
    }

    func testCustomOpenAIHasDynamicEndpointKeyAndCloudDoesNot() {
        // The declarative dispatch invariant: ONLY the custom provider carries
        // a `dynamicEndpointKey`; every frozen provider has nil. A future
        // refactor that flipped a cloud provider's key would route it through
        // the dynamic-URL + pinning path — this test forbids that.
        for provider in STTProvider.allRegistered where provider.id != "custom-openai" {
            XCTAssertNil(provider.dynamicEndpointKey,
                         "Frozen provider \(provider.id) must have dynamicEndpointKey == nil — only the BYO custom endpoint resolves its URL dynamically.")
        }
        XCTAssertEqual(STTProvider.customOpenAICompat.dynamicEndpointKey, "stt.custom.url",
                       "custom-openai must carry the `stt.custom.url` dynamic-endpoint key.")
    }

    func testAppleOnDeviceLookupReturnsAppleNotFallback() {
        let resolved = STTProvider.lookup(id: "apple-on-device")
        XCTAssertEqual(resolved.id, "apple-on-device",
                       "lookup(id: \"apple-on-device\") must return the Apple registration, NOT the Mistral fallback. A miss here means the entry was dropped from `allRegistered`.")
    }

    func testAppleOnDeviceTransportIsInProcess() {
        XCTAssertEqual(STTProvider.appleOnDevice.transport, .inProcess,
                       "Apple on-device must dispatch via the `.inProcess` arm — `.multipart` / `.json` would attempt a network round-trip against the sentinel URL.")
    }

    func testAppleOnDeviceHasNoProbeURL() {
        XCTAssertNil(STTProvider.appleOnDevice.probeURL,
                     "Apple on-device has no key to probe; probeURL must be nil. `NoOpSTTProbe` handles validate(...) as a no-op.")
    }

    func testAppleOnDeviceInProcessRunnerIsAppleSpeechRunner() {
        // `inProcessRunner` wired to `AppleSpeechRunner.self`
        // on iOS / iPadOS / macOS / CarPlay (Watch keeps nil — the
        // Speech framework ships no watchOS symbols; Watch surface
        // relays audio to iPhone).
        //
        // The test target compiles for iOS + macOS only, so the
        // non-Watch branch always applies here. ObjectIdentifier
        // gives a metatype-equality comparison.
        let runner = STTProvider.appleOnDevice.inProcessRunner
        XCTAssertNotNil(runner,
                        "AppleSpeechRunner.self is wired on non-Watch targets. nil here means the conditional compile excluded it incorrectly.")
        if let runner {
            // Metatype identity via ObjectIdentifier — works for any
            // `AnyObject.Type` and any protocol-existential metatype.
            XCTAssertEqual(ObjectIdentifier(runner),
                           ObjectIdentifier(AppleSpeechRunner.self),
                           "inProcessRunner must point to AppleSpeechRunner, not another conformance.")
        }
    }

    func testAppleOnDeviceKeychainAccountFollowsLegacyConvention() {
        // Even though Apple never writes to its Keychain slot, the
        // account formatter MUST remain consistent — future code that
        // queries `presetIDsWithStoredKey()` filters on the prefix.
        XCTAssertEqual(Constants.sttApiKeyKeychainAccount(for: "apple-on-device"),
                       "stt.apiKey.apple-on-device",
                       "Keychain account convention must produce 'stt.apiKey.apple-on-device' even though slot is never written.")
    }

    // MARK: - maskedTail helper

    func testMaskedTailLastFourChars() {
        XCTAssertEqual(maskedTail("sk-abcd1234XK4q"), "••••••••XK4q")
    }

    func testMaskedTailAllAsterisksForShortKey() {
        XCTAssertEqual(maskedTail("short"), "•••••",
                       "Keys <8 chars render as all-bullets to avoid leaking the entire string.")
    }
}
