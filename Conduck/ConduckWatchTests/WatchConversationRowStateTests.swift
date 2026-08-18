// SPDX-License-Identifier: Apache-2.0

// Conduck
// WatchConversationRowStateTests.swift
//
// What a wrist row is allowed to say, now that the wrist is a full participant
// in the account's attention markers rather than an attention-blind mirror.
//
// TWO BRANCHES CHANGED SHAPE ON THIS SURFACE, and both were previously
// unreachable here for the same reason: the row had no way to answer a question
// without a per-row message fetch, which is exactly what the wrist's whole list
// design refuses to pay.
//
//   • THE UNSEEN BRANCH IS REACHABLE. It needs the role of the newest message,
//     and the wrist now reads it off the conversation row itself — the
//     versioned `tailProjection` envelope the phone writes in the same
//     transaction that bumps `lastActivityAt`. No fetch, one string.
//
//   • ACKNOWLEDGEMENT CAN BE TRUE HERE. It is an account fact carried on the
//     conversation (`failureSeenAttemptID`), so a failure the user retires on
//     any device is retired on the wrist, and — the half that is genuinely new
//     — a failure retired ON the wrist is retired everywhere else.
//
// THE RULE THAT MATTERS MOST IS THE ONE ABOUT NOT KNOWING. A stale, absent,
// malformed or future-versioned envelope means the wrist cannot prove the tail
// is a reply, and it SUPPRESSES the amber dot rather than guessing at one. The
// phone and the Mac can afford the fallback the wrist cannot (a lazy per-row
// tail fetch, plus a guarded repair of the envelope), so the two surfaces
// deliberately diverge here: the wrist under-reports for as long as the
// envelope is unreadable, and a missing dot is a cost the user can recover from
// by opening the thread, while a dot invented from a `lastActivityAt` bump that
// might have been the user's own message is a lie the row keeps telling.
//
// The mixed-fleet case is why "stale" is not a synonym for "malformed": a build
// that appends a message and bumps `lastActivityAt` WITHOUT rewriting the
// envelope leaves a perfectly well-formed string describing the previous tail.
// Only the stamp equality exposes it, which is why the envelope carries the
// tail's `createdAt` at all.
//
// PURE VALUE MATH, WITH TWO CASES THAT ARE NOT. Most cases here build a
// `ConversationRecord` by hand and call `TailProjection.read` and
// `ConversationActivityResolver.resolve` directly — the same composition
// `WatchConversationViewModel.rowState` performs, minus its two singletons. No
// `ConversationStore`, no `ReadStateStore`, no `WCSession`: the marker plumbing
// has its own suites on the phone side, and the question there is only what the
// resolver is told and what it answers.
//
// But a re-implementation cannot fail when the implementation does, and the
// watchOS half of this change is ONE line — the composition itself, where three
// values that used to be `nil` are now read off the record. So two cases drive
// `WatchConversationViewModel.rowState(for:now:)` for real, against an
// in-memory store and a reset `ReadStateStore`. Without them, reverting that
// line leaves this whole file green and the wrist silently attention-blind.

import XCTest
@testable import ConduckWatch_Watch_App

final class WatchConversationRowStateTests: XCTestCase {

    /// A fixed instant, so "before" and "after" are statements about the design
    /// rather than about when the suite ran.
    private let tailAt = Date(timeIntervalSince1970: 1_700_000_000)

    private var beforeTail: Date { tailAt.addingTimeInterval(-3_600) }

    // MARK: - The unseen branch, now reachable on the wrist

    func testAnAgentTailAfterTheViewMarkerIsUnseen() {
        let state = rowState(
            tailRole: .agent,
            lastActivityAt: tailAt,
            lastViewedAt: beforeTail
        )

        XCTAssertEqual(state.activity, .answeredUnseen,
                       "the reply arrived after the thread was last looked at on any device")
        XCTAssertTrue(state.hasUnseenReply, "which is what bolds the row title on the wrist")
    }

    func testTheUsersOwnTailIsNeverUnseen() {
        // The row is bumped by the user's own message too — including one sent
        // from this very wrist. A surface that inferred "something happened" from
        // `lastActivityAt` alone would paint an amber reply disc on the message
        // the user just dictated, which is the failure the role half of the
        // envelope exists to prevent.
        let state = rowState(
            tailRole: .user,
            lastActivityAt: tailAt,
            lastViewedAt: beforeTail
        )

        XCTAssertEqual(state.activity, .idle)
        XCTAssertFalse(state.hasUnseenReply)
    }

    func testAThreadViewedAtItsTailIsNotUnseen() {
        // Strict comparison: equal is NOT unseen. Opening a thread stamps the
        // marker from the same instant the tail carries, so an inclusive test
        // would leave every thread the user just read still bold.
        let state = rowState(
            tailRole: .agent,
            lastActivityAt: tailAt,
            lastViewedAt: tailAt
        )

        XCTAssertFalse(state.hasUnseenReply)
    }

    func testAThreadNeverViewedAnywhereShowsNoDot() {
        // No marker on the record, no cutover, no overlay — nothing is KNOWN,
        // and the resolver reads that as viewed rather than as unread. It is
        // what keeps a fresh wrist that has just imported a year of iCloud
        // history from arriving with a dot on every row.
        let state = rowState(
            tailRole: .agent,
            lastActivityAt: tailAt,
            lastViewedAt: nil
        )

        XCTAssertFalse(state.hasUnseenReply)
    }

    // MARK: - What the wrist does when it cannot prove the tail is a reply

    func testAnAbsentEnvelopeSuppressesTheDot() {
        // A row written before the attribute existed, or one that arrived from
        // CloudKit before the column did. The wrist has no fallback fetch, so
        // the honest answer is no mark.
        let state = rowState(
            envelope: nil,
            lastActivityAt: tailAt,
            lastViewedAt: beforeTail
        )

        XCTAssertEqual(state.activity, .idle)
        XCTAssertFalse(state.hasUnseenReply, "an unprojected tail must suppress the branch, never guess at it")
    }

    func testAnEnvelopeDescribingAnOlderTailIsStaleAndSuppressesTheDot() {
        // THE mixed-fleet case, and the reason the envelope carries a stamp at
        // all. A build that appends a message bumps `lastActivityAt` and leaves
        // the envelope naming the PREVIOUS tail: perfectly well-formed, and
        // wrong. It might name an agent role while the real tail is the user's
        // own message, so believing it would paint a reply disc on a row that
        // has no reply.
        let stale = TailProjection.encoded(messageID: UUID(), createdAt: beforeTail, role: .agent)

        let state = rowState(
            envelope: stale,
            lastActivityAt: tailAt,
            lastViewedAt: beforeTail
        )

        XCTAssertEqual(TailProjection.read(stale, lastActivityAt: tailAt), .stale,
                       "the stamp mismatch is the only thing that can expose this")
        XCTAssertFalse(state.hasUnseenReply)
    }

    func testAMalformedEnvelopeSuppressesTheDot() {
        // Untrusted by posture: the string arrives from CloudKit, written by a
        // build this one knows nothing about. There is no partial acceptance —
        // a field that fails to parse fails the whole envelope rather than
        // letting the remaining fields re-align onto their neighbours.
        // THE STAMP FIELD IS BUILT FROM THE REAL GRAMMAR, so each string below
        // differs from a VALID envelope in exactly the one field its comment
        // names. Any other encoding here (a hex `Double` bit pattern, say) fails
        // the stamp parse first, and the sub-cases about the id and the role
        // would then assert nothing about the id or the role: the rules they are
        // named for could be deleted outright and this test would still pass.
        let stamp = String(TailProjection.milliseconds(from: tailAt))
        let malformed = [
            "",                                                   // empty
            "not-an-envelope",                                    // no separators
            "1|\(UUID().uuidString)|\(stamp)",                    // three fields
            "1|\(UUID().uuidString)|\(stamp)|agent|extra",        // five fields
            "1|not-a-uuid|\(stamp)|agent",                        // unparsable id
            "1|\(UUID().uuidString)|zzzz|agent",                  // unparsable stamp
            "1|\(UUID().uuidString)|\(stamp)|assistant",          // role this build does not know
            "1|\(UUID().uuidString)|\(stamp)|",                   // empty role field
            "x|\(UUID().uuidString)|\(stamp)|agent"               // unparsable version
        ]

        for envelope in malformed {
            XCTAssertFalse(
                rowState(envelope: envelope, lastActivityAt: tailAt, lastViewedAt: beforeTail).hasUnseenReply,
                "\(envelope.isEmpty ? "<empty>" : envelope) must not produce a mark"
            )
        }
    }

    func testAnEnvelopeFromANewerBuildSuppressesTheDotAndIsLeftAlone() {
        // A future version is a different fact, not a wrong one. It is unusable
        // here — so no dot — but it must never be rewritten: a downgrade would
        // start a fight in which this build stamps version 1, the newer device
        // restamps its own, and the two export a CKRecord at each other for as
        // long as both exist.
        let stamp = String(TailProjection.milliseconds(from: tailAt))
        let future = "\(TailProjection.currentVersion + 1)|\(UUID().uuidString)|\(stamp)|agent"

        let reading = TailProjection.read(future, lastActivityAt: tailAt)

        XCTAssertEqual(reading, .unreadableVersion)
        XCTAssertFalse(reading.isRepairable, "rewriting it would downgrade a value the newer device restamps")
        XCTAssertFalse(rowState(envelope: future, lastActivityAt: tailAt, lastViewedAt: beforeTail).hasUnseenReply)
    }

    func testTheEnvelopeTheStoreWritesIsReadableOnTheWrist() {
        // The cross-target contract in one line: the writer runs on the phone,
        // the reader runs here, and both compile from the same declaration. A
        // round trip is the only thing that proves the wrist can actually use
        // what the phone stores — an encoding that lost precision would make
        // every row fail its own equality test and the wrist would never show a
        // mark at all.
        let messageID = UUID()
        let envelope = TailProjection.encoded(messageID: messageID, createdAt: tailAt, role: .agent)

        XCTAssertEqual(
            TailProjection.read(envelope, lastActivityAt: tailAt),
            .valid(TailProjection(messageID: messageID, createdAt: tailAt, role: .agent))
        )
        XCTAssertTrue(rowState(envelope: envelope, lastActivityAt: tailAt, lastViewedAt: beforeTail).hasUnseenReply)
    }

    // MARK: - Acknowledgement, which the wrist can now hold and now grant

    func testTheWristSeesAFailureTheAccountAcknowledged() {
        let attempt = UUID()

        let state = rowState(
            tailRole: .user,
            lastActivityAt: tailAt,
            lastViewedAt: tailAt,
            failed: FailedTurnProjection(messageID: UUID(), createdAt: tailAt, deliveryAttemptID: attempt),
            acknowledgedAttemptID: attempt
        )

        XCTAssertEqual(state.activity, .failed, "a seen failure is still a failure — the message did not go")
        XCTAssertTrue(state.failureAcknowledged, "what it loses is the alert, because the user has been told")
    }

    func testARetriedTurnIsMarkedAgainOnTheWrist() {
        // Asking again mints a NEW `deliveryAttemptID`, so the stored
        // acknowledgement simply stops matching and nothing anywhere has to
        // un-say something. Identity, never recency: a retry does not advance
        // the failed turn's `createdAt`, so a timestamp comparison could not
        // tell this case from the one above.
        let state = rowState(
            tailRole: .user,
            lastActivityAt: tailAt,
            lastViewedAt: tailAt,
            failed: FailedTurnProjection(messageID: UUID(), createdAt: tailAt, deliveryAttemptID: UUID()),
            acknowledgedAttemptID: UUID()
        )

        XCTAssertEqual(state.activity, .failed)
        XCTAssertFalse(state.failureAcknowledged, "the acknowledgement names a different attempt, so it does not apply")
    }

    func testAFailureWithNoAttemptIdentityIsNeverAcknowledgedOnTheWrist() {
        // `nil == nil` does NOT acknowledge. A failure written before the
        // attribute existed stays marked, which is the safe direction: an
        // unacknowledged failure over-reports and costs one tap, while a
        // silenced one is a message the user never learns did not send.
        let state = rowState(
            tailRole: .user,
            lastActivityAt: tailAt,
            lastViewedAt: tailAt,
            failed: FailedTurnProjection(messageID: UUID(), createdAt: tailAt, deliveryAttemptID: nil),
            acknowledgedAttemptID: nil
        )

        XCTAssertEqual(state.activity, .failed)
        XCTAssertFalse(state.failureAcknowledged)
    }

    func testAnAcknowledgementNeverLeaksOntoARowThatIsNotFailing() {
        // Acknowledgement is meaningful only while the row is actually reporting
        // the failure. A conversation that has moved on — a later message bumped
        // `lastActivityAt` past the failed turn — reports the reply, and a
        // leftover acknowledgement must not travel with it.
        let attempt = UUID()

        let state = rowState(
            tailRole: .agent,
            lastActivityAt: tailAt,
            lastViewedAt: beforeTail,
            failed: FailedTurnProjection(messageID: UUID(), createdAt: beforeTail, deliveryAttemptID: attempt),
            acknowledgedAttemptID: attempt
        )

        XCTAssertEqual(state.activity, .answeredUnseen, "the failure is no longer the last thing that happened here")
        XCTAssertTrue(state.hasUnseenReply)
        XCTAssertFalse(state.failureAcknowledged, "and the flag is meaningless off the failed arm")
    }

    // MARK: - The real view-model method, not a re-implementation

    /// Every case above builds the resolver's inputs by hand, which pins what the
    /// RESOLVER answers but not that the wrist actually asks it that way. These
    /// two drive `WatchConversationViewModel.rowState(for:now:)` itself — the one
    /// line the whole watchOS half of this change turns on, where three values
    /// that used to be `nil` are now read off the record. Reverting that line
    /// leaves every case above passing and the wrist silently attention-blind
    /// again, so it needs a test that can see it.
    @MainActor
    func testTheViewModelAsksTheRecordForTheTailRoleAndTheViewMarker() async throws {
        ReadStateStore._resetForTesting()
        let vm = WatchConversationViewModel(store: ConversationStore(inMemory: true))

        let record = self.record(
            envelope: TailProjection.encoded(messageID: UUID(), createdAt: tailAt, role: .agent),
            lastActivityAt: tailAt,
            lastViewedAt: beforeTail
        )

        let state = vm.rowState(for: record, now: tailAt)

        XCTAssertEqual(state.activity, .answeredUnseen)
        XCTAssertTrue(
            state.hasUnseenReply,
            "the tail role comes off the record's envelope and the view marker "
                + "off its own column — passing nil for either withholds the dot"
        )
    }

    @MainActor
    func testTheViewModelReadsTheAcknowledgementOffTheRecord() async throws {
        ReadStateStore._resetForTesting()
        let vm = WatchConversationViewModel(store: ConversationStore(inMemory: true))

        let attempt = UUID()
        let record = self.record(
            envelope: TailProjection.encoded(messageID: UUID(), createdAt: tailAt, role: .user),
            lastActivityAt: tailAt,
            lastViewedAt: nil,
            failed: FailedTurnProjection(
                messageID: UUID(), createdAt: tailAt, deliveryAttemptID: attempt
            ),
            acknowledgedAttemptID: attempt
        )

        let state = vm.rowState(for: record, now: tailAt)

        XCTAssertEqual(state.activity, .failed)
        XCTAssertTrue(
            state.failureAcknowledged,
            "a failure retired on any device is retired on the wrist — the "
                + "acknowledgement is a column on the conversation"
        )
    }

    // MARK: - Helpers

    /// One conversation row, built by hand. Shared by the pure-resolver cases and
    /// by the two view-model cases above, so both are stating things about the
    /// same record shape.
    private func record(
        envelope: String?,
        lastActivityAt: Date,
        lastViewedAt: Date?,
        failed: FailedTurnProjection? = nil,
        acknowledgedAttemptID: UUID? = nil
    ) -> ConversationRecord {
        ConversationRecord(
            id: UUID(),
            title: nil,
            createdAt: lastActivityAt.addingTimeInterval(-86_400),
            lastActivityAt: lastActivityAt,
            sessionID: UUID().uuidString,
            backend: "openclaw",
            titleSnippet: "a thread",
            lastViewedAt: lastViewedAt,
            failureSeenAttemptID: acknowledgedAttemptID,
            tailProjection: envelope,
            newestSendingAt: nil,
            newestFailed: failed
        )
    }

    /// Resolve a wrist row the way `WatchConversationViewModel.rowState` does:
    /// the record's own envelope decides `tailRole`, and the resolver is asked
    /// once. Building the record rather than passing loose inputs is deliberate
    /// — the record initializer is the thing that would silently drop a marker.
    private func rowState(
        envelope: String?,
        lastActivityAt: Date,
        lastViewedAt: Date?,
        failed: FailedTurnProjection? = nil,
        acknowledgedAttemptID: UUID? = nil,
        now: Date? = nil
    ) -> ConversationRowState {
        let record = self.record(
            envelope: envelope,
            lastActivityAt: lastActivityAt,
            lastViewedAt: lastViewedAt,
            failed: failed,
            acknowledgedAttemptID: acknowledgedAttemptID
        )

        return ConversationActivityResolver.resolve(
            ConversationActivityInputs(
                record: record,
                tailRole: TailProjection.read(
                    record.tailProjection,
                    lastActivityAt: record.lastActivityAt
                ).role
            ),
            // The wrist's own in-flight marker, absent in every case here: none
            // of them is about a turn running on THIS device.
            locallyLiveSince: nil,
            // The device-local optimistic overlay, likewise absent — the account
            // marker on the record is the fact under test.
            lastViewedAt: nil,
            now: now ?? lastActivityAt
        )
    }

    /// The same, with the envelope built from a known role so a case can state
    /// "the tail is a reply" without spelling out the grammar.
    private func rowState(
        tailRole: MessageRole,
        lastActivityAt: Date,
        lastViewedAt: Date?,
        failed: FailedTurnProjection? = nil,
        acknowledgedAttemptID: UUID? = nil,
        now: Date? = nil
    ) -> ConversationRowState {
        rowState(
            envelope: TailProjection.encoded(messageID: UUID(), createdAt: lastActivityAt, role: tailRole),
            lastActivityAt: lastActivityAt,
            lastViewedAt: lastViewedAt,
            failed: failed,
            acknowledgedAttemptID: acknowledgedAttemptID,
            now: now
        )
    }
}
