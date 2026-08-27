// SPDX-License-Identifier: Apache-2.0

// Conduck
// STTStatusMap.swift
//
// Multi-provider STT expansion. Per-provider HTTP
// status → AppError mapping. The load-bearing differentiator across
// providers is the 429 semantic:
//   - Mistral 429   → `sttQuotaExceeded` (billing-fatal, NON-retryable)
//   - OpenAI  429   → `sttTooManyRequests` (transient rate-limit, RETRYABLE)
//   - ElevenLabs 429→ `sttTooManyRequests` (transient, RETRYABLE)
//   - Qwen    429   → `sttTooManyRequests` (DashScope rate-limit, RETRYABLE)
//   - Gemini  429   → RESOLVED FROM THE BODY (see `.gemini` below): Google
//                     publishes distinct `rate_limit_exceeded` (transient) and
//                     `quota_exceeded` (billing-fatal) codes under one status.
//
// The "Mistral 429 retried as OpenAI 429" regression is locked
// here: per-provider instance is selected via `STTProvider.statusMap` at
// the dispatch boundary, never by string-match.
//
// The resolver takes the response BODY as well as the status because status
// alone is not sufficient for every provider (Gemini's 429 split above). All
// four dispatch sites — phone foreground/background and Watch foreground/
// background — already hold the body at the call, so this costs nothing.
// `map(_:_:)` takes the body as an explicit, non-defaulted parameter so a
// dispatch site cannot drop it without breaking the build.
//
// Body inspection matches STRUCTURED fields only (`error.code`,
// `error.status`) — never human-readable `error.message` text, which is
// localized and reworded without notice.

import Foundation

/// Per-provider HTTP-status → AppError mapper. `nil` returned for 2xx
/// (caller decodes the body); non-nil returned for any error status.
struct STTStatusMap: Sendable {
    /// Resolve an HTTP status (plus the response body, when the caller has
    /// it) to an `AppError`. `nil` = 2xx, caller decodes.
    let resolve: @Sendable (Int, Data?) -> AppError?

    init(_ resolve: @escaping @Sendable (Int, Data?) -> AppError?) {
        self.resolve = resolve
    }

    /// Apply the map. `body` is Optional but has NO DEFAULT, deliberately: a
    /// defaulted parameter would let a dispatch site quietly stop passing the
    /// response body and still compile, silently reverting Gemini's 429 split
    /// to its status-only verdict with no test able to catch it. Callers with
    /// no body pass `nil` explicitly and say so.
    func map(_ status: Int, _ body: Data?) -> AppError? {
        resolve(status, body)
    }

    /// Shared mapping for non-429 codes. Each provider's resolver
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
    static let mistral = STTStatusMap { code, _ in
        if code == 429 { return .sttQuotaExceeded }
        return sharedNon429(code)
    }

    /// OpenAI `gpt-4o-transcribe` — 429 is a transient rate-limit
    /// (organization RPM cap); retryable with backoff.
    static let openAICompat = STTStatusMap { code, _ in
        if code == 429 { return .sttTooManyRequests }
        return sharedNon429(code)
    }

    /// ElevenLabs Scribe v2 — 429 is the per-second rate-limit; retryable.
    static let elevenLabsScribe = STTStatusMap { code, _ in
        if code == 429 { return .sttTooManyRequests }
        return sharedNon429(code)
    }

    /// Google Gemini via the Interactions API (`POST /v1beta/interactions`).
    ///
    /// This map does NOT fall through to `sharedNon429` for the 4xx range,
    /// because the shared table was written for multipart audio endpoints
    /// where a 400 means the RECORDING was rejected. On Interactions a 400
    /// means the REQUEST was rejected (unknown model, malformed config) —
    /// blaming the user's microphone for that sends them to fix the one
    /// thing that is not broken.
    ///
    /// 400/404 are also DETERMINISTIC: the identical bytes fail identically
    /// on every attempt. They map to `.invalidRequest` (non-retryable) rather
    /// than `.apiFailure`, which `AppError.isRetryable` marks retryable and
    /// would re-send a request that cannot succeed.
    ///
    /// 429 splits on the structured error code. Google publishes
    /// `rate_limit_exceeded` (transient, retryable) and `quota_exceeded`
    /// (billing-fatal, terminal) under the same status. With no body — or an
    /// unrecognized code — the default is TRANSIENT: a wrongly-transient 429
    /// costs one retry against a request that does not bill, while a wrongly
    /// terminal one tells a merely rate-limited user to go top up an account
    /// that has money in it.
    static let gemini = STTStatusMap { code, body in
        switch code {
        case 200..<300:
            return nil
        case 400:
            return .invalidRequest(message: String(
                localized: "stt.error.gemini.badRequest",
                defaultValue: "That request was rejected. Check the model name in Advanced settings."
            ))
        case 401, 403:
            // Google returns 403 PERMISSION_DENIED for a disabled API or a
            // restricted key, and 401 for a malformed one. Both are
            // user-fixable auth problems, and `STTGETProbe` already treats
            // them that way — the hot path must agree, or the same bad key
            // reads "Invalid key." in Settings and "Unknown error (HTTP 403)"
            // mid-recording.
            return .sttAuthFailed
        case 404:
            // Unknown/withdrawn model. Deterministic — see above.
            return .invalidRequest(message: String(
                localized: "stt.error.gemini.modelNotFound",
                defaultValue: "That model is not available. Check the model name in Advanced settings."
            ))
        case 413:
            return .audioTooLarge
        case 429:
            return GoogleAPIError.isHardQuota(body) ? .sttQuotaExceeded : .sttTooManyRequests
        case 500..<600:
            return .sttServerError
        default:
            return .apiFailure(message: String(
                localized: "stt.error.unknownHTTPStatus",
                defaultValue: "Unknown error (HTTP \(code))"
            ))
        }
    }

    /// Qwen3-ASR-Flash (DashScope) — 429 is the standard DashScope
    /// rate-limit (default 100 RPM); transient and retryable.
    static let qwen = STTStatusMap { code, _ in
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
    static let openRouter = STTStatusMap { code, _ in
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
    static let never = STTStatusMap { _, _ in nil }
}

// MARK: - Google error envelope

/// Structured reader for Google's API error body. Google ships TWO envelope
/// shapes on the same host and the same `v1beta` prefix — measured, not
/// assumed:
///
///     {"error":{"message":"…","code":"not_found"}}          ← code is a STRING
///     {"error":{"code":403,"message":"…","status":"PERMISSION_DENIED"}}
///                                                            ← code is an INT
///
/// So `code` decodes as either, and a decode failure is never fatal: every
/// reader here answers a refinement question whose safe answer is "no".
enum GoogleAPIError {

    /// True only when the body positively identifies a hard, billing-fatal
    /// quota exhaustion. Absent/unparseable/unrecognized → false, which keeps
    /// the caller on the transient (retryable) branch. Never infers from
    /// `error.message`, which is prose and gets reworded.
    static func isHardQuota(_ body: Data?) -> Bool {
        guard let body, let envelope = try? JSONDecoder().decode(Envelope.self, from: body) else {
            return false
        }
        let tokens = [envelope.error?.code?.stringValue, envelope.error?.status]
            .compactMap { $0?.lowercased() }
        // `RESOURCE_EXHAUSTED` deliberately does NOT count: it is the legacy
        // status for BOTH a rate limit and a spent quota, so treating it as
        // hard would re-introduce the wrong-advice case this split exists to
        // fix. Only the specific quota code is conclusive.
        return tokens.contains { $0.contains("quota_exceeded") }
    }

    private struct Envelope: Decodable {
        let error: Body?

        struct Body: Decodable {
            let code: StringOrInt?
            let status: String?
        }
    }

    /// `error.code` is a string on one path and an integer on another.
    private struct StringOrInt: Decodable {
        let stringValue: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let s = try? container.decode(String.self) {
                stringValue = s
            } else if let i = try? container.decode(Int.self) {
                stringValue = String(i)
            } else {
                stringValue = nil
            }
        }
    }
}
