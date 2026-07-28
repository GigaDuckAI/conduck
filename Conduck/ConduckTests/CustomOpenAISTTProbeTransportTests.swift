// SPDX-License-Identifier: Apache-2.0

// Conduck
// CustomOpenAISTTProbeTransportTests.swift
//
// Locks that the custom-STT auth probe routes a transport failure through
// `RemoteAgentTrustEvaluator.classifyTransportError` — the same single source of
// truth as `STTClient.performRequest`, `STTClient+Background`, and
// `STTConnectionTestSuite`.
//
// It is the fourth custom-STT call site, and the one that used to collapse every
// `URLError` into `.sttProviderUnreachable`. That case is RETRYABLE, so a
// terminal refusal — the evaluator's fail-closed -999, or the system's own
// -1201…-1204 — was reported as a passing outage and retried, and the user never
// learned that the fix is a certificate this device would trust.
//
// Asserted on `errorCode` (`AppError` is not Equatable) against the named case's
// own code.
//
// Pure over its inputs: no bundled probe asset, no endpoint, no session.

import XCTest
@testable import Conduck

final class CustomOpenAISTTProbeTransportTests: XCTestCase {

    /// `challengeRefused` is what `hasPin` always stood for: the evaluator was on
    /// a path that CAN cancel. Named for the fact rather than the posture.
    private func map(_ code: URLError.Code,
                     challengeRefused: Bool = false,
                     systemTrustRejected: Bool = false,
                     pinRejected: Bool = false,
                     pinComparisonUnsupported: Bool = false) -> AppError {
        CustomOpenAISTTProbe.transportError(
            code,
            signals: .init(systemTrustRejected: systemTrustRejected,
                           challengeRefused: challengeRefused,
                           pinRejected: pinRejected,
                           pinComparisonUnsupported: pinComparisonUnsupported)
        )
    }

    func testTheFailClosedCancelIsAnUntrustedCertificateNotAnOutage() {
        // The evaluator answers a pinned challenge over a chain this device
        // rejects with `cancelAuthenticationChallenge`, which URLSession reports
        // as a bare -999. Read without the trust signals it is indistinguishable
        // from a user abort, and the probe reported it as a server that happened
        // to be down.
        let error = map(.cancelled, challengeRefused: true, systemTrustRejected: true)
        XCTAssertEqual(error.errorCode, AppError.sttCustomCertUntrusted.errorCode)
        XCTAssertFalse(error.isRetryable,
                       "The device will refuse the same certificate every time; retrying only delays the message that names the server-side fix.")
    }

    func testAConfirmedPinMismatchKeepsItsOwnVerdict() {
        let error = map(.cancelled, challengeRefused: true, pinRejected: true)
        XCTAssertEqual(error.errorCode, AppError.sttCustomCertMismatch.errorCode,
                       "A pinned key that disagreed with a chain the system DID trust is a different problem with a different remedy, and must never read as 'go get a trusted certificate'.")
        XCTAssertFalse(error.isRetryable)
    }

    func testAKeyConduckCannotFingerprintIsNotReportedAsAMismatch() {
        // Reachability guard, not just a mapping check. This lane threads the
        // whole `AttemptTrustSignals` snapshot precisely so this verdict can
        // arrive; on the loose-Bool overload `pinComparisonUnsupported` has
        // nowhere to travel and the same attempt reports `.sttCustomCertMismatch`
        // — telling a user with an Ed25519 certificate their connection may be
        // intercepted. If someone re-flattens the parameter, this fails.
        let error = map(.cancelled, challengeRefused: true,
                        pinRejected: true, pinComparisonUnsupported: true)
        XCTAssertEqual(error.errorCode, AppError.sttCustomCertKeyUnpinnable.errorCode,
                       "System trust passed and the digest could not be computed — nothing disagreed, so nothing may imply interception.")
        XCTAssertNotEqual(error.errorCode, AppError.sttCustomCertMismatch.errorCode)
        XCTAssertFalse(error.isRetryable)
    }

    func testSystemTrustRejectionOutranksAPinRejection() {
        XCTAssertEqual(map(.cancelled, challengeRefused: true, systemTrustRejected: true, pinRejected: true).errorCode,
                       AppError.sttCustomCertUntrusted.errorCode,
                       "Same precedence as every other lane.")
    }

    func testTheSystemsOwnCertificateCodesAreTerminalToo() {
        // -1201…-1204: the system named the certificate before any pin could
        // apply. No signal is needed and none is available on a probe whose
        // challenge never fired.
        for code in [URLError.Code.serverCertificateUntrusted, .serverCertificateHasBadDate,
                     .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid] {
            let error = map(code)
            XCTAssertEqual(error.errorCode, AppError.sttCustomCertUntrusted.errorCode,
                           "\(code) names the certificate")
            XCTAssertFalse(error.isRetryable, "\(code) is terminal")
        }
    }

    func testAColdTunnelStaysARetryableOutage() {
        // The regression the shared classifier exists to prevent: a generic
        // -1200 with neither signal set is a transient handshake failure, and
        // the probe's original retryable outcome is the right one.
        let error = map(.secureConnectionFailed, challengeRefused: true)
        XCTAssertEqual(error.errorCode, AppError.sttProviderUnreachable.errorCode)
        XCTAssertTrue(error.isRetryable)
    }

    func testOrdinaryTransportFailuresKeepTheProbesExistingOutcome() {
        for code in [URLError.Code.timedOut, .cannotConnectToHost, .notConnectedToInternet,
                     .cannotFindHost, .dnsLookupFailed, .badServerResponse, .cancelled] {
            XCTAssertEqual(map(code).errorCode, AppError.sttProviderUnreachable.errorCode,
                           "\(code) carries no certificate verdict — the probe reports the endpoint as unreachable, exactly as before.")
        }
    }
}
