// SPDX-License-Identifier: Apache-2.0

// Conduck
// EndpointURLPolicyTests.swift
//
// Covers `EndpointURLPolicy` — the ONE admissibility rule for every user-
// configured endpoint URL Conduck persists (gateway, agent file server, custom
// voice endpoint). All three dual-write verbatim into App-Group UserDefaults
// AND iCloud KVS, so this is a storage-privacy rule, not just input hygiene.
//
// The `Rejection` PRECEDENCE is pinned here because `PairingPayload` maps
// `.notHTTPS` onto `.insecureURL` and the other two onto `.malformed`; that
// user-facing split only stays meaningful while the order holds.
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
        XCTAssertEqual(EndpointURLPolicy.rejection(for: url("http://gw.example.com")), .notHTTPS)
        XCTAssertEqual(EndpointURLPolicy.rejection(for: url("ftp://gw.example.com")), .notHTTPS)
        XCTAssertFalse(EndpointURLPolicy.isAdmissible(url("file:///etc/passwd")),
                       "A local-file URL is inadmissible whichever rule catches it first (it has no host AND no https scheme).")
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

    func testNotHTTPSOutranksUserinfo() {
        XCTAssertEqual(EndpointURLPolicy.rejection(for: url("http://u:p@gw.example.com")), .notHTTPS,
                       "An unencrypted URL is named as such first — that is the more actionable message.")
    }

    // MARK: - Stored-string convenience (the storage read fence)

    func testAdmissibleURLFromStoredString() {
        XCTAssertEqual(EndpointURLPolicy.admissibleURL(from: "https://gw.example.com")?.absoluteString,
                       "https://gw.example.com")
    }

    func testAdmissibleURLRejectsContaminatedOrAbsentStoredStrings() {
        XCTAssertNil(EndpointURLPolicy.admissibleURL(from: nil))
        XCTAssertNil(EndpointURLPolicy.admissibleURL(from: ""))
        XCTAssertNil(EndpointURLPolicy.admissibleURL(from: "https://u:p@gw.example.com"),
                     "A value written before this policy — or synced in by a peer on an older build — must never resolve into a URL the app will request.")
        XCTAssertNil(EndpointURLPolicy.admissibleURL(from: "http://gw.example.com"))
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
        let generic = SettingsViewModel.remoteAgentURLRejectionMessage("http://gw.example.com")
        XCTAssertNotEqual(userinfo, generic,
                          "A userinfo URL must not collapse into the generic https:// prompt — the user cannot act on that.")
        XCTAssertFalse(userinfo.contains("u:p"),
                       "The message must never echo the credential back into the UI.")
    }

    func testGatewayHostlessGetsItsOwnMessage() {
        let hostless = SettingsViewModel.remoteAgentURLRejectionMessage("https:///v1")
        let generic = SettingsViewModel.remoteAgentURLRejectionMessage("http://gw.example.com")
        let userinfo = SettingsViewModel.remoteAgentURLRejectionMessage("https://u:p@gw.example.com")
        XCTAssertNotEqual(hostless, generic)
        XCTAssertNotEqual(hostless, userinfo)
    }

    /// An EMPTY field is "not filled in", not "missing a host" — it must read as
    /// the generic prompt. (`URL(string: "")` is hostless, so routing the empty
    /// string through the policy would surface the wrong copy.)
    func testEmptyGatewayFieldGetsTheGenericPrompt() {
        XCTAssertEqual(SettingsViewModel.remoteAgentURLRejectionMessage(""),
                       SettingsViewModel.remoteAgentURLRejectionMessage("http://gw.example.com"),
                       "An empty field must not be told its host name is missing.")
    }

    /// THE COMMONEST TYPO. A pasted host with no scheme parses with `scheme`
    /// AND `host` both nil (Foundation makes the whole string the path), so
    /// `EndpointURLPolicy` answers `.noHost` — and the `.noHost` copy would tell
    /// a user who typed nothing BUT a host name that their host name is missing.
    /// The policy's precedence is load-bearing elsewhere, so the copy layer is
    /// where this is corrected; these pin that it stays corrected.
    func testSchemelessGatewayAddressGetsTheHTTPSPrompt() {
        let generic = SettingsViewModel.remoteAgentURLRejectionMessage("http://gw.example.com")
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
                       SettingsViewModel.remoteAgentURLRejectionMessage("http://gw.example.com"),
                       "A host:port with no scheme must be told to add https://, not that its host is missing.")
    }

    /// The `.noHost` copy still has to fire for what it was written for: a
    /// string that IS an https URL and genuinely has no host.
    func testGenuinelyHostlessHTTPSURLKeepsTheHostMessage() {
        let generic = SettingsViewModel.remoteAgentURLRejectionMessage("http://gw.example.com")
        for hostless in ["https://", "https:///v1", "HTTPS:///v1"] {
            XCTAssertNotEqual(SettingsViewModel.remoteAgentURLRejectionMessage(hostless), generic,
                              "\(hostless) really is an https URL with no host — that copy must survive.")
        }
    }

    func testAllThreeFieldsAgreeOnTheSchemelessDiagnosis() {
        XCTAssertEqual(SettingsViewModel.customSTTURLRejectionMessage("voice.example.com"),
                       SettingsViewModel.customSTTURLRejectionMessage("http://voice.example.com"),
                       "The custom voice endpoint gets the same correction — one diagnosis for all three fields.")
    }

    func testCustomSTTMessagesFollowTheSameShape() {
        let userinfo = SettingsViewModel.customSTTURLRejectionMessage("https://u:p@voice.example.com")
        let hostless = SettingsViewModel.customSTTURLRejectionMessage("https://")
        let generic = SettingsViewModel.customSTTURLRejectionMessage("http://voice.example.com")
        XCTAssertNotEqual(userinfo, generic)
        XCTAssertNotEqual(hostless, generic)
        XCTAssertEqual(SettingsViewModel.customSTTURLRejectionMessage(""), generic)
    }
}
