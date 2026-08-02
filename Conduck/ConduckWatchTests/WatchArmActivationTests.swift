// SPDX-License-Identifier: Apache-2.0

// Conduck — watchOS-only capture-arm activation contract tests.
//
// Locks the off-main activation seam's guarantees in `_startRecording`:
// the post-activation stale bail (a cancel landing while the audio-server
// IPC is in flight must reset silently — no error state, no orphaned
// recorder), the throwing-activator failure surface, and the audio-session
// ownership handshake. The activator rides the coordinator's FIFO config
// lane (`runConfig`), and the release posture is split by whether the
// `.record` config committed: a CONFIGURED tenure releases PLAIN (the
// `.record` session staying active is deliberate), while a tenure that
// dies BEFORE its config lands must release-and-deactivate — its claim may
// have superseded a live TTS turn whose `.playback + .duckOthers` config
// is still the session's active state, and only the guarded deactivation
// restores the user's ducked audio.
//
// Every path drives an injected activator / permission seam plus a private
// `WatchAudioSessionCoordinator` with an inert, observable `deactivate` —
// no audio server, no TCC prompt, no network (the STT seam throws on
// contact). The real `AVAudioRecorder` init does run on the happy path
// (valid settings + writable temp URL need no mic grant).
//
// Shared-state hygiene: mirrors `WatchRecordingLifecycleTests` — the
// App-Group suite is process-shared, so in-flight keys + Ask hint + pointer
// are wiped in setUp/tearDown; iCloud KVS untouched (unsigned test host →
// inert store, phantom-failure trap).

import XCTest
@testable import ConduckWatch_Watch_App

/// Suspends the injected activator on a continuation so a test can act
/// (cancel, assert) while the "IPC" is provably in flight.
private actor ActivationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    private var opened = false

    func wait() async {
        entered = true
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

/// Records whether the coordinator's deactivation closure ever ran. Both
/// postures are asserted through it: a configured tenure's release must
/// NEVER fire it; an unconfigured death (activator throw, cancel mid-arm)
/// MUST — that deactivation is the duck-restore path.
private actor DeactivateSpy {
    private(set) var fired = false
    func record() { fired = true }
}

@MainActor
final class WatchArmActivationTests: XCTestCase {

    private var appGroup: InMemoryDefaultsStore { TestStores.defaults }

    private func wipeSharedState() {
        appGroup.removeObject(forKey: "watch.inFlight.conversationID")
        appGroup.removeObject(forKey: "watch.inFlight.startedAt")
        appGroup.removeObject(forKey: "watch.inFlight.turnID")
        WatchSettingsReader.shared.clearPendingInAppNewConversationBackend()
        WatchSettingsReader.shared.clearActiveConversation()
        AutoSpeakMailbox.shared.clear()
    }

    override func setUp() async throws {
        try await super.setUp()
        wipeSharedState()
    }

    override func tearDown() async throws {
        wipeSharedState()
        try await super.tearDown()
    }

    // MARK: - Rig

    private struct SeamError: Error {}

    private func makeCoordinator(spy: DeactivateSpy) -> WatchAudioSessionCoordinator {
        WatchAudioSessionCoordinator(
            deactivationGrace: .milliseconds(10),
            deactivate: { await spy.record() }
        )
    }

    private func makeService(coordinator: WatchAudioSessionCoordinator) -> WatchRecordingService {
        let service = WatchRecordingService()
        service.store = ConversationStore(inMemory: true)
        service.sessionCoordinator = coordinator
        // Permission seam: the real TCC prompt would park the arm Task in a
        // test host; the contracts under test all live past the gate.
        service.recordPermissionRequest = { true }
        // A capture that slips past the byte floor must fail fast locally,
        // never reach a real network.
        service.sttUpload = { _, _ in throw SeamError() }
        return service
    }

    /// Polls the MainActor condition, yielding so the service's unstructured
    /// arm Task can make progress between checks.
    private func settle(timeout: TimeInterval = 5.0, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func waitForActivationEntry(_ gate: ActivationGate, timeout: TimeInterval = 5.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await gate.entered), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Polls the actor-isolated spy until the deferred deactivation fires
    /// (or the timeout elapses); returns the final observation. The rig's
    /// 10 ms grace + the FIFO chain make the fire prompt but async.
    private func waitForDeactivation(_ spy: DeactivateSpy, timeout: TimeInterval = 2.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await spy.fired), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await spy.fired
    }

    // MARK: - Stale bail (cancel racing the activation IPC)

    func testCancelDuringActivationBailsSilently() async {
        let spy = DeactivateSpy()
        let coordinator = makeCoordinator(spy: spy)
        let service = makeService(coordinator: coordinator)
        let gate = ActivationGate()
        service.recordSessionActivator = { await gate.wait() }

        service.startCapture(boundTo: .existing(UUID()))
        XCTAssertEqual(service.state, .arming, "The capture arms synchronously.")
        await waitForActivationEntry(gate)
        let entered = await gate.entered
        XCTAssertTrue(entered, "The arm Task must reach the activator while suspended.")

        // Cancel while the activation is provably in flight — bumps the
        // capture generation and resets the machine.
        service.cancelRecording()
        XCTAssertEqual(service.state, .idle)
        XCTAssertFalse(coordinator.isClaimed, "Cancel drops the session claim.")

        // Release the suspended activator; the arm Task must take the
        // silent stale bail — no error state, no recorder resurrection.
        // (`runConfig` wraps the suspended activator: the claim was live at
        // issue time, so the config commits for the dead turn — harmless.)
        await gate.open()
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(service.state, .idle,
                       "A stale arm must bail silently — never an error toast for a turn the user already cancelled.")
        XCTAssertNil(service.audioRecorder, "No recorder may be minted for a dead turn.")
        XCTAssertNil(service.sessionClaim)
        XCTAssertFalse(coordinator.isClaimed)
        // The cancel landed BEFORE the tenure's config committed, so its
        // release is the deactivating kind — the guarded teardown must fire
        // once the FIFO chain drains (duck-restore posture for a mid-arm
        // death).
        let fired = await waitForDeactivation(spy)
        XCTAssertTrue(fired,
                      "A cancel before the `.record` config commits must schedule the guarded session deactivation.")
    }

    // MARK: - Throwing activator

    func testThrowingActivatorSurfacesArmFailure() async {
        let spy = DeactivateSpy()
        let coordinator = makeCoordinator(spy: spy)
        let service = makeService(coordinator: coordinator)
        service.recordSessionActivator = { throw SeamError() }

        service.startCapture(boundTo: .existing(UUID()))
        await settle { service.state.phaseKind == "error" }

        guard case .error = service.state else {
            return XCTFail("A live activation failure must surface the recording.failed error (state: \(service.state.phaseKind)).")
        }
        XCTAssertNil(service.audioRecorder)
        XCTAssertNil(service.sessionClaim, "The failure path releases the claim.")
        XCTAssertFalse(coordinator.isClaimed)
        // The tenure died before its `.record` config committed → the
        // failure release is the deactivating kind. On a never-active
        // session the production `setActive(false)` is a harmless no-op,
        // but the spy must still observe the scheduled teardown.
        let fired = await waitForDeactivation(spy)
        XCTAssertTrue(fired,
                      "An activator throw before the config commits must schedule the guarded session deactivation.")

        service.dismissError()
    }

    /// Duck-restore: the mic claim superseded a LIVE TTS turn, then the arm
    /// died before its `.record` config committed. The session is still
    /// active in `.playback + .duckOthers`, so the failure release MUST
    /// schedule the guarded deactivation — otherwise the user's music stays
    /// ducked forever.
    func testFailedArmAfterSupersedingPlaybackSchedulesDeactivate() async {
        let spy = DeactivateSpy()
        let coordinator = makeCoordinator(spy: spy)
        let service = makeService(coordinator: coordinator)
        service.recordSessionActivator = { throw SeamError() }

        // A live TTS turn owns the session before the capture starts.
        coordinator.claim(.playback)
        XCTAssertEqual(coordinator.current?.owner, .playback)

        service.startCapture(boundTo: .existing(UUID()))
        await settle { service.state.phaseKind == "error" }

        guard case .error = service.state else {
            return XCTFail("The activation failure must still surface (state: \(service.state.phaseKind)).")
        }
        XCTAssertNil(service.sessionClaim)
        XCTAssertFalse(coordinator.isClaimed,
                       "The failed tenure fully vacates ownership — nothing left to block the deactivation's unclaimed re-check.")

        let fired = await waitForDeactivation(spy)
        XCTAssertTrue(fired,
                      "The superseded TTS turn's ducked session must be torn down when the superseding arm dies unconfigured.")

        service.dismissError()
    }

    // MARK: - Happy path

    func testHappyPathReachesRecordingWithClaim() async {
        let spy = DeactivateSpy()
        let coordinator = makeCoordinator(spy: spy)
        let service = makeService(coordinator: coordinator)
        service.recordSessionActivator = {}

        service.startCapture(boundTo: .existing(UUID()))
        await settle { service.state == .recording }

        XCTAssertEqual(service.state, .recording)
        XCTAssertEqual(service.sessionClaim?.owner, .recording,
                       "The live capture holds the recording-tenure claim.")
        XCTAssertEqual(coordinator.current, service.sessionClaim,
                       "The coordinator's live claim is the service's own.")
        XCTAssertTrue(coordinator.isClaimed)

        service.cancelRecording()
        XCTAssertEqual(service.state, .idle)
    }

    // MARK: - Claim ordering (mic supersedes live playback)

    func testMicClaimSupersedesLivePlaybackClaimBeforeActivationCompletes() async {
        let spy = DeactivateSpy()
        let coordinator = makeCoordinator(spy: spy)
        let service = makeService(coordinator: coordinator)
        let gate = ActivationGate()
        service.recordSessionActivator = { await gate.wait() }

        let playback = coordinator.claim(.playback)
        XCTAssertEqual(coordinator.current?.owner, .playback)

        service.startCapture(boundTo: .existing(UUID()))

        // The claim flip is SYNCHRONOUS in `_startRecording` — the gate is
        // still closed, so activation provably has not completed.
        XCTAssertEqual(coordinator.current?.owner, .recording,
                       "The mic claim must supersede a live playback claim before any activation IPC.")
        XCTAssertFalse(coordinator.release(playback),
                       "The superseded playback claim's release must be a no-op — it no longer owns the session.")
        XCTAssertEqual(coordinator.current?.owner, .recording)

        service.cancelRecording()
        await gate.open()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(service.state, .idle)
    }

    // MARK: - Terminal releases (configured tenure → plain, never deactivating)

    func testCancelRecordingReleasesClaimWithoutDeactivate() async {
        let spy = DeactivateSpy()
        let coordinator = makeCoordinator(spy: spy)
        let service = makeService(coordinator: coordinator)
        service.recordSessionActivator = {}

        service.startCapture(boundTo: .existing(UUID()))
        await settle { service.state == .recording }
        XCTAssertTrue(coordinator.isClaimed)

        service.cancelRecording()

        XCTAssertFalse(coordinator.isClaimed, "Cancel drops ownership.")
        XCTAssertNil(service.sessionClaim)
        // Past the coordinator's grace window — a scheduled deactivation
        // would have fired by now. The `.record` config committed (the
        // capture reached `.recording`), so this tenure's release is PLAIN.
        try? await Task.sleep(nanoseconds: 100_000_000)
        let fired = await spy.fired
        XCTAssertFalse(fired, "A configured tenure's release is plain — the `.record` session stays active.")
    }

    func testStopRecordingReleasesClaimWithoutDeactivate() async {
        let spy = DeactivateSpy()
        let coordinator = makeCoordinator(spy: spy)
        let service = makeService(coordinator: coordinator)
        service.recordSessionActivator = {}

        service.startCapture(boundTo: .existing(UUID()))
        await settle { service.state == .recording }
        XCTAssertTrue(coordinator.isClaimed)

        // Outlast the mis-tap grace window so this exercises the REAL stop
        // path (recorder.stop → release → pipeline), not the grace discard.
        try? await Task.sleep(nanoseconds: 450_000_000)
        service.stopRecording()

        XCTAssertFalse(coordinator.isClaimed,
                       "Stop drops ownership synchronously, before the processing pipeline runs.")
        XCTAssertNil(service.sessionClaim)
        // Successful recording = configured tenure → plain release; the
        // deactivation spy must stay silent past the grace window.
        try? await Task.sleep(nanoseconds: 100_000_000)
        let fired = await spy.fired
        XCTAssertFalse(fired)

        // Drain the pipeline to a terminal (`.idle` via the byte floor for a
        // silent test-host capture, or `.error` via the throwing STT seam) so
        // no stray Task outlives the test.
        await settle { service.state.phaseKind == "idle" || service.state.phaseKind == "error" }
        if case .error = service.state { service.dismissError() }
    }
}
