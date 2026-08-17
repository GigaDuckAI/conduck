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
// 3. The HEADLESS gateway gate — a quick-capture trigger refuses BEFORE the
//    microphone arms when the couriered default gateway is not one this Watch
//    can send to, and says something true about why. Locked here: the refusal
//    sentences and which reading each belongs to (an EMPTY configured set is
//    ambiguous and keeps the existing "set up on iPhone" copy; a non-empty one
//    with no chosen default at all refuses UNNAMED, because the couriered ref is
//    the iPhone's fallback and may itself be configured; a non-empty one with a
//    chosen default missing from it names that default); that an unnameable
//    default drops the name rather than leaking a raw ref; that the resolver
//    is a pure verdict and NEVER writes `state` (the drain ladder owns the
//    ordering, and a write there would stomp a live turn); that a bound
//    conversation whose gateway is gone is refused, never rerouted; and that
//    the default-bound mint arm refuses instead of leaving an orphan thread.
// 4. The ORDER the gate is asked in: the POINTER branch first, the gateway gate
//    only after it misses. A capture that continues a live quick-lane thread
//    routes on that thread's own sealed ref and never touches the default, so no
//    verdict about the default may refuse it — the rule the phone states in
//    `SharedInboxRouting.liveQuickCaptureCanContinue`, restated here as a sibling
//    because the Watch app is a separate target that links none of it. The
//    four-row table both sides answer is locked in
//    `testTheWristAnswersThePhonesLiveCaptureTable`, whose phone-side twin is
//    `GigaActionPreflightTests.testTheLiveCaptureTableAnswersFourWays`.

import XCTest
@testable import ConduckWatch_Watch_App

@MainActor
final class WatchCaptureGuardTests: XCTestCase {

    private func wipeSharedState() {
        WatchSettingsReader.shared.clearPendingInAppNewConversationBackend()
        WatchSettingsReader.shared.clearActiveConversation()
        AutoSpeakMailbox.shared.clear()
        // `WatchSettingsReader` is a process singleton over ONE in-memory
        // App-Group double shared by every test in the run, so the gateway
        // cases below have to hand it back in the state sibling files expect:
        // nothing configured, no roster, no retirement records — and above all
        // no teardown marker, which permanently suppresses cold-launch config
        // hydration for every test that runs afterwards.
        clearCouriedGateways()
        let appGroup = TestStores.defaults
        appGroup.removeObject(forKey: Constants.retiredGatewayBadgesKey)
        appGroup.removeObject(forKey: Constants.customGatewaysRegistryKey)
        // Mirrors `WatchSettingsReader.remoteAgentTornDownKey`, which is private.
        appGroup.removeObject(forKey: "watch.remoteAgentTornDown")
    }

    /// Send a teardown envelope so the configured set is genuinely EMPTY (an
    /// empty `backends` array WITHOUT `clearAll` is deliberately non-destructive
    /// — see `testEmptyBackendsWithoutTheFlagDoesNotPurge`).
    private func clearCouriedGateways() {
        let reader = WatchSettingsReader.shared
        let ts = reader.lastRemoteAgentEnvelopeTimestamp + 20_000
        XCTAssertTrue(reader.updateRemoteAgents(multi: RemoteAgentMultiBroadcastEnvelope(
            backends: [],
            defaultBackendRef: Constants.remoteAgentDefaultBackendDefault.rawValue,
            timestamp: ts,
            sessionPolicy: nil,
            clearAll: true
        )), "A strictly-newer teardown envelope must be accepted.")
    }

    /// Stage the couriered gateway state this Watch routes on: `configured`
    /// becomes the configured set, `defaultRef` the couriered default pointer
    /// (`updateRemoteAgents(multi:)` stores it VERBATIM and never requires it to
    /// be a member of `backends`, which is what makes a broken default directly
    /// expressible here).
    ///
    /// Every ref is staged KEYLESS (`authScheme: .none`), so it counts as
    /// configured on its URL alone. `updateRemoteAgents(multi:)` writes the
    /// per-ref URL / scheme maps but NOT the Keychain — tokens ride
    /// `WatchSessionManager.applyEnvelopePayload` — so a `.bearer` sub-envelope
    /// would stage a ref that never reads back as configured and every case
    /// below would pass vacuously.
    private func stageGateways(
        _ configured: [(ref: String, name: String?)],
        default defaultRef: String,
        chosen: Bool = true
    ) {
        let reader = WatchSettingsReader.shared
        let ts = reader.lastRemoteAgentEnvelopeTimestamp + 20_000
        let subs = configured.enumerated().map { index, entry in
            RemoteAgentBroadcastEnvelope(
                backendRef: entry.ref,
                // Host derived from the INDEX, not the ref: a "custom_<uuid>"
                // ref carries an underscore, which has no business in a hostname.
                url: URL(string: "https://gw\(index).example.test")!,
                name: entry.name,
                model: nil,
                colorID: nil,
                monogram: nil,
                token: nil,
                authScheme: .none,
                certFingerprintHex: nil,
                activeSessionID: nil,
                timestamp: ts
            )
        }
        // A custom ref must be spelled the way `RemoteAgentRef.rawString` spells
        // it (lowercase uuid) — the reader indexes its roster by that accessor,
        // so an uppercase twin stages slots nothing ever looks up.
        for entry in configured where entry.ref.hasPrefix("custom_") {
            XCTAssertEqual(RemoteAgentRef(rawString: entry.ref)?.rawString, entry.ref,
                           "Stage custom refs via `RemoteAgentRef.custom(_:).rawString`, not string interpolation.")
        }
        XCTAssertTrue(reader.updateRemoteAgents(multi: RemoteAgentMultiBroadcastEnvelope(
            backends: subs, defaultBackendRef: defaultRef, timestamp: ts, sessionPolicy: nil,
            // Sent only as the unusual answer, mirroring the iPhone: an omitted
            // slot reads as CHOSEN, which is what every build predating the flag
            // means by staying silent.
            defaultBackendChosen: chosen ? nil : false
        )), "A strictly-newer multi-envelope must be accepted, or the case stages nothing.")
        XCTAssertEqual(Set(reader.configuredBackendRefs()), Set(configured.map(\.ref)),
                       "Control: the staged refs must genuinely read back as configured.")
        XCTAssertEqual(reader.defaultBackendRef, defaultRef,
                       "Control: the couriered default must be stored verbatim, member or not.")
        XCTAssertEqual(reader.hasChosenDefaultBackend, chosen,
                       "Control: the chosen flag must survive the courier, or the cases below assert nothing.")
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

    // MARK: - Headless gateway gate

    /// The bug this closes: the wrist recorded, billed an STT round-trip, and
    /// only THEN said "set up your personal AI on iPhone" — on a phone where
    /// other gateways work perfectly. The refusal has to happen at trigger
    /// time, and it has to name the gateway that is actually the problem.
    func testHeadlessCaptureRefusesBeforeRecordingWhenTheDefaultIsNotConfigured() async {
        let service = WatchRecordingService()
        service.store = ConversationStore(inMemory: true)
        // Built through `rawString`, never interpolated: that accessor
        // LOWERCASES the uuid, and the roster is indexed by what it returns — a
        // hand-spelled uppercase ref stages a URL under one key and looks it up
        // under another, so the gateway silently reads as unconfigured.
        let customRef = RemoteAgentRef.custom(UUID()).rawString
        stageGateways([(ref: "hermes", name: nil), (ref: customRef, name: "Studio box")],
                      default: "openclaw")

        let resolution = await service.resolveHeadlessCaptureTarget()

        guard case .refused(let message) = resolution else {
            return XCTFail("A default outside the configured set must refuse, not hand back a capture target.")
        }
        XCTAssertNil(resolution.captureTarget,
                     "A refusal carries no target — there is nothing to record into.")
        XCTAssertTrue(message.contains("OpenClaw"),
                      "The refusal names the gateway the user actually chose, resolved from the couriered roster.")
        XCTAssertFalse(message.contains("Set up your personal AI on iPhone first"),
                       "The phone HAS working gateways — the first-run sentence would be a lie here.")
    }

    /// An empty configured set is the AMBIGUOUS reading: a phone that has not
    /// broadcast yet, a wrist still hydrating, or a Keychain blackout all look
    /// identical to a genuinely un-set-up install. So the existing sentence and
    /// its existing meaning survive — no accusation against the default.
    func testHeadlessCaptureKeepsTheOriginalSentenceWhenNothingIsConfigured() async {
        let service = WatchRecordingService()
        service.store = ConversationStore(inMemory: true)
        clearCouriedGateways()
        XCTAssertTrue(WatchSettingsReader.shared.configuredBackendRefs().isEmpty,
                      "Control: the teardown must genuinely empty the configured set.")

        let resolution = await service.resolveHeadlessCaptureTarget()

        guard case .refused(let message) = resolution else {
            return XCTFail("Nothing configured still refuses before the mic — the turn could never have been sent.")
        }
        XCTAssertEqual(message, String(localized: "Set up your personal AI on iPhone first."),
                       "The ambiguous reading keeps the first-run sentence verbatim.")
    }

    func testHeadlessCaptureProceedsWhenTheDefaultIsConfigured() async {
        let service = WatchRecordingService()
        service.store = ConversationStore(inMemory: true)
        stageGateways([(ref: "openclaw", name: nil)], default: "openclaw")
        WatchSettingsReader.shared.clearActiveConversation()

        let resolution = await service.resolveHeadlessCaptureTarget()

        XCTAssertEqual(resolution, .capture(.new(backendRef: "openclaw")),
                       "A healthy default with no live pointer resolves to a fresh draft bound to it.")
        XCTAssertEqual(service.state, .idle,
                       "The happy path is as silent as it ever was — the resolver writes no state.")
    }

    /// A forgotten custom whose roster entry AND retired badge are both gone
    /// resolves to the generic "Custom gateway" label, which names nothing. The
    /// sentence drops the name rather than guessing — and never falls back to
    /// the raw ref or the URL (I5).
    func testARefusalForAnUnnameableDefaultDropsTheNameRatherThanGuessing() async {
        let service = WatchRecordingService()
        service.store = ConversationStore(inMemory: true)
        let orphanRef = "custom_\(UUID().uuidString)"
        stageGateways([(ref: "hermes", name: nil)], default: orphanRef)

        let resolution = await service.resolveHeadlessCaptureTarget()

        guard case .refused(let message) = resolution else {
            return XCTFail("A default outside the configured set must refuse however it is named.")
        }
        XCTAssertEqual(message, String(localized: LocalizedStringResource(
            "watch.capture.noDefaultGatewayNamed",
            defaultValue: "Choose which AI new chats use, on your iPhone."
        )), "No honest name available → the unnamed sentence, unchanged.")
        XCTAssertFalse(message.contains("custom_"),
                       "A raw ref is not a name and must never reach the wrist's copy.")
        XCTAssertFalse(message.contains(orphanRef.replacingOccurrences(of: "custom_", with: "")),
                       "The gateway's uuid must never appear in user copy.")
        XCTAssertFalse(message.lowercased().contains("http"),
                       "A gateway URL must never appear in user copy (I5).")
    }

    /// The wrist was the last surface still guessing. Its only gate was "is the
    /// couriered default a member of the configured set?", and when the iPhone
    /// has chosen NOTHING it couriers its compatibility fallback — so on a device
    /// where that fallback happens to be configured, the membership test waved
    /// every headless capture through to a gateway the user never picked, and
    /// `createConversation` sealed the binding for good (I1). Every picker-less
    /// lane on the phone refuses this exact device state; the wrist now does too.
    func testHeadlessCaptureRefusesWhenTheIPhoneHasChosenNoDefault() async {
        let service = WatchRecordingService()
        service.store = ConversationStore(inMemory: true)
        // The couriered default IS configured here — the whole point. Under the
        // membership test alone this reads as a perfectly healthy default.
        stageGateways([(ref: "openclaw", name: nil), (ref: "hermes", name: nil)],
                      default: "openclaw", chosen: false)

        let resolution = await service.resolveHeadlessCaptureTarget()

        guard case .refused(let message) = resolution else {
            return XCTFail("A default nobody chose must not become the destination of a headless capture.")
        }
        XCTAssertEqual(message, String(localized: LocalizedStringResource(
            "watch.capture.noDefaultGatewayNamed",
            defaultValue: "Choose which AI new chats use, on your iPhone."
        )), "There is no chosen default to name, so the unnamed sentence carries it.")
        XCTAssertFalse(message.contains("OpenClaw"),
                       "Naming the fallback would accuse a gateway that is working fine and was never picked.")

        // The control that keeps this from passing vacuously: the identical
        // roster with the identical default, chosen, proceeds.
        stageGateways([(ref: "openclaw", name: nil), (ref: "hermes", name: nil)],
                      default: "openclaw", chosen: true)
        let allowed = await service.resolveHeadlessCaptureTarget()
        guard case .capture(.new(let backendRef)) = allowed else {
            return XCTFail("Control: a chosen, configured default must still proceed straight to the mic.")
        }
        XCTAssertEqual(backendRef, "openclaw")
    }

    /// THE WRIST'S HALF OF THE SAME REGRESSION. Running the gateway gate before
    /// the pointer branch looks safe — the pointer branch only continues a thread
    /// bound to the couriered default — until you notice that under "no chosen
    /// default" the couriered ref IS the iPhone's compatibility fallback, which
    /// may itself be configured here. That ordering refuses a wrist whose
    /// quick-lane thread is live and healthy, while every lane on the phone
    /// continues it.
    ///
    /// Continuing a thread is not a reroute: the conversation is already bound,
    /// nothing is minted, and nothing is sealed to a gateway nobody picked (I1).
    func testHeadlessCaptureContinuesALiveThreadWhenTheIPhoneHasChosenNoDefault() async throws {
        let store = ConversationStore(inMemory: true)
        let service = WatchRecordingService()
        service.store = store
        stageGateways([(ref: "openclaw", name: nil), (ref: "hermes", name: nil)],
                      default: "openclaw", chosen: false)
        let record = try await store.createConversation(backend: "openclaw")
        WatchSettingsReader.shared.recordActiveConversation(record.id)

        let resolution = await service.resolveHeadlessCaptureTarget()

        XCTAssertEqual(resolution, .capture(.existing(record.id)),
                       "The thread is live and its gateway can send — a verdict about the DEFAULT has no "
                       + "authority over a capture that never touches it.")

        // The control that keeps this from passing vacuously: drop the pointer
        // and the identical device state refuses, exactly as it always has.
        WatchSettingsReader.shared.clearActiveConversation()
        let refused = await service.resolveHeadlessCaptureTarget()
        guard case .refused = refused else {
            return XCTFail("Control: with no live pointer this is a NEW chat, and an unchosen default must refuse it.")
        }
    }

    /// THE TWIN (I1). The pointer's thread is bound to the couriered default and
    /// that gateway is NOT set up here. A binding is permanent, so the refusal
    /// stands exactly as it does with no pointer at all — the wrist never rescues
    /// a thread onto a working gateway.
    func testHeadlessCaptureRefusesALiveThreadBoundToAnUnconfiguredGateway() async throws {
        let store = ConversationStore(inMemory: true)
        let service = WatchRecordingService()
        service.store = store
        stageGateways([(ref: "hermes", name: nil)], default: "openclaw")
        let record = try await store.createConversation(backend: "openclaw")
        WatchSettingsReader.shared.recordActiveConversation(record.id)

        let resolution = await service.resolveHeadlessCaptureTarget()

        guard case .refused(let message) = resolution else {
            return XCTFail("A live pointer is not a licence to record into a gateway that cannot send.")
        }
        XCTAssertNil(resolution.captureTarget)
        XCTAssertTrue(message.contains("OpenClaw"),
                      "The refusal names the gateway the user chose, so they fix the right one.")
    }

    /// THE CROSS-PLATFORM TABLE. `WatchRecordingService.liveCaptureCanContinue`
    /// is the wrist's sibling of `SharedInboxRouting.liveQuickCaptureCanContinue`
    /// — a separate target links none of the phone's routing code, so the rule is
    /// a copy and copies drift. `GigaActionPreflightTests
    /// .testTheLiveCaptureTableAnswersFourWays` walks the identical four rows on
    /// the phone. Change one table and this one has to change with it.
    func testTheWristAnswersThePhonesLiveCaptureTable() {
        // Row 1 — bound to the default, and the default is configured.
        XCTAssertTrue(WatchRecordingService.liveCaptureCanContinue(
            pointerBackend: "openclaw", defaultBackendRef: "openclaw",
            configured: ["openclaw", "hermes"]))
        // Row 2 — bound to the default, which cannot send here.
        XCTAssertFalse(WatchRecordingService.liveCaptureCanContinue(
            pointerBackend: "openclaw", defaultBackendRef: "openclaw",
            configured: ["hermes"]),
            "A bound gateway that cannot send still refuses (I1) — cloning is the user's exit.")
        // Row 3 — bound to a configured gateway that is NOT the default. The
        // implicit lane follows the default, so this is a NEW chat.
        XCTAssertFalse(WatchRecordingService.liveCaptureCanContinue(
            pointerBackend: "hermes", defaultBackendRef: "openclaw",
            configured: ["openclaw", "hermes"]))
        // Row 4 — nothing configured at all: the ambiguous reading (I3), which
        // hands the caller to the gate and its existing sentence.
        XCTAssertFalse(WatchRecordingService.liveCaptureCanContinue(
            pointerBackend: "openclaw", defaultBackendRef: "openclaw", configured: []))
    }

    /// I3 keeps its arm. An EMPTY configured set is the ambiguous reading — a
    /// cold-launched wrist and a Keychain before first unlock look exactly like a
    /// phone that has never been set up — so it keeps the existing sentence
    /// whether or not a default was chosen. Nothing about that reading may become
    /// an accusation.
    func testAnUnchosenDefaultOnAnEmptyRosterKeepsTheAmbiguousSentence() async {
        let service = WatchRecordingService()
        service.store = ConversationStore(inMemory: true)
        let reader = WatchSettingsReader.shared
        // Built inline rather than through `stageGateways` / `clearCouriedGateways`:
        // this needs BOTH an empty roster and an unchosen default at once, and the
        // helpers each own only one of those halves.
        XCTAssertTrue(reader.updateRemoteAgents(multi: RemoteAgentMultiBroadcastEnvelope(
            backends: [],
            defaultBackendRef: "openclaw",
            timestamp: reader.lastRemoteAgentEnvelopeTimestamp + 20_000,
            sessionPolicy: nil,
            clearAll: true,
            defaultBackendChosen: false
        )))
        XCTAssertTrue(reader.configuredBackendRefs().isEmpty, "Control: the roster must genuinely be empty.")
        XCTAssertFalse(reader.hasChosenDefaultBackend, "Control: and no default chosen.")

        let resolution = await service.resolveHeadlessCaptureTarget()

        guard case .refused(let message) = resolution else {
            return XCTFail("Nothing can send here, so the capture must still refuse.")
        }
        XCTAssertEqual(message, String(localized: "Set up your personal AI on iPhone first."),
                       "With nothing configured the reading is ambiguous, and this is the sentence that fits either way.")
    }

    /// The lane the pre-record gate cannot cover inherits the same rule: a
    /// deferred relay drain whose audio already exists must refuse rather than
    /// mint a thread bound to a gateway nobody chose.
    func testTheMintArmRefusesWhenTheIPhoneHasChosenNoDefault() async throws {
        let store = ConversationStore(inMemory: true)
        let service = WatchRecordingService()
        service.store = store
        WatchSettingsReader.shared.clearPendingInAppNewConversationBackend()
        stageGateways([(ref: "openclaw", name: nil), (ref: "hermes", name: nil)],
                      default: "openclaw", chosen: false)
        WatchSettingsReader.shared.clearActiveConversation()

        await service.startConverseHop(transcript: "hello wrist")

        let conversations = try await store.fetchConversations()
        XCTAssertTrue(conversations.isEmpty,
                      "A binding is permanent, so a turn with no chosen destination must leave no thread behind.")
        guard case .error(let message) = service.state else {
            return XCTFail("The refusal must surface as the turn's error, not vanish into a silent reset.")
        }
        XCTAssertFalse(message.contains("OpenClaw"))
    }

    /// The ordering lock. `resolveHeadlessCaptureTarget` runs BEFORE the
    /// liveness ladder in `WatchNoteView.drainCoordinatorIfNeeded`, so a
    /// resolver that wrote `.error` itself would wipe a live turn's thinking
    /// view — and on a `.recording` machine would orphan a hot mic that
    /// `stopRecording` (guarded on `state == .recording`) could never stop.
    /// The verdict is a value; only the caller may act on it.
    func testResolvingAHeadlessTargetNeverWritesTheRecordingState() async {
        let service = WatchRecordingService()
        service.store = ConversationStore(inMemory: true)
        let startedAt = Date()
        service.state = .waiting(startedAt: startedAt)
        stageGateways([(ref: "hermes", name: nil)], default: "openclaw")

        let resolution = await service.resolveHeadlessCaptureTarget()

        guard case .refused = resolution else {
            return XCTFail("Control: this staging must genuinely produce a refusal, or the lock is vacuous.")
        }
        XCTAssertEqual(service.state, .waiting(startedAt: startedAt),
                       "The resolver must leave the live turn exactly as it found it.")
    }

    /// I1 on the wrist: a conversation is locked to the gateway it was created
    /// with. One whose gateway is gone keeps its binding and its existing
    /// refusal — it is never rescued onto a configured gateway, even when the
    /// roster has two of them sitting right there.
    func testBoundConversationWithAMissingGatewayIsRefusedNotRerouted() async throws {
        let store = ConversationStore(inMemory: true)
        let service = WatchRecordingService()
        service.store = store
        let goneRef = "custom_\(UUID().uuidString)"
        let record = try await store.createConversation(backend: goneRef)
        stageGateways([(ref: "hermes", name: nil), (ref: "openclaw", name: nil)], default: "openclaw")

        let sent = await service.sendTypedText("hello wrist", into: record.id)
        XCTAssertTrue(sent, "Control: the send must actually be attempted, not refused as a no-op.")

        let conversations = try await store.fetchConversations()
        XCTAssertEqual(conversations.count, 1,
                       "A bound turn must never mint a second conversation to escape its dead gateway.")
        XCTAssertEqual(conversations.first?.backend, goneRef,
                       "The binding is the user's choice — a live roster is not permission to rewrite it.")
        XCTAssertEqual(service.state,
                       .error(message: String(localized: "setup.requiredOnPhone",
                                              defaultValue: "Set up your AI on iPhone first.")),
                       "The bound refusal keeps today's copy: the gateway gate is about the DEFAULT pointer, not about a bound thread.")
    }

    /// The lane the pre-record gate cannot cover: a deferred relay drain, or a
    /// relaunched background-STT process whose one-shot Ask hint is already
    /// gone. The audio exists, so the mint arm runs — and must refuse BEFORE
    /// `createConversation`, or the user is left with an orphan thread bound to
    /// a gateway that cannot answer it.
    func testTheDefaultBoundMintArmRefusesInsteadOfMintingAnOrphan() async throws {
        let store = ConversationStore(inMemory: true)
        let service = WatchRecordingService()
        service.store = store
        WatchSettingsReader.shared.clearPendingInAppNewConversationBackend()
        stageGateways([(ref: "hermes", name: nil)], default: "openclaw")
        WatchSettingsReader.shared.clearActiveConversation()

        await service.startConverseHop(transcript: "hello wrist")

        let conversations = try await store.fetchConversations()
        XCTAssertTrue(conversations.isEmpty,
                      "Nothing may be minted for a turn that can never be sent.")
        guard case .error(let message) = service.state else {
            return XCTFail("The refusal must surface as the turn's error, not vanish into a silent reset.")
        }
        XCTAssertTrue(message.contains("OpenClaw"),
                      "The mint arm carries the same named sentence the pre-record gate would have shown.")
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
