// SPDX-License-Identifier: Apache-2.0

// Conduck
// CustomVoicePresetIDTests.swift
//
// Phase B — multiple named custom voice endpoints. The per-uuid preset/provider
// id round-trips + the load-bearing DISJOINTNESS (STT `custom-openai_<uuid>` vs
// TTS `custom-openai-tts_<uuid>` vs the bare legacy ids) + the `lookup(id:)`
// SYNTHESIS (per-uuid `dynamicEndpointKey`; the TTS provider ALSO sets the
// per-uuid `sharedKeySTTPresetID` — the "one key, both directions" link) + the
// frozen `allRegistered` arrays staying length-frozen (7-provider invariant).
// Pure value-type coverage — no Keychain, no UserDefaults.

import XCTest
@testable import Conduck

final class CustomVoicePresetIDTests: XCTestCase {

    private let uuid = UUID()

    // MARK: - ID round-trip

    func testSTTIDRoundTrips() {
        let id = STTProvider.customEndpointID(for: uuid)
        XCTAssertEqual(id, "custom-openai_" + uuid.uuidString.lowercased())
        XCTAssertEqual(STTProvider.customEndpointUUID(fromPresetID: id), uuid)
    }

    func testTTSIDRoundTrips() {
        let id = TTSProvider.customEndpointID(for: uuid)
        XCTAssertEqual(id, "custom-openai-tts_" + uuid.uuidString.lowercased())
        XCTAssertEqual(TTSProvider.customEndpointUUID(fromProviderID: id), uuid)
    }

    // MARK: - Disjointness (load-bearing)

    /// `custom-openai_<uuid>` must NOT match the TTS prefix (char after the base
    /// is `-`, not `_`) nor the bare legacy `custom-openai`.
    func testSTTPrefixRejectsTTSAndBareLegacy() {
        let ttsID = TTSProvider.customEndpointID(for: uuid)   // custom-openai-tts_<uuid>
        XCTAssertNil(STTProvider.customEndpointUUID(fromPresetID: ttsID),
                     "An STT-prefix parse must REJECT a TTS id (custom-openai-tts_…).")
        XCTAssertNil(STTProvider.customEndpointUUID(fromPresetID: "custom-openai"),
                     "An STT-prefix parse must REJECT the bare legacy custom-openai.")
        XCTAssertNil(STTProvider.customEndpointUUID(fromPresetID: "custom-openai-tts"),
                     "An STT-prefix parse must REJECT the bare legacy custom-openai-tts.")
    }

    /// `custom-openai-tts_<uuid>` must NOT match the bare legacy `custom-openai-tts`.
    func testTTSPrefixRejectsBareLegacy() {
        XCTAssertNil(TTSProvider.customEndpointUUID(fromProviderID: "custom-openai-tts"),
                     "A TTS-prefix parse must REJECT the bare legacy custom-openai-tts.")
        // An STT id is not a TTS id.
        XCTAssertNil(TTSProvider.customEndpointUUID(fromProviderID: STTProvider.customEndpointID(for: uuid)),
                     "A TTS-prefix parse must REJECT an STT id (custom-openai_…).")
    }

    func testGarbageIDsYieldNil() {
        XCTAssertNil(STTProvider.customEndpointUUID(fromPresetID: "custom-openai_not-a-uuid"))
        XCTAssertNil(STTProvider.customEndpointUUID(fromPresetID: "openai-gpt4o-transcribe"))
        XCTAssertNil(TTSProvider.customEndpointUUID(fromProviderID: "custom-openai-tts_garbage"))
    }

    // MARK: - lookup synthesis

    /// `STTProvider.lookup` synthesizes a per-uuid provider with the per-uuid
    /// `dynamicEndpointKey`; everything else rides the template.
    func testSTTLookupSynthesizesPerUUIDProvider() {
        let id = STTProvider.customEndpointID(for: uuid)
        let provider = STTProvider.lookup(id: id)
        XCTAssertEqual(provider.id, id)
        XCTAssertEqual(provider.dynamicEndpointKey, Constants.customSTTURLKey(for: uuid),
                       "Synthesized STT provider must carry the per-uuid URL key.")
        // Template fields ride through unchanged.
        XCTAssertEqual(provider.model, STTProvider.customOpenAICompat.model)
        XCTAssertEqual(provider.transport, STTProvider.customOpenAICompat.transport)
    }

    /// `TTSProvider.lookup` synthesizes a per-uuid provider with BOTH the
    /// per-uuid `dynamicEndpointKey` AND the per-uuid `sharedKeySTTPresetID`
    /// (`custom-openai_<uuid>`) — the load-bearing "one key, both directions" link.
    func testTTSLookupSynthesizesPerUUIDProviderWithSharedKeyLink() {
        let id = TTSProvider.customEndpointID(for: uuid)
        let provider = TTSProvider.lookup(id: id)
        XCTAssertEqual(provider.id, id)
        XCTAssertEqual(provider.dynamicEndpointKey, Constants.customSTTURLKey(for: uuid),
                       "Synthesized TTS provider must carry the per-uuid URL key.")
        XCTAssertEqual(provider.sharedKeySTTPresetID, STTProvider.customEndpointID(for: uuid),
                       "Synthesized TTS provider MUST point its shared key at the per-uuid STT slot (one key, both directions).")
        XCTAssertEqual(provider.model, TTSProvider.customOpenAITTS.model)
    }

    /// The bare legacy ids still resolve to the frozen singletons (migration-read).
    func testLegacyBareIDsResolveToSingletons() {
        XCTAssertEqual(STTProvider.lookup(id: "custom-openai").id, STTProvider.customOpenAICompat.id)
        XCTAssertEqual(STTProvider.lookup(id: "custom-openai").dynamicEndpointKey, "stt.custom.url")
        XCTAssertEqual(TTSProvider.lookup(id: "custom-openai-tts").id, TTSProvider.customOpenAITTS.id)
        XCTAssertEqual(TTSProvider.lookup(id: "custom-openai-tts").sharedKeySTTPresetID, "custom-openai")
    }

    // MARK: - Frozen arrays stay length-frozen (7-provider invariant)

    func testFrozenArraysUnchanged() {
        // Synthesizing providers must NEVER append to the registries.
        _ = STTProvider.lookup(id: STTProvider.customEndpointID(for: uuid))
        _ = TTSProvider.lookup(id: TTSProvider.customEndpointID(for: uuid))

        // Pin the EXACT archetype composition (the LOCKED, Keychain-suffix-bearing
        // IDs) rather than a bare count: a legitimate add/remove must be an
        // intentional edit here, and a synthesized per-uuid provider leaking into
        // the frozen array fails loudly. Qwen (`qwen-asr-flash`) is deliberately
        // UNLISTED (see STTProvider.allRegistered); OpenRouter STT+TTS ARE listed.
        XCTAssertEqual(
            STTProvider.allRegistered.map(\.id),
            ["mistral-voxtral", "openai-gpt4o-transcribe", "elevenlabs-scribe-v2",
             "gemini-3-1-flash-lite", "openrouter-stt", "apple-on-device", "custom-openai"],
            "STT archetype registry composition is LOCKED (synthesized per-uuid providers stay on-demand, never appended)."
        )
        XCTAssertEqual(
            TTSProvider.allRegistered.map(\.id),
            ["apple-tts", "openai-tts", "mistral-tts", "elevenlabs-tts",
             "gemini-tts", "openrouter-tts", "custom-openai-tts"],
            "TTS archetype registry composition is LOCKED."
        )
        XCTAssertFalse(STTProvider.allRegistered.contains(where: { STTProvider.customEndpointUUID(fromPresetID: $0.id) != nil }),
                       "No per-uuid STT provider may appear in the frozen array.")
        XCTAssertFalse(TTSProvider.allRegistered.contains(where: { TTSProvider.customEndpointUUID(fromProviderID: $0.id) != nil }),
                       "No per-uuid TTS provider may appear in the frozen array.")
    }

    // MARK: - CustomVoiceEndpoint record

    func testEndpointComputedIDs() {
        let endpoint = CustomVoiceEndpoint(id: uuid, name: "Deepgram")
        XCTAssertEqual(endpoint.sttPresetID, STTProvider.customEndpointID(for: uuid))
        XCTAssertEqual(endpoint.ttsProviderID, TTSProvider.customEndpointID(for: uuid))
    }

    func testEndpointJSONRoundTrips() throws {
        let endpoint = CustomVoiceEndpoint(id: uuid, name: "Whisper box")
        let data = try JSONEncoder().encode([endpoint])
        let back = try JSONDecoder().decode([CustomVoiceEndpoint].self, from: data)
        XCTAssertEqual(back.first?.id, uuid)
        XCTAssertEqual(back.first?.name, "Whisper box")
    }
}
