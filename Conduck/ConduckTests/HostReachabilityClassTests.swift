// SPDX-License-Identifier: Apache-2.0

// Conduck
// HostReachabilityClassTests.swift
//
// Locks the pure locality classifier behind the Diagnostics Local-Network hint:
// private-LAN / `.local` / Tailscale hosts classify as "suggests local network
// permission"; public IPs and ordinary hostnames do not. A regression here would
// either mis-hint a public failure (crying wolf) or drop the hint on the
// self-hoster's #1 footgun (a denied LAN grant that fails as a generic timeout).
//
// Pure + headless: no network, no Keychain, no Core Data.

import XCTest
@testable import Conduck

final class HostReachabilityClassTests: XCTestCase {

    // MARK: - IPv4 private ranges → local

    func testRFC1918IPv4ClassifiesLocal() {
        for host in ["10.0.0.1", "10.255.1.2", "172.16.0.9", "172.31.255.1", "192.168.1.50", "127.0.0.1", "169.254.10.20"] {
            XCTAssertEqual(HostReachabilityClass.classify(host), .localLAN, "\(host) is a private/loopback/link-local IPv4")
            XCTAssertTrue(HostReachabilityClass.classify(host).suggestsLocalNetworkPermission, "\(host) should hint")
        }
    }

    func testTailscaleCGNATClassifiesTailscale() {
        for host in ["100.64.0.1", "100.100.100.100", "100.127.255.254"] {
            XCTAssertEqual(HostReachabilityClass.classify(host), .tailscale, "\(host) is Tailscale CGNAT 100.64.0.0/10")
            XCTAssertTrue(HostReachabilityClass.classify(host).suggestsLocalNetworkPermission)
        }
        // 100.128.x is OUTSIDE the /10 → public.
        XCTAssertEqual(HostReachabilityClass.classify("100.128.0.1"), .publicHost)
    }

    // MARK: - Public IPv4 / hostnames → public (no hint)

    func testPublicIPv4AndHostnamesClassifyPublic() {
        for host in ["8.8.8.8", "1.1.1.1", "203.0.113.5", "gateway.example.com", "openclaw.mydomain.io"] {
            XCTAssertEqual(HostReachabilityClass.classify(host), .publicHost, "\(host) is public")
            XCTAssertFalse(HostReachabilityClass.classify(host).suggestsLocalNetworkPermission, "\(host) must not hint")
        }
    }

    func testHostThatMerelyStartsWithTenIsNotLocal() {
        // A hostname beginning with "10" must NOT mis-parse as 10.0.0.0/8.
        XCTAssertEqual(HostReachabilityClass.classify("10hosting.example.com"), .publicHost)
    }

    // MARK: - mDNS

    func testDotLocalClassifiesMdns() {
        XCTAssertEqual(HostReachabilityClass.classify("gateway.local"), .mdnsLocal)
        XCTAssertEqual(HostReachabilityClass.classify("mac-mini.local"), .mdnsLocal)
        XCTAssertTrue(HostReachabilityClass.classify("gateway.local").suggestsLocalNetworkPermission)
    }

    // MARK: - IPv6

    func testIPv6ULAAndLinkLocalClassifyLocal() {
        for host in ["fc00::1", "fd12:3456:789a::1", "fe80::1", "[fe80::1]", "::1", "[fe80::1%en0]"] {
            XCTAssertEqual(HostReachabilityClass.classify(host), .localLAN, "\(host) is IPv6 ULA/link-local/loopback")
        }
    }

    func testPublicIPv6ClassifiesPublic() {
        // 2000::/3 global unicast.
        XCTAssertEqual(HostReachabilityClass.classify("2606:4700:4700::1111"), .publicHost)
        XCTAssertEqual(HostReachabilityClass.classify("[2606:4700::1]"), .publicHost)
    }

    // MARK: - Transport hint (secondary signal)

    func testTailscaleTransportHintOverridesPublicLookingHost() {
        // A public-looking tailnet MagicDNS name still resolves onto the tailnet.
        XCTAssertEqual(HostReachabilityClass.classify("myhost.tailnet.ts.net", transportHint: "tailscale"), .tailscale)
    }

    func testNonTailnetTransportHintDoesNotForceLocal() {
        // Funnel is PUBLIC egress — a down Funnel host is a real reachability
        // failure, NOT a Local-Network-permission one, so it must not force the hint.
        XCTAssertEqual(HostReachabilityClass.classify("myhost.example.com", transportHint: "funnel"), .publicHost)
        // Cloudflare / public transports say nothing about locality.
        XCTAssertEqual(HostReachabilityClass.classify("gateway.example.com", transportHint: "cloudflare"), .publicHost)
        XCTAssertEqual(HostReachabilityClass.classify("gateway.example.com", transportHint: "public"), .publicHost)
    }

    // MARK: - Degenerate input

    // MARK: - Delegated literal parsing (`LocalNetworkHost` owns the parser)

    /// The bug the delegation removes. `fe8::1` parses to `0fe8:…`, an ordinary
    /// global address — the old text-prefix match called it link-local.
    func testDelegatedParserFixesTextPrefixBug() {
        XCTAssertEqual(HostReachabilityClass.classify("fe8::1"), .publicHost,
                       "A TEXT prefix would call this link-local; byte-exact matching does not.")
        XCTAssertEqual(HostReachabilityClass.classify("fe80::1"), .localLAN,
                       "The genuine link-local address still classifies local.")
    }

    /// The second improvement: the legacy IPv4 grammar is now understood, so a
    /// decimal-encoded loopback is recognised instead of read as a hostname.
    func testDecimalIPv4LiteralIsRecognised() {
        XCTAssertEqual(HostReachabilityClass.classify("2130706433"), .localLAN,
                       "inet_aton reads this as 127.0.0.1, and so does the resolver.")
        XCTAssertEqual(HostReachabilityClass.classify("0xc0a80101"), .localLAN,
                       "Packed hex for 192.168.1.1.")
    }

    /// THE DELIBERATE DISAGREEMENT, pinned so it reads as intentional rather
    /// than accidental. `HostReachabilityClass` answers "would a denied Local
    /// Network permission explain this timeout?", for which a tailnet address IS
    /// local; `LocalNetworkHost` answers "will iOS send plain http here?", for
    /// which it is not (measured -1022). Both answers are correct for their own
    /// question, and the two types must go on disagreeing about exactly this.
    func testTailscaleCGNATStaysLocalForTheHint() {
        XCTAssertEqual(HostReachabilityClass.classify("100.64.0.1"), .tailscale)
        XCTAssertTrue(HostReachabilityClass.classify("100.64.0.1").suggestsLocalNetworkPermission)
        XCTAssertEqual(LocalNetworkHost.classify("100.64.0.1"), .remote,
                       "The transport classifier must NOT follow — iOS refuses plain http to CGNAT.")
    }

    func testNilOrEmptyHostIsUnknownAndDoesNotHint() {
        XCTAssertEqual(HostReachabilityClass.classify(nil), .unknown)
        XCTAssertEqual(HostReachabilityClass.classify(""), .unknown)
        XCTAssertFalse(HostReachabilityClass.classify(nil).suggestsLocalNetworkPermission)
    }
}
