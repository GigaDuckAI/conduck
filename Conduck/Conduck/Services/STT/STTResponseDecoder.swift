// Conduck
// STTResponseDecoder.swift
//
// Multi-provider STT expansion. Provider-shape-driven
// decode for multipart-family responses. Both shapes project to the
// uniform `STTResponse(text:, language:)` so downstream code is wire-
// agnostic.

import Foundation

/// Per-provider JSON response shape for the multipart family. JSON-family
/// providers (Gemini / Qwen) decode through their own `STTJSONBodyFactory`
/// conformance — they do NOT go through this decoder.
enum STTResponseShape: Sendable, Equatable {
    /// `{ "text": String, "language": String? }` — Mistral Voxtral V2 +
    /// OpenAI `gpt-4o-transcribe`. Unknown fields (`duration`, `segments`,
    /// `model`, V2's diarization/words) are ignored.
    case openAICompat

    /// `{ "text": String, "language_code": String? }` — ElevenLabs
    /// Scribe v2. The `words[]` array is IGNORED: ElevenLabs guarantees
    /// the top-level `text` field is pre-filtered to spoken content (the
    /// `words` array's per-token `type` discriminator includes
    /// non-spoken events like `audio_event` / `spacing` that we'd
    /// otherwise have to filter ourselves). Trust the vendor pre-filter
    /// until UI surfaces a use-case for word-level metadata.
    case elevenLabs
}

/// Decodes a multipart-family JSON response into the uniform
/// `STTResponse` shape. JSON-family decoders live alongside their
/// provider files and conform to `STTJSONBodyFactory` instead.
enum STTResponseDecoder {
    static func decode(_ data: Data, shape: STTResponseShape) throws -> STTResponse {
        let rawText: String
        let language: String?
        do {
            switch shape {
            case .openAICompat:
                struct Payload: Decodable {
                    let text: String
                    let language: String?
                }
                let p = try JSONDecoder().decode(Payload.self, from: data)
                rawText = p.text
                language = p.language

            case .elevenLabs:
                struct Payload: Decodable {
                    let text: String
                    let language_code: String?
                }
                let p = try JSONDecoder().decode(Payload.self, from: data)
                rawText = p.text
                language = p.language_code
            }
        } catch {
            throw AppError.sttDecodingFailure
        }

        // A 2xx with a present-but-empty/whitespace transcript is "no speech",
        // NOT a shape failure — checked OUTSIDE the decode `do/catch` so it
        // isn't re-mapped to `sttDecodingFailure`. Mirrors the JSON-family
        // guards (Gemini/OpenRouter) so every provider funnels an empty result
        // to the same surfaced `noSpeechDetected`. Without this, the multipart
        // family (Mistral/OpenAI/ElevenLabs/custom-openai) silently returned ""
        // and the caller dead-ended (no error, no UI).
        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.noSpeechDetected
        }
        return STTResponse(text: rawText, language: language)
    }
}
