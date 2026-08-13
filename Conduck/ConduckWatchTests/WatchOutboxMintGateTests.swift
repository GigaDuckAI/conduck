// SPDX-License-Identifier: Apache-2.0

// Conduck — watchOS-only contract test.
//
// Locks the gate on `WatchAudioUploader.outboxKey(forLane:conversationID:)` —
// the decision that puts a per-dispatch output folder on the wire from the
// wrist, or does not. It lives in the watchOS target, so ConduckTests (whose
// TEST_HOST is the iOS/macOS app) cannot see it; it runs here.
//
// WHY IT MATTERS: readiness and lane identity are TWO facts, and
// `WatchSettingsReader.remoteAgentFileLane` documents the state where they
// disagree — `ready == true`, `laneID == nil` — as legitimate and specific: the
// paired iPhone predates the lane courier. Minting on readiness alone names a
// folder the persistence layer then drops (`ConversationStore.appendMessage`
// writes `outputBoxKey` only alongside an `outputScanLaneID`), so an agent that
// obeys writes files into a directory NOTHING will ever list — unreachable by
// the retro scan, unreachable by the manual affordance, unreachable by any
// route. Asking for files nobody can collect is strictly worse than not asking.
//
// Deterministic + headless: a pure function over a value tuple. No network, no
// settings singleton, no Core Data, no WCSession.

import XCTest
@testable import ConduckWatch_Watch_App

final class WatchOutboxMintGateTests: XCTestCase {

    /// 64 lowercase hex — the shape `FileTransferSnapshot.durableLaneID` emits
    /// and the iPhone couriers.
    private let laneA = String(repeating: "ab", count: 32)

    /// THE defect this locks. An OLD iPHONE → NEW WATCH pair courier readiness
    /// but no identity. The wrist must name no folder: the reply row it later
    /// writes carries no lane, and a row with no lane keeps no folder either.
    func testAReadyLaneWithNoCourieredIdentityNamesNoFolder() {
        XCTAssertNil(
            WatchAudioUploader.outboxKey(
                forLane: (ready: true, laneID: nil),
                conversationID: UUID()
            ),
            """
            A folder named here is dropped at persistence and listed by nothing — \
            the agent writes into a directory unreachable by every route.
            """
        )
    }

    /// The ordinary wrist turn: both halves couriered, so the dispatch names a
    /// folder and a capable device lists it later.
    func testACourieredLanePairNamesAFolderInTheConversationsOwnFolder() throws {
        let conversationID = UUID()
        let key = try XCTUnwrap(
            WatchAudioUploader.outboxKey(
                forLane: (ready: true, laneID: laneA),
                conversationID: conversationID
            ),
            "A complete lane pair is exactly the state that earns an outbox."
        )
        XCTAssertTrue(
            key.hasPrefix(conversationID.uuidString + "/" + OutboxKey.componentPrefix),
            "The wrist mints the same two-segment shape as every other surface."
        )
    }

    /// No ready lane → nothing, whatever else is in hand. Fail closed: an
    /// identity without readiness describes a lane the sender has withdrawn.
    func testAnUnreadyLaneNamesNoFolderEvenHoldingAnIdentity() {
        XCTAssertNil(
            WatchAudioUploader.outboxKey(
                forLane: (ready: false, laneID: laneA),
                conversationID: UUID()
            ),
            "Readiness is the permission; an id alone is not one."
        )
        XCTAssertNil(
            WatchAudioUploader.outboxKey(
                forLane: (ready: false, laneID: nil),
                conversationID: UUID()
            )
        )
    }

    /// PER-DISPATCH, never per-conversation: two turns in one conversation get
    /// two folders, or a late file from the earlier turn lands in the later
    /// turn's listing and is attributed to a reply that never produced it.
    func testEachDispatchNamesItsOwnFolder() throws {
        let conversationID = UUID()
        let first = try XCTUnwrap(
            WatchAudioUploader.outboxKey(forLane: (ready: true, laneID: laneA), conversationID: conversationID)
        )
        let second = try XCTUnwrap(
            WatchAudioUploader.outboxKey(forLane: (ready: true, laneID: laneA), conversationID: conversationID)
        )
        XCTAssertNotEqual(first, second,
                          "A reused path lets an abandoned attempt's file surface as this turn's output.")
    }
}
