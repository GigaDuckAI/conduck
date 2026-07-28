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
///   3. Any error that is neither a recognised connectivity class nor a certificate
///      rejection the TRUST LAYER ITSELF named returns `fallback` unchanged, so this
///      NEVER fires on a real gateway/HTTP error — those arrive on a different code
///      path (the HTTP status-map branch), not the transport branch this serves.
///   4. The certificate arm covers ONLY `-1201…-1204`, the codes where the system
///      named the certificate as the cause. `.secureConnectionFailed` (-1200) is
///      excluded for the same reason `RemoteAgentTrustEvaluator.classifyTransportError`
///      excludes it: it is a GENERIC handshake failure a cold Tailscale tunnel
///      produces on a perfectly good certificate, and labelling that a trust problem
///      is the false "Untrusted certificate" this codebase already regressed on once.
enum WatchNetworkFailureCopy {

    /// - Parameters:
    ///   - error: the transport `Error` handed to the background `URLSession`
    ///     `didCompleteWithError` delegate.
    ///   - fallback: the call site's existing message for any error that is neither
    ///     a recognised connectivity class nor a named certificate rejection
    ///     (preserves per-site wording — the converse and STT branches keep their
    ///     own defaults).
    static func transportFailureMessage(for error: Error, fallback: String) -> String {
        switch (error as? URLError)?.code {
        case .notConnectedToInternet:
            // -1009 — the high-confidence companion-proxy signal. Hedged (constraint 1).
            return String(localized: "Couldn't connect to the internet. If your iPhone is nearby, your watch may be using its connection. Make sure the iPhone is online, or turn it off, then try again so your watch uses its own Wi-Fi.")
        case .timedOut, .cannotConnectToHost, .networkConnectionLost:
            // -1001 / -1004 / -1005 — connectivity, but not specific enough to point
            // at the companion iPhone. Broader hint, no over-claim (constraint 2).
            return String(localized: "Couldn't reach the internet. Check your connection and try again.")
        case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid:
            // -1202 / -1203 / -1201 / -1204 — the trust layer named the certificate,
            // so these are safe to label without any signal from the evaluator
            // (constraint 4). This is the UNPINNED lane's only certificate path: with
            // no pin configured the evaluator answers `.performDefaultHandling` and
            // records nothing, because its `SecTrustEvaluateWithError` call inside a
            // challenge is ADVISORY — it also fails when evaluation could not
            // complete, so on its own it does not prove the system refused.
            return CertificateTrustCopy.untrustedRefusalCompact
        default:
            return fallback
        }
    }

    /// A configured pin did not match a chain the system DID trust — the wrist form.
    ///
    /// A SEPARATE cause from `CertificateTrustCopy.untrustedRefusalCompact` and never
    /// merged with it: there the chain itself is rejected and the fix is a real
    /// certificate on the server; here the chain is fine and the KEY under it
    /// disagrees with the pin, which is what an intercepted connection looks like —
    /// so the warning is load-bearing and the two must not collapse into one
    /// message. Terminal, so it never invites a retry: the evaluator refuses this
    /// handshake every time until the key or the pin changes, and neither happens on
    /// the wrist. The words themselves live in `CertificateTrustCopy` — the wheel
    /// speaks the same line, and two owners for one cause is how they drift apart.
    static var certificatePinMismatchMessage: String {
        CertificateTrustCopy.pinMismatchRefusalCompact
    }

    /// The pin could not be COMPUTED on a chain the system trusted — the wrist form.
    ///
    /// A THIRD cause, merged with neither of the two above. It is not the untrusted
    /// case (this device accepted the chain, so there is nothing to fix on the
    /// server) and it is not the mismatch case (nothing was compared, so there is
    /// no interception to warn about — and a false alarm on that message is how a
    /// user learns to ignore the real one). Terminal like the others, so it never
    /// invites a retry. The words live in `CertificateTrustCopy` for the same
    /// reason: one owner per cause.
    static var certificateKeyUnpinnableMessage: String {
        CertificateTrustCopy.keyUnpinnableRefusalCompact
    }
}
