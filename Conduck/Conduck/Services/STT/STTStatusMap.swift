// SPDX-License-Identifier: Apache-2.0

// Conduck
// STTStatusMap.swift
//
// Multi-provider STT expansion. Per-provider HTTP
// status → AppError mapping. The load-bearing differentiator across
// providers is the 429 semantic:
//   - Mistral 429   → `sttQuotaExceeded` (billing-fatal, NON-retryable)
//   - Gemini  429   → `sttQuotaExceeded` (billing-fatal, NON-retryable)
//   - OpenAI  429   → `sttTooManyRequests` (transient rate-limit, RETRYABLE)
//   - ElevenLabs 429→ `sttTooManyRequests` (transient, RETRYABLE)
//   - Qwen    429   → `sttTooManyRequests` (DashScope rate-limit, RETRYABLE)
//
// The "Mistral 429 retried as OpenAI 429" regression is locked
// here: per-provider instance is selected via `STTProvider.statusMap` at
// the dispatch boundary, never by string-match.
//
// All other status codes share semantics across all 5 providers (mapped
// in a single helper to eliminate copy-drift).

import Foundation

/// Per-provider HTTP-status → AppError mapper. `nil` returned for 2xx
/// (caller decodes the body); non-nil returned for any error status.
struct STTStatusMap: Sendable {
    let map: @Sendable (Int) -> AppError?

    /// Shared mapping for non-429 codes. Each provider's `map` closure
    /// calls into this for the cases it does not need to specialize.
    @Sendable
    private static func sharedNon429(_ code: Int) -> AppError? {
        switch code {
        case 200..<300:
            return nil
        case 400:
            return .audioInvalid
        case 401:
            return .sttAuthFailed
        case 413:
            return .audioTooLarge
        case 422:
            return .audioProcessingFailed
        case 500..<600:
            return .sttServerError
        default:
            // Localized fallback for HTTP codes not in any provider's status
            // map. Surfaces as "Unknown error (HTTP 599)" — actionable for
            // user-reported support tickets without leaking provider names.
            return .apiFailure(message: String(
                localized: "stt.error.unknownHTTPStatus",
                defaultValue: "Unknown error (HTTP \(code))"
            ))
        }
    }

    /// Mistral Voxtral — 429 is billing-fatal (account out of credit /
    /// hard quota). NOT retryable; user must top up the account.
    static let mistral = STTStatusMap { code in
        if code == 429 { return .sttQuotaExceeded }
        return sharedNon429(code)
    }

    /// OpenAI `gpt-4o-transcribe` — 429 is a transient rate-limit
    /// (organization RPM cap); retryable with backoff.
    static let openAICompat = STTStatusMap { code in
        if code == 429 { return .sttTooManyRequests }
        return sharedNon429(code)
    }

    /// ElevenLabs Scribe v2 — 429 is the per-second rate-limit; retryable.
    static let elevenLabsScribe = STTStatusMap { code in
        if code == 429 { return .sttTooManyRequests }
        return sharedNon429(code)
    }

    /// Gemini 3.1 Flash-Lite — 429 is billing-fatal (free-tier exhausted
    /// or paid-tier quota hit); NOT retryable.
    static let gemini = STTStatusMap { code in
        if code == 429 { return .sttQuotaExceeded }
        return sharedNon429(code)
    }

    /// Qwen3-ASR-Flash (DashScope) — 429 is the standard DashScope
    /// rate-limit (default 100 RPM); transient and retryable.
    static let qwen = STTStatusMap { code in
        if code == 429 { return .sttTooManyRequests }
        return sharedNon429(code)
    }

    /// OpenRouter hosted transcription. 429 is a transient rate-limit
    /// (retryable). 402 is billing-fatal (account out of credits) — mapped to
    /// `sttQuotaExceeded` (NON-retryable, so no new STT error case is needed).
    /// Deliberately NOT the gateway's `remoteAgentOutOfCredits` posture, because
    /// the flag answers a different question on each lane: here `isRetryable`
    /// drives `STTClient`'s automatic loop, which would re-ask a question the
    /// account cannot answer, while on the gateway it draws a button the user
    /// taps once they have added credits. 400/404
    /// from this endpoint mean a bad request/model (OpenRouter rejects an
    /// unknown model ID), NOT bad audio — so they must NOT inherit the shared
    /// `400 → audioInvalid` mapping that would wrongly blame the recording;
    /// route them to the generic unknown-status fallback instead.
    static let openRouter = STTStatusMap { code in
        switch code {
        case 402:
            return .sttQuotaExceeded
        case 429:
            return .sttTooManyRequests
        case 400, 404:
            return .apiFailure(message: String(
                localized: "stt.error.unknownHTTPStatus",
                defaultValue: "Unknown error (HTTP \(code))"
            ))
        default:
            return sharedNon429(code)
        }
    }

    /// In-process providers (Apple on-device STT) never
    /// produce an HTTP status — failures surface as thrown errors directly
    /// from the runner (TCC denial, model-not-installed, audio-unreadable).
    /// `nil` here means "no HTTP error to map" for any status code; callers
    /// must not consult this map for in-process providers in practice.
    static let never = STTStatusMap { _ in nil }
}
