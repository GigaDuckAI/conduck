// SPDX-License-Identifier: Apache-2.0

// Conduck
// LocalNetworkHost.swift
//
// WHAT THIS IS, said first because it changes how every rule below reads: this
// is NOT a policy Conduck imposes, and it is NOT a security boundary. It is a
// PREDICTION of what iOS will permit over plain `http`, made from the same
// thing iOS itself decides from — the host STRING, before any TCP connect.
// Where this file answers `.remote`, App Transport Security answers
// `NSURLErrorAppTransportSecurityRequiresSecureConnection` (-1022). Surfacing
// that while the user is still looking at the address, instead of three screens
// later as an unexplained failure, is the entire purpose of the type.
//
// WHY IT EXISTS AT ALL. A large part of the self-hosting world serves plain
// HTTP on the local network and cannot be configured to do anything else —
// Ollama is the load-bearing example: it listens on port 11434 with no TLS
// support of its own. Refusing every non-`https` address shuts those users out
// of the product entirely, so `EndpointURLPolicy` admits plain `http` toward a
// host only the local network can reach, and this type decides which hosts
// those are.
//
// ─────────────────────────────────────────────────────────────────────────────
// THE MEASURED BOUNDARY (iOS 26.5 Simulator, build 23F77, hosted test bundle
// running inside Conduck.app; macOS 26.6 probed separately and matched on
// every row). The full matrix and its reasoning live in
// `EndpointURLPolicy.swift`'s header; the two results this file encodes are:
//
//   • A PRIVATE-RANGE IP LITERAL over plain http is PERMITTED — with no
//     `NSAppTransportSecurity` key at all. 10/8, 172.16/12, 192.168/16,
//     169.254/16, IPv6 ULA, loopback and `*.local` names all connected.
//   • A DOTTED DNS NAME over plain http is REFUSED — including one that
//     resolves INTO the private range. `http://192.168.1.50.nip.io/` returned
//     -1022 while the bare literal `http://192.168.1.50/` did not, so ATS keys
//     on the host STRING being a private literal, not on where the name points.
//     Nothing in the ATS declaration rescues it, and split-horizon DNS is
//     therefore unusable over plain http however private the machine behind it.
//
// That second result is the one that makes this file a lookalike-shaped
// classifier rather than a resolver: `gateway.myhomelab.com` may A-record to
// 192.168.1.50 and is still refused by the platform.
//
// ─────────────────────────────────────────────────────────────────────────────
// WHY THIS NEVER RESOLVES A NAME. Three reasons, each independently sufficient:
//
//   1. iOS decides from the string before any connect, so resolving would be
//      predicting a DIFFERENT question from the one that gets asked.
//   2. A name that resolves to a private address at validation time can resolve
//      somewhere else at connect time (DNS rebinding / TOCTOU). A verdict
//      earned from a lookup is a verdict about a moment that has passed.
//   3. A settings field runs this on every keystroke. A DNS round-trip there is
//      a hang in a text field.
//
// ─────────────────────────────────────────────────────────────────────────────
// THE ATTACK AND LOOKALIKE CASES THIS DEFENDS AGAINST, and why each rule is
// shaped the way it is. Every one of these was MEASURED on this machine — the
// numbers below are what Foundation and the platform's own parsers actually
// answered, not what the RFCs suggest they should.
//
//   • LEGACY IPv4 GRAMMAR. `inet_aton` — which is also what `getaddrinfo`
//     falls back to for a numeric-looking host — accepts far more than a dotted
//     quad: `2130706433` → 127.0.0.1, `0x7f.0.0.1` → 127.0.0.1,
//     `0177.0.0.1` → 127.0.0.1, `0xc0a80101` → 192.168.1.1, `127.1` →
//     127.0.0.1. THE CASE A DECIMAL REGEX GETS BACKWARDS is `010.1.1.1`: a
//     naive parse reads "10.1.1.1" and calls it private, while the resolver
//     reads the leading zero as OCTAL and connects to the PUBLIC 8.1.1.1.
//     Using the platform's own parser is what guarantees this file cannot
//     disagree with the resolver about where the connection goes. (A shipping
//     competitor matches `^\d+\.\d+\.\d+\.\d+$` and therefore treats
//     `2130706433` as an ordinary hostname.)
//   • SUFFIX CONFUSION. `192.168.1.1.evil.com` and `192.168.1.50.nip.io` are
//     ordinary public DNS names that merely LOOK numeric. They fail the literal
//     parse (mixed numeric and alphabetic labels) and land in the hostname
//     rules, which compare whole LABELS and never scan for an IP-shaped
//     substring — so both are `.remote`, which is also what ATS answers.
//   • TRAILING-DOT BYPASS. `myhost.local.` is the explicit-FQDN spelling of
//     `myhost.local` and resolves identically, but `hasSuffix(".local")` is
//     false for it. One trailing dot is stripped before any comparison. The
//     named locals (`localhost`, `local`) are matched AFTER the strip and keep
//     their verdict either way, which is what they mean rooted too.
//   • SINGLE-LABEL NAMES. `nas`, `ollama`, `uz` — refused, rooted or not. The
//     hopeful reading is that a dotless name resolves only via mDNS or the
//     device's search domain, both local — but real one-label TLDs answer at
//     the public root with apex A records. MEASURED on this machine:
//     `dig +short A uz.` → 91.212.89.8, `ws.` → 64.70.19.33, `cm.` →
//     195.24.205.60, and a `URLSession` GET of `http://uz./` reached that
//     public host. A resolver that falls through its search domains to the
//     root would deliver the bearer token in cleartext to such a host, so on
//     this path the label is refused — and the refusal costs nothing that
//     worked: the ATS probe for an unresolvable label dead-ends at -1003
//     (host not found) anyway. The `.local` spelling of the same machine
//     stays accepted, and the refusal copy names it as the fix.
//   • CONTROL CHARACTERS IN THE HOST. MEASURED:
//     `URL(string: "http://192.168.1.1%0aevil.com/")!.host` is
//     `"192.168.1.1\nevil.com"` — Foundation percent-DECODES it into `.host` —
//     and `inet_aton` accepts ONE trailing whitespace byte followed by arbitrary
//     junk, so the literal parse would read the private-looking prefix and stop.
//     Every scalar below `0x21` is therefore refused outright, which covers LF,
//     CR, VT, FF, NUL and the space/tab the named set already listed.
//   • IPv6 ZONE IDS. `inet_pton(AF_INET6, "fe80::1%en0", …)` SUCCEEDS on this
//     platform and yields `fe80:000e:…:0001` — a DIFFERENT address from
//     `fe80::1`. A raw zone id must therefore never reach the parser, so the
//     zone is stripped first. `URL.host` percent-DECODES the RFC 6874 spelling
//     (`%25en0` → `%en0`), so one strip covers both forms.
//   • IPv6 TEXT-PREFIX MATCHING. `fe8::1` parses to `0fe8:…`, which is NOT
//     link-local — so `hasPrefix("fe8")` is wrong. Every IPv6 range test here
//     is BYTE-EXACT against the parsed address.
//   • PRIVATE ADDRESSES IN IPv6 CLOTHING. `::ffff:192.168.1.1` parses to a
//     16-byte address ending `…ffffc0a80101`. Without the IPv4-mapped unwrap it
//     would classify as an ordinary global IPv6 address, i.e. "public", which
//     is the wrong answer in the direction that matters least here but is
//     simply incorrect. Both the mapped (`::ffff:0:0/96`) and the deprecated
//     compatible (`::a.b.c.d`) forms unwrap and re-run the IPv4 table.
//   • SMUGGLED AUTHORITY. Foundation should never put a space, `/`, `?`, `#`,
//     `@`, `[` or `]` inside `URL.host`, but a host string carrying one is
//     refused outright rather than parsed. That is also what covers the
//     measured quirk that `inet_aton("10.0.0.1 ")` — trailing space —
//     SUCCEEDS.
//
// ─────────────────────────────────────────────────────────────────────────────
// WHERE THE RANGES CAME FROM, and where they deliberately differ from the
// obvious guess.
//
//   • CGNAT 100.64.0.0/10 IS `.remote`, and it has its own arm rather than
//     falling into the default so the measurement can sit beside it: it
//     returned -1022 over plain http under the no-key control AND under
//     `NSAllowsLocalNetworking = YES`. This is the range an overlay VPN
//     (Tailscale) hands out, so a tailnet gateway must be `https`. The
//     exclusion is genuinely contested in the wild — some SSRF classifiers
//     bucket the range as public, others fold it into "local" — which is
//     exactly why it is written down as deliberate rather than left implicit.
//   • WHERE A CASE WAS NOT MEASURED, THE KERNEL DECIDES THE DEFAULT. This
//     file guards a path that sends a bearer token in CLEARTEXT, so an
//     unmeasured shape is allowed only when a wrong prediction cannot cost
//     the secret — i.e. when the kernel confines the traffic regardless of
//     the verdict. Two ranges qualify and stay `.local`: `127.0.0.0/8`
//     beyond `127.0.0.1` (the kernel routes the whole /8 to `lo0`; a packet
//     cannot leave the machine) and `fe80::/10` (link-local by definition,
//     and its IPv4 twin `169.254/16` WAS measured permitted). Every other
//     unmeasured shape is one a resolver or a route could carry beyond the
//     local network, and is REFUSED: `0.0.0.0/8` (with its v6 twin `::`),
//     the deprecated site-local
//     `fec0::/10`, and single-label names (the bullet above). The asymmetry
//     is the point: refusing a shape the platform might have permitted costs
//     a refusal message; allowing a shape that reaches the public internet
//     costs the token.
//   • `.lan`, `.home.arpa` and `.internal` are deliberately NOT local, even
//     though some classifiers list them. They are dotted names; the platform
//     refuses them over plain http; and calling them local here would promise
//     something iOS then takes away.
//
// ─────────────────────────────────────────────────────────────────────────────
// RELATIONSHIP TO `HostReachabilityClass` — the two disagree ONE-WAY, and
// only that way. That type answers a different question ("would a denied Local
// Network permission explain this timeout?"), so it may call local what this
// file refuses — Tailscale CGNAT, single-label names, `0.0.0.0/8`, `::`,
// `fec0::/10` — because a hint about an address the app refuses to save costs
// nothing, and an https URL with such a host is still saveable and still
// breaks under a denied grant. The REVERSE is forbidden: a row this file
// admits over plain http must be local there too, or its permission timeout
// loses the only hint that explains it. And they must NOT disagree about what
// a STRING IS, so `HostReachabilityClass` owns no address parser of its own
// and calls the ones below instead.
//
// Pure Foundation, isolation-free — the QR parser runs this off the main actor
// (through `EndpointURLPolicy`) while the Settings editor runs it on
// `@MainActor`.

import Foundation

enum LocalNetworkHost {

    /// Whether a host string names a destination only the local network can
    /// reach. `.local` is the PREDICTION that iOS will permit plain `http` to
    /// it; `.remote` is the prediction that iOS will refuse with -1022.
    enum Classification: Equatable, Sendable {
        case local
        case remote
    }

    /// True when `host` classifies `.local`. The predicate `EndpointURLPolicy`
    /// calls; nothing else in the app should re-derive it.
    static func isLocal(_ host: String) -> Bool {
        classify(host) == .local
    }

    /// Classify one host string.
    ///
    /// THE INPUT CONTRACT: pass `url.host` and nothing else. Never
    /// `URLComponents.host`, which keeps IPv6 brackets, and never a hand-rolled
    /// split of the URL string. MEASURED on this platform:
    /// `URL(string: "http://192.168.1.1@evil.com")!.host == "evil.com"` —
    /// Foundation resolves userinfo correctly, and `URL.host` is what every
    /// request, redirect-origin check, certificate challenge and pin lookup
    /// resolves. Classifying anything else classifies a destination the app
    /// will not connect to. Also measured:
    /// `URL(string: "http://[fd00::1]:8080")!.host == "fd00::1"` (brackets
    /// already stripped) and
    /// `URL(string: "http://[fe80::1%25en0]")!.host == "fe80::1%en0"` (zone
    /// percent-DECODED).
    ///
    /// The steps below are ORDERED and each either returns or falls through, so
    /// there is exactly one answer per input.
    static func classify(_ host: String) -> Classification {
        // 1. The function is TOTAL. Unreachable through `EndpointURLPolicy`
        //    (`.noHost` fires first), but a partial predicate is a hole.
        guard !host.isEmpty else { return .remote }

        // 2. One casing for every comparison below; all literals are ASCII.
        var candidate = host.lowercased()

        // 3. Defence in depth against a smuggled authority. Foundation should
        //    never emit any of these inside `.host`; if a future parser change
        //    does, the string must be refused rather than parsed. Also covers
        //    the measured `inet_aton("10.0.0.1 ")` trailing-space acceptance —
        //    and, through the scalar test, the percent-decoded control character
        //    (`%0a`, `%0d`, `%0b`, `%0c`, `%00`) that would otherwise truncate
        //    the parse to a private-looking prefix.
        if candidate.contains(where: { character in
            forbiddenHostCharacters.contains(character)
                || character.unicodeScalars.contains(where: { $0.value < 0x21 })
        }) {
            return .remote
        }

        // 4 + 5. Zone id, then trailing dot — BEFORE any parse, for the reasons
        //        in the header (a raw zone id parses to a different address; a
        //        trailing dot defeats a suffix comparison). The strip cannot
        //        flip a verdict: a single label is refused rooted or not, and
        //        the named/`.local` rows mean the same thing rooted.
        candidate = canonicalized(candidate)

        // 6. Nothing left to decide about.
        guard !candidate.isEmpty else { return .remote }

        // 7. IPv6 FIRST. A string that parses as an address is never retried as
        //    a hostname — every arm below returns.
        if let bytes = parseIPv6(candidate) {
            if let embedded = unwrappedIPv4(fromIPv6: bytes) {
                // IPv4-mapped `::ffff:0:0/96` or IPv4-compatible `::a.b.c.d`:
                // re-run the v4 table so a private address wearing v6 clothing
                // cannot classify as "public IPv6".
                return classifyIPv4(embedded)
            }
            return classifyIPv6(bytes)
        }

        // 8 + 9. IPv4, through the PLATFORM'S OWN legacy grammar.
        if let address = parseIPv4(candidate) {
            return classifyIPv4(address)
        }

        // 10. Only now is it a name.
        return classifyHostname(candidate)
    }

    // MARK: - Normalisation

    /// Characters that must never appear inside a `URL.host`. A host carrying
    /// one is refused whole (step 3) rather than parsed — the smuggled-authority
    /// defence.
    private static let forbiddenHostCharacters: Set<Character> = [
        " ", "\t", "/", "?", "#", "@", "[", "]"
    ]

    /// Drop an IPv6 zone id and AT MOST ONE trailing dot. Shared with
    /// `HostReachabilityClass` so the two cannot canonicalise differently.
    ///
    /// The zone strip keeps only the part before the FIRST `%`: two literals
    /// differing only by zone id are the same address for both decisions, and a
    /// raw zone id reaching `inet_pton` yields a DIFFERENT address entirely
    /// (measured — see the header). It applies ONLY to a string that also holds a
    /// `:`, i.e. one shaped like the IPv6 literal a zone id can legally attach
    /// to. Unconditional, it would truncate a NAME at its first `%` —
    /// `192.168.1.1%evil.com` (what `http://192.168.1.1%25evil.com/` decodes to)
    /// would become the private literal `192.168.1.1`, which is the smuggled
    /// authority this file exists to refuse.
    ///
    /// The dot strip is exactly one: `host.local.` is the explicit-FQDN spelling
    /// of `host.local`, while `host.local..` is not a name anything resolves.
    static func canonicalized(_ host: String) -> String {
        var candidate = host
        if candidate.contains(":"), let percent = candidate.firstIndex(of: "%") {
            candidate = String(candidate[candidate.startIndex..<percent])
        }
        if candidate.hasSuffix(".") {
            candidate = String(candidate.dropLast())
        }
        return candidate
    }

    // MARK: - Literal parsing (the ONE numeric-address parser in the app)

    /// Parse an IPv4 literal through `inet_aton`, the platform's own legacy
    /// grammar — NEVER a regular expression.
    ///
    /// THE SINGLE MOST LOAD-BEARING CHOICE IN THIS FILE. `getaddrinfo` falls
    /// back to the same grammar for a numeric-looking host, so using it is what
    /// guarantees this classifier cannot disagree with the resolver about where
    /// the connection actually goes. It accepts decimal, hex (`0x…`), octal
    /// (`0…`), packed and short forms; it correctly returns "not an address"
    /// for `1.2.3.4.5`, `192.168.1.1.evil.com`, `192.168.1.50.nip.io`, `ollama`,
    /// `256.1.1.1` and `10.0.0.1x`. Returns the address in HOST byte order.
    static func parseIPv4(_ host: String) -> UInt32? {
        var address = in_addr()
        let parsed = host.withCString { inet_aton($0, &address) }
        guard parsed != 0 else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }

    /// Parse an IPv6 literal through `inet_pton` into its 16 bytes, or nil.
    /// Bytes, never text: every range test in this app is byte-exact because
    /// `fe8::1` is not `fe80::1` (measured).
    ///
    /// Expects an already-canonicalised string — a raw `%zone` parses to a
    /// different address, so `classify(_:)` strips it first and any other caller
    /// must run `canonicalized(_:)` too.
    static func parseIPv6(_ host: String) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: 16)
        let parsed = host.withCString { cString in
            bytes.withUnsafeMutableBytes { buffer in
                inet_pton(AF_INET6, cString, buffer.baseAddress)
            }
        }
        return parsed == 1 ? bytes : nil
    }

    /// The four big-endian octets of a host-order IPv4 address.
    static func ipv4Octets(_ address: UInt32) -> (UInt8, UInt8, UInt8, UInt8) {
        (
            UInt8((address >> 24) & 0xFF),
            UInt8((address >> 16) & 0xFF),
            UInt8((address >> 8) & 0xFF),
            UInt8(address & 0xFF)
        )
    }

    /// The IPv4 address embedded in an IPv4-mapped (`::ffff:0:0/96`) or
    /// IPv4-compatible (`::a.b.c.d`) IPv6 literal, or nil when `bytes` is an
    /// ordinary IPv6 address.
    ///
    /// `::` (unspecified) and `::1` (loopback) are deliberately NOT treated as
    /// compatible-form wrappers — they are IPv6 addresses in their own right and
    /// are answered by the IPv6 table, which is where their meaning is written
    /// down.
    static func unwrappedIPv4(fromIPv6 bytes: [UInt8]) -> UInt32? {
        guard bytes.count == 16 else { return nil }
        let leadingTenAreZero = bytes[0..<10].allSatisfy { $0 == 0 }
        guard leadingTenAreZero else { return nil }
        let tail = (UInt32(bytes[12]) << 24) | (UInt32(bytes[13]) << 16)
            | (UInt32(bytes[14]) << 8) | UInt32(bytes[15])
        // IPv4-MAPPED: `::ffff:a.b.c.d`.
        if bytes[10] == 0xFF, bytes[11] == 0xFF { return tail }
        // IPv4-COMPATIBLE: `::a.b.c.d`. Deprecated, but unwrapping is the
        // conservative direction — `::192.168.1.1` reaches a private host.
        if bytes[10] == 0, bytes[11] == 0, tail != 0, tail != 1 { return tail }
        return nil
    }

    // MARK: - Range tables

    /// The IPv4 verdict. Every arm RETURNS: a string that parsed as IPv4 is
    /// never retried as a hostname.
    private static func classifyIPv4(_ address: UInt32) -> Classification {
        let (o0, o1, _, _) = ipv4Octets(address)
        switch (o0, o1) {
        // "This network" 0.0.0.0/8. `http://0/` reaches THIS host on Darwin —
        // which is exactly why it is a classic SSRF bypass string. Unmeasured
        // against ATS, not confined by the kernel the way 127/8 is, and no
        // user types it for a real server (loopback users have `localhost` /
        // `127.0.0.1`). Refused, per the header's unmeasured rule.
        case (0, _):
            return .remote
        case (10, _):
            return .local
        // The whole /8, not just 127.0.0.1 — unmeasured beyond `.0.0.1`, but
        // the kernel routes all of 127/8 to `lo0`, so a wrong prediction here
        // cannot put a byte on a wire (the header's kernel-confined carve-out).
        case (127, _):
            return .local
        case (169, 254):
            return .local
        case (172, 16...31):
            return .local
        case (192, 168):
            return .local
        // CGNAT 100.64.0.0/10 — the range an overlay VPN (Tailscale) hands out.
        // ITS OWN ARM, not a fall-through, so the measurement can sit beside it:
        // -1022 over plain http under the no-key control AND under
        // `NSAllowsLocalNetworking = YES`. Deliberate and measured, not an
        // oversight; a tailnet gateway must use https.
        case (100, 64...127):
            return .remote
        default:
            return .remote
        }
    }

    /// The IPv6 verdict, BYTE-EXACT throughout — never a text prefix, because
    /// `fe8::1` parses to `0fe8:…` and is not link-local.
    ///
    /// Reached only for addresses that are not IPv4-mapped or -compatible;
    /// `classify(_:)` unwraps those first.
    private static func classifyIPv6(_ bytes: [UInt8]) -> Classification {
        guard bytes.count == 16 else { return .remote }
        // Unspecified `::` — the v6 twin of 0.0.0.0, refused with it: never
        // measured against ATS, and no user types it for a real server.
        if bytes.allSatisfy({ $0 == 0 }) { return .remote }
        // Loopback `::1`.
        if bytes[0..<15].allSatisfy({ $0 == 0 }), bytes[15] == 1 { return .local }
        // Unique local address `fc00::/7`.
        if bytes[0] & 0xFE == 0xFC { return .local }
        // Link-local `fe80::/10` — confined to the link by definition, and its
        // IPv4 twin 169.254/16 was measured permitted (the header's
        // kernel-confined carve-out).
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return .local }
        // Deprecated site-local `fec0::/10`. Unmeasured against ATS, deprecated
        // since 2004 (RFC 3879), and — unlike link-local — routable beyond the
        // link, so the credential path refuses it (the header's unmeasured
        // rule).
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0xC0 { return .remote }
        // Everything else, explicitly including every global-unicast address and
        // NAT64 `64:ff9b::/96`.
        return .remote
    }

    /// The hostname verdict — reached only when nothing above parsed as a
    /// numeric literal. Decided by EXACT LABEL comparison, never by scanning for
    /// an IP-shaped substring, which is what keeps `192.168.1.1.evil.com` on the
    /// right side of the line.
    private static func classifyHostname(_ host: String) -> Classification {
        if host == "localhost" { return .local }
        // mDNS / Bonjour. MEASURED permitted over plain http.
        if host == "local" || host.hasSuffix(".local") { return .local }
        // EVERYTHING ELSE — two families, one verdict, refused for different
        // reasons:
        //
        //   • A DOTTED NAME. `gateway.myhomelab.com`, `nas.home.arpa`,
        //     `ollama.lan`, `box.internal`, `192.168.1.50.nip.io`,
        //     `192.168.1.1.evil.com` and every split-horizon name pointing at
        //     a LAN box. MEASURED: the platform refuses a dotted name over
        //     plain http even when it resolves into RFC1918, while the IP
        //     literal for the identical destination succeeds.
        //   • A SINGLE LABEL, rooted or not. `nas`, `ollama`, `uz`, `uz.`.
        //     Real one-label TLDs answer at the public root (`dig +short A uz.`
        //     → 91.212.89.8, measured), so a resolver falling through its
        //     search domains could carry the bearer token in cleartext to a
        //     public host — and an unresolvable label dead-ends at -1003
        //     anyway, so nothing that worked is lost. The refusal copy names
        //     the two working spellings of the same machine: its IP literal,
        //     or its `.local` name.
        return .remote
    }
}
