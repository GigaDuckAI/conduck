// SPDX-License-Identifier: Apache-2.0

// Conduck
// HostReachabilityClass.swift
//
// Pure locality classifier for a gateway / file-server host — the ONLY signal
// behind the Diagnostics "Local Network permission" INFERENCE hint (iOS). Apple
// exposes no readable Local-Network-permission status, so a denied grant makes a
// LAN / `.local` / Tailscale host fail as a generic timeout with no attributable
// cause. When such a host's reachability probe FAILS while the internet row is
// green, Diagnostics appends a soft "if this is a local address, check Local
// Network permission" hint to that row.
//
// Privacy: the classifier reduces a host string to a locality ENUM; ONLY the
// enum (never the host) crosses into the runner / a check detail / the copy
// block. The raw host never leaves this call.
//
// IT OWNS NO ADDRESS PARSER. Numeric literals are parsed by `LocalNetworkHost`,
// the app's single `inet_aton`/`inet_pton` front end, and this type keeps only
// its own RANGE TABLE on top. The two classifiers are SUPPOSED to disagree,
// but only in ONE DIRECTION:
//
//   • THIS type may call local what `LocalNetworkHost` refuses. CGNAT
//     `100.64.0.0/10` (a denied Local Network permission really does explain a
//     dead tailnet host, while iOS refuses plain http to it — measured,
//     -1022), single-label names, `0.0.0.0/8` with its v6 twin `::`, and
//     deprecated site-local `fec0::/10` all diverge this way. Harmless by construction: the app
//     refuses to SAVE those shapes as plain-http endpoints, so the worst case
//     is a soft hint about an address the user was already refused — while an
//     https URL with the same host IS saveable and genuinely breaks under a
//     denied grant, which is exactly when the hint earns its keep.
//
//   • The REVERSE is forbidden. A row `LocalNetworkHost` admits over plain
//     http (loopback, RFC1918, 169.254/16, ULA, link-local, `localhost`,
//     `.local`) must be local HERE too: an address the app admits but this
//     type calls public is one whose timeout gets NO Local-Network-permission
//     hint, and that hint is the only thing that explains the timeout a
//     denied grant produces.
//   • They must NOT disagree about what a STRING IS. One parser, so
//     `2130706433`, `0x7f.0.0.1` and `::ffff:192.168.1.1` mean the same address
//     to both — and so the text-prefix bug that called `fe8::1` link-local
//     cannot come back (`fe8::1` parses to `0fe8:…`; every range test below is
//     byte-exact).

import Foundation

/// Locality class of a host, derived from its string form (+ an optional pairing
/// transport hint). Drives ONLY the soft Local-Network-permission hint.
enum HostReachabilityClass: Equatable, Sendable {
    /// RFC1918 IPv4 (`10.` / `172.16–31.` / `192.168.`), IPv4 link-local
    /// (`169.254.`), loopback, or IPv6 ULA (`fc00::/7`) / link-local (`fe80::/10`)
    /// / loopback (`::1`).
    case localLAN
    /// An mDNS / Bonjour `.local` name (resolved on the local link).
    case mdnsLocal
    /// Tailscale CGNAT `100.64.0.0/10`, or a pairing transport hint of
    /// `.tailscale` (a public-looking tailnet MagicDNS name still resolves onto the
    /// private tailnet). NOTE: `.funnel` is deliberately EXCLUDED — Tailscale Funnel
    /// is PUBLIC egress (the client reaches `<name>.ts.net` over the ordinary
    /// internet, no tailnet membership / Local Network grant), so a down Funnel host
    /// is a genuine reachability failure, not a Local-Network-permission one.
    case tailscale
    /// A routable public host (public IP or ordinary hostname).
    case publicHost
    /// Could not parse a host.
    case unknown

    /// True when a FAILED reachability probe of a host of this class SHOULD hint
    /// at the iOS Local Network permission — a private-LAN / `.local` / tailnet
    /// host is the case a denied grant silently breaks. Public / unknown never
    /// hints (a public host failing is a genuine reachability problem, not a
    /// permission one).
    var suggestsLocalNetworkPermission: Bool {
        switch self {
        case .localLAN, .mdnsLocal, .tailscale:
            return true
        case .publicHost, .unknown:
            return false
        }
    }

    /// Classify a host string. `transportHint` is the per-ref
    /// `PairingPayload.Transport` raw value (App-Group stored) — a SECONDARY
    /// signal that pins `.tailscale` even when the host is a public-looking
    /// MagicDNS name.
    static func classify(_ host: String?, transportHint: String? = nil) -> HostReachabilityClass {
        // Secondary signal first: an explicit tailnet transport overrides a
        // public-looking host. Only `.tailscale` implies the private tailnet;
        // `.funnel` (public egress), `.cloudflare` and `.public` say nothing
        // about locality.
        if let raw = transportHint, let transport = PairingPayload.Transport(rawValue: raw) {
            switch transport {
            case .tailscale:
                return .tailscale
            case .funnel, .cloudflare, .publicCert:
                break
            }
        }

        guard var host = host?.lowercased(), !host.isEmpty else { return .unknown }
        // Strip IPv6 brackets (`[fe80::1]` → `fe80::1`). Kept here rather than in
        // `LocalNetworkHost`: that type's input contract is `URL.host`, which
        // Foundation has already unbracketed, while this one is also handed
        // display-shaped strings.
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        // Zone id + at most one trailing dot, through the shared canonicaliser —
        // `fe80::1%en0` parses to a DIFFERENT address with the zone attached.
        host = LocalNetworkHost.canonicalized(host)
        guard !host.isEmpty else { return .unknown }

        // mDNS / Bonjour.
        if host == "local" || host.hasSuffix(".local") { return .mdnsLocal }

        if let bytes = LocalNetworkHost.parseIPv6(host) {
            // A private v4 address wearing v6 clothing (`::ffff:192.168.1.1`)
            // is that v4 address for locality purposes.
            if let embedded = LocalNetworkHost.unwrappedIPv4(fromIPv6: bytes) {
                return classifyIPv4(embedded)
            }
            return classifyIPv6(bytes)
        }
        if let address = LocalNetworkHost.parseIPv4(host) { return classifyIPv4(address) }

        // `localhost`, and any name with no dot in it — when such a name
        // resolves at all it is via mDNS or this device's own search domain,
        // both the local link, and a denied Local Network grant is exactly what
        // makes `https://nas:8443` time out with nothing to attribute it to.
        // `LocalNetworkHost` REFUSES a bare label over plain http (a real
        // one-label TLD can answer at the public root) — that is the sanctioned
        // one-way divergence in the header: the plain-http spelling was never
        // saveable, while the https spelling is, and it is the https one this
        // hint exists for.
        if !host.contains(".") { return .localLAN }

        // A dotted hostname that is not `.local` → treat as public.
        return .publicHost
    }

    // MARK: - Range tables (parsing lives in `LocalNetworkHost`)

    private static func classifyIPv4(_ address: UInt32) -> HostReachabilityClass {
        let (o0, o1, _, _) = LocalNetworkHost.ipv4Octets(address)
        // Tailscale CGNAT 100.64.0.0/10 → 100.64.x.x – 100.127.x.x. FIRST, and
        // deliberately NOT what `LocalNetworkHost` answers — see the header.
        if o0 == 100, (64...127).contains(o1) { return .tailscale }
        // RFC1918 private ranges.
        if o0 == 10 { return .localLAN }
        if o0 == 172, (16...31).contains(o1) { return .localLAN }
        if o0 == 192, o1 == 168 { return .localLAN }
        // Loopback + IPv4 link-local.
        if o0 == 127 { return .localLAN }
        if o0 == 169, o1 == 254 { return .localLAN }
        // "This network" 0.0.0.0/8 — `http://0/` reaches THIS host on Darwin.
        // `LocalNetworkHost` refuses it over plain http (unmeasured, routable),
        // but local HERE: whatever a request to it fails against, it is not the
        // public internet — the sanctioned one-way divergence in the header.
        if o0 == 0 { return .localLAN }
        return .publicHost
    }

    /// Byte-exact, never a text prefix: `fe8::1` parses to `0fe8:…` and is a
    /// perfectly ordinary global address.
    private static func classifyIPv6(_ bytes: [UInt8]) -> HostReachabilityClass {
        guard bytes.count == 16 else { return .publicHost }
        if bytes.allSatisfy({ $0 == 0 }) { return .localLAN }                           // unspecified ::
        if bytes[0..<15].allSatisfy({ $0 == 0 }), bytes[15] == 1 { return .localLAN }  // ::1
        if bytes[0] & 0xFE == 0xFC { return .localLAN }                                 // ULA fc00::/7
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return .localLAN }               // link-local fe80::/10
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0xC0 { return .localLAN }               // site-local fec0::/10
        return .publicHost
    }
}
