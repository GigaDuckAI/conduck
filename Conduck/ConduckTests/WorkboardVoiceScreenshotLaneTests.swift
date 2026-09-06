// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardVoiceScreenshotLaneTests.swift
//
// The picture half of a Work voice capture taken from the Mac menu bar: a
// region dragged before the microphone comes up, staged until Stop, and
// published as a card of its own AHEAD of the recording.
//
// Two claims run through every case here, and they are the ones no source
// reading can settle.
//
// ORDER. The picture exists nowhere but this process between the drag and the
// desk, so it goes first: the crash window the ordering closes is the one where
// the audio lands and the image does not. The observation point is the image
// pipeline's own seam, which stands exactly where the publication begins — the
// desk read taken there is the state of the desk BEFORE either artifact
// reached it.
//
// INDEPENDENCE. The recording and the picture are two publications over one
// capture, and either may be owed while the other is finished. So a refused
// picture may not cost the words, may not fail the result, may not be reported
// as success, and may not be the last copy of anything: the capture's queue
// entry carries the bytes and stands until something publishes them.
//
// The recorder is driven through its own seams rather than through a
// microphone: `WorkboardAudioCaptureTests` documents why they exist, and these
// cases add the two the picture needs — the App-Group queue it rides and the
// image pipeline that normalizes it.

import XCTest
@testable import Conduck

final class WorkboardVoiceScreenshotLaneTests: XCTestCase {

    private var inboxRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        inboxRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-voice-shot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let inboxRoot { try? FileManager.default.removeItem(at: inboxRoot) }
        inboxRoot = nil
        try super.tearDownWithError()
    }

    // MARK: - The picture is a second card, and it goes first

    /// One capture, two cards, in the order the crash window demands. The
    /// screenshot's card stands at the id DERIVED from the capture's — the
    /// capture id already names the recording — and the desk read taken at the
    /// start of the picture's publication proves the recording is not there
    /// yet.
    @MainActor
    func testAStagedScreenshotBecomesItsOwnCardPublishedBeforeTheRecording() async throws {
        let store = ConversationStore(inMemory: true)
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.workInboxForTesting = Self.workingInbox(under: inboxRoot)
        recorder.capturedAudioForTesting = Self.recordingBytes

        var thePictureWasPublished = false
        var kindsWhenThePictureWasPublished: [WorkMaterialKind] = []
        // The picture's pipeline is SLOWED on purpose. Both cards are published
        // from one stop, and the only way to tell "dated from the capture" apart
        // from "dated when it happened to be written" is to put measurable time
        // between the two writes — the image normalize is exactly where a real
        // one spends it. See the date assertions at the end.
        let normalizeDelay: TimeInterval = 1.5
        recorder.workScreenshotNormalizeForTesting = { raw in
            thePictureWasPublished = true
            XCTAssertEqual(raw, Self.rawScreenshot, "the staged bytes are what reach the pipeline")
            let desk = try? await store.fetchWorkItem(id: Constants.workboardDeskItemID)
            kindsWhenThePictureWasPublished = desk?.materials.map(\.kind) ?? []
            try? await Task.sleep(nanoseconds: UInt64(normalizeDelay * 1_000_000_000))
            return Self.jpegBytes
        }
        var kindsAtTheHop: Set<WorkMaterialKind> = []
        recorder.transcriptionHopForTesting = { _ in
            let desk = try? await store.fetchWorkItem(id: Constants.workboardDeskItemID)
            kindsAtTheHop = Set(desk?.materials.map(\.kind) ?? [])
            return .success("the ferry leaves at seven")
        }

        recorder.stageWorkScreenshot(Self.rawScreenshot)
        let beforeTheStop = Date()
        let result = await recorder._finishCaptureForTesting()

        XCTAssertEqual(try result.get(), "the ferry leaves at seven")
        XCTAssertTrue(
            thePictureWasPublished,
            "the staged picture must actually be published, or every claim below is vacuous"
        )
        XCTAssertEqual(
            kindsWhenThePictureWasPublished, [],
            """
            MEASURED: the desk is EMPTY when the picture's publication begins. The picture \
            goes first because it is the artifact held nowhere but this process — a crash \
            between Stop and the desk costs it and nothing else.
            """
        )
        XCTAssertEqual(
            kindsAtTheHop, [.audio, .image],
            "…and both artifacts are on the desk before a single word is asked for"
        )

        let captureID = try XCTUnwrap(recorder.workRecordingMaterialID)
        let screenshotID = WorkVoiceScreenshotCoordinator.materialID(forCapture: captureID)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(
            Set(desk.materials.map(\.id)), [captureID, screenshotID],
            "one capture, two cards, and the picture is at its own derived id"
        )

        let recording = try XCTUnwrap(desk.materials.first { $0.id == captureID })
        XCTAssertEqual(recording.kind, .audio)
        XCTAssertEqual(recording.textContent, "the ferry leaves at seven")
        let recordingPayload = try await store.loadWorkMaterialPayload(id: captureID)
        XCTAssertEqual(
            recordingPayload, Self.recordingBytes,
            "the recording still holds the bytes that were spoken"
        )

        let picture = try XCTUnwrap(desk.materials.first { $0.id == screenshotID })
        XCTAssertEqual(picture.kind, .image)
        let picturePayload = try await store.loadWorkMaterialPayload(id: screenshotID)
        XCTAssertEqual(picturePayload, Self.jpegBytes)

        // ONE stop, one date. Both cards are published from the capture's own
        // `createdAt` — the picture always was, and the recording is dated from
        // it too rather than from a `Date()` taken at the moment it happens to
        // be written. The desk orders by sequence, so this does not buy
        // adjacency; what it buys is two cards from one stop that do not
        // disagree about when the person spoke.
        //
        // The tolerance is ONE SECOND and it is not slack: the picture travels
        // through the App-Group envelope, whose JSON dates are ISO-8601 and
        // therefore whole seconds, so its card carries the capture's instant
        // truncated. A recording dated at WRITE time would land a full
        // `normalizeDelay` later than that — which is why the normalize above
        // sleeps longer than the tolerance. Without the fix this reads ≥1.5s.
        let spread = recording.createdAt.timeIntervalSince(picture.createdAt)
        XCTAssertLessThan(
            abs(spread), 1,
            """
            MEASURED: the recording's card is \(spread)s from the picture's, after a picture \
            pipeline that took \(normalizeDelay)s. Two artifacts of ONE capture must carry that \
            capture's date, not the clock reading of whenever each one happened to be written.
            """
        )
        XCTAssertGreaterThanOrEqual(
            recording.createdAt, beforeTheStop,
            "control: the shared date is this capture's own, not a zero or an inherited one"
        )
        XCTAssertEqual(
            recorder.workCaptureFacts,
            InAppAudioRecorder.WorkCaptureFacts(
                recordingOnDesk: true,
                wordsOnDesk: true,
                screenshotStaged: true,
                screenshotQueued: true,
                screenshotOnDesk: true,
                screenshotEverOnDesk: true
            ),
            "every artifact landed, which is the ONE shape a receipt may describe as complete"
        )
    }

    #if os(macOS)
    /// The AUDIO's own crash window, declared so a quit cannot land inside it.
    ///
    /// `AudioRecorder.stopRecording()` hands back the bytes and deletes the
    /// file, so from the stop until phase one copies them into the store the
    /// recording exists nowhere but memory — through the compression, through
    /// the whole picture pipeline the case above measures at a second and a
    /// half. Nothing else can see that window: no gateway turn is involved, so
    /// the quit guard's in-flight registry reads zero and ⌘Q terminates at once,
    /// taking a recording with no card and no Try Again behind it.
    ///
    /// It closes at PHASE ONE, not at the end of the capture: after that the
    /// desk holds the recording and only the words are outstanding, and a quit
    /// should not wait out a speech hop to keep a promise already kept.
    @MainActor
    func testTheStoppedRecordingIsDeclaredInFlightUntilTheDeskHoldsIt() async throws {
        let store = ConversationStore(inMemory: true)
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.workInboxForTesting = Self.workingInbox(under: inboxRoot)
        recorder.capturedAudioForTesting = Self.recordingBytes

        XCTAssertEqual(
            InAppAudioRecorder.workPublicationsInFlight, 0,
            "control: nothing is declared before the stop"
        )

        // The picture's pipeline stands INSIDE the window — the audio is in
        // memory and the desk holds nothing at all while it runs.
        var declaredWhileThePictureRan = -1
        recorder.workScreenshotNormalizeForTesting = { _ in
            declaredWhileThePictureRan = InAppAudioRecorder.workPublicationsInFlight
            return Self.jpegBytes
        }
        var declaredAtTheSpeechHop = -1
        recorder.transcriptionHopForTesting = { _ in
            declaredAtTheSpeechHop = InAppAudioRecorder.workPublicationsInFlight
            return .success("the ferry leaves at seven")
        }

        recorder.stageWorkScreenshot(Self.rawScreenshot)
        let result = await recorder._finishCaptureForTesting()
        XCTAssertEqual(try result.get(), "the ferry leaves at seven")

        XCTAssertEqual(
            declaredWhileThePictureRan, 1,
            """
            MEASURED: the stopped recording is NOT declared in flight while its picture is being \
            written. A ⌘Q there returns `.terminateNow` and the audio — which the stop already \
            deleted from disk — goes with the process.
            """
        )
        XCTAssertEqual(
            declaredAtTheSpeechHop, 0,
            """
            MEASURED: the declaration outlives phase one and holds a quit for the whole speech \
            hop. The desk already has the recording by then; only the words are owed, and those \
            are retryable.
            """
        )
        XCTAssertEqual(
            InAppAudioRecorder.workPublicationsInFlight, 0,
            "the balance returns to zero, or the next quit waits out the whole timeout"
        )
    }
    #endif

    /// A capture with nothing staged is the capture this lane always was.
    ///
    /// All three ways of saying "no picture" answer identically: the surface
    /// that never stages (every iOS and desk capture), the one that stages the
    /// `nil` a skipped overlay hands back, and the degenerate empty payload. A
    /// receipt that named a missing screenshot for a capture that never had one
    /// would be exactly as untrue as one that hid a real loss.
    @MainActor
    func testStagingNoScreenshotLeavesTheCaptureExactlyAsItWas() async throws {
        let stagings: [(String, @MainActor (InAppAudioRecorder) -> Void)] = [
            ("nothing staged at all", { _ in }),
            ("the nil a skipped overlay hands back", { $0.stageWorkScreenshot(nil) }),
            ("empty bytes", { $0.stageWorkScreenshot(Data()) }),
        ]
        for (label, stage) in stagings {
            let store = ConversationStore(inMemory: true)
            let recorder = InAppAudioRecorder(retryDestination: .work)
            recorder.workStoreForTesting = store
            recorder.workInboxForTesting = Self.workingInbox(under: inboxRoot)
            recorder.capturedAudioForTesting = Self.recordingBytes
            var normalizeRan = false
            recorder.workScreenshotNormalizeForTesting = { _ in
                normalizeRan = true
                return Self.jpegBytes
            }
            recorder.transcriptionHopForTesting = { _ in .success("no picture here") }

            stage(recorder)
            let result = await recorder._finishCaptureForTesting()

            XCTAssertEqual(try result.get(), "no picture here", label)
            XCTAssertFalse(
                normalizeRan,
                "\(label): an absent picture is not published — nothing reaches the image pipeline"
            )
            let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
            let desk = try XCTUnwrap(deskValue, label)
            XCTAssertEqual(desk.materials.count, 1, "\(label): one card, the recording")
            XCTAssertEqual(desk.materials.first?.kind, .audio, label)
            XCTAssertEqual(
                recorder.workCaptureFacts,
                InAppAudioRecorder.WorkCaptureFacts(
                    recordingOnDesk: true,
                    wordsOnDesk: true,
                    screenshotStaged: false,
                    screenshotQueued: false,
                    screenshotOnDesk: false,
                    screenshotEverOnDesk: false
                ),
                "\(label): no picture was staged, so none is missing — the receipt names none"
            )
            XCTAssertFalse(recorder.canRetryWorkCapture, "\(label): the capture is finished")
        }
    }

    // MARK: - Cancel promises an untouched desk

    /// The whole reason the picture is staged rather than published at the drag:
    /// one Esc gets out of an accidental capture with nothing on the desk. The
    /// bytes go with the cancelled recording, so they cannot ride the NEXT
    /// capture either — a picture of one moment attached to another moment's
    /// words is worse than no picture at all.
    @MainActor
    func testACancelledRecordingPublishesNothingAndDropsTheStagedScreenshot() async throws {
        let store = ConversationStore(inMemory: true)
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.workInboxForTesting = Self.workingInbox(under: inboxRoot)
        recorder.capturedAudioForTesting = Self.recordingBytes
        var normalizeRan = false
        recorder.workScreenshotNormalizeForTesting = { _ in
            normalizeRan = true
            return Self.jpegBytes
        }
        recorder.transcriptionHopForTesting = { _ in .success("the capture that followed") }

        recorder.stageWorkScreenshot(Self.rawScreenshot)
        recorder.cancelRecording()

        let deskAfterCancel = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertNil(
            deskAfterCancel,
            "ZERO cards: a cancelled recording leaves the desk exactly as it was"
        )
        XCTAssertFalse(normalizeRan, "nothing was published, so nothing was normalized")

        // The staged bytes are GONE, not merely unpublished — the next capture
        // is a different moment and must not inherit the picture of this one.
        let result = await recorder._finishCaptureForTesting()

        XCTAssertEqual(try result.get(), "the capture that followed")
        XCTAssertFalse(normalizeRan, "the dropped picture is not published by the next capture")
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 1, "the second capture put ONE card on the desk")
        XCTAssertEqual(desk.materials.first?.kind, .audio)
    }

    /// The other way a capture stops before it starts. A microphone that never
    /// came up is not a capture either, so the picture staged for it goes the
    /// same way a cancelled one's does — otherwise it waits in the recorder and
    /// lands beside whatever is said next.
    @MainActor
    func testARefusedMicrophoneDropsTheStagedPictureRatherThanArmingTheNextCapture() async throws {
        let store = ConversationStore(inMemory: true)
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.workInboxForTesting = Self.workingInbox(under: inboxRoot)
        recorder.capturedAudioForTesting = Self.recordingBytes
        // The start path reads the machine's live Speech-Recognition TCC row,
        // which never prompts under XCTest, so a denied row would fail this
        // case on the machine rather than on the code.
        recorder.speechAuthorizationForTesting = .authorized
        recorder.microphoneStartForTesting = { false }
        var normalizeRan = false
        recorder.workScreenshotNormalizeForTesting = { _ in
            normalizeRan = true
            return Self.jpegBytes
        }
        recorder.transcriptionHopForTesting = { _ in .success("a later, different moment") }

        recorder.stageWorkScreenshot(Self.rawScreenshot)
        await recorder.startRecording()

        guard case .error = recorder.state else {
            return XCTFail("the fixture must actually refuse the microphone")
        }

        // Whatever is said NEXT is a different moment, and it gets no picture.
        recorder.dismissError()
        let result = await recorder._finishCaptureForTesting()

        XCTAssertEqual(try result.get(), "a later, different moment")
        XCTAssertFalse(
            normalizeRan,
            "the refused start's picture must not be published beside another capture's words"
        )
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 1, "one card, the recording that did happen")
        XCTAssertEqual(desk.materials.first?.kind, .audio)
        XCTAssertFalse(
            recorder.workCaptureFacts.screenshotStaged,
            "the capture that did happen carried no picture, so its receipt names none"
        )
    }

    // MARK: - A refused picture costs the picture and nothing else

    /// The queue refuses the bytes. The recording still publishes and the words
    /// still land on it — the picture costs neither — but the CAPTURE is not
    /// finished, and that is the whole point: a capture reported successful is
    /// one no surface offers a retry for, so the picture would be lost with
    /// nothing anywhere to get it back. The answer is the retryable desk error,
    /// the debt is retained with the words attached, and the queue entry stands
    /// carrying the only copy of the picture.
    @MainActor
    func testARefusedScreenshotHoldsTheCaptureRetryableWithTheWordsAlreadyOnTheCard() async throws {
        let store = ConversationStore(inMemory: true)
        let lane = RecordedScreenshotRetryLane()
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.workInboxForTesting = try Self.refusingInbox(under: inboxRoot)
        recorder.retryLaneForTesting = lane
        recorder.capturedAudioForTesting = Self.recordingBytes
        recorder.workScreenshotNormalizeForTesting = { _ in Self.jpegBytes }
        var hops = 0
        recorder.transcriptionHopForTesting = { _ in
            hops += 1
            return .success("the words that arrive anyway")
        }

        recorder.stageWorkScreenshot(Self.rawScreenshot)
        let result = await recorder._finishCaptureForTesting()

        guard case .failure(let surfaced) = result else {
            return XCTFail("a capture still owing an artifact must not report success")
        }
        XCTAssertEqual(
            surfaced.errorCode, AppError.workScreenshotWriteFailed.errorCode,
            """
            The code names the artifact that is missing. 78's copy says the RECORDING was not \
            saved, which contradicts the card standing on the desk with the words on it.
            """
        )
        XCTAssertTrue(surfaced.isRetryable, "the same bytes, published again, normally land")
        XCTAssertEqual(hops, 1, "the picture cost the words no second round trip")
        XCTAssertTrue(
            recorder.canRetryWorkCapture,
            """
            The Mac HUD's Try Again reads exactly this, and the Mac has no pending-retry card \
            to fall back on. False here is a picture nobody can ever publish.
            """
        )
        XCTAssertEqual(
            recorder.pendingWorkCapture?.transcript, "the words that arrive anyway",
            "the debt is retained WITH the words, so the retry spends no speech hop"
        )
        XCTAssertEqual(recorder.pendingWorkCapture?.screenshotQueued, false)

        let captureID = try XCTUnwrap(recorder.workRecordingMaterialID)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 1, "the recording landed; the picture did not")
        XCTAssertEqual(desk.materials.first?.id, captureID)
        XCTAssertEqual(
            desk.materials.first?.textContent, "the words that arrive anyway",
            "the words really are on the card, which is what the receipt may not deny"
        )

        XCTAssertEqual(
            recorder.workCaptureFacts,
            InAppAudioRecorder.WorkCaptureFacts(
                recordingOnDesk: true,
                wordsOnDesk: true,
                screenshotStaged: true,
                screenshotQueued: false,
                screenshotOnDesk: false,
                screenshotEverOnDesk: false
            ),
            """
            The one shape a single sentence cannot describe: two artifacts landed and one did \
            not. "Nothing reached your desk" and "only the words are missing" are both false \
            here, which is why the surface is handed facts rather than a verdict.
            """
        )

        let lastSave = await lane.lastSave
        let parked = try XCTUnwrap(lastSave, "the picture's only copy must be parked")
        XCTAssertEqual(
            parked.workImageData, Self.rawScreenshot,
            "the retry record carries the bytes, because nothing else holds them"
        )
        XCTAssertEqual(
            parked.metadata.publicationState, .published,
            "the RECORDING's verdict is accurate — it really is a card — so no recovery republishes it"
        )
        XCTAssertEqual(
            parked.metadata.transcript, "the words that arrive anyway",
            "…and the words ride along, so finishing this entry buys nothing from a provider"
        )
        let cleared = await lane.clears
        XCTAssertTrue(
            cleared.isEmpty,
            """
            A capture that still owes an artifact is not finished. Retiring its entry here \
            deletes the last copy of the picture on a clock the person never saw.
            """
        )
    }

    /// Try Again on a capture that owes ONLY its picture. Every other step finds
    /// its work done — the card exists, the words are in hand, the attachment
    /// re-delivers the same words to the same card — so one tap finishes it
    /// with no provider round trip at all, and the entry that sheltered the
    /// picture, and the picture's parked copy, go with it.
    @MainActor
    func testTryAgainOnAPictureOnlyDebtFinishesInOnePassWithNoSpeechHop() async throws {
        let store = ConversationStore(inMemory: true)
        let lane = RecordedScreenshotRetryLane()
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.workInboxForTesting = try Self.refusingInbox(under: inboxRoot)
        recorder.retryLaneForTesting = lane
        recorder.capturedAudioForTesting = Self.recordingBytes
        recorder.workScreenshotNormalizeForTesting = { _ in Self.jpegBytes }
        var hops = 0
        recorder.transcriptionHopForTesting = { _ in
            hops += 1
            return .success("recovered on the retry")
        }

        recorder.stageWorkScreenshot(Self.rawScreenshot)
        _ = await recorder._finishCaptureForTesting()

        let captureID = try XCTUnwrap(recorder.workRecordingMaterialID)
        XCTAssertTrue(recorder.canRetryWorkCapture, "the picture is still owed")
        XCTAssertFalse(recorder.workCaptureFacts.screenshotOnDesk)
        let firstDeskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let firstDesk = try XCTUnwrap(firstDeskValue)
        XCTAssertEqual(firstDesk.materials.count, 1, "only the recording is standing")

        // The queue comes back, and ONE tap settles what is left.
        recorder.workInboxForTesting = Self.workingInbox(under: inboxRoot)
        let repaired = await recorder.retryWorkCapture()

        XCTAssertEqual(try repaired.get(), "recovered on the retry")
        XCTAssertEqual(
            hops, 1,
            """
            NO second speech hop. The words were bought on the first pass and are held with \
            the capture, so a picture-only debt may not cost a provider round trip — nor the \
            key, the network or the wait one needs.
            """
        )
        XCTAssertEqual(
            recorder.workCaptureFacts,
            InAppAudioRecorder.WorkCaptureFacts(
                recordingOnDesk: true,
                wordsOnDesk: true,
                screenshotStaged: true,
                screenshotQueued: true,
                screenshotOnDesk: true,
                screenshotEverOnDesk: true
            ),
            "everything landed in the end, and the facts say so"
        )
        let discarded = await lane.discards
        XCTAssertEqual(
            discarded, [captureID],
            """
            The parked copy is retired the moment a card owns the picture. Left behind it goes \
            on telling the expiry sweep this entry shelters an irreplaceable image.
            """
        )
        let screenshotID = WorkVoiceScreenshotCoordinator.materialID(forCapture: captureID)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(
            Set(desk.materials.map(\.id)), [captureID, screenshotID],
            "the retry publishes the picture at the id derived from the capture, not a second one"
        )
        let picturePayload = try await store.loadWorkMaterialPayload(id: screenshotID)
        XCTAssertEqual(picturePayload, Self.jpegBytes)
        XCTAssertEqual(desk.materials.first { $0.id == captureID }?.textContent,
                       "recovered on the retry")
        XCTAssertEqual(desk.materials.count, 2, "no second card for a re-delivered transcript")
        XCTAssertFalse(recorder.canRetryWorkCapture, "both artifacts landed, so nothing is owed")
        let cleared = await lane.clears
        XCTAssertEqual(
            cleared, [captureID],
            "…and ONLY then is the entry that sheltered the picture retired"
        )
    }

    /// The verdict a refused picture writes must not outlive its own truth.
    ///
    /// The early record is armed BEFORE phase one runs, so the only thing it
    /// can honestly say is that the desk holds no recording. That sentence
    /// becomes false seconds later, and a great many exits — silence, a missing
    /// key, an abandoned hop — end the capture without ever revisiting it. A
    /// recovery reading `.phaseOneFailed` republishes the recording, which is
    /// how a card the person deleted comes back.
    @MainActor
    func testAPublishedRecordingCorrectsTheVerdictARefusedPictureArmed() async throws {
        let store = ConversationStore(inMemory: true)
        let lane = RecordedScreenshotRetryLane()
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.workInboxForTesting = try Self.refusingInbox(under: inboxRoot)
        recorder.retryLaneForTesting = lane
        recorder.capturedAudioForTesting = Self.recordingBytes
        recorder.workScreenshotNormalizeForTesting = { _ in Self.jpegBytes }
        // Silence: an exit that ends the capture on the far side of phase one
        // and never reaches the desk again.
        recorder.transcriptionHopForTesting = { _ in .success("   ") }

        recorder.stageWorkScreenshot(Self.rawScreenshot)
        _ = await recorder._finishCaptureForTesting()

        let saves = await lane.saves
        let firstVerdict = try XCTUnwrap(saves.first).metadata.publicationState
        let lastVerdict = try XCTUnwrap(saves.last).metadata.publicationState
        XCTAssertEqual(
            firstVerdict, .phaseOneFailed,
            "the first record is armed before phase one runs, and says exactly that"
        )
        XCTAssertEqual(
            lastVerdict, .published,
            """
            MEASURED: the verdict is corrected the moment the recording lands, not at the end \
            of a capture that may never get there. A stale `.phaseOneFailed` is licence for a \
            recovery hours later to republish a card the person has since deleted.
            """
        )
        let latestSave = await lane.lastSave
        let latest = try XCTUnwrap(latestSave)
        XCTAssertEqual(
            latest.workImageData, Self.rawScreenshot,
            "and the picture is still sheltered by that same entry"
        )
    }

    /// The Codex scenario the retirement exists for: the retry publishes the
    /// picture and then fails at something else. Its next record carries no
    /// image — the picture is a card now — so a parked file left behind would
    /// be the only thing on disk still claiming this entry shelters an
    /// irreplaceable image, and the clock could never retire it.
    @MainActor
    func testAPictureThatLandsIsRetiredEvenWhenTheRetryGoesOnToFail() async throws {
        let store = ConversationStore(inMemory: true)
        let lane = RecordedScreenshotRetryLane()
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.workInboxForTesting = try Self.refusingInbox(under: inboxRoot)
        recorder.retryLaneForTesting = lane
        recorder.capturedAudioForTesting = Self.recordingBytes
        recorder.workScreenshotNormalizeForTesting = { _ in Self.jpegBytes }
        recorder.transcriptionHopForTesting = { _ in .failure(.sttProviderUnreachable) }

        recorder.stageWorkScreenshot(Self.rawScreenshot)
        _ = await recorder._finishCaptureForTesting()
        let captureID = try XCTUnwrap(recorder.workRecordingMaterialID)

        // The queue comes back; the words still do not.
        recorder.workInboxForTesting = Self.workingInbox(under: inboxRoot)
        let stillFailing = await recorder.retryWorkCapture()

        guard case .failure = stillFailing else {
            return XCTFail("the words are still refused, so the capture is not finished")
        }
        XCTAssertTrue(recorder.workCaptureFacts.screenshotOnDesk, "the picture DID land")
        let discarded = await lane.discards
        XCTAssertEqual(
            discarded, [captureID],
            "the parked copy is retired at the publication, not at the end of the capture"
        )
        let latestSave = await lane.lastSave
        let latest = try XCTUnwrap(latestSave)
        XCTAssertNil(
            latest.workImageData,
            """
            MEASURED: the record written by the failure that followed carries no image. That is \
            precisely why the parked FILE had to be retired explicitly — a save carrying nil \
            writes no file and deletes none.
            """
        )
        let cleared = await lane.clears
        XCTAssertTrue(cleared.isEmpty, "the words are still owed, so the entry stays")
    }

    /// …and the half of that the recorder cannot show: what the retirement does
    /// to the clock. The exemption is read off the FILE, so an entry whose
    /// picture is published is governed by a budget again — the DAY a published
    /// Work capture waits, since its recording is a card and these bytes are a
    /// second copy.
    func testRetiringAPublishedPictureLetsItsEntryExpireOnTheDayBudget() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-shot-retire-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let store = PendingRetryStore(
            containerURL: container, defaults: InMemoryDefaultsStore()
        )
        let armedLongAgo = Date().addingTimeInterval(-Self.wellPastTheBudget)

        let published = Self.metadata(id: UUID(), createdAt: armedLongAgo)
        try await store.save(
            audioData: Self.recordingBytes, metadata: published, workImageData: Self.rawScreenshot
        )
        // The control: the same record, the same age, and a picture nothing has
        // published. It must survive, or this case would pass on a clock that
        // had simply stopped working.
        let stillOwed = Self.metadata(id: UUID(), createdAt: armedLongAgo)
        try await store.save(
            audioData: Self.recordingBytes, metadata: stillOwed, workImageData: Self.rawScreenshot
        )
        // The cross-lane control. A Chat record of the same age is on the SHORT
        // budget and must also be gone, which is what says the sweep below is
        // the ordinary one rather than something special-cased to Work.
        let chat = Self.chatMetadata(id: UUID(), createdAt: armedLongAgo)
        try await store.save(audioData: Self.recordingBytes, metadata: chat, workImageData: nil)

        let reservation = await store.claim(
            id: published.id, duration: PendingRetryStore.claimLeaseDuration
        )
        let claim = try XCTUnwrap(
            reservation,
            "the surface that publishes a picture holds the capture while it does"
        )
        let retired = await store.discardWorkImage(claim)
        // A live reservation exempts a capture from the clock all by itself, so
        // the hold goes back before the sweep is asked anything.
        await store.release(claim)

        XCTAssertTrue(retired, "the retirement must actually happen")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: container
                    .appendingPathComponent(PendingRetryFiles.workImage(published.id)).path
            ),
            "the parked copy is gone"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: container
                    .appendingPathComponent(PendingRetryFiles.audio(published.id, .work)).path
            ),
            "…and only the picture: the recording is not this operation's to touch"
        )

        let surviving = await store.load().map(\.metadata.id)

        XCTAssertEqual(
            surviving, [stillOwed.id],
            """
            MEASURED: with its picture published, the entry is protecting only a transcription \
            again and the day budget retires it. The sibling that still shelters a picture is \
            exempt, and the Chat record of the same age is gone on the shorter budget — which \
            together show the clock is running at all and running for both lanes.
            """
        )
    }

    /// Silence is the exit that named this rule. `.noSpeechDetected` is
    /// terminal and NOT retryable, so before the debt check moved above the
    /// pipeline a capture that ended there offered no Try Again at all — and
    /// the picture it was still holding had nowhere to go, on a surface with no
    /// pending-retry card to fall back on.
    @MainActor
    func testASilentCaptureStillOwingItsPictureStaysRetryable() async throws {
        let store = ConversationStore(inMemory: true)
        let lane = RecordedScreenshotRetryLane()
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.workInboxForTesting = try Self.refusingInbox(under: inboxRoot)
        recorder.retryLaneForTesting = lane
        recorder.capturedAudioForTesting = Self.recordingBytes
        recorder.workScreenshotNormalizeForTesting = { _ in Self.jpegBytes }
        recorder.transcriptionHopForTesting = { _ in .success("   ") }

        recorder.stageWorkScreenshot(Self.rawScreenshot)
        let result = await recorder._finishCaptureForTesting()

        guard case .failure(let surfaced) = result else {
            return XCTFail("silence is not a completed capture")
        }
        XCTAssertEqual(
            surfaced.errorCode, AppError.workScreenshotWriteFailed.errorCode,
            """
            MEASURED: the answer is the PICTURE's error, not silence's. \
            `.noSpeechDetected` is non-retryable, so a HUD that showed it would hide Try Again \
            and the picture would be unreachable for ever.
            """
        )
        XCTAssertTrue(surfaced.isRetryable)
        XCTAssertTrue(recorder.canRetryWorkCapture, "the capture is still finishable")
        XCTAssertEqual(
            recorder.workCaptureFacts,
            InAppAudioRecorder.WorkCaptureFacts(
                recordingOnDesk: true,
                wordsOnDesk: false,
                screenshotStaged: true,
                screenshotQueued: false,
                screenshotOnDesk: false,
                screenshotEverOnDesk: false
            ),
            "the words are what silence cost, and the facts say so beside the error about the picture"
        )
        let latestSave = await lane.lastSave
        let parked = try XCTUnwrap(latestSave, "a silent capture's picture is parked like any other")
        XCTAssertEqual(parked.workImageData, Self.rawScreenshot)

        // …and Try Again settles it as the SPEECH outcome dictates: the picture
        // publishes, and the silence that was always going to be silence is the
        // answer the second time.
        recorder.workInboxForTesting = Self.workingInbox(under: inboxRoot)
        let again = await recorder.retryWorkCapture()

        guard case .failure(let second) = again else {
            return XCTFail("the words are still not there")
        }
        XCTAssertEqual(
            second.errorCode, AppError.noSpeechDetected.errorCode,
            "with the picture published, the speech outcome is free to be the answer again"
        )
        XCTAssertTrue(recorder.workCaptureFacts.screenshotQueued, "the picture is durable now")
        let discarded = await lane.discards
        XCTAssertEqual(discarded, [try XCTUnwrap(recorder.workRecordingMaterialID)])
    }

    /// A card deleted while recognition was in flight, on an exit that never
    /// reaches the attach step. `materialID` is a memory of a write, so the
    /// facts have to ask the desk — otherwise the HUD says a recording is
    /// waiting on a desk that no longer holds it.
    @MainActor
    func testADeletedCardIsNotReportedAsPresentWhenRecognitionFails() async throws {
        let store = ConversationStore(inMemory: true)
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.workInboxForTesting = Self.workingInbox(under: inboxRoot)
        recorder.retryLaneForTesting = RecordedScreenshotRetryLane()
        recorder.capturedAudioForTesting = Self.recordingBytes
        recorder.transcriptionHopForTesting = { _ in
            // The person clears the card while the provider is being waited on.
            let desk = try? await store.fetchWorkItem(id: Constants.workboardDeskItemID)
            if let card = desk?.materials.first {
                try? await store.deleteWorkMaterial(id: card.id)
            }
            return .failure(.sttProviderUnreachable)
        }

        let result = await recorder._finishCaptureForTesting()

        guard case .failure(let surfaced) = result else {
            return XCTFail("the words never arrived")
        }
        XCTAssertEqual(
            surfaced.errorCode, AppError.sttProviderUnreachable.errorCode,
            "no picture was owed, so the speech outcome is the answer"
        )
        XCTAssertFalse(
            recorder.workCaptureFacts.recordingOnDesk,
            """
            MEASURED: the card is gone, and the facts were refreshed from the desk rather than \
            from the id phase one wrote. Reporting it present is the same untruth as reporting \
            a saved picture that never landed.
            """
        )
        XCTAssertFalse(
            recorder.workCaptureFacts.wordsOnDesk,
            "and words cannot be on a card that is not there"
        )
    }

    /// The queue accepted the envelope and the drain that imports it did not
    /// land. The picture is DURABLE — nothing may publish it twice — but it is
    /// not a card, and only a card may be described to a person as saved.
    @MainActor
    func testAQueuedPictureWhoseDrainFailsIsNotReportedAsOnTheDesk() async throws {
        let broken = try Self.unusableStore()
        let refuses = await Self.refusesWrites(broken)
        XCTAssertTrue(refuses, "the fixture must actually refuse a desk write")
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = broken
        recorder.workInboxForTesting = Self.workingInbox(under: inboxRoot)
        recorder.retryLaneForTesting = RecordedScreenshotRetryLane()
        recorder.capturedAudioForTesting = Self.recordingBytes
        recorder.workScreenshotNormalizeForTesting = { _ in Self.jpegBytes }
        recorder.transcriptionHopForTesting = { _ in .success("never reached") }

        recorder.stageWorkScreenshot(Self.rawScreenshot)
        _ = await recorder._finishCaptureForTesting()

        XCTAssertTrue(
            recorder.workCaptureFacts.screenshotQueued,
            "the envelope was accepted, so these bytes are no longer this process's only copy"
        )
        XCTAssertFalse(
            recorder.workCaptureFacts.screenshotOnDesk,
            """
            MEASURED: queued is not saved. The coordinator's drain is best-effort and answers \
            with an id either way, so a fact taken from that id claims a card that is still \
            sitting in the queue.
            """
        )
        XCTAssertFalse(
            recorder.pendingWorkCapture?.owesScreenshot ?? true,
            "…and the debt IS settled: a queued envelope is nobody's to publish a second time"
        )
    }

    /// The two surfaces that recover a parked capture retire its picture too.
    /// Neither can be mounted here — one lives in a SwiftUI view's action and
    /// the other in a menu-bar service — so what is asserted is the call-site
    /// policy: the retirement follows the publication, inside a guard on its answer.
    func testBothRetrySurfacesRetireTheParkedPictureOnlyWhenPublicationTookIt() throws {
        for path in ["Conduck/ContentView.swift", "Conduck/MenuBar/DictationService.swift"] {
            let text = RefusalLaneSource.stripComments(try Self.source(path))
            let publishAt = try XCTUnwrap(
                text.range(of: "WorkVoiceScreenshotCoordinator.publish(")?.lowerBound,
                "\(path) no longer publishes a recovered screenshot at all."
            )
            let discardAt = try XCTUnwrap(
                text.range(of: "discardWorkImage(claim)")?.lowerBound,
                """
                \(path) publishes the recovered picture and leaves its parked file behind. That \
                file is the only thing on disk still claiming the entry shelters an \
                irreplaceable image, so a recovery that throws below leaves the capture exempt \
                from the expiry clock for ever.
                """
            )
            XCTAssertLessThan(
                publishAt, discardAt,
                "\(path) retires the parked picture before it is published anywhere."
            )

            // …and it retires it only on a publication that TOOK the bytes.
            // Publication answers nil when the image pipeline could make
            // nothing of them, having enqueued nothing at all, and a discard
            // there deletes the only copy of the picture.
            // The window has to OPEN BEFORE the call, not at it. `guard try
            // await` sits to the LEFT of the publish it qualifies, so a slice
            // beginning at the call itself can never contain the keyword this
            // regex looks for — it would fail on correct and incorrect code
            // alike. Backing up covers the keyword without loosening the
            // pattern: the regex still demands that `guard try await` be
            // immediately followed by this coordinator's publish, so a bare
            // call preceded by some unrelated guard does not satisfy it.
            let windowStart = text.index(
                publishAt, offsetBy: -160, limitedBy: text.startIndex
            ) ?? text.startIndex
            let guarded = String(text[windowStart...].prefix(560))
            XCTAssertNotNil(
                guarded.range(
                    of: #"guard\s+try\s+await\s+WorkVoiceScreenshotCoordinator\.publish"#,
                    options: .regularExpression
                ),
                """
                \(path) publishes the recovered picture without requiring an id back, so a \
                normalization failure — which enqueues nothing — still reaches the discard \
                below and deletes the last copy of the picture.
                """
            )
            XCTAssertNotNil(
                guarded.range(of: "!= nil"),
                "\(path) no longer tests the publication's answer at all."
            )
            XCTAssertNotNil(
                text.range(of: "AppError.workScreenshotWriteFailed"),
                """
                \(path) reports a recovery whose picture was refused without naming the \
                picture, so the person is told about a recording that is standing fine.
                """
            )
        }
    }

    /// A desk cleared while recognition awaits, and an exit that never reaches
    /// the attach step. BOTH cards have to be re-read: the picture's earlier
    /// arrival is as much a memory of a write as the recording's, and a receipt
    /// that says "your screenshot is on your desk" over an empty desk is the
    /// same untruth.
    @MainActor
    func testADeletedScreenshotCardIsNotReportedAsPresentWhenRecognitionFails() async throws {
        let store = ConversationStore(inMemory: true)
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.workInboxForTesting = Self.workingInbox(under: inboxRoot)
        recorder.retryLaneForTesting = RecordedScreenshotRetryLane()
        recorder.capturedAudioForTesting = Self.recordingBytes
        recorder.workScreenshotNormalizeForTesting = { _ in Self.jpegBytes }
        recorder.transcriptionHopForTesting = { _ in
            // The person clears their desk while the provider is waited on.
            let desk = try? await store.fetchWorkItem(id: Constants.workboardDeskItemID)
            for card in desk?.materials ?? [] {
                try? await store.deleteWorkMaterial(id: card.id)
            }
            return .failure(.sttProviderUnreachable)
        }

        recorder.stageWorkScreenshot(Self.rawScreenshot)
        _ = await recorder._finishCaptureForTesting()

        XCTAssertTrue(
            recorder.workCaptureFacts.screenshotQueued,
            """
            Acceptance is HISTORY and does not un-happen: the inbox took this envelope, which \
            is what says the capture owes nothing more for it. Clearing it here would have the \
            capture publish a picture somebody deliberately deleted.
            """
        )
        XCTAssertFalse(
            recorder.workCaptureFacts.screenshotOnDesk,
            """
            MEASURED: the card is gone, so the picture is not on the desk and no receipt may \
            say it is. Presence is re-read for BOTH artifacts, not just the recording.
            """
        )
        XCTAssertFalse(
            recorder.workCaptureFacts.screenshotImportPending,
            """
            MEASURED: a card that ARRIVED and was deleted is not on its way. Only a queued \
            picture no lookup has ever confirmed is still coming, and promising a card that \
            will never appear is the same untruth as claiming one that is gone.
            """
        )
        XCTAssertTrue(
            recorder.workCaptureFacts.screenshotEverOnDesk,
            "…which is knowable only because the confirmation is remembered"
        )
        XCTAssertFalse(recorder.workCaptureFacts.recordingOnDesk)
        XCTAssertFalse(recorder.workCaptureFacts.wordsOnDesk)
    }

    /// Cancellation is checked between the image pipeline and the queue,
    /// because that is the last instant at which nothing durable exists. Past
    /// it the envelope is accepted and a cancel would have to be reported as a
    /// picture saved after all.
    func testAPublicationCancelledBeforeTheQueueEnqueuesNothing() async throws {
        let store = ConversationStore(inMemory: true)
        let inbox = Self.workingInbox(under: inboxRoot)
        let captureID = UUID()

        let task = Task { () -> UUID? in
            try await WorkVoiceScreenshotCoordinator.publish(
                Self.rawScreenshot,
                forCapture: captureID,
                createdAt: Date(),
                inbox: inbox,
                store: store,
                sourceDevice: "test-device",
                normalize: { _ in Self.jpegBytes }
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("a cancelled publication must not answer with an id")
        } catch is CancellationError {
            // The bytes are still the caller's, which is what lets it retry.
        }

        let queued = try await inbox.pendingCount()
        XCTAssertEqual(queued, 0, "MEASURED: nothing was enqueued, so nothing has to be undone")
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertNil(deskValue, "…and no card was written either")
    }

    /// ✕ during a picture-only retry. The speech hop is skipped entirely on
    /// that path, so nothing else in the pipeline looks at cancellation — and
    /// the answer it would otherwise return is the success the words already
    /// earned, told to somebody who just cancelled.
    @MainActor
    func testCancellingAPictureOnlyRetryReportsACancelAndKeepsTheDebt() async throws {
        let store = ConversationStore(inMemory: true)
        let lane = RecordedScreenshotRetryLane()
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.workInboxForTesting = try Self.refusingInbox(under: inboxRoot)
        recorder.retryLaneForTesting = lane
        recorder.capturedAudioForTesting = Self.recordingBytes
        recorder.workScreenshotNormalizeForTesting = { _ in Self.jpegBytes }
        recorder.transcriptionHopForTesting = { _ in .success("the words that already landed") }

        recorder.stageWorkScreenshot(Self.rawScreenshot)
        _ = await recorder._finishCaptureForTesting()
        XCTAssertTrue(recorder.canRetryWorkCapture, "the picture is owed")

        // The queue is fine now; the person is not waiting.
        recorder.workInboxForTesting = Self.workingInbox(under: inboxRoot)
        recorder.workScreenshotNormalizeForTesting = { [weak recorder] _ in
            recorder?.cancelProcessing()
            return Self.jpegBytes
        }
        let cancelled = await recorder.retryWorkCapture()

        guard case .failure(let surfaced) = cancelled else {
            return XCTFail("a cancelled retry must not report the picture saved")
        }
        guard case .unknown(let underlying) = surfaced, underlying is CancellationError else {
            return XCTFail("the answer is a cancellation, not an error about the desk")
        }
        XCTAssertEqual(
            recorder.state, .error(.workScreenshotWriteFailed),
            """
            MEASURED: back to the SAME surface the tap came from. `.idle` took the capture off \
            every affordance there is — the popover draws no Work HUD over an idle recorder \
            and the hotkey's finish arm refuses an idle capture — so an abandoned attempt \
            silently made the picture unreachable and the next capture replaced it.
            """
        )
        XCTAssertTrue(recorder.canRetryWorkCapture, "…and the picture is still theirs to publish")
        XCTAssertFalse(recorder.workCaptureFacts.screenshotQueued)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(
            desk.materials.count, 1,
            "MEASURED: only the recording. The cancel landed before anything was enqueued."
        )

        // The abandoned attempt cost nothing: the same Try Again finishes it.
        recorder.workScreenshotNormalizeForTesting = { _ in Self.jpegBytes }
        let repaired = await recorder.retryWorkCapture()

        XCTAssertEqual(try repaired.get(), "the words that already landed")
        XCTAssertTrue(recorder.workCaptureFacts.screenshotOnDesk)
        XCTAssertFalse(recorder.canRetryWorkCapture)
    }

    /// A picture-only retry asks the desk about its WORDS not at all. The
    /// attachment was answered on the first pass, and asking again is a
    /// throwing store read whose failure reports a refused recording for a
    /// capture whose recording was never in question.
    @MainActor
    func testAPictureOnlyRetryNeverReopensTheAttachmentItAlreadySettled() async throws {
        let store = ConversationStore(inMemory: true)
        let lane = RecordedScreenshotRetryLane()
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.workInboxForTesting = try Self.refusingInbox(under: inboxRoot)
        recorder.retryLaneForTesting = lane
        recorder.capturedAudioForTesting = Self.recordingBytes
        recorder.workScreenshotNormalizeForTesting = { _ in Self.jpegBytes }
        recorder.transcriptionHopForTesting = { _ in .success("settled on the first pass") }

        recorder.stageWorkScreenshot(Self.rawScreenshot)
        _ = await recorder._finishCaptureForTesting()
        let captureID = try XCTUnwrap(recorder.workRecordingMaterialID)

        // The queue comes back and the STORE breaks. A retry that asked about
        // the words again would be refused by it, and would report a desk
        // failure for words that are already on the card.
        let broken = try Self.unusableStore()
        let refuses = await Self.refusesWrites(broken)
        XCTAssertTrue(refuses, "the fixture must actually refuse a desk write")
        recorder.workInboxForTesting = Self.workingInbox(under: inboxRoot)
        recorder.workStoreForTesting = broken
        let repaired = await recorder.retryWorkCapture()

        XCTAssertEqual(
            try repaired.get(), "settled on the first pass",
            """
            MEASURED: the retry succeeded against a store that refuses everything, which it \
            could only do by never asking. Phase two is answered once per capture.
            """
        )
        XCTAssertFalse(recorder.canRetryWorkCapture, "the picture is queued, so nothing is owed")
        let cleared = await lane.clears
        XCTAssertEqual(cleared, [captureID], "…and the entry that sheltered it is retired")
    }

    /// The microphone gave nothing, and a region had already been dragged. The
    /// silence is still the answer, but the picture is not dropped with it: it
    /// gets a capture of its own that owes no recording, and one Try Again puts
    /// it on the desk.
    @MainActor
    func testAMicrophoneThatGaveNothingStillCarriesTheStagedPicture() async throws {
        let store = ConversationStore(inMemory: true)
        let lane = RecordedScreenshotRetryLane()
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.workInboxForTesting = try Self.refusingInbox(under: inboxRoot)
        recorder.retryLaneForTesting = lane
        recorder.capturedAudioForTesting = Data()
        recorder.workScreenshotNormalizeForTesting = { _ in Self.jpegBytes }
        recorder.transcriptionHopForTesting = { _ in
            XCTFail("a capture with no recording has nothing to transcribe")
            return .failure(.audioMissingData)
        }

        recorder.stageWorkScreenshot(Self.rawScreenshot)
        let result = await recorder._finishCaptureForTesting()

        guard case .failure(let surfaced) = result else {
            return XCTFail("an empty recording is not a completed capture")
        }
        XCTAssertEqual(
            surfaced.errorCode, AppError.workScreenshotWriteFailed.errorCode,
            "the picture is owed, so the retryable answer is the one that offers Try Again"
        )
        XCTAssertTrue(
            recorder.canRetryWorkCapture,
            """
            MEASURED: the picture survived a microphone that gave nothing. The guard that used \
            to return here ran BEFORE the staged bytes were moved into a capture, so the debt \
            wrapper found nothing pending and the HUD offered no way to publish them.
            """
        )
        XCTAssertEqual(
            recorder.workCaptureFacts,
            InAppAudioRecorder.WorkCaptureFacts(
                recordingOnDesk: false,
                wordsOnDesk: false,
                screenshotStaged: true,
                screenshotQueued: false,
                screenshotOnDesk: false,
                screenshotEverOnDesk: false
            )
        )
        let saves = await lane.saves
        XCTAssertTrue(
            saves.isEmpty,
            """
            A capture with no recording is held in memory ONLY. Every surface that recovers a \
            queued capture begins by transcribing it, so an entry with no audio is one none of \
            them could ever finish.
            """
        )

        // Read the identity BEFORE the retry retires the capture that holds it.
        let captureID = try XCTUnwrap(recorder.pendingWorkCapture?.id)

        // One Try Again, and the picture is a card.
        recorder.workInboxForTesting = Self.workingInbox(under: inboxRoot)
        let repaired = await recorder.retryWorkCapture()

        guard case .failure(let second) = repaired else {
            return XCTFail("there is still no recording, so this capture cannot succeed")
        }
        XCTAssertEqual(
            second.errorCode, AppError.audioMissingData.errorCode,
            "with the picture settled the microphone's own answer is what stands"
        )
        XCTAssertFalse(recorder.canRetryWorkCapture, "and nothing is owed any more")
        XCTAssertEqual(
            recorder.state, .error(.audioMissingData),
            """
            MEASURED: a terminal failure the person has not dismissed stays on screen. Going \
            `.idle` once the picture settled took the whole outcome away with it — neither the \
            missing recording nor the picture that DID land was shown anywhere.
            """
        )
        XCTAssertEqual(
            recorder.workCaptureFacts,
            InAppAudioRecorder.WorkCaptureFacts(
                recordingOnDesk: false,
                wordsOnDesk: false,
                screenshotStaged: true,
                screenshotQueued: true,
                screenshotOnDesk: true,
                screenshotEverOnDesk: true
            ),
            "…and the facts beside it are the whole truth: no recording, and a picture that landed"
        )
        let screenshotID = WorkVoiceScreenshotCoordinator.materialID(forCapture: captureID)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 1, "one card, the picture — there was no recording")
        XCTAssertEqual(desk.materials.first?.kind, .image)
        XCTAssertEqual(desk.materials.first?.id, screenshotID)
    }

    /// ✕ pressed once the queue has ALREADY taken the picture. Nothing is owed
    /// any more, so the capture is genuinely finished — but the person withdrew
    /// the request, and "Added to Work." printed over their ✕ answers a
    /// question they had just cancelled.
    @MainActor
    func testCancellingAfterThePictureIsAcceptedEndsSilentlyAndRetiresTheCapture() async throws {
        let store = ConversationStore(inMemory: true)
        let lane = RecordedScreenshotRetryLane()
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.workInboxForTesting = try Self.refusingInbox(under: inboxRoot)
        recorder.retryLaneForTesting = lane
        recorder.capturedAudioForTesting = Self.recordingBytes
        recorder.workScreenshotNormalizeForTesting = { _ in Self.jpegBytes }
        recorder.transcriptionHopForTesting = { _ in .success("the words that already landed") }

        recorder.stageWorkScreenshot(Self.rawScreenshot)
        _ = await recorder._finishCaptureForTesting()
        let captureID = try XCTUnwrap(recorder.workRecordingMaterialID)

        // The ✕ lands on the far side of acceptance: the retirement of the
        // parked copy is the first thing that happens once the queue has taken
        // the picture, so a hook there stands exactly where the person's press
        // would have.
        recorder.workInboxForTesting = Self.workingInbox(under: inboxRoot)
        await lane.cancelOnDiscard { [weak recorder] in recorder?.cancelProcessing() }
        let cancelled = await recorder.retryWorkCapture()

        guard case .failure(let surfaced) = cancelled else {
            return XCTFail("a withdrawn request may not report a capture saved")
        }
        guard case .unknown(let underlying) = surfaced, underlying is CancellationError else {
            return XCTFail("the answer is a cancellation, not an error")
        }
        XCTAssertEqual(
            recorder.state, .idle,
            "nothing is owed, so there is no error surface to return to — it just stops"
        )
        XCTAssertFalse(
            recorder.canRetryWorkCapture,
            "MEASURED: the capture IS finished. The cancel changes what is said, not what landed."
        )
        XCTAssertTrue(recorder.workCaptureFacts.screenshotQueued)
        let cleared = await lane.clears
        XCTAssertEqual(cleared, [captureID], "…and its entry is retired, owing nothing")
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(
            Set(desk.materials.map(\.id)),
            [captureID, WorkVoiceScreenshotCoordinator.materialID(forCapture: captureID)],
            "both artifacts are on the desk — the picture was accepted before the ✕"
        )
    }

    /// A card the desk ANSWERED for. `.recordingMissing` is a fact, and a
    /// resumed capture must not re-derive presence from the material id that
    /// fact was about — least of all when the store cannot be read and the
    /// refresh has nothing to correct it with.
    @MainActor
    func testARetryNeverResurrectsARecordingTheDeskAlreadySaidWasGone() async throws {
        let store = ConversationStore(inMemory: true)
        let lane = RecordedScreenshotRetryLane()
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.workInboxForTesting = try Self.refusingInbox(under: inboxRoot)
        recorder.retryLaneForTesting = lane
        recorder.capturedAudioForTesting = Self.recordingBytes
        recorder.workScreenshotNormalizeForTesting = { _ in Self.jpegBytes }
        recorder.transcriptionHopForTesting = { _ in
            // The recording is cleared while the provider is waited on, so the
            // attach step answers `.recordingMissing`.
            let desk = try? await store.fetchWorkItem(id: Constants.workboardDeskItemID)
            if let card = desk?.materials.first {
                try? await store.deleteWorkMaterial(id: card.id)
            }
            return .success("words with nowhere to land")
        }

        recorder.stageWorkScreenshot(Self.rawScreenshot)
        _ = await recorder._finishCaptureForTesting()

        XCTAssertFalse(recorder.workCaptureFacts.recordingOnDesk, "the desk said so")
        XCTAssertTrue(recorder.canRetryWorkCapture, "the picture is still owed")

        // The retry runs against a store that cannot be READ, so the refresh
        // has no answer at all. Only the remembered verdict stands between the
        // historical material id and a receipt claiming the recording is there.
        let broken = try Self.unusableStore()
        recorder.workStoreForTesting = broken
        let again = await recorder.retryWorkCapture()

        guard case .failure(let surfaced) = again else {
            return XCTFail("the picture is still refused, so the capture is not finished")
        }
        XCTAssertEqual(surfaced.errorCode, AppError.workScreenshotWriteFailed.errorCode)
        XCTAssertFalse(
            recorder.workCaptureFacts.recordingOnDesk,
            """
            MEASURED: a confirmed absence survives the resume. Re-deriving presence from \
            `materialID` — which is only a memory of a write — tells somebody who cleared \
            their desk that the recording is waiting on it.
            """
        )
        XCTAssertFalse(recorder.workCaptureFacts.wordsOnDesk)
    }

    /// Retiring a capture is news for the same reason arming one is: the
    /// surface whose row says how many are waiting is not always the one that
    /// finished this one. A stale positive offers a Retry against an empty
    /// queue, which answers "No saved recording to retry."
    func testRetiringACaptureAnnouncesTheQueueChanged() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-shot-notify-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let store = PendingRetryStore(
            containerURL: container, defaults: InMemoryDefaultsStore()
        )
        let parked = Self.metadata(id: UUID(), createdAt: Date())
        try await store.save(
            audioData: Self.recordingBytes, metadata: parked, workImageData: nil
        )
        let reservation = await store.claim(
            id: parked.id, duration: PendingRetryStore.claimLeaseDuration
        )
        let claim = try XCTUnwrap(reservation)

        // Armed AFTER the save, so only the retirement can fulfil it.
        let announced = expectation(
            forNotification: PendingRetryStore.queueDidChangeNotification,
            object: nil
        )
        let retired = await store.clear(claim)

        XCTAssertTrue(retired, "the fixture must actually retire the capture")
        await fulfillment(of: [announced], timeout: 2)
    }

    /// An absence learned by the REFRESH, on an exit that never reaches the
    /// attach step. It has to be latched onto the capture exactly as the attach
    /// step's own verdict is: a later pass cannot ask again once the store has
    /// stopped answering, and the material id outlives the card.
    @MainActor
    func testAnAbsenceLearnedByTheRefreshSurvivesTheResume() async throws {
        let store = ConversationStore(inMemory: true)
        let lane = RecordedScreenshotRetryLane()
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.workInboxForTesting = try Self.refusingInbox(under: inboxRoot)
        recorder.retryLaneForTesting = lane
        recorder.capturedAudioForTesting = Self.recordingBytes
        recorder.workScreenshotNormalizeForTesting = { _ in Self.jpegBytes }
        recorder.transcriptionHopForTesting = { _ in
            // Cleared while the provider is waited on, and the words never
            // arrive — so nothing asks the desk again on the way out.
            let desk = try? await store.fetchWorkItem(id: Constants.workboardDeskItemID)
            if let card = desk?.materials.first {
                try? await store.deleteWorkMaterial(id: card.id)
            }
            return .failure(.sttProviderUnreachable)
        }

        recorder.stageWorkScreenshot(Self.rawScreenshot)
        _ = await recorder._finishCaptureForTesting()

        XCTAssertFalse(recorder.workCaptureFacts.recordingOnDesk, "the lookup said so")
        XCTAssertEqual(
            recorder.pendingWorkCapture?.recordingConfirmedGone, true,
            """
            MEASURED: the refresh LATCHED what it found. Only the attach step used to record \
            an absence, and this exit never reaches it — so the verdict lived in a fact the \
            next pass was free to overwrite.
            """
        )

        // The retry runs against a store that cannot be read, so nothing can
        // correct a presence re-derived from the historical id.
        let broken = try Self.unusableStore()
        recorder.workStoreForTesting = broken
        let again = await recorder.retryWorkCapture()

        guard case .failure = again else {
            return XCTFail("neither artifact landed, so the capture is not finished")
        }
        XCTAssertFalse(
            recorder.workCaptureFacts.recordingOnDesk,
            "the recording is still gone, and no pass may say otherwise"
        )
        XCTAssertFalse(recorder.workCaptureFacts.wordsOnDesk)
    }

    /// The menu-bar service's own half of a dismissed debt. It cannot be
    /// mounted here — the class registers on the exclusivity bus and owns a
    /// live recorder — so what is asserted is the gate: a queue that still
    /// holds something is reachable from idle, and reaching it changes who may
    /// ask rather than what the answer does.
    func testTheMenuBarServiceCanReachAParkedCaptureWhileIdle() throws {
        let path = "Conduck/MenuBar/DictationService.swift"
        let text = RefusalLaneSource.stripComments(try Self.source(path))

        // A computed property, so it is scoped by a window after its
        // declaration rather than by the brace matcher, which reads `func`.
        let declaration = try XCTUnwrap(
            text.range(of: "var canRecoverPendingQueue: Bool"),
            "\(path) no longer declares the gate the popover draws its recovery from."
        )
        let gate = String(text[declaration.upperBound...].prefix(160))
        XCTAssertTrue(
            gate.contains("state == .idle"),
            "the recovery is offered from IDLE — the state a dismissed Work error leaves behind."
        )
        XCTAssertTrue(
            gate.contains("pendingRetryCount > 0"),
            "…and only while something is actually parked, or it offers a tap that answers nothing."
        )

        let retry = try RefusalLaneSource.body(ofFunction: "retryLast", in: text, path: path)
        XCTAssertNil(
            retry.range(of: "guard case .error = state else { return }"),
            """
            `retryLast` still refuses everything but a standing error, so the queue-only \
            recovery `canRecoverPendingQueue` advertises cannot run: the ✕ that dismissed the \
            Work debt is exactly what left this service idle.
            """
        )
        XCTAssertTrue(
            retry.contains("isRetryPermitted"),
            "the two ways in are one question, asked once."
        )
        XCTAssertTrue(
            text.contains("finishWorkRetry(claim, transcript:"),
            """
            A Work entry recovered from idle must reach the DESK by the same path an error-state \
            recovery takes. Losing it here turns a private voice note into a chat turn.
            """
        )
    }

    /// A HAL abort mid-recording. The microphone gave nothing and the region
    /// was dragged before it was ever asked for anything, so the picture is in
    /// exactly the position a silent microphone leaves it in — and it must
    /// survive the same way. Ending at the error left it staged with no capture
    /// to hold it: Stop refuses because the recording is over, and Try Again
    /// has nothing to finish.
    @MainActor
    func testAnAbortedRecordingStillCarriesTheStagedPictureToTheDesk() async throws {
        let store = ConversationStore(inMemory: true)
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.workInboxForTesting = Self.workingInbox(under: inboxRoot)
        recorder.retryLaneForTesting = RecordedScreenshotRetryLane()
        recorder.speechAuthorizationForTesting = .authorized
        recorder.microphoneStartForTesting = { true }
        // The abort is what the capture has instead of bytes.
        recorder.capturedAudioForTesting = Data()
        recorder.workScreenshotNormalizeForTesting = { _ in Self.jpegBytes }
        recorder.transcriptionHopForTesting = { _ in
            XCTFail("a capture with no recording has nothing to transcribe")
            return .failure(.audioMissingData)
        }

        recorder.stageWorkScreenshot(Self.rawScreenshot)
        await recorder.startRecording()
        guard case .recording = recorder.state else {
            return XCTFail("the fixture must actually reach a live recording")
        }
        await recorder._failRecordingForTesting()

        XCTAssertEqual(
            recorder.state, .error(.audioMissingData),
            "the abort is still the answer, and it stays on screen until dismissed"
        )
        XCTAssertFalse(recorder.canRetryWorkCapture, "nothing is owed — the picture landed")
        XCTAssertEqual(
            recorder.workCaptureFacts,
            InAppAudioRecorder.WorkCaptureFacts(
                recordingOnDesk: false,
                wordsOnDesk: false,
                screenshotStaged: true,
                screenshotQueued: true,
                screenshotOnDesk: true,
                screenshotEverOnDesk: true
            ),
            """
            MEASURED: the picture reached the desk through an exit that used to end at a bare
            `.error`. The staged bytes had no capture to move into, so nothing published them
            and nothing offered to.
            """
        )
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 1, "one card, the picture — there was no recording")
        XCTAssertEqual(desk.materials.first?.kind, .image)
    }

    /// The control, and the behaviour this must not change: an abort with no
    /// picture staged is the bare error it has always been.
    @MainActor
    func testAnAbortedRecordingWithNoPictureIsTheBareErrorItAlwaysWas() async throws {
        let store = ConversationStore(inMemory: true)
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.workInboxForTesting = Self.workingInbox(under: inboxRoot)
        recorder.speechAuthorizationForTesting = .authorized
        recorder.microphoneStartForTesting = { true }
        var normalizeRan = false
        recorder.workScreenshotNormalizeForTesting = { _ in
            normalizeRan = true
            return Self.jpegBytes
        }

        await recorder.startRecording()
        await recorder._failRecordingForTesting()

        XCTAssertEqual(recorder.state, .error(.audioMissingData))
        XCTAssertFalse(recorder.canRetryWorkCapture)
        XCTAssertFalse(normalizeRan, "there was no picture, so nothing was published")
        XCTAssertEqual(recorder.workCaptureFacts, .none, "and nothing to report about one")
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertNil(deskValue, "the desk is untouched")
    }

    /// …and the wiring, which the seam above deliberately does not prove: the
    /// delegate callback has to reach that handler and nothing else.
    func testTheRecorderFailureCallbackRunsTheHandlerTheseCasesDrive() throws {
        let text = RefusalLaneSource.stripComments(
            try Self.source("Conduck/Services/InAppAudioRecorder.swift")
        )
        let callback = try XCTUnwrap(
            text.range(of: "recorder.onRecordingFailed = {"),
            "the recorder no longer answers the audio delegate's failure at all."
        )
        let handler = String(text[callback.upperBound...].prefix(200))
        XCTAssertTrue(
            handler.contains("handleUnexpectedRecordingFailure()"),
            """
            The callback sets a state of its own again, so an abort skips the picture-only
            finalization and the staged region is stranded with no capture to hold it.
            """
        )
    }

    // MARK: - The clock does not retire a capture whose picture is still here

    /// The expiry budget is a budget for a TRANSCRIPTION, and it reads the
    /// recording's verdict. A capture whose recording is a card and whose
    /// picture is not has a `.published` verdict and a screenshot that exists
    /// nowhere else — so the file, not the verdict, is what the clock has to
    /// ask before it deletes anything.
    func testTheClockDoesNotRetireAnEntryStillHoldingAnUnpublishedScreenshot() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-shot-expiry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let store = PendingRetryStore(
            containerURL: container, defaults: InMemoryDefaultsStore()
        )
        let armedLongAgo = Date().addingTimeInterval(-Self.wellPastTheBudget)

        let withPicture = Self.metadata(id: UUID(), createdAt: armedLongAgo)
        try await store.save(
            audioData: Self.recordingBytes,
            metadata: withPicture,
            workImageData: Self.rawScreenshot
        )
        // The control: the same record, the same age, the same verdict, and no
        // picture. Without it this case would pass just as well if the clock
        // had stopped working altogether.
        let withoutPicture = Self.metadata(id: UUID(), createdAt: armedLongAgo)
        try await store.save(
            audioData: Self.recordingBytes,
            metadata: withoutPicture,
            workImageData: nil
        )
        // The control that pins WHICH budget. Same record, same verdict, no
        // picture, but aged past ten minutes and well inside the day: on the
        // transcription TTL this is swept, and on the published-Work one it
        // survives. It is the only fixture here whose fate differs between the
        // two rules, so it is the one that says the longer budget is real —
        // and it is the case the car actually depends on.
        let withinTheDay = Self.metadata(
            id: UUID(),
            createdAt: Date().addingTimeInterval(-Self.pastTenMinutesWithinTheDay)
        )
        try await store.save(
            audioData: Self.recordingBytes, metadata: withinTheDay, workImageData: nil
        )
        // …and the cross-lane control at that same age. A Chat capture IS on the
        // ten-minute budget, so it must be gone — which is what stops the
        // survivor above being explained by a clock that had simply stopped.
        let chatWithinTheDay = Self.chatMetadata(
            id: UUID(),
            createdAt: Date().addingTimeInterval(-Self.pastTenMinutesWithinTheDay)
        )
        try await store.save(
            audioData: Self.recordingBytes, metadata: chatWithinTheDay, workImageData: nil
        )

        let surviving = Set(await store.load().map(\.metadata.id))

        XCTAssertEqual(
            surviving, [withPicture.id, withinTheDay.id],
            """
            MEASURED: the clock retired the day-old capture that owed nothing and kept the one \
            still holding a picture. Both say `.published`, which is true of their RECORDINGS \
            and says nothing at all about the pictures. It also kept the hour-old published \
            Work capture and retired the hour-old CHAT one, which is the whole of the new \
            rule: past ten minutes, the two lanes no longer answer the same way.
            """
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: container
                    .appendingPathComponent(PendingRetryFiles.workImage(withPicture.id)).path
            ),
            "and the bytes are still there, which is the only reason keeping the entry matters"
        )
    }

    // MARK: - Fixtures

    /// Stands in for a compressed 16 kHz mono AAC voice note: small, so the
    /// storage policy picks the synced lane exactly as it does in the app, and
    /// not decodable as audio, so `AudioCompressor` returns it untouched.
    private static let recordingBytes = Data(repeating: 0x7F, count: 4_096)

    /// The bytes the overlay hands over — a raw region capture, before the
    /// image pipeline has stripped its metadata.
    private static let rawScreenshot = Data("the region that was dragged".utf8)

    /// What the pipeline answers with: the normalized JPEG that becomes the
    /// card's payload.
    private static let jpegBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46])

    /// Comfortably past the LONGEST budget any fixture here can be on, so a
    /// case is about the exemption rather than about a clock skew of seconds.
    ///
    /// Derived rather than written as a number: every record below is a
    /// `.published` Work one, which waits `publishedWorkRetryTTL` — a day — and
    /// a hardcoded hour would have quietly stopped being "past the budget" the
    /// moment that constant grew, leaving these cases asserting a sweep that
    /// never ran.
    private static let wellPastTheBudget: TimeInterval =
        PendingRetryMetadata.publishedWorkRetryTTL + 3_600

    /// Past the ten-minute transcription budget and well INSIDE the day a
    /// published Work capture gets. The age at which the two rules disagree,
    /// which is the only age that proves which one is running.
    private static let pastTenMinutesWithinTheDay: TimeInterval = 3_600

    /// A store that cannot mount, so every operation on it throws — including
    /// the drain that turns a queued envelope into a card. The URL names a
    /// DIRECTORY, which SQLite cannot open as a database file.
    private static func unusableStore() throws -> ConversationStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "conduck-shot-unusable-\(UUID().uuidString).sqlite", isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return ConversationStore(inMemory: false, storeURL: directory)
    }

    /// Proves the broken fixture is really broken: a case that passed because
    /// the store quietly worked would assert nothing at all.
    private static func refusesWrites(_ store: ConversationStore) async -> Bool {
        do {
            _ = try await store.upsertDeskMaterial(
                WorkMaterialDraft(
                    id: UUID(), kind: .note, title: "probe",
                    textContent: "probe", storageMode: .metadataOnly
                )
            )
            return false
        } catch {
            return true
        }
    }

    /// `.../Conduck/Conduck` — the project container holding the app sources.
    /// Derived from this file's compile-time path so the source guard does not
    /// depend on the test runner's working directory.
    private static func source(_ relativePath: String) throws -> String {
        let container = URL(fileURLWithPath: #filePath)  // .../ConduckTests/<this>
            .deletingLastPathComponent()                 // .../ConduckTests
            .deletingLastPathComponent()                 // .../Conduck/Conduck
        return try String(
            contentsOf: container.appendingPathComponent(relativePath), encoding: .utf8
        )
    }

    /// A queue of this case's own, under a directory nothing else writes. The
    /// production one is a single App-Group directory every capture surface in
    /// the process publishes into, which is neither isolated nor empty.
    private static func workingInbox(under root: URL) -> WorkCaptureInbox {
        WorkCaptureInbox(
            baseURL: root.appendingPathComponent("queue-\(UUID().uuidString)", isDirectory: true)
        )
    }

    /// A queue that cannot open its own directories, because its base path is
    /// an ordinary FILE. It stands for the transient refusal — a full disk, a
    /// protected-data blackout — that must cost the picture and nothing else.
    private static func refusingInbox(under root: URL) throws -> WorkCaptureInbox {
        let blocked = root.appendingPathComponent("blocked-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: blocked)
        return WorkCaptureInbox(baseURL: blocked)
    }

    /// A Work record in the state this lane leaves behind: the recording is a
    /// card, so the entry protects only a transcription — on the day budget a
    /// published Work capture waits, not the ten-minute one.
    private static func metadata(id: UUID, createdAt: Date) -> PendingRetryMetadata {
        PendingRetryMetadata(
            id: id,
            createdAt: createdAt,
            audioFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("conduck-shot-\(id.uuidString).m4a"),
            preferredLanguage: nil,
            attemptCount: 1,
            lastErrorCode: AppError.workDeskWriteFailed.errorCode,
            destination: .work,
            transcript: "already bought",
            publicationState: .published
        )
    }

    /// The other lane's record, for the cases that have to show the two budgets
    /// are actually different. A Chat capture's words can be bought again, so
    /// it waits ten minutes and nothing about the desk applies to it.
    private static func chatMetadata(id: UUID, createdAt: Date) -> PendingRetryMetadata {
        PendingRetryMetadata(
            id: id,
            createdAt: createdAt,
            audioFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("conduck-shot-chat-\(id.uuidString).m4a"),
            preferredLanguage: nil,
            attemptCount: 1,
            lastErrorCode: AppError.sttProviderUnreachable.errorCode,
            destination: .chat,
            transcript: nil,
            publicationState: nil
        )
    }
}

/// The retry queue as this lane uses it, with the SCREENSHOT kept.
///
/// The real store is a process-global singleton over one App-Group file every
/// capture test in the bundle shares, and what these cases assert is what the
/// recorder parks and when it lets go — a property of the recorder, not of the
/// wire format. The existing lane double lives private to another suite and
/// drops `workImageData`, which is the one field these cases are about.
private actor RecordedScreenshotRetryLane: PendingRetryLaneReserving {

    /// Everything the recorder asked to park, newest last, bytes included.
    private(set) var saves: [(metadata: PendingRetryMetadata, workImageData: Data?)] = []

    /// Every capture retired through a reservation, so a case can tell an entry
    /// that was finished from one that was merely handed back.
    private(set) var clears: [UUID] = []

    /// Every capture whose parked picture was retired, newest last. The real
    /// store deletes a file; what a case asserts here is that the recorder ASKS
    /// — at the publication, not at the end of the capture.
    private(set) var discards: [UUID] = []

    var lastSave: (metadata: PendingRetryMetadata, workImageData: Data?)? { saves.last }

    private var leases: [UUID: UUID] = [:]

    func save(
        audioData: Data,
        metadata: PendingRetryMetadata,
        workImageData: Data?
    ) async throws {
        saves.append((metadata, workImageData))
    }

    func claim(id: UUID, duration: TimeInterval) async -> PendingRetryClaim? {
        guard let parked = saves.last(where: { $0.metadata.id == id }) else { return nil }
        let token = UUID()
        leases[id] = token
        return PendingRetryClaim(
            entry: PendingRetryEntry(
                audioData: Data(),
                metadata: parked.metadata,
                workImageData: parked.workImageData
            ),
            token: token
        )
    }

    @discardableResult
    func renew(_ claim: PendingRetryClaim) async -> Bool {
        leases[claim.id] == claim.token
    }

    func confirmOwnership(_ claim: PendingRetryClaim) async -> Bool {
        leases[claim.id] == claim.token
    }

    func release(_ claim: PendingRetryClaim) async {
        guard leases[claim.id] == claim.token else { return }
        leases[claim.id] = nil
    }

    @discardableResult
    func clear(_ claim: PendingRetryClaim) async -> Bool {
        guard leases[claim.id] == claim.token else { return false }
        leases[claim.id] = nil
        clears.append(claim.id)
        return true
    }

    /// Runs at the retirement, which is the first thing the recorder does once
    /// the queue has TAKEN the picture. It is the only place a case can stand
    /// between acceptance and the answer.
    private var onDiscard: (@MainActor @Sendable () -> Void)?

    func cancelOnDiscard(_ hook: @escaping @MainActor @Sendable () -> Void) {
        onDiscard = hook
    }

    @discardableResult
    func discardWorkImage(_ claim: PendingRetryClaim) async -> Bool {
        guard leases[claim.id] == claim.token else { return false }
        discards.append(claim.id)
        if let onDiscard { await onDiscard() }
        // Mirrored, not merely counted: the real store deletes the file, so an
        // entry read back afterwards must no longer offer the picture either.
        for index in saves.indices where saves[index].metadata.id == claim.id {
            saves[index].workImageData = nil
        }
        return true
    }
}
