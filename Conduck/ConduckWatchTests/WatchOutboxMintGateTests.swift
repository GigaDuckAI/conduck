// SPDX-License-Identifier: Apache-2.0

// Conduck — watchOS-only contract test.
//
// Locks the gate on `WatchAudioUploader.outboxKey(forLane:conversationID:)` —
// the decision that puts a per-dispatch output folder on the wire from the
// wrist, or does not. It lives in the watchOS target, so ConduckTests (whose
// TEST_HOST is the iOS/macOS app) cannot see it; it runs here.
//
// WHY IT MATTERS: readiness, lane identity and return capability are THREE
// facts, and `WatchSettingsReader.remoteAgentFileLane` documents every state
// where they disagree as legitimate and specific.
//   - `ready == true`, `laneID == nil`: the paired iPhone predates the lane
//     courier. Minting on readiness alone names a folder the persistence layer
//     then drops (`ConversationStore.appendMessage` writes `outputBoxKey` only
//     alongside an `outputScanLaneID`), so an agent that obeys writes files into
//     a directory NOTHING will ever list.
//   - `returnCapable == false`: the server answered a `PROPFIND` with `405`/`501`
//     and can therefore never list ANY folder, whatever else is in hand. The
//     wrist holds no file-server credential, issues no absence witness, and so
//     cannot discover this for itself — the iPhone couriers the verdict. Naming
//     a folder anyway earns the turn a permanent "couldn't read your file
//     server" fault row on the first capable device that opens the thread.
// Asking for files nobody can collect is strictly worse than not asking.
//
// Deterministic + headless: a pure function over a value tuple. No network, no
// settings singleton, no Core Data, no WCSession. The courier + persistence half
// — how that tuple gets its values and survives a relaunch — is locked next door
// in `WatchFileLaneReturnCapabilityTests`.

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
                forLane: (ready: true, laneID: nil, returnCapable: true),
                conversationID: UUID()
            ),
            """
            A folder named here is dropped at persistence and listed by nothing — \
            the agent writes into a directory unreachable by every route.
            """
        )
    }

    /// The ordinary wrist turn: every half couriered, so the dispatch names a
    /// folder and a capable device lists it later.
    func testACourieredLanePairNamesAFolderInTheConversationsOwnFolder() throws {
        let conversationID = UUID()
        let key = try XCTUnwrap(
            WatchAudioUploader.outboxKey(
                forLane: (ready: true, laneID: laneA, returnCapable: true),
                conversationID: conversationID
            ),
            "A complete lane pair is exactly the state that earns an outbox."
        )
        XCTAssertTrue(
            key.hasPrefix(conversationID.uuidString + "/" + OutboxKey.componentPrefix),
            "The wrist mints the same two-segment shape as every other surface."
        )
    }

    /// THE defect this file was extended for. A file server that uploads but
    /// cannot LIST (plain nginx with `dav_methods PUT DELETE`) is READY and has a
    /// real lane identity — every other gate here passes — yet a folder named on
    /// it can never be read by anything. Every non-wrist surface already refuses;
    /// the wrist must refuse on the same fact rather than on a proxy for it.
    func testAProvenIncapableLaneNamesNoFolderDespiteReadinessAndIdentity() {
        XCTAssertNil(
            WatchAudioUploader.outboxKey(
                forLane: (ready: true, laneID: laneA, returnCapable: false),
                conversationID: UUID()
            ),
            """
            A server that answers 405/501 to PROPFIND lists nothing, ever — the \
            turn would be persisted pointing at a folder that earns it a \
            permanent "couldn't read your file server" fault on the phone.
            """
        )
    }

    /// The capability is a NARROWING applied only on proof, so the permissive
    /// value is the one an un-upgraded iPhone produces: its envelope omits the
    /// key, the decoder reads `true`, and the wrist keeps minting exactly as it
    /// did before the courier existed. This pins that the gate reads the flag and
    /// not merely "the flag was populated".
    func testTheCapableValueIsTheOneThatMints() throws {
        XCTAssertNotNil(
            WatchAudioUploader.outboxKey(
                forLane: (ready: true, laneID: laneA, returnCapable: true),
                conversationID: UUID()
            ),
            "Absence of proof is not proof — a capable lane must keep its folder."
        )
    }

    /// No ready lane → nothing, whatever else is in hand. Fail closed: an
    /// identity without readiness describes a lane the sender has withdrawn.
    func testAnUnreadyLaneNamesNoFolderEvenHoldingAnIdentity() {
        XCTAssertNil(
            WatchAudioUploader.outboxKey(
                forLane: (ready: false, laneID: laneA, returnCapable: true),
                conversationID: UUID()
            ),
            "Readiness is the permission; an id alone is not one."
        )
        XCTAssertNil(
            WatchAudioUploader.outboxKey(
                forLane: (ready: false, laneID: nil, returnCapable: true),
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
            WatchAudioUploader.outboxKey(
                forLane: (ready: true, laneID: laneA, returnCapable: true),
                conversationID: conversationID
            )
        )
        let second = try XCTUnwrap(
            WatchAudioUploader.outboxKey(
                forLane: (ready: true, laneID: laneA, returnCapable: true),
                conversationID: conversationID
            )
        )
        XCTAssertNotEqual(first, second,
                          "A reused path lets an abandoned attempt's file surface as this turn's output.")
    }
}
