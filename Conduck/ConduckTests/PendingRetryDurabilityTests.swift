// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// PendingRetryDurabilityTests.swift
//
// The DURABLE half of the pending-retry queue: the two write orders, the
// reconciliation that reads the residue of an interrupted one, and the
// reservation that stops two retry surfaces finishing the same capture.
//
// `PendingRetryQueueTests` drives the queue's pure rules and deliberately
// touches no file. Everything here needs the opposite — a real directory, a
// real defaults domain and the actor's own cross-process lock — because the
// defects these cases pin are all about what is left on disk when a process
// dies between two writes that cannot be one.
//
// Each case runs against an ISOLATED store: its own temporary directory and its
// own in-memory defaults, through the `CONDUCK_TESTING` initializer. The
// production singleton writes the process-global App-Group container every
// other capture test in this bundle shares, so driving it here would assert
// against — and corrupt — its neighbours' state.

import XCTest
@testable import Conduck

final class PendingRetryDurabilityTests: XCTestCase {

    private var container: URL!
    private var defaults: InMemoryDefaultsStore!
    private var store: PendingRetryStore!

    override func setUp() {
        super.setUp()
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-retry-\(UUID().uuidString)", isDirectory: true)
        defaults = InMemoryDefaultsStore()
        store = PendingRetryStore(containerURL: container, defaults: defaults)
    }

    override func tearDown() {
        if let container { try? FileManager.default.removeItem(at: container) }
        store = nil
        defaults = nil
        container = nil
        super.tearDown()
    }

    // MARK: - An interrupted ARM keeps the whole record

    /// The defect: a recording landed before the index row, so a process death
    /// in between left an entry the reader could only rebuild from the
    /// FILENAME — id and destination and nothing else. A refused Work
    /// publication came back with no verdict, no words and no language, which
    /// is the state a recovery cannot act on: nil publication state means
    /// UNKNOWN, so it republishes nothing and re-buys the transcript it was
    /// already given.
    func testAnArmInterruptedBeforeTheIndexCommitsKeepsEveryFieldOfItsRecord() async throws {
        let armed = Self.metadata(
            destination: .work,
            preferredLanguage: "et",
            attemptCount: 3,
            lastErrorCode: AppError.workDeskWriteFailed.errorCode,
            transcript: "the ferry leaves at seven",
            publicationState: .phaseOneFailed
        )
        try await store.save(
            audioData: Data("the recording".utf8),
            metadata: armed,
            workImageData: nil
        )

        // The process died between the bytes and the index row.
        defaults.removeObject(forKey: PendingRetryDefaultsKeys.queue)

        let adopted = await store.claimNext()
        let claim = try XCTUnwrap(adopted, "the arm is adopted, not lost")
        XCTAssertEqual(claim.entry.metadata.id, armed.id)
        XCTAssertEqual(claim.entry.audioData, Data("the recording".utf8))
        XCTAssertEqual(
            claim.entry.metadata.publicationState, .phaseOneFailed,
            """
            The verdict is the field a recovery branches on: without it the \
            desk never gets the recording back, because nil means UNKNOWN and \
            a recovery must not republish on an unknown.
            """
        )
        XCTAssertEqual(claim.entry.metadata.transcript, "the ferry leaves at seven")
        XCTAssertEqual(claim.entry.metadata.preferredLanguage, "et")
        XCTAssertEqual(claim.entry.metadata.attemptCount, 3)
        XCTAssertEqual(
            claim.entry.metadata.lastErrorCode, AppError.workDeskWriteFailed.errorCode
        )
    }

    /// A record with no recording beside it is an arm that never landed its
    /// bytes. There is nothing to protect and no retry that could succeed.
    func testAnArmWhoseBytesNeverLandedLeavesNoWaitingCapture() async throws {
        let armed = Self.metadata(destination: .work, publicationState: .phaseOneFailed)
        try await store.save(audioData: Data("bytes".utf8), metadata: armed, workImageData: nil)
        defaults.removeObject(forKey: PendingRetryDefaultsKeys.queue)
        try FileManager.default.removeItem(at: audioURL(armed.id, .work))

        let count = await store.pendingCount()

        XCTAssertEqual(count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarURL(armed.id).path))
    }

    // MARK: - An interrupted CLEAR stays cleared

    /// The other half of the same defect, and the one that made it
    /// unresolvable: an interrupted clear left the IDENTICAL residue as an
    /// interrupted arm — a recording the index does not name — so adoption
    /// resurrected a capture the person had already finished, and its
    /// notification and its retry card came back with it.
    func testAClearInterruptedBeforeTheFilesGoDoesNotBringTheCaptureBack() async throws {
        let armed = Self.metadata(destination: .work, publicationState: .phaseOneFailed)
        try await store.save(audioData: Data("finished".utf8), metadata: armed, workImageData: nil)

        // The process died after the tombstone and the index row, before the
        // payloads: exactly the state `clear` passes through.
        try Data(armed.id.uuidString.utf8).write(to: tombstoneURL(armed.id))
        persistIndex([])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL(armed.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL(armed.id, .work).path))

        let count = await store.pendingCount()
        let claim = await store.claimNext()

        XCTAssertEqual(count, 0, "a finished capture does not come back")
        XCTAssertNil(claim)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarURL(armed.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL(armed.id, .work).path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tombstoneURL(armed.id).path),
            "the tombstone is the last file to go, and it goes"
        )
    }

    /// The steady state of the current layout: a recording with neither a
    /// record nor an index row is residue a clear did not finish deleting, and
    /// it is reclaimed rather than offered.
    func testARecordingLeftBehindByAFinishedCaptureIsNotResurrected() async throws {
        // Bring the container up to the current layout first, so the one-time
        // adoption of the previous one is behind us.
        _ = await store.pendingCount()

        let stray = UUID()
        try Data("residue".utf8).write(to: audioURL(stray, .work))

        let count = await store.pendingCount()

        XCTAssertEqual(count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL(stray, .work).path))
    }

    // MARK: - The pre-id-scoped recording belongs to one capture

    /// The defect: the fixed-name recording carries no id, so every Chat
    /// capture resolved to it and every Chat capture's completion deleted it.
    /// Finishing a capture armed today took a recording parked by a build that
    /// predates ids.
    func testTheLegacyRecordingSurvivesAChatCaptureFinishingBesideIt() async throws {
        let parked = Self.metadata(at: Date().addingTimeInterval(-60), destination: .chat)
        try Data("what was said before the upgrade".utf8).write(to: legacyAudioURL())
        defaults.set(try JSONEncoder().encode(parked), forKey: PendingRetryDefaultsKeys.legacySlot)

        let newer = Self.metadata(destination: .chat)
        try await store.save(audioData: Data("newer".utf8), metadata: newer, workImageData: nil)

        let waiting = await store.pendingCount()
        XCTAssertEqual(waiting, 2, "the parked capture is folded in beside the new one")

        let offered = await store.claimNext()
        let claim = try XCTUnwrap(offered)
        XCTAssertEqual(claim.id, newer.id, "newest first")
        let cleared = await store.clear(claim)
        XCTAssertTrue(cleared)

        let remaining = await store.claimNext()
        let survivor = try XCTUnwrap(
            remaining,
            "finishing one capture must not finish another"
        )
        XCTAssertEqual(survivor.id, parked.id)
        XCTAssertEqual(
            survivor.entry.audioData, Data("what was said before the upgrade".utf8),
            "its bytes were copied under its own id before anything could reach them"
        )
    }

    /// The fold retires both halves of the old shape once the queue carrying
    /// them is committed, and nothing reads the fixed name afterwards.
    func testTheFoldRetiresThePointerAndTheFixedNameOnceTheQueueCommits() async throws {
        let parked = Self.metadata(destination: .chat)
        try Data("parked".utf8).write(to: legacyAudioURL())
        defaults.set(try JSONEncoder().encode(parked), forKey: PendingRetryDefaultsKeys.legacySlot)

        let count = await store.pendingCount()

        XCTAssertEqual(count, 1)
        XCTAssertNil(defaults.data(forKey: PendingRetryDefaultsKeys.legacySlot))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyAudioURL().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL(parked.id, .chat).path))
    }

    /// An entry an earlier build folded in without moving the bytes points at
    /// the fixed name and owns nothing. Its recording is claimed for it once,
    /// on the first read of the new layout.
    func testACaptureFoldedInWithoutItsBytesGetsThemOnTheFirstReadOfTheNewLayout() async throws {
        let folded = Self.metadata(destination: .chat)
        persistIndex([folded])
        try Data("still at the fixed name".utf8).write(to: legacyAudioURL())

        let offered = await store.claimNext()
        let claim = try XCTUnwrap(offered)

        XCTAssertEqual(claim.id, folded.id)
        XCTAssertEqual(claim.entry.audioData, Data("still at the fixed name".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyAudioURL().path))
    }

    // MARK: - A claim reads one recording

    /// The defect: both retry surfaces read the whole queue to consume its
    /// first entry, so a queue of expiry-exempt Work captures materialised
    /// every one of their recordings — up to `Constants.maxAudioSize` each — to
    /// offer one.
    func testClaimingTheNextCaptureReadsExactlyOneRecording() async throws {
        for _ in 0..<3 {
            try await store.save(
                audioData: Data("recording".utf8),
                metadata: Self.metadata(destination: .work, publicationState: .phaseOneFailed),
                workImageData: nil
            )
        }

        await store.resetAudioReadsForTesting()
        _ = await store.claimNext()
        let claimReads = await store.audioReadsForTesting

        await store.resetAudioReadsForTesting()
        _ = await store.load()
        let loadReads = await store.audioReadsForTesting

        XCTAssertEqual(claimReads, 1, "one capture is offered, so one recording is read")
        XCTAssertEqual(
            loadReads, 3,
            """
            The measurement of what `claimNext` replaces: the superseded read \
            materialises every queued recording to hand back the first one.
            """
        )
    }

    func testCountingWhatIsWaitingReadsNoRecordingAtAll() async throws {
        for _ in 0..<3 {
            try await store.save(
                audioData: Data("recording".utf8),
                metadata: Self.metadata(destination: .work, publicationState: .phaseOneFailed),
                workImageData: nil
            )
        }

        await store.resetAudioReadsForTesting()
        let count = await store.pendingCount()
        let reads = await store.audioReadsForTesting

        XCTAssertEqual(count, 3)
        XCTAssertEqual(reads, 0, "a count is a question about records, not about bytes")
    }

    // MARK: - A capture is held by one surface at a time

    /// The defect: the menu bar and the desk's voice sheet both read the queue
    /// and both took its first entry, so one capture was transcribed twice and
    /// finished twice — the second completion clearing an entry the first had
    /// already replaced.
    func testACaptureAnotherSurfaceIsHoldingIsNotOfferedAgain() async throws {
        let armed = Self.metadata(destination: .work, publicationState: .phaseOneFailed)
        try await store.save(audioData: Data("one copy".utf8), metadata: armed, workImageData: nil)

        let offered = await store.claimNext()
        let first = try XCTUnwrap(offered)
        let second = await store.claimNext()

        XCTAssertEqual(first.id, armed.id)
        XCTAssertNil(second, "the other surface is offered nothing while this one holds it")
    }

    /// A reservation is a horizon, not a lock: a process killed while holding
    /// one must give the capture back rather than strand it until reinstall.
    func testAReservationNobodyFinishedIsOfferedAgainOnceItLapses() async throws {
        let armed = Self.metadata(destination: .work, publicationState: .phaseOneFailed)
        try await store.save(audioData: Data("one copy".utf8), metadata: armed, workImageData: nil)
        let offered = await store.claimNext()
        let first = try XCTUnwrap(offered)
        let whileHeld = await store.claimNext()
        XCTAssertNil(whileHeld)

        try lapseReservation(for: armed.id)

        let reoffered = await store.claimNext()
        let second = try XCTUnwrap(reoffered)
        XCTAssertEqual(second.id, armed.id)
        XCTAssertNotEqual(
            second.token, first.token,
            "whoever takes it over holds it under their own reservation"
        )
    }

    func testReleasingACaptureOffersItAgainAndFinishesNothing() async throws {
        let armed = Self.metadata(destination: .work, publicationState: .phaseOneFailed)
        try await store.save(audioData: Data("one copy".utf8), metadata: armed, workImageData: nil)
        let offered = await store.claimNext()
        let first = try XCTUnwrap(offered)

        await store.release(first)

        let reoffered = await store.claimNext()
        let second = try XCTUnwrap(reoffered)
        XCTAssertEqual(second.id, armed.id)
        XCTAssertNotEqual(second.token, first.token)
        let waiting = await store.pendingCount()
        XCTAssertEqual(waiting, 1, "a release gives a capture back; it does not finish it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL(armed.id, .work).path))
    }

    /// The reason every operation takes the claim rather than a bare id: a
    /// holder that was overtaken must not be able to finish, or restate, a
    /// capture somebody else is now working on.
    func testAStaleReservationNeitherRecordsAVerdictNorFinishesTheCapture() async throws {
        let armed = Self.metadata(
            destination: .work, attemptCount: 1, publicationState: .phaseOneFailed
        )
        try await store.save(audioData: Data("one copy".utf8), metadata: armed, workImageData: nil)
        let offered = await store.claimNext()
        let overtaken = try XCTUnwrap(offered)
        await store.release(overtaken)
        let reoffered = await store.claimNext()
        let holder = try XCTUnwrap(reoffered)
        XCTAssertNotEqual(holder.token, overtaken.token)

        let recorded = await store.recordPublicationState(
            overtaken, transcript: "not this holder's words", publicationState: .published
        )
        let attempted = await store.updateAttempt(overtaken, lastErrorCode: 99)
        let cleared = await store.clear(overtaken)

        XCTAssertFalse(recorded)
        XCTAssertFalse(attempted)
        XCTAssertFalse(cleared)

        let waiting = await store.pendingCount()
        XCTAssertEqual(waiting, 1, "nothing was finished")
        let queued = await store.load()
        let still = try XCTUnwrap(queued.first)
        XCTAssertNil(still.metadata.transcript, "and nothing was written")
        XCTAssertEqual(still.metadata.attemptCount, 1)
        XCTAssertEqual(still.metadata.publicationState, .phaseOneFailed)
    }

    func testTheHolderRecordsItsVerdictAndFinishesItsOwnCapture() async throws {
        let armed = Self.metadata(destination: .work, publicationState: .phaseOneFailed)
        try await store.save(audioData: Data("one copy".utf8), metadata: armed, workImageData: nil)
        let offered = await store.claimNext()
        let holder = try XCTUnwrap(offered)

        let recorded = await store.recordPublicationState(
            holder, transcript: nil, publicationState: .published
        )
        XCTAssertTrue(recorded)
        let queued = await store.load()
        let restated = try XCTUnwrap(queued.first)
        XCTAssertEqual(restated.metadata.publicationState, .published)
        XCTAssertEqual(
            restated.metadata.transcript, nil,
            "a nil field keeps what the record already carried"
        )

        let cleared = await store.clear(holder)
        XCTAssertTrue(cleared)
        let waiting = await store.pendingCount()
        XCTAssertEqual(waiting, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL(armed.id, .work).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarURL(armed.id).path))
    }

    /// Two waiting captures are drained one at a time, and the second is never
    /// the one already being finished.
    func testTwoWaitingCapturesAreOfferedOneAtATimeAndNeverTheSameOne() async throws {
        let older = Self.metadata(
            at: Date().addingTimeInterval(-30), destination: .work,
            publicationState: .phaseOneFailed
        )
        let newer = Self.metadata(destination: .work, publicationState: .phaseOneFailed)
        try await store.save(audioData: Data("older".utf8), metadata: older, workImageData: nil)
        try await store.save(audioData: Data("newer".utf8), metadata: newer, workImageData: nil)

        let offered = await store.claimNext()
        let first = try XCTUnwrap(offered)
        let reoffered = await store.claimNext()
        let second = try XCTUnwrap(reoffered)

        XCTAssertEqual(first.id, newer.id)
        XCTAssertEqual(second.id, older.id)
        XCTAssertEqual(first.entry.audioData, Data("newer".utf8))
        XCTAssertEqual(second.entry.audioData, Data("older".utf8))
    }

    /// A surface can only be handed a capture it is able to finish: a Work
    /// recording belongs on the desk and a Chat recording in a conversation.
    func testASurfaceIsOfferedOnlyTheCapturesItCanFinish() async throws {
        let chat = Self.metadata(destination: .chat)
        let work = Self.metadata(
            at: Date().addingTimeInterval(-30), destination: .work,
            publicationState: .phaseOneFailed
        )
        try await store.save(audioData: Data("chat".utf8), metadata: chat, workImageData: nil)
        try await store.save(audioData: Data("work".utf8), metadata: work, workImageData: nil)

        let offered = await store.claimNext(surface: .work)
        let claimed = try XCTUnwrap(offered)

        XCTAssertEqual(claimed.id, work.id, "the newer Chat capture is not this surface's to finish")
    }

    // MARK: - Arming displaces nothing, through the real files

    func testASecondArmLeavesTheFirstRecordingExactlyWhereItIs() async throws {
        let first = Self.metadata(
            at: Date().addingTimeInterval(-30), destination: .work,
            publicationState: .phaseOneFailed
        )
        let second = Self.metadata(destination: .chat)
        try await store.save(audioData: Data("the first".utf8), metadata: first, workImageData: nil)

        try await store.save(audioData: Data("the second".utf8), metadata: second, workImageData: nil)

        XCTAssertEqual(
            try Data(contentsOf: audioURL(first.id, .work)), Data("the first".utf8),
            "an arming save deletes no other capture's bytes"
        )
        let waiting = await store.pendingCount()
        XCTAssertEqual(waiting, 2)
    }

    // MARK: - The container the previous layout wrote

    /// A device upgrading into this layout has index rows and recordings and no
    /// records at all. Nothing of it is deleted, and every entry gains the
    /// record the new reconciliation needs.
    func testAContainerWrittenByThePreviousLayoutKeepsEveryRecording() async throws {
        let parked = Self.metadata(
            destination: .work,
            transcript: "already recognised",
            publicationState: .phaseOneFailed
        )
        persistIndex([parked])
        try Data("previous layout".utf8).write(to: audioURL(parked.id, .work))

        let offered = await store.claimNext()
        let claim = try XCTUnwrap(offered)

        XCTAssertEqual(claim.id, parked.id)
        XCTAssertEqual(claim.entry.audioData, Data("previous layout".utf8))
        XCTAssertEqual(claim.entry.metadata.transcript, "already recognised")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sidecarURL(parked.id).path),
            "the record is backfilled, so the NEXT crash is describable"
        )
    }

    /// An arm the previous layout could not describe — bytes with no index row,
    /// because it committed the row last and wrote no record — is adopted once
    /// rather than reclaimed.
    func testARecordingThePreviousLayoutCouldNotDescribeIsAdoptedOnce() async throws {
        let stranded = UUID()
        try Data("stranded".utf8).write(to: audioURL(stranded, .work))

        let offered = await store.claimNext()
        let claim = try XCTUnwrap(offered)

        XCTAssertEqual(claim.id, stranded)
        XCTAssertEqual(claim.entry.audioData, Data("stranded".utf8))
        XCTAssertEqual(claim.entry.metadata.resolvedDestination, .work, "the filename says so")
    }

    // MARK: - The record outranks its index row

    /// The defect: a restatement writes the record and then the index row, and
    /// the reconciliation read a record only for a capture the index did not
    /// name. So a process that died between the two writes left the OLD row in
    /// charge for ever — a Work capture whose recording had just reached the
    /// desk came back saying `.phaseOneFailed`, which is a licence to republish
    /// a card that already exists, and its words were thrown away with it.
    func testARecordRestatedBeforeTheCrashOutranksItsStaleIndexRow() async throws {
        let armed = Self.metadata(destination: .work, publicationState: .phaseOneFailed)
        try await store.save(
            audioData: Data("the recording".utf8), metadata: armed, workImageData: nil
        )
        let offered = await store.claimNext()
        let holder = try XCTUnwrap(offered)
        let recorded = await store.recordPublicationState(
            holder, transcript: "the ferry leaves at seven", publicationState: .published
        )
        XCTAssertTrue(recorded)

        // The process died between the two writes the restatement makes: the
        // record landed, the index row did not.
        persistIndex([armed])

        let queued = await store.load()
        let entry = try XCTUnwrap(queued.first)

        XCTAssertEqual(
            entry.metadata.publicationState, .published,
            "the record is the newer half of a write that could not be one"
        )
        XCTAssertEqual(entry.metadata.transcript, "the ferry leaves at seven")
        let index = try XCTUnwrap(defaults.data(forKey: PendingRetryDefaultsKeys.queue))
        let rows = try JSONDecoder().decode([PendingRetryMetadata].self, from: index)
        XCTAssertEqual(
            rows.first?.publicationState, .published,
            "and the stale row is repaired, not merely overridden for this read"
        )
    }

    /// The other half: a record that cannot be READ is evidence of nothing. It
    /// used to be replaced by a reconstruction from the filename — no verdict,
    /// no words, no language, attempt count 1 — and because a capture the index
    /// names is never re-read from its record, that lossy row then blocked the
    /// real one for ever, even once the file became readable.
    func testAnUnreadableRecordDefersItsCaptureRatherThanRebuildingItBadly() async throws {
        let armed = Self.metadata(
            destination: .work,
            preferredLanguage: "et",
            attemptCount: 3,
            transcript: "the ferry leaves at seven",
            publicationState: .phaseOneFailed
        )
        try await store.save(
            audioData: Data("the recording".utf8), metadata: armed, workImageData: nil
        )
        let record = try Data(contentsOf: sidecarURL(armed.id))

        // The arm never committed its index row, and its record cannot be read
        // — the file is protected until first unlock, or a write was truncated.
        defaults.removeObject(forKey: PendingRetryDefaultsKeys.queue)
        try Data("not a record".utf8).write(to: sidecarURL(armed.id), options: [.atomic])

        let deferredCount = await store.pendingCount()
        let deferredClaim = await store.claimNext()

        XCTAssertEqual(deferredCount, 0, "a capture nothing can describe is not offered")
        XCTAssertNil(deferredClaim)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: audioURL(armed.id, .work).path),
            "and its recording is kept — deferring costs nothing, guessing costs the recording"
        )
        XCTAssertNil(
            defaults.data(forKey: PendingRetryDefaultsKeys.queue),
            "nothing lossy is written in its place"
        )

        // Once the record can be read, the capture comes back whole.
        try record.write(to: sidecarURL(armed.id), options: [.atomic])
        let reoffered = await store.claimNext()
        let claim = try XCTUnwrap(reoffered)

        XCTAssertEqual(claim.entry.metadata.publicationState, .phaseOneFailed)
        XCTAssertEqual(claim.entry.metadata.transcript, "the ferry leaves at seven")
        XCTAssertEqual(claim.entry.metadata.preferredLanguage, "et")
        XCTAssertEqual(claim.entry.metadata.attemptCount, 3)
    }

    // MARK: - The fold retires the old recording however it was interrupted

    /// The defect: the fold copied the fixed-name recording under an id,
    /// committed the queue, then retired the pointer and the file. A death
    /// between the commit and those two left the capture already queued, so the
    /// next read skipped the recognition entirely, retired the pointer — the
    /// last thing that could name the file — and left the recording in the
    /// container for ever.
    func testACrashBetweenTheQueueAndTheFixedNameStillRetiresTheOldRecording() async throws {
        let parked = Self.metadata(destination: .chat)
        try Data("parked".utf8).write(to: legacyAudioURL())
        try Data("parked".utf8).write(to: audioURL(parked.id, .chat))
        persistIndex([parked])
        defaults.set(
            try JSONEncoder().encode(parked), forKey: PendingRetryDefaultsKeys.legacySlot
        )

        let count = await store.pendingCount()

        XCTAssertEqual(count, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacyAudioURL().path),
            "the fixed name goes even though the capture was already queued"
        )
        XCTAssertNil(defaults.data(forKey: PendingRetryDefaultsKeys.legacySlot))
        XCTAssertEqual(
            try Data(contentsOf: audioURL(parked.id, .chat)), Data("parked".utf8),
            "and the copy under its own id is what survives"
        )
    }

    /// The window on the other side of the same fold, which a build before this
    /// ordering could leave: the pointer was retired BEFORE the file, so nothing
    /// names the recording any more. It is reclaimed only on proof — a queued
    /// capture's own recording is byte-for-byte this file — never on inference.
    func testACrashAfterThePointerWasRetiredStillReclaimsTheDuplicateRecording() async throws {
        let parked = Self.metadata(destination: .chat)
        try Data("parked".utf8).write(to: legacyAudioURL())
        try Data("parked".utf8).write(to: audioURL(parked.id, .chat))
        persistIndex([parked])

        let count = await store.pendingCount()

        XCTAssertEqual(count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyAudioURL().path))
        XCTAssertEqual(
            try Data(contentsOf: audioURL(parked.id, .chat)), Data("parked".utf8),
            "the bytes survive under the id; only the copy nothing can name goes"
        )
    }

    /// The control on that rule, and the reason it compares CONTENT: a
    /// fixed-name recording whose bytes no queued capture holds is a recording
    /// that may exist nowhere else, and it is left exactly where it is.
    func testAFixedNameRecordingNoQueuedCaptureDuplicatesIsLeftWhereItIs() async throws {
        let waiting = Self.metadata(destination: .work, publicationState: .phaseOneFailed)
        try Data("a work recording".utf8).write(to: audioURL(waiting.id, .work))
        persistIndex([waiting])
        try Data("something nobody else has".utf8).write(to: legacyAudioURL())

        let count = await store.pendingCount()

        XCTAssertEqual(count, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: legacyAudioURL().path),
            "nothing proves these bytes are preserved, so nothing may delete them"
        )
    }

    // MARK: - Reclamation

    func testTheLaunchSweepReclaimsOnlyWhatNoWaitingCaptureNames() async throws {
        let waiting = Self.metadata(destination: .work, publicationState: .phaseOneFailed)
        try await store.save(audioData: Data("waiting".utf8), metadata: waiting, workImageData: nil)
        let stray = UUID()
        try Data("stray".utf8).write(to: audioURL(stray, .chat))

        await store.cleanupExpired()

        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL(waiting.id, .work).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL(waiting.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL(stray, .chat).path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: container.appendingPathComponent(PendingRetryFiles.lockName).path
            ),
            "the sweep owns captures' files, not the lock every process serializes on"
        )
    }

    /// The explicit discard is the one operation allowed to reach the
    /// pre-id-scoped recording, because it is the one operation a person asked
    /// for.
    func testDiscardingEverythingLeavesNoRecordingBehind() async throws {
        let waiting = Self.metadata(destination: .work, publicationState: .phaseOneFailed)
        try await store.save(audioData: Data("waiting".utf8), metadata: waiting, workImageData: nil)
        try Data("pre-id".utf8).write(to: legacyAudioURL())

        await store.clear()

        let count = await store.pendingCount()
        XCTAssertEqual(count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL(waiting.id, .work).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarURL(waiting.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyAudioURL().path))
    }

    // MARK: - The picture a recording belongs to

    /// The link survives the whole durable round trip — sidecar, index row and
    /// the decode on the far side of a process death — and it survives the loss
    /// of the picture's BYTES, which is the state it exists for.
    ///
    /// `discardWorkImage` runs the moment the queue has taken the picture, and
    /// from then on the entry shelters no image at all. A recovery that
    /// reconstructed the association from the remaining bytes would find
    /// nothing exactly when the picture is safest.
    func testTheLinkOutlivesThePictureBytesItWasArmedBeside() async throws {
        let pictureID = UUID()
        let armed = Self.metadata(
            destination: .work,
            publicationState: .published,
            workAttachedToMaterialID: pictureID
        )
        try await store.save(
            audioData: Data("the recording".utf8),
            metadata: armed,
            workImageData: Data("the picture".utf8)
        )

        let firstClaim = await store.claimNext()
        let claimed = try XCTUnwrap(firstClaim, "the arm must be claimable")
        XCTAssertEqual(
            claimed.entry.metadata.workAttachedToMaterialID, pictureID,
            "the link is on the record the surface reads back"
        )
        XCTAssertNotNil(claimed.entry.workImageData, "the premise: bytes are still parked")

        let discarded = await store.discardWorkImage(claimed)
        XCTAssertTrue(discarded, "the retirement must actually run")
        await store.release(claimed)

        // …and again from disk, the way another process would see it.
        let reclaimed = await store.claimNext()
        let afterDiscard = try XCTUnwrap(reclaimed)
        XCTAssertNil(
            afterDiscard.entry.workImageData,
            "the premise: the parked picture is gone"
        )
        XCTAssertEqual(
            afterDiscard.entry.metadata.workAttachedToMaterialID, pictureID,
            """
            MEASURED: the link is stored independently of the bytes and is still there when \
            they are not. This is the only fact left in the entry that knows the recording \
            belongs to a picture.
            """
        )
    }

    /// The control: the same round trip with no picture at all. Nothing names
    /// anything, so the case above is about the link rather than about a value
    /// the decoder always produces.
    func testARecordArmedWithNoPictureCarriesNoLink() async throws {
        let armed = Self.metadata(destination: .work, publicationState: .published)
        try await store.save(
            audioData: Data("the recording".utf8), metadata: armed, workImageData: nil
        )

        let onlyClaim = await store.claimNext()
        let claimed = try XCTUnwrap(onlyClaim)
        XCTAssertNil(
            claimed.entry.metadata.workAttachedToMaterialID,
            "NEGATIVE CONTROL: no picture was taken, so the record names none"
        )
    }

    /// A record written before this field existed decodes to nil rather than
    /// failing to decode at all. The queue's index is JSON in a defaults
    /// domain, and a device updating into this build reads rows an older one
    /// wrote — a decode that threw would silently empty the whole queue.
    func testARecordEncodedWithoutTheLinkStillDecodesAndNamesNothing() async throws {
        let legacy: [String: Any] = [
            "id": UUID().uuidString,
            "createdAt": 0,
            "audioFileURL": "file:///dev/null",
            "attemptCount": 1,
            "destination": "work",
            "publicationState": "published"
        ]
        let bytes = try JSONSerialization.data(withJSONObject: [legacy])

        let decoded = try XCTUnwrap(
            try? JSONDecoder().decode([PendingRetryMetadata].self, from: bytes),
            """
            MEASURED: a nine-field record still decodes. A non-optional link would throw here, \
            and the queue reader answers a throw with an empty array — every parked recording \
            on the device would vanish on first launch.
            """
        )
        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded[0].workAttachedToMaterialID, "unknown, which is nil")
        XCTAssertEqual(
            decoded[0].publicationState, .published,
            "the control: the fields that WERE encoded are still read"
        )
    }

    /// The link is not picture debt. A published Work capture whose picture has
    /// already landed waits the day it has always waited and is then retired —
    /// the exemption reads the parked FILE, and a link is a fact about identity
    /// that shelters no bytes.
    func testALinkedRecordWithNoParkedPictureStillExpiresOnTheDayBudget() async throws {
        let linked = Self.metadata(
            at: Date().addingTimeInterval(-(PendingRetryMetadata.publishedWorkRetryTTL + 3_600)),
            destination: .work,
            publicationState: .published,
            workAttachedToMaterialID: UUID()
        )
        try await store.save(
            audioData: Data("the recording".utf8), metadata: linked, workImageData: nil
        )
        // The control that says the clock is running rather than stopped: the
        // same age, the same lane, INSIDE the budget.
        let young = Self.metadata(
            at: Date(),
            destination: .work,
            publicationState: .published,
            workAttachedToMaterialID: UUID()
        )
        try await store.save(
            audioData: Data("the recording".utf8), metadata: young, workImageData: nil
        )

        let surviving = Set(await store.load().map(\.metadata.id))

        XCTAssertEqual(
            surviving, [young.id],
            """
            MEASURED: the day-old linked record was swept and the fresh one kept. A link that \
            counted as unpublished-picture debt would exempt every folded capture from the \
            clock for ever, and the queue would only ever grow.
            """
        )
    }

    // MARK: - Fixtures

    private static func metadata(
        at createdAt: Date = Date(),
        destination: PendingRetryDestination = .chat,
        preferredLanguage: String? = nil,
        attemptCount: Int = 1,
        lastErrorCode: Int? = nil,
        transcript: String? = nil,
        publicationState: PendingRetryPublicationState? = nil,
        workAttachedToMaterialID: UUID? = nil
    ) -> PendingRetryMetadata {
        PendingRetryMetadata(
            id: UUID(),
            createdAt: createdAt,
            audioFileURL: URL(fileURLWithPath: "/dev/null"),
            preferredLanguage: preferredLanguage,
            attemptCount: attemptCount,
            lastErrorCode: lastErrorCode,
            destination: destination,
            transcript: transcript,
            publicationState: publicationState,
            workAttachedToMaterialID: workAttachedToMaterialID
        )
    }

    private func audioURL(_ id: UUID, _ destination: PendingRetryDestination) -> URL {
        container.appendingPathComponent(PendingRetryFiles.audio(id, destination))
    }

    private func sidecarURL(_ id: UUID) -> URL {
        container.appendingPathComponent(PendingRetryFiles.sidecar(id))
    }

    private func tombstoneURL(_ id: UUID) -> URL {
        container.appendingPathComponent(PendingRetryFiles.tombstone(id))
    }

    private func legacyAudioURL() -> URL {
        container.appendingPathComponent(PendingRetryFiles.legacyAudioName)
    }

    /// Commit an index without going through the store, so a case can stage the
    /// exact on-disk state a death between two writes leaves.
    private func persistIndex(_ entries: [PendingRetryMetadata]) {
        try? FileManager.default.createDirectory(
            at: container, withIntermediateDirectories: true
        )
        guard let encoded = try? JSONEncoder().encode(entries) else { return }
        defaults.set(encoded, forKey: PendingRetryDefaultsKeys.queue)
    }

    /// Move one capture's reservation into the past, which is the only
    /// observable a process killed while holding it leaves.
    private func lapseReservation(for id: UUID) throws {
        let data = try Data(contentsOf: sidecarURL(id))
        let sidecar = try JSONDecoder().decode(PendingRetrySidecar.self, from: data)
        let token = try XCTUnwrap(sidecar.lease?.token)
        let lapsed = PendingRetrySidecar(
            metadata: sidecar.metadata,
            lease: PendingRetryLease(token: token, expiresAt: Date().addingTimeInterval(-1))
        )
        try JSONEncoder().encode(lapsed).write(to: sidecarURL(id), options: [.atomic])
    }
}
