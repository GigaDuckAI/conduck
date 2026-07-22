// Conduck
// TTSProviderRegistryTests.swift
//
// Cloud Text-to-Speech registry invariants. LOCKED provider IDs, the
// shared-STT-Keychain-slot mapping (`sharedKeySTTPresetID`), `effectiveVoice`
// override-vs-default, and `effectiveSpeechURL` (ElevenLabs path-rewrite +
// output_format query vs OpenAI/Mistral unchanged).
//
// The locked-id + shared-slot tests are load-bearing: renaming an id orphans a
// user's stored TTS selection + voice override, and changing a
// `sharedKeySTTPresetID` would point a vendor's TTS at the wrong Keychain slot.

import XCTest
@testable import Conduck

final class TTSProviderRegistryTests: XCTestCase {

    // MARK: - Locked IDs

    func testRegisteredProviderIDsAreLocked() {
        let ids = TTSProvider.allRegistered.map(\.id)
        XCTAssertEqual(ids, ["apple-tts", "openai-tts", "mistral-tts", "elevenlabs-tts", "gemini-tts", "openrouter-tts", "custom-openai-tts"],
                       "TTS provider IDs + order are LOCKED. A rename orphans a user's stored TTS selection + tts.voice.<id> override. The BYO custom endpoint is appended LAST.")
    }

    func testRegisteredProviderCountIsSeven() {
        XCTAssertEqual(TTSProvider.allRegistered.count, 7,
                       "Ships 7 TTS providers (Apple + OpenAI + Mistral + ElevenLabs + Gemini + OpenRouter + custom-openai-tts).")
    }

    func testAllRegistryIDsAreUnique() {
        let ids = TTSProvider.allRegistered.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "TTS provider IDs must be unique. Raw: \(ids)")
    }

    func testLookupFallsBackToApple() {
        XCTAssertEqual(TTSProvider.lookup(id: "no-such-provider").id, "apple-tts",
                       "Unknown id must fall back to the Apple sentinel (default + keyless offline fallback).")
        XCTAssertEqual(TTSProvider.lookup(id: "openai-tts").id, "openai-tts")
    }

    // MARK: - Shared STT Keychain slot mapping

    func testSharedKeySTTPresetIDMapping() {
        XCTAssertNil(TTSProvider.appleTTS.sharedKeySTTPresetID,
                     "Apple sentinel has no key slot.")
        XCTAssertEqual(TTSProvider.openAITTS.sharedKeySTTPresetID, "openai-gpt4o-transcribe",
                       "OpenAI TTS must read the SAME Keychain slot as OpenAI STT.")
        XCTAssertEqual(TTSProvider.mistralTTS.sharedKeySTTPresetID, "mistral-voxtral",
                       "Mistral TTS must read the SAME Keychain slot as Mistral Voxtral STT.")
        XCTAssertEqual(TTSProvider.elevenLabsTTS.sharedKeySTTPresetID, "elevenlabs-scribe-v2",
                       "ElevenLabs TTS must read the SAME Keychain slot as ElevenLabs Scribe STT.")
        XCTAssertEqual(TTSProvider.geminiTTS.sharedKeySTTPresetID, "gemini-3-1-flash-lite",
                       "Gemini TTS must read the SAME Keychain slot as Gemini STT (one key, both directions).")
        XCTAssertEqual(TTSProvider.openRouterTTS.sharedKeySTTPresetID, "openrouter-stt",
                       "OpenRouter TTS must read the SAME Keychain slot as OpenRouter STT (one key, both directions; also cross-reusable with the OpenRouter gateway token).")
        XCTAssertEqual(TTSProvider.customOpenAITTS.sharedKeySTTPresetID, "custom-openai",
                       "Custom TTS must read the SAME Keychain slot as the custom STT endpoint (one server, both directions).")
    }

    // MARK: - Custom BYO endpoint (dynamic URL + cert pin)

    func testCustomTTSWireContract() {
        let p = TTSProvider.customOpenAITTS
        XCTAssertEqual(p.id, "custom-openai-tts")
        XCTAssertEqual(p.model, "tts-1", "Default custom TTS model is the de-facto OpenAI-compatible tag tts-1 (user-overridable).")
        XCTAssertEqual(p.transport, .openAISpeech)
        XCTAssertEqual(p.auth, .bearer, "Default scheme is .bearer; the effective scheme (.bearer/.none) rides CustomTTSConfig.")
        XCTAssertEqual(p.defaultVoice, "alloy")
        XCTAssertTrue(Self.factoryIs(p.bodyFactory, OpenAISpeechBody.self),
                      "Custom TTS reuses OpenAISpeechBody ({model,input,voice,response_format:mp3}).")
        XCTAssertEqual(p.responseDecoding, .rawAudio, "OpenAI-compatible /v1/audio/speech returns raw audio bytes.")
        XCTAssertEqual(p.speechURL.absoluteString, "x-conduck-custom-tts://synthesize",
                       "speechURL is a SENTINEL — the real URL resolves from the stored base via SettingsManager.customTTSSpeechURL().")
    }

    func testOnlyCustomCarriesDynamicEndpointKey() {
        // Declarative dispatch invariant: ONLY the BYO custom endpoint resolves
        // its URL dynamically + cert-pins. A future refactor that flipped a frozen
        // provider's key would route it through the dynamic-URL/pinning path.
        for provider in TTSProvider.allRegistered where provider.id != "custom-openai-tts" {
            XCTAssertNil(provider.dynamicEndpointKey,
                         "Frozen provider \(provider.id) must have dynamicEndpointKey == nil.")
        }
        XCTAssertEqual(TTSProvider.customOpenAITTS.dynamicEndpointKey, "stt.custom.url",
                       "Custom TTS shares the custom STT base URL key (stt.custom.url) — one server, both directions.")
    }

    // MARK: - Wire-level contract (model / auth / transport / default voice)

    func testOpenAIWireContract() {
        let p = TTSProvider.openAITTS
        XCTAssertEqual(p.model, "gpt-4o-mini-tts")
        XCTAssertEqual(p.transport, .openAISpeech)
        XCTAssertEqual(p.auth, .bearer)
        XCTAssertEqual(p.defaultVoice, "alloy")
        XCTAssertEqual(p.speechURL.absoluteString, "https://api.openai.com/v1/audio/speech")
        XCTAssertTrue(Self.factoryIs(p.bodyFactory, OpenAISpeechBody.self),
                      "OpenAI must use OpenAISpeechBody (`voice`).")
        XCTAssertEqual(p.responseDecoding, .rawAudio, "OpenAI returns raw mp3 bytes.")
    }

    func testMistralWireContract() {
        let p = TTSProvider.mistralTTS
        XCTAssertEqual(p.model, "voxtral-mini-tts-2603")
        XCTAssertEqual(p.transport, .openAISpeech)
        XCTAssertEqual(p.auth, .bearer)
        XCTAssertEqual(p.defaultVoice, "en_paul_neutral",
                       "Mistral default must be a real `GET /v1/audio/voices` slug; `neutral_female` 404s on the cloud API.")
        XCTAssertEqual(p.speechURL.absoluteString, "https://api.mistral.ai/v1/audio/speech")
        XCTAssertTrue(Self.factoryIs(p.bodyFactory, MistralSpeechBody.self),
                      "Mistral must use MistralSpeechBody (`voice_id`), NOT OpenAISpeechBody.")
        XCTAssertEqual(p.responseDecoding, .base64JSON(field: "audio_data"),
                       "Mistral returns JSON with base64 audio under `audio_data`, not raw bytes.")
    }

    func testElevenLabsWireContract() {
        let p = TTSProvider.elevenLabsTTS
        XCTAssertEqual(p.model, "eleven_flash_v2_5")
        XCTAssertEqual(p.transport, .elevenLabs)
        XCTAssertEqual(p.auth, .headerName("xi-api-key"))
        XCTAssertEqual(p.defaultVoice, "9BWtsMINqrJLrRacOk9x",
                       "ElevenLabs default must be Aria (current premade); Rachel `21m00…` is deprecating (expires 2026-12-31).")
        XCTAssertTrue(Self.factoryIs(p.bodyFactory, ElevenLabsTTSBody.self),
                      "ElevenLabs must use ElevenLabsTTSBody.")
        XCTAssertEqual(p.responseDecoding, .rawAudio, "ElevenLabs returns raw mp3 bytes.")
    }

    func testGeminiWireContract() {
        let p = TTSProvider.geminiTTS
        XCTAssertEqual(p.id, "gemini-tts")
        XCTAssertEqual(p.model, "gemini-3.1-flash-tts-preview")
        XCTAssertEqual(p.transport, .generateContent)
        XCTAssertEqual(p.auth, .headerName("x-goog-api-key"),
                       "Gemini TTS must use the x-goog-api-key header — identical to Gemini STT.")
        XCTAssertEqual(p.defaultVoice, "Kore",
                       "Gemini default is the title-case prebuilt voice `Kore` (live-verified 200).")
        XCTAssertEqual(p.outputFormat, .wav,
                       "Gemini returns headerless PCM wrapped in a WAV container at the decode chokepoint.")
        XCTAssertEqual(p.speechURL.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-tts-preview:generateContent")
        XCTAssertTrue(Self.factoryIs(p.bodyFactory, GeminiSpeechBody.self),
                      "Gemini must use GeminiSpeechBody (nested :generateContent shape).")
        XCTAssertEqual(p.responseDecoding, .geminiInlineAudio,
                       "Gemini audio is base64 inlineData → WAV-wrapped PCM, not raw mp3.")
    }

    func testGeminiSpeechURLUnchanged() {
        // `.generateContent` falls through `effectiveSpeechURL` (voice rides the
        // body, model rides the URL path) — the URL must be unchanged.
        let url = TTSProvider.geminiTTS.effectiveSpeechURL(voice: "Charon")
        XCTAssertEqual(url.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-tts-preview:generateContent",
                       "Gemini voice rides the body — the URL must be unchanged.")
    }

    // MARK: - Voice-vendor row (Gemini now shippable; Qwen still coming)

    func testGeminiVendorRowIsShippable() {
        XCTAssertEqual(VoiceVendorRegistry.gemini.ttsProviderID, "gemini-tts",
                       "The Gemini vendor row must point at the gemini-tts provider.")
        XCTAssertEqual(VoiceVendorRegistry.gemini.ttsStatus, .available,
                       "Gemini TTS is shipped via gemini-3.1-flash-tts-preview.")
    }

    /// Qwen is UNLISTED from `VoiceVendorRegistry.all` (pulled pending live
    /// STT verification), so it no longer renders a row — but the `static let
    /// qwen` definition is RETAINED for a one-line re-list. This guards that
    /// retained definition's TTS shape (still unshipped) so re-listing brings
    /// back a correct "coming soon" row, not a broken one.
    func testRetainedQwenVendorDefStaysComing() {
        XCTAssertNil(VoiceVendorRegistry.qwen.ttsProviderID,
                     "Qwen TTS is still not shipped — no provider id.")
        XCTAssertEqual(VoiceVendorRegistry.qwen.ttsStatus, .coming,
                       "Retained Qwen vendor def must keep its 'coming soon' TTS shape for a clean re-list.")
    }

    func testAppleSentinelNeverHitsClient() {
        let p = TTSProvider.appleTTS
        XCTAssertNil(p.bodyFactory, "Apple sentinel has no body factory — it never reaches TTSClient.")
        XCTAssertEqual(p.auth, .none)
        XCTAssertEqual(p.responseDecoding, .rawAudio, "Apple sentinel's decoding is unused but defaults to rawAudio.")
    }

    /// Compare a `TTSBodyFactory.Type?` against a concrete factory type by
    /// identity — metatypes aren't directly `Equatable`, so use `ObjectIdentifier`.
    private static func factoryIs(_ factory: TTSBodyFactory.Type?, _ expected: TTSBodyFactory.Type) -> Bool {
        guard let factory else { return false }
        return ObjectIdentifier(factory) == ObjectIdentifier(expected)
    }

    // MARK: - effectiveVoice (override vs default)

    func testEffectiveVoiceUsesOverrideWhenPresent() {
        XCTAssertEqual(TTSProvider.openAITTS.effectiveVoice(override: "shimmer"), "shimmer")
    }

    func testEffectiveVoiceFallsBackToDefault() {
        XCTAssertEqual(TTSProvider.openAITTS.effectiveVoice(override: nil), "alloy")
        XCTAssertEqual(TTSProvider.openAITTS.effectiveVoice(override: ""), "alloy",
                       "Empty override is treated as no override.")
        XCTAssertEqual(TTSProvider.openAITTS.effectiveVoice(override: "   "), "alloy",
                       "Whitespace-only override is treated as no override.")
    }

    func testEffectiveVoiceTrimsOverride() {
        XCTAssertEqual(TTSProvider.openAITTS.effectiveVoice(override: "  echo  "), "echo")
    }

    // MARK: - effectiveSpeechURL (ElevenLabs path-rewrite vs others unchanged)

    func testEffectiveSpeechURLElevenLabsRewritesVoicePathAndFormat() {
        let url = TTSProvider.elevenLabsTTS.effectiveSpeechURL(voice: "Rachel123")
        XCTAssertEqual(url.absoluteString,
                       "https://api.elevenlabs.io/v1/text-to-speech/Rachel123?output_format=mp3_44100_128",
                       "ElevenLabs must append /{voice_id} to the path + the mp3_44100_128 output_format query.")
    }

    func testEffectiveSpeechURLOpenAIUnchanged() {
        let url = TTSProvider.openAITTS.effectiveSpeechURL(voice: "alloy")
        XCTAssertEqual(url.absoluteString, "https://api.openai.com/v1/audio/speech",
                       "OpenAI voice rides the body — the URL must be unchanged.")
    }

    func testEffectiveSpeechURLMistralUnchanged() {
        let url = TTSProvider.mistralTTS.effectiveSpeechURL(voice: "en_paul_neutral")
        XCTAssertEqual(url.absoluteString, "https://api.mistral.ai/v1/audio/speech",
                       "Mistral voice rides the body — the URL must be unchanged.")
    }

    func testEffectiveSpeechURLElevenLabsPercentEncodesVoice() {
        // A user-pasted custom voice id with a space must be percent-encoded
        // so URL composition cannot break.
        let url = TTSProvider.elevenLabsTTS.effectiveSpeechURL(voice: "my voice")
        XCTAssertTrue(url.absoluteString.contains("my%20voice"),
                      "ElevenLabs voice segment must be percent-encoded. Got: \(url.absoluteString)")
    }
}
