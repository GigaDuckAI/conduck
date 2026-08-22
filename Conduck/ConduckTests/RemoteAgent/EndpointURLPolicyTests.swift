// SPDX-License-Identifier: Apache-2.0

// Conduck
// EndpointURLPolicyTests.swift
//
// Covers `EndpointURLPolicy` — the ONE admissibility rule for every user-
// configured endpoint URL Conduck persists (gateway, agent file server, custom
// voice endpoint). All three dual-write verbatim into App-Group UserDefaults
// AND iCloud KVS, so this is a storage-privacy rule, not just input hygiene.
//
// The `Rejection` PRECEDENCE is pinned here because `PairingPayload` maps BOTH
// scheme verdicts (`.notHTTPS`, `.insecureRemoteHost`) onto `.insecureURL` and
// the other two onto `.malformed`; that user-facing split only stays meaningful
// while the order holds.
//
// The policy now admits plain `http` toward a host only the local network can
// reach — the classifier behind that is `LocalNetworkHost`, and its own suite
// owns the address-shape cases. What is pinned HERE is the POLICY: which
// rejection fires, in which order, and that userinfo is still refused on both
// schemes.
//
// Test URLs are synthetic — the "passwords" below are literals, never secrets.

import XCTest
@testable import Conduck

final class EndpointURLPolicyTests: XCTestCase {

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            XCTFail("Fixture must parse as a URL: \(string)")
            return URL(string: "https://unreachable.invalid")!
        }
        return url
    }

    // MARK: - Admissible

    func testOrdinaryHTTPSURLIsAdmissible() {
        XCTAssertNil(EndpointURLPolicy.rejection(for: url("https://gw.example.com")))
        XCTAssertNil(EndpointURLPolicy.rejection(for: url("https://gw.example.com:18789/agent")))
        XCTAssertNil(EndpointURLPolicy.rejection(for: url("https://gw.example.ts.net")))
        XCTAssertTrue(EndpointURLPolicy.isAdmissible(url("https://gw.example.com")))
    }

    func testBracketedIPv6LiteralIsAdmissible() {
        XCTAssertNil(EndpointURLPolicy.rejection(for: url("https://[2001:db8::1]:8443")),
                     "An IPv6 literal is a legitimate self-hoster address.")
    }

    func testAtSignInPathIsNotUserinfo() {
        XCTAssertFalse(EndpointURLPolicy.carriesUserinfo(url("https://gw.example.com/agents/a@b")),
                       "The check must PARSE, not scan for a literal '@' — an '@' in the path is ordinary.")
        XCTAssertNil(EndpointURLPolicy.rejection(for: url("https://gw.example.com/agents/a@b")))
    }

    // MARK: - Temporary Cloudflare addresses

    func testCloudflareQuickTunnelDetectionReadsTheParsedHost() {
        XCTAssertTrue(EndpointURLPolicy.isCloudflareQuickTunnelURLString(
            "https://brisk-lantern-quarry-motion.trycloudflare.com"
        ))
        XCTAssertTrue(EndpointURLPolicy.isCloudflareQuickTunnelURLString(
            "https://TRYCloudflare.com:443/path"
        ))
    }

    func testCloudflareQuickTunnelDetectionRejectsLookAlikes() {
        for value in [
            "https://nottrycloudflare.com",
            "https://trycloudflare.com.example.org",
            "https://example.org/trycloudflare.com",
            "not a url"
        ] {
            XCTAssertFalse(EndpointURLPolicy.isCloudflareQuickTunnelURLString(value), value)
        }
    }

    // MARK: - Userinfo

    func testUserAndPasswordIsRejected() {
        XCTAssertEqual(EndpointURLPolicy.rejection(for: url("https://u:p@gw.example.com")),
                       .carriesUserinfo)
        XCTAssertTrue(EndpointURLPolicy.carriesUserinfo(url("https://u:p@gw.example.com")))
    }

    func testBareUsernameIsStillUserinfo() {
        XCTAssertEqual(EndpointURLPolicy.rejection(for: url("https://admin@gw.example.com")),
                       .carriesUserinfo,
                       "No password is needed: a lone user@ is still a credential-shaped segment in a synced string, and it still makes the apparent host differ from the real one.")
    }

    func testUserinfoShapedLikeAHostnameIsRejected() {
        // The deception shape: connects to evil.example.com, reads as the
        // trusted host wherever the string is truncated.
        let hostile = url("https://gw.trusted.example@evil.example.com")
        XCTAssertEqual(hostile.host, "evil.example.com",
                       "Foundation resolves the REAL host — userinfo grants no new destination, only a misleading display.")
        XCTAssertEqual(EndpointURLPolicy.rejection(for: hostile), .carriesUserinfo)
    }

    func testEmptyPasswordAfterColonIsStillUserinfo() {
        XCTAssertEqual(EndpointURLPolicy.rejection(for: url("https://admin:@gw.example.com")),
                       .carriesUserinfo)
    }

    // MARK: - Host

    func testHostlessURLsAreRejected() {
        // Both of these PARSE — that is the trap. A hostless URL persisted as
        // configuration reports itself as set up and fails at the TLS layer.
        XCTAssertEqual(EndpointURLPolicy.rejection(for: url("https://")), .noHost)
        XCTAssertEqual(EndpointURLPolicy.rejection(for: url("https:///v1")), .noHost)
    }

    func testHostCheckReadsURLHostNotURLComponentsHost() {
        // `URLComponents.host` is Optional("") for these, so a `!= nil` test
        // would pass them. This assertion exists so a refactor to
        // `URLComponents` fails loudly rather than silently reopening the hole.
        let hostless = url("https:///v1")
        XCTAssertNil(hostless.host)
        XCTAssertEqual(URLComponents(url: hostless, resolvingAgainstBaseURL: false)?.host, "",
                       "If Foundation ever changes this, the policy's host check must be re-verified.")
        XCTAssertFalse(EndpointURLPolicy.isAdmissible(hostless))
    }

    // MARK: - Scheme

    func testNonHTTPSSchemesAreRejected() {
        // `http` toward a DOTTED NAME is now named for the defect that is
        // actually true of it: iOS will refuse it, and the copy can say so.
        XCTAssertEqual(EndpointURLPolicy.rejection(for: url("http://gw.example.com")), .insecureRemoteHost)
        // Everything that is neither https nor http keeps the old verdict.
        XCTAssertEqual(EndpointURLPolicy.rejection(for: url("ftp://gw.example.com")), .notHTTPS)
        XCTAssertEqual(EndpointURLPolicy.rejection(for: url("ws://gw.example.com")), .notHTTPS)
        XCTAssertFalse(EndpointURLPolicy.isAdmissible(url("file:///etc/passwd")),
                       "A local-file URL is inadmissible whichever rule catches it first (it has no host AND no https scheme).")
    }

    /// The carve-out itself: Ollama on a home LAN, a Mac by Bonjour name,
    /// loopback, and an IPv6 ULA all import and save.
    func testPlainHTTPToLocalHostIsAdmissible() {
        for value in [
            "http://192.168.1.10:11434",
            "http://10.0.0.5:11434",
            "http://172.16.4.4:8080",
            "http://127.0.0.1:11434",
            "http://[fd00::1]:8080",
            "http://mac-mini.local:11434"
        ] {
            XCTAssertNil(EndpointURLPolicy.rejection(for: url(value)), value)
            XCTAssertTrue(EndpointURLPolicy.isAdmissible(url(value)), value)
        }
    }

    /// The refusals, all of which iOS would answer -1022 to. The nip.io row is
    /// the measured one: the IP literal for that identical destination is
    /// admitted, and the NAME for it is not.
    func testPlainHTTPToARemoteHostIsRefused() {
        for value in [
            "http://gateway.myhomelab.com",
            "http://192.168.1.50.nip.io:8899",
            "http://192.168.1.1.evil.com",
            "http://nas.home.arpa",
            "http://box.lan",
            "http://100.64.0.1:11434",
            "http://8.8.8.8",
            "http://010.1.1.1",
            // Refused-when-unmeasured: a bare label can resolve publicly
            // (`uz` is a real one-label TLD), and 0.0.0.0/8 + site-local
            // fec0::/10 were never measured — the classifier's header rule.
            "http://ollama:11434",
            "http://nas",
            "http://uz",
            "http://0.0.0.0",
            "http://[fec0::1]:8080"
        ] {
            XCTAssertEqual(EndpointURLPolicy.rejection(for: url(value)), .insecureRemoteHost, value)
        }
        XCTAssertNil(EndpointURLPolicy.rejection(for: url("http://192.168.1.50:8899")),
                     "The IP literal for the same destination IS admitted — that asymmetry is the platform's, and it is the whole reason the classifier exists.")
    }

    /// Requirement 4, and the case where the fall-through actually matters:
    /// a LOCAL http host passes the scheme guard and then still meets the
    /// userinfo rule.
    func testUserinfoIsStillRefusedOnALocalHTTPHost() {
        XCTAssertEqual(EndpointURLPolicy.rejection(for: url("http://u:p@192.168.1.10")),
                       .carriesUserinfo)
        XCTAssertEqual(EndpointURLPolicy.rejection(for: url("http://admin@192.168.1.10")),
                       .carriesUserinfo)
        XCTAssertFalse(EndpointURLPolicy.isAdmissible(url("http://u:p@mac-mini.local")))
    }

    /// `http://192.168.1.1@evil.com` is a REMOTE host wearing a private-looking
    /// costume. It is refused — the point of the test is that it is refused, and
    /// that the case it reports is a scheme verdict, which is the deliberate
    /// naming documented on `rejection(for:)`.
    func testUserinfoSpoofOfALocalHostIsRefused() {
        let hostile = url("http://192.168.1.1@evil.com")
        XCTAssertEqual(hostile.host, "evil.com",
                       "Foundation resolves the REAL host; the private-looking segment is userinfo.")
        XCTAssertFalse(EndpointURLPolicy.isAdmissible(hostile))
        XCTAssertEqual(EndpointURLPolicy.rejection(for: hostile), .insecureRemoteHost,
                       "Named for the defect that is true of it whichever way you look: plain http toward a remote host.")
    }

    // MARK: - The plain-http warning trigger

    func testIsAdmittedPlainHTTPURLStringGatesTheWarning() {
        XCTAssertTrue(EndpointURLPolicy.isAdmittedPlainHTTPURLString("http://192.168.1.10:11434"))
        XCTAssertTrue(EndpointURLPolicy.isAdmittedPlainHTTPURLString("HTTP://mac-mini.local"))
        // https never warns — there is nothing unencrypted to warn about.
        XCTAssertFalse(EndpointURLPolicy.isAdmittedPlainHTTPURLString("https://192.168.1.10:11434"))
        // A REFUSED http URL never warns either: the user is being stopped, and
        // pairing a refusal with a warning is how people learn to skim refusals.
        XCTAssertFalse(EndpointURLPolicy.isAdmittedPlainHTTPURLString("http://gw.example.com"))
        XCTAssertFalse(EndpointURLPolicy.isAdmittedPlainHTTPURLString("http://u:p@192.168.1.10"))
        XCTAssertFalse(EndpointURLPolicy.isAdmittedPlainHTTPURLString(""))
        XCTAssertFalse(EndpointURLPolicy.isAdmittedPlainHTTPURLString("not a url at all"))
        XCTAssertFalse(EndpointURLPolicy.isAdmittedPlainHTTPURLString("192.168.1.10:11434"),
                       "Schemeless — Foundation reads the host as the scheme, so there is no http URL here.")
    }

    // MARK: - Pin interaction

    func testPinCannotApplyToPlainHTTP() {
        XCTAssertTrue(EndpointURLPolicy.pinCannotApply(to: url("http://192.168.1.10:11434")),
                      "An ADMITTED plain-http address still hands over no certificate.")
        XCTAssertTrue(EndpointURLPolicy.pinCannotApply(to: url("http://gw.example.com")),
                      "A REFUSED one likewise — the predicate is about the scheme, not admissibility.")
        XCTAssertTrue(EndpointURLPolicy.pinCannotApply(to: url("HTTP://192.168.1.10")))
        XCTAssertFalse(EndpointURLPolicy.pinCannotApply(to: url("https://gw.example.com")))
    }

    func testUppercaseSchemeIsAccepted() {
        XCTAssertNil(EndpointURLPolicy.rejection(for: url("HTTPS://gw.example.com")),
                     "Scheme comparison is case-insensitive — a pasted HTTPS:// is the same URL.")
    }

    // MARK: - Precedence (load-bearing for the parser's error taxonomy)

    func testNoHostOutranksNotHTTPS() {
        XCTAssertEqual(EndpointURLPolicy.rejection(for: url("http:///v1")), .noHost,
                       "`PairingPayload` reports a hostless URL as .malformed, not .insecureURL — the precedence is what makes that true.")
    }

    func testSchemeVerdictOutranksUserinfo() {
        XCTAssertEqual(EndpointURLPolicy.rejection(for: url("http://u:p@gw.example.com")),
                       .insecureRemoteHost,
                       "The RANK is unchanged — only WHICH same-rank scheme case fires. Reordering userinfo above it would flip this string from .insecureURL to .malformed in the pairing UI.")
        XCTAssertEqual(EndpointURLPolicy.rejection(for: url("ftp://u:p@gw.example.com")), .notHTTPS)
    }

    /// `noHost` still outranks the scheme verdict — re-pinned against the new
    /// arm, because `PairingPayload` reports a hostless URL as `.malformed`.
    func testNoHostStillOutranksTheSchemeVerdict() {
        XCTAssertEqual(EndpointURLPolicy.rejection(for: url("http:///v1")), .noHost)
        XCTAssertEqual(EndpointURLPolicy.rejection(for: url("http://")), .noHost)
    }

    // MARK: - Stored-string convenience (the storage read fence)

    func testAdmissibleURLFromStoredString() {
        XCTAssertEqual(EndpointURLPolicy.admissibleURL(from: "https://gw.example.com")?.absoluteString,
                       "https://gw.example.com")
    }

    /// The storage read fence moves with the policy — a stored local-http URL
    /// now resolves, and a stored remote-http one still does not.
    func testAdmissibleURLFromStoredStringAcceptsLocalHTTPAndRefusesRemote() {
        XCTAssertEqual(EndpointURLPolicy.admissibleURL(from: "http://192.168.1.10:11434")?.absoluteString,
                       "http://192.168.1.10:11434")
        XCTAssertEqual(EndpointURLPolicy.admissibleURL(from: "http://mac-mini.local:11434")?.absoluteString,
                       "http://mac-mini.local:11434")
        XCTAssertNil(EndpointURLPolicy.admissibleURL(from: "http://gateway.myhomelab.com"))
        XCTAssertNil(EndpointURLPolicy.admissibleURL(from: "http://100.64.0.1:11434"))
    }

    func testAdmissibleURLRejectsContaminatedOrAbsentStoredStrings() {
        XCTAssertNil(EndpointURLPolicy.admissibleURL(from: nil))
        XCTAssertNil(EndpointURLPolicy.admissibleURL(from: ""))
        XCTAssertNil(EndpointURLPolicy.admissibleURL(from: "https://u:p@gw.example.com"),
                     "A value written before this policy — or synced in by a peer on an older build — must never resolve into a URL the app will request.")
        XCTAssertNil(EndpointURLPolicy.admissibleURL(from: "http://gw.example.com"))
        XCTAssertNil(EndpointURLPolicy.admissibleURL(from: "http://192.168.1.50.nip.io"),
                     "A dotted name that resolves into RFC1918 is exactly what iOS refuses, so the storage fence must refuse it too.")
        XCTAssertNil(EndpointURLPolicy.admissibleURL(from: "https://"))
        XCTAssertNil(EndpointURLPolicy.admissibleURL(from: "not a url at all"))
    }
}

/// The editor's inline `.invalid` copy must NAME the reason. A user who typed a
/// password believes they configured auth; a generic "enter a valid URL" leaves
/// them re-typing the same string. Each derivation is the single source for both
/// Save and Test, so these also pin that the two can't tell different stories.
@MainActor
final class EndpointURLRejectionCopyTests: XCTestCase {

    func testGatewayUserinfoGetsItsOwnMessage() {
        let userinfo = SettingsViewModel.remoteAgentURLRejectionMessage("https://u:p@gw.example.com")
        let generic = SettingsViewModel.remoteAgentURLRejectionMessage("gw.example.com")
        XCTAssertNotEqual(userinfo, generic,
                          "A userinfo URL must not collapse into the generic https:// prompt — the user cannot act on that.")
        XCTAssertFalse(userinfo.contains("u:p"),
                       "The message must never echo the credential back into the UI.")
    }

    func testGatewayHostlessGetsItsOwnMessage() {
        let hostless = SettingsViewModel.remoteAgentURLRejectionMessage("https:///v1")
        let generic = SettingsViewModel.remoteAgentURLRejectionMessage("gw.example.com")
        let userinfo = SettingsViewModel.remoteAgentURLRejectionMessage("https://u:p@gw.example.com")
        XCTAssertNotEqual(hostless, generic)
        XCTAssertNotEqual(hostless, userinfo)
    }

    /// An EMPTY field is "not filled in", not "missing a host" — it must read as
    /// the generic prompt. (`URL(string: "")` is hostless, so routing the empty
    /// string through the policy would surface the wrong copy.)
    func testEmptyGatewayFieldGetsTheGenericPrompt() {
        XCTAssertEqual(SettingsViewModel.remoteAgentURLRejectionMessage(""),
                       SettingsViewModel.remoteAgentURLRejectionMessage("gw.example.com"),
                       "An empty field must not be told its host name is missing — both land on the generic https:// prompt.")
        XCTAssertNotEqual(SettingsViewModel.remoteAgentURLRejectionMessage(""),
                          SettingsViewModel.remoteAgentURLRejectionMessage("http://gw.example.com"),
                          "An EXPLICIT http:// is unambiguous about what the user meant, so it must NOT collapse into the generic prompt.")
    }

    /// THE COMMONEST TYPO. A pasted host with no scheme parses with `scheme`
    /// AND `host` both nil (Foundation makes the whole string the path), so
    /// `EndpointURLPolicy` answers `.noHost` — and the `.noHost` copy would tell
    /// a user who typed nothing BUT a host name that their host name is missing.
    /// The policy's precedence is load-bearing elsewhere, so the copy layer is
    /// where this is corrected; these pin that it stays corrected.
    func testSchemelessGatewayAddressGetsTheHTTPSPrompt() {
        let generic = SettingsViewModel.remoteAgentURLRejectionMessage("")
        for typo in ["gw.example.com", "gw.example.com/v1", "not a url at all"] {
            XCTAssertEqual(SettingsViewModel.remoteAgentURLRejectionMessage(typo), generic,
                           "\(typo) is missing its SCHEME, not its host — the message must name the https:// it lacks.")
        }
    }

    /// `gw.example.com:18789` — a self-hoster's host:port with no scheme — is
    /// the same defect wearing a different parse: Foundation reads the HOST as
    /// the scheme and leaves `host` nil, so the policy again answers `.noHost`.
    func testSchemelessHostPortGetsTheHTTPSPrompt() {
        let hostPort = "gw.example.com:18789"
        XCTAssertNil(URL(string: hostPort)?.host,
                     "Precondition: Foundation parses this as scheme `gw.example.com`, path `18789`.")
        XCTAssertEqual(SettingsViewModel.remoteAgentURLRejectionMessage(hostPort),
                       SettingsViewModel.remoteAgentURLRejectionMessage(""),
                       "A host:port with no scheme must be told to add https://, not that its host is missing.")
    }

    /// The `.noHost` copy still has to fire for what it was written for: a
    /// string that IS an https URL and genuinely has no host.
    func testGenuinelyHostlessHTTPSURLKeepsTheHostMessage() {
        let generic = SettingsViewModel.remoteAgentURLRejectionMessage("gw.example.com")
        for hostless in ["https://", "https:///v1", "HTTPS:///v1"] {
            XCTAssertNotEqual(SettingsViewModel.remoteAgentURLRejectionMessage(hostless), generic,
                              "\(hostless) really is an https URL with no host — that copy must survive.")
        }
    }

    func testAllThreeFieldsAgreeOnTheSchemelessDiagnosis() {
        XCTAssertEqual(SettingsViewModel.customSTTURLRejectionMessage("voice.example.com"),
                       SettingsViewModel.customSTTURLRejectionMessage(""),
                       "The custom voice endpoint gets the same correction — one diagnosis for all three fields.")
    }

    /// The `.insecureRemoteHost` copy is its own message, distinct from every
    /// other arm, and IDENTICAL across the three fields — it names neither a
    /// host nor a home for the secret, so a per-field spelling would be three
    /// chances to drift with nothing gained.
    func testPlainHTTPRemoteGetsItsOwnMessage() {
        let gateway = SettingsViewModel.remoteAgentURLRejectionMessage("http://gw.example.com")
        let file = SettingsViewModel.fileServerURLRejectionMessage("http://files.example.com")
        let voice = SettingsViewModel.customSTTURLRejectionMessage("http://voice.example.com")

        XCTAssertEqual(gateway, file)
        XCTAssertEqual(gateway, voice)

        XCTAssertNotEqual(gateway, SettingsViewModel.remoteAgentURLRejectionMessage(""),
                          "must not collapse into the generic prompt")
        XCTAssertNotEqual(gateway, SettingsViewModel.remoteAgentURLRejectionMessage("https:///v1"),
                          "must not collapse into the .noHost copy")
        XCTAssertNotEqual(gateway, SettingsViewModel.remoteAgentURLRejectionMessage("https://u:p@gw.example.com"),
                          "must not collapse into the userinfo copy")

        // Names the platform, not the app, and names the fixes. "Apple", not
        // "iOS" — the same string renders on the Mac.
        XCTAssertTrue(gateway.contains("Apple"), "It must name Apple as the refuser — the app did not choose this.")
        XCTAssertTrue(gateway.contains("https://"), "It must name the encryption fix.")
        XCTAssertTrue(gateway.lowercased().contains("ip address"), "It must name the IP-literal fix.")
        for jargon in ["ATS", "App Transport Security", "-1022", "RFC1918", "DNS"] {
            XCTAssertFalse(gateway.contains(jargon), "No jargon: \(jargon)")
        }
    }

    /// An ADMITTED plain-http address produces no rejection copy at all — it is
    /// accepted, and the risk sentence belongs on the warning surface instead.
    func testAdmittedPlainHTTPProducesNoRejection() {
        XCTAssertNil(EndpointURLPolicy.rejection(for: URL(string: "http://192.168.1.10:11434")!))
    }

    /// The schemeless correction must survive the new arm — this is the
    /// commonest typo and it must keep landing on "include https://".
    func testSchemelessTypoStillGetsTheHTTPSPrompt() {
        let generic = SettingsViewModel.remoteAgentURLRejectionMessage("")
        XCTAssertEqual(SettingsViewModel.remoteAgentURLRejectionMessage("gw.example.com"), generic)
        XCTAssertEqual(SettingsViewModel.remoteAgentURLRejectionMessage("gw.example.com:18789"), generic)
        XCTAssertEqual(SettingsViewModel.remoteAgentURLRejectionMessage("192.168.1.10:11434"), generic,
                       "A schemeless LOCAL address is still a missing scheme, not an accepted plain-http URL.")
    }

    func testPinOnPlainHTTPMessageIsItsOwnString() {
        let pinMessage = SettingsViewModel.pinOnPlainHTTPMessage
        XCTAssertNotEqual(pinMessage, SettingsViewModel.plainHTTPRemoteMessage)
        XCTAssertTrue(pinMessage.contains("http://"))
        XCTAssertTrue(pinMessage.contains("https://"), "It must name the remedy that keeps the pin.")
    }

    func testCustomSTTMessagesFollowTheSameShape() {
        let userinfo = SettingsViewModel.customSTTURLRejectionMessage("https://u:p@voice.example.com")
        let hostless = SettingsViewModel.customSTTURLRejectionMessage("https://")
        let generic = SettingsViewModel.customSTTURLRejectionMessage("voice.example.com")
        XCTAssertNotEqual(userinfo, generic)
        XCTAssertNotEqual(hostless, generic)
        XCTAssertEqual(SettingsViewModel.customSTTURLRejectionMessage(""), generic)
    }
}
