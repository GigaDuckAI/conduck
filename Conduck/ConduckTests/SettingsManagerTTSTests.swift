// SPDX-License-Identifier: Apache-2.0

// Conduck
// SettingsManagerTTSTests.swift
//
// Cloud Text-to-Speech — `SettingsManager` TTS storage round-trip +
// `activeTTSSnapshot()` reading the SHARED STT Keychain slot. Mirrors the
// `STTCustomModelTests` / `SettingsManagerRemoteAgentTests` shape:
//   - Non-secret active-provider + voice override → App Groups + iCloud KVS
//     (no signing required; round-trips deterministically).
//   - `activeTTSSnapshot()`'s key read hits the shared `stt.apiKey.<…>`
//     Keychain slot, which needs the access-group entitlement → routed through
//     `setKeyOrSkip` (`XCTSkip` on an unsigned headless build; executed on the
//     signed founder-gate run).
//
// Test isolation: every test wipes the relevant App-Group + Keychain slots in
// setUp / tearDown (the actor is a `static let shared` singleton).

import XCTest
@testable import Conduck

final class SettingsManagerTTSTests: XCTestCase {

    private let defaults = TestStores.defaults

    /// The shared STT slot the OpenAI vendor's TTS reads its key from.
    private let openAIPresetID = "openai-gpt4o-transcribe"

    override func setUp() async throws {
        try await super.setUp()
        await wipe()
    }

    override func tearDown() async throws {
        await wipe()
        try await super.tearDown()
    }

    private func wipe() async {
        defaults.removeObject(forKey: Constants.ttsActiveProviderIDKVSKey)
        for provider in TTSProvider.allRegistered {
            defaults.removeObject(forKey: Constants.ttsVoiceKey(for: provider.id))
        }
        try? await SettingsManager.shared.clearAPIKey(forPresetID: openAIPresetID)
    }

    /// Shared-slot key setter, skipping on an unsigned build (the access-group
    /// Keychain write needs the entitlement — same posture as the remote-agent
    /// token tests).
    private func setKeyOrSkip(_ key: String, forPresetID presetID: String) async throws {
        do {
            try await SettingsManager.shared.setAPIKey(key, forPresetID: presetID)
        } catch {
            throw XCTSkip("Keychain access-group write requires a signed build (unsigned: \(error)).")
        }
    }

    // MARK: - Active TTS provider pointer (non-secret KVS round-trip)

    func testActiveTTSProviderDefaultsToApple() async {
        let id = await SettingsManager.shared.getActiveTTSProviderID()
        XCTAssertEqual(id, "apple-tts",
                       "Fresh install default TTS provider must be apple-tts (free, offline, the fallback).")
        XCTAssertEqual(Constants.ttsActiveProviderIDDefault, "apple-tts")
    }

    func testActiveTTSProviderRoundTrips() async {
        await SettingsManager.shared.setActiveTTSProviderID("elevenlabs-tts")
        let id = await SettingsManager.shared.getActiveTTSProviderID()
        XCTAssertEqual(id, "elevenlabs-tts", "Active TTS provider must round-trip through App Groups/KVS.")
    }

    // MARK: - Voice override (non-secret KVS round-trip)

    func testTTSVoiceDefaultsToNil() async {
        let voice = await SettingsManager.shared.getTTSVoice(forProviderID: "openai-tts")
        XCTAssertNil(voice, "No override → nil (the provider's pinned defaultVoice applies).")
    }

    func testTTSVoiceRoundTrips() async {
        await SettingsManager.shared.setTTSVoice("nova", forProviderID: "openai-tts")
        let voice = await SettingsManager.shared.getTTSVoice(forProviderID: "openai-tts")
        XCTAssertEqual(voice, "nova", "Voice override must round-trip.")
    }

    func testTTSVoiceEmptyClearsOverride() async {
        await SettingsManager.shared.setTTSVoice("nova", forProviderID: "openai-tts")
        await SettingsManager.shared.setTTSVoice("", forProviderID: "openai-tts")
        let voice = await SettingsManager.shared.getTTSVoice(forProviderID: "openai-tts")
        XCTAssertNil(voice, "An empty voice must clear the override → nil.")
    }

    // MARK: - activeTTSSnapshot() reads the SHARED STT slot

    func testSnapshotAppleHasNoKey() async {
        await SettingsManager.shared.setActiveTTSProviderID("apple-tts")
        let snapshot = await SettingsManager.shared.activeTTSSnapshot()
        XCTAssertEqual(snapshot.providerID, "apple-tts")
        XCTAssertNil(snapshot.apiKey, "Apple TTS is keyless — snapshot.apiKey must be nil.")
        XCTAssertEqual(snapshot.keyState, .notRequired,
                       "Apple TTS needs no key — keyState is .notRequired.")
    }

    func testSnapshotReadsSharedSTTKeyForCloudProvider() async throws {
        // Write the key into the SHARED STT slot (the OpenAI vendor's slot),
        // then make OpenAI the active TTS provider — the snapshot must read that
        // SAME slot (zero migration).
        try await setKeyOrSkip("sk-shared-openai-key", forPresetID: openAIPresetID)
        await SettingsManager.shared.setActiveTTSProviderID("openai-tts")
        await SettingsManager.shared.setTTSVoice("alloy", forProviderID: "openai-tts")

        let snapshot = await SettingsManager.shared.activeTTSSnapshot()
        XCTAssertEqual(snapshot.providerID, "openai-tts")
        XCTAssertEqual(snapshot.apiKey, "sk-shared-openai-key",
                       "activeTTSSnapshot must read the TTS key from the vendor's SHARED stt.apiKey slot.")
        XCTAssertEqual(snapshot.keyState, .present,
                       "A resolved non-empty key yields keyState .present (the apiKey⇔present invariant).")
        XCTAssertEqual(snapshot.voice, "alloy")
    }

    // MARK: - currentBroadcastEnvelope carries the TTS triple

    func testBroadcastEnvelopeCarriesTTSWhenAppleSTTButCloudTTSKeyed() async throws {
        // STT = Apple (keyless), TTS = OpenAI (cloud, keyed). The envelope must
        // STILL ship (the guard fix) and carry the TTS triple so the Watch
        // doesn't strand cloud TTS on its default.
        try await setKeyOrSkip("sk-shared-openai-key", forPresetID: openAIPresetID)
        await SettingsManager.shared.setActivePresetID("apple-on-device")
        await SettingsManager.shared.setActiveTTSProviderID("openai-tts")

        let envelope = await SettingsManager.shared.currentBroadcastEnvelope()
        let unwrapped = try XCTUnwrap(envelope,
            "An Apple-STT + keyed-cloud-TTS state must still produce a broadcast envelope.")
        XCTAssertEqual(unwrapped.presetID, "apple-on-device")
        XCTAssertNil(unwrapped.apiKey, "STT side is keyless Apple → STT apiKey nil.")
        XCTAssertEqual(unwrapped.ttsProviderID, "openai-tts")
        XCTAssertEqual(unwrapped.ttsApiKey, "sk-shared-openai-key",
                       "The envelope must carry the TTS key from the shared slot.")
    }
}
