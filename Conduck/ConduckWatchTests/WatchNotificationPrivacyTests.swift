// Conduck — watchOS notification privacy tests.
//
// Locks the hostname chokepoint in `AppleRelayPendingQueue.notificationBody(for:fallback:)`.
//
// `AppError.errorDescription` interpolates the WRAPPED error's
// `localizedDescription` for exactly three cases — `.networkError`,
// `.decodingError`, `.unknown` — and a cert-class `URLError` embeds the server
// hostname in that text. Putting that string into a `UNNotificationContent.body`
// renders it on the wrist AND mirrors it to the paired iPhone's lock screen,
// where anyone standing nearby can read it without an unlock. The two iOS/CarPlay
// posters (`BackgroundRemoteAgent`, `CarPlayConverseUploader`) already collapse
// those three cases to fixed copy; this pins the same guarantee on the Watch.
//
// The test INJECTS a hostname into a synthetic cert error and first asserts the
// injection really does reach `errorDescription` — otherwise the leak check would
// pass vacuously the moment the copy or the localisation changed.
import XCTest
@testable import ConduckWatch_Watch_App

@MainActor
final class WatchNotificationPrivacyTests: XCTestCase {

    /// A hostname of the shape that actually matters: a tailnet name, which
    /// identifies the user's private network as well as their machine.
    private static let injectedHost = "gateway.tail9f2c.ts.net"

    private static let fallback = "fallback copy"

    /// Stands in for `URLError(.serverCertificateUntrusted)`, whose real
    /// `localizedDescription` names the host it expected. Built as an `NSError`
    /// so the hostname is deterministic rather than OS-copy dependent.
    private func hostBearingCertError() -> Error {
        NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorServerCertificateUntrusted,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "The certificate for this server is invalid. You might be connecting to a "
                    + "server that is pretending to be “\(Self.injectedHost)”."
            ]
        )
    }

    /// NEGATIVE CONTROL. If the wrapped error's text stops reaching
    /// `errorDescription`, the leak assertions below would pass for the wrong
    /// reason, so prove the hazard is real before proving it is contained.
    func testWrappedErrorTextReallyDoesReachErrorDescription() {
        let hazard = AppError.networkError(hostBearingCertError())
        XCTAssertTrue(
            hazard.errorDescription?.contains(Self.injectedHost) == true,
            "`AppError.networkError.errorDescription` no longer interpolates the wrapped error, so the leak checks in this file no longer prove anything. Re-point them at whatever case does interpolate, or delete them."
        )
    }

    /// The three interpolating cases must never reach a notification body.
    func testInterpolatingErrorCasesCollapseToFixedGatewayCopy() throws {
        let gatewayCopy = try XCTUnwrap(AppError.remoteAgentUnreachable.errorDescription)
        let hazards: [AppError] = [
            .networkError(hostBearingCertError()),
            .decodingError(hostBearingCertError()),
            .unknown(hostBearingCertError()),
        ]
        for hazard in hazards {
            let body = AppleRelayPendingQueue.notificationBody(for: hazard, fallback: Self.fallback)
            XCTAssertFalse(
                body.contains(Self.injectedHost),
                "Notification body leaked the gateway host for \(hazard). Cert-class URLErrors name the host in their description, and this body renders on the wrist and the paired iPhone's lock screen."
            )
            XCTAssertEqual(
                body, gatewayCopy,
                "Interpolating error cases must map to the fixed `remoteAgentUnreachable` copy, matching the two iOS posters."
            )
        }
    }

    /// …and every OTHER case must pass through UNCHANGED. This is the half that
    /// is easy to break while "fixing" the half above: the payloads this queue
    /// really posts are Apple on-device STT relay failures, and telling a user
    /// whose iPhone merely lacks a language model that Conduck "could not reach
    /// your personal AI gateway" would be wrong, not merely vague.
    func testNonInterpolatingCasesKeepTheirOwnCopy() throws {
        let gatewayCopy = try XCTUnwrap(AppError.remoteAgentUnreachable.errorDescription)
        let cases: [AppError] = [.appleSpeechModelNotInstalled, .audioProcessingFailed]
        for error in cases {
            let ownCopy = try XCTUnwrap(error.errorDescription)
            let body = AppleRelayPendingQueue.notificationBody(for: error, fallback: Self.fallback)
            XCTAssertEqual(
                body, ownCopy,
                "\(error) must keep its own deliberate copy — the chokepoint only rewrites the three interpolating cases."
            )
            XCTAssertNotEqual(
                body, gatewayCopy,
                "\(error) was rewritten to the gateway-unreachable copy. That is a copy regression: this queue reports on-device STT relay failures, not gateway failures."
            )
        }
    }
}
