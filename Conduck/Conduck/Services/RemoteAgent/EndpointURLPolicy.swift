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
//   1. An ENCRYPTED transport — `https` — with ONE carve-out: plain `http` is
//      admitted when the host is one only the local network can reach
//      (`LocalNetworkHost`). See "Plain http on the local network" below for
//      the measured platform behaviour that fixes the boundary exactly there.
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
// ─────────────────────────────────────────────────────────────────────────────
// PLAIN HTTP ON THE LOCAL NETWORK — what was measured, and what the app does
// with it.
//
// A large part of the self-hosting world serves plain HTTP on the local network
// and cannot be configured otherwise; Ollama is the load-bearing example (port
// 11434, no TLS support of its own). Refusing every non-`https` address shuts
// those users out of the product, so plain `http` is admitted toward a host
// only the local network can reach, and refused everywhere else.
//
// THE RULE IS NOT CONDUCK'S OPINION — IT IS A PREDICTION OF THE PLATFORM'S.
// App Transport Security adjudicates from the URL STRING before any TCP
// connect, so the boundary is fixed by iOS and the app merely states it while
// the user is still looking at the address. `LocalNetworkHost` carries the
// classifier and its attack cases; the matrix behind it, measured on iOS 26.5
// Simulator (build 23F77) inside the hosted `ConduckTests` bundle:
//
//   PERMITTED, with NO `NSAppTransportSecurity` key at all — private IPv4
//   literals (10/8, 172.16/12, 192.168/16), 169.254/16, IPv6 ULA literals,
//   loopback, and `*.local` names.
//
//   REFUSED (-1022) — ANY dotted DNS hostname over plain http, INCLUDING one
//   that resolves to a private LAN address; 100.64/10 (CGNAT, the range an
//   overlay VPN hands out); every public literal; every public name.
//
// THE ORDERING PROOF that makes those readings valid: `http://198.51.100.7:8899/`
// — a public literal in TEST-NET-2, unroutable, nothing listening — returned
// -1022 in 0.01 s. An unroutable address can only produce -1022 if the policy
// decision precedes the connect attempt. So for a literal, -1022 means "ATS
// blocked" and -1001/-1004 means "ATS permitted, then the network failed".
//
// THE MATCHED PAIR that refutes the obvious confound (the simulator shares the
// Mac's network stack, so a LAN literal could have been exempt as a SELF
// address rather than as a private one): `http://192.168.1.50:8899/` returned
// 200 while `http://192.168.1.50.nip.io:8899/` — a real DNS name resolving to
// that identical address — returned -1022. Same destination, opposite verdict,
// decided pre-connect. ATS keys on the host STRING being a private literal.
//
// THE PLIST. The app ships `NSAppTransportSecurity = { NSAllowsLocalNetworking
// = YES }` and NOTHING ELSE, in the phone bundle and the Watch App bundle. The
// key measured as a NO-OP — the matrix under it is byte-identical to the no-key
// control across all fifteen targets — and is shipped anyway for three reasons:
// it is the documented declaration that pairs with
// `NSLocalNetworkUsageDescription`; it makes the private-literal exemption
// contractual rather than an OS default that could change; and it reads
// correctly to an App Review reviewer who sees plain-http gateway URLs.
// `NSAllowsArbitraryLoads` is NEVER added: measured, the local-networking key
// SUPPRESSES it (with both present `http://example.com` is refused -1022, while
// arbitrary-loads alone succeeds 200), so a future engineer adding it would get
// nothing and have no way to know why — and it disables ATS app-wide for every
// OpenRouter, cloud STT/TTS and https-gateway connection the user never asked
// anyone to touch.
//
// MEASURED ON macOS TOO (macOS 26.6 build 25G72, ad-hoc-signed probe .app,
// separate processes for the no-key control and the shipped-plist variant):
// the matrix is IDENTICAL to iOS on every row probed. Private IP literal and
// a `*.local` name permitted; public IP, dotted DNS name (nip.io resolving
// PRIVATE), CGNAT 100.64/10 and root-qualified `uz.` all -1022 — with the
// positive control (`http://example.com` → -1022 in ~1 ms) proving
// enforcement was live, and every permitted-but-dead target burning its full
// timeout, so the verdict is again computed from the string. Two extras: a
// Mac holding a Tailscale 100.64/10 interface address STILL gets -1022
// toward that range, and `NSAllowsLocalNetworking` again changed nothing.
// (`ConduckTests` will not compile for a macOS destination, so this evidence
// lives in the probe record, not the suite.)
//
// PLAIN HTTP IS NEVER CHOSEN FOR THE USER. It is never a default, never a
// placeholder, never suggested in footer copy — it is accepted only when the
// user typed or scanned it, and an accepted plain address carries a warning
// wherever it is reviewed. Being told is the whole of the consent; there is
// deliberately no toggle.
//
// A PIN ON AN UNENCRYPTED ADDRESS. A saved certificate fingerprint cannot apply
// to a plain-`http` endpoint: no TLS handshake happens, so no challenge ever
// reaches `RemoteAgentTrustEvaluator` and nothing is ever compared. The
// combination must fail CLOSED and be NAMED (`pinCannotApply(to:)`). Honouring
// the address and quietly dropping the pin is the one forbidden outcome — it
// leaves the user believing a protection is in force that is not, and it
// inverts the standing doctrine that a pin can only tighten, never be waived.
//
// ONE EDIT MOVED ALL THREE BOUNDARIES. Every caller reaches this type through
// `isAdmissible` / `admissibleURL(from:)`, so widening the rule here widened it
// for the gateway URL, the file-server URL and the custom voice-endpoint URL
// together. That is the point of the chokepoint: they are one rule, and there
// is deliberately no per-field opt-out.
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

    /// Why a URL is inadmissible. Precedence is FIXED — `noHost` first, then the
    /// SCHEME verdict (`notHTTPS` or `insecureRemoteHost` — same rank, they are
    /// two readings of one question), then `carriesUserinfo` — so a caller
    /// mapping these onto its own error type gets one stable answer per input.
    /// (`PairingPayload` maps both scheme verdicts to `.insecureURL` and the
    /// other two to `.malformed`; that split only stays meaningful if the order
    /// never drifts.)
    enum Rejection: Equatable, Sendable {
        /// Parsed, but with no host to connect to (`https://`, `https:///v1`).
        case noHost
        /// A scheme that is neither `https` nor `http` (`ftp`, `file`, `ws`, none).
        case notHTTPS
        /// Carries `user:password@` (or a bare `user@`) userinfo.
        case carriesUserinfo
        /// Plain `http` toward a host the local network cannot reach on its own —
        /// a dotted DNS name, a CGNAT address, or any public address. Named apart
        /// from `notHTTPS` so the copy can state the fix instead of the rule.
        case insecureRemoteHost
    }

    /// The reason `url` is inadmissible, or nil when it satisfies every rule.
    ///
    /// WHY THE SCHEME VERDICT STAYS AHEAD OF USERINFO, and why that still means
    /// userinfo is absolutely refused on both schemes.
    /// `http://192.168.1.1@evil.com` has `URL.host == "evil.com"` (measured), so
    /// it is plain http toward a REMOTE host and reports `.insecureRemoteHost`.
    /// The URL is still refused, at every write and read fence — it is simply
    /// named for the defect that is true of it whichever way you look at it.
    /// `http://u:p@192.168.1.10` is local, falls through the scheme guard, and
    /// reports `.carriesUserinfo`. `https://…@evil.com` is unchanged.
    ///
    /// Reordering `carriesUserinfo` above the scheme verdict was considered and
    /// REJECTED: it would flip `http://u:p@gw.example.com` from `.insecureURL`
    /// to `.malformed` in the pairing UI, breaking the rank the parser's error
    /// taxonomy and its tests depend on.
    static func rejection(for url: URL) -> Rejection? {
        guard let host = url.host, !host.isEmpty else { return .noHost }
        let scheme = url.scheme?.lowercased()
        if scheme != "https" {
            guard scheme == "http" else { return .notHTTPS }
            guard LocalNetworkHost.isLocal(host) else { return .insecureRemoteHost }
        }
        guard !carriesUserinfo(url) else { return .carriesUserinfo }
        return nil
    }

    /// True when `raw` is a plain-`http` URL the policy ADMITS — i.e. its host is
    /// one only the local network can reach. The trigger for the warning shown
    /// wherever such an address is reviewed. False for https, for an http URL the
    /// policy refuses, and for anything that does not parse.
    ///
    /// Parses the host through `URL` rather than scanning the raw string, the
    /// same idiom as `isCloudflareQuickTunnelURLString`, so the views keep one
    /// shape and a path segment can never trip a warning.
    static func isAdmittedPlainHTTPURLString(_ raw: String) -> Bool {
        guard let url = URL(string: raw), url.scheme?.lowercased() == "http" else {
            return false
        }
        return isAdmissible(url)
    }

    /// True when a certificate pin cannot apply to this URL, because there is no
    /// handshake to compare a key against. Plain `http`, both admitted and
    /// refused. See "A pin on an unencrypted address" in this file's header for
    /// why the pairing must fail closed rather than have the pin silently
    /// dropped.
    static func pinCannotApply(to url: URL) -> Bool {
        url.scheme?.lowercased() == "http"
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
