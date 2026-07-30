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
        case 502, 503, 504, 521, 522, 523, 524, 525, 526, 530:
            // Something in the route ANSWERED, but not the gateway's own
            // application. Kept ahead of the 5xx arm because 29's remedy sends
            // the user to read gateway logs, and in every one of these cases the
            // gateway's application may never have seen the request at all.
            //
            // 521–526 and 530 are Cloudflare edge↔origin conditions: the edge
            // answered on the origin's behalf after failing to reach it (521 origin
            // down, 522 connect timeout, 523 origin unreachable, 524 origin
            // silent, 525/526 origin TLS). 530 (Cloudflare error 1033) means the
            // hostname does not route to a live origin at all — a quick tunnel
            // that has expired or moved — NOT that a tunnel is up and its origin
            // is sick.
            //
            // The copy stays deliberately generic even so: 502/503/504 can
            // equally come from a reverse proxy, the gateway itself, or the model
            // provider behind it, and only the response body could tell them
            // apart. Naming a tunnel here would send some users to restart the
            // one component that is working.
            return .remoteAgentServiceUnavailable
        case 500..<600:
            return .remoteAgentServerError
        default:
            // A status no backend specialises. Carries the NUMBER, which is the
            // whole point: this arm used to build "Unknown error (HTTP 599)" and
            // hand it to `.apiFailure`, whose `errorDescription` discards its
            // associated message — so every unmapped status rendered as
            // "Something went wrong with the last request." The number is the
            // one actionable fact available, and 71 keeps it.
            //
            // Deliberately NOT routed back through `.apiFailure`: that case is
            // the collapse target for text arriving off the Watch relay wire, so
            // surfacing its message would open a copy-injection path.
            return .remoteAgentUnexpectedStatus(status: code)
        }
    }

    /// The canonical map. Both `RemoteAgentBackend` cases return this — the
    /// per-backend seam exists only for a future `.custom` backend, not for
    /// any difference between OpenClaw and Hermes.
    static let unified = RemoteAgentStatusMap { code in
        mapStatus(code)
    }
}
