// SPDX-License-Identifier: Apache-2.0

// Conduck
// EndpointURLPolicy.swift
//
// The ONE admissibility rule for every user-configured endpoint URL Conduck
// PERSISTS: the gateway URL, the agent file-server URL, and the custom
// voice-endpoint (STT/TTS) URL. All three are dual-written verbatim to
// App-Group UserDefaults AND iCloud KVS, so the rule they must satisfy is a
// storage-privacy rule, not just input hygiene:
//
//   1. `https` scheme — the only transport a bearer token / credential may
//      ride (`spec.md` Architectural Invariants).
//   2. A NON-EMPTY host — `URL(string: "https://")` and
//      `URL(string: "https:///v1")` both parse, both carry a nil `URL.host`,
//      and both survive `normalizedGatewayBaseURL` as the unusable string
//      "https://". Persisting one leaves a structurally broken gateway that
//      reports itself as configured and fails every request at the TLS layer.
//      (Read `URL.host`, NOT `URLComponents.host` — the latter is
//      `Optional("")` for these, so a `!= nil` test passes them.)
//   3. NO `user:password@` userinfo.
//
// WHY RULE 3 IS ABSOLUTE, INCLUDING FOR THE GATEWAY URL. iCloud KVS is
// Apple-key server-side-encrypted — NOT the developer-blind iCloud-Keychain
// path the bearer token and the file-server credential ride. A `user:password@`
// URL therefore parks a plaintext password in exactly the store the privacy
// invariant says must never hold one, and it rides back out verbatim into any
// setup code exported from this device (`PairingPayloadExport`).
//
// Userinfo also makes the APPARENT host differ from the real one:
// `https://gateway.trusted.example@evil.com` connects to `evil.com` while
// reading as the trusted host in a truncated single-line field. That is a
// deception gain — not a new destination capability (every request, cert
// challenge, redirect-origin check and pin lookup resolves `URL.host`) — but
// the inspection surfaces are the only review a user gets on an imported
// setup code, so it is worth closing.
//
// WHAT THIS DELIBERATELY REMOVES. URL userinfo was the only way to put a
// gateway behind an HTTP-Basic reverse proxy: `RemoteAgentAuthScheme` offers
// `.bearer` and `.none` only, and CFNetwork answers a 401 Basic challenge from
// the URL's credentials. That capability was accidental (never specified in
// `spec.md`, no UI, undocumented) and partial: the 401 retry REPLACES the app's
// own `Authorization: Bearer`, so it can only ever work when the upstream
// gateway is keyless. Supporting a Basic-auth proxy properly means a
// first-class `.basic` auth scheme with the password in the Keychain — not a
// credential smuggled through a synced configuration string.
//
// This is a REAL removal, not just hygiene: anyone who had typed such a URL
// loses that gateway until they reconfigure it. That was judged worth it
// pre-launch, when the migration cost is zero.
//
// Pure Foundation, isolation-free — the QR parser runs this on the scanner's
// capture-output queue, off the main actor, while the Settings editor runs it
// on `@MainActor`.

import Foundation

enum EndpointURLPolicy {

    /// Cloudflare Quick Tunnel hostnames are disposable: `cloudflared tunnel
    /// --url` assigns a new `*.trycloudflare.com` address on every restart.
    /// Detection is shared by the manual editor and pairing review so the same
    /// address cannot be warned about in one setup path and silently accepted in
    /// another. Parse the HOST rather than searching the raw string — a path like
    /// `/trycloudflare.com` or a look-alike suffix must never trip the warning.
    static func isCloudflareQuickTunnelURLString(_ raw: String) -> Bool {
        guard let host = URLComponents(string: raw)?.host?.lowercased() else {
            return false
        }
        return host == cloudflareQuickTunnelSuffix
            || host.hasSuffix(".\(cloudflareQuickTunnelSuffix)")
    }

    private static let cloudflareQuickTunnelSuffix = "trycloudflare.com"

    /// Why a URL is inadmissible. Precedence is FIXED — `noHost` before
    /// `notHTTPS` before `carriesUserinfo` — so a caller mapping these onto its
    /// own error type gets one stable answer per input. (`PairingPayload` maps
    /// `notHTTPS` to `.insecureURL` and the other two to `.malformed`; that
    /// split only stays meaningful if the order never drifts.)
    enum Rejection: Equatable, Sendable {
        /// Parsed, but with no host to connect to (`https://`, `https:///v1`).
        case noHost
        /// A scheme other than `https`.
        case notHTTPS
        /// Carries `user:password@` (or a bare `user@`) userinfo.
        case carriesUserinfo
    }

    /// The reason `url` is inadmissible, or nil when it satisfies every rule.
    static func rejection(for url: URL) -> Rejection? {
        guard let host = url.host, !host.isEmpty else { return .noHost }
        guard url.scheme?.lowercased() == "https" else { return .notHTTPS }
        guard !carriesUserinfo(url) else { return .carriesUserinfo }
        return nil
    }

    /// True when `url` may be persisted and requested.
    static func isAdmissible(_ url: URL) -> Bool {
        rejection(for: url) == nil
    }

    /// Does this URL carry `user:password@` userinfo? Reads through
    /// `URLComponents` rather than the soft-deprecated `URL.user`/`URL.password`.
    /// A BARE username counts — no password is needed for the host-confusion
    /// half, and a lone `user@` in a synced string is still credential-shaped.
    /// Parses rather than scanning for a literal "@", so an `@` in the PATH
    /// (`https://host/a@b`) is correctly not userinfo.
    static func carriesUserinfo(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.user != nil || components.password != nil
    }

    /// Parse a STORED string into an admissible URL, or nil. The storage-side
    /// fence: whatever put the value there (a legacy write from before this
    /// policy, or a version-skewed peer device syncing one in through KVS), an
    /// inadmissible string never resolves into a URL the app will request.
    static func admissibleURL(from raw: String?) -> URL? {
        guard let raw, !raw.isEmpty, let url = URL(string: raw), isAdmissible(url) else {
            return nil
        }
        return url
    }
}
