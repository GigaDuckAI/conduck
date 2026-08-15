// SPDX-License-Identifier: Apache-2.0

// Conduck
// OutputDeliveryOutcomeTests.swift
//
// Locks the PERSISTED half of the output-refusal escape hatch: the
// `OutputDeliveryOutcome` payload, its JSON blob, its round trip through
// `ConversationStore.reconcileOutputScan`, and the pure rule that decides
// whether a turn draws a standing row at all.
//
// THE ONE INVARIANT EVERYTHING HERE SERVES: NIL IS NOT ZERO. A nil outcome means
// no census was taken — an unreadable server, a folder that is not there, a root
// name search that never sees a folder. An all-zero outcome is a POSITIVE
// observation: the folder was read and nothing was withheld. Collapsing the two
// erases a true standing refusal the moment someone's tunnel blinks for five
// seconds, and it does so silently, because the row simply stops being drawn.
//
// WHY THE ENCODER'S KEY ORDER IS A TEST AND NOT A DETAIL. The store decides
// whether to write by comparing the freshly encoded blob against the stored one.
// A non-deterministic key order makes stored != encoded on EVERY pass, which
// flips `changedVisibleState`, which posts `.conversationsDidChange`, which
// reloads, which rescans, which writes again. On a turn still open that is a
// sync loop against the user's own iCloud database — and no test that only
// checks decoded VALUES would ever see it, because every value round-trips
// perfectly the whole time.
//
// Each store test builds its OWN isolated `inMemory` store (CloudKit OFF in the
// seam) — no `.shared` singleton, no App Group sqlite. Deterministic + headless;
// synthetic names only, and nothing is logged.

import XCTest
@testable import Conduck

/// A main-actor counter a `.conversationsDidChange` observer can bump.
/// `@MainActor` makes it Sendable, so the observer block can capture it without
/// a mutable-capture race — and the store posts that notification from the main
/// actor, so the observer genuinely runs there.
@MainActor
private final class ReloadCounter {
    var count = 0
}

final class OutputDeliveryOutcomeTests: XCTestCase {

    private let laneID = String(repeating: "c", count: 64)
    private let boxKey = "1F2E3D4C-5B6A-7890-ABCD-EF0123456789/out-\(String(repeating: "a", count: 32))"

    // MARK: - Fixtures

    private func makeStore() -> ConversationStore {
        ConversationStore(inMemory: true)
    }

    private func entry(_ name: String, bytes: Int = 4096) -> RefusedOutputEntry {
        RefusedOutputEntry(name: name, byteSize: bytes)
    }

    /// The census in the shape most of this file cares about — three TOTALS.
    ///
    /// It keeps the old flat labels deliberately: the split of the shape total
    /// into classes, and the cause behind the remainder, are the subject of
    /// exactly the tests that pass them explicitly. Everywhere else they are
    /// noise, and a fixture that forces every caller to spell them out is a
    /// fixture that hides which test is actually about them.
    private func outcome(
        typeRefusedCount: Int = 0,
        shapeRefusedCount: Int = 0,
        shapeOverlongCount: Int = 0,
        shapeWhitespaceCount: Int = 0,
        undeliveredCount: Int = 0,
        remainderIsRecoverable: Bool? = nil,
        entries: [RefusedOutputEntry] = []
    ) -> OutputDeliveryOutcome {
        OutputDeliveryOutcome(
            typeRefusedCount: typeRefusedCount,
            shapeRefused: ShapeRefusalCensus(
                overlongCount: shapeOverlongCount,
                whitespaceBoundedCount: shapeWhitespaceCount,
                unusableCount: shapeRefusedCount - shapeOverlongCount - shapeWhitespaceCount
            ),
            remainder: OutputRemainder(
                count: undeliveredCount, isRecoverable: remainderIsRecoverable
            ),
            typeRefusedEntries: entries
        )
    }

    /// Seed a conversation with one agent turn carrying a lane and a folder —
    /// the two columns a standing row needs before a census can mean anything.
    private func seed(
        outputBoxKey: String?,
        store: ConversationStore
    ) async throws -> UUID {
        let conversation = try await store.createConversation(backend: "openclaw")
        let user = try await store.appendMessage(
            role: "user",
            text: "make me a profile",
            conversationID: conversation.id,
            sourceDevice: "phone",
            status: "sending"
        )
        let agent = try await store.completeAgentTurn(
            userMessageID: user.id,
            userStatus: "sent",
            agentText: "done",
            conversationID: conversation.id,
            sourceDevice: "phone",
            outputScanLaneID: laneID,
            outputBoxKey: outputBoxKey
        )
        return agent.id
    }

    private func reload(_ messageID: UUID, in store: ConversationStore) async throws -> MessageRecord {
        let conversations = try await store.fetchConversations()
        let conversationID = try XCTUnwrap(conversations.first?.id)
        let messages = try await store.fetchMessages(for: conversationID)
        return try XCTUnwrap(messages.first { $0.id == messageID })
    }

    // MARK: - The blob: determinism

    /// THE SYNC-LOOP TRIPWIRE. Encoding the SAME entries must produce the SAME
    /// bytes, every time, in one process and across many encoder instances —
    /// `JSONEncoder` orders a dictionary's keys by the hash seed unless
    /// `.sortedKeys` is set, and that seed is per-process, so a single encode
    /// compared against itself would never catch this.
    ///
    /// Two entries with two keys each, because the defect only appears once
    /// there is more than one key to order.
    func testEncodingIsByteDeterministicAcrossRepeatedEncodes() {
        let entries = [entry("profile.mobileconfig", bytes: 12_345),
                       entry("workspace.sqlite", bytes: 6),
                       entry("installer.pkg", bytes: 0)]
        let first = OutputDeliveryOutcome.encodedNames(entries)
        XCTAssertNotNil(first)
        for _ in 0..<200 {
            XCTAssertEqual(OutputDeliveryOutcome.encodedNames(entries), first,
                           "an unstable key order makes every reconcile a 'change', which on "
                           + "CloudKit is a reload → rescan → write loop rather than a wasted repaint")
        }
    }

    /// THE OTHER AXIS, and the one the test above is structurally blind to. It
    /// re-encodes the SAME array, so it can only ever see key order inside an
    /// object — the ARRAY's own order is fixed for the whole of it, and an
    /// encoder that faithfully preserved a server's listing order would sail
    /// through.
    ///
    /// A WebDAV `PROPFIND` returns entries in whatever order the server's
    /// directory read produced, which on an ordinary ext4 box changes after any
    /// unrelated create or unlink in that folder. So the same dozen names arrive
    /// in a different order for no reason at all, and without a sort the census
    /// re-encodes differently, compares unequal against the stored string,
    /// writes, posts `.conversationsDidChange`, reloads, and rescans — forever,
    /// on every device.
    func testEncodingIsIdenticalWhateverOrderTheListingArrivedIn() {
        let entries = [entry("profile.mobileconfig", bytes: 12_345),
                       entry("workspace.sqlite", bytes: 6),
                       entry("installer.pkg", bytes: 0),
                       entry("README", bytes: 12)]
        let canonical = OutputDeliveryOutcome.encodedNames(entries)
        XCTAssertNotNil(canonical)

        for reordering in [Array(entries.reversed()),
                           [entries[2], entries[0], entries[3], entries[1]],
                           [entries[3], entries[2], entries[1], entries[0]],
                           [entries[1], entries[3], entries[0], entries[2]]] {
            XCTAssertEqual(OutputDeliveryOutcome.encodedNames(reordering), canonical,
                           "the same census in a different server order must encode to the same "
                           + "bytes — otherwise every reconcile is a 'change' and the write loop "
                           + "runs against the user's own iCloud database")
        }
    }

    /// The RETAINED SET is order-independent too, which is the half a byte
    /// comparison cannot reach. When the census outruns the retention cap the
    /// sort decides WHICH entries survive, so an unsorted truncation would keep a
    /// different dozen files per listing — a different offer in the review sheet
    /// on every pass, over a folder nobody touched.
    func testTheRetainedSubsetIsTheSameWhateverOrderTheListingArrivedIn() {
        let many = (1...40).map { entry("file\($0).mobileconfig", bytes: $0) }
        let forwards = outcome(typeRefusedCount: 40, entries: many)
        let backwards = outcome(typeRefusedCount: 40, entries: many.reversed())
        let shuffled = outcome(typeRefusedCount: 40,
                               entries: many.enumerated()
                                   .sorted { ($0.offset * 7) % 40 < ($1.offset * 7) % 40 }
                                   .map(\.element))

        XCTAssertEqual(forwards.typeRefusedEntries, backwards.typeRefusedEntries)
        XCTAssertEqual(forwards.typeRefusedEntries, shuffled.typeRefusedEntries)
        XCTAssertEqual(forwards.typeRefusedEntries.count,
                       OutputDeliveryOutcome.maxRetainedRefusedNames,
                       "the fixture really does overrun the cap — otherwise nothing is being tested")
    }

    /// AND THEREFORE NO WRITE AND NO RELOAD. The two properties above are means;
    /// this is the end they serve, measured where it actually bites — a census
    /// replayed with its entries in a different order must not look like a
    /// change to the store.
    func testAReorderedListingIsNotAChangeAndPostsNoReload() async throws {
        let store = makeStore()
        let messageID = try await seed(outputBoxKey: boxKey, store: store)
        let entries = [entry("profile.mobileconfig", bytes: 12_345),
                       entry("keys.sqlite", bytes: 6),
                       entry("README", bytes: 12)]

        let reloads = ReloadCounter()
        let token = NotificationCenter.default.addObserver(
            forName: .conversationsDidChange, object: nil, queue: nil
        ) { _ in MainActor.assumeIsolated { reloads.count += 1 } }
        defer { NotificationCenter.default.removeObserver(token) }

        func reconcile(_ listing: [RefusedOutputEntry]) async throws {
            _ = try await store.reconcileOutputScan([
                .init(messageID: messageID, drafts: [], markScanned: false,
                      expectedLaneID: laneID,
                      deliveryOutcome: outcome(typeRefusedCount: 3, entries: listing))
            ])
        }

        try await reconcile(entries)
        XCTAssertEqual(reloads.count, 1, "the census is new, so the thread repaints once")

        try await reconcile(entries.reversed())
        try await reconcile([entries[1], entries[2], entries[0]])
        XCTAssertEqual(reloads.count, 1,
                       "the server read its own directory out in a different order and nothing "
                       + "about the folder changed — so no write, and no reload to rescan into")
    }

    /// And the order is SORTED specifically, not merely stable — a stable-but-
    /// arbitrary order would still differ between two builds, and the comparison
    /// that gates the write happens across devices as well as across passes.
    func testTheEncodedKeysAreSortedNotMerelyStable() {
        let encoded = try? XCTUnwrap(OutputDeliveryOutcome.encodedNames([entry("a.pkg", bytes: 1)]))
        XCTAssertEqual(encoded, #"{"e":[{"b":1,"n":"a.pkg"}],"v":1}"#,
                       "keys sort ascending at every level, so two devices encode the same census "
                       + "into the same bytes and neither sees the other's write as a change")
    }

    /// Nothing to offer stores NO STRING, rather than an empty envelope. The
    /// counts beside it carry the census on their own, and a stored `{"e":[],"v":1}`
    /// would be a value that reads as "there were names" to anything checking
    /// for nil.
    func testAnEmptyOfferEncodesToNothingAtAll() {
        XCTAssertNil(OutputDeliveryOutcome.encodedNames([]))
    }

    // MARK: - The blob: decoding fails toward LESS, never toward wrong

    func testTheBlobRoundTrips() {
        let entries = [entry("profile.mobileconfig", bytes: 12_345), entry("keys.sqlite")]
        let decoded = OutputDeliveryOutcome.decodedNames(from: OutputDeliveryOutcome.encodedNames(entries))
        XCTAssertEqual(decoded, [entry("keys.sqlite"), entry("profile.mobileconfig", bytes: 12_345)],
                       "names and sizes survive — in the BLOB's own order, which is name order and "
                       + "not the server's, because listing order is not a fact worth persisting")
    }

    /// A blob this build cannot read degrades the row from "here they are" to
    /// "there were N" — never to a crash, and never to a name that means
    /// something else. The counts sit in their own columns and are untouched by
    /// any of this, which is exactly why THEY are the unknown-carrier and the
    /// array is not.
    func testAnUnreadableBlobDecodesToNothingRatherThanTrapping() {
        for blob in [nil, "", "not json", "[]", #"{"v":1}"#,
                     #"{"e":[{"n":"x.pkg"}],"v":99}"#,          // a version this build does not know
                     #"{"e":[{"b":"big","n":"x.pkg"}],"v":1}"#] // a type that does not match
        {
            XCTAssertEqual(OutputDeliveryOutcome.decodedNames(from: blob), [],
                           "\(blob ?? "nil") must fail to empty")
        }
    }

    // MARK: - Both bounds live at the one place nothing can bypass

    /// The retained OFFER is capped while the CENSUS is not, and they are
    /// allowed to disagree — that disagreement is what lets the row say "and N
    /// more" honestly instead of quietly under-reporting.
    func testTheRetainedOfferIsCappedWhileTheCensusIsNot() {
        let many = (1...40).map { entry("file\($0).mobileconfig") }
        let value = outcome(typeRefusedCount: 40, entries: many)
        XCTAssertEqual(value.typeRefusedCount, 40, "the census counts the WHOLE folder")
        XCTAssertEqual(value.typeRefusedEntries.count, OutputDeliveryOutcome.maxRetainedRefusedNames,
                       "the offer is bounded — this array replicates to every device the user owns")
        // The surviving set is the first dozen IN NAME ORDER, not the first
        // dozen the server happened to read out. That is the whole point of
        // sorting before the truncation: the offer stops depending on a
        // directory-read order that changes after any unrelated create.
        XCTAssertEqual(value.typeRefusedEntries.map(\.name),
                       (["file1"] + (10...19).map { "file\($0)" } + ["file2"])
                           .map { "\($0).mobileconfig" },
                       "truncation drops the tail OF THE SORTED array, so the same folder yields "
                       + "the same offer whatever order the listing arrived in")
    }

    /// A negative census is not a smaller fact, it is a broken one, so the counts
    /// clamp at zero at the initialiser rather than at each reader.
    func testNegativeCountsClampRatherThanPropagate() {
        let value = outcome(typeRefusedCount: -3, shapeRefusedCount: -1, undeliveredCount: -99)
        XCTAssertEqual(value.typeRefusedCount, 0)
        XCTAssertEqual(value.shapeRefusedCount, 0)
        XCTAssertEqual(value.undeliveredCount, 0)
        XCTAssertTrue(value.isSilent, "and a clamped-to-nothing census is silent, not negative")
    }

    /// The byte bound is a SECOND, independent ceiling on the same field, so
    /// raising the name cap can never quietly grow what syncs. Under today's
    /// name-length gate it does not bite — a dozen names of at most
    /// `storedKeyComponentMaxCharacters` cannot reach 4 KiB — and this test
    /// states that relationship rather than asserting a number, so a future
    /// widening of either bound fails here instead of in someone's iCloud quota.
    func testTheRetainedOfferFitsTheByteBudgetByConstruction() {
        let longest = String(repeating: "a",
                             count: FileServerClient.storedKeyComponentMaxCharacters - 5) + ".pkg"
        XCTAssertNotNil(FileServerClient.validatedOutboxEntryName(longest.replacingOccurrences(of: ".pkg", with: ".pdf")),
                        "the fixture is a name the gate would actually admit at full length")
        let worstCase = (1...OutputDeliveryOutcome.maxRetainedRefusedNames).map { _ in
            entry(longest, bytes: Int(Int32.max))
        }
        let encoded = try? XCTUnwrap(OutputDeliveryOutcome.encodedNames(worstCase))
        XCTAssertEqual(OutputDeliveryOutcome.decodedNames(from: encoded).count,
                       OutputDeliveryOutcome.maxRetainedRefusedNames,
                       "the worst case the name gate permits still fits, so no entry is dropped")
        XCTAssertLessThanOrEqual(encoded?.utf8.count ?? .max, Constants.outputRefusedNamesMaxBytes)
    }

    // MARK: - Round trip through the store

    /// THE PERSISTENCE ROUND TRIP, modelled on the `outputBoxKey` one: write a
    /// census through the real reconcile path and read it back off a freshly
    /// fetched record. Four columns in, one value out — a caller can never
    /// observe half a census.
    func testACensusSurvivesAReconcileAndReadsBackAsOneValue() async throws {
        let store = makeStore()
        let messageID = try await seed(outputBoxKey: boxKey, store: store)

        _ = try await store.reconcileOutputScan([
            .init(messageID: messageID,
                  drafts: [],
                  markScanned: false,
                  expectedLaneID: laneID,
                  deliveryOutcome: outcome(
                    typeRefusedCount: 3,
                    shapeRefusedCount: 2,
                    undeliveredCount: 1,
                    entries: [entry("profile.mobileconfig", bytes: 12_345), entry("keys.sqlite")]))
        ])

        let record = try await reload(messageID, in: store)
        let stored = try XCTUnwrap(record.outputDeliveryOutcome)
        XCTAssertEqual(stored.typeRefusedCount, 3)
        XCTAssertEqual(stored.shapeRefusedCount, 2)
        XCTAssertEqual(stored.undeliveredCount, 1)
        XCTAssertEqual(stored.typeRefusedEntries,
                       [entry("keys.sqlite"), entry("profile.mobileconfig", bytes: 12_345)],
                       "names AND sizes survive the blob, in the name order the blob is written in")
    }

    /// THE FIVE-SECOND-OUTAGE TEST, and the reason `deliveryOutcome` is optional
    /// rather than defaulted. A pass that took no census writes nothing, so a
    /// standing refusal recorded an hour ago is still there after a listing that
    /// could not be read.
    func testAPassWithNoCensusLeavesAStandingRefusalIntact() async throws {
        let store = makeStore()
        let messageID = try await seed(outputBoxKey: boxKey, store: store)

        _ = try await store.reconcileOutputScan([
            .init(messageID: messageID, drafts: [], markScanned: false, expectedLaneID: laneID,
                  deliveryOutcome: outcome(typeRefusedCount: 1,
                                           entries: [entry("profile.mobileconfig")]))
        ])
        // The server blinks: no listing, therefore no census, therefore no write.
        _ = try await store.reconcileOutputScan([
            .init(messageID: messageID, drafts: [], markScanned: false, expectedLaneID: laneID,
                  deliveryOutcome: nil)
        ])

        let record = try await reload(messageID, in: store)
        XCTAssertEqual(record.outputDeliveryOutcome?.typeRefusedCount, 1,
                       "a pass that learned nothing must not overwrite what an earlier pass proved")
        XCTAssertEqual(record.outputDeliveryOutcome?.typeRefusedEntries.map(\.name),
                       ["profile.mobileconfig"])
    }

    /// The OTHER half of the same rule, and the only retire there is: a pass that
    /// DID read the folder and found nothing withheld overwrites the standing
    /// census with zeros. The row then stops being drawn — not because the record
    /// was cleared, but because an all-zero census is silent.
    func testAnObservedEmptyCensusRetiresAStandingRefusal() async throws {
        let store = makeStore()
        let messageID = try await seed(outputBoxKey: boxKey, store: store)

        _ = try await store.reconcileOutputScan([
            .init(messageID: messageID, drafts: [], markScanned: false, expectedLaneID: laneID,
                  deliveryOutcome: outcome(typeRefusedCount: 1,
                                           entries: [entry("profile.mobileconfig")]))
        ])
        _ = try await store.reconcileOutputScan([
            .init(messageID: messageID, drafts: [], markScanned: false, expectedLaneID: laneID,
                  deliveryOutcome: outcome())
        ])

        let record = try await reload(messageID, in: store)
        let stored = try XCTUnwrap(record.outputDeliveryOutcome,
                                   "the census is PRESENT — 'read and clean' is a positive fact")
        XCTAssertTrue(stored.isSilent)
        XCTAssertTrue(stored.typeRefusedEntries.isEmpty, "the names go with the claim they supported")
        XCTAssertNil(ConversationDetailViewModel.outputDeliveryRow(for: record),
                     "and a silent census draws nothing")
    }

    /// A row that has never been listed carries NO census, which is a third state
    /// distinct from both of the above and must survive as nil.
    func testATurnNeverListedCarriesNoCensusAtAll() async throws {
        let store = makeStore()
        let messageID = try await seed(outputBoxKey: boxKey, store: store)
        let record = try await reload(messageID, in: store)
        XCTAssertNil(record.outputDeliveryOutcome,
                     "UNKNOWN, and it must not be manufacturable into an observed zero")
    }

    /// IDEMPOTENCE, which is what keeps the sync loop shut, measured on
    /// `.conversationsDidChange` because that notification IS the reload — the
    /// method's return value answers a different question (below).
    ///
    /// The loop this closes: a census that compared unequal on every pass would
    /// post a reload, which re-selects the turn, which re-lists the folder, which
    /// writes again. On a turn still open that runs against the user's own iCloud
    /// database, and every value round-trips perfectly the whole time — so only a
    /// test that counts the POSTS can see it.
    func testANewCensusPostsAReloadAndReplayingItDoesNot() async throws {
        let store = makeStore()
        let messageID = try await seed(outputBoxKey: boxKey, store: store)
        let census = outcome(typeRefusedCount: 2, shapeRefusedCount: 1,
                             entries: [entry("profile.mobileconfig"), entry("keys.sqlite")])

        let reloads = ReloadCounter()
        let token = NotificationCenter.default.addObserver(
            forName: .conversationsDidChange, object: nil, queue: nil
        ) { _ in
            // `postDidChange` always posts from the main actor, so the observer
            // runs there too and the count needs no lock.
            MainActor.assumeIsolated { reloads.count += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        func reconcile() async throws -> Bool {
            try await store.reconcileOutputScan([
                .init(messageID: messageID, drafts: [], markScanned: false,
                      expectedLaneID: laneID, deliveryOutcome: census)
            ])
        }

        _ = try await reconcile()
        XCTAssertEqual(reloads.count, 1,
                       "a census that appears IS user-visible state — it draws a standing row, so "
                       + "the thread has to repaint or the row waits for an unrelated reload")
        _ = try await reconcile()
        XCTAssertEqual(reloads.count, 1,
                       "an unchanged census must not manufacture a second reload — that echo is "
                       + "the first turn of the sync loop")
    }

    /// WHAT THE RETURN VALUE MEANS, pinned because it is easy to read as "did
    /// anything change" and it is not: it answers "was a CHIP inserted", and it
    /// gates preview enrichment. A census-only reconcile inserted no attachment,
    /// so there is nothing to build a preview from and the answer is false —
    /// while the row it just recorded is drawn all the same.
    ///
    /// Conflating the two would send the preview builder off after a census, i.e.
    /// off to enrich attachment rows that do not exist.
    func testACensusOnlyReconcileReportsNoInsertEvenThoughItChangedTheRow() async throws {
        let store = makeStore()
        let messageID = try await seed(outputBoxKey: boxKey, store: store)

        let inserted = try await store.reconcileOutputScan([
            .init(messageID: messageID, drafts: [], markScanned: false, expectedLaneID: laneID,
                  deliveryOutcome: outcome(typeRefusedCount: 1,
                                           entries: [entry("profile.mobileconfig")]))
        ])
        XCTAssertFalse(inserted, "no chip was inserted, so nothing has bytes to preview")

        let record = try await reload(messageID, in: store)
        XCTAssertNotNil(ConversationDetailViewModel.outputDeliveryRow(for: record),
                        "and yet the row IS drawn — the two answers are about different things")
    }

    /// A census may not be written through a lane that no longer owns the reply.
    /// The compare-and-set guard is what stops a stale in-flight pass from
    /// stamping a refusal onto a turn that has since been repointed at a
    /// different file server — where the names it holds address nothing.
    func testAMismatchedLaneWritesNoCensus() async throws {
        let store = makeStore()
        let messageID = try await seed(outputBoxKey: boxKey, store: store)

        _ = try await store.reconcileOutputScan([
            .init(messageID: messageID, drafts: [], markScanned: false,
                  expectedLaneID: String(repeating: "z", count: 64),
                  deliveryOutcome: outcome(typeRefusedCount: 5,
                                           entries: [entry("profile.mobileconfig")]))
        ])
        let record = try await reload(messageID, in: store)
        XCTAssertNil(record.outputDeliveryOutcome,
                     "the guard covers the census exactly as it covers the chips and the marker")
    }

    // MARK: - What draws a standing row (pure)

    /// The gate, arm by arm. Each clause exists for a population that can really
    /// occur, and the folder clause is the one that is easy to think theoretical:
    /// a CLONED agent turn carries its lane and no folder, and a rescue resolves
    /// `<outputBoxKey>/<name>` — so a census with no folder describes files
    /// nothing could ever fetch.
    func testTheStandingRowNeedsAnAgentTurnALaneAFolderAndSomethingToSay() {
        let census = outcome(typeRefusedCount: 1, entries: [entry("profile.mobileconfig")])

        func record(
            role: String = "agent",
            lane: String? = "lane",
            folder: String? = "conv/out-box",
            outcome: OutputDeliveryOutcome? = nil
        ) -> MessageRecord {
            MessageRecord(
                id: UUID(), role: role, text: "reply", createdAt: Date(), sourceDevice: "phone",
                outputScanLaneID: lane, outputBoxKey: folder, outputDeliveryOutcome: outcome
            )
        }

        XCTAssertNotNil(ConversationDetailViewModel.outputDeliveryRow(
            for: record(outcome: census)), "the qualifying shape")
        XCTAssertNil(ConversationDetailViewModel.outputDeliveryRow(
            for: record(role: "user", outcome: census)),
            "a user turn has no output folder to have refused anything from")
        XCTAssertNil(ConversationDetailViewModel.outputDeliveryRow(
            for: record(lane: nil, outcome: census)),
            "an ownerless turn cannot prove which server the names came from")
        XCTAssertNil(ConversationDetailViewModel.outputDeliveryRow(
            for: record(folder: nil, outcome: census)),
            "no folder means no key to rescue with, so the offer would be unfulfillable")
        XCTAssertNil(ConversationDetailViewModel.outputDeliveryRow(for: record()),
            "UNKNOWN draws nothing")
        XCTAssertNil(ConversationDetailViewModel.outputDeliveryRow(
            for: record(outcome: outcome())), "and so does OBSERVED NONE")
    }

    /// A CENSUS WHOSE NAMES HAVE ALL BECOME DELIVERABLE DRAWS NOTHING, and
    /// specifically not a bare count.
    ///
    /// The allowlist is the one input that can move between the pass that wrote
    /// a census and the render that reads it, and `rescuableEntries` already
    /// re-asks the verdict for exactly that reason. Without the same question at
    /// the row's own gate, the row survives its evidence: "the folder held 2
    /// files Conduck doesn't open on its own" with no name under it and no
    /// Review button beside it, over two files the thread is about to show as
    /// ordinary chips.
    func testACensusWhoseNamesAreAllDeliverableNowDrawsNoRow() {
        let stale = record(census: outcome(typeRefusedCount: 2,
                                           entries: [entry("clip.mp4"), entry("chart.png")]))
        XCTAssertTrue(OutputTypeRefusal.rescuableEntries(in: stale).isEmpty,
                      "both names are chips' work now, so there is nothing left to rescue")
        XCTAssertNil(ConversationDetailViewModel.outputDeliveryRow(for: stale),
                     "and therefore nothing left to say — a count with no name and no action is "
                     + "a claim the app can no longer support")
    }

    /// THE THREE CONDITIONS THAT KEEP THAT NARROW, each of which is a row that
    /// must still be drawn. Stated together because the failure they prevent is
    /// the opposite one — a real refusal silently disappearing.
    func testARowSurvivesWheneverAnyPartOfItsClaimIsStillSupported() {
        // One name still refused: the claim stands, and the sheet has an entry.
        XCTAssertNotNil(ConversationDetailViewModel.outputDeliveryRow(for: record(
            census: outcome(typeRefusedCount: 2,
                            entries: [entry("clip.mp4"), entry("profile.mobileconfig")]))))
        // The census counted MORE of the folder than it kept, so what the
        // retained names now say is no answer about the rest.
        XCTAssertNotNil(ConversationDetailViewModel.outputDeliveryRow(for: record(
            census: outcome(typeRefusedCount: 9, entries: [entry("clip.mp4")]))))
        // A blob this build could not read left the count standing alone. "There
        // were N" is the correct degradation, not silence.
        XCTAssertNotNil(ConversationDetailViewModel.outputDeliveryRow(for: record(
            census: outcome(typeRefusedCount: 2))))
        // The other two populations are bare integers about names that were
        // never persisted, so nothing can overtake them.
        XCTAssertNotNil(ConversationDetailViewModel.outputDeliveryRow(for: record(
            census: outcome(typeRefusedCount: 1, shapeRefusedCount: 1,
                            entries: [entry("clip.mp4")]))))
        XCTAssertNotNil(ConversationDetailViewModel.outputDeliveryRow(for: record(
            census: outcome(typeRefusedCount: 1, undeliveredCount: 1,
                            remainderIsRecoverable: true, entries: [entry("clip.mp4")]))))
    }

    // MARK: - What a TAP may write, and what it may CLOSE

    /// TWO DIFFERENT QUESTIONS, and the pure function that keeps them apart.
    ///
    /// Stamping a turn is PERMANENT: it removes the turn from the automatic
    /// candidate set forever. Writing a census is not — every later pass
    /// recomputes it over the whole folder. So a tap on a readable-but-empty
    /// folder must record what it saw and close nothing, which is exactly what
    /// the tap did before there was a census to write; making the census carry a
    /// store write must not smuggle a change to WHEN A TURN IS STAMPED along
    /// with it.
    func testAZeroDraftLookWritesItsCensusAndStampsNothing() {
        let readableButEmpty = ConversationDetailViewModel.tappedOutputCommit(
            draftCount: 0, conclusive: true, hasCensus: true)
        XCTAssertTrue(readableButEmpty.writesToStore,
                      "the census is the one fact worth keeping from a zero-draft look")
        XCTAssertFalse(readableButEmpty.stampsTurnScanned,
                       "and it may not also close the turn — a reporting change does not get to "
                       + "decide that a reply is never examined again")

        // A look that delivered may close, and only then — with the age gate
        // still on top of it.
        XCTAssertEqual(
            ConversationDetailViewModel.tappedOutputCommit(
                draftCount: 2, conclusive: true, hasCensus: true).stampsTurnScanned,
            true)
        XCTAssertEqual(
            ConversationDetailViewModel.tappedOutputCommit(
                draftCount: 2, conclusive: false, hasCensus: true).stampsTurnScanned,
            false,
            "inside the grace window a delivering pass still may not close the turn")

        // And a look with neither drafts nor a census — the root search on a
        // reply that named nothing — opens the store at all.
        XCTAssertFalse(
            ConversationDetailViewModel.tappedOutputCommit(
                draftCount: 0, conclusive: true, hasCensus: false).writesToStore)
    }

    /// The same rule through the REAL store, because the decision above is only
    /// worth anything if the write it describes leaves the marker alone.
    func testACensusOnlyWriteLeavesTheScanMarkerWhereItWas() async throws {
        let store = makeStore()
        let messageID = try await seed(outputBoxKey: boxKey, store: store)
        let before = try await reload(messageID, in: store)

        let commit = ConversationDetailViewModel.tappedOutputCommit(
            draftCount: 0, conclusive: true, hasCensus: true)
        _ = try await store.reconcileOutputScan([
            .init(messageID: messageID, drafts: [], markScanned: commit.stampsTurnScanned,
                  expectedLaneID: laneID,
                  deliveryOutcome: outcome(shapeRefusedCount: 2, shapeOverlongCount: 2))
        ])

        let after = try await reload(messageID, in: store)
        XCTAssertEqual(after.outputScanDone, before.outputScanDone,
                       "the marker is untouched — a tap that delivered nothing closed nothing")
        XCTAssertEqual(after.outputDeliveryOutcome?.shapeRefused,
                       ShapeRefusalCensus(overlongCount: 2, whitespaceBoundedCount: 0,
                                          unusableCount: 0),
                       "and yet the census landed, which is the whole point of the write")
    }

    /// Each of the three populations independently earns the row. Pinned
    /// separately because they are rendered as three separate lines with three
    /// separate counts, and a gate that required a TYPE refusal would silently
    /// swallow a folder that only overran the budget.
    func testAnyOneOfTheThreePopulationsEarnsTheRow() {
        for census in [outcome(typeRefusedCount: 1, entries: [entry("a.pkg")]),
                       outcome(shapeRefusedCount: 1),
                       outcome(undeliveredCount: 1)] {
            let record = MessageRecord(
                id: UUID(), role: "agent", text: "reply", createdAt: Date(), sourceDevice: "phone",
                outputScanLaneID: "lane", outputBoxKey: "conv/out-box",
                outputDeliveryOutcome: census
            )
            XCTAssertNotNil(ConversationDetailViewModel.outputDeliveryRow(for: record),
                            "\(census) withheld something, so the user is told")
        }
    }

    // MARK: - The listing → payload projection

    /// The boundary conversion, and the rule that governs it: a census may be
    /// projected ONLY from a verdict that actually read the folder. `.absent` is
    /// deliberately in the refusing group even though it closes the turn — a
    /// folder that is gone held nothing to withhold, but it also says nothing
    /// about what an earlier pass legitimately found in it.
    func testOnlyAReadFolderProducesACensus() async {
        for verdict in [FileServerListingVerdict.absent, .unusable(.transport)] {
            let reconciliation = FileTransferOutputDetector.OutboxReconciliation(
                drafts: [], conclusive: true, verdict: verdict)
            XCTAssertNil(ConversationDetailViewModel.deliveryOutcome(from: reconciliation),
                         "\(verdict) observed no folder, so it may not report zero withheld")
        }
        let read = FileTransferOutputDetector.OutboxReconciliation(
            drafts: [], conclusive: true, verdict: .entries([]))
        let census = ConversationDetailViewModel.deliveryOutcome(from: read)
        XCTAssertNotNil(census, "a folder that WAS read reports what it held, including nothing")
        XCTAssertTrue(census?.isSilent == true)
    }

    // MARK: - What a rescue may be OFFERED for

    /// The last gate before "Save anyway" exists, and the one place the rescue
    /// key is rebuilt. Every offer must address `<outputBoxKey>/<name>` — the
    /// same bytes the delivery arm would have fetched — because a rescue is a GET
    /// and there is no second way back to the file.
    func testARescueIsOfferedForTheRefusedNameUnderTheTurnsOwnFolder() {
        let refusals = OutputTypeRefusal.rescuableEntries(in: record(
            census: outcome(typeRefusedCount: 2,
                            entries: [entry("profile.mobileconfig", bytes: 4096),
                                      entry("README", bytes: 12)])))
        // Name order, because that is the order the census was stored in.
        XCTAssertEqual(refusals.map(\.name), ["README", "profile.mobileconfig"])
        XCTAssertEqual(refusals.map(\.storedKey),
                       ["\(boxKey)/README", "\(boxKey)/profile.mobileconfig"],
                       "the key is the folder column plus the stored name, rebuilt rather than "
                       + "stored twice — two copies of one key are two values that can drift")
        XCTAssertEqual(refusals.map(\.byteSize), [12, 4096])
        XCTAssertEqual(refusals.last?.reason, .unopenedExtension("mobileconfig"))
        XCTAssertEqual(refusals.first?.reason, .noReadableExtension,
                       "an unreadable type is UNKNOWN — the sheet may not assert what the file is")
    }

    /// THE ALLOWLIST MOVES AND THE CENSUS DOES NOT. A stored refusal whose
    /// extension has since become deliverable is dropped from the offer rather
    /// than shown: the next pass rewrites the census, and until then offering to
    /// rescue a file the thread is about to show as an ordinary chip is a
    /// contradiction the user cannot resolve.
    ///
    /// This is why the projection re-asks the verdict instead of trusting the
    /// record — the allowlist is the one input that can move between the pass
    /// that wrote the census and the render that reads it.
    func testANameTheAllowlistHasSinceAdmittedIsNoLongerOffered() {
        let refusals = OutputTypeRefusal.rescuableEntries(in: record(
            census: outcome(typeRefusedCount: 2,
                            entries: [entry("clip.mp4"), entry("profile.mobileconfig")])))
        XCTAssertEqual(refusals.map(\.name), ["profile.mobileconfig"],
                       "mp4 is deliverable now, so it is a chip's job, not a rescue's")
    }

    /// DEFENCE IN DEPTH at the render seam. Nothing shape-refused is ever
    /// persisted with a name, so this input is unreachable — and it is dropped
    /// rather than trusted anyway, because "unreachable" is a property of today's
    /// write path and this is the last place a name becomes something a user can
    /// tap.
    func testAShapeRefusedNameSomehowPersistedIsStillNeverOffered() {
        let refusals = OutputTypeRefusal.rescuableEntries(in: record(
            census: outcome(typeRefusedCount: 2,
                            entries: [entry("../../.ssh/id_rsa"), entry("keys.sqlite")])))
        XCTAssertEqual(refusals.map(\.name), ["keys.sqlite"])
        XCTAssertFalse(refusals.contains { $0.storedKey.contains("id_rsa") },
                       "a shape-refused name may not become a key this app would GET")
    }

    /// A turn with no folder offers nothing, whatever its census says — there is
    /// no key to build. The clone path is why this is not theoretical: a cloned
    /// agent turn can carry a lane and no folder.
    func testATurnWithNoFolderOffersNoRescue() {
        XCTAssertTrue(OutputTypeRefusal.rescuableEntries(in: record(
            folder: nil,
            census: outcome(typeRefusedCount: 1, entries: [entry("profile.mobileconfig")])
        )).isEmpty)
    }

    /// The louder-warning class is asked of the DETECTOR, so the validator stays
    /// ignorant of a distinction that is purely about what a user is told. Only a
    /// KNOWN extension can earn it: an unknown type cannot be asserted to be an
    /// installer any more than it can be asserted to be a document.
    func testOnlyAKnownConfigurationOrInstallerTypeEarnsTheLouderWarning() {
        let refusals = OutputTypeRefusal.rescuableEntries(in: record(
            census: outcome(typeRefusedCount: 3,
                            entries: [entry("profile.mobileconfig"), entry("keys.sqlite"),
                                      entry("README")])))
        // Name order again — README, keys.sqlite, profile.mobileconfig — so the
        // profile is LAST here, not first.
        XCTAssertEqual(refusals.map(\.name), ["README", "keys.sqlite", "profile.mobileconfig"])
        XCTAssertEqual(refusals.map(\.isConfigurationOrInstaller), [false, false, true],
                       "a profile changes the device; a workspace DB and an unknown type do not "
                       + "get a claim made about them")
    }

    /// An empty review is UNPRESENTABLE, structurally — the failable initialiser
    /// is what stops a sheet from opening onto nothing after a census has been
    /// overtaken by a later pass.
    func testAReviewWithNothingToShowCannotBeConstructed() {
        XCTAssertNil(OutputRefusalReview(message: record(census: outcome(shapeRefusedCount: 4))),
                     "shape refusals have nothing to review, so there is no sheet to open")
        XCTAssertNil(OutputRefusalReview(message: record(census: nil)))
        XCTAssertNotNil(OutputRefusalReview(message: record(
            census: outcome(typeRefusedCount: 1, entries: [entry("profile.mobileconfig")]))))
    }

    /// A record shaped like a qualifying agent turn — agent role, a lane and a
    /// folder — so the tests above vary one thing at a time.
    private func record(census: OutputDeliveryOutcome?) -> MessageRecord {
        record(folder: boxKey, census: census)
    }

    private func record(folder: String?, census: OutputDeliveryOutcome?) -> MessageRecord {
        MessageRecord(
            id: UUID(), role: "agent", text: "reply", createdAt: Date(), sourceDevice: "phone",
            outputScanLaneID: laneID,
            outputBoxKey: folder,
            outputDeliveryOutcome: census
        )
    }

    /// The projection drops the storedKey the listing minted, on purpose:
    /// `<outputBoxKey>/<name>` rebuilds it from a column the row already carries,
    /// and one key stored twice is one more pair of values that can drift apart.
    /// The NAME and the SIZE are what survive, because the sheet renders both.
    func testTheProjectionKeepsTheNameAndSizeAndDropsTheReconstructableKey() {
        let listed = FileTransferOutputDetector.RefusedOutboxEntry(
            name: "profile.mobileconfig", ext: "mobileconfig", byteSize: 4096,
            storedKey: "\(boxKey)/profile.mobileconfig")
        let reconciliation = FileTransferOutputDetector.OutboxReconciliation(
            drafts: [], conclusive: true, verdict: .entries([]),
            typeRefusedEntries: [listed], shapeRefused: .nothingRefused, capState: .complete)

        let census = ConversationDetailViewModel.deliveryOutcome(from: reconciliation)
        XCTAssertEqual(census?.typeRefusedEntries, [entry("profile.mobileconfig", bytes: 4096)])
        XCTAssertEqual(census?.typeRefusedCount, 1)
        XCTAssertEqual("\(boxKey)/\(listed.name)", listed.storedKey,
                       "the key the projection dropped is the key the folder column rebuilds — "
                       + "if this ever stops holding, the rescue fetches a path that is not there")
    }
}
