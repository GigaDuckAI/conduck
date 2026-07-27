// SPDX-License-Identifier: Apache-2.0

// Conduck
// PairingTrustDecisionTests.swift
//
// The inbound-pairing trust matrix (`PairingTrustDecision.decide(_:)`), which is
// pure by construction so the whole table is exercised without a TLS fixture.
// The live-handshake counterpart lives in `RemoteAgentLiveTLSTrustTests`.
//
// The two assertions that carry the most weight:
//   - a MATCHING payload pin under ordinary trust must NOT install a pin;
//   - a MISMATCHING payload pin under ordinary trust must BLOCK (the enterprise
//     TLS-inspection row — the one a "trust passed, we're fine" rule waves through).

import XCTest
@testable import Conduck

final class PairingTrustDecisionTests: XCTestCase {

    // Two distinct, well-formed SPKI SHA-256 digests (64 lowercase hex chars).
    private let keyA = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"
    private let keyB = "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0"

    private func decide(
        payloadPin: String?,
        presented: String?,
        completed: Bool,
        transport: RemoteAgentTrustEvaluator.TransportErrorClass? = nil
    ) -> PairingTrustVerdict {
        PairingTrustDecision.decide(
            PairingTrustProbeSignals(
                payloadPinHex: payloadPin,
                presentedFingerprintHex: presented,
                requestCompleted: completed,
                transportClass: transport
            )
        )
    }

    // MARK: - Ordinary trust accepted the chain

    func testOrdinaryTrustWithNoClaimUsesOrdinaryTrust() {
        XCTAssertEqual(
            decide(payloadPin: nil, presented: keyA, completed: true),
            .useOrdinaryTrust,
            "The common case (Tailscale Funnel / Cloudflare Tunnel / Let's Encrypt): nothing claimed, system satisfied."
        )
    }

    func testOrdinaryTrustWithMatchingClaimDoesNotInstallAPin() {
        XCTAssertEqual(
            decide(payloadPin: keyA, presented: keyA, completed: true),
            .useOrdinaryTrust,
            """
            A matching claim under ordinary trust must resolve to ordinary trust and NOT \
            `.offerPinException` — retaining the pin would convert a working publicly-trusted \
            gateway into a pinned one that breaks on ordinary certificate renewal, and would \
            re-introduce pin-replaces-WebPKI for a lane that does not need it.
            """
        )
    }

    func testOrdinaryTrustWithMismatchingClaimIsBlocked() {
        XCTAssertEqual(
            decide(payloadPin: keyB, presented: keyA, completed: true),
            .blocked(.pinContradictsLiveServer),
            """
            THE motivating row. Under enterprise TLS inspection the middlebox root is installed \
            so ordinary trust PASSES, while the key on the wire is the middlebox's, not the one \
            the code names. Accepting here is the exact silent downgrade this matrix exists to stop.
            """
        )
    }

    func testOrdinaryTrustWithUnreadableKeyButAClaimIsBlocked() {
        XCTAssertEqual(
            decide(payloadPin: keyA, presented: nil, completed: true),
            .blocked(.unverifiablePin),
            "A claim that could not be checked against the wire must fail closed, never be installed unverified."
        )
    }

    func testOrdinaryTrustIgnoresAStaleTransportClass() {
        // `requestCompleted` is authoritative; a leftover classification must not
        // override a completed request.
        XCTAssertEqual(
            decide(payloadPin: nil, presented: keyA, completed: true, transport: .untrustedCert),
            .useOrdinaryTrust,
            "A completed request is the authoritative pass signal and outranks any transport classification."
        )
    }

    // MARK: - Ordinary trust rejected the certificate (the self-signed lane)

    func testUntrustedWithMatchingClaimOffersAnException() {
        XCTAssertEqual(
            decide(payloadPin: keyA, presented: keyA, completed: false, transport: .untrustedCert),
            .offerPinException(fingerprintHex: keyA),
            "Honest self-signed setup: the code names exactly the key on the wire. Offer — never auto-apply."
        )
    }

    func testUntrustedWithNoClaimIsBlocked() {
        XCTAssertEqual(
            decide(payloadPin: nil, presented: keyA, completed: false, transport: .untrustedCert),
            .blocked(.untrustedWithoutClaim),
            """
            The LOCKED v1 contract emits `certFP` whenever the transport is self-signed, so a \
            canonical self-signed code always carries one. Offering first-contact trust here would \
            let an attacker unlock a friendlier branch by DELETING a field.
            """
        )
    }

    /// The metamorphic property that motivates `untrustedWithoutClaim`: removing
    /// attacker-controlled input must never IMPROVE the verdict. Field omission is
    /// free for an attacker, so any branch reachable by deleting a field is a
    /// branch the attacker selects.
    func testDeletingTheClaimCannotSoftenTheVerdict() {
        let withMismatchedClaim = decide(
            payloadPin: keyB, presented: keyA, completed: false, transport: .untrustedCert)
        let withClaimDeleted = decide(
            payloadPin: nil, presented: keyA, completed: false, transport: .untrustedCert)

        XCTAssertEqual(withMismatchedClaim, .blocked(.untrustedAndPinMismatch))
        guard case .blocked = withClaimDeleted else {
            return XCTFail(
                """
                Deleting `certFP` turned \(withMismatchedClaim) into \(withClaimDeleted). \
                An attacker controls the whole payload, so a verdict reachable by omission is a \
                verdict the attacker chooses.
                """
            )
        }
    }

    // Deliberately NOT named "cannot soften": under ordinary trust, deleting the
    // claim DOES move blocked → useOrdinaryTrust. That is the one place the
    // metamorphic property above legitimately does not hold, and the assertion
    // below records why.
    func testDeletingTheClaimUnderOrdinaryTrustIsSafeAndWhy() {
        // Same property on the completed arm: a contradicting claim blocks, and
        // dropping it must not become a silent success with a DIFFERENT server
        // than the one the code described. Here it legitimately does resolve to
        // ordinary trust — which is safe only because nothing about the server is
        // then being asserted by the code at all, and WebPKI is fully in force.
        XCTAssertEqual(
            decide(payloadPin: keyB, presented: keyA, completed: true),
            .blocked(.pinContradictsLiveServer))
        XCTAssertEqual(
            decide(payloadPin: nil, presented: keyA, completed: true),
            .useOrdinaryTrust,
            """
            Dropping the claim under ORDINARY trust is not a downgrade: the chain, hostname and \
            expiry checks all still apply. This asymmetry with the untrusted arm is deliberate — \
            there, dropping the claim would remove the only check standing.
            """
        )
    }

    func testUntrustedWithMismatchingClaimIsBlocked() {
        XCTAssertEqual(
            decide(payloadPin: keyB, presented: keyA, completed: false, transport: .untrustedCert),
            .blocked(.untrustedAndPinMismatch),
            """
            Untrusted AND the code disagrees with the wire. Never offer one-tap trust: the user cannot \
            tell a re-issued cert from a substituted one, and the code already fails to vouch for what is presented.
            """
        )
    }

    func testUntrustedWithUnreadableKeyAndNoClaimIsBlocked() {
        XCTAssertEqual(
            decide(payloadPin: nil, presented: nil, completed: false, transport: .untrustedCert),
            .blocked(.untrustedWithoutPinnableKey),
            "Nothing pinnable was computed and nothing was claimed — there is no exception to offer."
        )
    }

    func testUntrustedWithUnreadableKeyButAClaimReportsUnverifiable() {
        XCTAssertEqual(
            decide(payloadPin: keyA, presented: nil, completed: false, transport: .untrustedCert),
            .blocked(.unverifiablePin),
            """
            The code DID make a claim; it simply could not be checked. Reporting \
            `untrustedWithoutPinnableKey` here would contradict that case's own definition and \
            send the user to the wrong remedy.
            """
        )
    }

    func testCompletedWithNoClaimAndUnreadableKeyUsesOrdinaryTrust() {
        XCTAssertEqual(
            decide(payloadPin: nil, presented: nil, completed: true),
            .useOrdinaryTrust,
            """
            An unreadable digest is absence of evidence, not evidence of a problem. With no claim \
            to check it against and ordinary trust satisfied, there is nothing to verify — this is \
            the Ed25519-gateway case, which WebPKI already covers.
            """
        )
    }

    // MARK: - Transient failures are never trust verdicts

    func testTimeoutIsUnreachableEvenWithAClaim() {
        XCTAssertEqual(
            decide(payloadPin: keyA, presented: nil, completed: false, transport: .timeout),
            .unreachable(.timeout),
            "A timeout says nothing about the certificate."
        )
    }

    func testUnreachableIsUnreachable() {
        XCTAssertEqual(
            decide(payloadPin: keyA, presented: nil, completed: false, transport: .unreachable),
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
            decide(payloadPin: keyA, presented: keyA, completed: false, transport: .cancelled),
            .unreachable(.cancelled),
            "A benign cancellation must not be reported as a certificate outcome."
        )
    }

    func testNonURLErrorFailureIsUnreachable() {
        XCTAssertEqual(
            decide(payloadPin: keyA, presented: keyA, completed: false, transport: nil),
            .unreachable(.unreachable),
            "An unclassifiable failure is conservatively unreachable — never a trust verdict."
        )
    }

    func testCertMismatchSignalBlocks() {
        // A pairing probe runs unpinned so this should not arise; if it ever
        // does, "the wire disagrees with the pin" is what it means.
        XCTAssertEqual(
            decide(payloadPin: keyA, presented: keyB, completed: false, transport: .certMismatch),
            .blocked(.pinContradictsLiveServer)
        )
    }

    // MARK: - "Connect anyway" override

    private func override(
        payloadPin: String?,
        presented: String?,
        completed: Bool,
        transport: RemoteAgentTrustEvaluator.TransportErrorClass? = nil
    ) -> PairingTrustOverride? {
        let signals = PairingTrustProbeSignals(
            payloadPinHex: payloadPin,
            presentedFingerprintHex: presented,
            requestCompleted: completed,
            transportClass: transport
        )
        return PairingTrustDecision.override(
            for: PairingTrustDecision.decide(signals), signals: signals)
    }

    func testNoOverrideIsOfferedWhenNothingWasBlocked() {
        // useOrdinaryTrust
        XCTAssertNil(override(payloadPin: nil, presented: keyA, completed: true))
        // offerPinException
        XCTAssertNil(override(payloadPin: keyA, presented: keyA, completed: false, transport: .untrustedCert))
        // unreachable
        XCTAssertNil(override(payloadPin: keyA, presented: nil, completed: false, transport: .timeout),
                     "Unreachable is not a refusal to override — there is nothing to overrule, and a retry is the remedy.")
    }

    func testContradictionUnderOrdinaryTrustCanProceedWithFullValidation() {
        XCTAssertEqual(
            override(payloadPin: keyB, presented: keyA, completed: true),
            .proceedUnderOrdinaryTrust,
            """
            The enterprise-TLS-inspection case, and the reason an override must exist: on a \
            corporate network this disagreement is permanent, so without a way past it those users \
            could never pair at all. Proceeding keeps chain, hostname and expiry validation intact.
            """
        )
    }

    func testUntrustedBlocksCanProceedByPinningWhatWasPresented() {
        XCTAssertEqual(
            override(payloadPin: keyB, presented: keyA, completed: false, transport: .untrustedCert),
            .pinPresentedKey(fingerprintHex: keyA),
            "Genuine trust-on-first-use: the user accepts a server nothing vouches for."
        )
        XCTAssertEqual(
            override(payloadPin: nil, presented: keyA, completed: false, transport: .untrustedCert),
            .pinPresentedKey(fingerprintHex: keyA)
        )
    }

    /// The safety property of the whole override design. Proceeding must trust
    /// what is ON THE WIRE, never what the CODE CLAIMS — installing a claimed but
    /// unconfirmed pin would be strictly worse than blocking, since the real
    /// server can never present that key.
    func testOverrideNeverInstallsTheClaimedPin() {
        for completed in [true, false] {
            let result = override(
                payloadPin: keyB,
                presented: keyA,
                completed: completed,
                transport: completed ? nil : .untrustedCert
            )
            if case .pinPresentedKey(let hex) = result {
                XCTAssertEqual(hex, keyA, "Pinned the PRESENTED key")
                XCTAssertNotEqual(hex, keyB, "MUST NOT pin the claimed key")
            }
        }
    }

    func testNoOverrideExistsWhenNothingCanBePinned() {
        XCTAssertNil(
            override(payloadPin: nil, presented: nil, completed: false, transport: .untrustedCert),
            """
            Ordinary trust refused and no digest could be computed, so there is no route to a \
            connection at all — the app has no "ignore certificate errors" mode. The UI must say \
            the remedy is on the server (a supported key type), not offer a button that cannot work.
            """
        )
        XCTAssertNil(
            override(payloadPin: keyA, presented: nil, completed: false, transport: .untrustedCert),
            "Same when the code made an unverifiable claim — still nothing to pin."
        )
    }

    func testUnverifiableClaimUnderOrdinaryTrustCanProceed() {
        XCTAssertEqual(
            override(payloadPin: keyA, presented: nil, completed: true),
            .proceedUnderOrdinaryTrust,
            "An unreadable key (e.g. Ed25519) under passing ordinary trust is a verification gap, not a danger signal."
        )
    }

    // MARK: - Normalization

    func testComparisonIsCaseInsensitive() {
        XCTAssertEqual(
            decide(payloadPin: keyA.uppercased(), presented: keyA, completed: true),
            .useOrdinaryTrust,
            "A hand-pasted uppercase fingerprint must not read as a mismatch (mirrors the evaluator's defensive lowercase compare)."
        )
    }

    func testSurroundingWhitespaceIsIgnored() {
        XCTAssertEqual(
            decide(payloadPin: "  \(keyA)\n", presented: keyA, completed: false, transport: .untrustedCert),
            .offerPinException(fingerprintHex: keyA),
            "Whitespace must be trimmed before comparison, and the offered value normalized."
        )
    }

    func testEmptyOrWhitespaceClaimCountsAsAbsent() {
        for blank in ["", "   ", "\n\t"] {
            XCTAssertEqual(
                decide(payloadPin: blank, presented: keyA, completed: true),
                .useOrdinaryTrust,
                "An empty pin field is absence of a claim, not a claim of the empty string."
            )
        }
    }

    func testOfferedFingerprintIsNormalizedLowercase() {
        guard case .offerPinException(let hex) = decide(
            payloadPin: keyA,
            presented: keyA.uppercased(),
            completed: false,
            transport: .untrustedCert
        ) else {
            return XCTFail("Expected an exception offer")
        }
        XCTAssertEqual(
            hex, keyA,
            "The offered fingerprint must be lowercase — it is what would be persisted, and storage is lowercase by convention."
        )
    }
}
