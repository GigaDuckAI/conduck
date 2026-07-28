// SPDX-License-Identifier: Apache-2.0

// Conduck
// PairingTrustDecisionTests.swift
//
// The inbound-pairing trust table (`PairingTrustDecision.decide(_:)`), which is
// pure by construction so every row is exercised without a TLS fixture. The
// live-handshake counterpart lives in `RemoteAgentLiveTLSTrustTests`.
//
// The two assertions that carry the most weight:
//   - an untrusted certificate BLOCKS, and that block is the only trust refusal
//     the type system can express — there is no arm the app can proceed past;
//   - a transient failure is NEVER a trust verdict, so a cold tunnel on a
//     perfectly valid certificate still reads as "could not reach".

import XCTest
@testable import Conduck

final class PairingTrustDecisionTests: XCTestCase {

    private func decide(
        completed: Bool,
        transport: RemoteAgentTrustEvaluator.TransportErrorClass? = nil
    ) -> PairingTrustVerdict {
        PairingTrustDecision.decide(
            PairingTrustProbeSignals(
                requestCompleted: completed,
                transportClass: transport
            )
        )
    }

    // MARK: - The handshake was accepted

    func testCompletedHandshakeUsesOrdinaryTrust() {
        XCTAssertEqual(
            decide(completed: true),
            .useOrdinaryTrust,
            "The overwhelmingly common case (Tailscale Serve / Funnel / Cloudflare Tunnel / Let's Encrypt): the system accepted the chain, which is the whole question."
        )
    }

    func testCompletedHandshakeIgnoresAStaleTransportClass() {
        // `requestCompleted` is authoritative; a leftover classification must not
        // override a request that actually came back.
        XCTAssertEqual(
            decide(completed: true, transport: .untrustedCert),
            .useOrdinaryTrust,
            "A completed request is the authoritative pass signal and outranks any transport classification."
        )
    }

    // MARK: - The system rejected the certificate

    func testUntrustedCertificateIsBlocked() {
        XCTAssertEqual(
            decide(completed: false, transport: .untrustedCert),
            .blocked(.certificateNotPubliclyTrusted),
            """
            App Transport Security lets an app tighten trust evaluation, never loosen it, so no \
            pin could rescue this chain. The refusal is terminal and the remedy is on the server.
            """
        )
    }

    /// `PairingTrustBlock` is exhaustive, and the point of this design is that it
    /// has exactly one arm. A second one would mean the app had grown a
    /// certificate refusal it reasons about differently — which is the shape that
    /// carried first-contact trust in the first place.
    func testTheOnlyTrustRefusalIsTheUntrustedCertificate() {
        guard case .blocked(let block) = decide(
            completed: false, transport: .untrustedCert
        ) else {
            return XCTFail("Expected a block")
        }
        switch block {
        case .certificateNotPubliclyTrusted:
            break   // The only arm — the compiler keeps this true.
        }
    }

    // MARK: - Transient failures are never trust verdicts

    func testTimeoutIsUnreachable() {
        XCTAssertEqual(
            decide(completed: false, transport: .timeout),
            .unreachable(.timeout),
            "A timeout says nothing about the certificate."
        )
    }

    func testUnreachableIsUnreachable() {
        XCTAssertEqual(
            decide(completed: false, transport: .unreachable),
            .unreachable(.unreachable),
            """
            Regression guard for the recorded incident: a cold tunnel produced a generic \
            `.secureConnectionFailed` on a perfectly valid certificate. It must resolve to \
            "could not reach", never to a statement about trust.
            """
        )
    }

    func testCancelledIsUnreachable() {
        XCTAssertEqual(
            decide(completed: false, transport: .cancelled),
            .unreachable(.cancelled),
            "A benign cancellation must not be reported as a certificate outcome."
        )
    }

    func testNonURLErrorFailureIsUnreachable() {
        XCTAssertEqual(
            decide(completed: false, transport: nil),
            .unreachable(.unreachable),
            "An unclassifiable failure is conservatively unreachable — never a trust verdict."
        )
    }

    /// The probe runs unpinned, so the evaluator has no pin to mismatch and this
    /// signal cannot arise. If it ever does it must not become a refusal the user
    /// has no way to act on: no pin was applied, so nothing was contradicted.
    func testCertMismatchSignalDegradesToUnreachable() {
        XCTAssertEqual(
            decide(completed: false, transport: .certMismatch),
            .unreachable(.certMismatch)
        )
    }
}
