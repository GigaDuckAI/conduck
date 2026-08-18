// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationStoreDeliveryAttemptIdentityTests.swift
//
// Locks WHERE `Message.deliveryAttemptID` comes from. Every case here is really
// a question about what the user sees, because the account-wide failure mark is
// retired by an IDENTITY match — `Conversation.failureSeenAttemptID` against the
// `deliveryAttemptID` of the newest failed turn — and by nothing else:
//
//   • MINTED WHERE AN ATTEMPT BEGINS. `appendMessage` writing a user turn
//     `sending` stamps one, and `beginRetry` stamps another inside its
//     `failed → sending` compare-and-set. The retry mint is why acknowledgement
//     is an identity and not a timestamp: a retry does NOT advance the turn's
//     `createdAt`, so a stamp could never distinguish "the user saw this
//     failure" from "the user saw the PREVIOUS attempt's failure".
//   • MINTED AGAIN BY EVERY WRITER THAT DECLARES THE TURN FAILED, over
//     whatever identity the row already carries — the plain send-state writer,
//     both writing branches of the failure classifier, the launch sweep for
//     stale `sending` turns, and the clone's synthetic `failed` stamp. What an
//     acknowledgement matches is therefore THE LATEST FAILURE DECLARATION, not
//     one immutable id per semantic delivery. That is the opposite of the
//     intuitive rule and it is forced by how these rows converge: `Message`
//     merges under RECORD-LEVEL last-writer-wins across devices, so an
//     identity a straggling writer preserves is an ABA hazard, not a stability
//     guarantee. Trace it — turn M is `sending` on devices A and B; A declares
//     it failed as A1, the user is shown that mark and acknowledges it; B goes
//     offline still holding `sending`; A retries and fails again, and the mark
//     correctly returns. B relaunches, its launch sweep finds ITS copy of M
//     still `sending` past the grace, and publishes a `failed` record with a
//     LATER record timestamp. If that record could carry A1, the fleet
//     converges on `failed`/A1 against a standing acknowledgement of A1 and the
//     row renders CLEAR — permanently, because `failed` is terminal and nothing
//     writes that row again, and on the Watch the row shows nothing at all. A
//     fresh identity makes the straggler's export name an attempt no
//     acknowledgement can match, so the mark survives whichever record wins.
//   • MINTED BY THE ONE WRITER THAT DECLARES NOTHING AND STILL REPUBLISHES.
//     `repairTailProjection` snaps a legacy tail's `createdAt` onto its
//     millisecond, and record-level last-writer-wins does not care what a
//     writer meant: that save carries `status` and `deliveryAttemptID` from
//     whatever this device holds, which on a device that has not imported a
//     retry made elsewhere is the PREVIOUS attempt. Republishing it against a
//     standing acknowledgement of that attempt is the same ABA the trace above
//     rules out, so the repair mints too. Covered in
//     `ConversationTailProjectionTests`, beside the rest of that path.
//   • NOT MINTED BY A WRITE THAT DECLARES NOTHING. A repeat `failed` write, a
//     classification that upgrades nothing, a retry claim that loses the
//     compare-and-set: each is gated by its own writer and never reaches the
//     mint, or every no-op would relight a retired mark and export a CKRecord
//     for it.
//
// The residual error has a chosen direction: a straggling writer can re-arm a
// mark the user already retired, which costs one thread opened for nothing, and
// never the reverse. An extra mark is a nuisance; a missing one is a message the
// user never learns did not send.
//
// The row is always re-read through `fetchMessages`, never trusted from the
// returned snapshot alone — a mint that landed in only one of the two would let
// a caller acknowledge an attempt the store never recorded. Several cases also
// check the id the AGGREGATE reports, because that is the value a surface
// actually acknowledges against.
//
// Each test builds its OWN isolated `inMemory` store (CloudKit OFF in the seam).
// Deterministic + headless; synthetic text only.

import XCTest
@testable import Conduck

/// A main-actor counter a `.conversationsDidChange` observer can bump.
/// `@MainActor` makes it Sendable, so the observer block can capture it without
/// a mutable-capture race — and the store posts that notification from the main
/// actor, so the observer genuinely runs there.
@MainActor
private final class AttemptIdentityChangeCounter {
    var count = 0
}

final class ConversationStoreDeliveryAttemptIdentityTests: XCTestCase {

    private func makeStore() -> ConversationStore {
        ConversationStore(inMemory: true)
    }

    /// The STORED row for `messageID`, read back through the same fetch every
    /// surface uses.
    private func storedMessage(
        _ messageID: UUID,
        in conversationID: UUID,
        store: ConversationStore
    ) async throws -> MessageRecord {
        let messages = try await store.fetchMessages(for: conversationID)
        let match = messages.first { $0.id == messageID }
        return try XCTUnwrap(match)
    }

    /// The identity ON THE ROW.
    private func storedAttemptID(
        _ messageID: UUID,
        in conversationID: UUID,
        store: ConversationStore
    ) async throws -> UUID? {
        try await storedMessage(messageID, in: conversationID, store: store).deliveryAttemptID
    }

    /// The identity the AGGREGATE reports for this conversation's newest failed
    /// turn — the value a surface actually acknowledges against.
    private func reportedFailedAttemptID(
        _ conversationID: UUID,
        store: ConversationStore
    ) async throws -> UUID? {
        let turns = try await store.fetchUnresolvedUserTurns()
        return turns[conversationID]?.newestFailed?.deliveryAttemptID
    }

    /// The acknowledgement stored ON THE CONVERSATION.
    private func storedAcknowledgement(
        _ conversationID: UUID,
        store: ConversationStore
    ) async throws -> UUID? {
        let fetched = try await store.fetchConversation(id: conversationID)
        return try XCTUnwrap(fetched).failureSeenAttemptID
    }

    /// Run `body` with a live `.conversationsDidChange` observer and report how
    /// many times the store announced a persistent change. A writer that
    /// declares nothing must announce nothing.
    private func countingChanges(
        _ body: () async throws -> Void
    ) async rethrows -> Int {
        let counter = AttemptIdentityChangeCounter()
        let token = NotificationCenter.default.addObserver(
            forName: .conversationsDidChange, object: nil, queue: nil
        ) { _ in MainActor.assumeIsolated { counter.count += 1 } }
        defer { NotificationCenter.default.removeObserver(token) }
        try await body()
        return await MainActor.run { counter.count }
    }

    // MARK: - Minted at the start of an attempt

    func testAUserTurnBeingSentIsMintedAnIdentityTheStoredRowAgreesWith() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let turn = try await store.appendMessage(
            role: "user", text: "hi", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        let minted = try XCTUnwrap(
            turn.deliveryAttemptID,
            "a user turn written `sending` IS a delivery attempt beginning"
        )
        let stored = try await storedAttemptID(turn.id, in: convo.id, store: store)
        XCTAssertEqual(
            stored, minted,
            "the snapshot and the row must carry ONE identity — a caller that "
                + "acknowledges an id the store never recorded retires the mark "
                + "for a failure that is still standing"
        )
    }

    func testEveryAttemptGetsItsOwnIdentity() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let first = try await store.appendMessage(
            role: "user", text: "a", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        let second = try await store.appendMessage(
            role: "user", text: "b", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        XCTAssertNotNil(first.deliveryAttemptID)
        XCTAssertNotEqual(
            first.deliveryAttemptID, second.deliveryAttemptID,
            "two sends are two attempts — sharing an identity would let one "
                + "acknowledgement silence both"
        )
    }

    func testAnAgentReplyIsMintedNoIdentity() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        // `sending` on an agent row is nonsensical and must be ignored anyway:
        // a reply is not a delivery this app attempted.
        let reply = try await store.appendMessage(
            role: "agent", text: "answer", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        XCTAssertNil(reply.deliveryAttemptID)
        let stored = try await storedAttemptID(reply.id, in: convo.id, store: store)
        XCTAssertNil(stored)
    }

    func testAHeadlessCaptureWithNoSendStateIsMintedNoIdentity() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let note = try await store.appendMessage(
            role: "user", text: "wrist note", conversationID: convo.id,
            sourceDevice: "watch"                     // status nil = nothing dispatched
        )
        XCTAssertNil(
            note.deliveryAttemptID,
            "no attempt was made, so there is no attempt to identify"
        )
    }

    func testAUserTurnWrittenAlreadyResolvedIsMintedNoIdentity() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let turn = try await store.appendMessage(
            role: "user", text: "hi", conversationID: convo.id,
            sourceDevice: "phone", status: "sent"
        )
        XCTAssertNil(turn.deliveryAttemptID)
    }

    // MARK: - Declaring a failure mints, even over an identity already there

    func testTheClassifyingFailureWriterMintsOverTheIdentityAlreadyOnTheRow() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let turn = try await store.appendMessage(
            role: "user", text: "hi", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        let atStart = try XCTUnwrap(turn.deliveryAttemptID)
        await store.failTurn(messageID: turn.id, classification: nil)

        let stored = try await storedMessage(turn.id, in: convo.id, store: store)
        XCTAssertEqual(stored.status, "failed")
        XCTAssertNotNil(stored.deliveryAttemptID)
        XCTAssertNotEqual(
            stored.deliveryAttemptID, atStart,
            "this writer is DECLARING the failure, so the row must carry the "
                + "identity of that declaration — preserving an older one lets a "
                + "device that never saw the newest attempt republish an id an "
                + "acknowledgement still names, and a send that never happened "
                + "goes silent forever"
        )
    }

    func testThePlainSendStateWriterMintsOverTheIdentityAlreadyOnTheRow() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let turn = try await store.appendMessage(
            role: "user", text: "hi", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        let atStart = try XCTUnwrap(turn.deliveryAttemptID)
        await store.markPendingUserTurn(messageID: turn.id, to: "failed")

        let stored = try await storedMessage(turn.id, in: convo.id, store: store)
        XCTAssertEqual(stored.status, "failed")
        XCTAssertNotNil(stored.deliveryAttemptID)
        XCTAssertNotEqual(
            stored.deliveryAttemptID, atStart,
            "every authority that declares one delivery failed stamps its own "
                + "declaration — a preserved id is what silences a failed send"
        )
    }

    func testTheConversationWideFailureWriterMintsOverTheIdentityAlreadyOnTheRow() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let turn = try await store.appendMessage(
            role: "user", text: "hi", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        let atStart = try XCTUnwrap(turn.deliveryAttemptID)
        await store.failPendingUserTurns(conversationID: convo.id, classification: nil)

        let stored = try await storedMessage(turn.id, in: convo.id, store: store)
        XCTAssertEqual(stored.status, "failed")
        XCTAssertNotNil(stored.deliveryAttemptID)
        XCTAssertNotEqual(
            stored.deliveryAttemptID, atStart,
            "the conversation-wide classifier declares these failures too, so it "
                + "mints — otherwise a failed send can be silenced"
        )
    }

    func testTheConversationWideSendStateFlipMintsOverTheIdentityAlreadyOnTheRow() async throws {
        // The background-delegate cleanup path: no exact message id, just
        // "everything still `sending` in this conversation failed".
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let turn = try await store.appendMessage(
            role: "user", text: "hi", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        let atStart = try XCTUnwrap(turn.deliveryAttemptID)
        await store.markPendingUserTurns(conversationID: convo.id, to: "failed")

        let stored = try await storedMessage(turn.id, in: convo.id, store: store)
        XCTAssertEqual(stored.status, "failed")
        XCTAssertNotNil(stored.deliveryAttemptID)
        XCTAssertNotEqual(
            stored.deliveryAttemptID, atStart,
            "this flip is often the only failure declaration a turn ever gets; "
                + "publishing a stale id from it silences a failed send"
        )
    }

    func testTheLaunchSweepMintsOverTheIdentityAlreadyOnTheRow() async throws {
        // The sweep is THE writer the mint rule exists for: the row it flips was
        // very often written by another device, so whatever identity it finds
        // there may already be behind the fleet.
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let turn = try await store.appendMessage(
            role: "user", text: "hi", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        let atStart = try XCTUnwrap(turn.deliveryAttemptID)

        // `olderThan: 0` → cutoff = now, so the turn is stale. The pause is not
        // decoration: an append's stamp is quantised to its millisecond and
        // nudged one past the conversation's last activity, so it can sit a
        // fraction of a millisecond in the FUTURE and miss a cutoff taken
        // immediately after.
        try await Task.sleep(for: .milliseconds(10))
        await store.sweepStaleSendingUserTurns(olderThan: 0)

        let stored = try await storedMessage(turn.id, in: convo.id, store: store)
        XCTAssertEqual(stored.status, "failed")
        XCTAssertNotNil(stored.deliveryAttemptID)
        XCTAssertNotEqual(
            stored.deliveryAttemptID, atStart,
            "a sweep that republishes the identity it found cannot be told apart "
                + "from the device that minted it, and a failed send the user was "
                + "never shown renders clear"
        )
    }

    func testEnrichingAnAlreadyFailedTurnMintsAFreshIdentity() async throws {
        // The generic-first race: a plain failure lands, then the delegate's
        // coded one upgrades the classification in place. Counter-intuitive but
        // load-bearing — the row is already `failed` and nothing new failed, yet
        // this write is still a declaration being published, and the device
        // publishing it may be a straggler holding a copy the fleet has moved
        // past.
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let turn = try await store.appendMessage(
            role: "user", text: "hi", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        await store.failTurn(messageID: turn.id, classification: nil)
        let onRow = try await storedAttemptID(turn.id, in: convo.id, store: store)
        let declared = try XCTUnwrap(onRow)

        await store.failTurn(
            messageID: turn.id,
            classification: ConversationStore.TurnFailureClassification(
                failureCode: 42, wireCode: "image_unsupported"
            )
        )

        let stored = try await storedMessage(turn.id, in: convo.id, store: store)
        XCTAssertEqual(
            stored.failureCode, 42,
            "the upgrade must actually have happened, or this case proves nothing"
        )
        XCTAssertNotEqual(
            stored.deliveryAttemptID, declared,
            "a real upgrade re-declares this failure, so it re-identifies it — "
                + "leaving the id alone lets a straggler's upgrade land on top of "
                + "a newer attempt and silence a failed send"
        )
    }

    func testTheAggregateReportsTheIdentityTheDeclarationMinted() async throws {
        // What a surface acknowledges is what the aggregate reports, so the mint
        // is only real if it reaches there — not merely the row.
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let turn = try await store.appendMessage(
            role: "user", text: "hi", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        let atStart = try XCTUnwrap(turn.deliveryAttemptID)
        await store.failTurn(messageID: turn.id, classification: nil)

        let onTheRow = try await storedAttemptID(turn.id, in: convo.id, store: store)
        let reported = try await reportedFailedAttemptID(convo.id, store: store)
        XCTAssertEqual(
            reported, onTheRow,
            "the aggregate and the row must name ONE attempt, or an "
                + "acknowledgement retires a mark for something else"
        )
        XCTAssertNotEqual(reported, atStart)
    }

    // MARK: - A write that declares nothing mints nothing

    func testAnUpgradeThatUpgradesNothingMintsNothingAndSavesNothing() async throws {
        // The mint is unconditional; CALLING it is not. This is the guard that
        // keeps the rule from becoming a write amplifier — without it every
        // redundant classification would relight a retired mark and export a
        // record for it.
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let turn = try await store.appendMessage(
            role: "user", text: "hi", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        await store.failTurn(
            messageID: turn.id,
            classification: ConversationStore.TurnFailureClassification(
                failureCode: 7, wireCode: "image_unsupported"
            )
        )
        let onRow = try await storedAttemptID(turn.id, in: convo.id, store: store)
        let declared = try XCTUnwrap(onRow)

        let posts = try await countingChanges {
            // Identical classification, then a poorer one, then one whose code
            // the row already has: none of the three adds information.
            await store.failTurn(
                messageID: turn.id,
                classification: ConversationStore.TurnFailureClassification(
                    failureCode: 7, wireCode: "image_unsupported"
                )
            )
            await store.failTurn(messageID: turn.id, classification: nil)
            await store.failTurn(
                messageID: turn.id,
                classification: ConversationStore.TurnFailureClassification(failureCode: 9)
            )
        }

        XCTAssertEqual(
            posts, 0,
            "a write that changes nothing must not save or announce a change"
        )
        let after = try await storedAttemptID(turn.id, in: convo.id, store: store)
        XCTAssertEqual(
            after, declared,
            "and it must not mint — a mark the user retired would come back for "
                + "a failure nothing new happened to"
        )
    }

    func testRewritingFailedOntoAnAlreadyFailedRowMintsNothing() async throws {
        // The send-state writer's idempotence story is its `previousStatus`
        // guard: only a REAL transition into `failed` is a declaration. (This
        // path still saves, for reasons that have nothing to do with the
        // identity; only the mint is under test here.)
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let turn = try await store.appendMessage(
            role: "user", text: "hi", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        await store.failTurn(messageID: turn.id, classification: nil)
        let onRow = try await storedAttemptID(turn.id, in: convo.id, store: store)
        let declared = try XCTUnwrap(onRow)

        try await store.updateStatus(messageID: turn.id, status: "failed")

        let after = try await storedAttemptID(turn.id, in: convo.id, store: store)
        XCTAssertEqual(
            after, declared,
            "re-writing `failed` onto a `failed` row declares nothing, so it "
                + "identifies nothing"
        )
    }

    func testALostRetryClaimMintsNothing() async throws {
        // The compare-and-set IS the mint site, so a claim that does not fire
        // must not produce an identity either — a turn that is not `failed` has
        // no attempt to re-begin.
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let turn = try await store.appendMessage(
            role: "user", text: "hi", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        let minted = try XCTUnwrap(turn.deliveryAttemptID)

        let claimed = await store.beginRetry(messageID: turn.id)   // still `sending`
        XCTAssertFalse(claimed)
        let stored = try await storedAttemptID(turn.id, in: convo.id, store: store)
        XCTAssertEqual(stored, minted)
    }

    // MARK: - A row that reaches `failed` carrying nothing

    func testALegacySendingRowIsMintedAnIdentityWhenTheClassifierFailsIt() async throws {
        // Stands in for a turn written `sending` by a build older than the
        // attribute, or mirrored in from one: it reaches `failed` carrying
        // nothing, and a nil identity can never be acknowledged. The same mint
        // every other failure declaration runs covers it — no special case.
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let turn = try await store.appendMessage(
            role: "user", text: "hi", conversationID: convo.id, sourceDevice: "phone"
        )
        XCTAssertNil(turn.deliveryAttemptID)

        try await store.updateStatus(messageID: turn.id, status: "sending")
        let whileSending = try await storedAttemptID(turn.id, in: convo.id, store: store)
        XCTAssertNil(
            whileSending,
            "entering `sending` from outside an append declares nothing and "
                + "begins nothing this writer knows about, so it mints nothing"
        )

        await store.failTurn(messageID: turn.id, classification: nil)
        let stored = try await storedMessage(turn.id, in: convo.id, store: store)
        XCTAssertEqual(stored.status, "failed")
        XCTAssertNotNil(
            stored.deliveryAttemptID,
            "without a mint this row stays marked for the life of the install "
                + "with nothing the user can do about it"
        )
    }

    func testALegacySendingRowIsMintedAnIdentityWhenThePlainWriterFailsIt() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let turn = try await store.appendMessage(
            role: "user", text: "hi", conversationID: convo.id, sourceDevice: "phone"
        )
        try await store.updateStatus(messageID: turn.id, status: "sending")
        try await store.updateStatus(messageID: turn.id, status: "failed")

        let stored = try await storedAttemptID(turn.id, in: convo.id, store: store)
        XCTAssertNotNil(stored)
    }

    // MARK: - Retry re-mints, and that is what re-arms the mark

    func testARetryMintsAFreshIdentityInTheSameCompareAndSet() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let turn = try await store.appendMessage(
            role: "user", text: "hi", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        await store.failTurn(messageID: turn.id, classification: nil)
        let onRow = try await storedAttemptID(turn.id, in: convo.id, store: store)
        let failedAs = try XCTUnwrap(onRow)

        let claimed = await store.beginRetry(messageID: turn.id)
        XCTAssertTrue(claimed)

        let stored = try await storedMessage(turn.id, in: convo.id, store: store)
        XCTAssertEqual(stored.status, "sending")
        XCTAssertNotNil(stored.deliveryAttemptID)
        XCTAssertNotEqual(
            stored.deliveryAttemptID, failedAs,
            "asking again IS a new delivery attempt"
        )
    }

    func testTwoFailuresOfOneTurnSeparatedByARetryCarryDifferentIdentities() async throws {
        // THE case the whole identity scheme exists for. A retry does not move
        // the turn's `createdAt`, so if these two failures shared an identity
        // (or were compared by time) the second would resolve ALREADY
        // ACKNOWLEDGED on every device — a message that never sent, showing no
        // mark at all, permanently.
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let turn = try await store.appendMessage(
            role: "user", text: "hi", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        await store.failTurn(messageID: turn.id, classification: nil)
        let reportedFirst = try await reportedFailedAttemptID(convo.id, store: store)
        let firstFailure = try XCTUnwrap(reportedFirst)

        let claimed = await store.beginRetry(messageID: turn.id)
        XCTAssertTrue(claimed)
        await store.failTurn(messageID: turn.id, classification: nil)
        let reportedSecond = try await reportedFailedAttemptID(convo.id, store: store)
        let secondFailure = try XCTUnwrap(reportedSecond)

        XCTAssertNotEqual(
            firstFailure, secondFailure,
            "the two failures of one turn must be distinguishable, or an "
                + "acknowledgement of the first silences the second forever"
        )
        let stored = try await storedMessage(turn.id, in: convo.id, store: store)
        XCTAssertEqual(
            stored.createdAt, turn.createdAt,
            "and the stamp did NOT move — which is exactly why a timestamp "
                + "acknowledgement cannot work here"
        )
    }

    func testARetryLeavesTheStoredAcknowledgementUntouchedSoItSimplyStopsMatching() async throws {
        // There is no destructive clear anywhere in this design: the
        // acknowledgement stays exactly where it is and stops being the id the
        // row reports.
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let turn = try await store.appendMessage(
            role: "user", text: "hi", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        await store.failTurn(messageID: turn.id, classification: nil)
        let reported = try await reportedFailedAttemptID(convo.id, store: store)
        let seen = try XCTUnwrap(reported)
        await store.acknowledgeConversationFailure(convo.id, attemptID: seen)

        let claimed = await store.beginRetry(messageID: turn.id)
        XCTAssertTrue(claimed)
        await store.failTurn(messageID: turn.id, classification: nil)

        let stored = try await storedAcknowledgement(convo.id, store: store)
        XCTAssertEqual(
            stored, seen,
            "`beginRetry` must not clear it — a clear is what reintroduces the "
                + "stale-write class of bug identity was chosen to kill"
        )
        let reArmed = try await reportedFailedAttemptID(convo.id, store: store)
        XCTAssertNotEqual(
            reArmed, seen,
            "the mark re-arms because the stored acknowledgement no longer names "
                + "the attempt the row reports"
        )
    }

    // MARK: - The ABA a preserved identity would open

    func testAStaleSweepCannotSilenceAFailureTheUserWasNeverShown() async throws {
        // THE defect, modeled. An in-memory store cannot reproduce two CloudKit
        // replicas merging under record-level last-writer-wins, so the losing
        // replica's STATE is built directly instead: a device that acknowledged
        // one failure and then went offline holds the turn as `sending` still
        // carrying the identity the user acknowledged. Driving the row back to
        // `sending` reproduces exactly that pair, because only the failure edge
        // mints.
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let turn = try await store.appendMessage(
            role: "user", text: "hi", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        await store.failTurn(messageID: turn.id, classification: nil)
        let firstReported = try await reportedFailedAttemptID(convo.id, store: store)
        let acknowledged = try XCTUnwrap(firstReported)
        await store.acknowledgeConversationFailure(convo.id, attemptID: acknowledged)
        let ack = try await storedAcknowledgement(convo.id, store: store)
        XCTAssertEqual(
            ack, acknowledged,
            "premise: the user has been shown this failure and the mark is clear"
        )

        // The stale replica's state.
        try await store.updateStatus(messageID: turn.id, status: "sending")
        let held = try await storedAttemptID(turn.id, in: convo.id, store: store)
        XCTAssertEqual(
            held, acknowledged,
            "premise: this device still holds the acknowledged attempt as in "
                + "flight — it never saw the retry that moved the fleet on"
        )

        // It relaunches past the grace and declares the failure — the write that
        // lands LAST and therefore decides what the whole account sees.
        try await Task.sleep(for: .milliseconds(10))
        await store.sweepStaleSendingUserTurns(olderThan: 0)

        let stored = try await storedMessage(turn.id, in: convo.id, store: store)
        XCTAssertEqual(stored.status, "failed")
        let republished = try XCTUnwrap(stored.deliveryAttemptID)
        XCTAssertNotEqual(
            republished, acknowledged,
            "the stale writer must not be able to republish an identity the user "
                + "already acknowledged: `failed` is terminal, so a message that "
                + "never sent would show no mark at all, on every device, forever"
        )
        let reported = try await reportedFailedAttemptID(convo.id, store: store)
        let standingAck = try await storedAcknowledgement(convo.id, store: store)
        XCTAssertNotEqual(
            reported, standingAck,
            "the mark must be ARMED — a silenced failed send is the defect this "
                + "rule exists to prevent"
        )
    }

    func testAStaleClassificationUpgradeCannotSilenceAFailureTheUserWasNeverShown() async throws {
        // The same ABA through the other branch: the straggler comes back not
        // with a status flip but with a richer classification for the copy it
        // still holds. Enriching is a re-declaration, so it re-identifies.
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let turn = try await store.appendMessage(
            role: "user", text: "hi", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        await store.failTurn(messageID: turn.id, classification: nil)
        let firstReported = try await reportedFailedAttemptID(convo.id, store: store)
        let acknowledged = try XCTUnwrap(firstReported)
        await store.acknowledgeConversationFailure(convo.id, attemptID: acknowledged)
        let reportedBefore = try await reportedFailedAttemptID(convo.id, store: store)
        let ackBefore = try await storedAcknowledgement(convo.id, store: store)
        XCTAssertEqual(
            reportedBefore, ackBefore,
            "premise: the mark is clear before the straggler writes"
        )

        await store.failTurn(
            messageID: turn.id,
            classification: ConversationStore.TurnFailureClassification(
                failureCode: 42, wireCode: "image_unsupported"
            )
        )

        let stored = try await storedMessage(turn.id, in: convo.id, store: store)
        XCTAssertEqual(stored.failureCode, 42, "the upgrade must have fired")
        XCTAssertNotEqual(
            stored.deliveryAttemptID, acknowledged,
            "an upgrade that keeps the acknowledged identity is the same silence "
                + "by another route: a failed send the user was never shown, "
                + "rendering clear on every device with nothing left to write it "
                + "again"
        )
        let reportedAfter = try await reportedFailedAttemptID(convo.id, store: store)
        let ackAfter = try await storedAcknowledgement(convo.id, store: store)
        XCTAssertNotEqual(
            reportedAfter, ackAfter,
            "the mark must be ARMED — an over-reported mark costs one thread "
                + "opened for nothing, a missing one costs the message"
        )
    }

    // MARK: - The clone's synthetic failure

    func testTheClonedTrailingUserTurnCarriesAFreshIdentityOfItsOwn() async throws {
        let store = makeStore()
        let source = try await store.createConversation(backend: "openclaw")
        _ = try await store.appendMessage(
            role: "user", text: "question", conversationID: source.id,
            sourceDevice: "phone", status: "sent"
        )
        _ = try await store.appendMessage(
            role: "agent", text: "answer", conversationID: source.id, sourceDevice: "phone"
        )
        let trailing = try await store.appendMessage(
            role: "user", text: "follow up", conversationID: source.id,
            sourceDevice: "phone", status: "sending"
        )
        await store.failTurn(messageID: trailing.id, classification: nil)
        let sourceStored = try await storedAttemptID(trailing.id, in: source.id, store: store)
        let sourceAttempt = try XCTUnwrap(sourceStored)

        let clone = try await store.cloneConversation(id: source.id, toBackend: "hermes")
        let continuationID = try XCTUnwrap(clone.continuationMessageID)
        let copied = try await storedMessage(
            continuationID, in: clone.conversation.id, store: store
        )

        XCTAssertEqual(copied.status, "failed")
        let cloneAttempt = try XCTUnwrap(
            copied.deliveryAttemptID,
            "the copy loop carries no identity across, so the synthetic `failed` "
                + "stamp must mint one — otherwise this row is a failure that can "
                + "never be acknowledged"
        )
        XCTAssertNotEqual(
            cloneAttempt, sourceAttempt,
            "the source id names an attempt made in another thread against "
                + "another gateway; inheriting it would let one acknowledgement "
                + "cover both threads"
        )
        let sourceAfter = try await storedAttemptID(trailing.id, in: source.id, store: store)
        XCTAssertEqual(sourceAfter, sourceAttempt, "and the source row is untouched")
    }

    func testNoOtherClonedTurnCarriesAnIdentity() async throws {
        // Cloned turns are historical: nothing was dispatched for them, so an
        // identity on one would be a claim about an attempt that never happened.
        let store = makeStore()
        let source = try await store.createConversation(backend: "openclaw")
        let sent = try await store.appendMessage(
            role: "user", text: "question", conversationID: source.id,
            sourceDevice: "phone", status: "sending"
        )
        await store.markPendingUserTurn(messageID: sent.id, to: "sent")
        _ = try await store.appendMessage(
            role: "agent", text: "answer", conversationID: source.id, sourceDevice: "phone"
        )
        let trailing = try await store.appendMessage(
            role: "user", text: "follow up", conversationID: source.id,
            sourceDevice: "phone", status: "sending"
        )
        await store.failTurn(messageID: trailing.id, classification: nil)

        let clone = try await store.cloneConversation(id: source.id, toBackend: "hermes")
        let continuationID = try XCTUnwrap(clone.continuationMessageID)
        let copies = try await store.fetchMessages(for: clone.conversation.id)
        XCTAssertEqual(copies.count, 3)
        for copy in copies where copy.id != continuationID {
            XCTAssertNil(
                copy.deliveryAttemptID,
                "a copied historical turn was never dispatched from this thread"
            )
            XCTAssertNil(copy.status)
        }
    }

    func testACloneEndingOnAnAgentReplyMintsNothingAtAll() async throws {
        let store = makeStore()
        let source = try await store.createConversation(backend: "openclaw")
        _ = try await store.appendMessage(
            role: "user", text: "question", conversationID: source.id,
            sourceDevice: "phone", status: "sent"
        )
        _ = try await store.appendMessage(
            role: "agent", text: "answer", conversationID: source.id, sourceDevice: "phone"
        )

        let clone = try await store.cloneConversation(id: source.id, toBackend: "hermes")
        XCTAssertNil(clone.continuationMessageID)
        let copies = try await store.fetchMessages(for: clone.conversation.id)
        XCTAssertTrue(copies.allSatisfy { $0.deliveryAttemptID == nil })
        let turns = try await store.fetchUnresolvedUserTurns()
        XCTAssertNil(
            turns[clone.conversation.id],
            "nothing in this fork is unresolved, so it enters no aggregate"
        )
    }
}
