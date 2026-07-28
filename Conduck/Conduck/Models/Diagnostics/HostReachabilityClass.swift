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
        // Strip IPv6 brackets (`[fe80::1]` → `fe80::1`).
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }

        // mDNS / Bonjour.
        if host == "local" || host.hasSuffix(".local") { return .mdnsLocal }

        if let octets = parseIPv4(host) { return classifyIPv4(octets) }
        if host.contains(":") { return classifyIPv6(host) }

        // A hostname that is neither an IP nor `.local` → treat as public.
        return .publicHost
    }

    // MARK: - IPv4

    /// Parse dotted-quad IPv4 into four octets, or nil if the string isn't a
    /// well-formed IPv4 literal (rejects leading zeros / out-of-range octets so a
    /// hostname like `10.example.com` never mis-parses).
    private static func parseIPv4(_ s: String) -> (Int, Int, Int, Int)? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard let n = Int(part), (0...255).contains(n), String(n) == part else { return nil }
            octets.append(n)
        }
        return (octets[0], octets[1], octets[2], octets[3])
    }

    private static func classifyIPv4(_ o: (Int, Int, Int, Int)) -> HostReachabilityClass {
        // Tailscale CGNAT 100.64.0.0/10 → 100.64.x.x – 100.127.x.x.
        if o.0 == 100, (64...127).contains(o.1) { return .tailscale }
        // RFC1918 private ranges.
        if o.0 == 10 { return .localLAN }
        if o.0 == 172, (16...31).contains(o.1) { return .localLAN }
        if o.0 == 192, o.1 == 168 { return .localLAN }
        // Loopback + IPv4 link-local.
        if o.0 == 127 { return .localLAN }
        if o.0 == 169, o.1 == 254 { return .localLAN }
        return .publicHost
    }

    // MARK: - IPv6

    private static func classifyIPv6(_ host: String) -> HostReachabilityClass {
        // Drop any zone id (`fe80::1%en0`).
        let addr = (host.split(separator: "%").first.map(String.init) ?? host).lowercased()
        if addr == "::1" { return .localLAN }                       // loopback
        if addr.hasPrefix("fc") || addr.hasPrefix("fd") { return .localLAN }  // ULA fc00::/7
        // Link-local fe80::/10 → fe80..febf (first hextet 0xfe8–0xfeb).
        if addr.hasPrefix("fe8") || addr.hasPrefix("fe9")
            || addr.hasPrefix("fea") || addr.hasPrefix("feb") { return .localLAN }
        return .publicHost
    }
}
