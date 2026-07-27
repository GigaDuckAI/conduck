// SPDX-License-Identifier: Apache-2.0

// Conduck — watchOS capture-hygiene contract tests.
//
// 1. `WatchCaptureGuard` — the pure mis-tap/too-short predicates behind the
//    double-tap grace window (`stopRecording`) and the pre-compression byte
//    floor (`processRecording`). The field failure they close: a 0.0 s /
//    557-byte husk ran the compression-failure cascade plus a billed STT
//    round-trip just to surface "no speech detected".
// 2. The cancel-supersede contract on BOTH STT legs: a transcript resolving
//    AFTER `cancelRecording()` must be dropped — never chained into
//    `startConverseHop` (the resurrection bug: cancel wipes the routing pins,
//    so a chained hop would mint/land the turn in a thread the user never
//    chose). Driven through the `sttUpload` / `relayTranscribe` seams + an
//    injected in-memory store; refs are never-configured customs so nothing
//    reaches a network.
//    • `runSTTUpload` (cloud): the generation gate alone suffices.
//    • `runRelay` (iPhone relay — the DEFAULT `apple-on-device` path): the
//      generation gate is NOT enough, because the queue is enqueue-first
//      durable and its Task is detached from `processTask`. The cancel must
//      also CLAIM the queue entry, or a later drain ships the cancelled turn
//      (a relaunched process starts back at generation 0).
//    Each drop test is paired with an un-cancelled control, so a drop that
//    passes vacuously (nothing could ever have minted) fails the control.

import XCTest
@testable import ConduckWatch_Watch_App

@MainActor
final class WatchCaptureGuardTests: XCTestCase {

    private func wipeSharedState() {
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

    // MARK: - Pure predicates

    func testMisTapStopWindow() {
        XCTAssertTrue(WatchCaptureGuard.isMisTapStop(elapsedSinceRecordingFlip: 0.0))
        XCTAssertTrue(WatchCaptureGuard.isMisTapStop(elapsedSinceRecordingFlip: 0.2))
        XCTAssertFalse(WatchCaptureGuard.isMisTapStop(elapsedSinceRecordingFlip: WatchCaptureGuard.misTapStopWindow),
                       "The window boundary is exclusive — an exactly-at-window stop is intentional.")
        XCTAssertFalse(WatchCaptureGuard.isMisTapStop(elapsedSinceRecordingFlip: 1.0))
        XCTAssertFalse(WatchCaptureGuard.isMisTapStop(elapsedSinceRecordingFlip: Constants.maxAudioDuration),
                       "The max-duration hard stop can never classify as a mis-tap.")
        XCTAssertFalse(WatchCaptureGuard.isMisTapStop(elapsedSinceRecordingFlip: nil),
                       "No flip timestamp (defensive) never discards.")
    }

    func testTooShortCaptureByteFloor() {
        XCTAssertTrue(WatchCaptureGuard.isTooShortCapture(byteCount: 0))
        XCTAssertTrue(WatchCaptureGuard.isTooShortCapture(byteCount: 557),
                      "The field husk (557 bytes, zero frames) must be discarded.")
        XCTAssertTrue(WatchCaptureGuard.isTooShortCapture(byteCount: WatchCaptureGuard.minCaptureBytes - 1))
        XCTAssertFalse(WatchCaptureGuard.isTooShortCapture(byteCount: WatchCaptureGuard.minCaptureBytes))
        XCTAssertFalse(WatchCaptureGuard.isTooShortCapture(byteCount: 6_000),
                       "A genuine half-second 48 kHz AAC clip (≳6 KB) must pass.")
    }

    // MARK: - Cancel-supersede (runSTTUpload)

    func testCancelMidUploadDropsTranscriptWithoutResurrection() async throws {
        let store = ConversationStore(inMemory: true)
        let service = WatchRecordingService()
        service.store = store

        // Gate the fake upload so it resolves only AFTER the cancel below.
        var release: (@Sendable () -> Void)!
        let gate = AsyncStream<Void> { continuation in
            release = { continuation.finish() }
        }
        service.sttUpload = { _, _ in
            for await _ in gate {}
            return STTResponse(text: "resurrected transcript", language: nil)
        }

        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-guard-\(UUID().uuidString).m4a")
        try Data(repeating: 0xAB, count: 4096).write(to: audioURL)
        let request = WatchSTTRequest(
            audioData: Data(repeating: 0xAB, count: 4096),
            audioFormat: .aac,
            language: nil,
            provider: .mistralVoxtral
        )

        let generation = service.captureGeneration
        let upload = Task {
            await service.runSTTUpload(request: request, audioFileURL: audioURL,
                                       provider: .mistralVoxtral, generation: generation)
        }
        // Let the upload Task reach its suspension point, then cancel + release.
        await Task.yield()
        service.cancelRecording()
        release()
        await upload.value

        let conversations = try await store.fetchConversations()
        XCTAssertEqual(conversations.count, 0,
                       "A cancelled turn's late transcript must never mint/land a conversation.")
        XCTAssertEqual(service.state, .idle)
        XCTAssertNil(service.inFlightConversationID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path),
                       "The drop path must remove the audio file (cleanup mandate).")
    }

    // MARK: - Cancel-supersede (runRelay — the iPhone-relay branch)

    /// The relay leg's Task is deliberately detached from `processTask` (a
    /// wrist-drop must not kill a relay) and the queue is enqueue-first durable
    /// — so a cancel that only bumped the generation would still ship the turn
    /// when the queue drained (in a relaunched process the generation is 0
    /// again). `cancelRecording()` must CLAIM the entry: remove it, delete the
    /// queue-owned audio, and leave nothing that can mint a conversation.
    /// This is the DEFAULT STT path (`apple-on-device`).
    func testCancelMidRelayClaimsQueueEntryWithoutResurrection() async throws {
        let store = ConversationStore(inMemory: true)
        let service = WatchRecordingService()
        service.store = store

        let baselineEntries = AppleRelayPendingQueue.shared.entryCount

        // Gate the fake relay so its reply resolves only AFTER the cancel below,
        // and capture the queue-owned audio URL the seam is handed.
        final class URLBox: @unchecked Sendable { var url: URL? }
        let queued = URLBox()
        var release: (@Sendable () -> Void)!
        let gate = AsyncStream<Void> { continuation in
            release = { continuation.finish() }
        }
        service.relayTranscribe = { _, audioFileURL, _, _ in
            queued.url = audioFileURL
            for await _ in gate {}
            return "resurrected transcript"
        }

        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-guard-\(UUID().uuidString).m4a")
        try Data(repeating: 0xAB, count: 4096).write(to: audioURL)

        let relay = Task {
            await service.runRelay(audioFileURL: audioURL, originalFileURL: audioURL, providerID: nil)
        }
        // Let the relay Task enqueue and reach its reply suspension point.
        await Task.yield()
        XCTAssertEqual(AppleRelayPendingQueue.shared.entryCount, baselineEntries + 1,
                       "Enqueue-first: the entry must be durably queued before the reply is awaited.")

        service.cancelRecording()
        release()
        await relay.value

        let conversations = try await store.fetchConversations()
        XCTAssertEqual(conversations.count, 0,
                       "A cancelled turn's late relay transcript must never mint/land a conversation.")
        XCTAssertEqual(service.state, .idle)
        XCTAssertNil(service.inFlightConversationID)
        XCTAssertEqual(AppleRelayPendingQueue.shared.entryCount, baselineEntries,
                       "The cancel must CLAIM the entry — a surviving entry would drain the turn later.")
        let queuedPath = try XCTUnwrap(queued.url?.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: queuedPath),
                       "The claim must delete the queue-owned audio (cleanup mandate).")
    }

    /// Control for the relay drop test: the SAME drive without a cancel must
    /// claim the entry and chain into the converse hop (proves the drop test
    /// isn't vacuous — i.e. that the relay reply CAN mint a conversation).
    func testUncancelledRelayChainsIntoConverseHop() async throws {
        let store = ConversationStore(inMemory: true)
        let service = WatchRecordingService()
        service.store = store
        service.relayTranscribe = { _, _, _, _ in "hello from the wrist" }

        let baselineEntries = AppleRelayPendingQueue.shared.entryCount
        let capturedRef = "custom_\(UUID().uuidString)"
        WatchSettingsReader.shared.setPendingInAppNewConversationBackend(capturedRef)

        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-guard-\(UUID().uuidString).m4a")
        try Data(repeating: 0xCD, count: 4096).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        await service.runRelay(audioFileURL: audioURL, originalFileURL: audioURL, providerID: nil)

        let conversations = try await store.fetchConversations()
        XCTAssertEqual(conversations.count, 1,
                       "The un-cancelled relay must reach the converse resolver.")
        XCTAssertEqual(conversations.first?.backend, capturedRef)
        XCTAssertEqual(AppleRelayPendingQueue.shared.entryCount, baselineEntries,
                       "A dispatched relay claims its entry (exactly-once) — nothing is left queued.")
    }

    /// Control for the drop test: the SAME drive without a cancel must chain
    /// into the converse hop (mint happens; the never-configured ref then
    /// stops the hop at the not-configured gate — zero network).
    func testUncancelledUploadChainsIntoConverseHop() async throws {
        let store = ConversationStore(inMemory: true)
        let service = WatchRecordingService()
        service.store = store
        service.sttUpload = { _, _ in STTResponse(text: "hello wrist", language: nil) }

        let capturedRef = "custom_\(UUID().uuidString)"
        WatchSettingsReader.shared.setPendingInAppNewConversationBackend(capturedRef)

        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-guard-\(UUID().uuidString).m4a")
        try Data(repeating: 0xCD, count: 4096).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let request = WatchSTTRequest(
            audioData: Data(repeating: 0xCD, count: 4096),
            audioFormat: .aac,
            language: nil,
            provider: .mistralVoxtral
        )

        await service.runSTTUpload(request: request, audioFileURL: audioURL,
                                   provider: .mistralVoxtral, generation: service.captureGeneration)

        let conversations = try await store.fetchConversations()
        XCTAssertEqual(conversations.count, 1,
                       "The un-cancelled chain must reach the converse resolver (proves the drop test isn't vacuous).")
        XCTAssertEqual(conversations.first?.backend, capturedRef)
    }
}

// MARK: - Capture discard outcome (`captureDiscardCount`)

/// The contract behind the draft pop-on-discard: `captureDiscardCount` bumps
/// EXACTLY when a capture retires without minting a conversation, and NEVER on
/// a path that mints (or on `dismissError()`, which doubles as the internal
/// error-supersede — new-attempt entry points and the relay-success
/// auto-clear). A false bump pops a live draft off the nav stack mid-mint; a
/// missed bump strands the user on the draft's forever-spinner.
@MainActor
final class WatchCaptureDiscardOutcomeTests: XCTestCase {

    private func wipeSharedState() {
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

    func testCancelDuringActiveCaptureBumpsOnce() {
        let service = WatchRecordingService()
        service.state = .recording

        service.cancelRecording()
        XCTAssertEqual(service.captureDiscardCount, 1,
                       "Cancelling a live capture retires it un-minted — that IS a discard.")

        // The machine is idle now; a repeated cancel retired nothing.
        service.cancelRecording()
        XCTAssertEqual(service.captureDiscardCount, 1,
                       "A cancel that found the machine idle must not re-announce a discard.")
    }

    func testCancelAtIdleOrErrorDoesNotBump() {
        let service = WatchRecordingService()

        service.cancelRecording()
        XCTAssertEqual(service.captureDiscardCount, 0,
                       "No active capture, nothing discarded — a bump here would pop an unrelated live draft.")

        service.state = .error(message: "boom")
        service.cancelRecording()
        XCTAssertEqual(service.captureDiscardCount, 0,
                       "Error-state resets belong to `dismissError()` semantics — never a discard announcement.")
    }

    /// The mis-tap grace window and the byte floor both discard by routing
    /// through `cancelRecording()` from an active state (`.recording` /
    /// `.uploading` respectively) — this pins the entry states those paths use
    /// (the paths themselves need a live recorder, sim-excluded).
    func testCancelFromEachActiveStateBumps() {
        for state: WatchRecordingState in [.arming, .recording, .uploading, .waiting(startedAt: Date())] {
            let service = WatchRecordingService()
            service.state = state
            service.cancelRecording()
            XCTAssertEqual(service.captureDiscardCount, 1,
                           "Entry state \(state.phaseKind) is an active capture — its cancel is a discard.")
        }
        // NOTE the `.waiting` case above is the composer's post-mint in-flight
        // cancel: the SERVICE still announces the discard; the VIEW's pop
        // predicate filters it (the composer only exists on a thread with a
        // non-nil conversation id, and only nil-id drafts pop).
    }

    func testEmptyTranscriptDiscardBumpsOnce() async {
        let service = WatchRecordingService()
        service.store = ConversationStore(inMemory: true)
        service.state = .uploading

        await service.startConverseHop(transcript: "   \n ")

        XCTAssertEqual(service.captureDiscardCount, 1,
                       "An empty transcript mints nothing — the silent reset must announce the discard.")
        XCTAssertEqual(service.state, .idle)
    }

    /// The anti-false-pop invariant: a capture that MINTS must never read as a
    /// discard — not at the mint, and not when the converse leg then fails
    /// (the not-configured gate lands `.error` post-mint; the draft adopted
    /// the id and keeps its thread + banner).
    func testMintedPathNeverBumps() async throws {
        let store = ConversationStore(inMemory: true)
        let service = WatchRecordingService()
        service.store = store
        service.sttUpload = { _, _ in STTResponse(text: "hello wrist", language: nil) }

        WatchSettingsReader.shared.setPendingInAppNewConversationBackend("custom_\(UUID().uuidString)")

        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("discard-outcome-\(UUID().uuidString).m4a")
        try Data(repeating: 0xCD, count: 4096).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let request = WatchSTTRequest(
            audioData: Data(repeating: 0xCD, count: 4096),
            audioFormat: .aac,
            language: nil,
            provider: .mistralVoxtral
        )

        await service.runSTTUpload(request: request, audioFileURL: audioURL,
                                   provider: .mistralVoxtral, generation: service.captureGeneration)

        let conversations = try await store.fetchConversations()
        XCTAssertEqual(conversations.count, 1, "Control: the drive must actually mint.")
        XCTAssertEqual(service.captureDiscardCount, 0,
                       "A minted turn is not a discard — a bump here pops a REAL conversation's draft.")
    }

    func testDismissErrorNeverBumps() {
        let service = WatchRecordingService()
        service.state = .error(message: "boom")

        service.dismissError()

        XCTAssertEqual(service.captureDiscardCount, 0,
                       "`dismissError()` doubles as the internal error-supersede (new attempts, relay-success auto-clear) — a bump there pops a live draft mid-mint. User abandonment pops view-locally instead.")
        XCTAssertEqual(service.state, .idle)
    }
}
