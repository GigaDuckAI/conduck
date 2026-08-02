// SPDX-License-Identifier: Apache-2.0

// Conduck — watchOS-only turn-lifecycle contract tests.
//
// Locks the WatchRecordingService state-machine transitions behind every
// field symptom: background reply/failure takeover matching (a resurrected
// OLD task's failure must not overwrite the machine while it waits on a
// NEWER turn), deferred-dispatch gating, the restore stale-guard, and the
// guard-first capture refusal. Every path driven here never touches
// AVAudioRecorder/WCSession — fresh service instances + direct App-Group
// writes for the in-flight marker keys.
//
// Shared-state hygiene: the App-Group suite is process-shared across tests —
// every test wipes the in-flight keys + Ask hint + pointer in setUp/tearDown.
// iCloud KVS is untouched (unsigned test host → inert store, phantom-failure
// trap).

import XCTest
@testable import ConduckWatch_Watch_App

@MainActor
final class WatchRecordingLifecycleTests: XCTestCase {

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

    // MARK: - Background reply (success path)

    func testMatchingReplyResetsLiveWaitAndClearsMarkers() {
        let service = WatchRecordingService()
        let cid = UUID()
        appGroup.set(cid.uuidString, forKey: "watch.inFlight.conversationID")
        appGroup.set(Date().timeIntervalSinceReferenceDate, forKey: "watch.inFlight.startedAt")
        appGroup.set(UUID().uuidString, forKey: "watch.inFlight.turnID")
        service.state = .waiting(startedAt: Date())

        service.handleBackgroundReply("done", conversationID: cid, messageID: UUID())

        XCTAssertEqual(service.state, .idle, "A matching reply must reset the live wait to idle.")
        XCTAssertNil(appGroup.string(forKey: "watch.inFlight.conversationID"),
                     "The persisted in-flight marker must clear with the reply.")
        XCTAssertNil(appGroup.object(forKey: "watch.inFlight.startedAt"))
        XCTAssertNil(appGroup.string(forKey: "watch.inFlight.turnID"))
        XCTAssertNil(service.inFlightConversationID)
    }

    // MARK: - Background failure (takeover matching)

    func testUnrelatedConversationFailureKeepsLiveWait() async throws {
        let store = ConversationStore(inMemory: true)
        let service = WatchRecordingService()
        service.store = store
        // Pin the machine to conversation A via a bound typed send. The bound
        // ref is a never-configured custom, so the hop stops at the
        // not-configured gate WITH the pin retained — the state a live wait
        // carries.
        let a = try await store.createConversation(backend: "custom_\(UUID().uuidString)")
        let sent = await service.sendTypedText("follow-up", into: a.id)
        XCTAssertTrue(sent)
        service.state = .waiting(startedAt: Date())

        service.handleBackgroundFailure("unrelated turn failed", conversationID: UUID())

        guard case .waiting = service.state else {
            return XCTFail("An unrelated turn's failure must not stomp the live wait (state: \(service.state.phaseKind)).")
        }
    }

    func testMatchingConversationFailureTakesOverLiveWait() async throws {
        let store = ConversationStore(inMemory: true)
        let service = WatchRecordingService()
        service.store = store
        let a = try await store.createConversation(backend: "custom_\(UUID().uuidString)")
        _ = await service.sendTypedText("follow-up", into: a.id)
        service.state = .waiting(startedAt: Date())

        service.handleBackgroundFailure("this turn failed", conversationID: a.id)

        XCTAssertEqual(service.state, .error(message: "this turn failed"),
                       "The pinned turn's own failure must take over the machine.")
    }

    func testNilConversationFailureTakesOverLiveWait() {
        let service = WatchRecordingService()
        service.state = .waiting(startedAt: Date())

        service.handleBackgroundFailure("transport down", conversationID: nil)

        XCTAssertEqual(service.state, .error(message: "transport down"),
                       "A nil-conversation failure (STT task / metadata decode miss) can't be pin-checked — takeover stands.")
    }

    func testFailureWhileIdleLeavesMachineUntouched() {
        let service = WatchRecordingService()

        service.handleBackgroundFailure("late failure", conversationID: UUID())

        XCTAssertEqual(service.state, .idle,
                       "With no live turn showing, the notification carries the failure — no state takeover.")
    }

    // MARK: - Deferred-dispatch gate

    /// `lastErrorIsRelayDeferral == true` is set ONLY inside `runRelay`'s
    /// timeout branch and cleared by every state transition — the flag-true
    /// row is not drivable without invoking the relay pipeline, so it stays
    /// covered by code inspection (documented gap).
    func testCanAcceptDeferredDispatchTruthTable() {
        let service = WatchRecordingService()
        XCTAssertTrue(service.canAcceptDeferredDispatch, ".idle accepts deferred dispatch.")
        service.state = .arming
        XCTAssertFalse(service.canAcceptDeferredDispatch, ".arming refuses.")
        service.state = .recording
        XCTAssertFalse(service.canAcceptDeferredDispatch, ".recording refuses.")
        service.state = .uploading
        XCTAssertFalse(service.canAcceptDeferredDispatch, ".uploading refuses.")
        service.state = .waiting(startedAt: Date())
        XCTAssertFalse(service.canAcceptDeferredDispatch, ".waiting refuses.")
        service.state = .error(message: "unrelated")
        XCTAssertFalse(service.canAcceptDeferredDispatch,
                       "An unrelated error refuses (provenance flag false — only the relay-deferral toast may be stomped).")
    }

    // MARK: - Restore stale-guard

    func testStaleInFlightMarkerClearsWithoutRestore() {
        let service = WatchRecordingService()
        appGroup.set(UUID().uuidString, forKey: "watch.inFlight.conversationID")
        let stale = Date().addingTimeInterval(-(Constants.remoteAgentConverseResourceTimeout + 60))
        appGroup.set(stale.timeIntervalSinceReferenceDate, forKey: "watch.inFlight.startedAt")
        appGroup.set(UUID().uuidString, forKey: "watch.inFlight.turnID")

        service.restoreInFlightStateIfNeeded()

        // The stale branch clears + returns synchronously, BEFORE the
        // store-backed restore Task — assertable immediately.
        XCTAssertEqual(service.state, .idle, "A stale marker must never restore a thinking view.")
        XCTAssertNil(appGroup.string(forKey: "watch.inFlight.conversationID"))
        XCTAssertNil(appGroup.object(forKey: "watch.inFlight.startedAt"))
        XCTAssertNil(appGroup.string(forKey: "watch.inFlight.turnID"))
    }

    // MARK: - Guard-first capture refusal

    func testGuardFirstRefusalPreservesFirstCapturePins() {
        let service = WatchRecordingService()
        let a = UUID()
        service.startCapture(boundTo: .existing(a))
        XCTAssertEqual(service.state, .arming, "The first capture arms synchronously.")
        XCTAssertEqual(service.inFlightConversationID, a)

        // A genuinely different second trigger while `.arming` — refused
        // BEFORE any pin/hint mutation.
        service.startCapture(boundTo: .new(backendRef: "custom_refused"))

        XCTAssertEqual(service.inFlightConversationID, a,
                       "A refused second trigger must not clobber the live turn's pin.")
        XCTAssertNil(WatchSettingsReader.shared.consumePendingInAppNewConversationBackend(),
                     "A refused `.new` start must not leave an Ask hint behind.")
        // Tear the armed machine down before its permission Task advances
        // (the cancel bumps the capture generation, so the leaked arm Task
        // bails at its supersede guard).
        service.cancelRecording()
        XCTAssertEqual(service.state, .idle)
    }
}
