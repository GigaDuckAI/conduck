// SPDX-License-Identifier: Apache-2.0

// Conduck
// ReadStateStoreTests.swift
//
// Locks `ReadStateStore` in its account-fact shape: a façade over the
// conversation record plus a short-lived optimistic overlay, owning no durable
// truth of its own.
//
// WHAT THESE CASES ARE ACTUALLY DEFENDING:
//
//   • THE ACCOUNT CUTOVER is the floor under every read marker, and an
//     unstamped cutover with no other source means "viewed" — which is what
//     keeps a fresh install with an imported iCloud history from arriving with
//     a dot on every row. It merges by `min`, never `max`: a device set up last
//     week must not be able to declare that everything before last week had
//     been read, because nothing in this app ever re-bolds a row.
//
//   • THE OVERLAY IS AN ECHO OF AN INTENT, NOT A CACHE. It is visible on the
//     very next read (backing out of a thread un-bolds its row on the same
//     runloop turn), it retires the moment the record carries the same value,
//     and — the rule that is easy to get wrong — its expiry clock starts when
//     the STORE WRITE RETURNS, not when the intent was recorded. A cold wrist
//     launch can leave the first store touch tens of seconds behind, and
//     expiring an in-flight entry would revert a row under a user who is
//     looking straight at the thread they just read.
//
//   • THE TWO MARKERS ARE STILL TWO SEPARATE FACTS, and the six cases under
//     "the two markers never contaminate each other" are the most valuable in
//     this file. The read marker is stamped the instant the user's own message
//     appears — before the send that will fail has failed — so an
//     acknowledgement derived from it would arrive pre-granted and the red mark
//     would never appear at all for anything sent from the composer.
//
//   • ACKNOWLEDGEMENT IS AN IDENTITY, NOT A TIME, and that is what retires the
//     destructive clear this class used to need. Asking again mints a NEW
//     `Message.deliveryAttemptID`, so the stored acknowledgement simply stops
//     matching and the row goes red again with nothing anywhere having to
//     un-say something. `testARetriedTurnGoesRedAgainWithNoDestructiveClear`
//     is the case that pins it.
//
//   • THE LEGACY DEFAULTS KEYS ARE A READ-SIDE FALLBACK, NOT A MIGRATION. They
//     keep answering reads until the store CONFIRMS the record covers them, and
//     only then is the key deleted — `.failed` keeps its key for the next pass,
//     because a marker deleted on an unconfirmed fold is not recoverable from
//     anywhere, on any device. Legacy FAILURE keys are swept and never folded.
//
// WHY THE WRITER IS INJECTED. `ConversationStore.shared` opens the real
// App-Group sqlite — one of the documented carve-outs from the storage seam —
// so an overlay case driving the singleton would write files beside the
// installed app's. Every case here supplies its own writer: a recording double
// for the dispatch/coalescing/TTL rules, and a genuine
// `ConversationStore(inMemory: true)` for the round-trips that have to prove a
// value really reaches a record and comes back.
//
// Every case builds its OWN `ReadStateStore` over a private
// `InMemoryDefaultsStore`. Nothing here touches `ReadStateStore.shared`, so no
// case can leak state into the next one through the singleton.

import XCTest
@testable import Conduck

// MARK: - Doubles

/// Holds a store write open, so a case can look at the overlay in the exact
/// window the TTL rule is about: the intent is recorded, the save has not
/// returned. Nothing else can produce that window deterministically — a real
/// store's first touch is fast enough on a simulator that the race is
/// unobservable, which is precisely why the bug it guards would ship.
private actor WriteGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiting
        waiting.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

/// Records what `ReadStateStore` asked the durable side to do.
///
/// An actor because `ConversationReadStateWriter` is `Sendable` and the calls
/// arrive from the unstructured `Task`s the store dispatches — a plain class
/// would be a data race the moment two stamps overlapped.
private actor RecordingReadStateWriter: ConversationReadStateWriter {
    struct ViewedCall: Equatable { let id: UUID; let at: Date }
    struct AcknowledgeCall: Equatable { let id: UUID; let attemptID: UUID }
    struct CombinedCall: Equatable { let id: UUID; let at: Date; let attemptID: UUID? }
    struct FoldCall: Equatable { let id: UUID; let localMarker: Date }

    private(set) var viewed: [ViewedCall] = []
    private(set) var acknowledgements: [AcknowledgeCall] = []
    private(set) var combined: [CombinedCall] = []
    private(set) var folds: [FoldCall] = []

    private var foldOutcome: ReadMarkerFoldOutcome = .saved
    private let gate: WriteGate?

    init(gate: WriteGate? = nil) { self.gate = gate }

    func setFoldOutcome(_ outcome: ReadMarkerFoldOutcome) { foldOutcome = outcome }

    // Every call RECORDS BEFORE IT WAITS, so a gated case can observe that the
    // write is genuinely in flight rather than merely not yet started.

    func markConversationViewed(_ id: UUID, at date: Date) async {
        viewed.append(ViewedCall(id: id, at: date))
        await gate?.wait()
    }

    func acknowledgeConversationFailure(_ id: UUID, attemptID: UUID) async {
        acknowledgements.append(AcknowledgeCall(id: id, attemptID: attemptID))
        await gate?.wait()
    }

    func markConversationViewedAndAcknowledged(_ id: UUID, at date: Date, attemptID: UUID?) async {
        combined.append(CombinedCall(id: id, at: date, attemptID: attemptID))
        await gate?.wait()
    }

    func foldLegacyReadMarker(_ id: UUID, localMarker: Date) async -> ReadMarkerFoldOutcome {
        folds.append(FoldCall(id: id, localMarker: localMarker))
        await gate?.wait()
        return foldOutcome
    }
}

// MARK: - Tests

@MainActor
final class ReadStateStoreTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Fixtures

    private func makeStore(
        defaults: InMemoryDefaultsStore = InMemoryDefaultsStore(),
        writer: any ConversationReadStateWriter = RecordingReadStateWriter()
    ) -> ReadStateStore {
        ReadStateStore(defaults: defaults, writer: writer)
    }

    /// A store wired to its OWN iCloud doubles, for the cases that exercise the
    /// account register rather than the local mirror alone.
    ///
    /// The register, its change feed and the availability answer are injected
    /// together and privately. `SettingsDependencies.processDefault` hands every
    /// suite in the process the SAME in-memory doubles, so a case that let a
    /// cutover reach those would publish a value the next case reads as its own
    /// account's — and because the meet is `min`, a stray early value STICKS
    /// rather than being overwritten by the next writer.
    private func makeCloudStore(
        defaults: InMemoryDefaultsStore = InMemoryDefaultsStore(),
        ubiquitous: InMemoryUbiquitousStore = InMemoryUbiquitousStore(),
        cloudAvailable: Bool = true
    ) -> ReadStateStore {
        ReadStateStore(
            defaults: defaults,
            writer: RecordingReadStateWriter(),
            ubiquitous: ubiquitous,
            cloudAvailability: StubCloudAvailability(available: cloudAvailable),
            changes: InMemoryKVSChangeSource(store: ubiquitous)
        )
    }

    /// Defaults that already carry a cutover — a device on its SECOND launch,
    /// whose value is therefore no longer provisional.
    private func defaultsCarryingCutover(_ value: Date) -> InMemoryDefaultsStore {
        InMemoryDefaultsStore(seed: [Constants.conversationReadStateEpochKey: value.timeIntervalSince1970])
    }

    /// What the account register actually holds, distinguishing "absent" from
    /// the 1970 an absent numeric key reads as.
    private func registerCutover(_ ubiquitous: InMemoryUbiquitousStore) -> Date? {
        guard ubiquitous.object(forKey: Constants.conversationReadCutoverKVSKey) != nil else { return nil }
        return Date(timeIntervalSince1970: ubiquitous.double(forKey: Constants.conversationReadCutoverKVSKey))
    }

    private func legacyReadKey(_ id: UUID) -> String {
        Constants.conversationReadStatePrefix + id.uuidString
    }

    private func legacyFailureKey(_ id: UUID) -> String {
        Constants.conversationFailureSeenPrefix + id.uuidString
    }

    private func record(
        _ id: UUID,
        lastActivityAt: Date? = nil,
        lastViewedAt: Date? = nil,
        failureSeenAttemptID: UUID? = nil
    ) -> ConversationRecord {
        ConversationRecord(
            id: id,
            title: nil,
            createdAt: now,
            lastActivityAt: lastActivityAt ?? now,
            sessionID: "session",
            backend: "openclaw",
            titleSnippet: nil,
            lastViewedAt: lastViewedAt,
            failureSeenAttemptID: failureSeenAttemptID
        )
    }

    /// Suspends until `condition()` holds, failing by name rather than leaving
    /// the caller's assertion to report an expiry as a logic bug.
    ///
    /// `Task.sleep` rather than a `Task.yield()` budget, and a monotonic
    /// `ContinuousClock` rather than wall time: the work being waited on is a
    /// Core Data `perform` on a private queue, which is OUTSIDE the cooperative
    /// pool, so a yield budget can drain in microseconds without that queue ever
    /// being scheduled.
    private func waitUntil(
        _ what: String,
        timeout: Duration = .seconds(10),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async throws -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline, !Task.isCancelled {
            if try await condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("timed out after \(timeout) waiting for \(what)", file: file, line: line)
    }

    /// Ask the REAL resolver whether a reply would show as unseen, so the
    /// cutover cases lock the END-TO-END answer rather than a comparison
    /// re-implemented in the test.
    private func hasUnseenReply(
        _ store: ReadStateStore,
        _ id: UUID,
        lastActivityAt: Date,
        stored: Date? = nil,
        at instant: Date
    ) -> Bool {
        ConversationActivityResolver.resolve(
            ConversationActivityInputs(
                lastActivityAt: lastActivityAt,
                newestSendingAt: nil,
                newestFailed: nil,
                storedLastViewedAt: stored,
                storedFailureSeenAttemptID: nil,
                tailRole: .agent
            ),
            locallyLiveSince: nil,
            lastViewedAt: store.lastViewed(id, stored: stored),
            now: instant
        ).hasUnseenReply
    }

    /// The same end-to-end question for the failure mark: given a failed turn
    /// and whatever the account has acknowledged, does the row still carry it?
    private func failureState(
        _ store: ReadStateStore,
        _ id: UUID,
        failedAt: Date,
        attemptID: UUID?,
        acknowledgedAttemptID: UUID?,
        stored: Date? = nil
    ) -> ConversationRowState {
        ConversationActivityResolver.resolve(
            ConversationActivityInputs(
                lastActivityAt: failedAt,
                newestSendingAt: nil,
                newestFailed: FailedTurnProjection(
                    messageID: UUID(),
                    createdAt: failedAt,
                    deliveryAttemptID: attemptID
                ),
                storedLastViewedAt: stored,
                storedFailureSeenAttemptID: acknowledgedAttemptID,
                tailRole: .user
            ),
            locallyLiveSince: nil,
            lastViewedAt: store.lastViewed(id, stored: stored),
            now: now
        )
    }

    // MARK: - The account cutover

    func testEverythingIsViewedBeforeTheCutoverIsStamped() {
        let store = makeStore()
        XCTAssertNil(store.currentAccountCutover())
        XCTAssertNil(store.lastViewed(UUID(), stored: nil),
                     "no cutover, no marker, no record value — nothing is known, and the resolver reads that as viewed")
    }

    func testAMarkerlessConversationResolvesToTheCutover() {
        let store = makeStore()
        store.stampAccountCutoverIfNeeded(now: now)
        XCTAssertEqual(store.lastViewed(UUID(), stored: nil), now)
    }

    func testImportedHistoryStaysDark() {
        // THE imported-history guarantee: a conversation whose last activity
        // predates the account's cutover is viewed, so a fresh install that
        // pulls a year of iCloud history shows zero dots.
        let store = makeStore()
        store.stampAccountCutoverIfNeeded(now: now)
        XCTAssertFalse(
            hasUnseenReply(store, UUID(), lastActivityAt: now.addingTimeInterval(-86_400), at: now)
        )
    }

    func testAReplyAfterTheCutoverIsUnseen() {
        let store = makeStore()
        store.stampAccountCutoverIfNeeded(now: now)
        XCTAssertTrue(
            hasUnseenReply(
                store,
                UUID(),
                lastActivityAt: now.addingTimeInterval(60),
                at: now.addingTimeInterval(60)
            )
        )
    }

    func testStampingTheCutoverIsIdempotent() {
        let store = makeStore()
        store.stampAccountCutoverIfNeeded(now: now)
        store.stampAccountCutoverIfNeeded(now: now.addingTimeInterval(10_000))
        XCTAssertEqual(store.currentAccountCutover(), now,
                       "a second launch must not push the cutover forward and silence everything in between")
    }

    func testTheCutoverSurvivesAReload() {
        let defaults = InMemoryDefaultsStore()
        makeStore(defaults: defaults).stampAccountCutoverIfNeeded(now: now)
        XCTAssertEqual(makeStore(defaults: defaults).currentAccountCutover(), now,
                       "the local mirror is what a synchronous offline read answers from")
    }

    func testTheCutoverMeetsDownwardsAndNeverUpwards() {
        // `min`, NEVER `max`. The account's cutover is the EARLIEST moment any
        // of its devices could have been recording; adopting a later value
        // would mark every genuinely unread reply before it as read on every
        // device at once, permanently.
        let defaults = InMemoryDefaultsStore()
        let store = makeStore(defaults: defaults)
        store.stampAccountCutoverIfNeeded(now: now)

        store.applyAccountCutover(now.addingTimeInterval(86_400))
        XCTAssertEqual(store.currentAccountCutover(), now, "a LATER account value is not adopted")

        let earlier = now.addingTimeInterval(-86_400)
        store.applyAccountCutover(earlier)
        XCTAssertEqual(store.currentAccountCutover(), earlier, "an EARLIER account value pushes the cutover down")
        XCTAssertEqual(
            defaults.double(forKey: Constants.conversationReadStateEpochKey),
            earlier.timeIntervalSince1970,
            accuracy: 0.001,
            "the pushed-down value is mirrored locally, or an offline launch reverts to the later one"
        )
    }

    func testTheCutoverKeyIsNotMistakenForALegacyMarker() {
        // The cutover key literally starts with the legacy marker prefix; the
        // load sweep must skip it rather than treat "epoch" as a conversation
        // id and try to fold it into a record that does not exist.
        let defaults = InMemoryDefaultsStore()
        makeStore(defaults: defaults).stampAccountCutoverIfNeeded(now: now)

        let reloaded = makeStore(defaults: defaults)
        XCTAssertTrue(reloaded.pendingLegacyMarkers().isEmpty)
        XCTAssertEqual(reloaded.currentAccountCutover(), now)
    }

    // MARK: - The cutover's account register (iCloud KVS)

    func testAnAbsentRegisterIsNeverReadAsNineteenSeventy() {
        // An absent numeric KVS key reads as `0` — 1 January 1970. Adopting that
        // would be catastrophic and PERMANENT: `min` would lock the account's
        // cutover at 1970, every conversation would arrive bold on every device,
        // and no later value could ever raise it again.
        let store = makeCloudStore()
        store.resolveAccountCutover(now: now)
        XCTAssertEqual(store.currentAccountCutover(), now,
                       "an empty register must leave this device's own stamp alone")
    }

    func testAnEarlierRegisterValueIsAdoptedAndMirroredLocally() {
        let earlier = now.addingTimeInterval(-86_400)
        let defaults = InMemoryDefaultsStore()
        let ubiquitous = InMemoryUbiquitousStore(
            seed: [Constants.conversationReadCutoverKVSKey: earlier.timeIntervalSince1970]
        )
        let store = makeCloudStore(defaults: defaults, ubiquitous: ubiquitous)

        store.resolveAccountCutover(now: now)

        XCTAssertEqual(store.currentAccountCutover(), earlier,
                       "the account was recording before this device existed, so its value wins")
        XCTAssertEqual(
            defaults.double(forKey: Constants.conversationReadStateEpochKey),
            earlier.timeIntervalSince1970,
            accuracy: 0.001,
            "the adopted value must reach the local mirror, or the next offline launch reverts to this device's own stamp"
        )
        XCTAssertEqual(registerCutover(ubiquitous), earlier,
                       "this device's LATER value must never be pushed up")
    }

    func testALaterRegisterValueDoesNotRaiseThisDevice() {
        let earlier = now.addingTimeInterval(-86_400)
        let store = makeCloudStore(
            defaults: defaultsCarryingCutover(earlier),
            ubiquitous: InMemoryUbiquitousStore(
                seed: [Constants.conversationReadCutoverKVSKey: now.timeIntervalSince1970]
            )
        )

        store.resolveAccountCutover(now: now)

        XCTAssertEqual(store.currentAccountCutover(), earlier,
                       "adopting the later value would declare a day of genuinely unread replies already read")
    }

    func testThisDevicesEarlierValueIsPushedDownIntoTheRegister() {
        // Push DOWN, never up: the account converges on the earliest moment any
        // of its devices could have been recording.
        let earlier = now.addingTimeInterval(-86_400)
        let ubiquitous = InMemoryUbiquitousStore(
            seed: [Constants.conversationReadCutoverKVSKey: now.timeIntervalSince1970]
        )
        let store = makeCloudStore(defaults: defaultsCarryingCutover(earlier), ubiquitous: ubiquitous)

        store.resolveAccountCutover(now: now)

        XCTAssertEqual(registerCutover(ubiquitous), earlier,
                       "an earlier local value lowers the register so every other device converges on it")
    }

    func testAValueMintedThisLaunchIsNotSeededIntoAnEmptyRegister() {
        // PROVISIONAL. Silence right after `synchronize()` is not evidence the
        // key is absent — KVS is empty on a device that has never completed a
        // first download. Seeding here would publish a cutover LATER than the
        // account's truth and hide unread replies on every other device until
        // one of them next launched.
        let ubiquitous = InMemoryUbiquitousStore()
        let store = makeCloudStore(ubiquitous: ubiquitous)

        store.resolveAccountCutover(now: now)

        XCTAssertEqual(store.currentAccountCutover(), now, "the value is still used locally")
        XCTAssertNil(registerCutover(ubiquitous), "but it is not published on non-evidence")
    }

    func testACutoverCarriedOverFromAnEarlierLaunchSeedsAnEmptyRegister() {
        // Not provisional: a value loaded from the mirror has already survived a
        // whole session's worth of downloading, so an empty register beside it
        // really is an empty register.
        let ubiquitous = InMemoryUbiquitousStore()
        let earlier = now.addingTimeInterval(-86_400)
        let store = makeCloudStore(defaults: defaultsCarryingCutover(earlier), ubiquitous: ubiquitous)

        store.resolveAccountCutover(now: now)

        XCTAssertEqual(registerCutover(ubiquitous), earlier)
    }

    func testACloudDeliveryRetiresTheProvisionalHold() async throws {
        let ubiquitous = InMemoryUbiquitousStore()
        let store = makeCloudStore(ubiquitous: ubiquitous)
        store.resolveAccountCutover(now: now)
        XCTAssertNil(registerCutover(ubiquitous))

        // A delivery naming an UNRELATED key still proves the store has
        // downloaded — which is the whole point of not filtering on
        // `changedKeys`, since that list can never name a key the register does
        // not hold.
        ubiquitous.simulateRemoteChange(values: [Constants.sttPreferredLanguageKVSKey: "en-US"])

        try await waitUntil("the provisional stamp to be published once iCloud has spoken") {
            registerCutover(ubiquitous) != nil
        }
        XCTAssertEqual(registerCutover(ubiquitous), now)
    }

    func testADeliveredChangeIsProofEnoughForADeviceWithNoUbiquityToken() async throws {
        // The wrist. `CloudAvailability` tracks iCloud DRIVE, which does not
        // exist on watchOS, so the token is ALWAYS nil there — a delivered
        // change is the Watch's only honest proof that the store is live.
        let ubiquitous = InMemoryUbiquitousStore()
        let store = makeCloudStore(ubiquitous: ubiquitous, cloudAvailable: false)
        store.resolveAccountCutover(now: now)

        ubiquitous.simulateRemoteChange(values: [Constants.sttPreferredLanguageKVSKey: "en-US"])

        try await waitUntil("the wrist to publish once a change proves the store is live") {
            registerCutover(ubiquitous) != nil
        }
        XCTAssertEqual(registerCutover(ubiquitous), now)
    }

    func testADeviceWithNoICloudStampsReadsLocallyAndPublishesNothing() {
        // Coherent rather than degraded: with no iCloud there is no CloudKit
        // mirror either, so this is a single-device world and the local value IS
        // the account value.
        let ubiquitous = InMemoryUbiquitousStore()
        let earlier = now.addingTimeInterval(-86_400)
        let store = makeCloudStore(
            defaults: defaultsCarryingCutover(earlier),
            ubiquitous: ubiquitous,
            cloudAvailable: false
        )

        store.resolveAccountCutover(now: now)

        XCTAssertEqual(store.currentAccountCutover(), earlier, "reads still answer from the local mirror")
        XCTAssertNil(registerCutover(ubiquitous), "nothing is published from a device with no account")
    }

    func testAQuotaViolationIsNotEvidenceThatTheStoreHasDownloaded() {
        // A quota violation or an account change carries no inbound delta, so it
        // must not retire the provisional hold.
        let ubiquitous = InMemoryUbiquitousStore()
        let store = makeCloudStore(ubiquitous: ubiquitous)
        store.resolveAccountCutover(now: now)

        store.handleAccountCutoverChange(KVSChange(reason: .quotaViolationChange, changedKeys: []))
        XCTAssertNil(registerCutover(ubiquitous))

        store.handleAccountCutoverChange(KVSChange(reason: .accountChange, changedKeys: []))
        XCTAssertNil(registerCutover(ubiquitous),
                     "neither reason delivers remote values, so neither proves the register is genuinely empty")
    }

    func testMeetCutoverIsTheEarliestOpinionAnyoneHolds() {
        let earlier = now.addingTimeInterval(-86_400)
        XCTAssertEqual(ReadStateStore.meetCutover(now, earlier), earlier)
        XCTAssertEqual(ReadStateStore.meetCutover(earlier, now), earlier, "commutative")
        XCTAssertEqual(ReadStateStore.meetCutover(earlier, earlier), earlier, "idempotent")
        XCTAssertEqual(ReadStateStore.meetCutover(nil, now), now, "no opinion never vetoes one")
        XCTAssertEqual(ReadStateStore.meetCutover(now, nil), now, "an empty register never erases a device's value")
        XCTAssertNil(ReadStateStore.meetCutover(nil, nil))
    }

    // MARK: - lastViewed folds four sources by max

    func testTheStoredRecordMarkerAnswersReadsOnItsOwn() {
        let store = makeStore()
        let stored = now.addingTimeInterval(600)
        XCTAssertEqual(store.lastViewed(UUID(), stored: stored), stored,
                       "the record is the durable truth — this class holds nothing of its own for a fresh conversation")
    }

    func testTheCutoverIsAFloorUnderAnOlderStoredMarker() {
        let store = makeStore()
        store.stampAccountCutoverIfNeeded(now: now)
        XCTAssertEqual(store.lastViewed(UUID(), stored: now.addingTimeInterval(-600)), now)
    }

    func testTheOverlayLeadsAStoredMarkerThatHasNotCaughtUp() {
        let store = makeStore()
        let id = UUID()
        store.markViewed(id, lastActivityAt: nil, now: now.addingTimeInterval(600))
        XCTAssertEqual(store.lastViewed(id, stored: now), now.addingTimeInterval(600),
                       "a stale record must not drag the answer back behind an intent this device already has")
    }

    func testALateStoredMarkerFromAnotherDeviceMovesTheAnswerForward() {
        let store = makeStore()
        let id = UUID()
        store.markViewed(id, lastActivityAt: nil, now: now)
        XCTAssertEqual(store.lastViewed(id, stored: now.addingTimeInterval(600)), now.addingTimeInterval(600),
                       "reading on the iPad clears the dot here — `max` means an out-of-order arrival can only move forward")
    }

    // MARK: - clamped (pure, no store)

    func testClampedIsMonotonicAgainstABackwardsClock() {
        XCTAssertEqual(
            ReadStateStore.clamped(existing: now.addingTimeInterval(600), reference: nil, now: now),
            now.addingTimeInterval(600),
            "a clock that moves backwards can never resurrect already-seen state"
        )
    }

    func testClampedWithNothingToBeatIsNow() {
        XCTAssertEqual(ReadStateStore.clamped(existing: nil, reference: nil, now: now), now)
    }

    func testClampedAbsorbsAModestlyAheadReferenceExactly() {
        // A row mirrored from a device whose clock runs a minute or two ahead:
        // absorbed as-is, or its own activity would stay newer than the marker
        // and its row would stay bold while the user is looking straight at it.
        let slightlyAhead = now.addingTimeInterval(90)
        XCTAssertEqual(
            ReadStateStore.clamped(existing: nil, reference: slightlyAhead, now: now),
            slightlyAhead
        )
    }

    func testClampedCapsAWildlyAheadReferenceAtTheSkewGrace() {
        // A device a month fast must not be able to poison this marker into the
        // future and suppress a month of genuinely new activity. The residual
        // failure is a stuck marker, not silence.
        XCTAssertEqual(
            ReadStateStore.clamped(existing: nil, reference: now.addingTimeInterval(30 * 86_400), now: now),
            now.addingTimeInterval(ReadStateStore.clockSkewGrace)
        )
    }

    func testClampedAnchorsOnTheTailRatherThanOnTheClock() {
        // THE CASE THE WHOLE COALESCING CHAIN RESTS ON. An older tail is what
        // the marker has to cover, and the unseen test is strict
        // (`lastActivityAt > effectiveViewedAt`), so a marker EQUAL to it
        // already reads as seen. Anchoring at `now` instead would make every
        // single call produce a strictly larger value, and no "write only when
        // the value moves" guard downstream could ever fire.
        XCTAssertEqual(
            ReadStateStore.clamped(existing: nil, reference: now.addingTimeInterval(-5_000), now: now),
            now.addingTimeInterval(-5_000),
            "the marker covers the tail, so a repeat view of an unchanged thread computes the same value"
        )
    }

    func testClampedNeverFallsBehindAMarkerThatAlreadyCoversMore() {
        // A caller holding a STALE reference — a thread stamping before its
        // messages have loaded — must not drag the marker back behind one that
        // already covers a newer tail.
        XCTAssertEqual(
            ReadStateStore.clamped(
                existing: now, reference: now.addingTimeInterval(-5_000), now: now
            ),
            now
        )
    }

    // MARK: - markViewed

    func testAnOptimisticMarkerIsVisibleOnTheVeryNextRead() async throws {
        // THE reason the overlay exists. The durable write is a background save
        // that has to come back round as a fetch; without the echo, backing out
        // of a thread would leave its row bold for as long as that takes.
        let store = makeStore()
        let id = UUID()
        store.markViewed(id, lastActivityAt: nil, now: now)
        XCTAssertEqual(store.lastViewed(id, stored: nil), now, "no await, no fetch — the same runloop turn")
        XCTAssertEqual(store.overlayMarkers()[id], now)
    }

    func testMarkViewedDispatchesTheClampedMarkerToTheStore() async throws {
        let writer = RecordingReadStateWriter()
        let store = makeStore(writer: writer)
        let id = UUID()
        store.markViewed(id, lastActivityAt: now.addingTimeInterval(90), now: now)

        try await waitUntil("the store write to be dispatched") { await writer.viewed.count == 1 }
        let dispatched = await writer.viewed.first
        XCTAssertEqual(dispatched,
                       RecordingReadStateWriter.ViewedCall(id: id, at: now.addingTimeInterval(90)),
                       "the record gets the clamped marker, not the raw `now`")
    }

    func testMarkViewedCoalescesARepeatOfTheSameTailIntoNoStoreWriteAtAll() async throws {
        // THE PRODUCTION CASE, and the reason the marker is anchored on the tail
        // rather than on the clock: the clock ALWAYS advances between two views
        // of the same thread. A macOS window activation, a return to the
        // foreground, the `.onAppear` followed by the first tail-id change —
        // each re-stamps an UNCHANGED thread with a later `now`. Anchoring
        // there would export a CKRecord and fan a whole-list refetch every time.
        let writer = RecordingReadStateWriter()
        let store = makeStore(writer: writer)
        let id = UUID()
        let tail = now.addingTimeInterval(-30)

        store.markViewed(id, lastActivityAt: tail, now: now)
        try await waitUntil("the first store write") { await writer.viewed.count == 1 }

        store.markViewed(id, lastActivityAt: tail, now: now.addingTimeInterval(600))
        store.markViewed(id, lastActivityAt: tail, now: now.addingTimeInterval(1_200))

        XCTAssertEqual(store.lastViewed(id, stored: nil), tail)
        let viewedCount = await writer.viewed.count
        XCTAssertEqual(viewedCount, 1,
                       "a stamp that does not move the marker dispatches nothing — the guard is synchronous, so no second task exists")
    }

    func testMarkViewedIsMonotonicAgainstABackwardsClock() async throws {
        let writer = RecordingReadStateWriter()
        let store = makeStore(writer: writer)
        let id = UUID()
        store.markViewed(id, lastActivityAt: nil, now: now.addingTimeInterval(600))
        try await waitUntil("the first store write") { await writer.viewed.count == 1 }

        store.markViewed(id, lastActivityAt: nil, now: now)   // clock moved back

        XCTAssertEqual(store.lastViewed(id, stored: nil), now.addingTimeInterval(600))
        let viewedCount = await writer.viewed.count
        XCTAssertEqual(viewedCount, 1)
    }

    func testANewTailStillMovesTheMarkerAndWritesAgain() async throws {
        // The other half of the anchor: coalescing must never swallow a genuine
        // new tail, or a reply landing in an open thread would stay bold on
        // every other device.
        let writer = RecordingReadStateWriter()
        let store = makeStore(writer: writer)
        let id = UUID()
        let firstTail = now.addingTimeInterval(-30)

        store.markViewed(id, lastActivityAt: firstTail, now: now)
        try await waitUntil("the first store write") { await writer.viewed.count == 1 }

        let secondTail = now.addingTimeInterval(5)
        store.markViewed(id, lastActivityAt: secondTail, now: now.addingTimeInterval(5))
        try await waitUntil("the second store write") { await writer.viewed.count == 2 }

        XCTAssertEqual(store.lastViewed(id, stored: nil), secondTail)
    }

    // MARK: - The overlay retires; it is never durable truth

    func testTheOverlayRetiresOnceTheRecordCatchesUp() {
        let store = makeStore()
        let id = UUID()
        store.markViewed(id, lastActivityAt: nil, now: now)
        XCTAssertFalse(store.overlayMarkers().isEmpty)

        store.reconcile(with: [record(id, lastViewedAt: now)], now: now)

        XCTAssertTrue(store.overlayMarkers().isEmpty, "the echo has nothing left to add once the record carries it")
        XCTAssertEqual(store.lastViewed(id, stored: now), now, "and the answer does not change when it goes")
    }

    func testAnOverlayAheadOfTheRecordSurvivesReconcile() {
        let store = makeStore()
        let id = UUID()
        store.markViewed(id, lastActivityAt: nil, now: now.addingTimeInterval(600))

        store.reconcile(with: [record(id, lastViewedAt: now)], now: now.addingTimeInterval(600))

        XCTAssertEqual(store.overlayMarkers()[id], now.addingTimeInterval(600),
                       "the record is still behind this device's intent — dropping the echo would re-bold the row")
    }

    func testReconcileIgnoresConversationsAbsentFromTheFetch() {
        // Absence from a fetch means NOTHING: a filtered list, a partial local
        // mirror before the CloudKit import lands, and a real deletion are
        // indistinguishable from here, and only the last of them justifies
        // dropping anything.
        let store = makeStore()
        let id = UUID()
        store.markViewed(id, lastActivityAt: nil, now: now)

        store.reconcile(with: [], now: now)

        XCTAssertEqual(store.overlayMarkers()[id], now)
    }

    func testAnOverlayEntryWhoseStoreWriteIsStillInFlightNeverExpires() async throws {
        // THE TTL RULE. The store's first touch has to open sqlite and CloudKit
        // metadata, which on a cold wrist launch can sit tens of seconds behind.
        // An entry expiring in that window reverts the row under a user who is
        // looking straight at the thread they just read.
        let gate = WriteGate()
        let writer = RecordingReadStateWriter(gate: gate)
        let store = makeStore(writer: writer)
        let id = UUID()
        store.markViewed(id, lastActivityAt: nil, now: now)
        try await waitUntil("the store write to be in flight") { await writer.viewed.count == 1 }

        store.reconcile(with: [], now: now.addingTimeInterval(ReadStateStore.overlaySettledTTL * 100))

        XCTAssertEqual(store.overlayMarkers()[id], now,
                       "the clock cannot start on a value the store has not seen yet")
        await gate.open()
    }

    func testTheTTLClockStartsWhenTheStoreWriteReturns() async throws {
        let gate = WriteGate()
        let writer = RecordingReadStateWriter(gate: gate)
        let store = makeStore(writer: writer)
        let id = UUID()
        let farFuture = now.addingTimeInterval(ReadStateStore.overlaySettledTTL * 100)
        store.markViewed(id, lastActivityAt: nil, now: now)
        try await waitUntil("the store write to be in flight") { await writer.viewed.count == 1 }

        store.reconcile(with: [], now: farFuture)
        XCTAssertNotNil(store.overlayMarkers()[id], "still in flight")

        await gate.open()

        // The settle happens on the main actor as the dispatched task returns,
        // so the observable fact is that a far-future reconcile now retires the
        // entry — where a moment ago the same call kept it.
        try await waitUntil("the settled entry to age out") {
            store.reconcile(with: [], now: Date().addingTimeInterval(ReadStateStore.overlaySettledTTL * 100))
            return store.overlayMarkers().isEmpty
        }
    }

    // MARK: - forget

    func testForgetDropsTheOverlayEcho() {
        let store = makeStore()
        let kept = UUID()
        let doomed = UUID()
        store.markViewed(kept, lastActivityAt: nil, now: now)
        store.markViewed(doomed, lastActivityAt: nil, now: now)

        store.forget(doomed)

        XCTAssertNil(store.overlayMarkers()[doomed])
        XCTAssertEqual(store.overlayMarkers()[kept], now, "forget names one conversation and touches no other")
    }

    func testForgetDeletesThatConversationsLegacyKey() {
        // A REAL DELETION is the one authoritative signal that a legacy key is
        // dead. Its record is gone, so the key can never fold; absence from a
        // fetch would not justify this, but a delete does.
        let doomed = UUID()
        let kept = UUID()
        let defaults = InMemoryDefaultsStore(seed: [
            legacyReadKey(doomed): now.timeIntervalSince1970,
            legacyReadKey(kept): now.timeIntervalSince1970
        ])
        let store = makeStore(defaults: defaults)

        store.forget(doomed)

        XCTAssertNil(defaults.object(forKey: legacyReadKey(doomed)))
        XCTAssertNotNil(defaults.object(forKey: legacyReadKey(kept)))
        XCTAssertEqual(Array(store.pendingLegacyMarkers().keys), [kept])
    }

    func testForgetOnAnUnknownConversationIsANoOp() {
        let defaults = InMemoryDefaultsStore()
        let store = makeStore(defaults: defaults)
        store.forget(UUID())
        XCTAssertTrue(store.overlayMarkers().isEmpty)
        XCTAssertTrue(store.pendingLegacyMarkers().isEmpty)
        XCTAssertTrue(defaults.dictionaryRepresentation().isEmpty)
    }

    // MARK: - The legacy keys are a read-side fallback, not a migration

    func testUnparsableKeysUnderTheReadPrefixArePrunedOnLoad() {
        let defaults = InMemoryDefaultsStore(seed: [
            Constants.conversationReadStatePrefix + "not-a-uuid": 12.0,
            Constants.conversationReadStatePrefix + UUID().uuidString: "not-a-number",
            "unrelated.key": 7
        ])
        let store = makeStore(defaults: defaults)

        let survivors = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(Constants.conversationReadStatePrefix) }
        XCTAssertTrue(survivors.isEmpty, "garbage under the prefix can never fold, so it only grows the sweep")
        XCTAssertTrue(store.pendingLegacyMarkers().isEmpty)
        XCTAssertNotNil(defaults.object(forKey: "unrelated.key"))
    }

    func testLegacyFailureAcknowledgementsAreSweptAtInitAndNeverFolded() async throws {
        // THE ASYMMETRY WITH THE READ PREFIX, LOCKED. The old marker is a TIME
        // and the new acknowledgement is an ATTEMPT IDENTITY, so folding one
        // would have to invent an identity for whatever attempt happens to be
        // failed right now — and a turn retried after the upgrade keeps its
        // `createdAt`, so that invented cover would silence its re-failure
        // permanently. The safe failure mode is one extra red mark, not a
        // hidden one. Nothing will ever read these again, so the one pass that
        // already visits them retires them.
        let id = UUID()
        let defaults = InMemoryDefaultsStore(seed: [
            legacyFailureKey(id): now.timeIntervalSince1970,
            Constants.conversationFailureSeenPrefix + "not-a-uuid": 12.0,
            "unrelated.key": 7
        ])
        let writer = RecordingReadStateWriter()
        let store = makeStore(defaults: defaults, writer: writer)

        let survivors = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(Constants.conversationFailureSeenPrefix) }
        XCTAssertTrue(survivors.isEmpty, "a well-formed legacy acknowledgement is retired, not kept for later")
        XCTAssertTrue(store.pendingLegacyMarkers().isEmpty, "and it is never loaded as something foldable")
        XCTAssertNotNil(defaults.object(forKey: "unrelated.key"))

        store.reconcile(with: [record(id)], now: now)
        let acknowledgements = await writer.acknowledgements
        let folds = await writer.folds
        XCTAssertTrue(acknowledgements.isEmpty, "no reconcile pass ever folds one into a record")
        XCTAssertTrue(folds.isEmpty)
    }

    func testALegacyMarkerAnswersReadsUntilItsFoldIsConfirmed() async throws {
        let id = UUID()
        let marker = now.addingTimeInterval(-600)
        let defaults = InMemoryDefaultsStore(seed: [legacyReadKey(id): marker.timeIntervalSince1970])
        let writer = RecordingReadStateWriter()
        await writer.setFoldOutcome(.saved)
        let store = makeStore(defaults: defaults, writer: writer)

        XCTAssertEqual(store.lastViewed(id, stored: nil), marker,
                       "before any fold, the key is the only thing keeping this row from going bold")

        store.reconcile(with: [record(id)], now: now)

        try await waitUntil("the fold to be dispatched") { await writer.folds.count == 1 }
        let firstFold = await writer.folds.first
        XCTAssertEqual(firstFold,
                       RecordingReadStateWriter.FoldCall(id: id, localMarker: marker))
        try await waitUntil("the confirmed key to retire") { store.pendingLegacyMarkers().isEmpty }
        XCTAssertNil(defaults.object(forKey: legacyReadKey(id)))
        XCTAssertEqual(store.lastViewed(id, stored: marker), marker, "the record answers it now")
    }

    func testAnAlreadyCoveredFoldAlsoRetiresTheKey() async throws {
        let id = UUID()
        let defaults = InMemoryDefaultsStore(seed: [legacyReadKey(id): now.timeIntervalSince1970])
        let writer = RecordingReadStateWriter()
        await writer.setFoldOutcome(.alreadyCovered)
        let store = makeStore(defaults: defaults, writer: writer)

        store.reconcile(with: [record(id)], now: now)

        try await waitUntil("the covered key to retire") { store.pendingLegacyMarkers().isEmpty }
        XCTAssertNil(defaults.object(forKey: legacyReadKey(id)),
                     "the record is already at or past the marker — there is nothing left to lose")
    }

    func testAConfirmedFoldStillAnswersReadsUntilTheRecordIsREFETCHED() async throws {
        // THE SECOND GAP, and the one that is easy to miss. Confirmation means
        // the RECORD carries the marker — not that this device has fetched the
        // record again. The fold deliberately posts no change notification, so
        // the `ConversationRecord` snapshots the list is rendering still say
        // `lastViewedAt == nil`. Dropping the marker at that moment takes it out
        // of `lastViewed`'s fold with nothing replacing it, and because these
        // reads happen inside a SwiftUI `body` over `@Observable` stored state,
        // every row that key covered repaints bold on the spot — on the first
        // launch after the upgrade, for as long as the list stays idle.
        let id = UUID()
        let marker = now.addingTimeInterval(-600)
        let defaults = InMemoryDefaultsStore(seed: [legacyReadKey(id): marker.timeIntervalSince1970])
        let writer = RecordingReadStateWriter()
        await writer.setFoldOutcome(.saved)
        let store = makeStore(defaults: defaults, writer: writer)

        store.reconcile(with: [record(id)], now: now)
        try await waitUntil("the confirmed key to retire") { store.pendingLegacyMarkers().isEmpty }

        XCTAssertEqual(
            store.lastViewed(id, stored: nil), marker,
            "the record has it, but the list is still rendering the snapshot that does not"
        )
        XCTAssertEqual(store.overlayMarkers()[id], marker, "handed to the overlay, not dropped")
    }

    func testTheHandedOverMarkerRetiresWHENTheRecordIsObservedToCarryIt() async throws {
        // And it retires through the one mechanism that actually checks — the
        // same `reconcile` step 1 that retires every other optimistic echo. A
        // marker that outlived its record would be harmless; one that died
        // before it is a re-bolded row.
        let id = UUID()
        let marker = now.addingTimeInterval(-600)
        let defaults = InMemoryDefaultsStore(seed: [legacyReadKey(id): marker.timeIntervalSince1970])
        let writer = RecordingReadStateWriter()
        await writer.setFoldOutcome(.saved)
        let store = makeStore(defaults: defaults, writer: writer)

        store.reconcile(with: [record(id)], now: now)
        try await waitUntil("the confirmed key to retire") { store.pendingLegacyMarkers().isEmpty }

        // Still nothing on the record: the echo stands.
        store.reconcile(with: [record(id)], now: now)
        XCTAssertEqual(store.overlayMarkers()[id], marker)

        // The refetch finally carries it.
        store.reconcile(with: [record(id, lastViewedAt: marker)], now: now)
        XCTAssertTrue(store.overlayMarkers().isEmpty)
        XCTAssertEqual(store.lastViewed(id, stored: marker), marker)
    }

    func testAFailedFoldKeepsItsKeyForTheNextPass() async throws {
        // CONFIRM, THEN DELETE. A lost read marker is not recoverable from
        // anywhere, on any device: the conversation reverts to unread
        // everywhere with nothing left to repair it from.
        let id = UUID()
        let marker = now.addingTimeInterval(-600)
        let defaults = InMemoryDefaultsStore(seed: [legacyReadKey(id): marker.timeIntervalSince1970])
        let writer = RecordingReadStateWriter()
        await writer.setFoldOutcome(.failed)
        let store = makeStore(defaults: defaults, writer: writer)

        store.reconcile(with: [record(id)], now: now)
        try await waitUntil("the failed fold to return") { await writer.folds.count == 1 }

        XCTAssertEqual(store.pendingLegacyMarkers()[id], marker)
        XCTAssertNotNil(defaults.object(forKey: legacyReadKey(id)))
        XCTAssertEqual(store.lastViewed(id, stored: nil), marker, "and it keeps answering reads meanwhile")
    }

    func testOnlyConversationsPresentInTheFetchAreFolded() async throws {
        // PER CONVERSATION ACTUALLY PRESENT, never a sweep over the keys. A key
        // whose conversation has not imported yet has nothing to fold into, and
        // treating its absence as "nothing to do" is exactly the one-shot
        // migration this design rejects.
        let present = UUID()
        let absent = UUID()
        let defaults = InMemoryDefaultsStore(seed: [
            legacyReadKey(present): now.timeIntervalSince1970,
            legacyReadKey(absent): now.timeIntervalSince1970
        ])
        let writer = RecordingReadStateWriter()
        let store = makeStore(defaults: defaults, writer: writer)

        store.reconcile(with: [record(present)], now: now)

        try await waitUntil("the present conversation to fold") { await writer.folds.count == 1 }
        let foldedIDs = await writer.folds.map(\.id)
        XCTAssertEqual(foldedIDs, [present])
        try await waitUntil("the folded key to retire") { store.pendingLegacyMarkers().keys.contains(absent) && store.pendingLegacyMarkers().count == 1 }
        XCTAssertNotNil(defaults.object(forKey: legacyReadKey(absent)),
                        "an import that has not landed yet is NOT a deletion")
    }

    func testTheLegacyDrainIsBoundedPerReconcilePass() async throws {
        // The first launch after the upgrade can hold thousands of keys, and a
        // store round-trip per key in a single main-actor turn would stall the
        // list fetch that triggered it. Undrained keys wait for the next pass
        // and keep answering reads meanwhile, so the delay is invisible.
        let ids = (0..<(ReadStateStore.maxLegacyFoldsPerPass + 5)).map { _ in UUID() }
        var seed: [String: Any] = [:]
        for id in ids { seed[legacyReadKey(id)] = now.timeIntervalSince1970 }
        let writer = RecordingReadStateWriter()
        await writer.setFoldOutcome(.failed)
        let store = makeStore(defaults: InMemoryDefaultsStore(seed: seed), writer: writer)

        store.reconcile(with: ids.map { record($0) }, now: now)

        try await waitUntil("the bounded batch to be dispatched") {
            await writer.folds.count == ReadStateStore.maxLegacyFoldsPerPass
        }
        let foldCount = await writer.folds.count
        XCTAssertEqual(foldCount, ReadStateStore.maxLegacyFoldsPerPass,
                       "one pass dispatches at most maxLegacyFoldsPerPass folds")
        XCTAssertEqual(store.pendingLegacyMarkers().count, ids.count, "and a .failed fold keeps every key")
    }

    func testTheUndrainableLegacyResidueIsBoundedOldestFirst() {
        // The one residue this design cannot drain: a key whose conversation
        // never reappears locally — deleted on another device before this one
        // imported. Absence from a fetch is not proof of deletion, so it can
        // never retire on that evidence; the ceiling covers it instead, oldest
        // first because an old marker's conversation sits far down a list
        // sorted by activity and is the least likely to still matter.
        let oldest = UUID()
        var seed: [String: Any] = [legacyReadKey(oldest): now.addingTimeInterval(-1_000_000).timeIntervalSince1970]
        for index in 0..<ReadStateStore.maxLegacyMarkers {
            seed[legacyReadKey(UUID())] = now.addingTimeInterval(Double(index)).timeIntervalSince1970
        }
        let defaults = InMemoryDefaultsStore(seed: seed)
        let store = makeStore(defaults: defaults)

        XCTAssertEqual(store.pendingLegacyMarkers().count, ReadStateStore.maxLegacyMarkers)
        XCTAssertNil(store.pendingLegacyMarkers()[oldest], "the oldest marker is the one dropped")
        XCTAssertNil(defaults.object(forKey: legacyReadKey(oldest)), "and its key goes with it")
    }

    // MARK: - Acknowledgement is an identity, and it is dispatched, never overlaid

    func testAcknowledgeFailureDispatchesTheAttemptIdentity() async throws {
        let writer = RecordingReadStateWriter()
        let store = makeStore(writer: writer)
        let id = UUID()
        let attempt = UUID()

        store.acknowledgeFailure(id, attemptID: attempt)

        try await waitUntil("the acknowledgement to be dispatched") { await writer.acknowledgements.count == 1 }
        let firstAcknowledgement = await writer.acknowledgements.first
        XCTAssertEqual(firstAcknowledgement,
                       RecordingReadStateWriter.AcknowledgeCall(id: id, attemptID: attempt))
    }

    func testANilAttemptIDAcknowledgesNothingAndTheRowStaysRed() async throws {
        // NIL IS A NO-OP, NOT A CLEAR AND NOT A WILDCARD. A failed turn with no
        // attempt id is a row from before the attribute existed, or one retried
        // by a build that mints none; storing "seen nothing" would either mean
        // nothing or match the next id-less failure by accident.
        let writer = RecordingReadStateWriter()
        let store = makeStore(writer: writer)
        let id = UUID()

        store.acknowledgeFailure(id, attemptID: nil)

        // The guard is synchronous — no task is created at all, so an empty log
        // here is a fact rather than a race.
        let dispatchedAcknowledgements = await writer.acknowledgements
        XCTAssertTrue(dispatchedAcknowledgements.isEmpty)
        XCTAssertFalse(
            failureState(store, id, failedAt: now, attemptID: nil, acknowledgedAttemptID: nil).failureAcknowledged,
            "and the mark stays: an unacknowledged failure costs a tap, a silenced one costs the message"
        )
    }

    func testAcknowledgementGetsNoOverlay() {
        // No device-local value can say WHICH attempt the account has seen, so
        // the mark retires when the RECORD does and not a moment earlier.
        let store = makeStore()
        let id = UUID()
        store.acknowledgeFailure(id, attemptID: UUID())
        XCTAssertTrue(store.overlayMarkers().isEmpty)
        XCTAssertNil(store.lastViewed(id, stored: nil))
    }

    // MARK: - Both markers on one user action

    func testTheCombinedCallLandsBothInOneTransaction() async throws {
        // The macOS menu bar is that surface: one click is simultaneously "I
        // have looked at this" and "I have seen its failure". Two calls would
        // produce two saves, two change posts and two CKRecord exports per
        // opening, and would let a reload land between them and paint the row
        // half-updated.
        let writer = RecordingReadStateWriter()
        let store = makeStore(writer: writer)
        let id = UUID()
        let attempt = UUID()

        store.markViewedAndAcknowledgeFailure(id, lastActivityAt: nil, attemptID: attempt, now: now)

        try await waitUntil("the combined write") { await writer.combined.count == 1 }
        let firstCombined = await writer.combined.first
        let singleViewed = await writer.viewed
        let singleAcknowledgements = await writer.acknowledgements
        XCTAssertEqual(firstCombined,
                       RecordingReadStateWriter.CombinedCall(id: id, at: now, attemptID: attempt))
        XCTAssertTrue(singleViewed.isEmpty, "not routed through the two single-marker writers")
        XCTAssertTrue(singleAcknowledgements.isEmpty)
        XCTAssertEqual(store.overlayMarkers()[id], now, "and the view half still gets its optimistic echo")
    }

    func testTheCombinedCallAcknowledgesEvenWhenTheOverlayDoesNotMove() async throws {
        // The coalescing guard belongs to the VIEW marker alone. The user has
        // seen this failure whether or not their read marker moved, and letting
        // the guard swallow the acknowledgement would leave the row red on
        // every device after the click that was supposed to retire it.
        let writer = RecordingReadStateWriter()
        let store = makeStore(writer: writer)
        let id = UUID()
        let attempt = UUID()
        store.markViewed(id, lastActivityAt: nil, now: now)
        try await waitUntil("the first write") { await writer.viewed.count == 1 }

        store.markViewedAndAcknowledgeFailure(id, lastActivityAt: nil, attemptID: attempt, now: now)

        try await waitUntil("the combined write") { await writer.combined.count == 1 }
        let combinedCall = await writer.combined.first
        XCTAssertEqual(combinedCall,
                       RecordingReadStateWriter.CombinedCall(id: id, at: now, attemptID: attempt))
    }

    func testTheCombinedCallWithNoAttemptStillMarksViewed() async throws {
        let writer = RecordingReadStateWriter()
        let store = makeStore(writer: writer)
        let id = UUID()

        store.markViewedAndAcknowledgeFailure(id, lastActivityAt: nil, attemptID: nil, now: now)

        try await waitUntil("the combined write") { await writer.combined.count == 1 }
        let combinedAttemptID = await writer.combined.first?.attemptID
        XCTAssertEqual(combinedAttemptID, nil,
                       "nil rides through as nil — the store treats it as 'acknowledge nothing', never as a clear")
        XCTAssertEqual(store.overlayMarkers()[id], now)
    }

    // MARK: - The two markers never contaminate each other

    func testMarkingViewedNeverAcknowledgesAFailure() async throws {
        // THE defect the second marker exists to prevent, now proved against a
        // real record. The read marker is stamped the instant the user's own
        // message appears — before the send that will fail has failed — so if
        // acknowledgement read from it, every composer-sent failure would
        // arrive pre-acknowledged and the red mark would never appear at all.
        let conversations = ConversationStore(inMemory: true)
        let created = try await conversations.createConversation(backend: "openclaw")
        let store = makeStore(writer: conversations)

        store.markViewed(created.id, lastActivityAt: now, now: now)

        try await waitUntil("the view marker to reach the record") {
            try await self.fetched(created.id, from: conversations)?.lastViewedAt == self.now
        }
        let record = try await fetched(created.id, from: conversations)
        XCTAssertNil(record?.failureSeenAttemptID, "reading a thread acknowledges nothing")
    }

    func testAcknowledgingAFailureNeverMovesTheReadMarker() async throws {
        let conversations = ConversationStore(inMemory: true)
        let created = try await conversations.createConversation(backend: "openclaw")
        let store = makeStore(writer: conversations)
        let attempt = UUID()

        store.acknowledgeFailure(created.id, attemptID: attempt)

        try await waitUntil("the acknowledgement to reach the record") {
            try await self.fetched(created.id, from: conversations)?.failureSeenAttemptID == attempt
        }
        let record = try await fetched(created.id, from: conversations)
        XCTAssertNil(record?.lastViewedAt, "seeing an error is not a statement about having read the thread")
        XCTAssertTrue(store.overlayMarkers().isEmpty)
    }

    func testTheTwoMarkersRoundTripSeparatelyThroughTheStore() async throws {
        let conversations = ConversationStore(inMemory: true)
        let created = try await conversations.createConversation(backend: "openclaw")
        let store = makeStore(writer: conversations)
        let attempt = UUID()

        store.markViewed(created.id, lastActivityAt: nil, now: now)
        store.acknowledgeFailure(created.id, attemptID: attempt)

        try await waitUntil("both markers to reach the record") {
            let record = try await self.fetched(created.id, from: conversations)
            return record?.lastViewedAt == self.now && record?.failureSeenAttemptID == attempt
        }
        let record = try await fetched(created.id, from: conversations)
        XCTAssertEqual(record?.lastViewedAt, now, "two columns, two facts, neither derived from the other")
        XCTAssertEqual(record?.failureSeenAttemptID, attempt)
    }

    func testARetriedTurnGoesRedAgainWithNoDestructiveClear() async throws {
        // THE retry regression, and the reason acknowledgement is an IDENTITY.
        // Retry writes only the status column, so the failed turn keeps its
        // original `createdAt` and no timestamp comparison can tell
        // "acknowledged" from "acknowledged the PREVIOUS attempt". Minting a new
        // attempt id makes the stored acknowledgement simply stop matching — so
        // the mark comes back with nothing anywhere having to un-say something,
        // and the whole class of "a stale write silences a live failure" bug
        // goes with the clear that used to be needed.
        let conversations = ConversationStore(inMemory: true)
        let created = try await conversations.createConversation(backend: "openclaw")
        let store = makeStore(writer: conversations)
        let firstAttempt = UUID()
        let failedAt = now.addingTimeInterval(-600)   // frozen across the retry

        store.markViewed(created.id, lastActivityAt: nil, now: now)
        store.acknowledgeFailure(created.id, attemptID: firstAttempt)
        try await waitUntil("the acknowledgement to reach the record") {
            try await self.fetched(created.id, from: conversations)?.failureSeenAttemptID == firstAttempt
        }
        let acknowledged = try await fetched(created.id, from: conversations)
        XCTAssertTrue(
            failureState(store, created.id,
                         failedAt: failedAt,
                         attemptID: firstAttempt,
                         acknowledgedAttemptID: acknowledged?.failureSeenAttemptID).failureAcknowledged
        )

        // `beginRetry` mints a NEW attempt id on the same turn. Nothing clears
        // the stored acknowledgement, and nothing has to.
        let secondAttempt = UUID()
        let reFailed = failureState(store, created.id,
                                    failedAt: failedAt,
                                    attemptID: secondAttempt,
                                    acknowledgedAttemptID: acknowledged?.failureSeenAttemptID)

        XCTAssertEqual(reFailed.activity, .failed)
        XCTAssertFalse(reFailed.failureAcknowledged,
                       "a re-failed turn earns a fresh mark rather than inheriting the old acknowledgement")
        let settled = try await fetched(created.id, from: conversations)
        XCTAssertEqual(settled?.failureSeenAttemptID, firstAttempt,
                       "and the stored acknowledgement is untouched — there is no destructive clear left in this design")
        XCTAssertEqual(settled?.lastViewedAt, now,
                       "nor did any of it disturb the read marker")
    }

    func testAcknowledgementTakesNoCutoverFallback() async throws {
        // The asymmetry with `lastViewed`, locked. The cutover answers "were we
        // recording yet", which is a question about READING; applying it to
        // acknowledgement would silence every failure older than this device's
        // first launch — which is every turn a retry touches, since a retry
        // never advances `createdAt`.
        let store = makeStore()
        store.stampAccountCutoverIfNeeded(now: now)
        let id = UUID()

        XCTAssertFalse(
            failureState(store, id,
                         failedAt: now.addingTimeInterval(-60),
                         attemptID: UUID(),
                         acknowledgedAttemptID: nil).failureAcknowledged,
            "no stored identity means unacknowledged, never 'as of the cutover'"
        )
        XCTAssertEqual(store.lastViewed(id, stored: nil), now, "while the read marker still takes the cutover")
    }

    func testAPreCutoverFailureStillCarriesItsMark() async throws {
        // The silent-suppression class this closes: an imported failed tail, or
        // a pre-cutover `sending` turn the launch sweep later fails. Both are
        // older than the cutover and both must still be able to show a mark.
        let store = makeStore()
        store.stampAccountCutoverIfNeeded(now: now)

        let state = failureState(store, UUID(),
                                 failedAt: now.addingTimeInterval(-86_400),
                                 attemptID: UUID(),
                                 acknowledgedAttemptID: nil)

        XCTAssertEqual(state.activity, .failed)
        XCTAssertFalse(state.failureAcknowledged)
    }

    // MARK: - Helpers

    private func fetched(
        _ id: UUID,
        from store: ConversationStore
    ) async throws -> ConversationRecord? {
        try await store.fetchConversations().first { $0.id == id }
    }
}
