// SPDX-License-Identifier: Apache-2.0

// Diagnostics checks setup. Saved captures are consulted only for an explicitly
// requested support report, and never create checks or change its health verdict.
// The real queue lives in an isolated directory with in-memory defaults; provider
// operations use the runner's existing seam, so these cases send nothing.

import XCTest
@testable import Conduck

@MainActor
final class DiagnosticsSetupBoundaryTests: XCTestCase {
    private var container: URL!
    private var retryStore: PendingRetryStore!

    override func setUp() async throws {
        try await super.setUp()
        TestStores.removeAll()
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-setup-boundary-\(UUID().uuidString)", isDirectory: true)
        retryStore = PendingRetryStore(containerURL: container, defaults: InMemoryDefaultsStore())
        let ref = RemoteAgentRef.builtin(.openclaw)
        await SettingsManager.shared.setRemoteAgentURL(URL(string: "https://gateway.example.test")!, for: ref)
        await SettingsManager.shared.setRemoteAgentAuthScheme(.none, for: ref)
        await SettingsManager.shared.setDefaultRemoteAgentRef(ref)
    }

    override func tearDown() async throws {
        if let container { try? FileManager.default.removeItem(at: container) }
        retryStore = nil
        container = nil
        TestStores.removeAll()
        try await super.tearDown()
    }

    func testOpeningRefreshingAndTestingSetupNeverInspectsSavedRecordings() async {
        let reads = DiagnosticSnapshotReadCount()
        let store = retryStore!
        let runner = makeRunner {
            await reads.record()
            return await store.diagnosticSnapshot()
        }

        await runner.runAutoReads()
        await runner.refreshConfig()
        await runner.runAllTests()

        let count = await reads.count
        XCTAssertEqual(count, 0, "setup checks must not monitor or maintain the message recovery queue")
        XCTAssertFalse(runner.showsVoiceSection)
        XCTAssertFalse(runner.checks.contains { $0.id == "voice.pendingRetry" })
    }

    func testCopyIncludesFreshAnonymousQueueFactsWithoutChangingSetupHealth() async throws {
        let store = retryStore!
        let runner = makeRunner { await store.diagnosticSnapshot() }
        await runner.runAllTests()
        let checks = runner.checks
        let attention = runner.attentionCount
        let passed = runner.checksSettledGreen
        let voiceVisible = runner.showsVoiceSection

        let capture = PendingRetryMetadata(
            id: UUID(), createdAt: Date(),
            audioFileURL: URL(fileURLWithPath: "/private/sensitive-recording.m4a"),
            preferredLanguage: "private-language", attemptCount: 1, lastErrorCode: 12345,
            destination: .work, transcript: "private transcript https://private.example secret-token",
            publicationState: .phaseOneFailed
        )
        try await store.save(audioData: Data("saved recording".utf8), metadata: capture, workImageData: nil)
        await store.resetAudioReadsForTesting()

        let report = await runner.prepareCopyBlock()
        XCTAssertTrue(report.contains("PendingRetry: queued(total 1, available 1, processing 0, transcription 0, finish-saving 1"))
        for secret in [capture.id.uuidString, "sensitive-recording", "private-language", "12345", "private transcript", "secret-token"] {
            XCTAssertFalse(report.contains(secret), "support context must not expose capture content or identity")
        }
        XCTAssertEqual(runner.checks, checks)
        XCTAssertEqual(runner.attentionCount, attention)
        XCTAssertEqual(runner.checksSettledGreen, passed)
        XCTAssertEqual(runner.showsVoiceSection, voiceVisible)
        let audioReads = await store.audioReadsForTesting
        XCTAssertEqual(audioReads, 0)
        let count = await store.pendingCount()
        XCTAssertEqual(count, 1, "copying never claims or retries a recording")

        let offered = await store.claimNext()
        let claim = try XCTUnwrap(offered)
        let cleared = await store.clear(claim)
        XCTAssertTrue(cleared)
        let refreshedReport = await runner.prepareCopyBlock()
        XCTAssertTrue(refreshedReport.contains("PendingRetry: none"), "each requested copy reflects the current queue")
        XCTAssertEqual(runner.checks, checks)
        XCTAssertEqual(runner.attentionCount, attention)
    }

    private func makeRunner(
        snapshot: @escaping @Sendable () async -> PendingRetryDiagnosticSnapshot?
    ) -> DiagnosticsRunner {
        DiagnosticsRunner(
            gatewayProbe: { _ in .passed },
            voicePermissions: { (.notRequested, .notRequested) },
            pendingRetrySnapshot: snapshot
        )
    }
}

private actor DiagnosticSnapshotReadCount {
    private(set) var count = 0
    func record() { count += 1 }
}
