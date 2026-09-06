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
// 5. The Ask DESTINATION chooser's service half. Ask offers every configured
//    gateway and then Add to Work on every press, so the two lanes sit one tap
//    apart on one sheet: an explicit gateway row must bind to the ref the
//    person picked even where a headless press would be refused outright, a
//    pick of either lane must inherit nothing from an abandoned pick of the
//    other, and a full relay queue must refuse the Work row BEFORE the
//    microphone arms without disturbing a single recording already waiting on
//    the iPhone.

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
        service.relayTranscribe = { _, audioFileURL, _, _, _ in
            queued.url = audioFileURL
            for await _ in gate {}
            return RelayReply(text: "resurrected transcript", workSaved: false)
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
        service.relayTranscribe = { _, _, _, _, _ in RelayReply(text: "hello from the wrist", workSaved: false) }

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

    // MARK: - Ask destination chooser (gateway rows vs the Work row)
    //
    // The chooser opens on EVERY Ask press and offers the desk beside the
    // gateways, so the two lanes are now one tap apart on the same sheet. The
    // view wiring is founder-QA territory; what is pinned here is the SERVICE
    // behaviour those rows depend on — an explicit gateway pick binds to the ref
    // the person picked no matter what the headless default gate says, and a
    // pick of either lane inherits nothing from an abandoned pick of the other.

    /// Poll until `condition` holds (or the timeout elapses), sleeping so the
    /// arm Task can make progress between checks.
    private func settle(timeout: TimeInterval = 5.0, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// A row in the chooser is an EXPLICIT choice, and it is written as the Ask
    /// hint regardless of the headless default gate: `hasChosenDefaultBackend`
    /// is false here, which refuses a headless press outright, and must not
    /// touch a capture the person routed by hand.
    func testAnExplicitGatewayPickWritesItsHintWithNoChosenDefault() {
        stageGateways([(ref: "hermes", name: nil)], default: "hermes", chosen: false)
        let service = WatchRecordingService()
        service.store = ConversationStore(inMemory: true)
        // Nothing arms: the permission denial is the cheapest way to keep a
        // microphone out of a unit-test host, and every assertion below is
        // written synchronously by `startCapture` before the arm Task runs.
        service.recordPermissionRequest = { false }

        let outcome = service.startCapture(boundTo: .new(backendRef: "hermes"), requestID: UUID())

        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(WatchSettingsReader.shared.consumePendingInAppNewConversationBackend(), "hermes",
                       "An explicit gateway row must stamp its own ref, not defer to the default gate.")
        XCTAssertEqual(service.captureDestination, .chat,
                       "A gateway row is a chat ask — the Work stamp belongs to `startWorkCapture` alone.")
        service.cancelRecording()
    }

    /// The other half of that contract, one hop later: the mint binds to the
    /// CAPTURED ref even though the iPhone has chosen no default at all. The
    /// captured ref is a never-configured custom, so the hop stops at the
    /// config gate AFTER the mint — the mint mechanics run with zero network.
    func testAHintDrivenMintBypassesTheDefaultGate() async throws {
        stageGateways([(ref: "hermes", name: nil)], default: "hermes", chosen: false)
        let store = ConversationStore(inMemory: true)
        let service = WatchRecordingService()
        service.store = store
        let capturedRef = RemoteAgentRef.custom(UUID()).rawString
        WatchSettingsReader.shared.setPendingInAppNewConversationBackend(capturedRef)

        await service.startConverseHop(transcript: "hello wrist")

        let conversations = try await store.fetchConversations()
        XCTAssertEqual(conversations.count, 1,
                       "The hint arm mints exactly one conversation, unchosen default or not.")
        XCTAssertEqual(conversations.first?.backend, capturedRef,
                       "The mint must bind to the ref the chooser row carried.")
        guard case .error = service.state else {
            return XCTFail("An unconfigured captured ref must surface the not-configured error (control: no network was reached).")
        }
    }

    /// The chooser's two lanes share one machine, so the dangerous direction is
    /// a gateway pick abandoned mid-flight followed by a Work pick: the desk
    /// must inherit NOTHING from it. Preconditioned on `.idle` — entering Work
    /// from `.error` runs `dismissError()`, which clears the hint by itself and
    /// would make this vacuous — and the stale hint is seeded IMMEDIATELY
    /// before the start, because a cancel already clears it.
    ///
    /// SCOPE: this case owns the stale HINT and the "Work mints nothing"
    /// floor, both genuine from an idle machine. The conversation PIN is a
    /// different fixture — an idle machine has no pin to inherit — so the two
    /// cases below establish a real one first and assert the precondition
    /// before starting Work. Deliberately NO pin assertion here: it would start
    /// nil and end nil, staying green with `startWorkCapture`'s own pin clears
    /// deleted, which is exactly the tautology those two cases exist to remove.
    func testAWorkPickAfterAnAbandonedGatewayDraftInheritsNothing() async throws {
        let store = ConversationStore(inMemory: true)
        let service = WatchRecordingService()
        service.store = store
        service.recordPermissionRequest = { false }
        XCTAssertEqual(service.state, .idle,
                       "Precondition: from `.error` the Work start would clear the hint through `dismissError()`.")
        let mintsBefore = service.captureMintCount
        let rowsBefore = try await store.fetchConversations().count

        WatchSettingsReader.shared.setPendingInAppNewConversationBackend(RemoteAgentRef.custom(UUID()).rawString)
        let outcome = service.startWorkCapture(requestID: UUID())

        XCTAssertEqual(outcome, .started)
        XCTAssertNil(WatchSettingsReader.shared.consumePendingInAppNewConversationBackend(),
                     "A Work capture must clear the Ask hint — an unconsumed one would give it a conversation.")
        XCTAssertEqual(service.captureDestination, .work)
        XCTAssertEqual(service.captureMintCount, mintsBefore)
        let rowsAfter = try await store.fetchConversations().count
        XCTAssertEqual(rowsAfter, rowsBefore,
                       "A Work start mints nothing in the synced store.")
        service.cancelRecording()
    }

    /// The pin half, with a pin that genuinely exists: an in-thread capture
    /// bound to a conversation, abandoned when the microphone was refused. The
    /// machine still names that conversation when the Work row is picked, and
    /// the desk must not adopt it — a Work capture that kept a chat pin would
    /// settle a private recording through a conversation-bound path.
    ///
    /// The machine is walked back to `.idle` with the pin still on it before
    /// Work starts, and that is the whole point of the fixture: entering Work
    /// from `.error` runs `dismissError()`, whose own clears would answer the
    /// assertion below no matter what `startWorkCapture` did. From `.idle` the
    /// only clears left are `startWorkCapture`'s, so deleting one turns this
    /// case red. The state is reachable in production the same way — an older
    /// turn's reply landing against a newer turn's marker returns the machine to
    /// `.idle` without touching the pins.
    func testAWorkPickAfterADeniedBoundCaptureInheritsNoConversationPin() async {
        let service = WatchRecordingService()
        service.store = ConversationStore(inMemory: true)
        service.recordPermissionRequest = { false }
        let bound = UUID()

        service.startCapture(boundTo: .existing(bound), requestID: UUID())
        await settle { if case .error = service.state { return true } else { return false } }
        guard case .error = service.state else {
            return XCTFail("A denied capture must surface the microphone error, or the pin below is not abandoned.")
        }
        XCTAssertEqual(service.inFlightConversationID, bound,
                       "Precondition: the machine genuinely holds the abandoned turn's conversation pin.")
        service.state = .idle
        XCTAssertEqual(service.inFlightConversationID, bound,
                       "Precondition: the walk back to idle leaves the pin standing — otherwise Work clears nothing.")

        let outcome = service.startWorkCapture(requestID: UUID())

        XCTAssertEqual(outcome, .started)
        XCTAssertNil(service.inFlightConversationID,
                     "Work has no conversation — it must not carry the abandoned thread's pin into the desk lane.")
        XCTAssertEqual(service.captureDestination, .work)
        service.cancelRecording()
    }

    /// The same guarantee for the OTHER pin: a draft that reached the mint and
    /// then died at the gateway gate leaves a minted conversation on the
    /// machine. The Work row must leave that conversation exactly where it is
    /// — neither adopted, nor added to, nor minted over.
    func testAWorkPickAfterAMintedDraftInheritsNoConversationPin() async throws {
        stageGateways([(ref: "hermes", name: nil)], default: "hermes", chosen: false)
        let store = ConversationStore(inMemory: true)
        let service = WatchRecordingService()
        service.store = store
        service.recordPermissionRequest = { false }
        // A never-configured custom: the mint runs, the hop then stops at the
        // config gate, and zero network is reached.
        WatchSettingsReader.shared.setPendingInAppNewConversationBackend(RemoteAgentRef.custom(UUID()).rawString)

        await service.startConverseHop(transcript: "hello wrist")

        guard case .error = service.state else {
            return XCTFail("Precondition: the unconfigured ref must surface the not-configured error.")
        }
        let minted = try XCTUnwrap(service.inFlightConversationID,
                                   "Precondition: the hint arm mints and PINS a conversation — without it this asserts nothing.")
        XCTAssertEqual(service.captureMintCount, 1)
        let rowsBefore = try await store.fetchConversations()
        XCTAssertEqual(rowsBefore.count, 1)
        // Idle WITH the mint still pinned — the state `startWorkCapture`'s own
        // clears are the only answer to. From `.error` the entry's
        // `dismissError()` would clear it first and the assertion below would
        // hold with those clears deleted.
        service.state = .idle
        XCTAssertEqual(service.inFlightConversationID, minted,
                       "Precondition: the walk back to idle leaves the minted pin standing.")

        let outcome = service.startWorkCapture(requestID: UUID())

        XCTAssertEqual(outcome, .started)
        XCTAssertNil(service.inFlightConversationID,
                     "A Work capture must not adopt the conversation an abandoned draft minted.")
        XCTAssertEqual(service.captureDestination, .work)
        XCTAssertEqual(service.captureMintCount, 1, "Work mints nothing of its own.")
        let rowsAfter = try await store.fetchConversations()
        XCTAssertEqual(rowsAfter.count, 1, "…and adds nothing to the synced store.")
        XCTAssertEqual(rowsAfter.first?.id, minted,
                       "The abandoned draft's conversation is left exactly as it was.")
        service.cancelRecording()
    }

    /// The reverse direction, and the one a cancel would fake: a DENIED Work
    /// capture leaves the lane stamped `.work`, and the next gateway row must
    /// re-stamp it `.chat` rather than force the relay and settle a chat ask
    /// onto the desk.
    func testAGatewayPickAfterADeniedWorkCaptureIsChat() async {
        let service = WatchRecordingService()
        service.store = ConversationStore(inMemory: true)
        service.recordPermissionRequest = { false }

        service.startWorkCapture(requestID: UUID())
        // The denial is async — assert the state it actually leaves behind, or
        // the gateway start below would be superseding nothing.
        await settle { if case .error = service.state { return true } else { return false } }
        guard case .error = service.state else {
            return XCTFail("A denied Work capture must surface the microphone error.")
        }
        XCTAssertEqual(service.captureDestination, .work,
                       "Control: the lane is genuinely stamped Work before the gateway pick.")

        service.startCapture(boundTo: .new(backendRef: "hermes"), requestID: UUID())

        XCTAssertEqual(service.captureDestination, .chat,
                       "A gateway row must never inherit Work's lane.")
        service.cancelRecording()
    }

    /// The deferral the chooser makes routine: a gateway row picked, the iPhone
    /// out of range, and the settlement landing minutes later in a process that
    /// never saw the pick. The pick lives on the QUEUE ENTRY because nowhere
    /// else can hold it — a `.new` draft has no conversation to pin, and the
    /// one-shot Ask hint belongs to the live hop and is deliberately not
    /// consumable here — so the deferred mint binds to THAT gateway rather than
    /// to whichever one happens to be default by the time the phone comes back.
    func testADeferredAskMintsAgainstTheGatewayItWasAddressedTo() async throws {
        stageGateways([(ref: "hermes", name: nil)], default: "hermes")
        let store = ConversationStore(inMemory: true)
        let service = WatchRecordingService()
        service.store = store
        let picked = RemoteAgentRef.custom(UUID()).rawString
        XCTAssertNotEqual(picked, WatchSettingsReader.shared.defaultBackendRef,
                          "Control: the pick must differ from the default, or the fall-through arm would pass this vacuously.")

        await service.startDeferredConverseHop(
            transcript: "an older ask",
            boundTo: nil,
            addressedTo: picked
        )

        let rows = try await store.fetchConversations()
        XCTAssertEqual(rows.count, 1, "One deferred turn, one conversation.")
        XCTAssertEqual(rows.first?.backend, picked,
                       "Words addressed to one gateway must never be delivered to another.")
    }

    /// A private save owns the machine for its whole relay leg, and no gateway
    /// reply can ever be its completion. An older Chat turn's reply landing
    /// there must not release it: the next capture would take a machine whose
    /// Work pipeline is still running, and that pipeline's own
    /// `recordingFileURL = nil` would null the replacement's handle — the
    /// person's Stop then finds no recording.
    func testAnOlderChatReplyDoesNotReleaseALiveWorkSave() {
        let service = WatchRecordingService()
        service.store = ConversationStore(inMemory: true)
        service.recordPermissionRequest = { false }

        XCTAssertEqual(service.startWorkCapture(requestID: UUID()), .started)
        XCTAssertEqual(service.captureDestination, .work,
                       "Control: the machine really is running the Work lane.")
        // The relay leg. `processRecording` enters `.uploading` the moment the
        // recorder stops and stays there for the whole publish/transcribe round
        // trip; this is that window, without a microphone.
        service.state = .uploading

        service.handleBackgroundReply(
            "an answer to something else",
            conversationID: UUID(),
            messageID: UUID()
        )

        XCTAssertEqual(service.state, .uploading,
                       "The save still owns the machine — a reply that belongs to no capture on it may not hand it over.")
        XCTAssertEqual(service.captureDestination, .work)
        service.cancelRecording()
    }

    /// The same reply, against the OTHER machine a pin cannot describe: an Ask
    /// that has not minted yet. Relaunch with an older turn outstanding, press
    /// Ask before the restore's fetch resolves, pick a gateway — the draft is
    /// uploading with `pendingConversationID` and `mintedConversationID` both
    /// nil, so a pin-only guard reads the older turn's reply as this capture's
    /// completion. The pick lives ONLY in the one-shot Ask hint until the hop
    /// consumes it, so releasing the machine here both strips the capture of
    /// the gateway the person chose (it would resolve through the default) and
    /// admits a second capture on top of a live upload.
    func testAnOlderChatReplyDoesNotStripANewUnmintedAskOfItsGateway() {
        let appGroup = TestStores.defaults
        defer {
            appGroup.removeObject(forKey: "watch.inFlight.conversationID")
            appGroup.removeObject(forKey: "watch.inFlight.startedAt")
            appGroup.removeObject(forKey: "watch.inFlight.turnID")
        }
        // Relaunch state: an older gateway turn's marker is still persisted and
        // its reply has not landed yet.
        let older = UUID()
        appGroup.set(older.uuidString, forKey: "watch.inFlight.conversationID")
        appGroup.set(Date().timeIntervalSinceReferenceDate, forKey: "watch.inFlight.startedAt")

        let service = WatchRecordingService()
        service.store = ConversationStore(inMemory: true)
        service.recordPermissionRequest = { false }
        let picked = RemoteAgentRef.custom(UUID()).rawString

        XCTAssertEqual(service.startCapture(boundTo: .new(backendRef: picked), requestID: UUID()), .started)
        XCTAssertNil(service.inFlightConversationID,
                     "Control: a `.new` draft pins nothing until the hop mints — the state this case is about.")
        // The relay leg: `.uploading` from the moment the recorder stops until
        // the transcript comes back, without a microphone.
        service.state = .uploading

        service.handleBackgroundReply(
            "an answer to the older turn",
            conversationID: older,
            messageID: UUID()
        )

        XCTAssertEqual(service.state, .uploading,
                       "An older turn's reply may not release a capture that is still uploading.")
        XCTAssertEqual(WatchSettingsReader.shared.peekPendingInAppNewConversationBackend(), picked,
                       "The pick lives only in the hint until the hop consumes it — clearing it re-routes the "
                       + "person's words to whichever gateway happens to be default.")
        XCTAssertNil(appGroup.string(forKey: "watch.inFlight.conversationID"),
                     "The dead turn's persisted marker still goes — it is the live capture's state that must not.")
        service.cancelRecording()
    }

    /// The failure counterpart of `testAnOlderChatReplyDoesNotReleaseALiveWorkSave`,
    /// and the same defect through the other door: an older Chat turn FAILING
    /// while a private save owns the machine. Work has no conversation to pin,
    /// so a pin-only guard permits `state = .error` — which returns the wrist to
    /// a screen that admits another capture while Work's pipeline is still
    /// running, and that pipeline's `recordingFileURL = nil` then erases the
    /// replacement recording's handle.
    func testAnOlderChatFailureDoesNotReleaseALiveWorkSave() {
        let service = WatchRecordingService()
        service.store = ConversationStore(inMemory: true)
        service.recordPermissionRequest = { false }

        XCTAssertEqual(service.startWorkCapture(requestID: UUID()), .started)
        XCTAssertEqual(service.captureDestination, .work,
                       "Control: the machine really is running the Work lane.")
        service.state = .uploading

        service.handleBackgroundFailure("an older turn failed", conversationID: UUID())

        XCTAssertEqual(service.state, .uploading,
                       "The save still owns the machine — a failure that belongs to no capture on it may not "
                       + "hand it over.")
        XCTAssertEqual(service.captureDestination, .work)
        service.cancelRecording()
    }

    /// And the unminted Ask, failing side. Same machine as the reply case
    /// above: a live draft with no pin yet, and an older turn's failure that a
    /// pin-only guard reads as its own.
    func testAnOlderChatFailureDoesNotReleaseANewUnmintedAsk() {
        let service = WatchRecordingService()
        service.store = ConversationStore(inMemory: true)
        service.recordPermissionRequest = { false }
        let picked = RemoteAgentRef.custom(UUID()).rawString

        XCTAssertEqual(service.startCapture(boundTo: .new(backendRef: picked), requestID: UUID()), .started)
        XCTAssertNil(service.inFlightConversationID,
                     "Control: nothing is pinned yet, which is why the pin alone cannot answer this.")
        service.state = .uploading

        service.handleBackgroundFailure("an older turn failed", conversationID: UUID())

        XCTAssertEqual(service.state, .uploading,
                       "An older turn's failure must not surface as this capture's, nor free the machine under it.")
        XCTAssertEqual(WatchSettingsReader.shared.peekPendingInAppNewConversationBackend(), picked,
                       "…and it must not take the pick with it.")
        service.cancelRecording()
    }

    /// The upgrade case the queue cannot ask anybody about: an entry written by
    /// a build that predates `Entry.backendRef`, so it carries neither a pin nor
    /// an addressed gateway. What it DOES tell us is that the capture was
    /// always-new — every capture that continues a thread pins it — so the
    /// replay mints its own conversation. Continuing whichever thread the
    /// pointer happens to hold minutes later would put words the person spoke
    /// into a new chat inside an existing one.
    func testALegacyUnboundDeferredAskMintsInsteadOfContinuingTheActiveThread() async throws {
        // Nothing configured, so the hop mints and then stops at the
        // not-configured gate — the mint is the whole measurement, and no
        // network is reachable.
        let store = ConversationStore(inMemory: true)
        let service = WatchRecordingService()
        service.store = store
        let reader = WatchSettingsReader.shared
        let pointed = try await store.createConversation(backend: reader.defaultBackendRef)
        reader.recordActiveConversation(pointed.id)
        XCTAssertEqual(reader.resolveActiveConversationID(), pointed.id,
                       "Control: the pointer is fresh and resolvable, or the arm this case removes is never reached.")
        XCTAssertEqual(pointed.backend, reader.defaultBackendRef,
                       "Control: the pointed thread is bound to the CURRENT default, which is what the pointer arm "
                       + "requires before it continues one.")

        await service.startDeferredConverseHop(transcript: "an older ask", boundTo: nil)

        let rows = try await store.fetchConversations()
        XCTAssertEqual(rows.count, 2,
                       "A replayed always-new capture mints its own conversation: \(rows.map(\.backend))")
        XCTAssertEqual(service.captureMintCount, 1)
        XCTAssertNotEqual(service.inFlightConversationID, pointed.id,
                          "The deferred turn must not be resolved into the thread the pointer happens to name.")
    }

    /// A dismissed Work error leaves the lane stamped `.work`, and the deferred
    /// drain takes the machine over without passing `startCapture` — the one
    /// entry point that stamps. So the deferred hop stamps it itself: a real
    /// gateway turn running under the launchpad's "Saving to Work…" caption is
    /// the one sentence this lane must never show.
    func testADeferredChatTurnClearsAStaleWorkStamp() async {
        let service = WatchRecordingService()
        service.store = ConversationStore(inMemory: true)
        service.recordPermissionRequest = { false }

        service.startWorkCapture(requestID: UUID())
        await settle { if case .error = service.state { return true } else { return false } }
        XCTAssertEqual(service.captureDestination, .work,
                       "Control: the lane is genuinely stamped Work before the deferred turn.")
        service.dismissError()
        XCTAssertEqual(service.captureDestination, .work,
                       "Control: dismissing the error does not un-stamp the lane — that is why the hop must.")

        await service.startDeferredConverseHop(transcript: "an older ask", boundTo: nil)

        XCTAssertEqual(service.captureDestination, .chat,
                       "A gateway turn must never be described to the person as a save to Work.")
    }

    /// The capacity hand-off the chooser now reaches one tap sooner. Work
    /// entries are eviction-exempt, so a full queue refuses the pick BEFORE the
    /// microphone arms — and, far more importantly, without disturbing a single
    /// recording already waiting on the iPhone.
    func testAFullQueueRefusesTheWorkPickBeforeArmingAndKeepsEveryQueuedRecording() throws {
        let queue = AppleRelayPendingQueue.shared
        XCTAssertLessThan(queue.entryCount, AppleRelayPendingQueue.maxEntryCount,
                          "Control: a sibling left the relay queue at capacity, so this case would seed nothing.")

        var seeded: [(id: String, bytes: Data)] = []
        defer {
            // Only the entries this case created — `StorageTestSupport`
            // isolates defaults and secrets, not the queue's audio directory.
            for entry in seeded { _ = queue.claimEntry(requestID: entry.id) }
        }
        var filler: UInt8 = 0x10
        while queue.entryCount < AppleRelayPendingQueue.maxEntryCount {
            let id = "work-capacity-\(UUID().uuidString)"
            let bytes = Data(repeating: filler, count: 2048)
            filler &+= 1
            let source = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(id).m4a")
            try bytes.write(to: source)
            queue.enqueue(requestID: id, audioFileURL: source, language: nil, destination: .work)
            seeded.append((id: id, bytes: bytes))
        }
        XCTAssertFalse(seeded.isEmpty, "Control: the queue must have been filled by THIS case.")

        final class CallBox: @unchecked Sendable {
            var permission = 0
            var activation = 0
        }
        let calls = CallBox()
        let service = WatchRecordingService()
        service.store = ConversationStore(inMemory: true)
        service.recordPermissionRequest = { calls.permission += 1; return false }
        service.recordSessionActivator = { calls.activation += 1 }

        let request = UUID()
        let outcome = service.startWorkCapture(requestID: request)

        XCTAssertEqual(outcome, .refusedBusy)
        XCTAssertEqual(calls.permission, 0, "The refusal must come BEFORE the microphone is asked for.")
        XCTAssertEqual(calls.activation, 0, "…and before the audio session is activated.")
        XCTAssertEqual(service.state, .idle, "Nothing was armed, so the machine stays idle.")
        XCTAssertEqual(service.workCaptureID, request,
                       "The refusal belongs to the screen this start was pushed for.")
        XCTAssertEqual(service.workCaptureOutcome,
                       .refused(reason: WatchWorkCaptureRefusal.queueFull.message))
        XCTAssertEqual(service.captureDestination, .chat,
                       "The lane stamp is written only on an ACCEPTED start.")

        for entry in seeded {
            let queued = try XCTUnwrap(queue.peekEntry(requestID: entry.id),
                                       "A refused Work pick must evict nothing — entry \(entry.id.prefix(8)) is gone.")
            let bytes = try Data(contentsOf: URL(fileURLWithPath: queued.audioFilePath))
            XCTAssertEqual(bytes, entry.bytes,
                           "A queued recording exists nowhere else; its bytes must survive the refusal intact.")
        }
    }

    /// A deferred dispatch is UNPINNED for its whole first suspension — it
    /// occupies the machine synchronously and only creates its conversation
    /// several awaits later — and an unowned `.waiting` is exactly the shape
    /// `liveTurnOwns` reads as a RESTORED wait. So an older Chat reply landing
    /// in that window used to take the machine back to `.idle`, which admits a
    /// Work capture; the hop then resumed, wrote `.waiting` over the live
    /// recording, and `stopRecording()` refused to save it because the state was
    /// no longer `.recording`. The person's words reached nothing at all.
    ///
    /// Reproduced at the boundary that matters — the machine's state during the
    /// hop's unminted window — rather than by racing a real await.
    func testAnOlderChatReplyCannotReleaseTheMachineUnderADeferredDispatch() async {
        let service = WatchRecordingService()
        service.store = ConversationStore(inMemory: true)
        // No gateway is configured, so the hop mints nothing and lands on the
        // not-configured error — the mint is not what this case measures.
        let older = UUID()

        // The synchronous half of `startDeferredConverseHop`, which is the whole
        // of the window: `.waiting`, no pin, and nothing minted yet.
        let hop = Task { await service.startDeferredConverseHop(transcript: "an older ask", boundTo: nil) }
        await Task.yield()
        XCTAssertNil(service.inFlightConversationID,
                     "Control: the hop holds no pin yet, which is why the pin alone cannot answer this.")

        service.handleBackgroundReply("an answer to something else",
                                      conversationID: older,
                                      messageID: UUID())

        if case .idle = service.state {
            XCTFail("An older turn's reply released the machine under a live deferred dispatch. "
                    + "A Work capture starts on that idle machine and the resumed hop writes `.waiting` "
                    + "over its live recording — Stop then saves nothing.")
        }
        await hop.value
        service.dismissError()
    }

    /// The `.work` lane guard in `handleBackgroundFailure`, ISOLATED. Every
    /// other Work fixture also fails the ownership guard beside it, so deleting
    /// the lane guard leaves them green. A nil `conversationID` — the STT
    /// funnel's and the upload watchdog's shape — skips the ownership guard by
    /// design, so it is the only fixture the lane guard alone answers.
    func testAnUnmatchableFailureCannotReleaseALiveWorkSave() {
        let service = WatchRecordingService()
        service.store = ConversationStore(inMemory: true)
        service.recordPermissionRequest = { false }

        XCTAssertEqual(service.startWorkCapture(requestID: UUID()), .started)
        service.state = .uploading

        service.handleBackgroundFailure("an unmatchable turn failed", conversationID: nil)

        XCTAssertEqual(service.state, .uploading,
                       "A nil-conversation failure keeps its takeover for CHAT only — on Work it releases a save "
                       + "whose relay is still running, and that relay's `recordingFileURL = nil` then erases the "
                       + "next capture's handle.")
        XCTAssertEqual(service.captureDestination, .work)
        service.cancelRecording()
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
