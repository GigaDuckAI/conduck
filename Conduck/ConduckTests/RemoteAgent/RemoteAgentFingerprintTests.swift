// SPDX-License-Identifier: Apache-2.0

// Conduck
// RemoteAgentFingerprintTests.swift
//
// Locks three things about `RemoteAgentTrustEvaluator`:
//
//   1. The SHA-256 public-key fingerprint computation (the value users paste).
//   2. The BRANCH ORDER of `decide(serverTrust:)` — specifically that system
//      trust is evaluated on EVERY challenge and that a pin can only tighten a
//      chain the system already accepts, never rescue one it rejected.
//   3. `classifyTransportError`, the single source of truth every gateway probe
//      maps its outcome from.
//
// A synthesised `URLAuthenticationChallenge` cannot carry a `serverTrust`, so
// (2) is exercised through `decide(serverTrust:)` against a real `SecTrust`
// built from the fixture certificate, with the injectable `evaluateSystemTrust`
// standing in for the system verdict. No live TLS server, no App Transport
// Security involvement — those live in `RemoteAgentLiveTLSTrustTests`.
//
// Fixture: `ConduckTests/Resources/test-cert.der` is an 809-byte
// DER-encoded RSA-2048 self-signed cert. The expected public-key DER
// digest is precomputed and hardcoded below; any change to the fixture
// breaks this test deliberately (re-pin would require updating the
// constant).

import XCTest
@testable import Conduck

final class RemoteAgentFingerprintTests: XCTestCase {

    /// Expected SHA-256 (lowercase hex, no separators) of the test cert's
    /// public-key DER. Precomputed via:
    ///   openssl x509 -pubkey -in test-cert.pem -noout \
    ///     | openssl pkey -pubin -outform DER \
    ///     | shasum -a 256
    private let expectedPublicKeyDigest =
        "e79f26c30eecceb968407b38cfb7f5ad9cad4d33e90d16aa0a146cccee562867"

    /// Full-cert DER digest — included as a negative control. If we
    /// accidentally hashed the WHOLE cert instead of just the public key,
    /// this is what the test would (incorrectly) match against. Used in
    /// `testHashIsOverPublicKeyNotWholeCert` to catch that regression.
    private let fullCertDigest =
        "62b5af00388dbe7d5e4f15e028edaa86e3131f19647655388c0baee874cc44d1"

    func testFingerprintMatchesExpectedDigest() throws {
        // End-to-end SPKI digest path: parse the fixture cert, extract
        // the public key, wrap in the SPKI envelope (`spkiDER(from:)`),
        // and hash. The expected value is the SPKI digest — what users
        // see when they run `openssl x509 -pubkey | openssl pkey -pubin
        // -outform DER | shasum -a 256` against their gateway's cert.
        // Plain `SecKeyCopyExternalRepresentation` on Apple platforms
        // returns the RAW key body (PKCS#1 for RSA), NOT SPKI — those
        // hashes would mismatch the recipe users follow.
        let der = try loadFixtureDER()
        let cert = try XCTUnwrap(
            SecCertificateCreateWithData(nil, der as CFData),
            "Failed to parse fixture as a DER certificate"
        )
        let publicKey = try XCTUnwrap(
            SecCertificateCopyKey(cert),
            "Failed to extract public key from fixture cert"
        )
        let spki = try XCTUnwrap(
            RemoteAgentTrustEvaluator.spkiDER(from: publicKey),
            "spkiDER must return non-nil for a known RSA-2048 fixture"
        )

        let computed = RemoteAgentTrustEvaluator.sha256Hex(publicKeyDER: spki)
        XCTAssertEqual(
            computed,
            expectedPublicKeyDigest,
            "SPKI SHA-256 digest must match the locked fixture value (openssl recipe). Pinning regressions land here first."
        )
    }

    func testHashIsOverPublicKeyNotWholeCert() throws {
        // Defensive: ensure the helper never accidentally gets pointed at
        // the whole-cert DER. If a future refactor changes the pin shape
        // from "public-key DER" to "whole-cert DER", this test forces
        // explicit re-pinning.
        let der = try loadFixtureDER()
        let wholeCertHash = RemoteAgentTrustEvaluator.sha256Hex(publicKeyDER: der)
        XCTAssertEqual(wholeCertHash, fullCertDigest,
                       "Sanity: hashing the whole cert DER produces the documented full-cert digest")
        XCTAssertNotEqual(wholeCertHash, expectedPublicKeyDigest,
                          "Full-cert digest MUST differ from public-key digest — otherwise we cannot tell them apart in a regression")
    }

    func testEmptyInputProducesEmptyStringSHA256() {
        // RFC-mandated SHA-256 of empty input — locks the helper's
        // formatting (lowercase hex, no separators).
        let empty = RemoteAgentTrustEvaluator.sha256Hex(publicKeyDER: Data())
        XCTAssertEqual(
            empty,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            "Empty-input SHA-256 must match the RFC value, lowercase hex, no separators"
        )
    }

    // MARK: - Transport-error classification (the single source of truth)

    private typealias Cls = RemoteAgentTrustEvaluator.TransportErrorClass
    /// The parameter is named for the verdict it FEEDS. It used to be `hasPin`,
    /// which made every assertion below read as a claim about whether a pin was
    /// configured while it was actually testing whether the evaluator refused
    /// the challenge — the same pin-as-proxy the classifier removed, surviving
    /// as a label. The two coincide only because of an invariant inside `decide`
    /// (an unpinned challenge is never cancelled) that the classifier cannot see,
    /// and a test that states the proxy instead of the fact stops being a check
    /// on the fact. There is no loose-Bool classifier surface to call any more;
    /// the assembly happens here, in a test, where `pinComparisonUnsupported:
    /// false` is a stated property of these cases rather than a shim silently
    /// dropping a verdict.
    private func classify(
        _ code: URLError.Code,
        challengeRefused: Bool = false,
        systemTrustRejected: Bool = false,
        pinRejected: Bool = false
    ) -> Cls {
        RemoteAgentTrustEvaluator.classifyTransportError(
            code,
            signals: .init(systemTrustRejected: systemTrustRejected,
                           challengeRefused: challengeRefused,
                           pinRejected: pinRejected,
                           pinComparisonUnsupported: false))
    }

    func testClassifyTimeout() {
        XCTAssertEqual(classify(.timedOut), .timeout)
        XCTAssertEqual(classify(.timedOut, challengeRefused: true, pinRejected: true), .timeout,
                       "Timeout is a timeout regardless of pin/trust signals.")
    }

    func testClassifyUnreachableFamily() {
        for code in [URLError.Code.cannotConnectToHost, .notConnectedToInternet,
                     .networkConnectionLost, .cannotFindHost, .dnsLookupFailed, .resourceUnavailable] {
            XCTAssertEqual(classify(code), .unreachable, "\(code) must be unreachable")
        }
    }

    func testClassifySpecificCertCodesResolveToUntrustedWithoutASignal() {
        // The system NAMED the cert as the cause → classify regardless of the
        // trust signals, and with NEITHER signal set the answer is UNTRUSTED
        // whether or not the evaluator also refused. Our own refusal is not
        // evidence that the PIN is what refused: the codes below are the system
        // saying it does not trust the certificate, and relabelling that as a
        // mismatch told the user their fingerprint had changed (it had not) and
        // sent them to edit a pin nothing had consulted.
        for code in [URLError.Code.serverCertificateUntrusted, .serverCertificateHasBadDate,
                     .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid] {
            XCTAssertEqual(classify(code, challengeRefused: false), .untrustedCert,
                           "\(code) with no refusal of our own → untrustedCert")
            XCTAssertEqual(classify(code, challengeRefused: true), .untrustedCert,
                           "\(code) refused by the evaluator but with NO recorded pin rejection → still untrustedCert")
        }
    }

    func testClassifySpecificCertCodesNeedPinRejectedToBeAMismatch() {
        // The counterpart: `pinRejected` is the POSITIVE record that a digest
        // was compared against a chain the system DID trust and the key
        // disagreed. That — and only that — makes one of these codes a
        // mismatch, which is the one verdict that warns about interception.
        for code in [URLError.Code.serverCertificateUntrusted, .serverCertificateHasBadDate,
                     .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid] {
            XCTAssertEqual(classify(code, challengeRefused: true, systemTrustRejected: false, pinRejected: true),
                           .certMismatch,
                           "\(code) with a CONFIRMED pin rejection → certMismatch")
        }
    }

    func testClassifyIsIdenticalAcrossEveryCertificateNamingCode() {
        // Which code URLSession picks for one refusal is a CFNetwork detail: the
        // pinned fail-closed arm surfaces as `.cancelled`, the same chain on
        // another lane can surface as `-1200` or `-1202`. The user must not get
        // a different story per code, so every code that can name a certificate
        // resolves the same way for the same pair of signals.
        let certNaming: [URLError.Code] = [
            .secureConnectionFailed, .cancelled,
            .serverCertificateUntrusted, .serverCertificateHasBadDate,
            .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
        ]
        for code in certNaming {
            XCTAssertEqual(classify(code, challengeRefused: true, systemTrustRejected: true), .untrustedCert,
                           "\(code): a system rejection is an untrusted certificate on every code.")
            XCTAssertEqual(classify(code, challengeRefused: true, pinRejected: true), .certMismatch,
                           "\(code): a confirmed pin rejection is a mismatch on every code.")
        }
    }

    // The regression: a GENERIC `.secureConnectionFailed` must NOT be a cert
    // problem unless the trust layer actually rejected the cert.
    func testClassifySecureConnectionFailed_noPin_transient_isUnreachable() {
        XCTAssertEqual(classify(.secureConnectionFailed, challengeRefused: false, systemTrustRejected: false),
                       .unreachable,
                       "Cold-tunnel handshake hiccup (no system rejection) must be retryable, NOT 'untrusted certificate'.")
    }

    func testClassifySecureConnectionFailed_noPin_systemRejected_isUntrusted() {
        XCTAssertEqual(classify(.secureConnectionFailed, challengeRefused: false, systemTrustRejected: true),
                       .untrustedCert,
                       "A genuine no-pin system rejection that surfaced as the generic code must still name the certificate.")
    }

    func testClassifySecureConnectionFailed_pin_transient_isUnreachable() {
        XCTAssertEqual(classify(.secureConnectionFailed, challengeRefused: true, pinRejected: false),
                       .unreachable,
                       "A pinned host on a cold tunnel must NOT falsely read as a cert MISMATCH (which implies MITM).")
    }

    func testClassifySecureConnectionFailed_pin_pinRejected_isCertMismatch() {
        XCTAssertEqual(classify(.secureConnectionFailed, challengeRefused: true, pinRejected: true),
                       .certMismatch,
                       "A pinned host where the evaluator confirmed the mismatch is a genuine cert mismatch.")
    }

    func testClassifyCancelled() {
        // The evaluator refused nothing → a real task cancellation.
        XCTAssertEqual(classify(.cancelled, challengeRefused: false), .cancelled)
        // It refused, but no confirmed pin rejection → still a benign cancellation.
        XCTAssertEqual(classify(.cancelled, challengeRefused: true, pinRejected: false), .cancelled)
        // It refused AND confirmed the digest disagreement → cert mismatch.
        XCTAssertEqual(classify(.cancelled, challengeRefused: true, pinRejected: true), .certMismatch)
    }

    func testClassifyCancelledWithSystemTrustRejectedIsUntrustedCert() {
        // The fail-closed arm: a pin configured over a chain the system rejects
        // is answered with `cancelAuthenticationChallenge`, so it reaches the
        // caller as `.cancelled` (-999). Without this arm the one lane that
        // actually refuses a MITM would report "the user cancelled".
        XCTAssertEqual(classify(.cancelled, challengeRefused: true, systemTrustRejected: true, pinRejected: false),
                       .untrustedCert,
                       "A pinned challenge cancelled because the system rejected the chain is an UNTRUSTED CERTIFICATE, not a cancel.")
    }

    func testClassifyCancelledOnAnUnpinnedLaneStaysACancelEvenWithASystemRejection() {
        // This case used to assert `.untrustedCert`, on the reasoning that
        // `systemTrustRejected` is a positive signal. It is — but on an UNPINNED
        // lane it is not a signal about THIS failure. `decide` records it before
        // the no-pin guard and then returns `.performDefaultHandling`, so the
        // evaluator never cancels; a -999 there is a genuine cancellation. And
        // the flag latches: `SecTrustEvaluateWithError` inside a challenge is
        // ADVISORY (it also fails when evaluation could not COMPLETE — an OCSP
        // fetch needing the network), so the system can go on to accept the
        // chain, the request can SUCCEED with the flag set, and the user's next
        // real Cancel would then be reported as an untrusted certificate.
        XCTAssertEqual(classify(.cancelled, challengeRefused: false, systemTrustRejected: true), .cancelled,
                       "A -999 the evaluator did not produce is a cancellation whatever the advisory trust flag says.")
        XCTAssertEqual(classify(.cancelled, challengeRefused: true, systemTrustRejected: true), .untrustedCert,
                       "A -999 the evaluator DID produce over a chain the system objected to keeps the fail-closed verdict.")
    }

    func testClassifyCancelledStillReportsAConfirmedMismatchWithoutAPinPosture() {
        // Only a refusing branch sets `pinRejected`, so `challengeRefused: false`
        // alongside it is a caller contradicting itself. Keep the mismatch rather
        // than swallow it: dropping the one verdict that says the connection may
        // be intercepted is the worse failure mode of the two.
        XCTAssertEqual(classify(.cancelled, challengeRefused: false, pinRejected: true), .certMismatch,
                       "A confirmed digest disagreement must never be silently downgraded to a benign cancel.")
    }

    func testClassifySystemTrustRejectionOutranksPinRejection() {
        // Ordering, not preference: "this device does not trust this
        // certificate" names a remedy the user can act on (get a real cert);
        // "the pinned key changed" would send them to re-check a fingerprint
        // that was never the problem. The precedence is IDENTICAL in every arm
        // that can name a certificate, generic codes and specific alike —
        // otherwise the same refusal would be described two different ways
        // depending on which code URLSession happened to pick.
        for code in [URLError.Code.secureConnectionFailed, .cancelled,
                     .serverCertificateUntrusted, .serverCertificateHasBadDate,
                     .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid] {
            XCTAssertEqual(classify(code, challengeRefused: true, systemTrustRejected: true, pinRejected: true),
                           .untrustedCert,
                           "\(code): systemTrustRejected must be checked before pinRejected.")
            XCTAssertEqual(classify(code, challengeRefused: true, systemTrustRejected: true, pinRejected: false),
                           .untrustedCert,
                           "\(code): a refusal with no digest disagreement behind it must not be relabelled a key mismatch.")
        }
    }

    func testClassifyUnknownCodeIsUnreachable() {
        XCTAssertEqual(classify(.badServerResponse), .unreachable)
        XCTAssertEqual(classify(.badURL), .unreachable)
    }

    // MARK: - Branch order: a pin applies ON TOP of system trust
    //
    // THE rule these lock: a certificate pin is an ADDITIONAL restriction on a
    // connection the system already trusts. It can never rescue an untrusted
    // chain. `evaluateSystemTrust` is injected so the system's verdict is a test
    // input — no unit test can make this machine trust the fixture certificate,
    // and relying on App Transport Security to refuse the connection later is
    // exactly the posture this change removes.

    func testSystemTrustIsEvaluatedOnEveryChallengeIncludingPinnedOnes() throws {
        // THE ROOT DEFECT this locks: system trust used to be evaluated only on
        // the no-pin path, so a pinned connection never recorded that the device
        // distrusted the chain.
        let trust = try makeFixtureTrust()
        let counter = CallCounter()
        let evaluator = RemoteAgentTrustEvaluator(
            pinnedFingerprintHex: expectedPublicKeyDigest,
            evaluateSystemTrust: { _ in counter.record(); return true })

        _ = evaluator.decide(serverTrust: trust)

        XCTAssertEqual(counter.count, 1,
                       "A PINNED challenge must still run system chain validation — the pin is a second gate, not a replacement for the first.")
    }

    func testPinnedChallengeOverAnUntrustedChainFailsClosed() throws {
        let trust = try makeFixtureTrust()
        let evaluator = RemoteAgentTrustEvaluator(
            pinnedFingerprintHex: expectedPublicKeyDigest,
            evaluateSystemTrust: { _ in false })

        XCTAssertEqual(evaluator.decide(serverTrust: trust), .cancel,
                       "A matching pin must NOT rescue a chain the system rejected. Returning .useCredential here and letting App Transport Security kill the connection is not equivalent — the app's own behaviour has to be correct on its own.")
        XCTAssertTrue(evaluator.systemTrustRejected)
        XCTAssertFalse(evaluator.pinRejected,
                       "The pin MATCHED. Recording a pin rejection here would send the user off to re-check a fingerprint that was never the problem.")
        XCTAssertEqual(classify(.cancelled, challengeRefused: true,
                                systemTrustRejected: evaluator.systemTrustRejected,
                                pinRejected: evaluator.pinRejected),
                       .untrustedCert,
                       "End to end: the fail-closed cancel must reach the user as 'untrusted certificate'.")
    }

    func testPinnedChallengeUsesTheRealSystemEvaluationByDefault() throws {
        // The production default (`SecTrustEvaluateWithError`) with no injection:
        // the fixture is self-signed, so the system rejects it and the pin — which
        // matches — must not save it. Guards against the seam being wired up but
        // the default being something permissive.
        let trust = try makeFixtureTrust()
        let evaluator = RemoteAgentTrustEvaluator(pinnedFingerprintHex: expectedPublicKeyDigest)

        XCTAssertEqual(evaluator.decide(serverTrust: trust), .cancel,
                       "Default (real) system evaluation must reject the self-signed fixture even though the pin matches it exactly.")
        XCTAssertTrue(evaluator.systemTrustRejected)
    }

    func testPinMatchOnASystemTrustedChainIsAccepted() throws {
        let trust = try makeFixtureTrust()
        let evaluator = RemoteAgentTrustEvaluator(
            pinnedFingerprintHex: expectedPublicKeyDigest.uppercased(),
            evaluateSystemTrust: { _ in true })

        XCTAssertEqual(evaluator.decide(serverTrust: trust), .useCredential,
                       "System trust passed AND the SPKI digest matches (case-insensitively, so a hand-pasted uppercase pin works) → accept.")
        XCTAssertFalse(evaluator.systemTrustRejected)
        XCTAssertFalse(evaluator.pinRejected)
    }

    func testPinMismatchOnASystemTrustedChainIsAPinRejection() throws {
        let trust = try makeFixtureTrust()
        let evaluator = RemoteAgentTrustEvaluator(
            pinnedFingerprintHex: String(repeating: "ab", count: 32),
            evaluateSystemTrust: { _ in true })

        XCTAssertEqual(evaluator.decide(serverTrust: trust), .cancel)
        XCTAssertTrue(evaluator.pinRejected,
                      "A publicly-trusted certificate that is not the pinned key is the MITM case the pin exists for.")
        XCTAssertFalse(evaluator.systemTrustRejected,
                       "The system accepted the chain — only the pin refused it.")
        XCTAssertEqual(classify(.cancelled, challengeRefused: true,
                                systemTrustRejected: evaluator.systemTrustRejected,
                                pinRejected: evaluator.pinRejected),
                       .certMismatch)
    }

    func testUnpinnedChallengeLeavesTheSystemAuthoritative() throws {
        // No pin → `.performDefaultHandling` in BOTH directions. Our own
        // evaluation is advisory (it can differ from the full system policy), so
        // it records the signal and gets out of the way.
        let trust = try makeFixtureTrust()

        let rejected = RemoteAgentTrustEvaluator(pinnedFingerprintHex: nil,
                                                 evaluateSystemTrust: { _ in false })
        XCTAssertEqual(rejected.decide(serverTrust: trust), .performDefaultHandling)
        XCTAssertTrue(rejected.systemTrustRejected,
                      "The signal must still be recorded — it is what tells a genuine rejection apart from a transient handshake failure.")
        XCTAssertFalse(rejected.pinRejected)

        let accepted = RemoteAgentTrustEvaluator(pinnedFingerprintHex: "",
                                                 evaluateSystemTrust: { _ in true })
        XCTAssertEqual(accepted.decide(serverTrust: trust), .performDefaultHandling,
                       "An EMPTY pin string is 'no pin', not 'a pin that matches nothing'.")
        XCTAssertFalse(accepted.systemTrustRejected)
        XCTAssertFalse(accepted.pinRejected)
    }

    func testPresentedFingerprintIsCapturedBeforeEveryBranch() throws {
        let trust = try makeFixtureTrust()
        let cases: [(String, RemoteAgentTrustEvaluator)] = [
            ("no pin, system rejected",
             RemoteAgentTrustEvaluator(pinnedFingerprintHex: nil, evaluateSystemTrust: { _ in false })),
            ("pinned, system rejected (fail closed)",
             RemoteAgentTrustEvaluator(pinnedFingerprintHex: expectedPublicKeyDigest, evaluateSystemTrust: { _ in false })),
            ("pinned, system trusted, digest differs",
             RemoteAgentTrustEvaluator(pinnedFingerprintHex: String(repeating: "ab", count: 32), evaluateSystemTrust: { _ in true })),
        ]
        for (label, evaluator) in cases {
            _ = evaluator.decide(serverTrust: trust)
            XCTAssertEqual(evaluator.presentedFingerprintHex, expectedPublicKeyDigest,
                           "\(label): the presented leaf digest is captured before any branch. Nothing SHOWS it to a user — trust-on-first-use is gone — but a test can see that the evaluator hashed the leaf it was handed.")
        }
    }

    // MARK: - Signal LIFETIME: a verdict belongs to ONE attempt
    //
    // THE DEFECT THESE LOCK. `systemTrustRejected` is an advisory OBJECTION, not
    // a refusal: `SecTrustEvaluateWithError` inside a challenge also fails when
    // evaluation merely could not COMPLETE (an OCSP fetch needing the network),
    // after which the system's own default handling can ACCEPT the chain and the
    // request SUCCEED. While the flag lived on the evaluator rather than on the
    // attempt, that objection outlived the attempt that recorded it — and the
    // lanes that reuse ONE evaluator across MANY attempts (`STTClient` retries 3×,
    // `TTSClient` 2×, the file-lane staged test and folder probe issue a whole
    // sequence) turned a later, unrelated transient `-1200`/`-999` into a
    // certificate verdict the user could not act on.
    //
    // Three review rounds patched that in three different ARMS. These test the
    // lifetime instead, which is where the defect actually was.

    func testAnObjectionOnAnAttemptThatSUCCEEDEDDoesNotExplainTheNextAttemptsFailure() throws {
        let trust = try makeFixtureTrust()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        // UNPINNED lane: `decide` records the objection and hands the challenge
        // back to the system, whose full policy may still accept the chain. This
        // is the attempt that WORKS.
        let evaluator = RemoteAgentTrustEvaluator(pinnedFingerprintHex: nil,
                                                  evaluateSystemTrust: { _ in false })

        beginAttempt(on: evaluator, session: session)
        XCTAssertEqual(evaluator.decide(serverTrust: trust), .performDefaultHandling)
        XCTAssertTrue(evaluator.systemTrustRejected,
                      "The objection must still be RECORDED — it is what tells a genuine rejection apart from a transient handshake failure on the attempt it belongs to.")

        // The retry. A cold tunnel fails before any certificate arrives, so this
        // attempt raises NO challenge at all and has nothing to say about trust.
        beginAttempt(on: evaluator, session: session)

        XCTAssertFalse(evaluator.systemTrustRejected,
                       "A verdict from a previous attempt must not be visible to this one. This is the whole defect: the objection was recorded on an attempt that SUCCEEDED.")
        XCTAssertEqual(evaluator.classifyTransportError(.secureConnectionFailed), .unreachable,
                       "A cold-tunnel -1200 on the retry must stay retryable. Reading the previous attempt's objection here reported 'untrusted certificate' for a certificate nothing had rejected.")
    }

    func testAPinRefusalOnOneAttemptDoesNotExplainTheNextAttemptsCancel() throws {
        let trust = try makeFixtureTrust()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        let evaluator = RemoteAgentTrustEvaluator(
            pinnedFingerprintHex: String(repeating: "ab", count: 32),
            evaluateSystemTrust: { _ in true })

        beginAttempt(on: evaluator, session: session)
        XCTAssertEqual(evaluator.decide(serverTrust: trust), .cancel)
        XCTAssertEqual(evaluator.classifyTransportError(.cancelled), .certMismatch)

        // Next attempt, no challenge (connection reused, or a failure before the
        // certificate stage). A -999 here is an ordinary cancellation.
        beginAttempt(on: evaluator, session: session)

        XCTAssertFalse(evaluator.pinRejected)
        XCTAssertEqual(evaluator.classifyTransportError(.cancelled), .cancelled,
                       "A stale pin refusal must never turn a later benign cancel into 'the connection may be intercepted' — a false alarm on the app's most alarming message.")
    }

    func testAGenuineRejectionOnTheFAILINGAttemptIsStillReported() throws {
        // The counterpart, and the property the pairing trust decision rests on:
        // scoping must not throw the signal away when it DOES belong to the
        // failing attempt. Under ATS a remote self-signed host returns the generic
        // -1200, never -1201…-1204, so this signal is the only thing that can tell
        // the unpinned pairing probe "untrusted chain" from "cold tunnel".
        let trust = try makeFixtureTrust()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        let evaluator = RemoteAgentTrustEvaluator(pinnedFingerprintHex: nil,
                                                  evaluateSystemTrust: { _ in false })
        beginAttempt(on: evaluator, session: session)
        _ = evaluator.decide(serverTrust: trust)

        XCTAssertEqual(evaluator.classifyTransportError(.secureConnectionFailed), .untrustedCert,
                       "An objection recorded during THIS attempt still explains THIS attempt's -1200. Without it the pairing probe could not tell an untrusted chain from a cold tunnel.")
    }

    func testTheAttemptWindowOpensBeforeAnyChallengeCanFire() throws {
        // Ordering guard. The boundary is only sound because URLSession delivers
        // `didCreateTask` on its serial delegate queue before that task can raise
        // a challenge. If a refactor ever moved the boundary AFTER the challenge,
        // it would wipe the verdict it was supposed to scope.
        let trust = try makeFixtureTrust()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        let evaluator = RemoteAgentTrustEvaluator(pinnedFingerprintHex: nil,
                                                  evaluateSystemTrust: { _ in false })
        beginAttempt(on: evaluator, session: session)
        _ = evaluator.decide(serverTrust: trust)

        XCTAssertTrue(evaluator.systemTrustRejected,
                      "Opening the window must not clear a verdict the SAME attempt then records.")
        XCTAssertEqual(evaluator.presentedFingerprintHex, expectedPublicKeyDigest,
                       "The presented digest lives in the same window and must survive it too.")
    }

    // MARK: - `challengeRefused`: the evaluator's own refusal, not a pin's existence

    func testRefusalIsRecordedOnlyWhenTheEvaluatorActuallyCancels() throws {
        let trust = try makeFixtureTrust()

        let unpinned = RemoteAgentTrustEvaluator(pinnedFingerprintHex: nil,
                                                 evaluateSystemTrust: { _ in false })
        XCTAssertEqual(unpinned.decide(serverTrust: trust), .performDefaultHandling)
        XCTAssertFalse(unpinned.attemptSignals.challengeRefused,
                       "Default handling is not a refusal, however loudly the advisory check objected.")

        let failClosed = RemoteAgentTrustEvaluator(pinnedFingerprintHex: expectedPublicKeyDigest,
                                                   evaluateSystemTrust: { _ in false })
        XCTAssertEqual(failClosed.decide(serverTrust: trust), .cancel)
        XCTAssertTrue(failClosed.attemptSignals.challengeRefused,
                      "The fail-closed cancel IS the evaluator's refusal, and -999 is otherwise indistinguishable from a user cancel.")

        let accepted = RemoteAgentTrustEvaluator(pinnedFingerprintHex: expectedPublicKeyDigest,
                                                 evaluateSystemTrust: { _ in true })
        XCTAssertEqual(accepted.decide(serverTrust: trust), .useCredential)
        XCTAssertFalse(accepted.attemptSignals.challengeRefused)
    }

    func testAnUnpinnedUserCancelIsNotReportedAsAnUntrustedCertificate() throws {
        // The scenario that keeps the gate on `.cancelled` load-bearing even after
        // the lifetime fix, expressed WITHIN one attempt: the advisory check could
        // not complete, the system accepted the chain anyway, the reply started
        // arriving, and the user tapped Cancel. Objection and -999, same attempt,
        // nothing to do with each other.
        let trust = try makeFixtureTrust()
        let evaluator = RemoteAgentTrustEvaluator(pinnedFingerprintHex: nil,
                                                  evaluateSystemTrust: { _ in false })
        _ = evaluator.decide(serverTrust: trust)

        XCTAssertTrue(evaluator.systemTrustRejected)
        XCTAssertEqual(evaluator.classifyTransportError(.cancelled), .cancelled,
                       "Only a challenge the evaluator REFUSED can make a -999 a certificate verdict. An unpinned challenge is handed back to the system and never cancelled.")
    }

    // MARK: - `.certKeyUnpinnable`: a key we cannot fingerprint is not an attack

    func testAnUnpinnableKeyIsItsOwnClassNotAnInterceptionWarning() {
        let unpinnable = signals(pinRejected: true, pinComparisonUnsupported: true)
        let disagreed = signals(pinRejected: true)

        for code in [URLError.Code.secureConnectionFailed, .cancelled,
                     .serverCertificateUntrusted, .serverCertificateHasBadDate,
                     .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid] {
            XCTAssertEqual(classify(code, signals: unpinnable), .certKeyUnpinnable,
                           "\(code): a pin that could not be COMPUTED must not be reported as a pin that DISAGREED. That user's chain is publicly trusted and nothing was caught — telling them the connection may be intercepted is a false alarm on the app's most alarming message.")
            XCTAssertEqual(classify(code, signals: disagreed), .certMismatch,
                           "\(code): a real digest disagreement stays the interception shape.")
        }
    }

    func testSystemRejectionStillOutranksAnUnpinnableKey() {
        // Ordering is identical for the new class: "this device does not trust
        // this certificate" names the remedy the user can act on. In practice
        // `decide` cannot produce this pair (the unpinnable arm sits after
        // `guard systemTrusts`), so this locks the classifier against a caller
        // that supplies it anyway.
        let both = signals(systemTrustRejected: true, pinRejected: true, pinComparisonUnsupported: true)
        for code in [URLError.Code.secureConnectionFailed, .cancelled,
                     .serverCertificateUntrusted] {
            XCTAssertEqual(classify(code, signals: both), .untrustedCert, "\(code)")
        }
    }

    func testAKeyOutsideTheV1PrefixTableCannotBeFingerprinted() throws {
        // The precondition the `.certKeyUnpinnable` arm rests on, proven against a
        // REAL key rather than assumed: P-521 is a perfectly valid EC key that the
        // V1 SPKI prefix table does not cover, so no digest can be computed for it
        // and the evaluator has nothing to compare a pin against.
        //
        // Driving `decide` all the way to that arm additionally needs a
        // CERTIFICATE carrying such a key, which the RSA-2048 fixture is not;
        // `RemoteAgentLiveTLSTrustTests`' fixture is where that belongs.
        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 521,
            kSecAttrIsPermanent as String: false,
        ]
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw XCTSkip("This platform refused to mint a P-521 key: \(String(describing: error?.takeRetainedValue()))")
        }

        XCTAssertNil(RemoteAgentTrustEvaluator.spkiDER(from: publicKey),
                     "P-521 is outside the V1 prefix table, so there is no SPKI envelope to hash — which is exactly the condition `.certKeyUnpinnable` describes.")
    }

    func testDecideReachesTheUnpinnableArmWithARealUnfingerprintableCertificate() throws {
        // Closes the gap the classifier-level cases above cannot: those supply the
        // verdicts by hand, so they lock the TABLE but not the wiring. This drives
        // the production branch order against a real P-521 certificate — a valid
        // EC key the V1 SPKI prefix table has no envelope for — and proves `decide`
        // itself produces the pair `.certKeyUnpinnable` is derived from.
        let trust = try makeTrust(resource: "test-cert-p521")

        XCTAssertNil(RemoteAgentTrustEvaluator.computeLeafSPKIHex(from: trust),
                     "Precondition: the fixture must be a key outside the V1 prefix table, or this test proves nothing.")

        let evaluator = RemoteAgentTrustEvaluator(
            pinnedFingerprintHex: String(repeating: "ab", count: 32),
            evaluateSystemTrust: { _ in true })

        XCTAssertEqual(evaluator.decide(serverTrust: trust), .cancel,
                       "FAIL CLOSED: with a pin configured and no digest computable, falling through to default handling would accept a chain the user pinned against.")

        let recorded = evaluator.attemptSignals
        XCTAssertTrue(recorded.pinComparisonUnsupported,
                      "The reason must be recorded, not inferred — it is what separates this from a key that disagreed.")
        XCTAssertTrue(recorded.pinRejected)
        XCTAssertTrue(recorded.challengeRefused)
        XCTAssertFalse(recorded.systemTrustRejected,
                       "The system TRUSTED this chain. Reporting an untrusted certificate would send the user to fix one that is fine.")

        XCTAssertEqual(evaluator.classifyTransportError(.cancelled), .certKeyUnpinnable,
                       "End to end: a gateway serving a P-521 certificate to a pinned user is an unfingerprintable key, not an interception.")
        XCTAssertNil(evaluator.presentedFingerprintHex,
                     "There is no digest to report for a key the table cannot envelope.")
    }

    func testTheAttemptBoundaryClearsEveryVerdictNotJustTheOnesInUseToday() throws {
        // The reset is the entire mechanism, so it is asserted WHOLE rather than
        // field by field. A verdict added to the window without a line in the reset
        // would be a latch again — the exact class of defect the boundary exists to
        // close — and a per-field test would not notice.
        let trust = try makeTrust(resource: "test-cert-p521")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        // The unpinnable arm sets three of the four verdicts at once, which makes
        // it the densest state the window can hold.
        let evaluator = RemoteAgentTrustEvaluator(
            pinnedFingerprintHex: String(repeating: "ab", count: 32),
            evaluateSystemTrust: { _ in true })

        beginAttempt(on: evaluator, session: session)
        _ = evaluator.decide(serverTrust: trust)
        XCTAssertNotEqual(evaluator.attemptSignals, .empty)

        beginAttempt(on: evaluator, session: session)
        XCTAssertEqual(evaluator.attemptSignals, .empty,
                       "Every verdict resets together. Leaving one behind is how the previous three rounds of this bug survived a fix.")
        XCTAssertNil(evaluator.presentedFingerprintHex,
                     "The presented digest is attempt-scoped too — a leaf seen on an earlier attempt must not be reported as this attempt's.")
    }

    func testASequenceOfAttemptsWithoutAChallengeNeverAccumulatesAVerdict() throws {
        // The file-lane shape: `FileServerClient.performStagedTest` issues PUT,
        // GET, DELETE and a nested MKCOL+PUT on ONE probe session, and
        // `probeFolderCapability` several more. Once the first hop has handshaken,
        // the rest reuse the connection and raise no challenge — so no stage may
        // ever inherit a certificate verdict from an earlier one.
        let trust = try makeFixtureTrust()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        let evaluator = RemoteAgentTrustEvaluator(pinnedFingerprintHex: nil,
                                                  evaluateSystemTrust: { _ in false })

        // Stage 1 handshakes; the advisory check objects but the system accepts.
        beginAttempt(on: evaluator, session: session)
        _ = evaluator.decide(serverTrust: trust)

        for stage in 2...5 {
            beginAttempt(on: evaluator, session: session)
            XCTAssertEqual(evaluator.attemptSignals, .empty, "stage \(stage)")
            XCTAssertEqual(evaluator.classifyTransportError(.secureConnectionFailed), .unreachable,
                           "stage \(stage): a stage that never saw a certificate has nothing to say about one.")
            XCTAssertEqual(evaluator.classifyTransportError(.cancelled), .cancelled,
                           "stage \(stage): likewise for -999.")
        }
    }

    // MARK: - Helpers

    /// A real `SecTrust` over an arbitrary fixture certificate in the test bundle.
    /// `makeFixtureTrust()` above is the RSA-2048 default; this reaches the other
    /// fixtures, which exist to exercise key algorithms the default cannot.
    ///
    /// `test-cert-p521.der` — a self-signed EC P-521 certificate, i.e. a valid key
    /// the V1 SPKI prefix table deliberately has no envelope for. Regenerate with:
    ///
    ///     openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:secp521r1 \
    ///       -keyout key.pem -out cert.pem -days 3650 -nodes \
    ///       -subj "/CN=unpinnable.example.test"
    ///     openssl x509 -in cert.pem -outform DER -out test-cert-p521.der
    ///
    /// Nothing depends on its digest (there isn't one — that is the point), so it
    /// can be regenerated freely, unlike the RSA fixture whose digest is pinned.
    private func makeTrust(resource: String) throws -> SecTrust {
        let bundle = Bundle(for: type(of: self))
        let url = try XCTUnwrap(bundle.url(forResource: resource, withExtension: "der"),
                                "Fixture \(resource).der missing from test bundle Resources")
        let der = try Data(contentsOf: url)
        let cert = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData),
                                 "Failed to parse \(resource) as a DER certificate")
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(cert, SecPolicyCreateBasicX509(), &trust)
        XCTAssertEqual(status, errSecSuccess, "SecTrustCreateWithCertificates failed (\(status))")
        return try XCTUnwrap(trust)
    }

    /// Open a new attempt window the way URLSession does — by creating a task on
    /// the session the evaluator is the delegate of. The task is never resumed, so
    /// nothing touches the network; the delegate callback is the whole point.
    private func beginAttempt(on evaluator: RemoteAgentTrustEvaluator, session: URLSession) {
        evaluator.urlSession(
            session,
            didCreateTask: session.dataTask(with: URL(string: "https://gateway.example.test/v1/models")!)
        )
    }

    private func signals(
        systemTrustRejected: Bool = false,
        challengeRefused: Bool = true,
        pinRejected: Bool = false,
        pinComparisonUnsupported: Bool = false
    ) -> RemoteAgentTrustEvaluator.AttemptTrustSignals {
        .init(systemTrustRejected: systemTrustRejected,
              challengeRefused: challengeRefused,
              pinRejected: pinRejected,
              pinComparisonUnsupported: pinComparisonUnsupported)
    }

    private func classify(
        _ code: URLError.Code,
        signals: RemoteAgentTrustEvaluator.AttemptTrustSignals
    ) -> Cls {
        RemoteAgentTrustEvaluator.classifyTransportError(code, signals: signals)
    }

    /// Lock-guarded call counter. The injected `evaluateSystemTrust` is
    /// `@Sendable`, so it cannot capture a mutable local.
    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func record() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    /// A real `SecTrust` over the fixture certificate. The system does not trust
    /// it (self-signed), which is why `evaluateSystemTrust` is injected wherever
    /// a passing chain is the thing under test.
    private func makeFixtureTrust() throws -> SecTrust {
        let der = try loadFixtureDER()
        let cert = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData),
                                 "Failed to parse fixture as a DER certificate")
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(cert, SecPolicyCreateBasicX509(), &trust)
        XCTAssertEqual(status, errSecSuccess, "SecTrustCreateWithCertificates failed (\(status))")
        return try XCTUnwrap(trust)
    }

    private func loadFixtureDER() throws -> Data {
        let bundle = Bundle(for: type(of: self))
        let url = try XCTUnwrap(
            bundle.url(forResource: "test-cert", withExtension: "der"),
            "Fixture test-cert.der missing from test bundle Resources"
        )
        return try Data(contentsOf: url)
    }
}
