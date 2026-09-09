// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardInAppVoiceLaneTests.swift
//
// The ORDER the in-app Work lane runs in, and the three claims that order
// exists for. `InAppAudioRecorder(retryDestination: .work)` drives the desk's
// voice sheet and the Mac menu bar, and nothing it captures reaches the desk as
// audio: the recording is parked in the device-local retry queue before the
// speech hop and deleted once the words are a card.
//
// PARK BEFORE THE HOP. The bytes leave the file system at the stop, so between
// there and the queue they exist in one process's memory. A park that FAILS is
// not durable, and the capture has to say so — transcribing on and handing the
// words to a composer reports a capture complete whose recording nothing holds.
//
// THE AUDIO GOES ONLY AFTER THE WORDS ARRIVE. Clearing the entry is what
// deletes the recording, so it may not happen a moment before the desk holds
// the card that replaces it. The one capture that cannot clear — a picture
// still owed, whose parked bytes are the only copy of it — retires the
// recording alone and keeps the entry.
//
// The recorder is driven through its own seams rather than through a
// microphone: `WorkboardAudioCaptureTests` documents why they exist.

import XCTest
@testable import Conduck

final class WorkboardInAppVoiceLaneTests: XCTestCase {

    private var inboxRoot: URL!
    private var queueRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        inboxRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-inapp-lane-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
        queueRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-inapp-queue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: queueRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let inboxRoot { try? FileManager.default.removeItem(at: inboxRoot) }
        if let queueRoot { try? FileManager.default.removeItem(at: queueRoot) }
        inboxRoot = nil
        queueRoot = nil
        try super.tearDownWithError()
    }

    // MARK: - The recording outlives nothing, and predeceases nothing

    /// The clear is the DELETION, so it is measured against the desk at the
    /// instant it happens.
    ///
    /// Clearing the entry deletes the parked recording, and until the words are
    /// a card that entry holds the only copy of what somebody said. A clear
    /// taken a step early — on the words being recognized, on the hop returning,
    /// on the capture being "done" — is a recording destroyed for a publication
    /// that had not happened yet and might still fail.
    @MainActor
    func testTheParkedRecordingIsClearedOnlyOnceTheWordsCardStands() async throws {
        let store = ConversationStore(inMemory: true)
        let lane = ObservingRetryLane()
        let recorder = Self.workRecorder(store: store, lane: lane, inboxRoot: inboxRoot)

        var clearedWithNothingOnTheDesk = false
        var kindsAtTheClear: [WorkMaterialKind] = []
        await lane.observeClear { @MainActor in
            let desk = try? await store.fetchWorkItem(id: Constants.workboardDeskItemID)
            kindsAtTheClear = desk?.materials.map(\.kind) ?? []
            clearedWithNothingOnTheDesk = kindsAtTheClear.isEmpty
        }
        var clearsAtTheHop: [UUID] = []
        recorder.transcriptionHopForTesting = { _ in
            clearsAtTheHop = await lane.clears
            return .success("the ferry leaves at seven")
        }

        let result = await recorder._finishCaptureForTesting()

        XCTAssertEqual(try result.get(), "the ferry leaves at seven")
        XCTAssertEqual(
            clearsAtTheHop, [],
            """
            MEASURED: the entry was cleared before the words were even bought. The clear deletes \
            the parked recording, and at this instant it is the only copy of what was said.
            """
        )
        let cleared = await lane.clears
        XCTAssertEqual(cleared.count, 1, "the capture finished, so its entry is retired exactly once")
        XCTAssertEqual(
            kindsAtTheClear, [.transcript],
            """
            MEASURED: the recording was deleted with the desk holding \(kindsAtTheClear). The \
            words card is what replaces those bytes, so it has to be standing before they go.
            """
        )
        XCTAssertFalse(
            clearedWithNothingOnTheDesk,
            "…and above all it must not be deleted against an empty desk"
        )
        let parked = await lane.parkHistory
        XCTAssertEqual(
            parked.first?.audio, Self.recordingBytes,
            "control: the park really did carry the bytes, or the clear deletes nothing"
        )
        XCTAssertEqual(
            parked.first?.metadata.publicationState, .phaseOneFailed,
            "…and it says the desk holds nothing yet, which is what exempts it from the clock"
        )
        let stillQueued = await lane.saves
        XCTAssertTrue(stillQueued.isEmpty, "and the entry is gone with the bytes it sheltered")
    }

    // MARK: - A park that fails is not durable

    /// The queue refuses the bytes. Nothing else holds them — this lane
    /// publishes no recording — so the capture may not go on to spend a
    /// provider round trip and report success over a recording that exists in
    /// one process's memory and nowhere else.
    @MainActor
    func testAParkTheQueueRefusesStopsTheCaptureAndKeepsTheBytesInHand() async throws {
        let store = ConversationStore(inMemory: true)
        let lane = RefusingParkLane()
        let recorder = Self.workRecorder(store: store, lane: lane, inboxRoot: inboxRoot)
        var hops = 0
        recorder.transcriptionHopForTesting = { _ in
            hops += 1
            return .success("never reached")
        }

        let result = await recorder._finishCaptureForTesting()

        guard case .failure(let surfaced) = result else {
            return XCTFail("a capture nothing durable would take must not report success")
        }
        XCTAssertEqual(
            surfaced.errorCode, AppError.workDeskWriteFailed.errorCode,
            "the retryable desk error, which is what puts Try Again on the surface"
        )
        XCTAssertTrue(surfaced.isRetryable, "the same bytes, parked again, normally land")
        XCTAssertEqual(
            hops, 0,
            """
            MEASURED: the capture went to the provider with its recording held nowhere. The park \
            is what makes the speech hop survivable — a kill during it costs the words and not \
            the recording — so a refused park ends the capture instead of starting one.
            """
        )
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertTrue(
            deskValue?.materials.isEmpty ?? true,
            "and nothing was published, because there is nothing to publish until there are words"
        )
        XCTAssertTrue(recorder.canRetryWorkCapture, "the capture is retryable")
        XCTAssertEqual(
            recorder.pendingWorkCapture?.audio, Self.recordingBytes,
            """
            MEASURED: the bytes were dropped with the failure. They are in this recorder and \
            nowhere else, so the capture in hand IS the recording until something takes it.
            """
        )
    }

    // MARK: - A picture still owed keeps the entry, never the audio

    /// The one capture whose entry cannot be cleared when its words land: the
    /// picture parked in it is the only copy of itself. The RECORDING goes on
    /// its own, and what is left is claimable — with no bytes and the words
    /// already on the record — so the picture can still be published and the
    /// entry finished.
    @MainActor
    func testACaptureStillOwingItsPictureRetiresTheRecordingAndStaysFinishable() async throws {
        let store = ConversationStore(inMemory: true)
        let queue = PendingRetryStore(
            containerURL: queueRoot, defaults: InMemoryDefaultsStore()
        )
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.workInboxForTesting = try Self.refusingInbox(under: inboxRoot)
        recorder.retryLaneForTesting = queue
        recorder.capturedAudioForTesting = Self.recordingBytes
        recorder.workScreenshotNormalizeForTesting = { _ in Self.jpegBytes }
        recorder.transcriptionHopForTesting = { _ in .success("the ferry leaves at seven") }

        recorder.stageWorkScreenshot(Self.rawScreenshot)
        let result = await recorder._finishCaptureForTesting()

        guard case .failure(let surfaced) = result else {
            return XCTFail("a capture still owing its picture is not finished")
        }
        XCTAssertEqual(surfaced.errorCode, AppError.workScreenshotWriteFailed.errorCode)
        let captureID = try XCTUnwrap(recorder.workRecordingMaterialID, "the words landed")

        let audioFile = queueRoot.appendingPathComponent(
            PendingRetryFiles.audio(captureID, .work)
        )
        // The FILE may stand — the re-park that records the picture's own
        // failure writes one — but nothing of the recording may be in it.
        let survivingAudio = (try? Data(contentsOf: audioFile)) ?? Data()
        XCTAssertEqual(
            survivingAudio, Data(),
            """
            MEASURED: \(survivingAudio.count) bytes of the recording are still on the device \
            after its words became a card. The entry has to stay — the picture in it is the only \
            copy of itself — so the audio is retired on its own and never written back, or it \
            outlives the words for as long as that picture is owed.
            """
        )
        let picture = try? Data(
            contentsOf: queueRoot.appendingPathComponent(PendingRetryFiles.workImage(captureID))
        )
        XCTAssertEqual(picture, Self.rawScreenshot, "…and the picture it is sheltering is untouched")

        // What is left is a debt a surface can still settle: no bytes to
        // transcribe, the words already parked, and the picture to publish.
        let offered = await queue.claimNext(surface: .work)
        let claim = try XCTUnwrap(
            offered,
            "an entry no surface can take is a picture stranded on the device for ever"
        )
        XCTAssertEqual(claim.id, captureID)
        XCTAssertEqual(claim.entry.audioData, Data(), "there is nothing left to transcribe")
        XCTAssertEqual(
            claim.entry.metadata.transcript, "the ferry leaves at seven",
            """
            …and the words ride with it, so the surface that finishes this entry publishes the \
            picture and finds the card already standing rather than paying a provider again.
            """
        )
        XCTAssertEqual(claim.entry.metadata.publicationState, .published)
        XCTAssertEqual(claim.entry.workImageData, Self.rawScreenshot)
    }

    // MARK: - Fixtures

    /// Stands in for a compressed 16 kHz mono AAC voice note: small, so the
    /// storage policy picks the synced lane exactly as it does in the app, and
    /// not decodable as audio, so `AudioCompressor` returns it untouched.
    private static let recordingBytes = Data(repeating: 0x7F, count: 4_096)
    private static let rawScreenshot = Data(repeating: 0x2B, count: 2_048)
    private static let jpegBytes = Data(repeating: 0x5C, count: 1_024)

    @MainActor
    private static func workRecorder(
        store: ConversationStore,
        lane: any PendingRetryLaneReserving,
        inboxRoot: URL
    ) -> InAppAudioRecorder {
        let recorder = InAppAudioRecorder(retryDestination: .work)
        recorder.workStoreForTesting = store
        recorder.retryLaneForTesting = lane
        recorder.workInboxForTesting = WorkCaptureInbox(
            baseURL: inboxRoot.appendingPathComponent("queue-\(UUID().uuidString)", isDirectory: true)
        )
        recorder.capturedAudioForTesting = recordingBytes
        recorder.speechAuthorizationForTesting = .authorized
        return recorder
    }

    /// An inbox whose directory is a FILE, so every envelope write fails and
    /// the picture is refused without the recording being touched.
    private static func refusingInbox(under root: URL) throws -> WorkCaptureInbox {
        let blocked = root.appendingPathComponent("blocked-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: blocked)
        return WorkCaptureInbox(baseURL: blocked)
    }
}

/// A queue that takes what it is given and says exactly when it was asked to
/// let go — the observation the desk read at the clear needs, and the one no
/// assertion after the fact can make.
private actor ObservingRetryLane: PendingRetryLaneReserving {
    private(set) var saves: [(metadata: PendingRetryMetadata, audio: Data)] = []

    /// Every park this lane was ever asked for, kept after the entry is gone —
    /// "what the queue was holding when it let go" is a question only a record
    /// that outlives the clear can answer.
    private(set) var parkHistory: [(metadata: PendingRetryMetadata, audio: Data)] = []
    private(set) var clears: [UUID] = []
    private(set) var retired: [UUID] = []
    private var leases: [UUID: UUID] = [:]
    private var onClear: (@MainActor @Sendable () async -> Void)?

    /// Runs INSIDE the clear, before the entry is retired: the one moment a
    /// case can read the desk as the recording is being deleted.
    func observeClear(_ hook: @escaping @MainActor @Sendable () async -> Void) {
        onClear = hook
    }

    func save(audioData: Data, metadata: PendingRetryMetadata, workImageData: Data?) async throws {
        saves.removeAll { $0.metadata.id == metadata.id }
        saves.append((metadata, audioData))
        parkHistory.append((metadata, audioData))
    }

    func claim(id: UUID, duration: TimeInterval) async -> PendingRetryClaim? {
        guard let parked = saves.last(where: { $0.metadata.id == id }) else { return nil }
        let token = UUID()
        leases[id] = token
        return PendingRetryClaim(
            entry: PendingRetryEntry(
                audioData: parked.audio, metadata: parked.metadata, workImageData: nil
            ),
            token: token
        )
    }

    @discardableResult
    func renew(_ claim: PendingRetryClaim) async -> Bool { leases[claim.id] == claim.token }

    func confirmOwnership(_ claim: PendingRetryClaim) async -> Bool {
        guard saves.contains(where: { $0.metadata.id == claim.id }) else { return false }
        return leases[claim.id] == claim.token
    }

    func release(_ claim: PendingRetryClaim) async {
        guard leases[claim.id] == claim.token else { return }
        leases[claim.id] = nil
    }

    @discardableResult
    func clear(_ claim: PendingRetryClaim) async -> Bool {
        guard leases[claim.id] == claim.token else { return false }
        guard saves.contains(where: { $0.metadata.id == claim.id }) else { return false }
        if let onClear { await onClear() }
        saves.removeAll { $0.metadata.id == claim.id }
        leases[claim.id] = nil
        clears.append(claim.id)
        return true
    }

    @discardableResult
    func recordPublicationState(
        _ claim: PendingRetryClaim,
        transcript: String?,
        publicationState: PendingRetryPublicationState
    ) async -> Bool {
        guard leases[claim.id] == claim.token else { return false }
        guard let index = saves.firstIndex(where: { $0.metadata.id == claim.id }) else {
            return false
        }
        saves[index].metadata = saves[index].metadata.recording(
            transcript: transcript, publicationState: publicationState
        )
        return true
    }

    @discardableResult
    func retireRecording(_ claim: PendingRetryClaim) async -> Bool {
        guard leases[claim.id] == claim.token else { return false }
        guard let index = saves.firstIndex(where: { $0.metadata.id == claim.id }) else {
            return false
        }
        saves[index].audio = Data()
        retired.append(claim.id)
        return true
    }
}

/// A queue that takes nothing, for the one state this lane has no other shelter
/// for: the bytes are in a recorder's memory and nowhere else.
private actor RefusingParkLane: PendingRetryLaneReserving {
    func save(audioData: Data, metadata: PendingRetryMetadata, workImageData: Data?) async throws {
        throw AppError.settingsLoadFailed
    }
    func claim(id: UUID, duration: TimeInterval) async -> PendingRetryClaim? { nil }
    func reserve(id: UUID, duration: TimeInterval) async -> PendingRetryReservation { .absent }
    @discardableResult func renew(_ claim: PendingRetryClaim) async -> Bool { false }
    func confirmOwnership(_ claim: PendingRetryClaim) async -> Bool { false }
    func release(_ claim: PendingRetryClaim) async {}
    @discardableResult func clear(_ claim: PendingRetryClaim) async -> Bool { false }
}
