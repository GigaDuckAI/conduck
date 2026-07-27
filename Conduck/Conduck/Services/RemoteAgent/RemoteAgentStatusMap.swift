// SPDX-License-Identifier: Apache-2.0

// Conduck
// RemoteAgentStatusMap.swift
//
// Network foundation. HTTP-status → `AppError` mapper for the
// Personal AI gateway round-trip. Pattern transferred from
// `Services/STT/STTStatusMap.swift` (STT's `nonisolated @Sendable` closure
// shape).
//
// **Single unified mapping — NO per-backend differentiator.** Under
// client-owned history (locked 2026-05-20) Conduck pins no server
// session, so it never contends OpenClaw's per-session write lock; there
// is therefore no 423 / `remoteAgentSessionBusy` path on either backend
// (`spec.md "Cross-Device Sync"`, `spec.md "Error Taxonomy — AppError"`). Both `RemoteAgentBackend`
// cases return this one map. The `statusMap` seam on the enum is retained
// only as forward-compat for a future `.custom` backend — it is data
// dispatch, never behaviour dispatch.
//
// Mapping:
//   - 2xx          → nil (caller decodes the body)
//   - 401 / 403    → `.remoteAgentAuthFailed`
//   - 402          → `.remoteAgentOutOfCredits`
//   - 408          → `.remoteAgentTimeout`
//   - 429          → `.remoteAgentRateLimited`
//   - 5xx          → `.remoteAgentServerError` (incl. OpenClaw's HTTP-500
//                    lock-timeout body `session file locked` — practically
//                    unreachable since no session is pinned)
//   - other        → localized `.apiFailure` carrying the raw HTTP code

import Foundation

/// HTTP-status → `AppError` mapper. Returns `nil` for 2xx (caller decodes
/// the body); non-nil for any error status. One instance for every backend.
struct RemoteAgentStatusMap: Sendable {
    let map: @Sendable (Int) -> AppError?

    /// The single mapping shared by every backend. No 423 handling — under
    /// client-owned history no per-session lock is ever contended.
    @Sendable
    private static func mapStatus(_ code: Int) -> AppError? {
        switch code {
        case 200..<300:
            return nil
        case 401, 403:
            return .remoteAgentAuthFailed
        case 402:
            // Payment Required — hosted providers (OpenRouter) return this when
            // the account is out of credits. A dedicated actionable error beats
            // the generic "Unknown error (HTTP 402)" fallthrough.
            return .remoteAgentOutOfCredits
        case 408:
            // Request Timeout — surface as the existing timeout error (no new
            // string) rather than the generic retryable .apiFailure.
            return .remoteAgentTimeout
        case 429:
            // Too Many Requests — provider rate-limit / free-tier daily cap
            // (common on OpenRouter `:free` models). Non-retryable (no auto-retry
            // that would worsen the limit; the user retries manually after a wait).
            return .remoteAgentRateLimited
        case 500..<600:
            return .remoteAgentServerError
        default:
            // Localized fallback for HTTP codes neither backend specialises.
            // Surfaces as "Unknown error (HTTP 599)" — actionable for support
            // tickets without leaking backend names. (4xx other than 401/403
            // is rare on a chat-completions endpoint; if it surfaces this
            // catches it without losing the code.)
            return .apiFailure(message: String(
                localized: "remoteAgent.error.unknownHTTPStatus",
                defaultValue: "Unknown error (HTTP \(code))"
            ))
        }
    }

    /// The canonical map. Both `RemoteAgentBackend` cases return this — the
    /// per-backend seam exists only for a future `.custom` backend, not for
    /// any difference between OpenClaw and Hermes.
    static let unified = RemoteAgentStatusMap { code in
        mapStatus(code)
    }
}
