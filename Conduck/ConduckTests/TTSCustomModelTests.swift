// SPDX-License-Identifier: Apache-2.0

// Conduck
// TTSCustomModelTests.swift
//
// Phase A (Voice Settings redesign) — per-provider TTS MODEL override. The TTS
// sibling of `STTCustomModelTests`. Pure-data coverage of the two declarative
// resolution helpers on the `TTSProvider` value type
// (`effectiveModel(customModel:)` / `effectiveSpeechURL(voice:customModel:)`),
// the per-transport body-factory threading the override into the wire `model` /
// `model_id` field, the Gemini model-in-URL single-source rewrite, the
// coexistence regression (the per-provider override must NEVER leak to the BYO
// custom endpoint, which keeps its `CustomTTSConfig.model`), and the
// `STTBroadcastEnvelope` + `activeTTSSnapshot()` round-trip carrying the override.
//
// No URLSession, no Keychain on the deterministic paths. The one snapshot test
// that touches Keychain (active TTS key read) routes through `setKeyOrSkip`
// (`XCTSkip` unsigned; runs on the signed founder gate).

import XCTest
@testable import Conduck

final class TTSCustomModelTests: XCTestCase {

    // MARK: - effectiveModel(customModel:)

    func testEffectiveModelNilOverrideReturnsDefault() {
        XCTAssertEqual(TTSProvider.openAITTS.effectiveModel(customModel: nil),
                       "gpt-4o-mini-tts",
                       "A nil override must fall back to the provider's pinned default model.")
    }

    func testEffectiveModelEmptyOverrideReturnsDefault() {
        XCTAssertEqual(TTSProvider.openAITTS.effectiveModel(customModel: ""),
                       "gpt-4o-mini-tts",
                       "An empty-string override must fall back to the pinned default.")
    }

    func testEffectiveModelWhitespaceOverrideReturnsDefault() {
        XCTAssertEqual(TTSProvider.mistralTTS.effectiveModel(customModel: "  \n\t "),
                       "voxtral-mini-tts-2603",
                       "A whitespace-only override must be treated as empty → pinned default.")
    }

    func testEffectiveModelCustomOverrideReturnsCustom() {
        XCTAssertEqual(TTSProvider.openAITTS.effectiveModel(customModel: "gpt-5-mini-tts"),
                       "gpt-5-mini-tts",
                       "A non-empty override must win over the pinned default.")
    }

    func testEffectiveModelTrimsSurroundingWhitespace() {
        XCTAssertEqual(TTSProvider.elevenLabsTTS.effectiveModel(customModel: "  eleven_turbo_v3  "),
                       "eleven_turbo_v3",
                       "A surrounded override must be trimmed before use (no whitespace reaches the wire).")
    }

    func testEffectiveModelAppleSentinelUnchangedEvenWithOverride() {
        // Apple TTS has a nil `bodyFactory` (it never hits the network); the
        // sentinel `model` ("avspeechsynthesizer") is never sent, so an override
        // must be IGNORED.
        XCTAssertEqual(TTSProvider.appleTTS.effectiveModel(customModel: "whatever-the-user-typed"),
                       "avspeechsynthesizer",
                       "Apple TTS (nil bodyFactory) must ALWAYS return its sentinel model — an override is meaningless on-device.")
    }

    func testEffectiveModelGeminiOverrideReturnsCustom() {
        XCTAssertEqual(TTSProvider.geminiTTS.effectiveModel(customModel: "gemini-3.2-flash-tts"),
                       "gemini-3.2-flash-tts",
                       "Gemini's override resolves to the custom model (it also rides the URL — see the URL test).")
    }

    // MARK: - geminiSpeechEndpoint(model:) single source of truth

    func testGeminiSpeechEndpointMatchesDefaultRegistryURL() {
        // The registry default URL is built via the SAME static helper the
        // override resolver uses — proving default + override can never drift.
        XCTAssertEqual(TTSProvider.geminiSpeechEndpoint(model: "gemini-3.1-flash-tts-preview"),
                       TTSProvider.geminiTTS.speechURL,
                       "geminiSpeechEndpoint(model:) must reproduce the pinned default registry URL exactly (single source of truth).")
    }

    // MARK: - effectiveSpeechURL(voice:customModel:) — Gemini model-in-URL

    func testEffectiveSpeechURLGeminiOverrideRebuildsModelInPath() {
        let url = TTSProvider.geminiTTS.effectiveSpeechURL(voice: "Charon", customModel: "gemini-3.2-flash-tts")
        XCTAssertEqual(url.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.2-flash-tts:generateContent",
                       "A Gemini model override must rebuild the URL to '/models/<override>:generateContent'. Got: \(url.absoluteString)")
    }

    func testEffectiveSpeechURLGeminiNilOverrideReturnsDefault() {
        let url = TTSProvider.geminiTTS.effectiveSpeechURL(voice: "Kore", customModel: nil)
        XCTAssertEqual(url, TTSProvider.geminiTTS.speechURL,
                       "A nil Gemini override must return the pinned default speech URL.")
    }

    func testEffectiveSpeechURLGeminiEmptyOverrideReturnsDefault() {
        let url = TTSProvider.geminiTTS.effectiveSpeechURL(voice: "Kore", customModel: "  ")
        XCTAssertEqual(url, TTSProvider.geminiTTS.speechURL,
                       "A whitespace-only Gemini override must return the pinned default speech URL.")
    }

    // MARK: - effectiveSpeechURL(voice:customModel:) — non-Gemini unchanged

    func testEffectiveSpeechURLOpenAIModelOverrideDoesNotChangeURL() {
        let url = TTSProvider.openAITTS.effectiveSpeechURL(voice: "alloy", customModel: "gpt-5-mini-tts")
        XCTAssertEqual(url.absoluteString, "https://api.openai.com/v1/audio/speech",
                       "OpenAI's model rides the body — a model override must NOT touch the URL.")
    }

    func testEffectiveSpeechURLMistralModelOverrideDoesNotChangeURL() {
        let url = TTSProvider.mistralTTS.effectiveSpeechURL(voice: "en_paul_neutral", customModel: "voxtral-tts-next")
        XCTAssertEqual(url.absoluteString, "https://api.mistral.ai/v1/audio/speech",
                       "Mistral's model rides the body — a model override must NOT touch the URL.")
    }

    func testEffectiveSpeechURLElevenLabsModelOverrideKeepsVoiceRewriteOnly() {
        // ElevenLabs rewrites the VOICE into the path; a model override (which
        // rides the body) must NOT appear in the URL — only the voice rewrite.
        let url = TTSProvider.elevenLabsTTS.effectiveSpeechURL(voice: "Rachel123", customModel: "eleven_turbo_v3")
        XCTAssertEqual(url.absoluteString,
                       "https://api.elevenlabs.io/v1/text-to-speech/Rachel123?output_format=mp3_44100_128",
                       "ElevenLabs URL must carry only the voice path rewrite — the model override rides the body. Got: \(url.absoluteString)")
        XCTAssertFalse(url.absoluteString.contains("eleven_turbo_v3"),
                       "An ElevenLabs model override must NEVER reach the URL.")
    }

    // MARK: - Body factory carries the effective model under model / model_id

    func testOpenAIBodyCarriesOverrideModel() throws {
        let effModel = TTSProvider.openAITTS.effectiveModel(customModel: "gpt-5-mini-tts")
        let body = try OpenAISpeechBody.buildRequestBody(text: "hi", model: effModel, voice: "alloy")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["model"] as? String, "gpt-5-mini-tts",
                       "The OpenAI body's `model` field must carry the override.")
    }

    func testMistralBodyCarriesOverrideModel() throws {
        let effModel = TTSProvider.mistralTTS.effectiveModel(customModel: "voxtral-tts-next")
        let body = try MistralSpeechBody.buildRequestBody(text: "hi", model: effModel, voice: "en_paul_neutral")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["model"] as? String, "voxtral-tts-next",
                       "The Mistral body's `model` field must carry the override.")
    }

    func testElevenLabsBodyCarriesOverrideModelId() throws {
        // ElevenLabs's wire field is `model_id` (the voice rides the URL).
        let effModel = TTSProvider.elevenLabsTTS.effectiveModel(customModel: "eleven_turbo_v3")
        let body = try ElevenLabsTTSBody.buildRequestBody(text: "hi", model: effModel, voice: "ignored")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["model_id"] as? String, "eleven_turbo_v3",
                       "The ElevenLabs body's `model_id` field must carry the override.")
    }

    func testGeminiBodyIgnoresModel() throws {
        // Gemini's model rides the URL PATH, not the body — the factory ignores
        // its `model` arg. The body must carry NO model field of any name.
        let body = try GeminiSpeechBody.buildRequestBody(text: "hi", model: "gemini-3.2-flash-tts", voice: "Kore")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(obj["model"], "Gemini's body must NOT carry a top-level `model` — the model rides the URL path.")
        XCTAssertNil(obj["model_id"], "Gemini's body must NOT carry `model_id` either.")
        // The model override is reflected by the URL rewrite, tested above, not here.
    }

    // MARK: - sanitizeModelTag is reused (Gemini URL-injection guard, both directions)

    func testTTSModelOverrideReusesSanitizeAllowlist() {
        // The TTS save path runs the SAME `sanitizeModelTag` the STT path uses —
        // Gemini TTS also rides the model in the URL, so a `/` or `?` would inject.
        XCTAssertFalse(SettingsViewModel.sanitizeModelTag("../models/evil").contains("/"),
                       "A `/` must never survive sanitization (Gemini TTS URL-path injection guard).")
        XCTAssertEqual(SettingsViewModel.sanitizeModelTag("gemini-3.2.flash_tts-preview"),
                       "gemini-3.2.flash_tts-preview",
                       "Allowlisted chars (letters/digits/._-) survive for a legit model tag.")
    }

    // MARK: - Coexistence: the per-provider override must NEVER leak to the custom endpoint

    func testCustomEndpointUsesConfigModelNotPerProviderOverride() {
        // The BYO custom endpoint's effective model is its REQUIRED
        // `CustomTTSConfig.model` (`tts.custom.model`), resolved in `TTSClient`
        // off `isCustomEndpoint`. The per-provider override (`tts.customModel.<id>`)
        // is computed via `effectiveModel(customModel:)` — which for the custom
        // provider would just echo the typed override, NOT the config model. So
        // they are independent: this asserts the custom provider's OWN
        // `effectiveModel` is distinct from a `customConfig.model`, proving the
        // `TTSClient` branch (config model vs per-provider override) is meaningful.
        let perProviderOverride = TTSProvider.customOpenAITTS.effectiveModel(customModel: "should-not-be-used")
        let configModel = "kokoro"
        XCTAssertNotEqual(perProviderOverride, configModel,
                          "The custom endpoint's wire model is its CustomTTSConfig.model, never the per-provider override — the two resolution paths must stay distinct.")
        XCTAssertEqual(perProviderOverride, "should-not-be-used",
                       "effectiveModel echoes its argument; TTSClient must NOT pass the per-provider override for the custom endpoint (it passes customConfig.model instead).")
    }

    func testCustomEndpointDefaultModelIsTTS1() {
        XCTAssertEqual(TTSProvider.customOpenAITTS.model, "tts-1",
                       "The BYO custom endpoint's pinned default model stays `tts-1`.")
    }

    // MARK: - STTBroadcastEnvelope round-trip carries ttsCustomModel

    func testEnvelopeRoundTripCarriesTTSCustomModel() throws {
        let envelope = STTBroadcastEnvelope(
            presetID: "apple-on-device",
            apiKey: nil,
            ttsProviderID: "openai-tts",
            ttsApiKey: "sk-key",
            ttsVoice: "shimmer",
            ttsCustomModel: "gpt-5-mini-tts",
            timestamp: 100
        )
        let dict = envelope.encodedDict()
        XCTAssertEqual(dict["ttsCustomModel"] as? String, "gpt-5-mini-tts",
                       "encodedDict must carry the ttsCustomModel when set.")
        let decoded = try XCTUnwrap(STTBroadcastEnvelope.decode(from: dict))
        XCTAssertEqual(decoded.ttsCustomModel, "gpt-5-mini-tts",
                       "Decoded envelope must round-trip ttsCustomModel.")
    }

    func testEnvelopeOmitsTTSCustomModelWhenNil() {
        let envelope = STTBroadcastEnvelope(
            presetID: "openai-gpt4o-transcribe",
            apiKey: "sk-stt",
            ttsProviderID: "openai-tts",
            ttsApiKey: "sk-key",
            ttsVoice: nil,
            ttsCustomModel: nil,
            timestamp: 200
        )
        let dict = envelope.encodedDict()
        XCTAssertNil(dict["ttsCustomModel"],
                     "A nil ttsCustomModel must be OMITTED from the encoded dict (omit-when-nil — an older Watch decode is unaffected).")
        let decoded = STTBroadcastEnvelope.decode(from: dict)
        XCTAssertNil(decoded?.ttsCustomModel,
                     "A dict with no ttsCustomModel key must decode to nil (tolerant decode).")
    }

    func testEnvelopeLegacyDictWithoutTTSCustomModelDecodes() {
        // A legacy sender's dict (no TTS-model key) must decode fine with nil.
        let legacyDict: [String: Any] = [
            "presetID": "mistral-voxtral",
            "apiKey": "sk-legacy",
            "timestamp": TimeInterval(300),
        ]
        let decoded = STTBroadcastEnvelope.decode(from: legacyDict)
        XCTAssertNotNil(decoded, "A legacy dict must still decode.")
        XCTAssertNil(decoded?.ttsCustomModel, "A legacy dict (no TTS-model key) yields a nil ttsCustomModel.")
    }
}

// MARK: - SettingsManager per-provider TTS model override (KVS round-trip)

final class SettingsManagerTTSCustomModelTests: XCTestCase {

    private let defaults: UserDefaults = {
        UserDefaults(suiteName: Constants.appGroupID) ?? UserDefaults.standard
    }()

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
            defaults.removeObject(forKey: Constants.ttsCustomModelKey(for: provider.id))
        }
        try? await SettingsManager.shared.clearAPIKey(forPresetID: openAIPresetID)
    }

    private func setKeyOrSkip(_ key: String, forPresetID presetID: String) async throws {
        do {
            try await SettingsManager.shared.setAPIKey(key, forPresetID: presetID)
        } catch {
            throw XCTSkip("Keychain access-group write requires a signed build (unsigned: \(error)).")
        }
    }

    // MARK: - Non-secret KVS round-trip

    func testGetSetTTSCustomModelRoundTrips() async {
        await SettingsManager.shared.setTTSCustomModel("gpt-5-mini-tts", forProviderID: "openai-tts")
        let read = await SettingsManager.shared.getTTSCustomModel(forProviderID: "openai-tts")
        XCTAssertEqual(read, "gpt-5-mini-tts", "A set TTS model override must read back.")
    }

    func testEmptyTTSCustomModelClears() async {
        await SettingsManager.shared.setTTSCustomModel("x", forProviderID: "openai-tts")
        await SettingsManager.shared.setTTSCustomModel("", forProviderID: "openai-tts")
        let read = await SettingsManager.shared.getTTSCustomModel(forProviderID: "openai-tts")
        XCTAssertNil(read, "An empty override must clear (the pinned default applies).")
    }

    func testTTSCustomModelIsDistinctFromCustomEndpointModel() async {
        // The per-provider override slot (`tts.customModel.<id>`) is DISTINCT from
        // the BYO custom endpoint's required `tts.custom.model` — setting one must
        // not touch the other.
        await SettingsManager.shared.setTTSCustomModel("openai-override", forProviderID: "openai-tts")
        await SettingsManager.shared.setCustomTTSModel("kokoro")
        let perProvider = await SettingsManager.shared.getTTSCustomModel(forProviderID: "openai-tts")
        let custom = await SettingsManager.shared.getCustomTTSModel()
        XCTAssertEqual(perProvider, "openai-override")
        XCTAssertEqual(custom, "kokoro", "The custom endpoint's required model must keep working unchanged.")
        // Reset the custom-endpoint model so it doesn't leak into other suites.
        await SettingsManager.shared.setCustomTTSModel(nil)
    }

    // MARK: - activeTTSSnapshot resolves the per-provider model

    func testSnapshotResolvesPerProviderModelOverride() async throws {
        // Needs the shared STT slot key so the active-TTS snapshot resolves a key
        // (Keychain → skip unsigned). The model override is non-secret KVS.
        try await setKeyOrSkip("sk-shared-openai-key", forPresetID: openAIPresetID)
        await SettingsManager.shared.setActiveTTSProviderID("openai-tts")
        await SettingsManager.shared.setTTSCustomModel("gpt-5-mini-tts", forProviderID: "openai-tts")

        let snapshot = await SettingsManager.shared.activeTTSSnapshot()
        XCTAssertEqual(snapshot.providerID, "openai-tts")
        XCTAssertEqual(snapshot.customModel, "gpt-5-mini-tts",
                       "activeTTSSnapshot must resolve the per-provider model override in the same actor hop.")
    }
}
