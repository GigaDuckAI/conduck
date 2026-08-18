// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationStoreAttentionMarkerTests.swift
//
// Locks the writes that make "I have already seen this" a fact about the
// ACCOUNT rather than about one device — `Conversation.lastViewedAt`,
// `Conversation.failureSeenAttemptID`, and the legacy fold that carries a
// device-local marker into the record — plus the one property all of them share:
// THEY SAVE AND POST ONLY WHEN A VALUE ACTUALLY MOVED.
//
// Why each rule is here, stated as what breaks without it:
//
//   • MONOTONE AGAINST THE STORED VALUE. The column is last-writer-wins across
//     devices, so a marker that could move BACKWARD would let a delayed write
//     carrying an older view time re-bold a thread that was read somewhere else.
//     Comparing inside the transaction that writes makes moving backward
//     unrepresentable on this device, which is as far as a record-level LWW
//     field can be defended.
//   • AN EQUAL STAMP IS NOT A MOVE. A thread left open across a long
//     conversation re-stamps the same clamped value on every landing tail;
//     treating that as a change is a local refetch loop and a CKRecord export
//     per turn. This file asserts it the only way it is observable from outside
//     the store — by counting `.conversationsDidChange`, which the store posts
//     only after a save it believes changed something.
//   • ACKNOWLEDGEMENT IS AN IDENTITY, SO IT HAS NO ORDER. There is no "later"
//     UUID and the newest attempt is not the largest one, so the stored value is
//     replaced rather than maxed — and it is never written nil, because nil
//     would ERASE an acknowledgement another device made and relight the mark
//     everywhere because somebody opened a conversation.
//   • NEITHER MARKER EVER TOUCHES `lastActivityAt`. That column is what the list
//     sorts on AND what the unseen test compares against, so a marker write that
//     touched it would float a thread to the top of the list for being READ and
//     would silence the very reply the marker is being compared with.
//   • THE COMBINED WRITE IS ONE TRANSACTION. The macOS menu bar means both
//     things with one click; calling the two writers in sequence would produce
//     two saves, two posts and two exports per opening, and would let a reload
//     land between them and paint the row half-updated.
//   • THE FOLD RETURNS AN OUTCOME. The legacy defaults key is a durable
//     read-side fallback, not a migration input: the caller deletes it only on a
//     confirmed cover, so a conversation that is not present locally must report
//     `.failed` (an import that has not landed yet is NOT a deletion) and a save
//     that did not commit must never report `.saved`. A lost read marker is
//     recoverable from nowhere, on any device.
//
// Each test builds its OWN isolated `inMemory` store (CloudKit OFF in the seam),
// which is also what lets the fold run at all — it refuses to touch anything but
// an in-memory store from a test host, because the Core Data container it folds
// INTO is a documented carve-out from the storage seam and is real.
// Deterministic + headless; synthetic text only.

import XCTest
@testable import Conduck

/// A main-actor counter a `.conversationsDidChange` observer can bump.
/// `@MainActor` makes it Sendable, so the observer block can capture it without
/// a mutable-capture race — and the store posts that notification from the main
/// actor, so the observer genuinely runs there.
@MainActor
private final class MarkerChangeCounter {
    var count = 0
}

final class ConversationStoreAttentionMarkerTests: XCTestCase {

    private let noon = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() -> ConversationStore {
        ConversationStore(inMemory: true)
    }

    /// A conversation with one real turn in it, so `lastActivityAt` is a value a
    /// marker write could plausibly disturb rather than the creation stamp.
    private func seedConversation(
        _ store: ConversationStore
    ) async throws -> ConversationRecord {
        let convo = try await store.createConversation(backend: "openclaw")
        _ = try await store.appendMessage(
            role: "agent", text: "reply", conversationID: convo.id, sourceDevice: "phone"
        )
        return try await reload(convo.id, store: store)
    }

    private func reload(
        _ id: UUID, store: ConversationStore
    ) async throws -> ConversationRecord {
        let fetched = try await store.fetchConversation(id: id)
        return try XCTUnwrap(fetched)
    }

    /// Run `body` with a live `.conversationsDidChange` observer and report how
    /// many times the store announced a persistent change.
    private func countingChanges(
        _ body: () async throws -> Void
    ) async rethrows -> Int {
        let counter = MarkerChangeCounter()
        let token = NotificationCenter.default.addObserver(
            forName: .conversationsDidChange, object: nil, queue: nil
        ) { _ in MainActor.assumeIsolated { counter.count += 1 } }
        defer { NotificationCenter.default.removeObserver(token) }
        try await body()
        return await MainActor.run { counter.count }
    }

    // MARK: - Viewed

    func testViewingStoresTheStamp() async throws {
        let store = makeStore()
        let convo = try await seedConversation(store)
        await store.markConversationViewed(convo.id, at: noon)
        let after = try await reload(convo.id, store: store)
        XCTAssertEqual(after.lastViewedAt, noon)
    }

    func testAnOlderStampNeverMovesTheMarkerBackwards() async throws {
        let store = makeStore()
        let convo = try await seedConversation(store)
        await store.markConversationViewed(convo.id, at: noon)

        let posts = try await countingChanges {
            await store.markConversationViewed(convo.id, at: noon.addingTimeInterval(-3600))
        }
        let after = try await reload(convo.id, store: store)
        XCTAssertEqual(
            after.lastViewedAt, noon,
            "a delayed write carrying an older view time must not re-bold a "
                + "thread that was already read somewhere else"
        )
        XCTAssertEqual(posts, 0, "nothing moved, so nothing saved and nothing posted")
    }

    func testAnEqualStampIsNotAChangeAndPostsNothing() async throws {
        let store = makeStore()
        let convo = try await seedConversation(store)

        let first = try await countingChanges {
            await store.markConversationViewed(convo.id, at: noon)
        }
        XCTAssertEqual(first, 1)

        let repeated = try await countingChanges {
            await store.markConversationViewed(convo.id, at: noon)
            await store.markConversationViewed(convo.id, at: noon)
        }
        XCTAssertEqual(
            repeated, 0,
            "a thread open across many landing tails re-stamps the same value — "
                + "exporting a CKRecord for each is the write amplification this "
                + "rule exists to prevent"
        )
    }

    func testViewingTouchesNeitherTheActivityStampNorTheAcknowledgement() async throws {
        let store = makeStore()
        let convo = try await seedConversation(store)
        await store.markConversationViewed(convo.id, at: noon)

        let after = try await reload(convo.id, store: store)
        XCTAssertEqual(
            after.lastActivityAt, convo.lastActivityAt,
            "reading a thread must not float it to the top of the list, and must "
                + "not silence the very reply the marker is compared against"
        )
        XCTAssertNil(after.failureSeenAttemptID)
    }

    // MARK: - Acknowledgement

    func testAcknowledgingStoresTheAttemptID() async throws {
        let store = makeStore()
        let convo = try await seedConversation(store)
        let attempt = UUID()
        await store.acknowledgeConversationFailure(convo.id, attemptID: attempt)
        let after = try await reload(convo.id, store: store)
        XCTAssertEqual(after.failureSeenAttemptID, attempt)
    }

    func testAcknowledgingTheSameAttemptTwiceIsNotAChange() async throws {
        let store = makeStore()
        let convo = try await seedConversation(store)
        let attempt = UUID()

        let first = try await countingChanges {
            await store.acknowledgeConversationFailure(convo.id, attemptID: attempt)
        }
        XCTAssertEqual(first, 1)

        let repeated = try await countingChanges {
            await store.acknowledgeConversationFailure(convo.id, attemptID: attempt)
        }
        XCTAssertEqual(repeated, 0, "an exact repeat is the common case and must not export")
    }

    func testAcknowledgingAnotherAttemptReplacesTheStoredOneWithNoOrdering() async throws {
        // Deliberately writes a numerically LOWER uuid second: identities have
        // no order, and a helper that reached for `max` would keep the wrong one
        // and leave the row silently acknowledged against an attempt the user
        // never saw.
        let store = makeStore()
        let convo = try await seedConversation(store)
        let high = try XCTUnwrap(UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000000"))
        let low = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))

        await store.acknowledgeConversationFailure(convo.id, attemptID: high)
        await store.acknowledgeConversationFailure(convo.id, attemptID: low)
        let after = try await reload(convo.id, store: store)
        XCTAssertEqual(
            after.failureSeenAttemptID, low,
            "the newest attempt is not the largest one — replacement, never max"
        )
    }

    func testAcknowledgingTouchesNeitherTheViewMarkerNorTheActivityStamp() async throws {
        let store = makeStore()
        let convo = try await seedConversation(store)
        await store.acknowledgeConversationFailure(convo.id, attemptID: UUID())

        let after = try await reload(convo.id, store: store)
        XCTAssertNil(
            after.lastViewedAt,
            "the two markers answer different questions and one is not evidence "
                + "of the other"
        )
        XCTAssertEqual(after.lastActivityAt, convo.lastActivityAt)
    }

    // MARK: - Both at once

    func testTheCombinedWriteLandsBothMarkersInOneTransaction() async throws {
        let store = makeStore()
        let convo = try await seedConversation(store)
        let attempt = UUID()

        let posts = try await countingChanges {
            await store.markConversationViewedAndAcknowledged(
                convo.id, at: noon, attemptID: attempt
            )
        }
        let after = try await reload(convo.id, store: store)
        XCTAssertEqual(after.lastViewedAt, noon)
        XCTAssertEqual(after.failureSeenAttemptID, attempt)
        XCTAssertEqual(after.lastActivityAt, convo.lastActivityAt)
        XCTAssertEqual(
            posts, 1,
            "one click means one save, one post and one export — and no reload "
                + "can land between the two markers and paint the row half-updated"
        )
    }

    func testTheCombinedWriteAcknowledgesEvenWhenTheViewMarkerCannotMove() async throws {
        // Neither arm may short-circuit the other: the user has seen this
        // failure whether or not the view marker had anywhere to go.
        let store = makeStore()
        let convo = try await seedConversation(store)
        await store.markConversationViewed(convo.id, at: noon)
        let attempt = UUID()

        let posts = try await countingChanges {
            await store.markConversationViewedAndAcknowledged(
                convo.id, at: noon.addingTimeInterval(-60), attemptID: attempt
            )
        }
        let after = try await reload(convo.id, store: store)
        XCTAssertEqual(after.lastViewedAt, noon, "the older stamp still loses")
        XCTAssertEqual(after.failureSeenAttemptID, attempt)
        XCTAssertEqual(posts, 1)
    }

    func testTheCombinedWriteMovesTheViewMarkerEvenWhenTheAcknowledgementRepeats() async throws {
        let store = makeStore()
        let convo = try await seedConversation(store)
        let attempt = UUID()
        await store.acknowledgeConversationFailure(convo.id, attemptID: attempt)

        let posts = try await countingChanges {
            await store.markConversationViewedAndAcknowledged(
                convo.id, at: noon, attemptID: attempt
            )
        }
        let after = try await reload(convo.id, store: store)
        XCTAssertEqual(after.lastViewedAt, noon)
        XCTAssertEqual(after.failureSeenAttemptID, attempt)
        XCTAssertEqual(posts, 1)
    }

    func testACombinedWriteWithNoAttemptIDNeverErasesAnAcknowledgement() async throws {
        // A nil is not a clear and not a wildcard: it means the row had no
        // failure to acknowledge, or one carrying no identity. Writing it would
        // relight the mark on every device because somebody opened a
        // conversation.
        let store = makeStore()
        let convo = try await seedConversation(store)
        let attempt = UUID()
        await store.acknowledgeConversationFailure(convo.id, attemptID: attempt)

        await store.markConversationViewedAndAcknowledged(convo.id, at: noon, attemptID: nil)
        let after = try await reload(convo.id, store: store)
        XCTAssertEqual(after.lastViewedAt, noon)
        XCTAssertEqual(
            after.failureSeenAttemptID, attempt,
            "another device's acknowledgement must survive this device opening "
                + "the thread"
        )
    }

    func testACombinedWriteThatMovesNothingSavesNothing() async throws {
        let store = makeStore()
        let convo = try await seedConversation(store)
        let attempt = UUID()
        await store.markConversationViewedAndAcknowledged(
            convo.id, at: noon, attemptID: attempt
        )

        let posts = try await countingChanges {
            await store.markConversationViewedAndAcknowledged(
                convo.id, at: noon, attemptID: attempt
            )
        }
        XCTAssertEqual(posts, 0)
    }

    // MARK: - A conversation that is not there

    func testAMarkerWriteForAConversationThatIsNotPresentDoesNothing() async throws {
        // Best-effort and non-throwing by contract: a marker write happens
        // because the user opened a thread, and nothing about opening a thread
        // may fail on a store that cannot answer.
        let store = makeStore()
        _ = try await seedConversation(store)
        let absent = UUID()

        let posts = try await countingChanges {
            await store.markConversationViewed(absent, at: noon)
            await store.acknowledgeConversationFailure(absent, attemptID: UUID())
            await store.markConversationViewedAndAcknowledged(
                absent, at: noon, attemptID: UUID()
            )
        }
        XCTAssertEqual(posts, 0)
    }

    // MARK: - The legacy fold

    func testFoldingAMarkerTheRecordDoesNotCoverSavesIt() async throws {
        let store = makeStore()
        let convo = try await seedConversation(store)

        let outcome = await store.foldLegacyReadMarker(convo.id, localMarker: noon)
        XCTAssertEqual(outcome, .saved)
        let after = try await reload(convo.id, store: store)
        XCTAssertEqual(after.lastViewedAt, noon)
        XCTAssertEqual(
            after.lastActivityAt, convo.lastActivityAt,
            "the fold moves a read marker, not the thread"
        )
    }

    func testFoldingAMarkerTheRecordAlreadyCoversWritesNothing() async throws {
        let store = makeStore()
        let convo = try await seedConversation(store)
        await store.markConversationViewed(convo.id, at: noon)

        let older = await store.foldLegacyReadMarker(
            convo.id, localMarker: noon.addingTimeInterval(-60)
        )
        XCTAssertEqual(older, .alreadyCovered)
        let equal = await store.foldLegacyReadMarker(convo.id, localMarker: noon)
        XCTAssertEqual(
            equal, .alreadyCovered,
            "an equal stamp is covered — the key may be deleted, and nothing is "
                + "written for it"
        )
        let after = try await reload(convo.id, store: store)
        XCTAssertEqual(after.lastViewedAt, noon)
    }

    func testFoldingAConversationThatIsNotPresentReportsFailedSoItsKeySurvives() async throws {
        // The case a one-shot migration with a done-flag gets wrong: the initial
        // CloudKit import is asynchronous, so absence from a fetch is not proof
        // of deletion.
        let store = makeStore()
        _ = try await seedConversation(store)

        let outcome = await store.foldLegacyReadMarker(UUID(), localMarker: noon)
        XCTAssertEqual(
            outcome, .failed,
            "reporting `.alreadyCovered` here would tell the caller to delete the "
                + "only remaining copy of a read marker whose conversation has "
                + "simply not arrived yet"
        )
    }

    func testFoldingPostsNoChangeNotification() async throws {
        // The value the fold commits is one the read path was ALREADY answering
        // with, so nothing on this device renders differently; posting would fan
        // a whole-list refetch per folded key, and the first launch after the
        // upgrade folds them in batches.
        let store = makeStore()
        let convo = try await seedConversation(store)

        var outcome: ReadMarkerFoldOutcome = .failed
        let posts = try await countingChanges {
            outcome = await store.foldLegacyReadMarker(convo.id, localMarker: noon)
        }
        XCTAssertEqual(outcome, .saved)
        XCTAssertEqual(posts, 0)
    }

    func testFoldingNeverAcknowledgesAFailure() async throws {
        // Legacy failure acknowledgements are deliberately never migrated: a
        // stale fold can silence a failure that re-occurred after the upgrade,
        // and the safe direction is one extra red mark rather than a hidden one.
        let store = makeStore()
        let convo = try await seedConversation(store)
        _ = await store.foldLegacyReadMarker(convo.id, localMarker: noon)
        let after = try await reload(convo.id, store: store)
        XCTAssertNil(after.failureSeenAttemptID)
    }
}
