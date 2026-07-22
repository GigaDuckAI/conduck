// Conduck
// VoiceVendorRegistryTests.swift
//
// Cloud Text-to-Speech — the merged "Voice" vendor registry. Pure-data
// coverage: the shared-key invariant (`sharedKeychainAccount` resolves to the
// LOCKED STT slot for every cloud vendor — ZERO migration), reverse-lookup
// round-trips, per-direction capability statuses, and the Apple-first display
// order. Phase B: `vendors(customEndpoints:)` appends one vendor per named
// custom endpoint; built-ins are now 5 (custom is dynamic). No URLSession, no
// Keychain — every test is deterministic.

import XCTest
@testable import Conduck

final class VoiceVendorRegistryTests: XCTestCase {

    /// A two-endpoint roster for the dynamic-custom-vendor assertions.
    private let endpointA = CustomVoiceEndpoint(id: UUID(), name: "Deepgram")
    private let endpointB = CustomVoiceEndpoint(id: UUID(), name: "Whisper box")
    private var roster: [CustomVoiceEndpoint] { [endpointA, endpointB] }

    // MARK: - Order + count

    func testBuiltInsAreAppleFirst() {
        XCTAssertEqual(VoiceVendorRegistry.builtIns.first?.id, "apple",
                       "Apple must be the FIRST built-in vendor (recommended default).")
    }

    func testBuiltInsHaveSixVendors() {
        XCTAssertEqual(VoiceVendorRegistry.builtIns.count, 6,
                       "Expected 6 built-ins (Apple + 5 cloud incl. OpenRouter) after Qwen was unlisted; custom is dynamic.")
    }

    func testVendorsAppendsOnePerCustomEndpoint() {
        let vendors = VoiceVendorRegistry.vendors(customEndpoints: roster)
        XCTAssertEqual(vendors.count, 8, "6 built-ins + 2 custom endpoints.")
        // Built-ins first, then customs in roster order.
        XCTAssertEqual(vendors.prefix(6).map(\.id), VoiceVendorRegistry.builtIns.map(\.id))
        XCTAssertEqual(vendors[6].displayName, "Deepgram")
        XCTAssertEqual(vendors[7].displayName, "Whisper box")
    }

    func testCustomVendorIDsRoundTrip() {
        let vendor = VoiceVendorRegistry.customVendor(for: endpointA)
        XCTAssertEqual(vendor.id, "custom_" + endpointA.id.uuidString.lowercased())
        XCTAssertEqual(VoiceVendorRegistry.customVendorUUID(from: vendor.id), endpointA.id)
        // A built-in id is not a custom vendor.
        XCTAssertNil(VoiceVendorRegistry.customVendorUUID(from: "apple"))
    }

    func testVendorIDsAreUnique() {
        let ids = VoiceVendorRegistry.vendors(customEndpoints: roster).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Vendor UI ids must be unique (raw: \(ids)).")
    }

    // MARK: - Per-endpoint custom vendor maps to per-uuid wire ids

    func testCustomVendorMapsToPerUUIDWireIDs() {
        let vendor = VoiceVendorRegistry.customVendor(for: endpointA)
        XCTAssertEqual(vendor.sttPresetID, STTProvider.customEndpointID(for: endpointA.id))
        XCTAssertEqual(vendor.ttsProviderID, TTSProvider.customEndpointID(for: endpointA.id))
        XCTAssertEqual(vendor.displayName, "Deepgram", "Display name is the user's endpoint name.")
        XCTAssertEqual(vendor.sttStatus, .available)
        XCTAssertEqual(vendor.ttsStatus, .available)
        // The shared Keychain slot resolves to THIS endpoint's per-uuid slot.
        XCTAssertEqual(vendor.sharedKeychainAccount,
                       Constants.sttApiKeyKeychainAccount(for: STTProvider.customEndpointID(for: endpointA.id)))
    }

    // MARK: - Shared Keychain slot (ZERO migration) — load-bearing

    func testSharedKeychainAccountMatchesLockedSTTSlot() {
        let expected: [(id: String, presetID: String)] = [
            ("openai", "openai-gpt4o-transcribe"),
            ("mistral", "mistral-voxtral"),
            ("elevenlabs", "elevenlabs-scribe-v2"),
            ("gemini", "gemini-3-1-flash-lite"),
            ("openrouter", "openrouter-stt"),
        ]
        for entry in expected {
            let vendor = try! XCTUnwrap(VoiceVendorRegistry.lookup(id: entry.id, customEndpoints: []))
            XCTAssertEqual(vendor.sharedKeychainAccount,
                           Constants.sttApiKeyKeychainAccount(for: entry.presetID),
                           "\(entry.id): sharedKeychainAccount must resolve to the LOCKED STT slot stt.apiKey.\(entry.presetID) (ZERO migration).")
            XCTAssertEqual(vendor.sharedKeychainAccount, "stt.apiKey.\(entry.presetID)",
                           "\(entry.id): the shared slot literal must remain frozen.")
        }
    }

    func testApplePresetIDsMatchKeyless() {
        let apple = VoiceVendorRegistry.apple
        XCTAssertEqual(apple.sttPresetID, "apple-on-device")
        XCTAssertEqual(apple.ttsProviderID, "apple-tts")
        XCTAssertTrue(apple.isOnDevice, "Apple vendor must be on-device.")
    }

    // MARK: - Reverse lookups round-trip (roster-aware)

    func testReverseLookupBySTTPresetIDRoundTrips() {
        for vendor in VoiceVendorRegistry.vendors(customEndpoints: roster) {
            guard let presetID = vendor.sttPresetID else { continue }
            XCTAssertEqual(VoiceVendorRegistry.vendor(forSTTPresetID: presetID, customEndpoints: roster)?.id, vendor.id,
                           "vendor(forSTTPresetID: \(presetID)) must round-trip to \(vendor.id).")
        }
    }

    func testReverseLookupByTTSProviderIDRoundTrips() {
        for vendor in VoiceVendorRegistry.vendors(customEndpoints: roster) {
            guard let ttsID = vendor.ttsProviderID else { continue }
            XCTAssertEqual(VoiceVendorRegistry.vendor(forTTSProviderID: ttsID, customEndpoints: roster)?.id, vendor.id,
                           "vendor(forTTSProviderID: \(ttsID)) must round-trip to \(vendor.id).")
        }
    }

    func testReverseLookupResolvesPerUUIDCustomEndpoint() {
        let sttID = STTProvider.customEndpointID(for: endpointB.id)
        let ttsID = TTSProvider.customEndpointID(for: endpointB.id)
        XCTAssertEqual(VoiceVendorRegistry.vendor(forSTTPresetID: sttID, customEndpoints: roster)?.displayName, "Whisper box")
        XCTAssertEqual(VoiceVendorRegistry.vendor(forTTSProviderID: ttsID, customEndpoints: roster)?.displayName, "Whisper box")
    }

    func testReverseLookupUnknownIDsYieldNil() {
        XCTAssertNil(VoiceVendorRegistry.vendor(forSTTPresetID: "no-such-preset", customEndpoints: roster))
        XCTAssertNil(VoiceVendorRegistry.vendor(forTTSProviderID: "no-such-tts", customEndpoints: roster))
        XCTAssertNil(VoiceVendorRegistry.lookup(id: "no-such-vendor", customEndpoints: roster))
        // A custom vendor id whose endpoint was deleted (not in the roster) → nil.
        XCTAssertNil(VoiceVendorRegistry.lookup(id: "custom_" + UUID().uuidString.lowercased(), customEndpoints: roster))
    }

    func testTTSProviderIDsMatchLockedTTSRegistry() {
        XCTAssertEqual(VoiceVendorRegistry.apple.ttsProviderID, TTSProvider.appleTTS.id)
        XCTAssertEqual(VoiceVendorRegistry.openAI.ttsProviderID, TTSProvider.openAITTS.id)
        XCTAssertEqual(VoiceVendorRegistry.mistral.ttsProviderID, TTSProvider.mistralTTS.id)
        XCTAssertEqual(VoiceVendorRegistry.elevenLabs.ttsProviderID, TTSProvider.elevenLabsTTS.id)
    }

    // MARK: - Capability statuses

    func testShippedVendorsHaveBothDirectionsAvailable() {
        for id in ["apple", "openai", "mistral", "elevenlabs", "gemini"] {
            let vendor = try! XCTUnwrap(VoiceVendorRegistry.lookup(id: id, customEndpoints: []))
            XCTAssertEqual(vendor.sttStatus, .available, "\(id) STT must be available.")
            XCTAssertEqual(vendor.ttsStatus, .available, "\(id) TTS must be available.")
        }
    }

    func testGeminiTTSIsShipped() {
        let gemini = try! XCTUnwrap(VoiceVendorRegistry.lookup(id: "gemini", customEndpoints: []))
        XCTAssertEqual(gemini.ttsStatus, .available, "Gemini TTS is shipped via gemini-3.1-flash-tts-preview.")
        XCTAssertEqual(gemini.ttsProviderID, "gemini-tts", "Gemini's TTS row points at the gemini-tts provider.")
    }

    func testRetainedQwenVendorDefShape() {
        XCTAssertNil(VoiceVendorRegistry.lookup(id: "qwen", customEndpoints: []),
                     "Qwen is unlisted — it must NOT resolve via the registry lookup.")
        let qwen = VoiceVendorRegistry.qwen
        XCTAssertEqual(qwen.sttStatus, .available, "Retained Qwen def keeps STT available.")
        XCTAssertEqual(qwen.ttsStatus, .coming, "Retained Qwen def keeps TTS 'coming soon'.")
        XCTAssertNil(qwen.ttsProviderID, "Qwen has no shipped TTS provider id yet.")
    }

    func testCustomEndpointHasBothDirections() {
        let custom = VoiceVendorRegistry.customVendor(for: endpointA)
        XCTAssertEqual(custom.sttStatus, .available, "Custom STT endpoint is available.")
        XCTAssertEqual(custom.ttsStatus, .available,
                       "The custom BYO endpoint serves TTS too (/v1/audio/speech), shared with STT.")
    }

    // MARK: - Display copy comes from the STT registry (built-ins)

    func testDisplayNamesMatchSTTRegistry() {
        XCTAssertEqual(VoiceVendorRegistry.openAI.displayName, STTProviderRegistry.openAI.displayName)
        XCTAssertEqual(VoiceVendorRegistry.mistral.displayName, STTProviderRegistry.mistralVoxtral.displayName)
        XCTAssertEqual(VoiceVendorRegistry.elevenLabs.displayName, STTProviderRegistry.elevenLabs.displayName)
    }

    func testSTTMetadataResolvesForBuiltIns() {
        for vendor in VoiceVendorRegistry.builtIns {
            XCTAssertNotNil(vendor.sttMetadata,
                            "\(vendor.id): sttMetadata must resolve (every built-in vendor has an STT preset).")
            XCTAssertEqual(vendor.sttMetadata?.id, vendor.sttPresetID)
        }
    }
}
