// SPDX-License-Identifier: Apache-2.0

// Conduck
// OpenRouterSTTTests.swift
//
// Covers the OpenRouter voice provider added on the openrouter-voice branch:
//   - `OpenRouterSTT` JSON body factory (container sniff, body shape, decode).
//   - The STT + TTS registry entries (locked ids, transport, shared key slot).
//   - `modelInURL` + the slash-aware `sanitizeModelTag` (Blocker 1: OpenRouter
//     model IDs like `openai/whisper-large-v3` must keep their `/`).
//   - The cross-reuse preset-id constant (wired to the registry id).
//
// The actual key-copy round-trip (gateway ⇄ voice) is Keychain-backed and
// validated at the signed founder gate, not here.

import XCTest
@testable import Conduck

final class OpenRouterSTTTests: XCTestCase {

    // MARK: - Container sniff (Blocker 2: format is not always m4a)

    func testDetectFormatRecognizesM4A() {
        // ISO base-media: "ftyp" box type at offset 4.
        var bytes: [UInt8] = [0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70] // ....ftyp
        bytes += [0x4D, 0x34, 0x41, 0x20] // "M4A "
        XCTAssertEqual(OpenRouterSTT.detectFormat(Data(bytes)), "m4a")
    }

    func testDetectFormatRecognizesWAV() {
        // "RIFF....WAVE"
        let bytes: [UInt8] = [0x52, 0x49, 0x46, 0x46, 0x24, 0x00, 0x00, 0x00, 0x57, 0x41, 0x56, 0x45]
        XCTAssertEqual(OpenRouterSTT.detectFormat(Data(bytes)), "wav")
    }

    func testDetectFormatDefaultsToM4AForUnknownOrShort() {
        XCTAssertEqual(OpenRouterSTT.detectFormat(Data([0x01, 0x02, 0x03])), "m4a",
                       "Too-short buffer must default to m4a (the dominant case).")
        let unknown: [UInt8] = Array(repeating: 0xAB, count: 16)
        XCTAssertEqual(OpenRouterSTT.detectFormat(Data(unknown)), "m4a",
                       "Unrecognized signature must default to m4a.")
    }

    // MARK: - Request body shape

    private func decodeBody(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testBuildRequestBodyEncodesInputAudioModelAndLanguage() throws {
        let m4a = Data([0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41, 0x20, 0xDE, 0xAD])
        let body = try OpenRouterSTT.buildRequestBody(audioData: m4a, language: "en", model: "openai/whisper-large-v3")
        let json = try decodeBody(body)

        XCTAssertEqual(json["model"] as? String, "openai/whisper-large-v3",
                       "model rides the JSON body (not the URL).")
        XCTAssertEqual(json["language"] as? String, "en")
        let inputAudio = try XCTUnwrap(json["input_audio"] as? [String: Any])
        XCTAssertEqual(inputAudio["format"] as? String, "m4a")
        XCTAssertEqual(inputAudio["data"] as? String, m4a.base64EncodedString(),
                       "Audio is sent as base64 in input_audio.data.")
    }

    func testBuildRequestBodyOmitsLanguageWhenNilOrEmpty() throws {
        let audio = Data([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x41, 0x56, 0x45])
        for lang in [nil, "", "   "] as [String?] {
            let body = try OpenRouterSTT.buildRequestBody(audioData: audio, language: lang, model: "m")
            let json = try decodeBody(body)
            XCTAssertNil(json["language"], "language must be omitted when nil/empty (auto-detect), got \(String(describing: json["language"])) for input \(String(describing: lang)).")
            // The WAV magic should be reflected in the sniffed format.
            let inputAudio = try XCTUnwrap(json["input_audio"] as? [String: Any])
            XCTAssertEqual(inputAudio["format"] as? String, "wav")
        }
    }

    // MARK: - Response decode

    func testDecodeResponseTrimsText() throws {
        let data = Data(#"{"text":"  hello world  "}"#.utf8)
        let response = try OpenRouterSTT.decodeResponse(data)
        XCTAssertEqual(response.text, "hello world")
        XCTAssertNil(response.language)
    }

    func testDecodeResponseRejectsWhitespaceOnly() {
        let data = Data(#"{"text":"   "}"#.utf8)
        // A 2xx with no usable transcript is "no speech detected", surfaced
        // uniformly across providers — not silently swallowed, not a shape error.
        XCTAssertThrowsError(try OpenRouterSTT.decodeResponse(data),
                             "A whitespace-only transcript must throw, not silently swallow the audio.") { error in
            guard let appErr = error as? AppError, case .noSpeechDetected = appErr else {
                return XCTFail("Expected .noSpeechDetected, got \(error)")
            }
        }
    }

    func testDecodeResponseRejectsMissingTextAndMalformed() {
        XCTAssertThrowsError(try OpenRouterSTT.decodeResponse(Data(#"{"usage":{}}"#.utf8)))
        XCTAssertThrowsError(try OpenRouterSTT.decodeResponse(Data("not json".utf8)))
    }

    // MARK: - Registry entries

    func testSTTProviderEntry() {
        let p = STTProvider.openRouter
        XCTAssertEqual(p.id, "openrouter-stt")
        XCTAssertEqual(p.transport, .json)
        XCTAssertNotNil(p.jsonBodyFactory, "OpenRouter STT uses the JSON body-factory path.")
        XCTAssertEqual(p.model, "openai/whisper-large-v3")
        XCTAssertNil(p.dynamicEndpointKey, "A frozen cloud provider must keep dynamicEndpointKey == nil (no cert-pin path).")
        XCTAssertFalse(p.modelInURL, "OpenRouter's model rides the body — slash-bearing IDs must survive sanitization.")
        XCTAssertEqual(p.probeURL?.absoluteString, "https://openrouter.ai/api/v1/key",
                       "Key validation reuses GET /v1/key (OpenRouter's /v1/models is public).")
        XCTAssertEqual(p.transcribeURL.absoluteString, "https://openrouter.ai/api/v1/audio/transcriptions")
    }

    func testSTTLookupReturnsOpenRouterNotFallback() {
        XCTAssertEqual(STTProvider.lookup(id: "openrouter-stt").id, "openrouter-stt",
                       "A miss would mean the entry was dropped from allRegistered (lookup falls back to Mistral).")
    }

    func testKeychainAccountIsLocked() {
        XCTAssertEqual(Constants.sttApiKeyKeychainAccount(for: "openrouter-stt"),
                       "stt.apiKey.openrouter-stt")
    }

    func testTTSProviderEntry() {
        let p = TTSProvider.openRouterTTS
        XCTAssertEqual(p.id, "openrouter-tts")
        XCTAssertEqual(p.transport, .openAISpeech)
        XCTAssertEqual(p.responseDecoding, .rawAudio)
        XCTAssertEqual(p.sharedKeySTTPresetID, "openrouter-stt",
                       "One key, both directions — and cross-reusable with the OpenRouter gateway token.")
        XCTAssertEqual(p.model, "x-ai/grok-voice-tts-1.0",
                       "Default TTS model is founder-selected + funded-key-verified live.")
        XCTAssertEqual(p.defaultVoice, "Eve")
        XCTAssertFalse(p.modelInURL, "OpenRouter TTS model rides the body.")
    }

    // MARK: - modelInURL (drives slash-aware sanitization)

    func testModelInURLOnlyForGemini() {
        XCTAssertTrue(STTProvider.geminiFlashLite.modelInURL, "Gemini STT model lives in the URL path.")
        XCTAssertFalse(STTProvider.openRouter.modelInURL)
        XCTAssertFalse(STTProvider.openAITranscribe.modelInURL)
        XCTAssertTrue(TTSProvider.geminiTTS.modelInURL, "Gemini TTS (.generateContent) model lives in the URL path.")
        XCTAssertFalse(TTSProvider.openRouterTTS.modelInURL)
    }

    // MARK: - Slash-aware sanitizer (Blocker 1)

    func testSanitizeModelTagPreservesSlashWhenAllowed() {
        XCTAssertEqual(SettingsViewModel.sanitizeModelTag("openai/whisper-large-v3", allowsSlash: true),
                       "openai/whisper-large-v3",
                       "Body-model providers (OpenRouter) MUST keep the slash — it's part of the model id.")
    }

    func testSanitizeModelTagStripsSlashByDefault() {
        XCTAssertFalse(SettingsViewModel.sanitizeModelTag("gpt/4o").contains("/"),
                       "Default (URL-path / Gemini) still strips the slash — the injection guard.")
        XCTAssertEqual(SettingsViewModel.sanitizeModelTag("gpt/4o"), "gpt4o")
    }

    // MARK: - Cross-reuse constant

    func testReusePresetIDMatchesRegistry() {
        XCTAssertEqual(SettingsViewModel.openRouterVoiceSTTPresetID, "openrouter-stt")
        XCTAssertEqual(SettingsViewModel.openRouterVoiceSTTPresetID, STTProvider.openRouter.id,
                       "The cross-reuse plumbing must target the same locked id as the registry entry.")
    }
}
