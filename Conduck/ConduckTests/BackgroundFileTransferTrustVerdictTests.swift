// SPDX-License-Identifier: Apache-2.0

// Conduck
// BackgroundFileTransferTrustVerdictTests.swift
//
// Locks WHICH certificate story the file lane tells, which is the one thing a
// user acts on differently:
//
//   - "this device does not trust the certificate" → the fix is on the SERVER
//     (give it a certificate this device would trust), and it is terminal.
//   - "the pinned key disagreed with a chain the system DID trust" → the fix is
//     in Settings, and it is the ONLY message that warns the connection may be
//     intercepted.
//
// Both of the evaluator's refusals reach `didCompleteWithError` as a bare
// `.cancelled` (-999), so the code alone cannot separate them — or separate
// either from a benign task cancellation. The per-task trust NOTE recorded at
// challenge time is what does, and `trustError` is where it is read. Folding
// -999 in with the explicit certificate codes instead sent every real pin
// mismatch — a rotated key, or interception using a publicly-trusted
// certificate — off to obtain a trusted certificate they already had, and threw
// away the interception warning.
//
// Asserted on `errorCode` (`AppError` is not Equatable) against the named case's
// own code, so a renumbering is `AppErrorCodeContractTests`' business, not this
// file's.
//
// Pure seams over pure inputs: no live server, no session, no App Group.

import XCTest
@testable import Conduck

final class BackgroundFileTransferTrustVerdictTests: XCTestCase {

    /// One recorded attempt snapshot. `challengeRefused` is always true here:
    /// the delegate records a snapshot ONLY for a challenge it answered, which is
    /// exactly what makes the resulting -999 attributable to us.
    private func noted(systemTrustRejected: Bool = false,
                       pinRejected: Bool = false,
                       pinComparisonUnsupported: Bool = false)
    -> RemoteAgentTrustEvaluator.AttemptTrustSignals {
        .init(systemTrustRejected: systemTrustRejected,
              challengeRefused: true,
              pinRejected: pinRejected,
              pinComparisonUnsupported: pinComparisonUnsupported)
    }

    // MARK: - trustError: the note decides, not the code

    func testPinRejectionOnACancelIsAMismatchNotAnUntrustedCertificate() {
        // -999 is the ONLY code the pin-mismatch arm can produce: the evaluator
        // compared a digest against a chain the system DID trust, disagreed, and
        // cancelled the challenge.
        XCTAssertEqual(
            BackgroundFileTransfer.trustError(urlError: URLError(.cancelled),
                                              signals: noted(systemTrustRejected: false, pinRejected: true))?.errorCode,
            AppError.fileTransferCertMismatch.errorCode,
            "A confirmed pin mismatch must keep its own verdict — it is the only one that says the connection may be intercepted, and the remedy it names is a pin the user can actually edit.")
    }

    func testSystemTrustRejectionOnACancelIsAnUntrustedCertificate() {
        XCTAssertEqual(
            BackgroundFileTransfer.trustError(urlError: URLError(.cancelled),
                                              signals: noted(systemTrustRejected: true, pinRejected: false))?.errorCode,
            AppError.fileTransferCertUntrusted.errorCode,
            "The fail-closed arm cancels a PINNED challenge over a chain the system rejected. The certificate is the problem; the fingerprint never was.")
    }

    func testSystemTrustRejectionOutranksAPinRejection() {
        XCTAssertEqual(
            BackgroundFileTransfer.trustError(urlError: URLError(.cancelled),
                                              signals: noted(systemTrustRejected: true, pinRejected: true))?.errorCode,
            AppError.fileTransferCertUntrusted.errorCode,
            "Same precedence as every other lane: an untrusted chain is the truthful, actionable statement, so it outranks a key mismatch when both are recorded.")
    }

    func testAnUnfingerprintableKeyIsItsOwnVerdict() {
        // Reachable only because the registry stores the whole snapshot: the
        // loose-Bool form drops `pinComparisonUnsupported`, and this file lane
        // then warns of interception over a chain the system just accepted.
        XCTAssertEqual(
            BackgroundFileTransfer.trustError(
                urlError: URLError(.cancelled),
                signals: noted(pinRejected: true, pinComparisonUnsupported: true))?.errorCode,
            AppError.fileTransferCertKeyUnpinnable.errorCode,
            "System trust passed and no digest was ever computed — nothing disagreed, so nothing may imply interception.")
    }

    func testNoNoteYieldsNoCertificateVerdict() {
        for code in [URLError.Code.cancelled, .secureConnectionFailed, .timedOut] {
            XCTAssertNil(
                BackgroundFileTransfer.trustError(urlError: URLError(code),
                                              signals: .empty),
                "\(code) with neither note is not a certificate verdict — inventing one here is exactly the false alarm the shared classifier exists to prevent.")
        }
    }

    func testTheNoteAlsoDecidesOnTheGenericAndSpecificCodes() {
        // Which code URLSession picks for one refusal is a CFNetwork detail, so
        // the verdict must not change with it.
        for code in [URLError.Code.cancelled, .secureConnectionFailed, .serverCertificateUntrusted] {
            XCTAssertEqual(
                BackgroundFileTransfer.trustError(urlError: URLError(code),
                                              signals: noted(systemTrustRejected: true, pinRejected: false))?.errorCode,
                AppError.fileTransferCertUntrusted.errorCode,
                "\(code) + a system-trust rejection → untrusted certificate")
            XCTAssertEqual(
                BackgroundFileTransfer.trustError(urlError: URLError(code),
                                              signals: noted(systemTrustRejected: false, pinRejected: true))?.errorCode,
                AppError.fileTransferCertMismatch.errorCode,
                "\(code) + a confirmed pin rejection → certificate mismatch")
        }
    }

    // MARK: - mapTransferError: no trust guessing on the caller's side

    func testABareCancelIsNotACertificateProblem() {
        // THE REGRESSION: `.cancelled` used to be folded in with the explicit
        // certificate codes. Every un-noted -999 — a parent-task cancellation, a
        // session invalidation — was reported as a certificate this device does
        // not trust, and every NOTED one lost the mismatch verdict.
        XCTAssertEqual(
            BackgroundFileTransfer.mapTransferError(URLError(.cancelled),
                                                    fallback: .fileTransferUploadFailed).errorCode,
            AppError.fileTransferUploadFailed.errorCode,
            "An un-noted cancel is a cancelled transfer, not a refused certificate.")
        XCTAssertEqual(
            BackgroundFileTransfer.mapTransferError(URLError(.cancelled),
                                                    fallback: .fileTransferServerError).errorCode,
            AppError.fileTransferServerError.errorCode,
            "The download direction takes its own fallback, same as every other unmapped code.")
    }

    func testAResolvedCertificateVerdictPassesThroughUnchanged() {
        // `didCompleteWithError` resolves a noted refusal into an AppError
        // BEFORE the continuation throws, because that is the last place the
        // task — and therefore its notes — is reachable. This mapper runs on the
        // caller's side and must not second-guess it.
        for resolved: AppError in [.fileTransferCertMismatch, .fileTransferCertUntrusted] {
            XCTAssertEqual(
                BackgroundFileTransfer.mapTransferError(resolved,
                                                        fallback: .fileTransferUploadFailed).errorCode,
                resolved.errorCode,
                "A resolved certificate verdict must survive the trip across the continuation.")
        }
    }

    func testTheSystemNamingTheCertificateStillMeansUntrusted() {
        // Reaching the mapper on one of these means no challenge recorded a note
        // (a reused connection, or a rejection made before any challenge fired),
        // so nothing compared a pinned digest: "untrusted" is the whole of what
        // is known, and it is right whether or not a pin exists.
        for code in [URLError.Code.serverCertificateUntrusted, .serverCertificateHasBadDate,
                     .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid] {
            XCTAssertEqual(
                BackgroundFileTransfer.mapTransferError(URLError(code),
                                                        fallback: .fileTransferUploadFailed).errorCode,
                AppError.fileTransferCertUntrusted.errorCode,
                "\(code) names the certificate — never 'check your file-server is running'.")
        }
    }

    func testAColdTunnelStaysReachableRatherThanACertificateFailure() {
        XCTAssertEqual(
            BackgroundFileTransfer.mapTransferError(URLError(.secureConnectionFailed),
                                                    fallback: .fileTransferUploadFailed).errorCode,
            AppError.fileTransferUnreachable.errorCode,
            "A generic -1200 with no note is a transient handshake failure. Calling it a certificate problem is the regression the shared classifier exists to prevent.")
    }

    // MARK: - Only a PINNED challenge may leave a note behind

    func testAnUnpinnedChallengeResolvesNoPinAndSoCanRecordNoNote() {
        // The rule the guard in `answerTaskTrustChallenge` enforces, at the one
        // seam that is pure: with no pin the challenge is default-handled, no
        // evaluator is built, and no note can be written. That matters because
        // the evaluator's `SecTrustEvaluateWithError` call is ADVISORY — it also
        // fails when evaluation could not COMPLETE — and on the unpinned path it
        // does not cancel, so the system may accept the chain and the transfer
        // succeed with a note on file. The user cancelling a staged upload later
        // would then be told their file server's certificate is untrusted.
        XCTAssertNil(BackgroundFileTransfer.effectiveTaskPin(taskDescription: nil, hostPin: nil),
                     "Neither source has a pin → unpinned lane → default ATS.")
        XCTAssertNil(BackgroundFileTransfer.effectiveTaskPin(taskDescription: nil, hostPin: ""),
                     "An EMPTY host pin is 'no pin', not 'a pin that matches nothing' — otherwise an evaluator gets built for a lane the user never pinned.")
        XCTAssertNil(BackgroundFileTransfer.effectiveTaskPin(taskDescription: "not-json", hostPin: nil),
                     "An undecodable envelope carries no pin.")
    }

    func testTheTaskEnvelopeOutranksTheHostLookupWhenBothCarryAPin() {
        let envelope = FileTransferBackgroundMetadata(
            storedKey: "abc12345__notes.pdf",
            refSuffix: "",
            direction: .upload,
            pinnedFingerprintHex: "aa").encoded()
        XCTAssertEqual(
            BackgroundFileTransfer.effectiveTaskPin(taskDescription: envelope, hostPin: "bb"),
            "aa",
            "The pin stamped at enqueue is the one the user's lane was configured with; the host lookup is only the fallback for an envelope that carries none.")
        XCTAssertEqual(
            BackgroundFileTransfer.effectiveTaskPin(taskDescription: nil, hostPin: "bb"),
            "bb",
            "With no envelope pin the host lookup still pins the challenge — a note stays possible exactly when a pin exists.")
    }

    func testTheCertificateVerdictsAreTerminalAndTheCancelIsNot() {
        // The two verdicts are refusals the user has to go fix; retrying only
        // delays the message that names the fix.
        XCTAssertFalse(AppError.fileTransferCertUntrusted.isRetryable)
        XCTAssertFalse(AppError.fileTransferCertMismatch.isRetryable)
        XCTAssertTrue(AppError.fileTransferUploadFailed.isRetryable,
                      "A cancelled or incomplete transfer IS worth another attempt — which is why it must not be labelled a certificate refusal.")
    }
}
