// Conduck
// TTSBodyFactory.swift
//
// Cloud Text-to-Speech foundation. Static-protocol that per-transport TTS
// request-body builders conform to, mirroring `Services/STT/STTJSONBodyFactory.swift`.
// `TTSProvider.bodyFactory` holds the metatype reference; a later `TTSClient`
// dispatches by `TTSProvider.transport` and calls `buildRequestBody`.
//
// Named static methods preferred over closures so stack traces show
// `OpenAISpeechBody.buildRequestBody` rather than an anonymous closure (same
// debuggability rationale as the STT body factories).
//
// NEVER log the `text` argument — it is the agent reply being read aloud
// (privacy-sensitive content; see the spec.md "Privacy & Security" section).

import Foundation

/// Per-transport TTS request-body conformance. One enum per wire shape
/// implements `buildRequestBody`; `TTSProvider.bodyFactory` holds the metatype
/// (`OpenAISpeechBody.self`, `MistralSpeechBody.self`, `ElevenLabsTTSBody.self`).
/// The Apple sentinel provider has a nil `bodyFactory` (it never reaches the
/// network).
protocol TTSBodyFactory {
    /// Construct the provider-specific JSON request body for a synthesis.
    ///
    /// - `text`: the text to speak (privacy-sensitive — never logged).
    /// - `model`: the wire-level model tag (`TTSProvider.model`).
    /// - `voice`: the already-resolved effective voice
    ///   (`TTSProvider.effectiveVoice(override:)`). For `.elevenLabs` the voice
    ///   rides the URL, not the body — `ElevenLabsTTSBody` ignores it for
    ///   signature parity.
    static func buildRequestBody(text: String, model: String, voice: String) throws -> Data
}

/// OpenAI `POST /v1/audio/speech` body — `gpt-4o-mini-tts` ONLY. Emits
/// `{"model":<model>,"input":<text>,"voice":<voice>,"response_format":"mp3"}`.
///
/// NOTE: Mistral is NOT shared here. Although it uses the same endpoint PATH,
/// its body field is `voice_id` (not `voice`) and its response is base64 JSON
/// (not raw bytes) — see `MistralSpeechBody` + `TTSProvider.ResponseShape`.
enum OpenAISpeechBody: TTSBodyFactory {
    static func buildRequestBody(text: String, model: String, voice: String) throws -> Data {
        // Ordered, explicit dictionary → `JSONSerialization`. The key set is
        // fixed (no user-controlled keys) so serialization cannot throw on a
        // bad type, but `try` keeps the protocol signature honest.
        let body: [String: Any] = [
            "model": model,
            "input": text,
            "voice": voice,
            "response_format": "mp3",
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [])
    }
}

/// Mistral `POST /v1/audio/speech` body — `voxtral-mini-tts-2603`. Like OpenAI's
/// but the voice field is `voice_id` (NOT `voice`); verified against
/// docs.mistral.ai/capabilities/audio/text_to_speech/speech. Emits
/// `{"model":<model>,"input":<text>,"voice_id":<voice>,"response_format":"mp3"}`.
/// The `voice` value is a slug from `GET /v1/audio/voices` (`en_paul_neutral`,
/// …) — only the JSON KEY differs from OpenAI's `voice`. The 2xx response is
/// JSON with base64 audio (`audio_data`), decoded by `TTSClient` per
/// `TTSProvider.responseDecoding`.
enum MistralSpeechBody: TTSBodyFactory {
    static func buildRequestBody(text: String, model: String, voice: String) throws -> Data {
        let body: [String: Any] = [
            "model": model,
            "input": text,
            "voice_id": voice,
            "response_format": "mp3",
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [])
    }
}

/// ElevenLabs `POST /v1/text-to-speech/{voice_id}` body. Voice + output format
/// ride the URL (path + `output_format` query, set in
/// `TTSProvider.effectiveSpeechURL(voice:)`), so the body carries only
/// `{"text":<text>,"model_id":<model>}`. The `voice` argument is accepted for
/// protocol parity and intentionally ignored here.
enum ElevenLabsTTSBody: TTSBodyFactory {
    static func buildRequestBody(text: String, model: String, voice _: String) throws -> Data {
        let body: [String: Any] = [
            "text": text,
            "model_id": model,
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [])
    }
}

/// Gemini `POST /v1beta/models/{model}:generateContent` body —
/// `gemini-3.1-flash-tts-preview`. The model rides the URL PATH (not the body),
/// so the `model` argument is intentionally ignored (signature parity, mirroring
/// `ElevenLabsTTSBody` ignoring `voice`). Emits the nested
/// `:generateContent` shape verified against
/// ai.google.dev/gemini-api/docs/speech-generation + a live curl probe:
/// ```
/// {"contents":[{"parts":[{"text":"Say the following:\n\n"<text>}]}],
///  "generationConfig":{"responseModalities":["AUDIO"],
///   "speechConfig":{"voiceConfig":{"prebuiltVoiceConfig":{"voiceName":<voice>}}}}}
/// ```
/// `voice` is a TITLE-CASE prebuilt name (`Kore`, `Charon`, …). The `text` is
/// never logged (privacy).
///
/// SAFETY-BLOCK FIX (load-bearing): the text is prefixed with a fixed
/// `"Say the following:"` directive. Sending the BARE reply text as the prompt
/// makes Gemini's prompt-safety classifier flag even innocuous sentences as
/// `promptFeedback.blockReason = PROHIBITED_CONTENT` — a 200 with NO
/// `candidates` and NO audio (reproduced 5/5 via live curl; `safetySettings:
/// BLOCK_NONE` does NOT override it — the block is a non-configurable
/// prompt-level category). Prefixing reframes the input as a TTS DIRECTIVE
/// rather than a free-form prompt, so the classifier passes and only the text
/// AFTER the directive is spoken (5/5 audio, EN + DE). The directive is an internal API instruction,
/// NOT user-facing → not localized (the model auto-detects the spoken
/// language from the text, so an English directive does not force English
/// pronunciation). Shared by iOS/macOS `TTSClient` AND watchOS `WatchTTSClient`
/// (both call this factory).
enum GeminiSpeechBody: TTSBodyFactory {
    /// Fixed TTS directive prepended to the spoken text — see the type doc.
    /// Speaks only the text after it; reframes the prompt past the
    /// PROHIBITED_CONTENT prompt-safety block.
    static let synthesisDirective = "Say the following:"

    static func buildRequestBody(text: String, model _: String, voice: String) throws -> Data {
        let prompt = "\(synthesisDirective)\n\n\(text)"
        let body: [String: Any] = [
            "contents": [
                ["parts": [["text": prompt]]],
            ],
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": [
                    "voiceConfig": [
                        "prebuiltVoiceConfig": [
                            "voiceName": voice,
                        ],
                    ],
                ],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [])
    }
}
