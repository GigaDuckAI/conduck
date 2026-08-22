// SPDX-License-Identifier: Apache-2.0

// Conduck
// LocalNetworkHostTests.swift
//
// Covers `LocalNetworkHost` — the classifier that decides which hosts iOS will
// accept a plain-`http` request to. It is a PREDICTION of the platform's answer,
// not a policy of ours, so every case here is either something the ATS probe
// MEASURED on iOS 26.5 or a lookalike a naive implementation gets wrong.
//
// The lookalike half is the part worth guarding: `192.168.1.1.evil.com` is a
// public host that reads as private, `010.1.1.1` is the PUBLIC 8.1.1.1 that a
// decimal regex reads as private, `fe8::1` is a global address that a text
// prefix reads as link-local, and `fe80::1%en0` parses to a different address
// entirely if the zone id is left attached. Every one of those is a way to be
// told a remote host is local.
//
// Host strings below are synthetic; nothing here performs a lookup or a
// connection (the classifier deliberately never resolves — see its header).

import XCTest
@testable import Conduck

final class LocalNetworkHostTests: XCTestCase {

    private func assertLocal(_ hosts: [String], _ why: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        for host in hosts {
            XCTAssertEqual(LocalNetworkHost.classify(host), .local, "\(host): \(why)",
                           file: file, line: line)
            XCTAssertTrue(LocalNetworkHost.isLocal(host), host, file: file, line: line)
        }
    }

    private func assertRemote(_ hosts: [String], _ why: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        for host in hosts {
            XCTAssertEqual(LocalNetworkHost.classify(host), .remote, "\(host): \(why)",
                           file: file, line: line)
            XCTAssertFalse(LocalNetworkHost.isLocal(host), host, file: file, line: line)
        }
    }

    // MARK: - IPv4 ranges

    func testPrivateIPv4LiteralsAreLocal() {
        assertLocal([
            "10.0.0.1", "10.255.255.254",
            // Both edges of 172.16/12 — the range most often written as 172.16
            // only, or as the whole of 172.
            "172.16.0.1", "172.31.255.254",
            "192.168.1.10", "192.168.0.1",
            "169.254.1.1",
            // The whole 127/8, not just `.0.0.1` — kernel-confined to `lo0`,
            // the header's carve-out from the refuse-when-unmeasured rule.
            "127.0.0.1", "127.1.2.3"
        ], "measured permitted, or kernel-confined under the header's unmeasured rule")
    }

    /// The unmeasured-but-routable shapes are REFUSED on this path — the
    /// header's rule: an unmeasured case is allowed only when the kernel
    /// confines the traffic; everything else costs a refusal message rather
    /// than risking the token. 0.0.0.0/8 is also a classic SSRF bypass string.
    func testUnmeasuredRoutableShapesAreRemote() {
        assertRemote(["0.0.0.0", "0.1.2.3", "0.255.255.254"],
                     "0.0.0.0/8 is unmeasured and not kernel-confined — refused rather than risked")
    }

    func testAddressesJustOutsideThePrivateRangesAreRemote() {
        assertRemote([
            "172.15.255.254", "172.32.0.1",   // 172.16/12 boundaries, both sides
            "192.167.1.1", "192.169.1.1",     // 192.168/16 boundaries
            "169.253.1.1", "169.255.1.1",     // 169.254/16 boundaries
            "9.0.0.1", "11.0.0.1",            // 10/8 boundaries
            "8.8.8.8", "1.1.1.1", "203.0.113.5"
        ], "one octet outside a private range is an ordinary public address")
    }

    /// CGNAT is the contested one, and it is EXCLUDED deliberately: the probe
    /// measured -1022 for it over plain http under the no-key control AND under
    /// `NSAllowsLocalNetworking = YES`. This is the range Tailscale hands out, so
    /// a tailnet gateway must be https. Pinned from BOTH sides of the /10 so a
    /// future "just widen it to 100/8" cannot pass quietly.
    func testCGNATIsRemote() {
        assertRemote(["100.64.0.1", "100.99.99.99", "100.127.255.254"],
                     "CGNAT 100.64.0.0/10 — MEASURED -1022 over plain http")
        assertRemote(["100.63.255.254", "100.128.0.1"],
                     "outside the /10, and public for the ordinary reason")
    }

    // MARK: - The legacy IPv4 grammar

    /// THE REASON THE PLATFORM PARSER IS USED. `getaddrinfo` falls back to
    /// `inet_aton`'s grammar for numeric-looking hosts, so anything this app
    /// parses differently is an address it would classify one way and connect
    /// another.
    func testDecimalHexAndOctalIPv4FormsAreParsedNotGlobbed() {
        assertLocal([
            "2130706433",   // decimal integer → 127.0.0.1
            "0x7f.0.0.1",   // hex octet      → 127.0.0.1
            "0177.0.0.1",   // octal octet    → 127.0.0.1
            "0xc0a80101",   // packed hex     → 192.168.1.1
            "127.1",        // short form     → 127.0.0.1
            "192.168.001.010"
        ], "the platform reads all of these as private/loopback addresses")
        assertRemote(["0"], // → 0.0.0.0, the refused "this network" range
                     "the short form of 0.0.0.0 gets the range's verdict, not a hostname's")

        // THE CASE A DECIMAL REGEX GETS BACKWARDS. A naive parse reads
        // "10.1.1.1" and calls it private; the resolver reads the leading zero
        // as OCTAL and connects to the PUBLIC 8.1.1.1.
        assertRemote(["010.1.1.1"],
                     "leading zero is OCTAL — this is 8.1.1.1, a public address")
        XCTAssertEqual(LocalNetworkHost.parseIPv4("010.1.1.1"),
                       (8 << 24) | (1 << 16) | (1 << 8) | 1,
                       "Precondition for the assertion above: inet_aton reads the leading zero as octal.")
    }

    func testStringsThatMerelyLookNumericAreNotAddresses() {
        for host in ["1.2.3.4.5", "192.168.1.1.evil.com", "192.168.1.50.nip.io",
                     "ollama", "256.1.1.1", "10.0.0.1x", "10hosting.example.com"] {
            XCTAssertNil(LocalNetworkHost.parseIPv4(host),
                         "\(host) must not parse as an IPv4 literal.")
        }
    }

    // MARK: - IPv6

    /// BYTE-EXACT, never a text prefix. `fe8::1` parses to `0fe8:…` and is a
    /// perfectly ordinary global address — `hasPrefix("fe8")` is the bug this
    /// pins shut.
    func testIPv6RangesAreByteExact() {
        assertLocal(["::1", "fc00::1", "fd00::1", "fdff:ffff::1",
                     "fe80::1", "febf::1"],
                    "loopback / ULA fc00::/7 / link-local fe80::/10")
        assertRemote(["::", "fec0::1", "fecf::1", "feff::1"],
                     "unspecified `::` (the v6 twin of 0.0.0.0) and site-local fec0::/10 — unmeasured and routable, refused")
        assertRemote(["fe8::1", "fec::1", "2001:db8::1", "2606:4700:4700::1111",
                      "64:ff9b::1.2.3.4", "fe00::1"],
                     "a TEXT prefix would call the first two local; they are global unicast")
    }

    func testIPv4MappedAndCompatibleIPv6AreUnwrapped() {
        assertLocal(["::ffff:192.168.1.1", "::ffff:10.0.0.1", "::192.168.1.1"],
                    "a private v4 address wearing v6 clothing is still that address")
        assertRemote(["::ffff:8.8.8.8", "::ffff:100.64.0.1"],
                     "unwrapping must not launder a public (or CGNAT) address into 'local IPv6'")
    }

    /// MEASURED: `inet_pton(AF_INET6, "fe80::1%en0", …)` SUCCEEDS and yields a
    /// DIFFERENT address from `fe80::1`. If a refactor drops the zone strip, the
    /// classifier starts answering about an address nothing connects to — so the
    /// quirk is pinned here, not just the outcome.
    func testZoneIdIsStrippedBeforeParsing() {
        assertLocal(["fe80::1%en0", "fe80::1%25en0", "fd00::1%utun3"],
                    "two literals differing only by zone id are one address for this decision")

        let withZone = LocalNetworkHost.parseIPv6("fe80::1%en0")
        let withoutZone = LocalNetworkHost.parseIPv6("fe80::1")
        XCTAssertNotNil(withZone, "Precondition: the platform parses a zoned literal at all.")
        XCTAssertNotEqual(withZone, withoutZone,
                          "The measured quirk: a raw zone id parses to a DIFFERENT address, which is why classify() strips it first.")
    }

    // MARK: - Suffix and lookalike shapes

    func testTrailingDotIsStripped() {
        assertLocal(["mac-mini.local.", "localhost.", "local."],
                    "the explicit-FQDN spelling resolves identically, and hasSuffix('.local') is false for it")
        assertRemote(["gateway.myhomelab.com."],
                     "the trailing dot must not turn a public name into a local one either")
    }

    /// Single labels are refused ROOTED OR NOT. Real one-label TLDs answer at
    /// the public root with apex A records — `dig +short A uz.` returns
    /// 91.212.89.8, `ws.` 64.70.19.33, `cm.` 195.24.205.60 (measured) — so a
    /// resolver falling through its search domains could carry a bearer token
    /// in cleartext to a public host. The refusal costs nothing that worked
    /// (the ATS probe for an unresolvable label dead-ends at -1003 anyway),
    /// and the `.local` spelling of the same machine stays accepted.
    func testSingleLabelIsRemoteRootedOrNot() {
        assertRemote(["uz.", "ws.", "cm.", "tk.", "myhost.", "ollama."],
                     "a trailing dot forces public-root resolution, where real one-label TLDs answer")
        assertRemote(["uz", "ws", "myhost", "ollama", "nas", "mac-mini"],
                     "the unrooted spelling can reach the same public host through search-domain fall-through")
        // The named locals are matched after the strip and mean the same rooted.
        assertLocal(["localhost.", "local."],
                    "localhost. and local. are the rooted spellings of names that are local by definition")
    }

    /// MEASURED: `URL(string: "http://192.168.1.1%0aevil.com/")!.host` is
    /// `"192.168.1.1\nevil.com"` — Foundation percent-DECODES the control
    /// character straight into `.host` — and `inet_aton` accepts ONE trailing
    /// whitespace byte followed by arbitrary junk, so a literal parse would read
    /// the private-looking prefix and stop. The smuggled-authority guard covers
    /// every scalar below 0x21, not just the space and tab it names.
    func testControlCharactersInAHostAreRefused() {
        assertRemote([
            "192.168.1.1\nevil.com",
            "192.168.1.1\revil.com",
            "10.0.0.1\u{0B}evil.com",
            "10.0.0.1\u{0C}evil.com",
            "10.0.0.1\0evil.com",
            "10.0.0.1 ",
            "10.0.0.1\tevil.com"
        ], "a host carrying a control character is refused whole rather than parsed to its private-looking prefix")

        // The precondition that makes the assertion above load-bearing.
        XCTAssertEqual(LocalNetworkHost.parseIPv4("10.0.0.1\nevil.com"),
                       (10 << 24) | 1,
                       "Measured: inet_aton checks only the FIRST trailing byte for isspace, so it truncates here.")
    }

    /// The `%` strip exists for an IPv6 zone id and must not truncate a NAME.
    /// `http://192.168.1.1%25evil.com/` decodes to the host
    /// `192.168.1.1%evil.com`; an unconditional strip would leave the private
    /// literal `192.168.1.1`, which is the smuggled authority this file refuses.
    func testPercentDoesNotTruncateAHostname() {
        assertRemote(["192.168.1.1%evil.com", "10.0.0.1%25evil.com"],
                     "the zone strip applies only to a string shaped like the IPv6 literal a zone can attach to")
        assertLocal(["fe80::1%en0"], "and it still applies where it is meant to")
    }

    /// The lookalike family. Every one of these is a PUBLIC host that reads as
    /// private to a scan-for-a-substring implementation.
    func testSuffixConfusion() {
        assertRemote([
            "192.168.1.1.evil.com",
            "192.168.1.50.nip.io",
            "127.0.0.1.attacker.example",
            "mylocal.example.com",
            "local.example.com",
            "example.com.local.evil.com",
            "brisk-lantern-quarry-motion.trycloudflare.com"
        ], "a dotted name is remote however private it looks")

        // `notlocal` has no dot at all, so the SINGLE-LABEL rule refuses it —
        // stated explicitly so neither rule is read as a suffix scan.
        assertRemote(["notlocal"], "a bare label is refused by its own rule, not by a suffix match")
    }

    func testHostnameRules() {
        assertLocal(["localhost", "local", "gateway.local", "mac-mini.local"],
                    "the loopback name and mDNS names — the only name shapes admitted")
        assertRemote(["ollama", "mac-mini", "nas"],
                     "bare labels are refused — a real one-label TLD can answer at the public root")
        assertRemote(["gateway.myhomelab.com", "nas.home.arpa", "box.lan",
                      "host.internal", "example.com", "gw.example.ts.net"],
                     ".lan/.home.arpa/.internal are deliberately NOT local: iOS refuses them over plain http")
    }

    // MARK: - Degenerate and hostile input

    func testSmuggledAuthorityCharactersAreRefused() {
        assertRemote(["", "10.0.0.1 ", "10.0.0.1\t", "192.168.1.1/x", "192.168.1.1?a",
                      "192.168.1.1#f", "192.168.1.1@evil.com", "[fd00::1]"],
                     "a host carrying one of these is refused whole rather than parsed")
        // The measured quirk the whitespace refusal covers: inet_aton itself
        // ACCEPTS a trailing space.
        XCTAssertNotNil(LocalNetworkHost.parseIPv4("10.0.0.1 "),
                        "Precondition: the platform parser is lenient here, which is why classify() screens first.")
    }

    func testCaseIsIgnored() {
        assertLocal(["LOCALHOST", "MAC-MINI.LOCAL", "FE80::1", "FD00::1"],
                    "every comparison runs against lowercase ASCII")
    }

    // MARK: - The input contract

    /// `URL.host` is the ONLY correct input, and this pins why: Foundation
    /// resolves userinfo, so the apparent host and the real one differ.
    func testURLHostIsWhatMustBeClassified() {
        XCTAssertEqual(URL(string: "http://192.168.1.1@evil.com")!.host, "evil.com",
                       "Foundation resolves userinfo — classifying anything else classifies a destination the app will not connect to.")
        XCTAssertEqual(LocalNetworkHost.classify("evil.com"), .remote)
        XCTAssertEqual(URL(string: "http://[fd00::1]:8080")!.host, "fd00::1",
                       "URL.host already strips IPv6 brackets.")
        XCTAssertEqual(URL(string: "http://[fe80::1%25en0]")!.host, "fe80::1%en0",
                       "URL.host percent-DECODES the RFC 6874 zone spelling, so one strip covers both forms.")
    }
}
