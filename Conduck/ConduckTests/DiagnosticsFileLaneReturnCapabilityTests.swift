// SPDX-License-Identifier: Apache-2.0

// Conduck
// DiagnosticsFileLaneReturnCapabilityTests.swift
//
// The Diagnostics screen's half of the file-lane return-capability model: what a
// staged Test Connection run from Settings ▸ Diagnostics COMMITS, and what the
// file-server badge on that screen SAYS afterwards.
//
// Two bugs are pinned here, and both were invisible to every test that exercised
// `FileServerClient` alone — the client was right in both cases, and the screen
// around it was wrong:
//   • THE SECOND COMMIT PATH. Diagnostics ran the identical staged test as the
//     gateway's File transfer page but spelled its own persistence, and that
//     copy wrote readiness and folder capability while dropping the listing
//     verdict. A user who tested a plain nginx-DAV server here got a proven
//     upload-only lane that kept a green badge everywhere while dispatch
//     silently stopped naming output folders. Both screens now commit through
//     `SettingsManager.commitStagedFileTransferResult`, and the first test
//     drives both to the same durable state to keep it that way.
//   • THE SESSION-SCOPED BADGE. The badge's "uploads only" override read this
//     session's test result, which is written only by a run in this process and
//     dropped when a lane's signature moves — so a lane whose upload-only
//     verdict was already PERSISTED showed green here while the gateway page
//     correctly showed amber.
//
// Isolation: the runner reads the `SettingsManager.shared` singleton, so the
// process-global in-memory stores are wiped on both edges. The staged test is
// driven against a `MockURLProtocol` session through the runner's own test seam
// — no network, no real file server.

import XCTest
@testable import Conduck

@MainActor
final class DiagnosticsFileLaneReturnCapabilityTests: XCTestCase {

    private let fileServerURL = URL(string: "https://files.example.test")!

    override func setUp() async throws {
        try await super.setUp()
        wipe()
    }

    override func tearDown() async throws {
        wipe()
        MockURLProtocol.requestHandler = nil
        try await super.tearDown()
    }

    /// Both stores AND the process-wide witness breaker: the staged test seeds
    /// the breaker, so a case that parks a lane would make a later case's probe
    /// never happen.
    private func wipe() {
        TestStores.removeAll()
        BackgroundFileTransfer.FileLaneWitnessBreaker.shared.resetAll()
    }

    // MARK: - Fixtures

    /// Give `ref` a file lane that `fileTransferSnapshot` will describe. Skips
    /// the case where the secret store refuses a write, since without a stored
    /// credential there is no snapshot and the staged test would never run.
    private func configureLane(_ ref: RemoteAgentRef) async throws {
        try? await SettingsManager.shared.setFileServerCredential(
            String(repeating: "a", count: 32), for: ref)
        await SettingsManager.shared.setFileServerURL(fileServerURL, for: ref)
        guard await SettingsManager.shared.fileTransferSnapshot(for: ref) != nil else {
            throw XCTSkip("No file-server credential could be stored in this host.")
        }
    }

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// Script a whole staged run: uploads always succeed (PUT → GET byte-echo →
    /// DELETE), and the caller decides what the listing stage's PROPFINDs answer
    /// — the only stage these tests are about.
    private func scriptStagedTest(propfind: @escaping @Sendable (URLRequest) -> Int) {
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            let ok = { (status: Int, body: Data) in
                (HTTPURLResponse(url: url, statusCode: status,
                                 httpVersion: "HTTP/1.1", headerFields: nil)!, body)
            }
            switch request.httpMethod {
            case "PUT": return ok(201, Data())
            case "GET":
                // The nested capability probe reads back from its own
                // `__conduck_probe_<8hex>__/` collection; the flat read stage
                // fetches the probe file at the root.
                let nested = url.absoluteString.contains("__/")
                return ok(200, Data((nested ? "conduck-nested-probe" : "conduck-probe").utf8))
            case "DELETE": return ok(204, Data())
            case "PROPFIND": return ok(propfind(request), Data())
            default: return ok(200, Data())
            }
        }
    }

    /// A server that lists perfectly: `207` for the collection, `404` for the
    /// negative control it must be able to miss on.
    private func scriptListingCapableServer() {
        scriptStagedTest(propfind: { request in
            request.url!.absoluteString.contains("__conduck_absent_") ? 404 : 207
        })
    }

    /// Everything the durable stores say about one lane after a staged test —
    /// compared as a triple, so a path that agrees on two of the three and drops
    /// the one that decides the return direction still fails.
    private struct DurableLane: Equatable {
        var available: Bool?
        var folderCapable: Bool?
        var returnCapable: Bool?
    }

    private func durableLane(_ ref: RemoteAgentRef) -> DurableLane {
        let defaults = TestStores.defaults
        return DurableLane(
            available: defaults.object(forKey: Constants.fileTransferAvailableKey(for: ref)) as? Bool,
            folderCapable: defaults.object(forKey: Constants.fileServerFolderCapableKey(for: ref)) as? Bool,
            returnCapable: defaults.object(forKey: Constants.fileServerReturnCapableKey(for: ref)) as? Bool
        )
    }

    // MARK: - One staged test, one durable conclusion

    /// THE DRIFT. Two screens offer the same staged test; they must reach the
    /// same stored answer. The Diagnostics arm runs the screen's real entry
    /// point end to end; the Settings arm runs the client and makes the one
    /// commit `SettingsViewModel.runFileTransferTest` makes. Before the repair
    /// the two disagreed on exactly one field — the listing verdict — which is
    /// the whole return direction.
    func testADiagnosticsInitiatedTestPersistsTheSameVerdictTheSettingsPathDoes() async throws {
        let viaDiagnostics = RemoteAgentRef.custom(UUID())
        let viaSettings = RemoteAgentRef.custom(UUID())
        try await configureLane(viaDiagnostics)
        try await configureLane(viaSettings)
        // Plain nginx with `dav_methods PUT DELETE`: uploads are perfect, the
        // listing method is not implemented.
        scriptStagedTest(propfind: { _ in 405 })

        let diagnosticsSession = makeMockSession()
        let runner = DiagnosticsRunner()
        await runner.runFileTransferTest(for: viaDiagnostics, session: diagnosticsSession)
        diagnosticsSession.invalidateAndCancel()

        let settingsSession = makeMockSession()
        let snapshot = await SettingsManager.shared.fileTransferSnapshot(for: viaSettings)
        let result = await FileServerClient.runConnectionTest(
            snapshot: try XCTUnwrap(snapshot), session: settingsSession)
        settingsSession.invalidateAndCancel()
        await SettingsManager.shared.commitStagedFileTransferResult(result, for: viaSettings)

        XCTAssertEqual(durableLane(viaDiagnostics), durableLane(viaSettings),
                       "the same staged run must leave the same durable state whichever screen ran it")
        XCTAssertEqual(durableLane(viaDiagnostics).returnCapable, false,
                       "the listing verdict is the field the Diagnostics copy dropped — without it "
                       + "the lane keeps a green badge everywhere while dispatch stops naming folders")
        XCTAssertEqual(durableLane(viaDiagnostics).available, true,
                       "and the upload half stays proven: a lane that cannot list is not a failed lane")
    }

    /// The runner's own published mirror follows the commit, so the badge is
    /// right the instant the test finishes and not only after the next rebuild.
    func testADiagnosticsTestUpdatesTheScreensUploadOnlyMirror() async throws {
        let ref = RemoteAgentRef.custom(UUID())
        try await configureLane(ref)
        scriptStagedTest(propfind: { _ in 405 })

        let session = makeMockSession()
        let runner = DiagnosticsRunner()
        await runner.runFileTransferTest(for: ref, session: session)
        session.invalidateAndCancel()

        XCTAssertTrue(runner.fileLaneUploadOnly.contains(ref))
    }

    /// A listing stage that settled NOTHING must not disturb a verdict already
    /// proven against this same tuple — the flag moves on proof in both
    /// directions, and a `502` from a reverse proxy is proof of neither.
    func testAnUnsettledListingStageLeavesAProvenVerdictAlone() async throws {
        let ref = RemoteAgentRef.custom(UUID())
        try await configureLane(ref)
        await SettingsManager.shared.commitFileTransferVerdict(
            available: true, folderCapable: true, returnCapable: .set(false), for: ref)
        scriptStagedTest(propfind: { _ in 502 })

        let session = makeMockSession()
        let runner = DiagnosticsRunner()
        await runner.runFileTransferTest(for: ref, session: session)
        session.invalidateAndCancel()

        XCTAssertEqual(durableLane(ref).returnCapable, false,
                       "an inconclusive probe may not widen a proven narrowing")
    }

    /// And the other direction: a server that answers both PROPFINDs correctly
    /// clears an earlier upload-only verdict, because the app widens on proof
    /// too — a user who enabled listing on their server must not have to keep
    /// reading that it is impossible.
    func testAPassingListingStageClearsAnEarlierUploadOnlyVerdict() async throws {
        let ref = RemoteAgentRef.custom(UUID())
        try await configureLane(ref)
        await SettingsManager.shared.commitFileTransferVerdict(
            available: true, folderCapable: true, returnCapable: .set(false), for: ref)
        scriptListingCapableServer()

        let session = makeMockSession()
        let runner = DiagnosticsRunner()
        await runner.runFileTransferTest(for: ref, session: session)
        session.invalidateAndCancel()

        XCTAssertEqual(durableLane(ref).returnCapable, true)
        XCTAssertFalse(runner.fileLaneUploadOnly.contains(ref))
    }

    // MARK: - The badge derives from the PERSISTED verdict

    /// THE BADGE BUG, at its smallest: a persisted upload-only lane with NO live
    /// result — every relaunch, and every device that did not run the test
    /// itself — showed the green seal.
    func testAPersistedUploadOnlyLaneReadsAmberWithNoLiveResult() {
        XCTAssertEqual(
            DiagnosticsRunner.fileLaneReturnCaveat(
                badge: .verified, persistedUploadOnly: true, liveResult: nil),
            .uploadsOnly,
            "the stored verdict is the one that outlives the run that took it")
    }

    /// The live result still earns its place, but only for the thing
    /// persistence deliberately cannot express: "we tried this run and could not
    /// tell". A stored key cannot say that — absent means never measured.
    func testAnUnverifiedLiveResultDowngradesAnOtherwiseCapableLane() {
        let unverified = FileTransferTestResult(
            reachedStage: .listing, success: true, failure: nil,
            returnVerification: .unverified(.fileTransferServerError))

        XCTAssertEqual(
            DiagnosticsRunner.fileLaneReturnCaveat(
                badge: .verified, persistedUploadOnly: false, liveResult: unverified),
            .returnUnchecked)
    }

    /// A live upload-only result narrows ahead of the mirror: the commit and the
    /// mirror refresh are two awaits apart, and the just-finished test is
    /// authoritative for the moment in between.
    func testALiveUploadOnlyResultNarrowsBeforeTheMirrorCatchesUp() {
        let uploadOnly = FileTransferTestResult(
            reachedStage: .listing, success: true, failure: nil,
            returnVerification: .methodUnavailable)

        XCTAssertEqual(
            DiagnosticsRunner.fileLaneReturnCaveat(
                badge: .verified, persistedUploadOnly: false, liveResult: uploadOnly),
            .uploadsOnly)
    }

    /// Nothing to qualify: a fully capable lane keeps the green seal it earned.
    func testACapableLaneKeepsItsGreenSeal() {
        let verified = FileTransferTestResult(
            reachedStage: .listing, success: true, failure: nil,
            returnVerification: .verified)

        XCTAssertNil(DiagnosticsRunner.fileLaneReturnCaveat(
            badge: .verified, persistedUploadOnly: false, liveResult: verified))
        XCTAssertNil(DiagnosticsRunner.fileLaneReturnCaveat(
            badge: .verified, persistedUploadOnly: false, liveResult: nil))
    }

    /// The caveat only ever qualifies a green badge. A failed or untested lane
    /// already says something truer, and "uploads only" over a lane that just
    /// failed its write test would be a claim nobody earned.
    func testANonVerifiedBadgeIsNeverOverridden() {
        for badge: FileLaneState.Badge in [.failed, .unconfirmed, .testing, .configuredNotTested, .notSetUp] {
            XCTAssertNil(
                DiagnosticsRunner.fileLaneReturnCaveat(
                    badge: badge, persistedUploadOnly: true, liveResult: nil),
                "\(badge) must keep its own meaning")
        }
    }

    /// End to end on the screen's own state: a lane whose upload-only verdict was
    /// proven in an EARLIER session (nothing in `fileTransferResults`) hydrates
    /// into the mirror on open and renders amber.
    func testAnOpenedScreenHydratesAPersistedUploadOnlyLane() async throws {
        let ref = RemoteAgentRef.builtin(.openclaw)
        // Keyless gateway: a configured gateway is what makes the file lane fan
        // out at all, and `.none` needs no Keychain token.
        await SettingsManager.shared.setRemoteAgentAuthScheme(.none, for: ref)
        await SettingsManager.shared.setRemoteAgentURL(
            URL(string: "https://openclaw.example.test")!, for: ref)
        try await configureLane(ref)
        // The state a passing upload-only test left behind, last session.
        await SettingsManager.shared.commitFileTransferVerdict(
            available: true, folderCapable: true, returnCapable: .set(false), for: ref)

        let runner = DiagnosticsRunner()
        await runner.runAutoReads()

        let lane = try XCTUnwrap(runner.fileLanes.first { $0.ref == ref })
        XCTAssertEqual(lane.badge, .verified, "precondition: the model still calls this lane a pass")
        XCTAssertNil(runner.fileTransferResults[ref], "precondition: no test ran in THIS session")
        XCTAssertTrue(runner.fileLaneUploadOnly.contains(ref))
        XCTAssertEqual(runner.fileLaneReturnCaveat(for: lane), .uploadsOnly,
                       "the amber the gateway's File transfer page shows for the same lane")
    }
}
