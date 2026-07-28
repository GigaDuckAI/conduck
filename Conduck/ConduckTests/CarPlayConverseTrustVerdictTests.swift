// SPDX-License-Identifier: Apache-2.0

// Conduck
// CarPlayConverseTrustVerdictTests.swift
//
// Locks WHICH story the CarPlay converse lane tells a driver when a turn dies on
// the transport, which is the one thing they act on differently:
//
//   - "this device does not trust the gateway's certificate" → the fix is on the
//     SERVER, and it is terminal: no retry can succeed.
//   - "the pinned key disagreed with a chain the system DID trust" → the only
//     verdict that means the connection may be intercepted.
//   - anything else → not a certificate verdict at all, so the lane's own cancel
//     handling and retryable fallback stay in charge.
//
// THE GAP this closes: the lane consulted the classifier only when a per-task
// trust NOTE existed, and a note is recorded only on a PINNED challenge. On the
// RECOMMENDED unpinned posture (Tailscale Serve / Let's Encrypt) that left
// `-1201…-1204` — the codes where the SYSTEM itself named the certificate —
// falling through to the generic unreachable route, which tells the driver to
// check that a gateway that answered is running and invites a retry that cannot
// succeed. Every sibling lane (`BackgroundRemoteAgent.mapURLError`,
// `STTClient+Background`, `BackgroundFileTransfer.mapTransferError`,
// `WatchNetworkFailureCopy`) already had the arm.
//
// Asserted on `errorCode` (`AppError` is not Equatable) against the named case's
// own code, so a renumbering is `AppErrorCodeContractTests`' business.
//
// Pure seam over pure inputs: no session, no CarPlay scene, no App Group.

#if os(iOS)
import XCTest
@testable import Conduck

final class CarPlayConverseTrustVerdictTests: XCTestCase {

    /// `challengeRefused` is derived rather than passed: the delegate records a
    /// snapshot ONLY for a challenge it answered, so any verdict at all implies
    /// the refusal was ours — which is exactly what the -999 arm needs to know.
    private func verdict(_ code: URLError.Code,
                         systemTrustRejected: Bool = false,
                         pinRejected: Bool = false,
                         pinComparisonUnsupported: Bool = false) -> AppError? {
        CarPlayConverseUploader.certificateError(
            urlError: URLError(code),
            signals: .init(systemTrustRejected: systemTrustRejected,
                           challengeRefused: systemTrustRejected || pinRejected,
                           pinRejected: pinRejected,
                           pinComparisonUnsupported: pinComparisonUnsupported)
        )
    }

    // MARK: - The unpinned arm (the one that was missing)

    func testTheSystemNamingTheCertificateIsAVerdictWithNoNoteAtAll() {
        for code in [URLError.Code.serverCertificateUntrusted, .serverCertificateHasBadDate,
                     .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid] {
            XCTAssertEqual(verdict(code)?.errorCode,
                           AppError.remoteAgentCertUntrusted.errorCode,
                           "\(code) on an unpinned gateway — the recommended posture — must name the certificate instead of routing to the retryable unreachable copy.")
        }
    }

    func testTheUntrustedVerdictIsTerminal() {
        XCTAssertFalse(AppError.remoteAgentCertUntrusted.isRetryable,
                       "Nothing about a certificate this device refuses changes on a second attempt; offering one only delays the message that names the fix.")
        XCTAssertFalse(AppError.remoteAgentCertMismatch.isRetryable)
    }

    // MARK: - The noted (pinned) arms, unchanged

    func testANotedSystemRejectionIsAnUntrustedCertificate() {
        XCTAssertEqual(verdict(.cancelled, systemTrustRejected: true)?.errorCode,
                       AppError.remoteAgentCertUntrusted.errorCode,
                       "The fail-closed arm cancels a PINNED challenge over a chain the system rejected, and URLSession reports it as a bare -999.")
    }

    func testANotedPinRejectionKeepsTheMismatchVerdict() {
        XCTAssertEqual(verdict(.cancelled, pinRejected: true)?.errorCode,
                       AppError.remoteAgentCertMismatch.errorCode,
                       "A key that disagreed with a chain the system TRUSTED is the interception case; it is the only verdict that may say so.")
    }

    func testAKeyThatCannotBeFingerprintedIsNotAnInterceptionWarning() {
        // Reachability guard for the registry shape: the delegate stores the
        // WHOLE snapshot precisely so this verdict survives to the completion
        // callback. Flattened back to two loose Bools it silently becomes
        // `.remoteAgentCertMismatch`, and the driver is told their connection may
        // be intercepted over a certificate the system just accepted.
        XCTAssertEqual(verdict(.cancelled, pinRejected: true, pinComparisonUnsupported: true)?.errorCode,
                       AppError.remoteAgentCertKeyUnpinnable.errorCode,
                       "System trust passed and the digest could not be computed — nothing disagreed with anything.")
    }

    func testASystemRejectionOutranksAPinRejection() {
        XCTAssertEqual(verdict(.cancelled, systemTrustRejected: true, pinRejected: true)?.errorCode,
                       AppError.remoteAgentCertUntrusted.errorCode,
                       "Same precedence as every other lane — the untrusted chain is the truthful, actionable statement.")
    }

    // MARK: - Everything the lane must still handle itself

    func testABareCancelIsNotACertificateVerdict() {
        // The driver pressing End, and the post-force-quit resurrect, both arrive
        // as -999 with no note. Claiming a certificate here would strand the turn
        // on a certificate banner instead of the Retry chip.
        XCTAssertNil(verdict(.cancelled),
                     "An un-noted cancel is a cancelled turn, not a refused certificate.")
    }

    func testAColdTunnelStaysWithTheRetryableFallback() {
        XCTAssertNil(verdict(.secureConnectionFailed),
                     "A generic -1200 with no note is a transient handshake failure — the regression the shared classifier exists to prevent.")
        XCTAssertNil(verdict(.timedOut))
        XCTAssertNil(verdict(.notConnectedToInternet))
        XCTAssertNil(verdict(.cannotConnectToHost))
    }
}
#endif
