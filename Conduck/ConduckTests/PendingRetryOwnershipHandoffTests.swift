// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// PendingRetryOwnershipHandoffTests.swift
//
// What a retry surface does about the RESERVATION while it works, and before it
// does anything it cannot take back.
//
// The defects these pin are all about time passing between taking a capture and
// acting on it. A reservation was granted for ten minutes and nothing extended
// it, while one custom STT request is allowed 300 seconds and is attempted three
// times — so the surface transcribing could lose the capture mid-flight. And
// neither surface then LOOKED: the transcript went to the Chat lane, and the
// deferred "Recording Saved" notice was cancelled, on the strength of a clear
// whose answer was thrown away — so an overtaken surface sent words another
// surface had already sent. The discard had the same shape from the other end:
// it re-selected out of the queue at confirmation time, so the recording it
// deleted was not necessarily the recording the question had been asked about.
//
// TWO KINDS OF CHECK, the same split `PendingRetrySurfaceHandoffTests` makes and
// for the same reason:
//
//   • BEHAVIOURAL, against an isolated `PendingRetryStore` over a real
//     directory and a real cross-process lock — the renewal, the refusals, and
//     what a reservation taken before a question protects.
//   • SOURCE, over comment-stripped release code, for the half that is a matter
//     of WHERE a statement sits. Neither surface is constructible here: one is a
//     SwiftUI root, the other a macOS-only `@Observable` service driving a live
//     `STTClient`.

import XCTest
@testable import Conduck

final class PendingRetryOwnershipHandoffTests: XCTestCase {

    private var container: URL!
    private var defaults: InMemoryDefaultsStore!
    private var store: PendingRetryStore!

    override func setUp() {
        super.setUp()
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("retry-ownership-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - The renewal (L2)

    /// A holder that is still working keeps its horizon ahead of the clock.
    ///
    /// The reservation is minted once and would otherwise stand still while a
    /// slow provider round trip runs, which is exactly the case it exists for:
    /// parked recordings come from bad connections, and a bad connection is what
    /// makes a transcription outlast its hold.
    func testAHolderThatKeepsWorkingKeepsItsReservationAheadOfTheClock() async throws {
        let waiting = Self.metadata(destination: .chat)
        try await store.save(audioData: Data("waiting".utf8), metadata: waiting, workImageData: nil)
        let claimed = await store.claimNext()
        let claim = try XCTUnwrap(claimed)
        let granted = try XCTUnwrap(readSidecar(waiting.id).lease).expiresAt

        await PendingRetryLeaseRenewal.whileRenewing(claim, in: store, every: 0.05) {
            try? await Task.sleep(nanoseconds: 400_000_000)
        }

        let extended = try XCTUnwrap(readSidecar(waiting.id).lease)
        XCTAssertEqual(extended.token, claim.token, "the same holder, on the same reservation")
        XCTAssertGreaterThan(
            extended.expiresAt, granted,
            """
            Nothing extended the reservation while the work was live, so a \
            transcription longer than the horizon hands the recording to \
            whoever asks next — and the expiry sweep, which waives the clock \
            only for a LIVE reservation, can retire it mid-flight.
            """
        )
    }

    /// …and stops the moment the work does. The renewal is scoped to the call,
    /// so there is no exit — a return, a throw, a cancellation — that leaves a
    /// task quietly holding a capture this surface has finished with.
    func testTheRenewalStopsWithTheWorkItWasProtecting() async throws {
        let waiting = Self.metadata(destination: .chat)
        try await store.save(audioData: Data("waiting".utf8), metadata: waiting, workImageData: nil)
        let claimed = await store.claimNext()
        let claim = try XCTUnwrap(claimed)

        await PendingRetryLeaseRenewal.whileRenewing(claim, in: store, every: 0.05) {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        // Let any renewal that was already in flight at the cancellation land,
        // so the baseline below is the LAST thing the renewal ever wrote.
        try await Task.sleep(nanoseconds: 250_000_000)
        let settled = try XCTUnwrap(readSidecar(waiting.id).lease).expiresAt

        try await Task.sleep(nanoseconds: 500_000_000)   // ten intervals
        XCTAssertEqual(
            try XCTUnwrap(readSidecar(waiting.id).lease).expiresAt, settled,
            "The renewal outlived the work it was protecting, so a surface that has stopped "
            + "working keeps a capture nobody is finishing."
        )
    }

    /// A renewal the store refuses ends the loop rather than retrying, and — the
    /// half that matters — cannot touch the reservation that overtook it. A
    /// straggling renewal that re-wrote somebody else's lease would hand the
    /// capture back to a surface that had already lost it.
    func testAnOvertakenHolderCannotExtendTheReservationThatReplacedIt() async throws {
        let waiting = Self.metadata(destination: .chat)
        try await store.save(audioData: Data("waiting".utf8), metadata: waiting, workImageData: nil)
        let firstClaim = await store.claimNext()
        let overtaken = try XCTUnwrap(firstClaim)
        try expire(waiting.id)
        let stolen = await store.claimNext()
        let holder = try XCTUnwrap(stolen, "a lapsed reservation is stealable")
        let holderLease = try XCTUnwrap(readSidecar(waiting.id).lease)

        await PendingRetryLeaseRenewal.whileRenewing(overtaken, in: store, every: 0.05) {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        let after = try XCTUnwrap(readSidecar(waiting.id).lease)
        XCTAssertEqual(after.token, holder.token, "the capture still belongs to the surface that took it")
        XCTAssertEqual(after.expiresAt, holderLease.expiresAt, "and its horizon was not moved by a stranger")
    }

    // MARK: - The ownership gate (L3)

    /// The exact answer both surfaces now act on before they hand words onward:
    /// a clear from an overtaken reservation is REFUSED, and the capture — and
    /// its recording — are left for the surface that owns them.
    func testAnOvertakenHolderIsRefusedTheClearItWouldHaveActedOn() async throws {
        let waiting = Self.metadata(destination: .chat)
        try await store.save(audioData: Data("waiting".utf8), metadata: waiting, workImageData: nil)
        let firstClaim = await store.claimNext()
        let overtaken = try XCTUnwrap(firstClaim)
        try expire(waiting.id)
        let stolen = await store.claimNext()
        _ = try XCTUnwrap(stolen, "a lapsed reservation is stealable")

        let owns = await store.confirmOwnership(overtaken)
        XCTAssertFalse(owns, "the overtaken holder no longer owns the capture")
        let cleared = await store.clear(overtaken)
        XCTAssertFalse(
            cleared,
            """
            A refused clear is the signal both surfaces gate the transcript \
            hand-off on. Reading it as a finish is how the same words are sent \
            twice and the deferred notice is cancelled out from under the \
            surface that is still working.
            """
        )
        let remaining = await store.pendingCount()
        XCTAssertEqual(remaining, 1, "and nothing was retired")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: container.appendingPathComponent(
                    PendingRetryFiles.audio(waiting.id, .chat)
                ).path
            ),
            "the recording belongs to the surface holding it"
        )
    }

    // MARK: - The discard's binding (r6a#7)

    /// The discard reserves BEFORE the question is asked, so the recording it
    /// deletes is the recording the question was about — even though the queue
    /// moved while the dialog was on screen.
    ///
    /// A discard that re-selected at confirmation time would take the newest
    /// unreserved capture, which by then is the one that arrived DURING the
    /// dialog: it would delete a recording the person has never seen, and leave
    /// the one they asked to be rid of.
    func testTheDiscardDeletesTheRecordingItsQuestionWasAskedAbout() async throws {
        let asked = Self.metadata(at: Date().addingTimeInterval(-120), destination: .work)
        try await store.save(audioData: Data("asked".utf8), metadata: asked, workImageData: nil)

        // The tap: reserve the capture the confirmation will be about.
        let tapped = await store.claimNext()
        let reserved = try XCTUnwrap(tapped)
        XCTAssertEqual(reserved.id, asked.id)

        // The queue moves while the dialog is up.
        let arrived = Self.metadata(destination: .work)
        try await store.save(audioData: Data("arrived".utf8), metadata: arrived, workImageData: nil)

        // The answer: delete exactly what was reserved.
        let discarded = await store.clear(reserved)
        XCTAssertTrue(discarded)

        let survivorClaim = await store.claimNext()
        let survivor = try XCTUnwrap(survivorClaim)
        XCTAssertEqual(
            survivor.id, arrived.id,
            "the capture that arrived during the dialog was never the question's subject"
        )
        XCTAssertEqual(survivor.entry.audioData, Data("arrived".utf8), "and keeps its own recording")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: container.appendingPathComponent(
                    PendingRetryFiles.audio(asked.id, .work)
                ).path
            ),
            "the recording the person asked to be rid of is the one that went"
        )
    }

    /// A discard that cannot take a reservation deletes NOTHING. Every waiting
    /// capture is held elsewhere, so there is no recording this surface may
    /// answer for, and the honest response is the busy line and no dialog.
    func testADiscardThatCannotReserveDeletesNothing() async throws {
        let held = Self.metadata(destination: .work)
        try await store.save(audioData: Data("held".utf8), metadata: held, workImageData: nil)
        let heldClaim = await store.claimNext()
        _ = try XCTUnwrap(heldClaim, "another surface is finishing it")

        let refused = await store.claimNext()
        XCTAssertNil(refused, "nothing is left for the discard to reserve")
        let stillWaiting = await store.pendingCount()
        XCTAssertEqual(stillWaiting, 1, "the capture is still waiting, so the card stays up")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: container.appendingPathComponent(
                    PendingRetryFiles.audio(held.id, .work)
                ).path
            ),
            "and its recording is untouched"
        )
    }

    // MARK: - The surfaces' shape

    /// The iOS card renews while the provider works and checks that it still
    /// owns the capture before anything it cannot take back.
    func testTheCardRenewsWhileItWorksAndChecksOwnershipBeforeItHandsTheWordsOn() throws {
        let path = "Conduck/ContentView.swift"
        let source = try RefusalLaneSource.source(at: path)

        let attempt = try RefusalLaneSource.body(
            ofFunction: "attemptPendingRetry", in: source, path: path
        )
        XCTAssertTrue(
            Self.collapsed(attempt).contains("PendingRetryLeaseRenewal.whileRenewing(claim)"),
            "The provider round trip no longer extends the reservation, so a transcription "
            + "longer than the horizon loses the recording it is transcribing."
        )
        let gate = try XCTUnwrap(
            attempt.range(of: "guard await finishPendingRetry(claim) else"),
            "The Chat lane no longer gates on whether the finish was allowed, so an overtaken "
            + "surface sends words another surface has already sent."
        )
        let handOff = try XCTUnwrap(
            attempt.range(of: "sendTurn(recoveredTranscript)"),
            "The Chat hand-off is gone from this lane — update this guard."
        )
        XCTAssertLessThan(gate.upperBound, handOff.lowerBound,
                          "The ownership check must come BEFORE the words go anywhere.")

        let work = try RefusalLaneSource.body(ofFunction: "finishWorkRetry", in: source, path: path)
        let confirm = try XCTUnwrap(
            work.range(of: "PendingRetryStore.shared.confirmOwnership(claim)"),
            "The desk write is attempted on behalf of a capture this surface may no longer hold."
        )
        let recover = try XCTUnwrap(
            work.range(of: "WorkVoiceCaptureCoordinator.recover("),
            "The recovery call is gone from this lane — update this guard."
        )
        XCTAssertLessThan(confirm.upperBound, recover.lowerBound,
                          "Ownership is confirmed BEFORE the words reach the desk, not after.")

        let finish = try RefusalLaneSource.body(
            ofFunction: "finishPendingRetry", in: source, path: path
        )
        XCTAssertTrue(
            Self.collapsed(finish).contains(
                "if retired { PendingRetryGuard.cancelDeferredNotification(for: claim.id) }"
            ),
            "The deferred `Recording Saved` notice is cancelled on a clear that was refused, "
            + "which tells the person a recording is dealt with while another surface is "
            + "still working on it."
        )
        XCTAssertTrue(source.contains("\"pendingRetry.card.busy\""),
                      "A refused hand-off says nothing, so the card just stops responding.")
    }

    /// The macOS window, same two rules.
    func testTheMenuBarRenewsWhileItWorksAndChecksOwnershipBeforeItHandsTheWordsOn() throws {
        let path = "Conduck/MenuBar/DictationService.swift"
        let source = try RefusalLaneSource.source(at: path)

        let attempt = try RefusalLaneSource.body(ofFunction: "attemptRetry", in: source, path: path)
        XCTAssertTrue(
            Self.collapsed(attempt).contains("PendingRetryLeaseRenewal.whileRenewing(claim)"),
            "The provider round trip no longer extends the reservation."
        )
        let gate = try XCTUnwrap(
            attempt.range(of: "guard await settleAfterFinishing(claim) else"),
            "The Chat lane no longer gates on whether the finish was allowed."
        )
        let handOff = try XCTUnwrap(
            attempt.range(of: "onTranscript(trimmed)"),
            "The Chat hand-off is gone from this lane — update this guard."
        )
        XCTAssertLessThan(gate.upperBound, handOff.lowerBound,
                          "The ownership check must come BEFORE the words go anywhere.")

        let work = try RefusalLaneSource.body(ofFunction: "finishWorkRetry", in: source, path: path)
        let confirm = try XCTUnwrap(
            work.range(of: "PendingRetryStore.shared.confirmOwnership(claim)"),
            "The desk write is attempted on behalf of a capture this window may no longer hold."
        )
        let recover = try XCTUnwrap(
            work.range(of: "WorkVoiceCaptureCoordinator.recover("),
            "The recovery call is gone from this lane — update this guard."
        )
        XCTAssertLessThan(confirm.upperBound, recover.lowerBound,
                          "Ownership is confirmed BEFORE the words reach the desk, not after.")

        let settle = try RefusalLaneSource.body(
            ofFunction: "settleAfterFinishing", in: source, path: path
        )
        XCTAssertTrue(
            Self.collapsed(settle).contains(
                "if retired { PendingRetryGuard.cancelDeferredNotification(for: claim.id) }"
            ),
            "The deferred `Recording Saved` notice is cancelled on a clear that was refused."
        )
    }

    /// The discard confirmation says what is actually lost.
    ///
    /// For a Work capture that already published, the recording is a playable
    /// card on the desk and the queue is holding a second copy purely so the
    /// words can be tried again — so "it cannot be recovered" is false, and
    /// false in the direction that stops somebody tidying up.
    func testTheDiscardConfirmationIsStateAwareAboutWhatItActuallyDeletes() throws {
        let cardPath = "Conduck/Views/Components/PendingRetryCard.swift"
        let card = try RefusalLaneSource.source(at: cardPath)
        XCTAssertTrue(card.contains("discardKeepsRecordingInWork"),
                      "The confirmation is the same sentence for every destination, so it "
                      + "promises a published Work recording is gone when Discard removes only "
                      + "the retry copy.")
        XCTAssertTrue(card.contains("\"pendingRetry.card.discard.confirm.body.published\""))
        XCTAssertTrue(card.contains("\"pendingRetry.card.discard.confirm.body\""),
                      "The unpublished / Chat sentence must survive: for those captures the "
                      + "recording really is the only copy.")

        let hostPath = "Conduck/ContentView.swift"
        let host = Self.collapsed(try RefusalLaneSource.source(at: hostPath))
        XCTAssertTrue(
            host.contains(
                "return metadata.resolvedDestination == .work "
                + "&& metadata.publicationState == .published"
            ),
            "The host decides `is this recording already on the desk` from the record's own "
            + "publication verdict; any looser reading tells a Chat user their words are safe "
            + "somewhere they are not."
        )
    }

    // MARK: - Fixtures

    /// Whitespace collapsed to single spaces, so a statement broken across lines
    /// is matched by the same needle as one written on a single line.
    private static func collapsed(_ source: String) -> String {
        source.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func sidecarURL(_ id: UUID) -> URL {
        container.appendingPathComponent(PendingRetryFiles.sidecar(id))
    }

    private func readSidecar(_ id: UUID) throws -> PendingRetrySidecar {
        try JSONDecoder().decode(
            PendingRetrySidecar.self, from: try Data(contentsOf: sidecarURL(id))
        )
    }

    /// Age the reservation out without touching anything else, so the next
    /// `claimNext` may take it — the state a force-quit or a crashed holder
    /// leaves behind.
    private func expire(_ id: UUID) throws {
        let sidecar = try readSidecar(id)
        let lease = try XCTUnwrap(sidecar.lease)
        let lapsed = PendingRetrySidecar(
            metadata: sidecar.metadata,
            lease: PendingRetryLease(
                token: lease.token,
                expiresAt: Date().addingTimeInterval(-1),
                duration: lease.duration
            )
        )
        try JSONEncoder().encode(lapsed).write(to: sidecarURL(id), options: [.atomic])
    }

    private static func metadata(
        at createdAt: Date = Date(),
        destination: PendingRetryDestination = .chat
    ) -> PendingRetryMetadata {
        PendingRetryMetadata(
            id: UUID(),
            createdAt: createdAt,
            audioFileURL: URL(fileURLWithPath: "/dev/null"),
            preferredLanguage: nil,
            attemptCount: 1,
            lastErrorCode: nil,
            destination: destination,
            transcript: nil,
            publicationState: destination == .work ? .phaseOneFailed : nil
        )
    }
}
