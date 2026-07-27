// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Maps a transport-layer `Error` from a Watch background `URLSession` task to an
/// honest, user-facing failure message.
///
/// WHY THIS EXISTS — the watchOS companion-routing trap. When the paired iPhone is
/// powered on and in Bluetooth range, watchOS routes the Watch's outbound HTTPS
/// THROUGH the iPhone ("prefer companion" / NECP policy) and does NOT fall back to
/// the Watch's own Wi-Fi, even when the iPhone has no working internet. So a Watch
/// turn to a PUBLIC endpoint (e.g. OpenRouter) can fail purely because the nearby
/// iPhone's network is dead — and there is NO public API to bypass it (Network
/// framework interface pinning is unsupported for `URLSession` on watchOS, TN3135;
/// no `URLSessionConfiguration` knob, workout/extended-runtime session, cellular
/// path, or entitlement selects the interface). The only remedy is honest copy that
/// names the LIKELY cause + the workaround. Verified unfixable-at-transport
/// 2026-06-30 (Claude + Codex/gpt-5.5 against the watchOS 26.5 SDK + Apple TN3135).
///
/// TRUTH CONSTRAINTS (load-bearing — the message must be certain and true):
///   1. NEVER assert the iPhone is the cause. The Watch cannot distinguish "routing
///      through a nearby-offline iPhone" from "no connectivity at all":
///      `WCSession` reachability is an app-level signal, not the OS Bluetooth
///      companion link that governs routing, and `NWPathMonitor` can't prove which
///      path the background daemon chose. Copy stays HEDGED ("if your iPhone is
///      nearby, your watch may be using its connection").
///   2. The iPhone-aware hint fires ONLY on `.notConnectedToInternet` (-1009) — the
///      high-confidence signal. `.timedOut` (-1001) / `.cannotConnectToHost` (-1004)
///      / `.networkConnectionLost` (-1005) get a broader connection hint. DNS codes
///      (-1003 / -1006) are deliberately EXCLUDED — false-positive prone for a
///      mistyped custom-gateway host.
///   3. Any non-connectivity error returns `fallback` unchanged, so this NEVER fires
///      on a real gateway/HTTP error — those arrive on a different code path (the
///      HTTP status-map branch), not the transport branch this serves.
enum WatchNetworkFailureCopy {

    /// - Parameters:
    ///   - error: the transport `Error` handed to the background `URLSession`
    ///     `didCompleteWithError` delegate.
    ///   - fallback: the call site's existing message for any error that is not a
    ///     recognised connectivity class (preserves per-site wording — the converse
    ///     and STT branches keep their own defaults).
    static func transportFailureMessage(for error: Error, fallback: String) -> String {
        switch (error as? URLError)?.code {
        case .notConnectedToInternet:
            // -1009 — the high-confidence companion-proxy signal. Hedged (constraint 1).
            return String(localized: "Couldn't connect to the internet. If your iPhone is nearby, your watch may be using its connection. Make sure the iPhone is online, or turn it off, then try again so your watch uses its own Wi-Fi.")
        case .timedOut, .cannotConnectToHost, .networkConnectionLost:
            // -1001 / -1004 / -1005 — connectivity, but not specific enough to point
            // at the companion iPhone. Broader hint, no over-claim (constraint 2).
            return String(localized: "Couldn't reach the internet. Check your connection and try again.")
        default:
            return fallback
        }
    }
}
