// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WatchWorkRelayPhoneTests.swift
//
// The phone half of the Watch → Work relay. A clip spoken into the wrist is
// parked on the iPhone, transcribed there, and this is where its words become a
// desk card. The recording itself never reaches the desk: a Work voice note is
// its words, and the bytes are a second copy kept only until they are written.
//
// Three claims, and each one has a failure the user pays for:
//   • ORDER. The clip is PARKED in the phone's device-local retry lane before
//     any transcribe arm runs, and while the temp file still exists — both STT
//     arms hand that URL to `STTClient`, which defer-deletes it. A park
//     deferred until after transcription would find nothing to park, and a
//     failed hop would cost the recording rather than just the words.
//   • RETRYABILITY. A refused park travels back as a code the wrist's queue
//     LEAVES QUEUED. Claiming an entry deletes the only copy of the audio, so a
//     terminal code on a storage blip destroys a capture the next attempt would
//     have delivered. A park that LANDED, by contrast, is answered with the
//     durability stamp however the words go: the phone's own retry card owns
//     the capture from then on.
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

    /// The retry lane over a directory of this case's own. The production store
    /// writes the process-global App-Group container every other capture test in
    /// this bundle shares, so driving it would assert against — and corrupt —
    /// their state.
    private var retryContainer: URL!
    private var lane: PendingRetryStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        retryContainer = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-relay-park-\(UUID().uuidString)", isDirectory: true)
        lane = PendingRetryStore(
            containerURL: retryContainer,
            defaults: InMemoryDefaultsStore()
        )
    }

    override func tearDown() async throws {
        await stores.cleanUp()
        lane = nil
        if let retryContainer { try? FileManager.default.removeItem(at: retryContainer) }
        retryContainer = nil
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

    // MARK: - The capture id one utterance keeps

    func testARequestIdThatIsAUuidIsTheCaptureIdItself() {
        // The wrist mints requestIDs as UUIDs, so the common path is an
        // identity — which is what makes both the park and the desk write
        // idempotent for a claim token the watch retries verbatim across the
        // inline send, the file fallback and every drain re-fire.
        let requestID = UUID()
        XCTAssertEqual(
            AppleSpeechRelayCoordinator.workCaptureID(forRequestID: requestID.uuidString),
            requestID
        )
    }

    func testAForeignRequestIdStillDerivesOneStableCaptureId() {
        // A sender whose requestID is not a UUID must still land on ONE capture
        // per utterance. A fresh random id here would turn each retry of one
        // recording into another entry and another card.
        let derived = AppleSpeechRelayCoordinator.workCaptureID(forRequestID: "wrist-42")
        XCTAssertEqual(
            derived,
            AppleSpeechRelayCoordinator.workCaptureID(forRequestID: "wrist-42"),
            "the same requestID derives the same capture, in this process and any other"
        )
        XCTAssertNotEqual(
            derived,
            AppleSpeechRelayCoordinator.workCaptureID(forRequestID: "wrist-43")
        )
        // RFC 4122 §4.3 name-based, SHA-1: version 5, standard variant.
        XCTAssertEqual((derived.uuid.6 & 0xF0) >> 4, 0x5, "version 5")
        XCTAssertEqual(derived.uuid.8 & 0xC0, 0x80, "standard variant")
    }

    // MARK: - Phase 1: the clip is parked, and nothing reaches the desk

    func testARelayedClipIsParkedInThePhonesRetryLaneStampedWatch() async throws {
        let store = stores.make()
        let requestID = UUID().uuidString

        let claim = try await AppleSpeechRelayCoordinator.parkRelayedWorkClip(
            requestID: requestID,
            audio: Self.recordingBytes,
            language: "en-US",
            lane: lane
        )

        XCTAssertEqual(claim.id, UUID(uuidString: requestID))
        XCTAssertEqual(claim.entry.audioData, Self.recordingBytes, "the wrist's bytes read back exactly")
        let parked = claim.entry.metadata
        XCTAssertEqual(
            parked.resolvedDestination, .work,
            "A chat record would send these words to a gateway — the one thing this lane exists to prevent."
        )
        XCTAssertEqual(
            parked.publicationState, .phaseOneFailed,
            """
            The ORDINARY state of a fresh Work capture, not a failure report: the desk holds \
            nothing, so these bytes are the only copy of what was said.
            """
        )
        XCTAssertEqual(
            parked.sourceDevice, "watch",
            """
            The entry names the surface the words were SPOKEN at. The phone publishes the card, so \
            reading the writer's own device would file every wrist note under whichever iPhone \
            happened to be nearby.
            """
        )
        XCTAssertNil(parked.transcript, "the park runs before transcription is attempted at all")
        XCTAssertNil(parked.lastErrorCode, "nothing has failed — there is no code to carry")
        XCTAssertEqual(parked.preferredLanguage, "en-US",
                       "a retry must ask for the same language the capture did")
        XCTAssertNil(parked.workAttachedToMaterialID, "the wrist relays a clip and nothing else")
        XCTAssertTrue(
            parked.isExemptFromExpiry,
            "No clock may retire the only copy of what somebody said."
        )
        XCTAssertNil(parked.retryTTL, "an exempt record is on no clock, not a longer one")

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertTrue(
            deskValue?.materials.isEmpty ?? true,
            """
            The park writes NOTHING to a desk. Storing and syncing the recording is the waste this \
            whole lane exists to stop: the words are the artifact, and nothing appears on the board \
            until they arrive.
            """
        )
    }

    func testTheParkedEntryIsTheOneTheRetryCardSees() async throws {
        // The reservation is the whole of what "the phone has it" means, and
        // the count is what a person is shown. A capture under a live hold is
        // being worked on, not waiting — so it must not flash a Try Again row
        // through every successful wrist capture.
        let claim = try await AppleSpeechRelayCoordinator.parkRelayedWorkClip(
            requestID: UUID().uuidString, audio: Self.recordingBytes, language: nil, lane: lane
        )
        let pending = await lane.pendingCount()
        XCTAssertEqual(pending, 1, "the capture is queued")
        let waiting = await lane.waitingCount()
        XCTAssertEqual(waiting, 0, "and it is not waiting for a person while this request holds it")

        await AppleSpeechRelayCoordinator.handBackParkedClip(claim, lane: lane)
        let afterHandBack = await lane.waitingCount()
        XCTAssertEqual(
            afterHandBack, 1,
            "the hand-back is what reveals the capture to the retry card that has to finish it"
        )
    }

    // MARK: - Phase 1 failure: the wrist keeps its clip

    func testAParkThatCannotWriteItsBytesRefusesRatherThanReportingAKeptCapture() async throws {
        // The failure is injected by putting a regular FILE where the lane's
        // container should be: nothing inside it can be created, so the arm
        // fails at its first write — the transient storage refusal (a full
        // disk, a protected-data blackout) the verdict has to be retryable for.
        let broken = try Self.unwritableLane()
        let refuses = await Self.refusesArming(broken)
        XCTAssertTrue(refuses, "the broken fixture must really be broken")

        do {
            _ = try await AppleSpeechRelayCoordinator.parkRelayedWorkClip(
                requestID: UUID().uuidString,
                audio: Self.recordingBytes,
                language: nil,
                lane: broken
            )
            XCTFail("a lane that cannot write the bytes must not report a parked capture")
        } catch {
            XCTAssertEqual(
                (error as? AppError)?.errorCode,
                AppleSpeechRelayCoordinator.workPublicationFailure.errorCode,
                """
                The refusal must be the RETRYABLE one whatever the file system said. A raw \
                underlying error travelling out is answered on whatever code the caller reaches \
                for, and a terminal one has the wrist delete the clip.
                """
            )
        }
    }

    /// The other half of a park that is not durable: the bytes landed and the
    /// RESERVATION did not. An entry nobody holds is one the retry card may
    /// take and finish while this request is still transcribing, so a reply
    /// built on the belief that this request owns the capture would be a
    /// durability claim about somebody else's work.
    func testAParkWhoseReservationIsRefusedIsNotAPark() async throws {
        let requestID = UUID().uuidString
        let captureID = AppleSpeechRelayCoordinator.workCaptureID(forRequestID: requestID)
        try await lane.save(
            audioData: Self.recordingBytes,
            metadata: Self.parkedMetadata(id: captureID),
            workImageData: nil
        )
        let elsewhere = await lane.claim(id: captureID, duration: 600)
        XCTAssertNotNil(elsewhere, "another surface holds this capture")

        do {
            _ = try await AppleSpeechRelayCoordinator.parkRelayedWorkClip(
                requestID: requestID, audio: Self.recordingBytes, language: nil, lane: lane
            )
            XCTFail(
                """
                A save that landed without a reservation reported a park. Two surfaces then finish \
                one recording — and the wrist, told the phone has it, deletes the only other copy.
                """
            )
        } catch {
            XCTAssertEqual(
                (error as? AppError)?.errorCode,
                AppleSpeechRelayCoordinator.workPublicationFailure.errorCode,
                "the wrist leaves its entry queued on this code and keeps the clip"
            )
        }
    }

    func testAParkRefusalTravelsBackOnACodeTheWristLeavesQueued() {
        let failure = AppleSpeechRelayCoordinator.workPublicationFailure
        XCTAssertTrue(
            failure.isRetryable,
            """
            MEASURED: the park-refusal code is retryable, which is the ONLY property that matters \
            here — `AppleRelayPendingQueue.leavesEntryQueued` reads exactly this, and a claimed \
            entry deletes the audio the person already spoke.
            """
        )
        XCTAssertEqual(failure.errorCode, 78, "workDeskWriteFailed — the phone refused a capture")
        XCTAssertFalse(
            AppleSpeechRelayCoordinator.shouldCacheVerdict(for: failure),
            "a memoized storage blip would poison every re-fire of this requestID"
        )
        // The codes an unthinking reflex would reach for, pinned as the wrong
        // answer: each one has the wrist delete its recording.
        for terminal in [AppError.audioProcessingFailed, .audioInvalid, .audioTooLarge] {
            XCTAssertFalse(
                terminal.isRetryable,
                "\(terminal) is terminal on the wrist — never the park-refusal verdict"
            )
        }
    }

    // MARK: - Phase 2: the words become the card, and the recording goes

    func testTheRelayedWordsBecomeAWordsOnlyCardAndTheRecordingIsRetired() async throws {
        let store = stores.make()
        let requestID = UUID().uuidString
        let claim = try await AppleSpeechRelayCoordinator.parkRelayedWorkClip(
            requestID: requestID, audio: Self.recordingBytes, language: nil, lane: lane
        )

        // Exactly the order the live path runs: park the words, publish them,
        // stamp the verdict, then — and only then — clear the entry.
        let parkedWords = await lane.recordPublicationState(
            claim, transcript: "remember the oat milk", publicationState: .phaseOneFailed
        )
        XCTAssertTrue(parkedWords, "the words are parked on the entry before the desk write")

        let outcome = try await WorkVoiceCaptureCoordinator.publishTranscript(
            "remember the oat milk",
            forCapture: claim.id,
            createdAt: claim.entry.metadata.createdAt,
            sourceDevice: "watch",
            attachedTo: nil,
            store: store
        )
        XCTAssertEqual(outcome, .wordsPublished(materialID: claim.id))

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 1, "one utterance, one card")
        let card = try XCTUnwrap(desk.materials.first)
        XCTAssertEqual(card.id, claim.id)
        XCTAssertEqual(
            card.kind, .transcript,
            "a Work voice note is its words — never a recording the desk syncs for ever"
        )
        XCTAssertEqual(card.textContent, "remember the oat milk")
        XCTAssertEqual(
            card.sourceDevice, "watch",
            "the card names the surface the words were spoken at, not the one that wrote it"
        )
        XCTAssertNil(card.attachedToMaterialID, "the wrist sends no picture on this lane")
        XCTAssertFalse(card.hasPayload, "no bytes ride the desk's lane for a spoken note")

        _ = await lane.recordPublicationState(
            claim, transcript: "remember the oat milk", publicationState: .published
        )
        let cleared = await lane.clear(claim)
        XCTAssertTrue(cleared)
        let remaining = await lane.pendingCount()
        XCTAssertEqual(
            remaining, 0,
            "the recording's last instant is the clear, and it comes AFTER the words are on the desk"
        )
    }

    func testARefireOfOneUtteranceRepairsTheSameCardRatherThanAddingASecond() async throws {
        // A re-fire of an already-finished capture re-parks (the entry was
        // cleared), transcribes again — one STT call, the documented cost of a
        // lost reply — and finds its own card standing. It must not write a
        // second one.
        let store = stores.make()
        let requestID = UUID().uuidString

        let first = try await WorkVoiceCaptureCoordinator.publishTranscript(
            "oat milk", forCapture: AppleSpeechRelayCoordinator.workCaptureID(forRequestID: requestID),
            createdAt: Date(), sourceDevice: "watch", attachedTo: nil, store: store
        )
        let second = try await WorkVoiceCaptureCoordinator.publishTranscript(
            "oat milk", forCapture: AppleSpeechRelayCoordinator.workCaptureID(forRequestID: requestID),
            createdAt: Date(), sourceDevice: "watch", attachedTo: nil, store: store
        )
        XCTAssertEqual(first.materialID, second.materialID)

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(
            desk.materials.count, 1,
            "an inline send and its file fallback are one utterance, not two cards"
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
            "a refusal kept nothing, so it claims nothing"
        )
    }

    func testAReplayedWorkVerdictStillCarriesItsStamp() throws {
        // The wrist re-fires an undelivered requestID and receives the CACHED
        // verdict. Dropping the stamp on replay would tell it the iPhone kept
        // nothing — and it would then write the words a second time as a note
        // beside the card that is already there.
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

    // MARK: - The words never arrived: the phone's own retry card owns it

    func testTheAcknowledgementIsASuccessReplyWithNoWordsInIt() {
        // Success-SHAPED, with an empty transcript — and NO new wire literal:
        // `result.text` and `result.work` are the two keys a stamped work reply
        // already carries, and emptiness is the value that says no words came.
        let acknowledgement = AppleSpeechRelayCoordinator.workRecordingAcknowledgement()
        XCTAssertEqual(acknowledgement.text, "")
        XCTAssertNil(acknowledgement.errorCode, "an acknowledgement is not a failure")
        XCTAssertEqual(acknowledgement.workSaved, true)

        let payload = acknowledgement.payload(requestID: "req-ack")
        XCTAssertEqual(payload.count, 4, "the stamped work shape — never a fifth key for this state")
        XCTAssertEqual(payload[AppleSpeechRelayCoordinator.Wire.resultTextKey] as? String, "")
        XCTAssertEqual(payload[AppleSpeechRelayCoordinator.Wire.resultWorkSavedKey] as? Bool, true)
        XCTAssertNil(
            payload[AppleSpeechRelayCoordinator.Wire.resultErrorCodeKey],
            "an error slot beside the stamp is a reply the wrist reads as a failure"
        )
    }

    func testAReplayedAcknowledgementSettlesTheWristToo() {
        // The cache is what a re-fire hits FIRST, before the park and before
        // transcription. A replay that carried the old error would re-strand the
        // very entry this answer exists to settle — and the capture is already
        // here, so a fresh attempt buys nothing the retry card does not own.
        let cache = RelayReplyCache()
        cache.store(AppleSpeechRelayCoordinator.workRecordingAcknowledgement(), forKey: "req-ack")
        let replayed = cache.cachedReply(forKey: "req-ack")
        XCTAssertEqual(replayed?.workSaved, true)
        XCTAssertEqual(replayed?.text, "")
        XCTAssertNil(replayed?.errorCode)
    }

    /// What the acknowledgement PROMISES, end to end. The wrist deletes its clip
    /// on reading that reply, so the capture it released has to be finishable on
    /// this side — by the phone's own retry card, from the entry the failed
    /// request handed back.
    func testAnAcknowledgedCaptureIsFinishedByThePhonesOwnRetryCard() async throws {
        let store = stores.make()
        let claim = try await AppleSpeechRelayCoordinator.parkRelayedWorkClip(
            requestID: UUID().uuidString, audio: Self.recordingBytes, language: "de-DE", lane: lane
        )
        // The speech hop failed; the request hands the capture back and
        // acknowledges. Everything below is a different surface, minutes later.
        await AppleSpeechRelayCoordinator.handBackParkedClip(claim, lane: lane)

        let selected = await lane.claimNext()
        let retry = try XCTUnwrap(
            selected,
            "the retry card selects the capture the relay released"
        )
        XCTAssertEqual(retry.id, claim.id)
        XCTAssertEqual(
            retry.entry.audioData, Self.recordingBytes,
            "and it gets the recording — a promise of words needs the bytes that make them"
        )
        XCTAssertEqual(retry.entry.metadata.preferredLanguage, "de-DE")

        let outcome = try await WorkVoiceCaptureCoordinator.recover(
            retry,
            transcript: "the words the wrist stopped waiting for",
            store: store,
            queue: lane
        )
        XCTAssertEqual(outcome, .wordsPublished)
        XCTAssertTrue(outcome.isTerminal)

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let card = try XCTUnwrap(deskValue?.materials.first)
        XCTAssertEqual(card.id, claim.id)
        XCTAssertEqual(card.kind, .transcript)
        XCTAssertEqual(
            card.sourceDevice, "watch",
            """
            The recovery publishes on the phone and the card still names the wrist. That is what \
            the parked `sourceDevice` is for — without it every relayed note recovered later reads \
            as an iPhone note.
            """
        )
        XCTAssertEqual(card.textContent, "the words the wrist stopped waiting for")

        _ = await lane.clear(retry)
        let remaining = await lane.pendingCount()
        XCTAssertEqual(remaining, 0, "the recording goes once the words are written, and not before")
    }

    /// The other half: a retry that ALSO fails changes nothing. The entry, its
    /// recording and its exemption stay exactly where they are — which is the
    /// only reason the acknowledgement was safe to send.
    func testAnAcknowledgedCaptureWhoseRetryAlsoFailsStaysInTheQueue() async throws {
        let store = stores.make()
        let claim = try await AppleSpeechRelayCoordinator.parkRelayedWorkClip(
            requestID: UUID().uuidString, audio: Self.recordingBytes, language: nil, lane: lane
        )
        await AppleSpeechRelayCoordinator.handBackParkedClip(claim, lane: lane)

        let selected = await lane.claimNext()
        let retry = try XCTUnwrap(selected)
        let outcome = try await WorkVoiceCaptureCoordinator.recover(
            retry, transcript: nil, store: store, queue: lane
        )
        XCTAssertEqual(
            outcome, .retryKept(.noTranscript),
            "recognition still owes this capture its words; nothing may be written"
        )
        XCTAssertFalse(outcome.isTerminal, "and the durable record must stay armed")
        await lane.release(retry)

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertTrue(deskValue?.materials.isEmpty ?? true, "nothing reaches the desk without words")

        let waiting = await lane.waitingCount()
        XCTAssertEqual(waiting, 1, "the capture is offered again")
        let record = await lane.load().first { $0.metadata.id == claim.id }
        let entry = try XCTUnwrap(record)
        XCTAssertEqual(entry.audioData, Self.recordingBytes, "the bytes are still the only copy")
        XCTAssertEqual(entry.metadata.publicationState, .phaseOneFailed)
        XCTAssertTrue(entry.metadata.isExemptFromExpiry, "and no clock may take them")
    }

    /// A lost reply is the state this lane is built around: the wrist never saw
    /// the answer and re-fires the SAME requestID. The re-park must not walk the
    /// capture backwards — words already bought stay bought, and a `.published`
    /// verdict never downgrades.
    func testALostReplyRefireReParksWithoutErasingTheWordsOrTheVerdict() async throws {
        let requestID = UUID().uuidString
        let claim = try await AppleSpeechRelayCoordinator.parkRelayedWorkClip(
            requestID: requestID, audio: Self.recordingBytes, language: nil, lane: lane
        )
        // The phone bought the words and died before the desk write.
        _ = await lane.recordPublicationState(
            claim, transcript: "oat milk", publicationState: .phaseOneFailed
        )
        await AppleSpeechRelayCoordinator.handBackParkedClip(claim, lane: lane)

        let refire = try await AppleSpeechRelayCoordinator.parkRelayedWorkClip(
            requestID: requestID, audio: Self.recordingBytes, language: nil, lane: lane
        )
        XCTAssertEqual(refire.id, claim.id, "one utterance keeps one capture id across every re-fire")
        XCTAssertEqual(
            refire.entry.metadata.transcript, "oat milk",
            """
            The re-park erased words the provider was already paid for. The next attempt then buys \
            the same answer again — and a wrist that re-fires after every lost reply pays for one \
            utterance as many times as the reply is lost.
            """
        )

        // And once the desk holds this capture, a re-fire may not say otherwise:
        // a record downgraded to `.phaseOneFailed` is exempt from every clock
        // for ever.
        _ = await lane.recordPublicationState(
            refire, transcript: "oat milk", publicationState: .published
        )
        await AppleSpeechRelayCoordinator.handBackParkedClip(refire, lane: lane)

        let third = try await AppleSpeechRelayCoordinator.parkRelayedWorkClip(
            requestID: requestID, audio: Self.recordingBytes, language: nil, lane: lane
        )
        XCTAssertEqual(
            third.entry.metadata.publicationState, .published,
            "the desk holds this capture, and a re-arm is not the newest thing that happened to it"
        )
    }

    // MARK: - Source shape: the order, and the answers each exit ships

    func testTheClipIsReadOffDiskAndParkedBeforeAnyTranscribeArm() throws {
        // Structural, because `processRelayRequest` has no seam: it needs an
        // activated `WCSession` and a paired watch. What has to hold is an
        // ORDER — the bytes are read and parked while the temp file still
        // exists, because both STT arms hand that URL to `STTClient`, which
        // defer-deletes it, and this scope's own defer deletes it on every exit.
        let code = Self.strippingComments(try Self.coordinatorSource())
        let read = try XCTUnwrap(
            code.range(of: "let audio = try Data(contentsOf: audioURL)")?.lowerBound,
            "the clip is no longer read off the temp file; re-anchor this guard"
        )
        let park = try XCTUnwrap(
            code.range(of: "Self.parkRelayedWorkClip(")?.lowerBound,
            "the park has moved or been renamed; re-anchor this guard"
        )
        let transcribe = try XCTUnwrap(
            code.range(of: "transcribeViaCustomEndpoint(audioFileURL: audioURL")?.lowerBound,
            "the first transcribe arm has moved; re-anchor this guard's end"
        )
        XCTAssertLessThan(read, park, "the bytes are read before they are parked")
        XCTAssertLessThan(
            park, transcribe,
            """
            The clip is parked AFTER a transcribe arm, so the file it was to be read from is \
            already deleted. A failed hop then costs the recording rather than just the words.
            """
        )
    }

    func testTheParkTakesNoDeskWriteWithIt() throws {
        // The one thing this whole lane exists to stop: the recording reaching
        // the board. The park's own body may not write a card by any route.
        let code = Self.callText(Self.strippingComments(try Self.coordinatorSource()))
        let body = try XCTUnwrap(
            Self.bracedBody(after: "static func parkRelayedWorkClip(", in: code),
            "the park has moved or been renamed; re-anchor this guard"
        )
        XCTAssertTrue(body.contains("lane.save("), "extractor sanity: the park still writes the entry")
        for forbidden in ["upsertDeskMaterial(", "publishTranscript(", "kind: .audio"] {
            XCTAssertFalse(
                body.contains(forbidden),
                """
                The park calls `\(forbidden)`. A relayed clip becomes a desk card only when its \
                WORDS arrive; storing and syncing the recording is the waste this lane removed.
                """
            )
        }
    }

    func testTheLeaseIsRenewedWhileSpeechRunsAndDroppedOnEveryExit() throws {
        // The hold is granted for `claimLeaseDuration` and a custom endpoint is
        // allowed 300 s per attempt, attempted three times — so the work can
        // outlast the reservation that protects it. Source, because the interval
        // is minutes and no simulator run can wait one out.
        let code = Self.strippingComments(try Self.coordinatorSource())
        let renewal = try XCTUnwrap(
            code.range(of: "leaseRenewal = Task { await Self.renewWhileTranscribing(claim) }")?.lowerBound,
            "the relay never extends its reservation, so a transcription longer than one lease "
            + "hands the capture to whoever asks next while this request is still working on it"
        )
        let cancel = try XCTUnwrap(
            code.range(of: "defer { leaseRenewal?.cancel() }")?.lowerBound,
            "the renewal is not cancelled by a `defer`, so a refusal path leaves it running and the "
            + "hold outlives the work it was protecting"
        )
        XCTAssertLessThan(
            cancel, renewal,
            "the `defer` is installed at request scope BEFORE the task it cancels, so every exit "
            + "drops the renewal"
        )
    }

    /// Every failure on a PARKED capture ships the acknowledgement and hands the
    /// entry back, and each one is where a one-line edit turns a refusal into a
    /// stranded wrist. Three arms: the phase-two publish, the typed throw, the
    /// untyped throw.
    func testEveryFailureOnAParkedCaptureHandsItBackAndAcknowledges() throws {
        let code = Self.strippingComments(try Self.coordinatorSource())

        XCTAssertFalse(
            code.contains("preserveRelayedWorkWords("),
            """
            The lane still parks a SECOND record after the fact. The clip is parked before speech \
            now, under the claim this request holds, so a late save can only re-arm a capture the \
            entry already describes.
            """
        )

        let requestStart = try XCTUnwrap(
            code.range(of: "var parkedClip: PendingRetryClaim?")?.lowerBound,
            "the parked-claim state has moved or been renamed; re-anchor this guard"
        )
        // Bounded at the next declaration so the helpers further down the file
        // are not counted as extra call sites.
        let tailEnd = try XCTUnwrap(
            code.range(of: "private func transcribeViaCustomEndpoint")?.lowerBound,
            "the coordinator's next declaration has been renamed; re-anchor this guard's end"
        )
        XCTAssertLessThan(requestStart, tailEnd, "extractor sanity: the request precedes the next declaration")
        let body = String(code[requestStart..<tailEnd])

        let handBacks = Self.occurrences(of: "await Self.handBackParkedClip(parkedClip)", in: body)
        let acknowledgements = Self.occurrences(of: "shipWorkRecordingAcknowledgement(", in: body)
        XCTAssertEqual(
            handBacks.count, 3,
            """
            A parked capture this request abandons without handing back is invisible to the retry \
            count until its lease lapses — and the wrist has already been told the phone has it. \
            All three failure exits (the refused publish, the typed throw, the untyped throw) owe \
            the hand-back.
            """
        )
        XCTAssertEqual(
            acknowledgements.count, 3,
            """
            An exit that answers a PARKED capture with an error leaves the wrist keeping a clip \
            this phone already holds — for ever, since a Work entry never ages out.
            """
        )
        for (handBack, acknowledgement) in zip(handBacks, acknowledgements) {
            XCTAssertLessThan(
                handBack.lowerBound, acknowledgement.lowerBound,
                """
                An arm ships the acknowledgement BEFORE handing the capture back, so a wrist that \
                reads it first can delete its clip against an entry no surface is offering.
                """
            )
        }

        // The error reply is the answer for an UNPARKED capture only — a chat
        // request, or a work request whose park was refused above.
        let errorReplies = Self.occurrences(
            of: "sendReply(requestID: requestID, errorCode:", in: body
        )
        XCTAssertEqual(errorReplies.count, 2, "extractor sanity: both catch arms still ship an error reply")
        for (acknowledgement, errorReply) in zip(acknowledgements.suffix(2), errorReplies) {
            XCTAssertLessThan(
                acknowledgement.lowerBound, errorReply.lowerBound,
                """
                A catch arm ships its error reply BEFORE consulting the parked capture, so the \
                acknowledgement can never be the answer.
                """
            )
        }
    }

    /// The phase-two arm in full. A `publishTranscript` that THROWS while its
    /// catch is a bare log falls through to the stamped success reply — the
    /// wrist reads the stamp, consumes its entry and deletes the only remaining
    /// copy of the clip, for a write that was refused.
    func testThePhaseTwoPublishFailureEndsTheRequest() throws {
        let code = Self.callText(Self.strippingComments(try Self.coordinatorSource()))
        XCTAssertTrue(
            code.contains(Self.callText("""
            _ = try await WorkVoiceCaptureCoordinator.publishTranscript(
                text,
                forCapture: parkedClip.id,
            """)),
            """
            The words are published against the CAPTURE id, which is what makes the desk write \
            idempotent for a claim token the watch retries verbatim.
            """
        )
        // BOUNDED TO THE ARM. The catch body holds no braces of its own, so the
        // first `}` after it closes it — and reading past that would let a
        // `return` belonging to the request's own tail satisfy the assertion.
        let publish = try XCTUnwrap(
            code.range(of: "WorkVoiceCaptureCoordinator.publishTranscript("),
            "the phase-two publish has moved or been renamed; re-anchor this guard"
        )
        let catchStart = try XCTUnwrap(
            code.range(of: "} catch {", range: publish.upperBound..<code.endIndex),
            "the phase-two publish no longer has a catch arm; a throw then falls through to the "
            + "stamped success reply"
        )
        let armEnd = try XCTUnwrap(
            code.range(of: "}", range: catchStart.upperBound..<code.endIndex),
            "extractor sanity: the catch arm must close"
        )
        let arm = String(code[catchStart.upperBound..<armEnd.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(
            arm.contains("handBackParkedClip"),
            "the refused publish keeps the capture reserved, so nothing can finish it"
        )
        XCTAssertTrue(
            arm.contains("shipWorkRecordingAcknowledgement"),
            "the refused publish answers with a code the wrist re-fires on, buying the same refusal"
        )
        XCTAssertTrue(
            arm.hasSuffix("return"),
            """
            The refused-publish arm does not END the request unconditionally, so it falls into the \
            stamped success reply below it — the exact shape a wrist reads as "saved" for a write \
            that did not happen. A `return` reached only under a condition is the same defect: \
            what this asserts is the LAST statement of the whole arm.
            """
        )
    }

    /// The words are parked on the entry BEFORE the desk write and the verdict
    /// stamped after it, so every instant between them is one a recovery can
    /// name. Parking them after would cost a crash the words the provider was
    /// already paid for.
    func testTheWordsAreParkedOnTheEntryBeforeTheDeskWrite() throws {
        let code = Self.callText(Self.strippingComments(try Self.coordinatorSource()))
        let parkedWords = try XCTUnwrap(
            code.range(of: Self.callText("""
            _ = await PendingRetryStore.shared.recordPublicationState(
                parkedClip,
                transcript: text,
                publicationState: .phaseOneFailed
            )
            """)),
            """
            The words are no longer parked on the entry before the desk write, so a death between \
            recognition and publication costs a transcription the provider was already paid for.
            """
        )
        let publish = try XCTUnwrap(
            code.range(of: "WorkVoiceCaptureCoordinator.publishTranscript(", range: parkedWords.upperBound..<code.endIndex),
            "extractor sanity: the desk write follows the words' park"
        )
        let stamp = try XCTUnwrap(
            code.range(of: "publicationState: .published", range: publish.upperBound..<code.endIndex),
            "the `.published` verdict is no longer written after the desk write; a record still "
            + "saying the desk holds nothing is exempt from every clock for ever"
        )
        let clear = try XCTUnwrap(
            code.range(of: "PendingRetryStore.shared.clear(parkedClip)", range: stamp.upperBound..<code.endIndex),
            """
            The entry is cleared before its verdict is stamped, so a clear that fails leaves a \
            record saying these bytes are the only copy of a capture the desk already holds.
            """
        )
        XCTAssertLessThan(stamp.lowerBound, clear.lowerBound)
    }

    // MARK: - Isolation: nothing on this branch reaches a gateway

    func testTheRelayCoordinatorNeverReachesAGatewayOrAConversation() throws {
        // Structural on purpose. The regression is one added line that
        // compiles, ships and breaks nothing a behavioural test can observe —
        // a Work capture quietly hopped to an agent. So the guard reads the
        // coordinator's own source and refuses the symbols outright.
        let code = Self.strippingComments(try Self.coordinatorSource())
        XCTAssertTrue(
            code.contains("parkRelayedWorkClip"),
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

    /// The coordinator's source, from this file's compile-time path so it holds
    /// regardless of the runner's working directory.
    private static func coordinatorSource() throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Conduck/Services/AppleSpeechRelayCoordinator.swift"),
            encoding: .utf8
        )
    }

    /// A parked Work record in the shape this lane writes, for the cases that
    /// need one already in the queue before the lane runs.
    private static func parkedMetadata(id: UUID) -> PendingRetryMetadata {
        PendingRetryMetadata(
            id: id,
            createdAt: Date(),
            audioFileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("relay-work-\(id.uuidString).m4a"),
            preferredLanguage: nil,
            attemptCount: 1,
            lastErrorCode: nil,
            destination: .work,
            publicationState: .phaseOneFailed,
            sourceDevice: "watch"
        )
    }

    /// The brace-matched body opened by the first `{` after `token`, without the
    /// braces themselves. Nil when the token is absent or the braces do not
    /// close, both of which mean this guard is anchored to code that has moved.
    ///
    /// Scoping to one construct is the whole point: an assertion about an arm
    /// that is allowed to read past it is satisfied by any statement anywhere
    /// after it.
    private static func bracedBody(after token: String, in source: String) -> String? {
        guard let anchor = source.range(of: token),
              let opening = source.range(of: "{", range: anchor.upperBound..<source.endIndex)
        else { return nil }
        var index = opening.upperBound
        let start = index
        var depth = 1
        while index < source.endIndex, depth > 0 {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" { depth -= 1 }
            index = source.index(after: index)
        }
        guard depth == 0 else { return nil }
        return String(source[start..<source.index(before: index)])
    }

    /// Call text with every run of whitespace collapsed to one space and the
    /// space after an opening parenthesis removed, so a body broken across lines
    /// matches the same needle as one written on fewer.
    private static func callText(_ source: String) -> String {
        source
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .replacingOccurrences(of: "( ", with: "(")
    }

    /// Every range at which `needle` appears, in order — the ordering is what
    /// the guards above measure, so a bare count would not do.
    private static func occurrences(of needle: String, in haystack: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var searchStart = haystack.startIndex
        while let next = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            found.append(next)
            searchStart = next.upperBound
        }
        return found
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

    /// A retry lane whose container is a regular FILE, so every write into it
    /// fails at `open` — the transient storage refusal the park verdict has to
    /// be retryable for.
    private static func unwritableLane() throws -> PendingRetryStore {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-relay-unwritable-\(UUID().uuidString)")
        try Data().write(to: path)
        return PendingRetryStore(containerURL: path, defaults: InMemoryDefaultsStore())
    }

    /// Proves the broken fixture is really broken: a case that passed because
    /// the lane quietly worked would assert nothing at all.
    private static func refusesArming(_ lane: PendingRetryStore) async -> Bool {
        do {
            try await lane.save(
                audioData: Data(repeating: 0x01, count: 8),
                metadata: parkedMetadata(id: UUID()),
                workImageData: nil
            )
            return false
        } catch {
            return true
        }
    }

    /// Not decodable as audio and comfortably under the sync ceiling, so the
    /// storage policy picks the synced lane exactly as it does in the app.
    private static let recordingBytes = Data(repeating: 0x6D, count: 4_096)
}

@MainActor
final class WatchWorkTextRelayPhoneTests: XCTestCase {
    func testReceiptFollowsDurableInboxAcceptanceAndReplayKeepsOneCapture() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = WorkCaptureInbox(baseURL: directory)
        let capture = WatchWorkTextCapture(id: UUID(), text: "Plan the launch review", createdAt: Date())
        let first = await PhoneSessionManager.acceptWorkTextCapture(capture, inbox: inbox)
        XCTAssertEqual(WatchWorkTextCaptureWire.accepted(first, for: capture.id), true)
        let replay = await PhoneSessionManager.acceptWorkTextCapture(capture, inbox: inbox)
        XCTAssertEqual(WatchWorkTextCaptureWire.accepted(replay, for: capture.id), true)
        let count = try await inbox.pendingCount()
        XCTAssertEqual(count, 1)

        // Re-open with a new owner: the ACK must mean bytes are on disk, not
        // that the old process remembers a request it has not persisted yet.
        let reopened = WorkCaptureInbox(baseURL: directory)
        let loadedClaim = try await reopened.claimNext()
        let claim = try XCTUnwrap(loadedClaim)
        XCTAssertEqual(claim.id, capture.id)
        XCTAssertEqual(claim.envelope.note, capture.text)
        XCTAssertTrue(claim.envelope.entries.isEmpty, "An explicit text capture contains no recording or attachments.")
    }

    func testStorageFailureNeverAcknowledgesTheTextAsAccepted() async throws {
        let blockedDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: blockedDirectory)
        defer { try? FileManager.default.removeItem(at: blockedDirectory) }
        let capture = WatchWorkTextCapture(id: UUID(), text: "Keep this thought", createdAt: Date())
        let reply = await PhoneSessionManager.acceptWorkTextCapture(
            capture, inbox: WorkCaptureInbox(baseURL: blockedDirectory)
        )
        XCTAssertEqual(WatchWorkTextCaptureWire.accepted(reply, for: capture.id), false)
    }
}

#endif // os(iOS)
