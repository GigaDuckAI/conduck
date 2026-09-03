// SPDX-License-Identifier: Apache-2.0

// Conduck
// ArmSideReservationTests.swift
//
// The three lanes that ARM a capture — the Shortcuts intent through
// `PendingRetryGuard`, the in-app recorder, and the desk's voice sheet through
// it — address the entry they minted rather than selecting one out of the
// queue. This file pins the half of that which the queue's own tests cannot see:
// that addressing by id is not the same as OWNING, and that every operation an
// arming lane performs against its entry goes through the RESERVATION.
//
// The defect. `PendingRetryGuard.disarm` cleared by id, and so did the
// recorder's release. Both were correct about WHICH capture; neither could tell
// whether that capture was still theirs. Meanwhile the app's retry card and the
// menu bar select through `claimNext`, so a Shortcut completing at the same
// moment the person tapped Retry deleted the recording the card was
// mid-transcription on — and for Chat, both surfaces finishing one capture is
// two user turns and two gateway effects for one thing said once.
//
// Two kinds of case here, and the split is deliberate:
//
//   • BEHAVIOURAL, against a real `PendingRetryStore` over a directory of this
//     case's own: what a disarm does when the reservation it holds has been
//     overtaken, and what it does when it has not.
//
//   • SOURCE, over comment-stripped source, for the things no simulator run can
//     reach: the renewal timer (its interval is minutes), and the absence of the
//     lease-blind operations these lanes used to call. `ConverseIntent` cannot be
//     driven here at all — `perform()` takes an `IntentFile` from the Shortcuts
//     runtime and a live STT provider — which is why its guards are written the
//     way `HeadlessRetryGuardSpanTests` writes them.

import XCTest
@testable import Conduck

final class ArmSideReservationTests: XCTestCase {

    private var container: URL!
    private var store: PendingRetryStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-arm-reservation-\(UUID().uuidString)", isDirectory: true)
        store = PendingRetryStore(
            containerURL: container,
            defaults: InMemoryDefaultsStore()
        )
        PendingRetryGuard.storeForTesting = store
    }

    override func tearDownWithError() throws {
        PendingRetryGuard.storeForTesting = nil
        store = nil
        if let container { try? FileManager.default.removeItem(at: container) }
        container = nil
        try super.tearDownWithError()
    }

    // MARK: - The disarm goes through the reservation

    /// r6a#1's headless half. A capture another surface reserved after this
    /// process's hold lapsed may not be deleted by this process finishing.
    ///
    /// The token models exactly that state: the intent still holds the claim it
    /// took at `arm`, and the store's live lease is now somebody else's. On the
    /// id-keyed clear this replaced, the disarm deleted the recording the other
    /// surface was transcribing — and the entry with it, so the words that
    /// surface was about to write had nothing left to land on.
    func testTheIntentCannotDisarmACaptureAnotherSurfaceHolds() async throws {
        let id = UUID()
        let bytes = Data(repeating: 0x5A, count: 512)
        try await store.save(audioData: bytes, metadata: Self.metadata(id: id), workImageData: nil)

        // The intent's hold, as it stood before it lapsed.
        let reserved = await store.claim(id: id, duration: PendingRetryGuard.leaseDuration)
        let stale = try XCTUnwrap(
            reserved,
            "the capture just armed must be reservable by the lane that armed it"
        )
        let staleToken = PendingRetryGuard.Token(
            retryID: id,
            notificationID: "conduck-pending-retry-\(id.uuidString)",
            audioPreserved: true,
            claim: stale
        )
        await store.release(stale)

        // Another surface takes it over — the retry card, selecting newest-first.
        let takeover = await store.claimNext()
        let overtaken = try XCTUnwrap(
            takeover,
            "with the hold given back the capture is selectable again"
        )
        XCTAssertEqual(overtaken.id, id)
        XCTAssertNotEqual(
            overtaken.token, stale.token,
            "a second reservation is a NEW token, which is what makes the first one stale"
        )

        await PendingRetryGuard.disarm(staleToken)

        let stillQueued = await store.load()
        XCTAssertEqual(
            stillQueued.map(\.metadata.id), [id],
            """
            The intent finished and deleted a capture it no longer held. The \
            surface that DOES hold it is mid-transcription on those bytes, and \
            it now has nowhere to put the words it bought.
            """
        )
        XCTAssertEqual(
            stillQueued.first?.audioData, bytes,
            "and the recording itself is untouched, byte for byte"
        )
        let ownerStillOwns = await store.confirmOwnership(overtaken)
        XCTAssertTrue(
            ownerStillOwns,
            "the disarm must not have disturbed the reservation it was refused by"
        )
    }

    /// The control, and the half that must not regress: a lane that still holds
    /// its reservation disarms exactly as it always did.
    func testTheIntentDisarmsTheCaptureItStillHolds() async throws {
        let id = UUID()
        try await store.save(
            audioData: Data(repeating: 0x11, count: 256),
            metadata: Self.metadata(id: id),
            workImageData: nil
        )
        let reserved = await store.claim(id: id, duration: PendingRetryGuard.leaseDuration)
        let claim = try XCTUnwrap(reserved)
        let token = PendingRetryGuard.Token(
            retryID: id,
            notificationID: "conduck-pending-retry-\(id.uuidString)",
            audioPreserved: true,
            claim: claim
        )

        await PendingRetryGuard.disarm(token)

        let remaining = await store.load()
        XCTAssertTrue(
            remaining.isEmpty,
            "a capture this process both armed and still holds is finished by its disarm"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: container.appendingPathComponent(
                    PendingRetryFiles.audio(id, .chat)
                ).path
            ),
            "and its recording goes with it"
        )
    }

    /// What an arming lane RETAINS is the reservation, not a second copy of the
    /// recording.
    ///
    /// `claim(id:)` answers with the parked bytes, because a surface that
    /// SELECTED a capture out of the queue needs them to finish it. This lane
    /// recorded those bytes and still holds them, so keeping the store's copy
    /// for the span of the work is a second recording of up to
    /// `Constants.maxAudioSize` beside the first — in an App Intent process,
    /// which is the one least able to afford it — and it buys nothing: every
    /// operation a holder performs reads the capture id and the token.
    ///
    /// Both halves are asserted here, so the case cannot pass by the claim
    /// being empty for some other reason: the store still hands its own callers
    /// the recording, and the reservation this lane keeps still works.
    func testAnArmingLaneRetainsAReservationAndNotASecondCopyOfTheRecording() async throws {
        let armed = UUID()
        let bytes = Data(repeating: 0x77, count: 4096)
        let token = await PendingRetryGuard.arm(
            audio: bytes,
            metadata: Self.metadata(id: armed),
            workImageData: nil,
            requestNotificationAuthorization: false
        )

        let held = try XCTUnwrap(
            token.claim,
            "arming takes a reservation over the capture it just wrote, by the id it minted"
        )
        XCTAssertEqual(held.id, armed, "and over THAT capture, never whichever is newest")
        XCTAssertTrue(
            held.entry.audioData.isEmpty,
            """
            The token holds a whole second copy of the recording for as long as \
            the intent runs, on top of the bytes it is transcribing.
            """
        )

        // Control, so the assertion above cannot pass on an empty queue: a
        // caller that ASKS the store for a reservation is still handed the
        // recording with it.
        let other = UUID()
        try await store.save(
            audioData: bytes,
            metadata: Self.metadata(id: other),
            workImageData: nil
        )
        let reservedByAsking = await store.claim(id: other, duration: 60)
        let issued = try XCTUnwrap(reservedByAsking)
        XCTAssertEqual(
            issued.entry.audioData, bytes,
            "Control: the store answers a reservation with the parked recording."
        )

        // …and the stripped reservation is a working one, not a husk.
        let owns = await PendingRetryGuard.stillOwnsCapture(token)
        XCTAssertTrue(owns, "the token still proves this process holds the capture")
        await PendingRetryGuard.disarm(token)
        let remaining = await store.load().map(\.metadata.id)
        XCTAssertEqual(
            remaining, [other],
            "and still finishes exactly the capture it names, and only that one"
        )
    }

    /// An arm whose durable write failed reserves nothing — and must still
    /// answer that this process owns the capture, because the bytes in hand are
    /// then the only copy there is and refusing would abandon them to protect an
    /// entry that was never written.
    func testAnArmThatPreservedNothingStillOwnsItsCapture() async throws {
        let token = PendingRetryGuard.Token(
            retryID: UUID(),
            notificationID: "conduck-pending-retry-none",
            audioPreserved: false,
            claim: nil
        )
        let owns = await PendingRetryGuard.stillOwnsCapture(token)
        XCTAssertTrue(
            owns,
            """
            No entry exists, so no other surface can be holding one. Answering \
            false here stops a Shortcut writing the recording to the desk on the \
            one path where this process holds the only copy of it.
            """
        )
        await PendingRetryGuard.disarm(token)  // and disarming it is a no-op, not a crash
    }

    /// `stillOwnsCapture` is the question every hand-off asks, and it has to
    /// answer for the RESERVATION rather than for the id.
    func testOwnershipIsAnsweredByTheTokenAndNotByTheIdentifier() async throws {
        let id = UUID()
        try await store.save(
            audioData: Data(repeating: 0x22, count: 128),
            metadata: Self.metadata(id: id),
            workImageData: nil
        )
        let reserved = await store.claim(id: id, duration: 60)
        let mine = try XCTUnwrap(reserved)
        let mineToken = PendingRetryGuard.Token(
            retryID: id,
            notificationID: "conduck-pending-retry-\(id.uuidString)",
            audioPreserved: true,
            claim: mine
        )
        let ownsWhileHeld = await PendingRetryGuard.stillOwnsCapture(mineToken)
        XCTAssertTrue(ownsWhileHeld)

        await store.release(mine)
        let takeover = await store.claimNext()
        let theirs = try XCTUnwrap(takeover)
        XCTAssertEqual(theirs.id, id, "same capture, same id — only the holder changed")

        let ownsAfterTakeover = await PendingRetryGuard.stillOwnsCapture(mineToken)
        XCTAssertFalse(
            ownsAfterTakeover,
            """
            The id is unchanged and the entry is still queued, so anything that \
            asks by id says yes. Only the token can say that the capture is \
            somebody else's now, which is the fact a Chat send has to branch on.
            """
        )
    }

    /// A verdict written by a lane that lost its reservation would overwrite the
    /// observation of the surface that actually holds the capture.
    func testAVerdictFromAnOvertakenLaneIsNotWritten() async throws {
        let id = UUID()
        try await store.save(
            audioData: Data(repeating: 0x33, count: 128),
            metadata: Self.metadata(id: id, publicationState: .phaseOneFailed),
            workImageData: nil
        )
        let reserved = await store.claim(id: id, duration: 60)
        let mine = try XCTUnwrap(reserved)
        let mineToken = PendingRetryGuard.Token(
            retryID: id,
            notificationID: "conduck-pending-retry-\(id.uuidString)",
            audioPreserved: true,
            claim: mine
        )
        await store.release(mine)
        let takeover = await store.claimNext()
        _ = try XCTUnwrap(takeover, "another surface takes it over")

        let wrote = await PendingRetryGuard.recordPublicationState(
            mineToken,
            transcript: "words from a lane that lost the capture",
            publicationState: .published
        )
        XCTAssertFalse(wrote, "the write is refused, not silently applied")

        let record = await store.load().first { $0.metadata.id == id }?.metadata
        XCTAssertEqual(
            record?.publicationState, .phaseOneFailed,
            "the verdict the holder can still act on is the one still there"
        )
        XCTAssertNil(
            record?.transcript,
            "and no words were parked by a lane that is not finishing this capture"
        )
    }

    // MARK: - Source shape: the renewal, and the operations that are gone

    /// L2 for the arming lanes: a transcription can outlast the reservation that
    /// protects it — a custom provider request is allowed 300 s and attempted
    /// three times — so a live surface extends its hold, and stops the moment it
    /// exits. Source, because the interval is minutes and no simulator run can
    /// wait one out.
    func testTheHeadlessLaneRenewsWhileItWorksAndStopsOnEveryExit() throws {
        let body = try RefusalLaneSource.body(
            ofFunction: "perform",
            in: try RefusalLaneSource.source(at: Self.intentPath),
            path: Self.intentPath
        )
        XCTAssertTrue(
            body.contains("PendingRetryGuard.renew(guardToken)"),
            "The Shortcuts lane never extends its reservation, so a transcription longer than one "
            + "notification window hands the capture to whoever asks next while this process is "
            + "still working on it."
        )
        let renewalAt = try XCTUnwrap(
            body.range(of: "let leaseRenewal = Task {")?.lowerBound,
            "The renewal is no longer a task this function owns; update this guard."
        )
        let cancelAt = try XCTUnwrap(
            body.range(of: "defer { leaseRenewal.cancel() }")?.lowerBound,
            "The renewal is not cancelled by a `defer`, so a refusal path leaves it running and the "
            + "hold outlives the work it was protecting."
        )
        XCTAssertLessThan(renewalAt, cancelAt)
        let transcribeAt = try XCTUnwrap(body.range(of: "STTClient.shared.transcribe")?.lowerBound)
        XCTAssertLessThan(
            cancelAt, transcribeAt,
            "The renewal has to be running BEFORE the speech hop — that is the only thing it "
            + "protects — which the `defer` at function scope guarantees."
        )
    }

    /// The same rule on the in-app lane, where the timer is a stored task.
    func testTheRecorderRenewsItsReservationWhileARetryRunsAndStopsOnEveryExit() throws {
        let source = try RefusalLaneSource.source(at: Self.recorderPath)
        let reserve = try RefusalLaneSource.body(
            ofFunction: "reserveDurableRetry", in: source, path: Self.recorderPath
        )
        XCTAssertTrue(
            reserve.contains("startRenewingRetryLease()"),
            "A retry that reserves but never renews loses its capture mid-transcription — a custom "
            + "provider request is allowed 300 s and attempted three times."
        )
        for owner in ["handBackUnfinishedRetry", "releaseDurableRetry"] {
            let body = try RefusalLaneSource.body(ofFunction: owner, in: source, path: Self.recorderPath)
            XCTAssertTrue(
                body.contains("stopRenewingRetryLease()"),
                "`\(owner)` leaves the renewal running over a reservation it just gave up, so a "
                + "capture somebody else now holds goes on being renewed by this recorder."
            )
        }
    }

    /// L5 for the three lanes this file is about: none of them may still reach
    /// the store through an operation that acts on a capture whether or not the
    /// caller holds it. The bundle-wide census lives in
    /// `PendingRetrySurfaceHandoffTests`; this is the arming lanes' own copy, so
    /// a regression in one of these three files fails beside its reason.
    ///
    /// The needles are compared with whitespace removed, because both of these
    /// calls are routinely broken across lines — the census's own KNOWN LIMIT is
    /// exactly that, and an id-keyed write that returned under a line break
    /// would otherwise read as migrated.
    func testNoArmingLaneStillReachesTheLeaseBlindOperations() throws {
        for path in [Self.guardPath, Self.recorderPath, Self.intentPath] {
            let source = Self.squeezed(try RefusalLaneSource.source(at: path))
            for needle in [
                "clear(ifCurrentID:",
                "recordPublicationState(id:",
                "PendingRetryStore.shared.load()",
                "retryLane.load()",
            ] {
                XCTAssertFalse(
                    source.contains(needle),
                    "`\(path)` still calls `\(needle)`, which acts on a capture whether or not this "
                    + "lane still holds it. Two surfaces then finish one recording — and for Chat "
                    + "that is two turns and two gateway effects for one thing said once."
                )
            }
        }
    }

    /// Rule 0 for the census above: the needles match the shapes they exist to
    /// refuse, including the line-broken form, and do NOT match the claim API
    /// that replaced them.
    func testTheLeaseBlindCensusMatchesTheShapesItExistsToRefuse() {
        let broken = """
        _ = await PendingRetryStore.shared.recordPublicationState(
            id: captureID,
            transcript: transcript
        )
        """
        let migrated = """
        _ = await PendingRetryStore.shared.recordPublicationState(
            claim,
            transcript: transcript
        )
        """
        XCTAssertTrue(
            Self.squeezed(broken).contains("recordPublicationState(id:"),
            "Control: the id-keyed write really is matched even when it is broken across lines."
        )
        XCTAssertFalse(
            Self.squeezed(migrated).contains("recordPublicationState(id:"),
            "Control: the claim form must NOT match, or the census refuses the fix."
        )
        XCTAssertTrue(
            Self.squeezed("_ = await lane.clear(ifCurrentID: id)").contains("clear(ifCurrentID:"),
            "Control: the lease-blind clear is matched."
        )
        XCTAssertFalse(
            Self.squeezed("_ = await lane.clear(claim)").contains("clear(ifCurrentID:"),
            "Control: the claim-gated clear is not."
        )
    }

    /// The fabricated reservation is gone. A token drawn from `UUID()` LOOKS
    /// like a reservation and is refused by every store operation, which is how
    /// the Shortcuts lane's durable `.published` verdict was silently not
    /// written for a whole round.
    func testNoLaneMintsATokenTheStoreNeverIssued() throws {
        for path in [Self.guardPath, Self.recorderPath, Self.intentPath] {
            let source = Self.squeezed(try RefusalLaneSource.source(at: path))
            XCTAssertFalse(
                source.contains("token:UUID()"),
                "`\(path)` builds a claim carrying a token no store issued. Every verdict written "
                + "through it is refused, and nothing says so."
            )
        }
    }

    // MARK: - Fixtures

    private static let guardPath = "Conduck/Services/PendingRetryGuard.swift"
    private static let recorderPath = "Conduck/Services/InAppAudioRecorder.swift"
    private static let intentPath = "Conduck/Intents/ConverseIntent.swift"

    /// Source with every whitespace character removed, so a call the author
    /// broke across lines reads the same as one written on a single line.
    private static func squeezed(_ source: String) -> String {
        source.filter { !$0.isWhitespace }
    }

    private static func metadata(
        id: UUID,
        destination: PendingRetryDestination = .chat,
        publicationState: PendingRetryPublicationState? = nil
    ) -> PendingRetryMetadata {
        PendingRetryMetadata(
            id: id,
            createdAt: Date(),
            audioFileURL: URL(fileURLWithPath: "/dev/null"),
            preferredLanguage: nil,
            attemptCount: 1,
            lastErrorCode: AppError.sttProviderUnreachable.errorCode,
            destination: destination,
            transcript: nil,
            publicationState: publicationState
        )
    }
}
