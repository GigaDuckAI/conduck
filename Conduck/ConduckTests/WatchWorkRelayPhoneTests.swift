// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WatchWorkRelayPhoneTests.swift
//
// The phone half of the Watch → Work relay. A clip spoken into the wrist is
// transcribed on the iPhone, and this is where it becomes a desk card.
//
// Three claims, and each one has a failure the user pays for:
//   • ORDER. The recording is published BEFORE any transcribe arm runs, and
//     while the temp file still exists — both STT arms hand that URL to
//     `STTClient`, which defer-deletes it. A publication deferred until after
//     transcription would find nothing to publish, and a failed hop would cost
//     the recording rather than just the words.
//   • RETRYABILITY. A phase-1 refusal travels back as a code the wrist's queue
//     LEAVES QUEUED. Claiming an entry deletes the only copy of the audio, so a
//     terminal code on a storage blip destroys a capture the next attempt would
//     have delivered.
//   • ISOLATION. Nothing on this branch touches a conversation, a gateway ref
//     or the converse pipeline. The whole point of a separate destination is
//     that a private thought does not reach an agent; that is asserted
//     STRUCTURALLY here, by reading the coordinator's own source, because the
//     regression would be one added line with no failing behaviour.
//
// PLATFORM GATE: `#if os(iOS)` — `AppleSpeechRelayCoordinator` exists only
// where WatchConnectivity does.

#if os(iOS)

import XCTest
@testable import Conduck

final class WatchWorkRelayPhoneTests: XCTestCase {

    private var stores = IsolatedWorkStores()

    override func tearDown() async throws {
        await stores.cleanUp()
        try await super.tearDown()
    }

    // MARK: - Destination reading

    func testAnAbsentDestinationIsAChatAskAndOnlyWorkIsWork() {
        // Chat is never spelled on the wire, so every shipped wrist build
        // sends nothing here. Reading an unknown value as Work would divert a
        // gateway ask; reading Work as chat would hand a private note to one.
        XCTAssertFalse(AppleSpeechRelayCoordinator.isWorkDestination(nil))
        XCTAssertFalse(AppleSpeechRelayCoordinator.isWorkDestination(""))
        XCTAssertFalse(AppleSpeechRelayCoordinator.isWorkDestination("chat"))
        XCTAssertFalse(AppleSpeechRelayCoordinator.isWorkDestination("workboard"))
        XCTAssertTrue(AppleSpeechRelayCoordinator.isWorkDestination("work"))
    }

    // MARK: - The card id one utterance keeps

    func testARequestIdThatIsAUuidIsTheCardIdItself() {
        // The wrist mints requestIDs as UUIDs, so the common path is an
        // identity — which is what makes the desk write idempotent for a claim
        // token the watch retries verbatim across the inline send, the file
        // fallback and every drain re-fire.
        let requestID = UUID()
        XCTAssertEqual(
            AppleSpeechRelayCoordinator.workCaptureID(forRequestID: requestID.uuidString),
            requestID
        )
    }

    func testAForeignRequestIdStillDerivesOneStableCardId() {
        // A sender whose requestID is not a UUID must still land on ONE card
        // per utterance. A fresh random id here would turn each retry of one
        // recording into another card on the desk.
        let derived = AppleSpeechRelayCoordinator.workCaptureID(forRequestID: "wrist-42")
        XCTAssertEqual(
            derived,
            AppleSpeechRelayCoordinator.workCaptureID(forRequestID: "wrist-42"),
            "the same requestID derives the same card, in this process and any other"
        )
        XCTAssertNotEqual(
            derived,
            AppleSpeechRelayCoordinator.workCaptureID(forRequestID: "wrist-43")
        )
        // RFC 4122 §4.3 name-based, SHA-1: version 5, standard variant.
        XCTAssertEqual((derived.uuid.6 & 0xF0) >> 4, 0x5, "version 5")
        XCTAssertEqual(derived.uuid.8 & 0xC0, 0x80, "standard variant")
    }

    // MARK: - Phase 1: the recording, before the words

    func testARelayedCaptureBecomesAPlayableCardStampedWatchBeforeAnyTranscript() async throws {
        let store = stores.make()
        let requestID = UUID().uuidString
        let recording = Self.recordingBytes

        let cardID = try await AppleSpeechRelayCoordinator.publishRelayedWorkRecording(
            requestID: requestID,
            audio: recording,
            store: store
        )
        XCTAssertEqual(cardID, UUID(uuidString: requestID))

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        let card = try XCTUnwrap(desk.materials.first { $0.id == cardID })
        XCTAssertEqual(card.kind, .audio, "the clip is playable, not a note about a clip")
        XCTAssertEqual(
            card.sourceDevice, "watch",
            """
            the card names the surface the words were SPOKEN at. The phone writes it, so \
            reading the writer's own device would file every wrist note under whichever \
            iPhone happened to be nearby.
            """
        )
        XCTAssertNil(card.textContent, "phase 1 runs before transcription is attempted at all")
        XCTAssertEqual(card.title, WorkVoiceCaptureCoordinator.untranscribedTitle)
        XCTAssertTrue(card.hasPayload)
        XCTAssertEqual(card.mimeType, "audio/mp4")
        let payload = try await store.loadWorkMaterialPayload(id: cardID)
        XCTAssertEqual(payload, recording, "the wrist's bytes read back exactly")
    }

    func testTheClipIsReadOffDiskBeforeTheTranscribeArmsCanDeleteIt() async throws {
        // The file-taking overload is what the live path calls, and its whole
        // job is to take the bytes while they still exist: the caller deletes
        // this URL in a defer, and `STTClient` deletes it from under everyone.
        let store = stores.make()
        let requestID = UUID().uuidString
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        try Self.recordingBytes.write(to: url)

        let cardID = try await AppleSpeechRelayCoordinator.publishRelayedWorkRecording(
            requestID: requestID,
            audioURL: url,
            store: store
        )
        // Exactly what the live path does next.
        try? FileManager.default.removeItem(at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        let payload = try await store.loadWorkMaterialPayload(id: cardID)
        XCTAssertEqual(
            payload, Self.recordingBytes,
            "the desk owns its own copy — the card survives the temp file it came from"
        )
    }

    func testARefireOfOneUtteranceRepairsTheSameCardRatherThanAddingASecond() async throws {
        let store = stores.make()
        let requestID = UUID().uuidString

        let first = try await AppleSpeechRelayCoordinator.publishRelayedWorkRecording(
            requestID: requestID, audio: Self.recordingBytes, store: store
        )
        let second = try await AppleSpeechRelayCoordinator.publishRelayedWorkRecording(
            requestID: requestID, audio: Self.recordingBytes, store: store
        )
        XCTAssertEqual(first, second)

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(
            desk.materials.count, 1,
            "an inline send and its file fallback are one utterance, not two cards"
        )
    }

    func testACaptureIdAlreadyHeldByAnotherKindEscapesInsteadOfStrandingTheWrist() async throws {
        // The refusal is right — a material id names ONE card — but on its own
        // it never clears, so every re-fire of this requestID would refuse
        // identically and the wrist's entry could never leave its queue. Work
        // entries are exempt from the queue's age-out, so "identically for
        // ever" means exactly that.
        let store = stores.make()
        let requestID = UUID().uuidString
        let captureID = AppleSpeechRelayCoordinator.workCaptureID(forRequestID: requestID)
        _ = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                id: captureID,
                kind: .note,
                title: "already here",
                textContent: "already here",
                storageMode: .metadataOnly
            )
        )

        let cardID = try await AppleSpeechRelayCoordinator.publishRelayedWorkRecording(
            requestID: requestID, audio: Self.recordingBytes, store: store
        )
        XCTAssertEqual(
            cardID,
            WorkMaterialCollisionEscape.materialID(forCapture: captureID),
            "the ONE escape every Work lane derives — never a fresh random id"
        )

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 2)
        let note = try XCTUnwrap(desk.materials.first { $0.id == captureID })
        XCTAssertEqual(note.kind, .note, "the card that was already there is untouched")
        let recording = try XCTUnwrap(desk.materials.first { $0.id == cardID })
        XCTAssertEqual(recording.kind, .audio)
        XCTAssertEqual(recording.sourceDevice, "watch")
    }

    // MARK: - Phase 1 failure: the wrist keeps its clip

    func testAPhaseOneRefusalTravelsBackOnACodeTheWristLeavesQueued() async throws {
        let store = try Self.unusableStore()
        let refuses = await Self.refusesWrites(store)
        XCTAssertTrue(refuses, "the broken fixture must really be broken")

        do {
            _ = try await AppleSpeechRelayCoordinator.publishRelayedWorkRecording(
                requestID: UUID().uuidString, audio: Self.recordingBytes, store: store
            )
            XCTFail("a desk that cannot be written must not report a saved capture")
        } catch {
            // The verdict the live path then ships.
        }

        let failure = AppleSpeechRelayCoordinator.workPublicationFailure
        XCTAssertTrue(
            failure.isRetryable,
            """
            MEASURED: the phase-1 code is retryable, which is the ONLY property that \
            matters here — `AppleRelayPendingQueue.leavesEntryQueued` reads exactly this, \
            and a claimed entry deletes the audio the person already spoke.
            """
        )
        XCTAssertEqual(failure.errorCode, 78, "workDeskWriteFailed — the desk refused a capture")
        XCTAssertFalse(
            AppleSpeechRelayCoordinator.shouldCacheVerdict(for: failure),
            "a memoized storage blip would poison every re-fire of this requestID"
        )
        // The codes an unthinking reflex would reach for, pinned as the wrong
        // answer: each one has the wrist delete its recording.
        for terminal in [AppError.audioProcessingFailed, .audioInvalid, .audioTooLarge] {
            XCTAssertFalse(
                terminal.isRetryable,
                "\(terminal) is terminal on the wrist — never the phase-1 verdict"
            )
        }
    }

    // MARK: - Phase 2: the words join the recording

    func testTheTranscriptLandsOnTheRelayedCardRatherThanBesideIt() async throws {
        let store = stores.make()
        let requestID = UUID().uuidString
        let cardID = try await AppleSpeechRelayCoordinator.publishRelayedWorkRecording(
            requestID: requestID, audio: Self.recordingBytes, store: store
        )

        await AppleSpeechRelayCoordinator.attachRelayedWorkTranscript(
            "remember the oat milk", toCard: cardID, store: store
        )

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 1, "the words joined the card; they did not start one")
        let card = try XCTUnwrap(desk.materials.first)
        XCTAssertEqual(card.id, cardID)
        XCTAssertEqual(card.kind, .audio, "still playable — a transcript does not replace a recording")
        XCTAssertEqual(card.textContent, "remember the oat milk")
        XCTAssertNotEqual(
            card.title, WorkVoiceCaptureCoordinator.untranscribedTitle,
            "the card names itself by its words once it has any"
        )
        let payload = try await store.loadWorkMaterialPayload(id: cardID)
        XCTAssertEqual(payload, Self.recordingBytes)
    }

    func testACardDeletedMidTranscriptionDoesNotFailTheWrist() async throws {
        // A missing card after a successful publication is a BUG, not a state
        // this lane is entitled to fail on: the transcript is already in hand
        // and the wrist is owed it either way. The answer is logged and the
        // reply still ships.
        let store = stores.make()
        await AppleSpeechRelayCoordinator.attachRelayedWorkTranscript(
            "nothing to land on", toCard: UUID(), store: store
        )
        let desk = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertTrue(
            desk?.materials.isEmpty ?? true,
            "the words are NOT published beside a card this lane never had — that is the recovery lane's decision, not this one's"
        )
    }

    // MARK: - The reply the wrist reads

    func testOnlyAWorkReplyCarriesTheSavedStamp() {
        let work = RelayReplyCache.CachedReply(text: "oat milk", errorCode: nil, workSaved: true)
            .payload(requestID: "req-1")
        XCTAssertEqual(work[AppleSpeechRelayCoordinator.Wire.resultWorkSavedKey] as? Bool, true)
        XCTAssertEqual(work.count, 4)

        let chat = RelayReplyCache.CachedReply(text: "oat milk", errorCode: nil)
            .payload(requestID: "req-2")
        XCTAssertNil(chat[AppleSpeechRelayCoordinator.Wire.resultWorkSavedKey])
        XCTAssertEqual(chat.count, 3, "chat's success reply is a frozen three-key shape")

        let failure = RelayReplyCache.CachedReply(text: nil, errorCode: 78)
            .payload(requestID: "req-3")
        XCTAssertNil(
            failure[AppleSpeechRelayCoordinator.Wire.resultWorkSavedKey],
            "a refusal saved nothing, so it claims nothing"
        )
    }

    func testAReplayedWorkVerdictStillCarriesItsStamp() throws {
        // The wrist re-fires an undelivered requestID and receives the CACHED
        // verdict. Dropping the stamp on replay would tell it the iPhone kept
        // no recording — and it would then write the words a second time as a
        // note beside the card that is already there.
        let cache = RelayReplyCache()
        cache.store(.init(text: "oat milk", errorCode: nil, workSaved: true), forKey: "req-work")
        cache.store(.init(text: "hello duck", errorCode: nil), forKey: "req-chat")

        let work = try XCTUnwrap(cache.cachedReply(forKey: "req-work"))
        XCTAssertEqual(work.workSaved, true)
        XCTAssertEqual(
            work.payload(requestID: "req-work")[AppleSpeechRelayCoordinator.Wire.resultWorkSavedKey] as? Bool,
            true
        )

        let chat = try XCTUnwrap(cache.cachedReply(forKey: "req-chat"))
        XCTAssertNil(
            chat.workSaved,
            """
            a verdict stored without the field — every chat reply, and every verdict \
            written before the field existed — reads as nil, never a false-positive Work
            """
        )
    }

    // MARK: - Isolation: nothing on this branch reaches a gateway

    func testTheRelayCoordinatorNeverReachesAGatewayOrAConversation() throws {
        // Structural on purpose. The regression is one added line that
        // compiles, ships and breaks nothing a behavioural test can observe —
        // a Work capture quietly hopped to an agent. So the guard reads the
        // coordinator's own source and refuses the symbols outright.
        let source = try String(
            contentsOf: Self.projectContainerURL()
                .appendingPathComponent("Conduck/Services/AppleSpeechRelayCoordinator.swift"),
            encoding: .utf8
        )
        let code = Self.strippingComments(source)
        XCTAssertTrue(
            code.contains("publishRelayedWorkRecording"),
            "extractor sanity: the stripped source must still hold this file's real code"
        )
        for forbidden in [
            "startConverseHop",
            "startDeferredConverseHop",
            "handleQuickSend",
            "RemoteAgentRef",
            "BackgroundRemoteAgent",
            "ConversationRecord",
            "upsertConversation",
        ] {
            XCTAssertFalse(
                code.contains(forbidden),
                """
                `\(forbidden)` appears in the relay coordinator's CODE. Nothing on the Work \
                branch may reach a gateway, a gateway ref, or a conversation — the whole \
                reason a wrist capture has a destination at all is that a private thought \
                stops at the desk.
                """
            )
        }
    }

    // MARK: - Fixtures

    /// `.../Conduck/Conduck` — derived from this file's compile-time path, so
    /// it holds regardless of the runner's working directory.
    private static func projectContainerURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Swift source with every comment removed, so a guard reads CODE and not
    /// the prose that describes it — this file's own subject matter names the
    /// forbidden symbols in the coordinator's doc comments on purpose.
    private static func strippingComments(_ source: String) -> String {
        var out = ""
        let characters = Array(source)
        var index = 0
        var inLine = false
        var inBlock = false
        var inString = false
        while index < characters.count {
            let ch = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if inLine {
                if ch == "\n" { inLine = false; out.append(ch) }
            } else if inBlock {
                if ch == "*", next == "/" { inBlock = false; index += 1 }
            } else if inString {
                if ch == "\\" { index += 2; continue }
                if ch == "\"" { inString = false }
                out.append(ch)
            } else if ch == "/", next == "/" {
                inLine = true
                index += 1
            } else if ch == "/", next == "*" {
                inBlock = true
                index += 1
            } else {
                if ch == "\"" { inString = true }
                out.append(ch)
            }
            index += 1
        }
        return out
    }

    /// Not decodable as audio and comfortably under the sync ceiling, so the
    /// storage policy picks the synced lane exactly as it does in the app.
    private static let recordingBytes = Data(repeating: 0x6D, count: 4_096)

    /// A store that cannot mount, so every operation on it throws — the
    /// transient desk failure (a full disk, a protected-data blackout) the
    /// phase-1 verdict has to be retryable for. The URL names a DIRECTORY,
    /// which SQLite cannot open as a database file.
    private static func unusableStore() throws -> ConversationStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "conduck-unusable-\(UUID().uuidString).sqlite",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        return ConversationStore(inMemory: false, storeURL: directory)
    }

    /// Proves the broken fixture is really broken: a test that passed because
    /// the store quietly worked would assert nothing at all.
    private static func refusesWrites(_ store: ConversationStore) async -> Bool {
        do {
            _ = try await store.upsertDeskMaterial(
                WorkMaterialDraft(
                    id: UUID(),
                    kind: .note,
                    title: "probe",
                    textContent: "probe",
                    storageMode: .metadataOnly
                )
            )
            return false
        } catch {
            return true
        }
    }
}

#endif // os(iOS)
