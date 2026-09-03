// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// PendingRetrySurfaceHandoffTests.swift
//
// What a RETRY SURFACE does with the queue, in the two ways it can be checked.
//
// The defects this pins are all about a surface treating a queue as a slot. The
// iOS card read the whole queue, took the first entry, reserved nothing and
// showed no count, so a second parked recording was invisible and two surfaces
// could transcribe the same one; the macOS window returned to `.idle` after
// finishing the newest, and `.error` is the only state its popover draws a
// Retry control in, so everything behind that capture became unreachable until
// an unrelated capture failed; and an exempt Work capture — one the desk never
// accepted, which nothing expires — had no way out but discarding every parked
// recording from Settings.
//
// TWO KINDS OF CHECK, because neither reaches the other's half:
//
//   • BEHAVIOURAL, against an isolated `PendingRetryStore`. The sequence a
//     surface performs — reserve one, finish exactly it, ask what is left — is
//     driven end to end over a real directory and a real cross-process lock.
//     What it cannot see is whether the surfaces actually perform it: they are
//     a SwiftUI root and a macOS-only `@Observable` service driving a live
//     `STTClient`, neither constructible here.
//   • SOURCE, over comment-stripped release code. That is where "which store
//     operation does this surface call" and "does the macOS window settle into
//     a state that offers the next tap" are decided, and both are matters of
//     WHERE a statement sits, which no runtime case in this bundle can reach.
//     Same technique and same helpers as `HeadlessRefusalLaneDriftGuardTests`.
//
// The legacy-caller census is the load-bearing source check. Every lease-BLIND
// operation it names — `clear(ifCurrentID:)`, `recordPublicationState(id:)` and
// `updateAttemptIfCurrent(id:)` — reached zero callers and no longer exists on
// the store; `load()` survives only as the control the durability cases measure
// `claimNext` against, and no production file may reach it either. The rows stay
// as guards against the shapes returning: each acts on a capture whether or not
// the caller still holds it, so one caller is one place two surfaces can finish
// the same recording. The census is an EXACT set on both sides: a new legacy
// caller fails it, and so does a listed one that has been migrated, which is
// what stops the allowlist outliving its reasons — every set is now empty, and
// an empty expectation is what a returning caller fails against.

import XCTest
@testable import Conduck

final class PendingRetrySurfaceHandoffTests: XCTestCase {

    private var container: URL!
    private var defaults: InMemoryDefaultsStore!
    private var store: PendingRetryStore!

    override func setUp() {
        super.setUp()
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("retry-surface-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - The sequence a surface performs

    /// r5a#4, behaviourally. Two captures are waiting; the surface finishes the
    /// one it was offered. What must be true afterwards is everything the card
    /// and the macOS window read to decide whether they still offer a retry: the
    /// count is one lower and NOT zero, and the next tap is offered the OTHER
    /// capture with its own bytes.
    ///
    /// On the old code the count did not exist — `hasPending()` answered a
    /// boolean, the card showed no number, and `DictationService` set `.idle`
    /// after a terminal finish, which is the state its popover draws no audio
    /// Retry in. Nothing here could be spelled against it.
    func testFinishingOneOfTwoLeavesTheSurfaceRetryCapableWithTheCountDecremented() async throws {
        let older = Self.metadata(at: Date().addingTimeInterval(-120), destination: .work)
        let newer = Self.metadata(at: Date(), destination: .work)
        try await store.save(audioData: Data("older".utf8), metadata: older, workImageData: nil)
        try await store.save(audioData: Data("newer".utf8), metadata: newer, workImageData: nil)

        let claimed = await store.claimNext()
        let offered = try XCTUnwrap(claimed, "two captures are waiting")
        XCTAssertEqual(offered.id, newer.id, "the queue is offered newest first")

        let cleared = await store.clear(offered)
        XCTAssertTrue(cleared, "the holder finishes its own capture")

        let remaining = await store.pendingCount()
        XCTAssertEqual(
            remaining, 1,
            """
            A terminal finish must leave the surface retry-capable when anything \
            is still waiting. This is the number the card renders and the number \
            `DictationService` settles its state on; reading it as zero is how \
            the second recording became unreachable.
            """
        )

        let offeredNext = await store.claimNext()
        let next = try XCTUnwrap(
            offeredNext,
            "the capture behind the finished one is offered to the next tap"
        )
        XCTAssertEqual(next.id, older.id)
        XCTAssertEqual(next.entry.audioData, Data("older".utf8), "with its OWN recording")
    }

    /// The other half of the same rule: a surface that gives its reservation
    /// back leaves the capture immediately takeable, rather than parked for the
    /// ten minutes the lease would otherwise run. Every outcome in
    /// `ContentView.attemptPendingRetry` and `DictationService.attemptRetry`
    /// that leaves the capture waiting reaches `release`.
    func testAReleasedCaptureIsOfferedAgainAtOnceAndIsStillCounted() async throws {
        let waiting = Self.metadata(destination: .chat)
        try await store.save(audioData: Data("waiting".utf8), metadata: waiting, workImageData: nil)

        let firstClaim = await store.claimNext()
        let first = try XCTUnwrap(firstClaim)
        await store.release(first)

        let stillWaiting = await store.pendingCount()
        XCTAssertEqual(stillWaiting, 1, "releasing finishes nothing")
        let secondClaim = await store.claimNext()
        let second = try XCTUnwrap(
            secondClaim,
            "a released capture is takeable at once, not after the lease lapses"
        )
        XCTAssertEqual(second.id, waiting.id)
        XCTAssertNotEqual(second.token, first.token, "and the next holder gets its own token")
    }

    /// The control that says why the release matters, and the exact state the
    /// surfaces' "Another window is finishing this recording" sentence
    /// describes: a reservation nobody handed back leaves a capture that is
    /// still WAITING — so the card stays up — and unclaimable, so the next tap
    /// finds nothing. A surface that dropped the release on one of its refusal
    /// paths would strand its own recording exactly this way.
    func testAnUnreleasedReservationLeavesACaptureCountedButUnclaimable() async throws {
        let waiting = Self.metadata(destination: .chat)
        try await store.save(audioData: Data("waiting".utf8), metadata: waiting, workImageData: nil)

        let held = await store.claimNext()
        _ = try XCTUnwrap(held)

        let counted = await store.pendingCount()
        XCTAssertEqual(counted, 1, "it is still waiting")
        let offeredAgain = await store.claimNext()
        XCTAssertNil(
            offeredAgain,
            "and no second surface may take it, which is what the busy sentence says"
        )
    }

    // MARK: - Discard (O-16)

    /// The discard affordance, behaviourally: it takes the capture the card is
    /// offering and removes EXACTLY that one — its record, its recording and its
    /// screenshot — leaving every other waiting capture byte-identical.
    ///
    /// `clear()` (discard everything) is the operation this must not be: it
    /// would also delete a capture another surface is in the middle of
    /// finishing, and the person asked to be rid of one recording.
    func testDiscardingTheOfferedCaptureRemovesExactlyThatOne() async throws {
        let keep = Self.metadata(at: Date().addingTimeInterval(-120), destination: .work)
        let discard = Self.metadata(at: Date(), destination: .work)
        try await store.save(audioData: Data("keep".utf8), metadata: keep, workImageData: nil)
        try await store.save(
            audioData: Data("discard".utf8),
            metadata: discard,
            workImageData: Data("picture".utf8)
        )

        let claimed = await store.claimNext()
        let offered = try XCTUnwrap(claimed)
        XCTAssertEqual(offered.id, discard.id)
        let discarded = await store.clear(offered)
        XCTAssertTrue(discarded)

        let remaining = await store.pendingCount()
        XCTAssertEqual(remaining, 1, "exactly one capture left")
        let survivorClaim = await store.claimNext()
        let survivor = try XCTUnwrap(survivorClaim)
        XCTAssertEqual(survivor.id, keep.id)
        XCTAssertEqual(survivor.entry.audioData, Data("keep".utf8))

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: container.appendingPathComponent(
                    PendingRetryFiles.audio(discard.id, .work)
                ).path
            ),
            "the discarded recording is gone from the device"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: container.appendingPathComponent(
                    PendingRetryFiles.workImage(discard.id)
                ).path
            ),
            "and so is its screenshot"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: container.appendingPathComponent(
                    PendingRetryFiles.audio(keep.id, .work)
                ).path
            ),
            "the recording nobody discarded is untouched"
        )
    }

    // MARK: - The legacy-caller census (r5a#5)

    /// No production code may still reach this store through an operation that
    /// cannot tell whether its caller holds the capture.
    ///
    /// EXACT SETS, both directions. A file that starts calling one of these
    /// fails; so does a file listed here that has stopped, because an allowlist
    /// that outlives its reasons is how the next reviewer concludes the
    /// migration is incomplete when it is done.
    ///
    /// KNOWN LIMIT, stated rather than implied: the needles are literal call
    /// text, so a caller that first binds the store to a local (`let queue =
    /// PendingRetryStore.shared; await queue.load()`) is invisible to them. The
    /// two ways production code actually reaches this store are the singleton
    /// and `InAppAudioRecorder`'s injected `retryLane`, and both are covered.
    func testNoProductionCallerRemainsOnTheSupersededQueueOperations() throws {
        let expected: [String: Set<String>] = [
            // Read EVERY parked recording into memory and reserve none of them.
            // Zero callers: both retry surfaces select through `claimNext`.
            "PendingRetryStore.shared.load()": [],
            "retryLane.load()": [],

            // Finish a capture without holding it. Zero callers: the three
            // arming lanes — `PendingRetryGuard`, `InAppAudioRecorder` and the
            // Shortcuts intent — reserve the capture they minted with
            // `claim(id:duration:)` and finish it through `clear(_ claim:)`.
            // The operation itself is gone; the row keeps the shape from coming
            // back under its old name.
            "clear(ifCurrentID:": [],

            // Count an attempt against a capture without holding it. The
            // operation itself is gone; this row keeps the shape from coming
            // back under its old name.
            "updateAttemptIfCurrent(": [],

            // Write a verdict about a capture without holding it. Gone for the
            // same reason: the intent process holds a reservation over the
            // capture it minted, so its verdict is token-checked.
            "recordPublicationState(id:": [],
        ]

        var actual: [String: Set<String>] = expected.mapValues { _ in [] }
        // The store itself is scanned like every other production file: it no
        // longer DECLARES any of these, so there is nothing here to exempt, and
        // a call to one from inside the store would be as lease-blind as a call
        // from anywhere else.
        for path in try Self.productionSwiftPaths() {
            let source = Self.callText(
                RefusalLaneSource.stripComments(
                    try String(contentsOf: RefusalLaneSource.projectContainerURL
                        .appendingPathComponent(path), encoding: .utf8)
                )
            )
            for needle in expected.keys where source.contains(needle) {
                actual[needle, default: []].insert(path)
            }
        }

        for (needle, files) in expected {
            XCTAssertEqual(
                actual[needle] ?? [], files,
                """
                `\(needle)` is superseded by the claim API and is lease-BLIND — it \
                acts on a capture whether or not the caller still holds it. \
                Expected exactly \(files.sorted()), found \((actual[needle] ?? []).sorted()). \
                A new entry is a place two surfaces can finish the same recording; \
                a missing one means this allowlist and its reasons are stale.
                """
            )
        }
    }

    /// Rule 0 for the census: the scan actually reads production sources and the
    /// needles actually match call text. Without it a broken path derivation or
    /// a comment stripper that ate the file would report a clean migration.
    func testTheCensusScanReachesProductionSourceAndItsNeedlesMatch() throws {
        let paths = try Self.productionSwiftPaths()
        XCTAssertGreaterThan(paths.count, 300,
                             "The production scan found \(paths.count) files; the path derivation is broken.")
        XCTAssertTrue(paths.contains(Self.storePath))
        XCTAssertFalse(paths.contains { $0.contains("Tests") },
                       "Test sources must stay out: they may drive the superseded API deliberately.")

        // The needles are matched against whitespace-collapsed, comment-stripped
        // text, so a call broken across lines still reads as one.
        let sample = Self.callText(RefusalLaneSource.stripComments("""
        _ = await PendingRetryStore.shared.recordPublicationState(
            id: captureID,
            transcript: nil,
            publicationState: .published
        )
        """))
        XCTAssertTrue(sample.contains("recordPublicationState(id:"))
        // …and the CLAIM form is not mistaken for it.
        let claimForm = Self.callText(RefusalLaneSource.stripComments("""
        _ = await queue.recordPublicationState(
            claim, transcript: nil, publicationState: .published
        )
        """))
        XCTAssertFalse(claimForm.contains("recordPublicationState(id:"))
    }

    // MARK: - The surfaces' shape

    /// The iOS card selects through the claim API, hands the reservation back on
    /// every outcome that leaves the capture waiting, and re-reads the count
    /// after the one outcome that finishes it.
    ///
    /// `runPendingRetry` holds the whole rule in three statements, and the check
    /// is that those three are what it holds: without the single `release` after
    /// `attemptPendingRetry`, each refusal path would have to remember it, which
    /// is exactly the duty the old code got wrong.
    func testTheCardSelectsReservesAndCountsThroughTheClaimAPI() throws {
        let path = "Conduck/ContentView.swift"
        let source = try RefusalLaneSource.source(at: path)

        let run = try RefusalLaneSource.body(ofFunction: "runPendingRetry", in: source, path: path)
        XCTAssertTrue(run.contains("PendingRetryStore.shared.claimNext()"),
                      "The card no longer RESERVES the capture it retries, so the menu bar or a "
                      + "Shortcut host can transcribe and finish the same recording beside it.")
        XCTAssertTrue(run.contains("attemptPendingRetry(claim) == false"),
                      "The one place the reservation is handed back is gone; each refusal path "
                      + "now has to remember it, and one of them will not.")
        XCTAssertTrue(run.contains("PendingRetryStore.shared.release(claim)"),
                      "Nothing releases the reservation, so a refused retry parks its own "
                      + "recording for the whole lease.")

        let finish = try RefusalLaneSource.body(ofFunction: "finishPendingRetry", in: source, path: path)
        XCTAssertTrue(finish.contains("PendingRetryStore.shared.clear(claim)"),
                      "A finish that does not go through the claim can retire a capture this "
                      + "surface no longer holds.")
        XCTAssertTrue(finish.contains("PendingRetryGuard.cancelDeferredNotification(for: claim.id)"),
                      "The deferred `Recording Saved` notice survives the capture it announces.")
        XCTAssertTrue(finish.contains("PendingRetryStore.shared.pendingCount()"),
                      "The card no longer re-reads the count after finishing one, so a card left "
                      + "standing for the NEXT capture reads as a retry that failed.")

        // The reservation is taken when the button is tapped, BEFORE the
        // confirmation is raised, so the dialog is bound to one exact capture;
        // the confirmed delete then acts on the reservation it was raised
        // about rather than re-selecting against a queue that may have moved.
        let offer = try RefusalLaneSource.body(
            ofFunction: "offerPendingRetryDiscard", in: source, path: path
        )
        XCTAssertTrue(offer.contains("PendingRetryStore.shared.claimNext()"),
                      "Discard must take the same reservation a retry does, or it deletes a "
                      + "capture another surface is finishing.")
        XCTAssertTrue(offer.contains("confirmingPendingRetryDiscard = true"),
                      "The confirmation is raised without a reservation, so the question is "
                      + "asked about no capture in particular.")

        let discard = try RefusalLaneSource.body(ofFunction: "discardPendingRetry", in: source, path: path)
        XCTAssertTrue(discard.contains("pendingRetryDiscard"),
                      "Discard must act on the reservation the confirmation was raised about, "
                      + "not on whatever the queue would hand it now.")
        XCTAssertTrue(discard.contains("finishPendingRetry(claim)"),
                      "Discard must retire exactly the claimed capture.")
        XCTAssertFalse(discard.contains("PendingRetryStore.shared.claimNext()"),
                       "Selecting at confirmation time re-answers `which capture` against a "
                       + "queue that may have changed while the dialog was on screen.")
        XCTAssertFalse(discard.contains("PendingRetryStore.shared.clear()"),
                       "`clear()` discards EVERY parked recording. The person asked to be rid of one.")

        // `true` is the surface's word for "the entry is retired", and exactly
        // one statement may say it — the one after the finish.
        let attempt = try RefusalLaneSource.body(ofFunction: "attemptPendingRetry", in: source, path: path)
        let claimsFinished = attempt.components(separatedBy: "return true").count - 1
        XCTAssertEqual(claimsFinished, 1,
                       "Only the path that actually retired the entry may report the capture "
                       + "finished; any other `return true` skips the release AND the clear.")
        let finished = try XCTUnwrap(attempt.range(of: "return true"))
        let finishCall = try XCTUnwrap(
            attempt.range(of: "await finishPendingRetry(claim)"),
            "The Chat lane no longer retires the entry before handing the words on."
        )
        XCTAssertLessThan(finishCall.upperBound, finished.lowerBound,
                          "The entry must be retired BEFORE the capture is reported finished.")
    }

    /// The macOS window's backlog state — r5a#4's other half.
    ///
    /// `.error` is the only state `DictationPopoverView` draws an audio Retry
    /// control in, so a terminal finish that returns to `.idle` with captures
    /// still waiting makes every one of them unreachable until an unrelated
    /// capture fails. The state is settled in ONE place, and the check is that
    /// the place still asks the queue what is left before choosing.
    func testTheMenuBarSettlesIntoAStateThatOffersTheNextTap() throws {
        let path = "Conduck/MenuBar/DictationService.swift"
        let source = try RefusalLaneSource.source(at: path)

        let settle = try RefusalLaneSource.body(
            ofFunction: "settleAfterFinishing", in: source, path: path
        )
        XCTAssertTrue(settle.contains("PendingRetryStore.shared.clear(claim)"),
                      "The finish no longer retires exactly the capture this window held.")
        XCTAssertTrue(settle.contains("PendingRetryGuard.cancelDeferredNotification(for: claim.id)"))
        XCTAssertTrue(settle.contains("await refreshPendingRetryCount()"),
                      "Nothing re-reads the queue after the finish, so the state below is chosen "
                      + "from a count taken before this capture left it.")

        let idle = try XCTUnwrap(
            settle.range(of: "state = .idle"),
            "The window never returns to idle, so a finished queue keeps offering a retry."
        )
        let backlog = try XCTUnwrap(
            settle.range(of: "state = .error("),
            "The window returns to idle with captures still waiting — the popover draws its "
            + "audio Retry only in `.error`, so everything behind the finished capture becomes "
            + "unreachable until an unrelated capture fails."
        )
        let gate = try XCTUnwrap(
            settle.range(of: "guard pendingRetryCount > 0 else"),
            "The idle/backlog choice is no longer gated on what is left in the queue."
        )
        XCTAssertLessThan(gate.upperBound, idle.lowerBound,
                          "Idle belongs INSIDE the guard's else — it is the answer for an empty queue.")
        XCTAssertLessThan(idle.upperBound, backlog.lowerBound,
                          "The backlog state must be the one reached when captures remain.")

        let retry = try RefusalLaneSource.body(ofFunction: "retryLast", in: source, path: path)
        XCTAssertTrue(retry.contains("PendingRetryStore.shared.claimNext()"),
                      "The menu bar no longer reserves the capture it retries.")
        XCTAssertTrue(retry.contains("attemptRetry(claim) == false"))
        XCTAssertTrue(retry.contains("PendingRetryStore.shared.release(claim)"),
                      "Nothing releases the reservation on a refusal, so this window parks its "
                      + "own recording for the whole lease.")
    }

    /// The card says how many are waiting and offers a confirmed way out.
    ///
    /// The count is rendered only ABOVE one: at exactly one the headline already
    /// says a recording is waiting. The discard is confirmed because a Work
    /// capture the desk never accepted is exempt from expiry — those bytes are
    /// the only copy of what somebody said, and this is the one affordance that
    /// deletes them on purpose.
    func testTheCardShowsTheBacklogAndConfirmsTheDiscard() throws {
        let path = "Conduck/Views/Components/PendingRetryCard.swift"
        let source = try RefusalLaneSource.source(at: path)

        XCTAssertTrue(source.contains("pendingCount > 1"),
                      "The card renders the count unconditionally or not at all; at exactly one "
                      + "it repeats the headline, and at zero the card is not on screen.")
        XCTAssertTrue(source.contains("pendingRetry.card.count"))
        XCTAssertTrue(source.contains("pendingRetry.card.discard"))
        XCTAssertTrue(source.contains("confirmationDialog"),
                      "The discard is unconfirmed. It deletes the only copy of a recording.")
        XCTAssertTrue(source.contains("pendingRetry.card.discard.confirm.body"),
                      "The confirmation no longer says the recording cannot be recovered.")
        XCTAssertTrue(source.contains("role: .destructive"))
        XCTAssertTrue(source.contains("onDiscard()"),
                      "The confirmed action no longer reaches the host, so Discard does nothing.")
    }

    // MARK: - Fixtures

    /// `.../Conduck` relative paths of every SHIPPING Swift source, tests
    /// excluded.
    private static func productionSwiftPaths() throws -> Set<String> {
        let root = RefusalLaneSource.projectContainerURL
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var paths: Set<String> = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let path = url.path.replacingOccurrences(of: root.path + "/", with: "")
            guard !path.contains("Tests") else { continue }
            paths.insert(path)
        }
        return paths
    }

    private static let storePath = "Conduck/Services/PendingRetryStore.swift"

    /// Call text with every run of whitespace collapsed to one space and the
    /// space after an opening parenthesis removed, so a call broken across lines
    /// is matched by the same needle as a call written on one. Without it a
    /// reformat — the kind an editor does silently — retires the census.
    private static func callText(_ source: String) -> String {
        source
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .replacingOccurrences(of: "( ", with: "(")
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
            publicationState: nil
        )
    }
}
