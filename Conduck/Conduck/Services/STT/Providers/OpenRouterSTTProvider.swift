// SPDX-License-Identifier: Apache-2.0

// Conduck
// OpenRouterSTTProvider.swift
//
// JSON-family STT provider for OpenRouter's dedicated transcription endpoint
// (`POST /api/v1/audio/transcriptions`, shipped 2026-05-01). `OpenRouterSTT`
// conforms to `STTJSONBodyFactory` with named static methods for stack-trace
// clarity (see `STTJSONBodyFactory.swift` rationale).
//
// Wire shape (verified June 2026 against openrouter.ai/docs):
//   request : { input_audio: { data: "<base64>", format: "m4a"|"wav" },
//               model: "<id>", language?: "<ISO-639-1>" }
//   response: { text: "<transcript>", usage?: { … } }
//
// Two divergences from the OpenAI native transcription endpoint, both
// load-bearing:
//   1. The request is JSON + base64 (`input_audio.data`), NOT multipart
//      `file=` — so this is the `.json` transport, not `.multipart`.
//   2. The `model` rides the BODY (not the URL path like Gemini), so the
//      effective model tag (default / user override) is encoded here.
//
// Unlike `GeminiSTT` there is NO defensive transcription prompt: this is a
// dedicated transcription endpoint that returns `{text}`, not an LLM
// `generateContent` call with a steerable system prompt — there is no prompt
// surface to inject into.
//
// Audio format is SNIFFED from the container magic bytes rather than hardcoded:
// `AudioCompressor` returns AAC-in-M4A normally but falls back to WAV (or the
// original bytes) in edge cases, so a fixed `format:"m4a"` would mislabel a WAV
// payload. `format` is provider-passthrough on OpenRouter (decode depends on the
// routed model's provider), so an accurate label matters.

import Foundation

enum OpenRouterSTT: STTJSONBodyFactory {

    /// Detect the audio container from its leading magic bytes so the wire
    /// `format` field is truthful regardless of which `AudioCompressor` path
    /// produced the bytes. `RIFF` (bytes 0–3) → WAV; `ftyp` (bytes 4–7) → an
    /// MPEG-4 / M4A container (what the AAC recorder emits). Defaults to `m4a`
    /// (the dominant case) when the signature is unrecognized — OpenRouter
    /// documents `m4a` on both audio endpoints.
    static func detectFormat(_ data: Data) -> String {
        if data.count >= 12 {
            let bytes = [UInt8](data.prefix(12))
            // "RIFF" .... "WAVE" — accept on the RIFF marker alone.
            if bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46 {
                return "wav"
            }
            // "ftyp" box type at offset 4 — ISO base media (M4A/MP4/AAC-in-MP4).
            if bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
                return "m4a"
            }
        }
        return "m4a"
    }

    static func buildRequestBody(audioData: Data, language: String?, model: String) throws -> Data {
        let trimmedLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = OpenRouterRequest(
            inputAudio: .init(
                data: audioData.base64EncodedString(),
                format: detectFormat(audioData)
            ),
            model: model,
            // Omit `language` entirely when nil/empty (auto-detect) — never send
            // an empty string the server might reject.
            language: (trimmedLanguage?.isEmpty == false) ? trimmedLanguage : nil
        )
        return try JSONEncoder().encode(body)
    }

    static func decodeResponse(_ data: Data) throws -> STTResponse {
        let payload: OpenRouterResponse
        do {
            payload = try JSONDecoder().decode(OpenRouterResponse.self, from: data)
        } catch {
            throw AppError.sttDecodingFailure
        }
        // OpenRouter's transcription response does not echo a detected language.
        //
        // Built BEFORE the emptiness verdict so the verdict reads the text
        // AFTER `STTResponse.init` normalizes it through `STTTranscript` (which
        // trims the outer whitespace too): a transcript of nothing but
        // bidi/control scalars is non-empty raw and empty here.
        let response = STTResponse(text: payload.text ?? "", language: nil)
        guard !response.text.isEmpty else {
            // A 2xx with no usable transcript — "no speech detected", not a
            // shape failure. Surfaced uniformly across providers rather than
            // silently swallowing the user's audio.
            throw AppError.noSpeechDetected
        }
        return response
    }
}

// MARK: - Codable types (fileprivate — not part of public surface)

private struct OpenRouterRequest: Encodable {
    let inputAudio: InputAudio
    let model: String
    let language: String?

    enum CodingKeys: String, CodingKey {
        case inputAudio = "input_audio"
        case model
        case language
    }

    struct InputAudio: Encodable {
        let data: String
        let format: String
    }
}

private struct OpenRouterResponse: Decodable {
    let text: String?
}
