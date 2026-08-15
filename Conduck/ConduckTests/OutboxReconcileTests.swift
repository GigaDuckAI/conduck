// SPDX-License-Identifier: Apache-2.0

// Conduck
// OutboxReconcileTests.swift
//
// Locks the AUTOMATIC output lane end to end, at the one seam where it is pure:
// `FileTransferOutputDetector.reconcileOutbox` — one listing of one per-dispatch
// folder, turned into chips and a close decision.
//
// THE PROPERTY THIS FILE EXISTS FOR, and the one whose failure is invisible in
// production: the three listing verdicts are never conflated. `.entries([])`
// (the folder is there and holds nothing), `.absent` (the folder is not there)
// and `.unusable` (the app learned nothing) produce zero chips alike, so a
// collapse between them shows up only as a turn closed on evidence nobody has —
// permanently, because closing is permanent.
//
// R1 wording, deliberately asserted here rather than left to the UI: `.absent`
// is the ORDINARY outcome of a reply that produced nothing, because nothing
// creates the folder in advance. It closes on the same age ladder as an empty
// folder and surfaces nothing. Only `.unusable` is a fault.
//
// A FOURTH conflation lives one level inside `.entries` and has the same shape:
// a folder holding only names the outbound gate refuses yields the same drafts,
// the same close decision and the same verdict as a folder holding nothing.
// `refusedEntryCount` is what separates them, and the cases below pin it to the
// LISTING rather than to the delivery walk — that walk stops at the message's
// remaining chip allowance and never starts when the allowance is spent, so a
// count taken inside it under-reports precisely when the folder is fullest.
//
// The listing itself is injected, so every case runs with no network, no Core
// Data and no Keychain. Synthetic keys and filenames only; nothing is logged.
//
// IT ALSO COVERS WHAT THE USER IS TOLD ABOUT THAT LISTING, because the two are
// one decision and the failure mode is the same shape: the age gate that keeps
// the AUTOMATIC pass from closing a turn early has no business deciding what a
// user who just tapped is told, the manual verbs must not be offered where they
// cannot run, and an answer that a later pass has overtaken must stop being
// shown. Those predicates are pure statics on the view model, so they test here
// alongside the reconciliation that feeds them.
//
// And the post-tap preview build, which is the one piece of this lane that
// touches real bytes: it must hand the main actor back while it reads and
// decodes.

import XCTest
@testable import Conduck

/// A main-actor flag a queued heartbeat can set. `@MainActor` makes it Sendable,
/// so the heartbeat task can capture it without a mutable-capture race.
@MainActor
private final class MainActorHeartbeat {
    var didRun = false
}

final class OutboxReconcileTests: XCTestCase {

    // MARK: - Fixtures

    private let boxKey = "1F2E3D4C-5B6A-7890-ABCD-EF0123456789/out-\(String(repeating: "a", count: 32))"
    private let created = Date(timeIntervalSince1970: 1_000_000)

    private var pastGrace: Date {
        created.addingTimeInterval(FileTransferOutputDetector.outputScanGrace + 1)
    }
    private var pastHorizon: Date {
        created.addingTimeInterval(FileTransferOutputDetector.truncatedScanHorizon + 1)
    }

    private func snapshot() -> SettingsManager.FileTransferSnapshot {
        SettingsManager.FileTransferSnapshot(
            baseURL: URL(string: "https://files.example.test/")!,
            username: "conduck",
            credential: "secret",
            certFingerprintHex: nil,
            available: true,
            folderCapable: true
        )
    }

    private func entry(_ name: String, bytes: Int = 0, isDirectory: Bool = false) -> FileServerEntry {
        FileServerEntry(name: name, isDirectory: isDirectory, byteSize: bytes)
    }

    /// Run one reconciliation against a canned verdict.
    private func reconcile(
        _ verdict: FileServerListingVerdict,
        excludedKeys: Set<String> = [],
        scanStartedAt: Date? = nil
    ) async -> FileTransferOutputDetector.OutboxReconciliation {
        var requestedKeys: [String] = []
        let result = await FileTransferOutputDetector.reconcileOutbox(
            outboxKey: boxKey,
            snapshot: snapshot(),
            excludedKeys: excludedKeys,
            turnCreatedAt: created,
            scanStartedAt: scanStartedAt ?? pastGrace,
            list: { _, key in
                requestedKeys.append(key)
                return verdict
            }
        )
        XCTAssertEqual(requestedKeys, [boxKey],
                       "exactly ONE listing, of exactly the folder this dispatch named")
        return result
    }

    // MARK: - The three verdicts are never conflated

    /// An empty folder past the grace window is the ordinary "nothing this turn"
    /// answer: it closes the turn and says nothing to the user.
    func testEmptyFolderPastGraceClosesSilently() async {
        let result = await reconcile(.entries([]))
        XCTAssertTrue(result.drafts.isEmpty)
        XCTAssertTrue(result.conclusive, "a folder the server read out clean is a real answer")
        XCTAssertEqual(result.verdict, .entries([]))
    }

    /// An ABSENT folder is the SAME ordinary answer, not an error. Nothing
    /// creates the folder in advance, so a `404` is what a reply with no output
    /// looks like — and it conflates "produced nothing", "ignored the
    /// instruction", "a mkdir failed" and "wrote somewhere else", which is
    /// exactly why it can never be reported as a claim about the agent.
    func testAbsentFolderPastGraceClosesLikeAnEmptyOne() async {
        let absent = await reconcile(.absent)
        let empty = await reconcile(.entries([]))
        XCTAssertEqual(absent.conclusive, empty.conclusive,
                       "a missing folder and an empty one are the same non-event")
        XCTAssertTrue(absent.drafts.isEmpty)
        XCTAssertEqual(absent.verdict, .absent,
                       "the verdict stays distinguishable even though the outcome is identical")
    }

    /// Inside the grace window nothing closes, whatever the folder said — a file
    /// that lands a second after the reply must not be lost to a listing that
    /// arrived a beat too early.
    func testNothingClosesInsideTheGraceWindow() async {
        for verdict in [FileServerListingVerdict.entries([]), .absent] {
            let result = await reconcile(verdict, scanStartedAt: created)
            XCTAssertFalse(result.conclusive,
                           "an instant listing cannot permanently close a turn")
        }
    }

    /// AN UNREADABLE SERVER NEVER CLOSES A TURN, at any age. This is the
    /// collapse the verdict type exists to prevent: an unusable listing reading
    /// as "the agent produced nothing" would close the turn on evidence nobody
    /// has, and closing is permanent.
    func testUnusableNeverClosesTheTurnAtAnyAge() async {
        let refusals: [FileTransferListingRefusal] = [
            .transport, .unauthorized, .serverError, .notMultiStatus,
            .malformedBody, .bodyTooLarge, .tooManyEntries,
            .entryOutsideCollection, .duplicateEntry, .namespaceAnswersEverything
        ]
        for refusal in refusals {
            let result = await reconcile(.unusable(refusal), scanStartedAt: pastHorizon)
            XCTAssertFalse(result.conclusive, "\(refusal) must never close a turn")
            XCTAssertTrue(result.drafts.isEmpty)
        }
    }

    // MARK: - Entries become chips, under the type gate

    /// The happy path: every entry becomes a server-reference draft keyed inside
    /// the folder, so the thread can tell this reply's output from a file found
    /// anywhere else on the server.
    func testEntriesBecomeDraftsKeyedInsideTheFolder() async {
        let result = await reconcile(.entries([
            entry("report.pdf", bytes: 4096),
            entry("data.csv", bytes: 12)
        ]))
        XCTAssertEqual(result.drafts.map(\.storedKey),
                       ["\(boxKey)/report.pdf", "\(boxKey)/data.csv"])
        XCTAssertEqual(result.drafts.map(\.filename), ["report.pdf", "data.csv"])
        XCTAssertEqual(result.drafts.map(\.byteSize), [4096, 12])
        XCTAssertTrue(result.drafts.allSatisfy(\.isServerReference))
        XCTAssertEqual(result.drafts.first?.mimeType, "application/pdf",
                       "the chip is labelled from the name, not from anything the server said")
        XCTAssertTrue(result.conclusive)
    }

    /// The outbound TYPE gate. An entry Conduck is unwilling to address is not
    /// delivered — and it is REJECTED, never repaired, because a cleaned name is
    /// a key that no longer exists on the server.
    ///
    /// The two names with spaces in them are the point of the fixture as much as
    /// the refusals are: the gate's job is a NAME POLICY, not an alphabet, so a
    /// filename a person would recognise rides all the way to a draft while the
    /// things that would actually break something do not.
    func testDisallowedAndHostileEntryNamesAreRejectedNotRepaired() async {
        let result = await reconcile(.entries([
            entry("keys.sqlite"),            // sensitive, off the allowlist
            entry("profile.mobileconfig"),   // off the allowlist
            entry("README"),                 // extensionless
            entry(".hidden.txt"),            // leading dot
            entry("-rf.txt"),                // reads as a CLI option
            entry("pay$load.txt"),           // still special inside the quotes the key rides in
            entry("nested/inner.txt"),       // not a single component
            entry("my report.txt"),          // an ordinary human filename — DELIVERED
            entry("Übersicht.md"),           // and so is this one
            entry("keep.txt")
        ]))
        XCTAssertEqual(result.drafts.map(\.filename), ["my report.txt", "Übersicht.md", "keep.txt"],
                       "a space and a diacritic are filenames, not attacks")
        XCTAssertEqual(result.drafts.map(\.storedKey),
                       ["\(boxKey)/my report.txt", "\(boxKey)/Übersicht.md", "\(boxKey)/keep.txt"],
                       "and the key keeps the server's own bytes — a repaired one addresses nothing")
        // THE PARTIAL CASE, and the reason the census is not simply "delivered
        // nothing": some files land and seven do not, and the chips that appear
        // are exactly what makes the folder look settled. Uncounted, those seven
        // are as invisible here as they are in a folder that delivered nothing
        // at all.
        XCTAssertEqual(result.refusedEntryCount, 7)
    }

    /// A folder the gate refuses ENTIRELY answers `.entries` and hands over
    /// nothing — the same two fields an EMPTY folder produces. The census is the
    /// only thing that separates them, and separating them is what keeps "a
    /// reply naming a file over a thread showing none" from being a silence the
    /// user cannot interrogate.
    func testAFolderRefusedInFullIsCountedRatherThanSilent() async {
        let refused = await reconcile(.entries([
            entry("keys.sqlite"),
            entry("profile.mobileconfig"),
            entry("README")
        ]))
        let empty = await reconcile(.entries([]))
        XCTAssertEqual(refused.drafts.count, empty.drafts.count)
        XCTAssertEqual(refused.conclusive, empty.conclusive,
                       "the two are indistinguishable in every other field, which is the point")
        XCTAssertEqual(refused.refusedEntryCount, 3)
        XCTAssertEqual(empty.refusedEntryCount, 0,
                       "an empty folder refused nothing — a count here would invent a claim")
    }

    /// A directory inside the folder is not a file to hand over.
    func testDirectoryEntriesAreNotDelivered() async {
        let result = await reconcile(.entries([
            entry("scratch", isDirectory: true),
            entry("out.txt")
        ]))
        XCTAssertEqual(result.drafts.map(\.filename), ["out.txt"])
        // …and it is not a file WITHHELD either. `scratch` is extensionless, so
        // the name gate would refuse it outright were it a file; counting it
        // would report a refusal to a user whose folder is behaving perfectly.
        XCTAssertEqual(result.refusedEntryCount, 0)
    }

    /// An entry already chipped on the message is not a refusal. Its storedKey
    /// exists only because a validated name produced it, so it PASSED this gate
    /// on an earlier pass and is dropped now for being a duplicate. Counting it
    /// would fire the caption on the commonest re-check there is: a second look
    /// at a folder that already delivered.
    func testAnAlreadyDeliveredEntryIsNotCountedAsARefusal() async {
        let result = await reconcile(
            .entries([entry("report.pdf"), entry("keys.sqlite")]),
            excludedKeys: ["\(boxKey)/report.pdf"]
        )
        XCTAssertTrue(result.drafts.isEmpty,
                      "the one deliverable entry is already on the message")
        XCTAssertEqual(result.refusedEntryCount, 1, "the sqlite, and only the sqlite")
    }

    /// THE CENSUS IS OF THE LISTING, NOT OF THE DELIVERY. The loop that mints
    /// drafts `break`s at the message's remaining allowance and is skipped
    /// outright when that allowance is zero, so a count taken inside it reports a
    /// number that shrinks exactly as the folder gets fuller — under-reporting
    /// hardest in the case the user most needs told.
    func testTheRefusalCensusIsUnaffectedByTheDeliveryBudget() async {
        // A message at its lifetime ceiling: the budget is zero and the loop
        // never runs at all.
        let full = Set((1...FileTransferOutputDetector.maxOutputChipsPerMessage)
            .map { "\(boxKey)/have\($0).txt" })
        let atCeiling = await reconcile(
            .entries([entry("keys.sqlite"), entry("profile.mobileconfig")]),
            excludedKeys: full
        )
        XCTAssertTrue(atCeiling.drafts.isEmpty)
        XCTAssertEqual(atCeiling.refusedEntryCount, 2,
                       "a pass that may deliver nothing still read the folder")

        // A TRUNCATED pass: the loop stops at the cap, so a refusal sitting past
        // the cut is never reached by the delivery walk.
        let filled = (1...FileTransferOutputDetector.maxOutboxEntriesPerReply)
            .map { entry("f\($0).txt") }
        let truncated = await reconcile(
            .entries(filled + [entry("tail.sqlite"), entry("late.txt")])
        )
        XCTAssertEqual(truncated.drafts.count,
                       FileTransferOutputDetector.maxOutboxEntriesPerReply)
        XCTAssertEqual(truncated.refusedEntryCount, 1,
                       "the refusal past the cut is still in the folder being asked about")
    }

    // MARK: - The walk

    /// Keys already on the message fall out BEFORE the cap, so a re-list neither
    /// duplicates a chip nor lets an existing one eat a slot and stall the walk.
    func testAlreadyChippedKeysAreDroppedBeforeTheCap() async {
        let names = (1...FileTransferOutputDetector.maxOutboxEntriesPerReply)
            .map { "f\($0).txt" }
        let result = await reconcile(
            .entries(names.map { entry($0) } + [entry("late.txt")]),
            excludedKeys: ["\(boxKey)/f1.txt"]
        )
        XCTAssertFalse(result.drafts.contains { $0.filename == "f1.txt" })
        XCTAssertTrue(result.drafts.contains { $0.filename == "late.txt" },
                      "dropping a delivered key exposes the entry the last pass could not reach")
    }

    /// A folder holding more than one pass may deliver reports itself TRUNCATED,
    /// which holds the turn open on the long horizon rather than closing it and
    /// losing the tail forever.
    func testOverfullFolderStaysOpenOnTheLongHorizon() async {
        let names = (1...(FileTransferOutputDetector.maxOutboxEntriesPerReply + 1))
            .map { "f\($0).txt" }
        let cut = await reconcile(.entries(names.map { entry($0) }))
        XCTAssertEqual(cut.drafts.count, FileTransferOutputDetector.maxOutboxEntriesPerReply)
        XCTAssertFalse(cut.conclusive,
                       "a pass that did not hand over everything it saw may not close the turn")

        let later = await reconcile(
            .entries(names.map { entry($0) }),
            scanStartedAt: pastHorizon
        )
        XCTAssertTrue(later.conclusive, "the extended window is a horizon, not 'forever'")
    }

    /// The message's LIFETIME ceiling bounds the walk: a pass may only deliver
    /// the remaining allowance, so repeated passes can never mint unbounded chips
    /// from a folder someone keeps refilling.
    func testTheMessageCeilingBoundsWhatOnePassMayDeliver() async {
        let used = FileTransferOutputDetector.maxOutputChipsPerMessage - 2
        let already = Set((1...used).map { "\(boxKey)/have\($0).txt" })
        let result = await reconcile(
            .entries((1...5).map { entry("new\($0).txt") }),
            excludedKeys: already
        )
        XCTAssertEqual(result.drafts.count, 2, "only the remaining allowance may be delivered")
        XCTAssertFalse(result.conclusive)
    }

    // MARK: - Missing metadata means UNKNOWN, never EMPTY

    /// THE load-bearing invariant of the whole design, asserted at the selection
    /// seam because that is where it is enforced: a row carrying a lane but no
    /// folder — a wrist turn on a device that has not synced the attribute yet, a
    /// lane that cannot hold a nested collection, a dispatch whose freshness was
    /// never witnessed — is selected OUT of the pass. It is never closed, because
    /// closing it would make "we have not been told yet" permanently
    /// indistinguishable from "there was nothing".
    @MainActor
    func testARowWithNoFolderIsSelectedOutRatherThanClosed() {
        let lane = String(repeating: "a", count: 64)
        let noBox = MessageRecord(
            id: UUID(),
            role: "agent",
            text: "Here is the summary.",
            createdAt: created,
            sourceDevice: "watch",
            outputScanDone: false,
            outputScanLaneID: lane,
            outputBoxKey: nil
        )
        XCTAssertTrue(
            ConversationDetailViewModel.retroScanCandidates(
                in: [noBox], attempted: [], cap: 20
            ).isEmpty,
            "no folder means no listing — and no marker either"
        )
        XCTAssertEqual(noBox.outputScanDone, false,
                       "the row stays PENDING: unknown, not empty")
        XCTAssertFalse(ConversationDetailViewModel.canRecheckOutputs(noBox),
                       "there is no folder for a tap to re-read either — the name search covers it")
    }

    /// The complete row IS selected, so the clause above narrows the pass rather
    /// than emptying it.
    @MainActor
    func testARowWithBothHalvesIsSelected() {
        let lane = String(repeating: "a", count: 64)
        let complete = MessageRecord(
            id: UUID(),
            role: "agent",
            text: "Here is the summary.",
            createdAt: created,
            sourceDevice: "mac",
            outputScanDone: false,
            outputScanLaneID: lane,
            outputBoxKey: boxKey
        )
        XCTAssertEqual(
            ConversationDetailViewModel.retroScanCandidates(
                in: [complete], attempted: [], cap: 20
            ).map(\.id),
            [complete.id]
        )
        XCTAssertTrue(ConversationDetailViewModel.canRecheckOutputs(complete))
    }

    // MARK: - What the USER's tap reports

    /// THE SEPARATION THIS SECTION EXISTS FOR: `conclusive` answers "may this
    /// pass permanently close the turn", and it folds in the age gate that keeps
    /// a listing fired a beat after the reply from closing a turn forever. What a
    /// user who just tapped is told is a different question, and the answer is
    /// whatever the server said. Wire the caption to `conclusive` and the common
    /// case — an impatient tap on a fresh reply, against a server that answered
    /// perfectly — reports "couldn't finish the check just now", i.e. a fault
    /// that did not happen.
    @MainActor
    func testATapInsideTheGraceWindowReportsTheServersAnswer() async {
        for verdict in [FileServerListingVerdict.entries([]), .absent] {
            let early = await reconcile(verdict, scanStartedAt: created)
            XCTAssertFalse(early.conclusive,
                           "the age gate still holds the turn open — that half is unchanged")
            XCTAssertTrue(
                ConversationDetailViewModel.folderReadAnswered(early),
                "a clean answer inside the grace window is still a clean answer to the user")
        }
    }

    /// The other side of it, and the line that must never move: a server the app
    /// could not read is never reported as "nothing found", at any age.
    @MainActor
    func testAnUnreadableServerIsNeverReportedAsAnAnswer() async {
        for refusal in [FileTransferListingRefusal.transport, .unauthorized, .malformedBody] {
            let dead = await reconcile(.unusable(refusal), scanStartedAt: pastHorizon)
            XCTAssertFalse(
                ConversationDetailViewModel.folderReadAnswered(dead),
                "\(refusal) means the app learned nothing — it cannot report an empty result")
        }
    }

    // MARK: - The manual verbs are offered only where they can run

    /// A turn sent with NO FILE SERVER configured persists no lane id, so the
    /// name search has nothing to probe and its handler returns immediately. That
    /// is the majority configuration, not an edge — offering the verb there
    /// answers a tap with nothing at all: no result, no caption, no error. Being
    /// an agent turn is not enough.
    @MainActor
    func testTheNameSearchIsOfferedOnlyOnATurnThatHasALane() {
        let noLane = MessageRecord(
            id: UUID(), role: "agent", text: "Here is report.pdf.",
            createdAt: created, sourceDevice: "iphone",
            outputScanLaneID: nil, outputBoxKey: nil
        )
        XCTAssertFalse(ConversationDetailViewModel.canSearchMentionedFiles(noLane),
                       "no lane means no server to search")
        XCTAssertFalse(ConversationDetailViewModel.showsOutputActionsMenu(noLane),
                       "and with neither verb available the row offers no menu at all")

        // A lane but no folder is the population the automatic lane never serves,
        // so the search is exactly what it keeps.
        let laneOnly = MessageRecord(
            id: UUID(), role: "agent", text: "Here is report.pdf.",
            createdAt: created, sourceDevice: "watch",
            outputScanLaneID: String(repeating: "a", count: 64), outputBoxKey: nil
        )
        XCTAssertTrue(ConversationDetailViewModel.canSearchMentionedFiles(laneOnly))
        XCTAssertFalse(ConversationDetailViewModel.canRecheckOutputs(laneOnly))
        XCTAssertTrue(ConversationDetailViewModel.showsOutputActionsMenu(laneOnly))
    }

    /// A USER's own sent message has no output verbs, so its footer must carry no
    /// context menu — an attached-but-empty one still runs the long-press lift
    /// animation and then presents an empty sheet.
    @MainActor
    func testAUserTurnOffersNoOutputMenuAtAll() {
        let sent = MessageRecord(
            id: UUID(), role: "user", text: "Please write report.pdf.",
            createdAt: created, sourceDevice: "iphone",
            fileTransferLaneID: String(repeating: "a", count: 64),
            outputScanLaneID: String(repeating: "a", count: 64),
            outputBoxKey: boxKey
        )
        XCTAssertFalse(ConversationDetailViewModel.showsOutputActionsMenu(sent),
                       "no verb applies to the user's own message, so no menu may lift it")
        XCTAssertFalse(ConversationDetailViewModel.canSearchMentionedFiles(sent))
        XCTAssertFalse(ConversationDetailViewModel.canRecheckOutputs(sent))
    }

    // MARK: - A caption a later pass has overtaken stops being shown

    /// "No returned files were discovered" is a report about ONE look at ONE
    /// instant. A tap inside the grace window gets it honestly, and the automatic
    /// pass a minute later can still list the folder and find the agent's late
    /// write — at which point the caption sits underneath a visible chip
    /// contradicting it for the rest of the session. A grown chip census retires
    /// it.
    @MainActor
    func testANoneFoundCaptionRetiresOnceTheRowGainsAChip() {
        let id = UUID()
        let states: [UUID: ConversationDetailViewModel.OutputRecheckState] =
            [id: .noneFound(chipCount: 0)]

        let stillEmpty = MessageRecord(
            id: id, role: "agent", text: "Done.", createdAt: created, sourceDevice: "mac")
        XCTAssertEqual(
            ConversationDetailViewModel.liveRecheckStates(states, after: [stillEmpty]),
            states,
            "nothing has changed about the row, so the answer is still the latest thing known")

        let nowHasAChip = MessageRecord(
            id: id, role: "agent", text: "Done.", createdAt: created, sourceDevice: "mac",
            attachments: [serverChip(named: "late.pdf")])
        XCTAssertTrue(
            ConversationDetailViewModel.liveRecheckStates(states, after: [nowHasAChip]).isEmpty,
            "a chip on screen makes 'none found' a contradiction, not a caveat")
    }

    /// The refusal caption is census-gated on the SAME rule, and it has to be:
    /// unlike "none found" it is also set on the PARTIAL case, where the look
    /// itself just added chips. A census stamped before those landed would read
    /// them back as the row outrunning the answer and retire the caption on the
    /// very next reload — before anyone had read it.
    @MainActor
    func testAnUndeliverableCaptionRetiresOnlyWhenTheRowOutrunsIt() {
        let id = UUID()
        // A look that delivered one chip and refused two entries, stamped
        // POST-INSERT: one chip is already accounted for.
        let states: [UUID: ConversationDetailViewModel.OutputRecheckState] =
            [id: .undeliverableEntries(count: 2, chipCount: 1)]

        let asStamped = MessageRecord(
            id: id, role: "agent", text: "Done.", createdAt: created, sourceDevice: "mac",
            attachments: [serverChip(named: "report.pdf")])
        XCTAssertEqual(
            ConversationDetailViewModel.liveRecheckStates(states, after: [asStamped]),
            states,
            "the chip this very look delivered is not the row outrunning its own answer")

        let grewLater = MessageRecord(
            id: id, role: "agent", text: "Done.", createdAt: created, sourceDevice: "mac",
            attachments: [serverChip(named: "report.pdf"), serverChip(named: "late.pdf")])
        XCTAssertTrue(
            ConversationDetailViewModel.liveRecheckStates(states, after: [grewLater]).isEmpty,
            "a chip the look never accounted for means a later pass has overtaken it")
    }

    /// A caption whose row is GONE goes with it — the pruning the reload already
    /// owed, kept intact by the census rule above.
    @MainActor
    func testACaptionForAVanishedRowIsDropped() {
        let states: [UUID: ConversationDetailViewModel.OutputRecheckState] = [
            UUID(): .noneFound(chipCount: 0),
            UUID(): .couldNotCheck
        ]
        XCTAssertTrue(ConversationDetailViewModel.liveRecheckStates(states, after: []).isEmpty)
    }

    /// A `couldNotCheck` caption is NOT census-gated: it says the app learned
    /// nothing, which a chip arriving from somewhere else does not refute.
    @MainActor
    func testACouldNotCheckCaptionSurvivesAChipArriving() {
        let id = UUID()
        let states: [UUID: ConversationDetailViewModel.OutputRecheckState] = [id: .couldNotCheck]
        let withChip = MessageRecord(
            id: id, role: "agent", text: "Done.", createdAt: created, sourceDevice: "mac",
            attachments: [serverChip(named: "late.pdf")])
        XCTAssertEqual(
            ConversationDetailViewModel.liveRecheckStates(states, after: [withChip]), states)
    }

    // MARK: - The post-tap preview is built OFF the main actor

    /// A chip tap builds the wrist's preview from bytes the download already put
    /// on disk — and it must not do that on the main thread. The read plus a full
    /// ImageIO decode / downsize / re-encode of a multi-megabyte image is a
    /// visible freeze, and it happens BEFORE Quick Look can appear.
    ///
    /// HOW THIS DISCRIMINATES: the heartbeat below is enqueued on the main actor
    /// before the call and can only run if the call actually suspends the main
    /// actor. `SWIFT_APPROACHABLE_CONCURRENCY` is on, so a `nonisolated async`
    /// callee runs in the CALLER's isolation domain — inline, the whole read and
    /// decode chain would run to completion on the main actor without ever
    /// yielding, and the heartbeat would still be waiting when it returned.
    @MainActor
    func testPreviewBuildHandsTheMainActorBackWhileItWorks() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-preview-\(UUID().uuidString).txt")
        try Data("the preview bytes".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let heartbeat = MainActorHeartbeat()
        let queued = Task { @MainActor in heartbeat.didRun = true }

        let patches = await FileTransferOutputDetector.previewPatchesForDownloadedFile(
            at: url,
            messageID: UUID(),
            storedKey: "\(boxKey)/note.txt",
            filename: "note.txt",
            mimeType: "text/plain",
            snapshot: snapshot()
        )

        XCTAssertTrue(heartbeat.didRun,
                      "the preview build must yield the main actor while it reads and decodes")
        await queued.value
        // …and it still has to produce the preview: the ordering the tap depends
        // on is "preview stored, THEN hand off to Quick Look", so the work must
        // be awaited, never fired and forgotten.
        XCTAssertEqual(patches.count, 1)
        XCTAssertEqual(patches.first?.previewKind, "text")
        XCTAssertEqual(patches.first?.previewData, Data("the preview bytes".utf8))
    }

    // MARK: - Local fixtures

    /// A minimal server-reference attachment — enough for the chip census.
    private func serverChip(named name: String) -> AttachmentRecord {
        AttachmentRecord(
            id: UUID(),
            mimeType: "application/pdf",
            filename: name,
            thumbnailData: nil,
            extractedText: nil,
            width: 0,
            height: 0,
            byteSize: 1024,
            sequence: 0,
            createdAt: created,
            isServerReference: true,
            storedKey: "\(boxKey)/\(name)"
        )
    }
}
