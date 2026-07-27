// SPDX-License-Identifier: Apache-2.0

// Conduck
// TTSStatusMap.swift
//
// Cloud Text-to-Speech foundation. Per-provider HTTP status → AppError
// mapping for the synthesize response, mirroring `Services/STT/STTStatusMap.swift`.
//
// TTS error semantics are SIMPLER than STT's because the Apple
// `AVSpeechSynthesizer` fallback is free + always available: a failed cloud
// synthesis is never queued for retry (the text reply is already on screen).
// So the map splits into four terminal-or-transient outcomes:
//   - transient transport/server where ONE retry is worth it (408/5xx) → `ttsProviderUnreachable`
//   - rate-limited / out of quota / out of credit (402/429)            → `ttsRateLimited`
//   - key rejected for TTS (401/403: missing text-to-speech scope)     → `ttsUnauthorized`
//   - genuine bad voice/request (400/404/422 + other 4xx)              → `ttsSynthesisFailed`
// All ultimately fall back to Apple at the playback layer; the split exists so
// the SURFACED message (settings preview / test) names the real cause instead
// of always blaming the voice ID. (ElevenLabs keys are commonly scoped to
// speech_to_text only, so a valid STT key 401s on TTS — that must read as an
// auth/scope problem, not "check the voice name.")

import Foundation

/// Per-provider HTTP-status → AppError mapper for TTS synthesis. `nil`
/// returned for 2xx (caller reads the audio body); non-nil for any error
/// status. Mirrors `STTStatusMap`.
struct TTSStatusMap: Sendable {
    let map: @Sendable (Int) -> AppError?

    /// Shared mapping. TTS does not differentiate 429 by provider (STT's
    /// load-bearing billing-fatal-vs-transient split does not apply — a
    /// rate-limited reply just falls back to Apple this once), so a single
    /// helper covers every cloud provider. 408 / 429 / 5xx are the only codes
    /// worth a single retry before falling back; auth/credit (401/402/403) →
    /// `ttsUnauthorized`; every other non-2xx (bad voice/request) → the
    /// terminal `ttsSynthesisFailed`.
    @Sendable
    private static func shared(_ code: Int) -> AppError? {
        switch code {
        case 200..<300:
            return nil
        case 408, 500..<600:
            // Transient transport/server — worth ONE retry (AppError caps
            // `ttsProviderUnreachable` at maxAttempts ≤ 2), else Apple fallback.
            return .ttsProviderUnreachable
        case 402, 429:
            // Rate-limited or out of quota/credit (OpenAI 429 `insufficient_quota`
            // is account-side, NOT a connectivity problem — "check your
            // connection" would be a lie). Capped one retry then Apple fallback.
            return .ttsRateLimited
        case 401, 403:
            // Key rejected for TTS: missing text-to-speech scope (common with
            // narrow-scoped ElevenLabs keys that grant only speech_to_text).
            // Terminal — a different voice won't help; the surfaced message must
            // point at the KEY, not the voice.
            return .ttsUnauthorized
        default:
            // Bad voice / model / request (400, 404 invalid voice, 422, any
            // other 4xx) → terminal. Retrying the same text won't help; the
            // playback layer falls back to Apple.
            return .ttsSynthesisFailed
        }
    }

    /// OpenAI `gpt-4o-mini-tts` + Mistral `voxtral-mini-tts-2603` (shared
    /// OpenAI-compatible `/v1/audio/speech`).
    static let openAICompat = TTSStatusMap { code in shared(code) }

    /// ElevenLabs Flash v2.5 (`/v1/text-to-speech/{voice_id}`).
    static let elevenLabs = TTSStatusMap { code in shared(code) }

    /// Gemini `gemini-3.1-flash-tts-preview` (`:generateContent`). 404 = invalid
    /// voice → terminal `ttsSynthesisFailed` (via the `shared` default arm).
    static let gemini = TTSStatusMap { code in shared(code) }

    /// Apple on-device TTS sentinel — never produces an HTTP status (handled
    /// at the playback layer, never reaches `TTSClient`). `nil` for every
    /// code; callers must not consult this map for the Apple provider.
    static let never = TTSStatusMap { _ in nil }
}
