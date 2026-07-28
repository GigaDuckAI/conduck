// SPDX-License-Identifier: Apache-2.0

// Conduck
// FileServerTrustRefusalTests.swift
//
// Locks that a certificate refusal ANYWHERE in the staged file-transfer Test
// Connection reaches the user as a certificate refusal.
//
// Two places used to swallow one. The flat read-back's `catch` hardcoded
// `.fileTransferUnreachable` on the reasoning that the PUT had already reached
// the host, so a failure on the very next GET must be connectivity — true for a
// dropped connection, false for a refused certificate, and the hardcode could
// not tell them apart. Worse, the nested folder probe collapsed every
// non-`.capable` outcome to `folderCapable = false` while the overall test still
// returned SUCCESS: a device refusing the server's certificate produced a green
// Test Connection with a quietly narrowed feature. That is the failure mode that
// looks like success, on the one screen whose entire job is to say whether the
// lane works.
//
// Each case below is paired with its cold-tunnel control — the same transport
// failure with NO trust verdict must still read as unreachable, because a
// generic `-1200` on a waking Tailscale tunnel is far commoner than a real
// rejection and must stay retryable.
//
// Deterministic + headless: `MockURLProtocol` transport, verdicts supplied
// through the probe's signals seam (a mocked transport raises no server-trust
// challenge, so there is no real evaluator to read), no network, no Keychain.
//
// Privacy: synthetic fixtures only; no real credentials / URLs / filenames.

import XCTest
@testable import Conduck

final class FileServerTrustRefusalTests: XCTestCase {

    private var session: URLSession!

    /// The nested capability probe is the only traffic under `__conduck_probe__/`;
    /// the flat stages write `__conduck_probe_<tag>.txt` at the root.
    private static let nestedDirMarker = "__conduck_probe__/"

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        session.invalidateAndCancel()
        session = nil
        super.tearDown()
    }

    // MARK: - The nested capability probe

    func testACertificateRefusalInTheNestedProbeFailsTheTestInsteadOfNarrowingFolderCapable() async {
        // Flat reachability → auth → write → read all pass. The nested probe then
        // meets a refused certificate. The old shape returned `success: true` with
        // `folderCapable: false`: a trust refusal absorbed into a capability flag,
        // reported to the user as a working file lane.
        MockURLProtocol.requestHandler = { request in
            if Self.isNested(request) { throw URLError(.secureConnectionFailed) }
            return try Self.flatStagesPass(request)
        }

        let result = await FileServerClient.runConnectionTest(
            snapshot: makeSnapshot(),
            session: session,
            signalsOverride: { Self.systemRejected }
        )

        XCTAssertFalse(result.success,
                       "A refused certificate must FAIL the connection test. Passing it and narrowing a feature flag tells the user their file lane is ready over a connection this device will not make.")
        XCTAssertEqual(result.failure?.errorCode, AppError.fileTransferCertUntrusted.errorCode,
                       "The user must be told the certificate is the problem — the one cause whose remedy is on the server.")
        XCTAssertEqual(result.reachedStage, .reachability,
                       "A certificate refusal is a TLS-layer verdict about the connection, so it lands on the row every other certificate refusal in this lane lands on. Marking the read row failed would put a red X on a stage that visibly succeeded.")
        XCTAssertTrue(result.folderCapable,
                      "The capability flag keeps its init default on EVERY failure path — a refused connection proves nothing about folders, and only a definitive nested-PUT rejection may narrow it. Neither caller persists it unless the test passed.")
    }

    func testAPinMismatchInTheNestedProbeKeepsItsOwnClassRatherThanCollapsing() async {
        // The three certificate classes must survive the nested probe intact. A
        // mismatch on a chain the system TRUSTED is the only one that means the
        // connection may be intercepted; reporting it as "untrusted certificate"
        // would send the user to obtain a certificate they already have.
        MockURLProtocol.requestHandler = { request in
            if Self.isNested(request) { throw URLError(.secureConnectionFailed) }
            return try Self.flatStagesPass(request)
        }

        let result = await FileServerClient.runConnectionTest(
            snapshot: makeSnapshot(),
            session: session,
            signalsOverride: { Self.pinDisagreed }
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.failure?.errorCode, AppError.fileTransferCertMismatch.errorCode,
                       "A pin that disagreed with a system-trusted chain keeps its own code all the way through the nested probe.")
    }

    func testAnUnfingerprintableKeyInTheNestedProbeIsNotReportedAsAMismatch() async {
        MockURLProtocol.requestHandler = { request in
            if Self.isNested(request) { throw URLError(.secureConnectionFailed) }
            return try Self.flatStagesPass(request)
        }

        let result = await FileServerClient.runConnectionTest(
            snapshot: makeSnapshot(),
            session: session,
            signalsOverride: { Self.pinNotComputable }
        )

        XCTAssertEqual(result.failure?.errorCode, AppError.fileTransferCertKeyUnpinnable.errorCode,
                       "System trust PASSED and nothing was compared, so this user's remedy is the key type — not an interception warning over a certificate that is fine.")
        XCTAssertNotEqual(result.failure?.errorCode, AppError.fileTransferCertMismatch.errorCode)
    }

    func testANestedProbeTransportFailureWithNoTrustVerdictStillOnlyNarrowsFolderCapable() async {
        // THE CONTROL. Without it the fix above could simply be "any nested
        // transport failure fails the test", which would turn every flaky moment
        // on a healthy server into a failed connection test.
        MockURLProtocol.requestHandler = { request in
            if Self.isNested(request) { throw URLError(.secureConnectionFailed) }
            return try Self.flatStagesPass(request)
        }

        let result = await FileServerClient.runConnectionTest(
            snapshot: makeSnapshot(),
            session: session,
            signalsOverride: { .empty }
        )

        XCTAssertTrue(result.success,
                      "A cold tunnel during the OPTIONAL nested probe is not a reason to fail a connection test whose four real stages passed.")
        XCTAssertEqual(result.reachedStage, .read)
        XCTAssertNil(result.failure)
        XCTAssertFalse(result.folderCapable,
                       "It still narrows the capability — flat keys work fine, and the launch-time re-probe retries the upgrade later.")
    }

    // MARK: - The flat read-back stage

    func testACertificateRefusalOnTheReadBackIsNotReportedAsUnreachable() async {
        // The PUT lands, the connection is re-established for the GET, and the
        // new handshake is refused. Hardcoding unreachable here printed "check
        // your file-server is running" for a host that answered.
        MockURLProtocol.requestHandler = { request in
            if request.httpMethod == "GET" { throw URLError(.secureConnectionFailed) }
            return (Self.http(request, 201), Data())
        }

        let result = await FileServerClient.runConnectionTest(
            snapshot: makeSnapshot(),
            session: session,
            signalsOverride: { Self.systemRejected }
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.reachedStage, .read)
        XCTAssertEqual(result.failure?.errorCode, AppError.fileTransferCertUntrusted.errorCode,
                       "The read stage is entitled to its own transport verdict. Reporting unreachable sends the user to check a server that is running and answering.")
    }

    func testAPinMismatchOnTheReadBackKeepsTheInterceptionSignal() async {
        MockURLProtocol.requestHandler = { request in
            if request.httpMethod == "GET" { throw URLError(.secureConnectionFailed) }
            return (Self.http(request, 201), Data())
        }

        let result = await FileServerClient.runConnectionTest(
            snapshot: makeSnapshot(),
            session: session,
            signalsOverride: { Self.pinDisagreed }
        )

        XCTAssertEqual(result.failure?.errorCode, AppError.fileTransferCertMismatch.errorCode,
                       "Folding this into unreachable discards the one signal that says the connection may be intercepted.")
    }

    func testAReadBackTransportFailureWithNoTrustVerdictStaysUnreachable() async {
        // THE CONTROL for the read stage: the original comment's case — the
        // connection genuinely dropped between the PUT and the GET — must still
        // read as connectivity.
        MockURLProtocol.requestHandler = { request in
            if request.httpMethod == "GET" { throw URLError(.networkConnectionLost) }
            return (Self.http(request, 201), Data())
        }

        let result = await FileServerClient.runConnectionTest(
            snapshot: makeSnapshot(),
            session: session,
            signalsOverride: { .empty }
        )

        XCTAssertEqual(result.reachedStage, .read)
        XCTAssertEqual(result.failure?.errorCode, AppError.fileTransferUnreachable.errorCode,
                       "No certificate verdict → the read-stage failure is connectivity, exactly as before.")
    }

    // MARK: - The probe itself, directly

    func testProbeFolderCapabilityReportsARefusalRatherThanIndeterminate() async {
        // `indeterminate` and `certificateRefused` carry opposite instructions —
        // "retry later" vs "no later probe will do better" — and the silent
        // launch-time refresher has to be able to tell them apart to avoid
        // stamping a definitive revision on the strength of a certificate problem.
        MockURLProtocol.requestHandler = { _ in throw URLError(.secureConnectionFailed) }

        let outcome = await FileServerClient.probeFolderCapability(
            snapshot: makeSnapshot(),
            session: session,
            signals: { Self.systemRejected }
        )

        XCTAssertEqual(outcome, .certificateRefused(.untrusted))
    }

    func testProbeFolderCapabilityStaysIndeterminateWithoutATrustVerdict() async {
        MockURLProtocol.requestHandler = { _ in throw URLError(.secureConnectionFailed) }

        let outcome = await FileServerClient.probeFolderCapability(
            snapshot: makeSnapshot(),
            session: session,
            signals: { .empty }
        )

        XCTAssertEqual(outcome, .indeterminate,
                       "A cold tunnel is retryable; only a positive trust verdict makes a refusal.")
    }

    // MARK: - Fixtures

    private func makeSnapshot() -> SettingsManager.FileTransferSnapshot {
        SettingsManager.FileTransferSnapshot(
            baseURL: URL(string: "https://fileserver.example.test")!,
            username: Constants.fileServerUsername,
            credential: "deadbeefdeadbeefdeadbeefdeadbeef",
            certFingerprintHex: "aabbcc",
            available: false,
            folderCapable: true
        )
    }

    private static func http(_ request: URLRequest, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    private static func isNested(_ request: URLRequest) -> Bool {
        (request.url?.absoluteString ?? "").contains(nestedDirMarker)
    }

    /// Every FLAT stage answers the way a healthy rclone-shaped server does,
    /// including the byte-echo the read stage compares against.
    private static func flatStagesPass(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        switch request.httpMethod {
        case "GET": return (http(request, 200), Data("conduck-probe".utf8))
        default: return (http(request, 201), Data())
        }
    }

    /// This device does not trust the chain (the verdict `decide` records on
    /// EVERY challenge, pinned or not).
    private static let systemRejected = RemoteAgentTrustEvaluator.AttemptTrustSignals(
        systemTrustRejected: true, challengeRefused: false,
        pinRejected: false, pinComparisonUnsupported: false)

    /// System trust PASSED and the pinned key disagreed — the interception shape.
    private static let pinDisagreed = RemoteAgentTrustEvaluator.AttemptTrustSignals(
        systemTrustRejected: false, challengeRefused: true,
        pinRejected: true, pinComparisonUnsupported: false)

    /// System trust PASSED and no digest could be computed for the leaf's key.
    private static let pinNotComputable = RemoteAgentTrustEvaluator.AttemptTrustSignals(
        systemTrustRejected: false, challengeRefused: true,
        pinRejected: true, pinComparisonUnsupported: true)
}
