// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// PendingRetryLeaseTests.swift
//
// The RESERVATION half of the pending-retry queue: addressing a capture by the
// id a lane minted, extending a hold that outlives its first horizon, and asking
// whether a hold is still good before acting on it.
//
// Why these are separate from `PendingRetryDurabilityTests`, which drives the
// write orders and the reconciliation: the defects here are about TIME rather
// than about crashes. A reservation was a fixed ten minutes and could not be
// extended, while one custom provider request is allowed 300 seconds and is
// attempted three times — so the surface doing the work could lose the capture,
// and the expiry sweep could delete the recording, in the middle of the
// transcription both were waiting for. And the only way to take a reservation
// was to ask for "the newest capture nobody holds", which is never the answer a
// lane that armed its own capture is looking for.
//
// Each case runs against an ISOLATED store — its own temporary directory and its
// own in-memory defaults, through the `CONDUCK_TESTING` initializer — because
// the production singleton writes the process-global App-Group container every
// other capture test in this bundle shares.

import XCTest
@testable import Conduck

final class PendingRetryLeaseTests: XCTestCase {

    private var container: URL!
    private var defaults: InMemoryDefaultsStore!
    private var store: PendingRetryStore!

    override func setUp() {
        super.setUp()
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-retry-lease-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Addressing the capture this lane minted

    /// The defect: the only way to hold a capture was to ask for the newest one
    /// nobody had reserved. A lane that armed its own capture — the guard, the
    /// recorder, a Shortcut's intent process — would then be handed somebody
    /// else's recording whenever anything armed after it.
    func testALaneReservesTheCaptureItNamesRatherThanTheNewestOne() async throws {
        let mine = Self.metadata(
            at: Date().addingTimeInterval(-30), destination: .work,
            publicationState: .phaseOneFailed
        )
        let newer = Self.metadata(destination: .work, publicationState: .phaseOneFailed)
        try await store.save(audioData: Data("mine".utf8), metadata: mine, workImageData: nil)
        try await store.save(audioData: Data("newer".utf8), metadata: newer, workImageData: nil)

        let addressed = await store.claim(id: mine.id)
        let claim = try XCTUnwrap(addressed)

        XCTAssertEqual(claim.id, mine.id, "the id it minted, not the newest capture in the queue")
        XCTAssertEqual(claim.entry.audioData, Data("mine".utf8))
    }

    /// A reservation is over ONE capture, so a lane holding its own leaves every
    /// other capture available to the retry surfaces.
    func testHoldingOneCaptureLeavesTheRestOfTheQueueClaimable() async throws {
        let mine = Self.metadata(
            at: Date().addingTimeInterval(-30), destination: .work,
            publicationState: .phaseOneFailed
        )
        let newer = Self.metadata(destination: .work, publicationState: .phaseOneFailed)
        try await store.save(audioData: Data("mine".utf8), metadata: mine, workImageData: nil)
        try await store.save(audioData: Data("newer".utf8), metadata: newer, workImageData: nil)

        _ = await store.claim(id: mine.id)
        let offered = await store.claimNext()
        let surfaceClaim = try XCTUnwrap(offered)

        XCTAssertEqual(surfaceClaim.id, newer.id)
        let waiting = await store.pendingCount()
        XCTAssertEqual(waiting, 2, "a reservation says who is finishing a capture, not whether it waits")
    }

    func testACaptureAnotherSurfaceIsHoldingCannotBeAddressedByIdEither() async throws {
        let armed = Self.metadata(destination: .work, publicationState: .phaseOneFailed)
        try await store.save(audioData: Data("one copy".utf8), metadata: armed, workImageData: nil)
        let offered = await store.claimNext()
        let holder = try XCTUnwrap(offered)

        let addressed = await store.claim(id: armed.id)
        XCTAssertNil(addressed, "an id is not a way around somebody else's reservation")

        try lapseReservation(for: armed.id)
        let afterLapse = await store.claim(id: armed.id)
        let taken = try XCTUnwrap(afterLapse, "a reservation nobody finished is takeable once it lapses")
        XCTAssertNotEqual(taken.token, holder.token, "under the new holder's own token")
    }

    func testAddressingACaptureThatIsNotQueuedReservesNothing() async throws {
        let claim = await store.claim(id: UUID())
        XCTAssertNil(claim)
    }

    /// The headless lane's horizon. An App Intent host that is killed announces
    /// a retry with a notification 90 seconds later, so a ten-minute hold taken
    /// there tells a person to tap a button the store then refuses them for
    /// another eight minutes.
    func testAShortLivedLaneTakesAHoldThatLapsesLongBeforeTheStandardOne() async throws {
        let armed = Self.metadata(destination: .work, publicationState: .phaseOneFailed)
        try await store.save(audioData: Data("headless".utf8), metadata: armed, workImageData: nil)

        let addressed = await store.claim(id: armed.id, duration: 90)
        _ = try XCTUnwrap(addressed)

        let lease = try XCTUnwrap(readSidecar(armed.id).lease)
        XCTAssertLessThanOrEqual(
            lease.expiresAt.timeIntervalSinceNow, 90,
            "the caller's own horizon, not the store's default"
        )
        XCTAssertLessThan(
            lease.expiresAt.timeIntervalSinceNow, PendingRetryStore.claimLeaseDuration,
            """
            The whole point of the parameter: the deferred notice fires at 90 \
            seconds, and the capture has to be takeable by then.
            """
        )
    }

    // MARK: - A reservation is renewed, not sized for the worst case

    /// The defect: the hold was a fixed ten minutes and could not be extended,
    /// while a custom provider request is allowed 300 seconds and is attempted
    /// three times. The surface doing the work lost the capture in the middle of
    /// the transcription it was waiting for.
    func testTheHolderExtendsItsReservationAndKeepsTheCapture() async throws {
        let armed = Self.metadata(destination: .work, publicationState: .phaseOneFailed)
        try await store.save(audioData: Data("long transcription".utf8), metadata: armed, workImageData: nil)
        let offered = await store.claimNext()
        let holder = try XCTUnwrap(offered)

        // The transcription outlived the horizon it was granted.
        try lapseReservation(for: armed.id)
        let renewed = await store.renew(holder)

        XCTAssertTrue(renewed)
        let overtaking = await store.claimNext()
        XCTAssertNil(overtaking, "the capture is still this holder's")
        let stillOwned = await store.confirmOwnership(holder)
        XCTAssertTrue(stillOwned)
    }

    func testARenewalExtendsByTheHorizonTheHolderWasGrantedNotTheDefault() async throws {
        let armed = Self.metadata(destination: .work, publicationState: .phaseOneFailed)
        try await store.save(audioData: Data("headless".utf8), metadata: armed, workImageData: nil)
        let addressed = await store.claim(id: armed.id, duration: 90)
        let holder = try XCTUnwrap(addressed)
        try lapseReservation(for: armed.id)

        let renewed = await store.renew(holder)

        XCTAssertTrue(renewed)
        let lease = try XCTUnwrap(readSidecar(armed.id).lease)
        XCTAssertLessThanOrEqual(lease.expiresAt.timeIntervalSinceNow, 90)
        XCTAssertGreaterThan(
            lease.expiresAt.timeIntervalSinceNow, 0,
            "a renewal is an extension from now, not a no-op"
        )
    }

    func testAnOvertakenHolderCanNeitherRenewNorConfirm() async throws {
        let armed = Self.metadata(destination: .work, publicationState: .phaseOneFailed)
        try await store.save(audioData: Data("one copy".utf8), metadata: armed, workImageData: nil)
        let offered = await store.claimNext()
        let overtaken = try XCTUnwrap(offered)
        await store.release(overtaken)
        let reoffered = await store.claimNext()
        let holder = try XCTUnwrap(reoffered)

        let renewed = await store.renew(overtaken)
        let confirmed = await store.confirmOwnership(overtaken)
        let holderStillOwns = await store.confirmOwnership(holder)

        XCTAssertFalse(renewed)
        XCTAssertFalse(confirmed)
        XCTAssertTrue(
            holderStillOwns,
            "and the reservation the overtaking surface holds is untouched"
        )
    }

    // MARK: - Ownership is what a surface asks before it acts

    /// A hold is confirmed, not assumed: the answer is what stands between a
    /// transcript reaching a card and two surfaces writing the same words twice.
    func testConfirmingOwnershipChangesNothingAtAll() async throws {
        let armed = Self.metadata(destination: .work, publicationState: .phaseOneFailed)
        try await store.save(audioData: Data("one copy".utf8), metadata: armed, workImageData: nil)
        let offered = await store.claimNext()
        let holder = try XCTUnwrap(offered)
        let before = try Data(contentsOf: sidecarURL(armed.id))

        let confirmed = await store.confirmOwnership(holder)

        XCTAssertTrue(confirmed)
        XCTAssertEqual(
            try Data(contentsOf: sidecarURL(armed.id)), before,
            "a question about ownership takes nothing, extends nothing and drops nothing"
        )
        let waiting = await store.pendingCount()
        XCTAssertEqual(waiting, 1)
    }

    func testAFinishedCaptureIsOwnedByNobody() async throws {
        let armed = Self.metadata(destination: .work, publicationState: .phaseOneFailed)
        try await store.save(audioData: Data("one copy".utf8), metadata: armed, workImageData: nil)
        let offered = await store.claimNext()
        let holder = try XCTUnwrap(offered)
        let cleared = await store.clear(holder)
        XCTAssertTrue(cleared)

        let confirmed = await store.confirmOwnership(holder)

        XCTAssertFalse(confirmed, "there is nothing left to own")
    }

    /// A holder that stopped renewing but that nobody overtook is still the
    /// holder: expiry makes a reservation stealable, it does not retire it.
    func testALapsedButUnstolenReservationStillConfirms() async throws {
        let armed = Self.metadata(destination: .work, publicationState: .phaseOneFailed)
        try await store.save(audioData: Data("one copy".utf8), metadata: armed, workImageData: nil)
        let offered = await store.claimNext()
        let holder = try XCTUnwrap(offered)
        try lapseReservation(for: armed.id)

        let confirmed = await store.confirmOwnership(holder)

        XCTAssertTrue(confirmed)
    }

    // MARK: - The clock does not reach a capture somebody is finishing

    /// The other half of the same defect. The expiry budget is ten minutes and a
    /// transcription can take longer than that on its own — 300 seconds a
    /// request, three attempts — so the sweep deleted the recording out from
    /// under the surface transcribing it, and the transcript arrived with
    /// nothing left to attach it to.
    func testTheExpirySweepDoesNotReachACaptureUnderALiveReservation() async throws {
        let armed = Self.metadata(destination: .chat)
        try await store.save(audioData: Data("still being transcribed".utf8), metadata: armed, workImageData: nil)
        let offered = await store.claimNext()
        let holder = try XCTUnwrap(offered)

        // The transcription is still running and the budget has passed.
        try backdate(armed.id, to: Date().addingTimeInterval(-660))

        let waiting = await store.pendingCount()

        XCTAssertEqual(waiting, 1, "the clock retires captures nobody is finishing")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL(armed.id, .chat).path))
        let stillOwned = await store.confirmOwnership(holder)
        XCTAssertTrue(stillOwned)
        let cleared = await store.clear(holder)
        XCTAssertTrue(cleared, "and its holder is the one that finishes it")
    }

    /// The control that keeps the rule honest: the exemption is the RESERVATION,
    /// not a disabled clock. The moment nobody is holding the capture, the same
    /// budget retires it.
    func testTheSameCaptureExpiresOnceNobodyIsHoldingIt() async throws {
        let armed = Self.metadata(destination: .chat)
        try await store.save(audioData: Data("nobody is coming back".utf8), metadata: armed, workImageData: nil)
        let offered = await store.claimNext()
        let holder = try XCTUnwrap(offered)
        try backdate(armed.id, to: Date().addingTimeInterval(-660))

        await store.release(holder)
        let waiting = await store.pendingCount()

        XCTAssertEqual(waiting, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL(armed.id, .chat).path))
    }

    // MARK: - Fixtures

    private static func metadata(
        at createdAt: Date = Date(),
        destination: PendingRetryDestination = .chat,
        transcript: String? = nil,
        publicationState: PendingRetryPublicationState? = nil
    ) -> PendingRetryMetadata {
        PendingRetryMetadata(
            id: UUID(),
            createdAt: createdAt,
            audioFileURL: URL(fileURLWithPath: "/dev/null"),
            preferredLanguage: nil,
            attemptCount: 1,
            lastErrorCode: nil,
            destination: destination,
            transcript: transcript,
            publicationState: publicationState
        )
    }

    private func audioURL(_ id: UUID, _ destination: PendingRetryDestination) -> URL {
        container.appendingPathComponent(PendingRetryFiles.audio(id, destination))
    }

    private func sidecarURL(_ id: UUID) -> URL {
        container.appendingPathComponent(PendingRetryFiles.sidecar(id))
    }

    private func readSidecar(_ id: UUID) throws -> PendingRetrySidecar {
        try JSONDecoder().decode(
            PendingRetrySidecar.self, from: try Data(contentsOf: sidecarURL(id))
        )
    }

    /// Move one capture's reservation into the past, which is the only
    /// observable a process killed while holding it leaves.
    private func lapseReservation(for id: UUID) throws {
        let sidecar = try readSidecar(id)
        let lease = try XCTUnwrap(sidecar.lease)
        try write(
            PendingRetrySidecar(
                metadata: sidecar.metadata,
                lease: PendingRetryLease(
                    token: lease.token,
                    expiresAt: Date().addingTimeInterval(-1),
                    duration: lease.duration
                )
            ),
            for: id
        )
    }

    /// Age one capture past the expiry budget without disturbing the
    /// reservation over it — the state a transcription that runs longer than
    /// the budget leaves, and the only way to reach it without waiting ten
    /// minutes. Both halves are rewritten, so the record and its index row still
    /// agree and nothing but the clock has moved.
    private func backdate(_ id: UUID, to createdAt: Date) throws {
        let sidecar = try readSidecar(id)
        let aged = PendingRetryMetadata(
            id: sidecar.metadata.id,
            createdAt: createdAt,
            audioFileURL: sidecar.metadata.audioFileURL,
            preferredLanguage: sidecar.metadata.preferredLanguage,
            attemptCount: sidecar.metadata.attemptCount,
            lastErrorCode: sidecar.metadata.lastErrorCode,
            destination: sidecar.metadata.destination,
            transcript: sidecar.metadata.transcript,
            publicationState: sidecar.metadata.publicationState
        )
        try write(PendingRetrySidecar(metadata: aged, lease: sidecar.lease), for: id)
        defaults.set(
            try JSONEncoder().encode([aged]), forKey: PendingRetryDefaultsKeys.queue
        )
    }

    private func write(_ sidecar: PendingRetrySidecar, for id: UUID) throws {
        try JSONEncoder().encode(sidecar).write(to: sidecarURL(id), options: [.atomic])
    }
}
