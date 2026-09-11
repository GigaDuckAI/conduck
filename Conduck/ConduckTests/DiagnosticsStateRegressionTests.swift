// SPDX-License-Identifier: Apache-2.0

// Exercises Diagnostics through its real rebuild and test entry points. Provider
// operations and voice permission reads are injected; configuration, verdict
// persistence and result invalidation use the normal in-memory storage seam.
// These are lifecycle regressions: a passing test must describe the current
// setup, and a removed server cannot keep an old test's spinner or verdict.

import XCTest
@testable import Conduck

@MainActor
final class DiagnosticsStateRegressionTests: XCTestCase {
    private let gateway = RemoteAgentRef.builtin(.openclaw)

    override func setUp() async throws {
        try await super.setUp()
        TestStores.removeAll()
        await configureGateway(gateway)
        await SettingsManager.shared.setDefaultRemoteAgentRef(gateway)
    }

    override func tearDown() async throws {
        TestStores.removeAll()
        try await super.tearDown()
    }

    private func configureGateway(_ ref: RemoteAgentRef) async {
        await SettingsManager.shared.setRemoteAgentURL(URL(string: "https://gateway.example.test")!, for: ref)
        await SettingsManager.shared.setRemoteAgentAuthScheme(.none, for: ref)
    }

    private func configureFileServer() async throws {
        try await SettingsManager.shared.setFileServerCredential(String(repeating: "a", count: 32), for: gateway)
        await SettingsManager.shared.setFileServerURL(URL(string: "https://files.example.test")!, for: gateway)
    }

    private func runner(
        microphone: DiagnosticPermissionState = .notRequested,
        speech: DiagnosticPermissionState = .notRequested,
        transcription: (@Sendable () async throws -> String)? = nil,
        fileTest: (@Sendable (SettingsManager.FileTransferSnapshot) async -> FileTransferTestResult)? = nil
    ) -> DiagnosticsRunner {
        DiagnosticsRunner(
            gatewayProbe: { _ in .passed },
            transcriptionProbe: transcription,
            fileTransferProbe: fileTest,
            voicePermissions: { (microphone, speech) }
        )
    }

    func testChangingGatewayURLInvalidatesTheCompletedRun() async {
        let runner = runner()
        await runner.runAllTests()
        XCTAssertTrue(runner.checksSettledGreen)

        await SettingsManager.shared.setRemoteAgentURL(URL(string: "https://replacement.example.test")!, for: gateway)
        await runner.refreshConfig()

        XCTAssertFalse(runner.connectionChecksHaveRun)
        XCTAssertFalse(runner.checksSettledGreen)
        XCTAssertNil(runner.lastChecked)
        XCTAssertEqual(runner.checks.first { $0.id == "gateway.openclaw" }?.status, .notRun)
        XCTAssertGreaterThan(runner.untestedCheckCount, 0)
    }

    func testAddingAndRemovingGatewayChangesTheCompletedScope() async {
        let runner = runner()
        await runner.runAllTests()
        XCTAssertTrue(runner.checksSettledGreen)

        let second = RemoteAgentRef.builtin(.hermes)
        await configureGateway(second)
        await runner.refreshConfig()
        XCTAssertFalse(runner.checksSettledGreen)
        XCTAssertEqual(runner.gatewayDisplayOrder.count, 2)

        await runner.runAllTests()
        XCTAssertTrue(runner.checksSettledGreen)
        await SettingsManager.shared.setRemoteAgentURL(nil, for: second)
        await runner.refreshConfig()
        XCTAssertFalse(runner.checksSettledGreen)
        XCTAssertFalse(runner.gatewayDisplayOrder.contains { $0.ref == second })
        XCTAssertFalse(runner.fileLanes.contains { $0.ref == second })
    }

    func testVoiceProviderChangesInvalidateTheRunAndPlaybackStaysSeparate() async {
        let runner = runner(microphone: .allowed, speech: .allowed, transcription: { "A sample" })
        await runner.runAllTests()
        XCTAssertTrue(runner.checksSettledGreen)
        XCTAssertTrue(runner.voicePreviewNeedsTest, "the main test must not imply it played the chosen voice")

        await SettingsManager.shared.setActiveTTSProviderID("elevenlabs-tts")
        await runner.refreshConfig()
        XCTAssertFalse(runner.connectionChecksHaveRun)
        XCTAssertFalse(runner.checksSettledGreen)

        await SettingsManager.shared.setActiveTTSProviderID("apple-tts")
        await runner.runAllTests()
        XCTAssertTrue(runner.checksSettledGreen)
        await SettingsManager.shared.setActivePresetID("elevenlabs-scribe-v2")
        await runner.refreshConfig()
        XCTAssertFalse(runner.connectionChecksHaveRun)
        XCTAssertFalse(runner.checksSettledGreen)
    }

    func testSavingOptionalFileServerRequiresACheckWithoutCreatingAFault() async throws {
        let runner = runner()
        await runner.runAllTests()
        let priorAttention = runner.attentionCount
        XCTAssertTrue(runner.checksSettledGreen)

        try await configureFileServer()
        await runner.refreshConfig()
        XCTAssertFalse(runner.checksSettledGreen)
        XCTAssertEqual(runner.untestedCheckCount, 1)
        XCTAssertEqual(runner.attentionCount, priorAttention)
        XCTAssertEqual(runner.fileLanes.first { $0.ref == gateway }?.badge, .configuredNotTested)
    }

    func testChangingAppleEngineInvalidatesTheCompletedRunAndTranscription() async {
        await SettingsManager.shared.setAppleOnDeviceEngineMode(.dictation)
        let runner = runner(microphone: .allowed, speech: .allowed, transcription: { "A sample" })
        await runner.runAllTests()
        XCTAssertTrue(runner.checksSettledGreen)
        XCTAssertEqual(runner.checks.first { $0.id == "voice.stt.test" }?.status, .passed)

        await SettingsManager.shared.setAppleOnDeviceEngineMode(.highQuality)
        await runner.refreshConfig()
        XCTAssertFalse(runner.connectionChecksHaveRun)
        XCTAssertFalse(runner.checksSettledGreen)
        XCTAssertNil(runner.lastChecked)
        XCTAssertEqual(runner.checks.first { $0.id == "voice.stt.test" }?.status, .notRun)

        await runner.runAllTests()
        XCTAssertTrue(runner.checksSettledGreen)
        await SettingsManager.shared.setAppleOnDeviceEngineMode(.dictation)
        await runner.refreshConfig()
        XCTAssertFalse(runner.checksSettledGreen)
        XCTAssertEqual(runner.checks.first { $0.id == "voice.stt.test" }?.status, .notRun)
    }

    func testMainRunDoesNotTestUnusedDefaultVoice() async {
        let calls = DiagnosticCallCounter()
        let runner = runner(transcription: { await calls.record(); return "A sample" })
        await runner.runAllTests()
        let count = await calls.count
        XCTAssertEqual(count, 0)
        XCTAssertFalse(runner.showsVoiceSection)
        XCTAssertEqual(runner.untestedCheckCount, 0)
        XCTAssertTrue(runner.checksSettledGreen)
    }

    func testOnDeviceTranscriptionShowsPermissionPrerequisiteWithoutCallingProvider() async {
        let calls = DiagnosticCallCounter()
        let runner = runner(microphone: .allowed, speech: .notRequested,
                            transcription: { await calls.record(); return "A sample" })
        await runner.runAllTests()
        let count = await calls.count
        XCTAssertEqual(count, 0)
        XCTAssertTrue(runner.showsVoiceSection)
        XCTAssertEqual(runner.transcriptionTestPrerequisite, .speechRecognition)
        XCTAssertEqual(runner.permissionAction(for: .speechRecognition), .allow)
        XCTAssertEqual(runner.checks.first { $0.id == "voice.stt.test" }?.status, .notRun)
        XCTAssertFalse(runner.checksSettledGreen)
    }

    func testOneMissingSharedVoiceKeyCountsOnceAndNeverCallsTranscription() async {
        let calls = DiagnosticCallCounter()
        let runner = runner(transcription: { await calls.record(); return "A sample" })
        await runner.runAutoReads()
        let priorAttention = runner.attentionCount
        await SettingsManager.shared.setActivePresetID("elevenlabs-scribe-v2")
        await SettingsManager.shared.setActiveTTSProviderID("elevenlabs-tts")
        await runner.runAllTests()

        let count = await calls.count
        XCTAssertEqual(count, 0)
        XCTAssertEqual(runner.activeVoiceSetup?.sttStatus, .warning)
        XCTAssertEqual(runner.activeVoiceSetup?.ttsStatus, .warning)
        XCTAssertEqual(runner.attentionCount, priorAttention + 1,
                       "both provider blocks and the failed auth check require the same key repair")
    }

    func testChangingServerDuringFileTestDropsOldSpinnerAndVerdict() async throws {
        try await assertFileTestInvalidation(forget: false)
    }

    func testForgettingServerDuringFileTestDoesNotRecreateItsWarning() async throws {
        try await assertFileTestInvalidation(forget: true)
    }

    private func assertFileTestInvalidation(forget: Bool) async throws {
        try await configureFileServer()
        let gate = SuspendedDiagnosticFileProbe()
        let runner = runner(fileTest: { _ in await gate.run() })
        await runner.runAutoReads()
        let running = Task { await runner.runFileTransferTest(for: gateway) }
        await gate.waitUntilStarted()
        XCTAssertEqual(runner.fileLanes.first { $0.ref == gateway }?.badge, .testing)

        if forget {
            await GatewayForget.wipeFileLane(for: gateway)
        } else {
            await SettingsManager.shared.setFileServerURL(URL(string: "https://new-files.example.test")!, for: gateway)
        }
        await runner.refreshConfig()
        XCTAssertNotEqual(runner.fileLanes.first { $0.ref == gateway }?.badge, .testing)
        await gate.finish(FileTransferTestResult(reachedStage: .listing, success: true, failure: nil))
        await running.value
        await runner.refreshConfig()

        XCTAssertFalse(runner.isBusy)
        XCTAssertNil(runner.fileTransferResults[gateway])
        XCTAssertEqual(runner.fileLanes.first { $0.ref == gateway }?.badge,
                       forget ? .notSetUp : .configuredNotTested)
        let available = await SettingsManager.shared.getFileTransferAvailable(for: gateway)
        XCTAssertFalse(available, "the old server's pass must never enable the new or forgotten server")
    }

    func testSameServerReadinessRefreshPreservesTheInFlightTestAndFinishedDetail() async throws {
        try await configureFileServer()
        let gate = SuspendedDiagnosticFileProbe()
        let runner = runner(fileTest: { _ in await gate.run() })
        await runner.runAutoReads()
        let running = Task { await runner.runFileTransferTest(for: gateway) }
        await gate.waitUntilStarted()
        // The test's own durable commit can notify observers before its display
        // mirror updates. A readiness-only change must preserve the same test.
        await SettingsManager.shared.setFileTransferAvailable(true, for: gateway)
        await runner.refreshConfig()
        XCTAssertEqual(runner.fileLanes.first { $0.ref == gateway }?.badge, .testing)

        await gate.finish(FileTransferTestResult(reachedStage: .listing, success: true, failure: nil,
                                               returnVerification: .methodUnavailable))
        await running.value
        await runner.refreshConfig()
        XCTAssertEqual(runner.fileTransferResults[gateway]?.success, true)
        let lane = try XCTUnwrap(runner.fileLanes.first { $0.ref == gateway })
        XCTAssertEqual(lane.badge, .verified)
        XCTAssertEqual(runner.fileLaneReturnCaveat(for: lane), .uploadsOnly)
    }

    func testReplacementFileTestCannotStartWhileOldCleanupStillOwnsTheLane() async throws {
        try await configureFileServer()
        let originalProbe = SuspendedDiagnosticFileProbe()
        let cleanup = SuspendedDiagnosticCleanup()
        let calls = DiagnosticCallCounter()
        let passed = FileTransferTestResult(reachedStage: .listing, success: true, failure: nil)
        let runner = DiagnosticsRunner(
            gatewayProbe: { _ in .passed },
            fileTransferProbe: { _ in
                await calls.record()
                if await calls.count == 1 { return await originalProbe.run() }
                return passed
            },
            voicePermissions: { (.notRequested, .notRequested) },
            fileTransferCleanupWillRefresh: { await cleanup.pause() }
        )
        await runner.runAutoReads()
        let original = Task { await runner.runFileTransferTest(for: gateway) }
        await originalProbe.waitUntilStarted()
        await SettingsManager.shared.setFileServerURL(URL(string: "https://replacement-files.example.test")!, for: gateway)
        await runner.refreshConfig()
        await originalProbe.finish(passed)
        await cleanup.waitUntilStarted()

        XCTAssertTrue(runner.fileTransferTestRunning.contains(gateway))
        XCTAssertNotEqual(runner.fileLanes.first { $0.ref == gateway }?.badge, .testing)
        await runner.runFileTransferTest(for: gateway)
        let duringCleanup = await calls.count
        XCTAssertEqual(duringCleanup, 1, "a replacement probe must not enter while the old call can still remove its guard")
        XCTAssertTrue(runner.isBusy)

        await cleanup.resume()
        await original.value
        XCTAssertFalse(runner.isBusy)
        await runner.runFileTransferTest(for: gateway)
        let afterCleanup = await calls.count
        XCTAssertEqual(afterCleanup, 2, "the replacement can run after the old call fully retires")
        XCTAssertEqual(runner.fileLanes.first { $0.ref == gateway }?.badge, .verified)
    }

    private func isolatedFileServer() async throws -> (SettingsManager, SettingsManager.FileTransferSnapshot) {
        let manager = SettingsManager(dependencies: .inMemory())
        try await manager.setFileServerCredential(String(repeating: "a", count: 32), for: gateway)
        await manager.setFileServerURL(URL(string: "https://original-files.example.test")!, for: gateway)
        let snapshot = await manager.fileTransferSnapshot(for: gateway)
        return (manager, try XCTUnwrap(snapshot))
    }

    func testGuardedFileCommitRefusesAReplacementIdentityWithoutChangingItsVerdict() async throws {
        let (manager, original) = try await isolatedFileServer()
        await manager.setFileServerURL(URL(string: "https://replacement-files.example.test")!, for: gateway)
        let before = await manager.fileTransferSnapshot(for: gateway)
        let result = FileTransferTestResult(reachedStage: .listing, success: true, failure: nil,
                                            folderCapable: false, returnVerification: .methodUnavailable)

        let committed = await DiagnosticsRunner.commitFileTestResultIfCurrent(
            result, for: gateway, expected: original, manager: manager
        )
        let after = await manager.fileTransferSnapshot(for: gateway)
        XCTAssertFalse(committed)
        XCTAssertEqual(after, before, "an old result cannot change readiness or capabilities of the replacement server")
    }

    func testGuardedFileCommitCannotRecreateForgottenVerdicts() async throws {
        let (manager, original) = try await isolatedFileServer()
        await manager.setFileServerURL(nil, for: gateway)
        try await manager.clearFileServerCredential(for: gateway)
        let priorFolderCapability = await manager.getFileServerFolderCapable(for: gateway)
        let priorReturnCapability = await manager.getFileServerReturnCapable(for: gateway)
        let result = FileTransferTestResult(reachedStage: .listing, success: true, failure: nil,
                                            folderCapable: false, returnVerification: .methodUnavailable)

        let committed = await DiagnosticsRunner.commitFileTestResultIfCurrent(
            result, for: gateway, expected: original, manager: manager
        )
        let snapshot = await manager.fileTransferSnapshot(for: gateway)
        let available = await manager.getFileTransferAvailable(for: gateway)
        let folderCapability = await manager.getFileServerFolderCapable(for: gateway)
        let returnCapability = await manager.getFileServerReturnCapable(for: gateway)
        XCTAssertFalse(committed)
        XCTAssertNil(snapshot)
        XCTAssertFalse(available)
        XCTAssertEqual(folderCapability, priorFolderCapability)
        XCTAssertEqual(returnCapability, priorReturnCapability)
    }

    func testGuardedFileCommitPreservesAllVerdictsForTheSameIdentity() async throws {
        let (manager, original) = try await isolatedFileServer()
        let result = FileTransferTestResult(reachedStage: .listing, success: true, failure: nil,
                                            folderCapable: false, returnVerification: .methodUnavailable)
        let committed = await DiagnosticsRunner.commitFileTestResultIfCurrent(
            result, for: gateway, expected: original, manager: manager
        )
        let snapshot = await manager.fileTransferSnapshot(for: gateway)
        XCTAssertTrue(committed)
        XCTAssertEqual(snapshot?.identitySignature, original.identitySignature)
        XCTAssertEqual(snapshot?.available, true)
        XCTAssertEqual(snapshot?.folderCapable, false)
        XCTAssertEqual(snapshot?.returnCapable, false)
    }

    func testSyncHistoryDoesNotAssertRecoveryAcrossDifferentOperations() {
        let state = DiagnosticsRunner.syncEventsRowState(["export FAIL", "import ok"])
        XCTAssertEqual(state.status, .notApplicable)
        XCTAssertFalse(state.detail.contains("recovered"))
        XCTAssertTrue(state.detail.contains("different sync operation"))
        XCTAssertEqual(DiagnosticsRunner.syncEventsRowState(["export FAIL"]).status, .notApplicable)
    }
}

private actor DiagnosticCallCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor SuspendedDiagnosticFileProbe {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var resultWaiter: CheckedContinuation<FileTransferTestResult, Never>?

    func run() async -> FileTransferTestResult {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        return await withCheckedContinuation { resultWaiter = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func finish(_ result: FileTransferTestResult) {
        resultWaiter?.resume(returning: result)
        resultWaiter = nil
    }
}

private actor SuspendedDiagnosticCleanup {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var cleanupWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { cleanupWaiter = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func resume() {
        cleanupWaiter?.resume()
        cleanupWaiter = nil
    }
}
