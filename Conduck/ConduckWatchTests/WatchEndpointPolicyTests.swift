// SPDX-License-Identifier: Apache-2.0

// Conduck
// WatchEndpointPolicyTests.swift
//
// The wrist and the phone must give ONE answer about one server. A gateway URL
// reaches this Watch by three routes (a multi-gateway WCSession envelope, a
// legacy single envelope, and cold App-Group/KVS hydration), and
// `remoteAgentConfig(for:)` is the dispatch chokepoint all three funnel through
// — so that is where admissibility is enforced, and this is where it is pinned.
//
// It matters that these assertions exist HERE and not only phone-side: the Watch
// used to carry a hand-copied twin of the policy, justified by the rule being
// four lines long. The rule is no longer four lines — it turns on a byte-exact
// address classifier — and a second copy of that cannot stay in agreement by
// care. The Watch now compiles the canonical `EndpointURLPolicy`; these cases
// are what would fail if someone reintroduced a local copy that drifted.
//
// Auth is `.none` (keyless) throughout so the tuple resolves on the URL alone —
// the Keychain token slot needs an entitlement that an unsigned run does not
// have, and nothing here is about tokens.

import XCTest
@testable import ConduckWatch_Watch_App

@MainActor
final class WatchEndpointPolicyTests: XCTestCase {

    private let reader = WatchSettingsReader.shared

    /// Push ONE keyless gateway at `ref` and hand back whether the reader will
    /// route to it. Timestamps advance off the reader's own high-water mark
    /// because it is a process singleton shared by every test in the run.
    private func resolvedConfig(
        url: String,
        certFingerprintHex: String? = nil,
        ref: String = "openclaw"
    ) -> (url: URL, token: String, authScheme: RemoteAgentAuthScheme, cert: String?, model: String?)? {
        let ts = reader.lastRemoteAgentEnvelopeTimestamp + 1000
        let accepted = reader.updateRemoteAgents(multi: RemoteAgentMultiBroadcastEnvelope(
            backends: [
                RemoteAgentBroadcastEnvelope(
                    backendRef: ref,
                    url: URL(string: url)!,
                    name: nil,
                    model: nil,
                    colorID: nil,
                    monogram: nil,
                    token: nil,
                    authScheme: .none,
                    certFingerprintHex: certFingerprintHex,
                    activeSessionID: nil,
                    timestamp: ts
                )
            ],
            defaultBackendRef: ref,
            timestamp: ts,
            sessionPolicy: nil
        ))
        XCTAssertTrue(accepted, "Precondition: a strictly newer envelope must apply.")
        return reader.remoteAgentConfig(for: ref)
    }

    // MARK: - The carve-out

    /// Plain http toward an address only the local network can reach is
    /// admissible on the wrist too. If it were not, a self-hoster's LAN gateway
    /// would work on the phone and silently report "not configured" on the watch.
    func testPlainHTTPToALocalHostRoutes() {
        XCTAssertEqual(resolvedConfig(url: "http://192.168.1.10:11434")?.url.absoluteString,
                       "http://192.168.1.10:11434")
        XCTAssertEqual(resolvedConfig(url: "http://mac-mini.local:11434")?.url.absoluteString,
                       "http://mac-mini.local:11434")
        XCTAssertEqual(resolvedConfig(url: "http://[fd00::1]:11434")?.url.absoluteString,
                       "http://[fd00::1]:11434")
    }

    // MARK: - The refusals

    /// A dotted DNS name over plain http is refused — iOS would answer -1022,
    /// and the phone reports the same value as not configured.
    func testPlainHTTPToADottedNameIsRefused() {
        XCTAssertNil(resolvedConfig(url: "http://gateway.myhomelab.test:18789"))
        XCTAssertNil(resolvedConfig(url: "http://192.168.1.50.nip.io:8899"),
                     "A name that resolves INTO the private range is still a name — measured -1022.")
        XCTAssertNil(resolvedConfig(url: "http://100.64.0.1:11434"),
                     "CGNAT is outside the exemption, so a tailnet gateway must be https.")
    }

    /// Userinfo stays absolutely refused on BOTH schemes.
    func testUserinfoIsRefusedOnBothSchemes() {
        XCTAssertNil(resolvedConfig(url: "https://u:p@gw.example.test"))
        XCTAssertNil(resolvedConfig(url: "http://u:p@192.168.1.10"))
    }

    /// A saved fingerprint over a plain-http address can never be compared —
    /// nothing hands over a certificate. The wrist fails CLOSED rather than
    /// connecting with the pin silently dropped, which is the same answer the
    /// phone's `remoteAgentSnapshot` read fence gives.
    func testPinPairedWithPlainHTTPIsRefused() {
        let pin = String(repeating: "ab", count: 32)
        XCTAssertNil(resolvedConfig(url: "http://192.168.1.10:11434", certFingerprintHex: pin))
        // The fence is the PAIR: the same address with no pin routes, and the
        // same pin over https routes.
        XCTAssertNotNil(resolvedConfig(url: "http://192.168.1.10:11434"))
        XCTAssertEqual(resolvedConfig(url: "https://gw.example.test", certFingerprintHex: pin)?.cert, pin)
    }

    /// The ordinary case, so a failure above cannot be read as "the harness
    /// never routes anything".
    func testOrdinaryHTTPSRoutes() {
        XCTAssertEqual(resolvedConfig(url: "https://gw.example.test:18789")?.url.absoluteString,
                       "https://gw.example.test:18789")
    }
}
