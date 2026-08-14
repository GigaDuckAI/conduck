// SPDX-License-Identifier: Apache-2.0

// Conduck — watchOS-only contract tests for the couriered file-server RETURN
// capability: the one file-lane fact the wrist cannot measure and must never
// guess.
//
// WHY THIS EXISTS. The wrist holds no file-server credential by design, so it
// issues no absence witness and has no way to discover that a server refuses to
// LIST a collection — yet it still NAMES a per-dispatch output folder on every
// spoken turn, because naming a path needs no credential. On a server that
// uploads but cannot list (plain nginx with `dav_methods PUT DELETE`), that name
// is worse than useless: the agent writes into a directory nothing can read, the
// turn is persisted pointing at it, and the first capable device to open the
// thread runs the retroactive scan and shows a permanent "couldn't read your
// file server" fault — for a limitation Settings already states in amber as
// "Uploads only". So the iPhone, which CAN measure it, couriers the verdict on
// `RemoteAgentBroadcastEnvelope.fileTransferReturnCapable`, and these tests pin
// what the wrist does with it.
//
// FOUR CONTRACTS:
//   1. TOLERANT DECODE, CAPABLE DEFAULT — a missing wire key leaves the wrist
//      minting. The flag is a narrowing applied only on proof, so absence is
//      absence of evidence; a `false` default would switch wrist file return off
//      for every pair mid-upgrade and for every pair whose iPhone runs older
//      code.
//   2. THE VERDICT NARROWS THE MINT AND NOTHING ELSE — an incapable lane still
//      hands back its identity, because `ConversationHistoryAssembler` reads the
//      same id to recognise a thread's earlier server files as reachable, and an
//      upload-only lane's earlier UPLOADS genuinely are reachable.
//   3. DURABLE — it survives a Watch relaunch, because a ControlWidget cold
//      start can dispatch a turn before any envelope arrives.
//   4. LIFECYCLE-BOUND — it is set, replaced, and cleared alongside its lane
//      siblings, never orphaned pointing at a gateway that is gone, and never
//      the last holder of a stale incapability after the user repairs a server.
//
// The pure mint gate these feed is locked next door in `WatchOutboxMintGateTests`.
//
// Envelopes carry built-in refs only, so no path here touches the Watch Keychain
// (signing-gated on the simulator).

import XCTest
@testable import ConduckWatch_Watch_App

@MainActor
final class WatchFileLaneReturnCapabilityTests: XCTestCase {

    /// 64 lowercase hex — the shape `FileTransferSnapshot.durableLaneID` emits
    /// and the iPhone couriers. Anything off-shape is rejected at the envelope
    /// boundary, so a malformed value could never reach these assertions.
    private let laneA = String(repeating: "ab", count: 32)

    private let openclaw = RemoteAgentRef.builtin(.openclaw)

    /// `WatchSettingsReader` is a process singleton over ONE in-memory App-Group
    /// double shared by every test in the run, so each case here has to restore
    /// clean the way the rest of the watch suite does. Chief offender: the
    /// teardown marker, which permanently suppresses cold-launch config
    /// hydration for every test that follows — including this file's own
    /// relaunch case.
    override func tearDown() {
        let appGroup = TestStores.defaults
        // Mirrors `WatchSettingsReader.remoteAgentTornDownKey`, which is private.
        appGroup.removeObject(forKey: "watch.remoteAgentTornDown")
        for backend in RemoteAgentBackend.allCases {
            appGroup.removeObject(
                forKey: WatchSettingsReader.fileServerReturnCapableKey(for: .builtin(backend)))
        }
        super.tearDown()
    }

    /// One built-in sub-envelope with a ready lane, a real identity, and an
    /// explicit return verdict — the shape a current iPhone broadcasts.
    private func sub(
        ref: String = "openclaw",
        lane: String?,
        returnCapable: Bool,
        _ timestamp: TimeInterval
    ) -> RemoteAgentBroadcastEnvelope {
        RemoteAgentBroadcastEnvelope(
            backendRef: ref,
            url: URL(string: "https://\(ref).example.test")!,
            name: nil, model: nil, colorID: nil, monogram: nil, token: "t",
            certFingerprintHex: nil,
            fileTransferAvailable: lane != nil,
            fileTransferLaneID: lane,
            fileTransferReturnCapable: returnCapable,
            activeSessionID: nil,
            timestamp: timestamp
        )
    }

    private func multi(
        _ subs: [RemoteAgentBroadcastEnvelope],
        _ timestamp: TimeInterval,
        clearAll: Bool? = nil
    ) -> RemoteAgentMultiBroadcastEnvelope {
        RemoteAgentMultiBroadcastEnvelope(
            backends: subs,
            defaultBackendRef: "openclaw",
            timestamp: timestamp,
            sessionPolicy: nil,
            clearAll: clearAll
        )
    }

    // MARK: - 1. Tolerant decode, capable default

    /// BACK-COMPAT WITH AN OLDER PHONE. The wire key is simply absent, and the
    /// wrist must land on CAPABLE — the state where its pre-courier behaviour was
    /// correct. The sub-envelope is built with `false` before the key is stripped,
    /// so a decoder that somehow preserved the value would fail this rather than
    /// pass by coincidence.
    func testAMissingWireKeyLeavesTheWristMinting() throws {
        let reader = WatchSettingsReader.shared
        let ts = reader.lastRemoteAgentEnvelopeTimestamp + 9_100

        var subDict = sub(lane: laneA, returnCapable: false, ts).encodedDict()
        subDict.removeValue(forKey: "fileTransferReturnCapable")
        XCTAssertNil(subDict["fileTransferReturnCapable"],
                     "precondition: this case is only meaningful with the key absent")

        let envelope = try XCTUnwrap(RemoteAgentMultiBroadcastEnvelope.decode(from: [
            "backends": [subDict],
            "defaultBackend": "openclaw",
            "timestamp": ts,
        ]), "A missing capability key must never strand the whole envelope.")
        XCTAssertTrue(reader.updateRemoteAgents(multi: envelope))

        XCTAssertTrue(reader.remoteAgentFileReturnCapable(for: "openclaw"),
                      "Absence of evidence is not evidence of absence — an un-upgraded iPhone must not disable wrist file return.")
        XCTAssertNotNil(
            WatchAudioUploader.outboxKey(
                forLane: reader.remoteAgentFileLane(for: "openclaw"),
                conversationID: UUID()
            ),
            "The pre-courier behaviour is the correct behaviour for a pre-courier sender."
        )
    }

    /// A ref the wrist has never heard of resolves capable too — same reasoning,
    /// and the reason the map's absent-key default runs opposite to every
    /// sibling map in the reader.
    func testANeverBroadcastRefReadsCapable() {
        XCTAssertTrue(
            WatchSettingsReader.shared.remoteAgentFileReturnCapable(for: "custom_never-broadcast"),
            "An unmeasured server is not a proven-incapable one."
        )
    }

    // MARK: - 2. The verdict narrows the mint and nothing else

    /// THE DEFECT. Ready lane, real identity, and a server that has structurally
    /// refused to list: every dispatch on the phone / Mac / CarPlay already goes
    /// out folder-less, and the wrist must too.
    func testAProvenIncapableLaneStopsMintingButKeepsItsIdentity() {
        let reader = WatchSettingsReader.shared
        let ts = reader.lastRemoteAgentEnvelopeTimestamp + 9_200

        XCTAssertTrue(reader.updateRemoteAgents(
            multi: multi([sub(lane: laneA, returnCapable: false, ts)], ts)))

        let lane = reader.remoteAgentFileLane(for: "openclaw")
        XCTAssertTrue(lane.ready,
                      "An upload-only server is still READY — files may go up, they just can't come back.")
        XCTAssertEqual(lane.laneID, laneA, """
            The identity must survive: ConversationHistoryAssembler reads it to \
            recognise this thread's earlier server files as reachable, and an \
            upload-only lane's earlier UPLOADS are reachable. Withholding it \
            would make every wrist turn claim the user's own attachments gone.
            """)
        XCTAssertFalse(lane.returnCapable)
        XCTAssertNil(
            WatchAudioUploader.outboxKey(forLane: lane, conversationID: UUID()),
            "The one thing that narrows is the invitation to send something back."
        )
    }

    /// The ordinary pair, through the full courier path rather than the pure
    /// gate: a capable lane still mints.
    func testACapableLaneStillMints() {
        let reader = WatchSettingsReader.shared
        let ts = reader.lastRemoteAgentEnvelopeTimestamp + 9_300

        XCTAssertTrue(reader.updateRemoteAgents(
            multi: multi([sub(lane: laneA, returnCapable: true, ts)], ts)))

        XCTAssertNotNil(
            WatchAudioUploader.outboxKey(
                forLane: reader.remoteAgentFileLane(for: "openclaw"),
                conversationID: UUID()
            ),
            "Enforcement must cost nothing on the servers that were always fine."
        )
    }

    /// Per-ref, never global: one gateway's refusal must not silence another's
    /// file return. The maps are keyed by ref for exactly this reason.
    func testTheVerdictIsPerRefNotGlobal() {
        let reader = WatchSettingsReader.shared
        let ts = reader.lastRemoteAgentEnvelopeTimestamp + 9_400
        let laneB = String(repeating: "cd", count: 32)

        XCTAssertTrue(reader.updateRemoteAgents(multi: multi([
            sub(ref: "openclaw", lane: laneA, returnCapable: false, ts),
            sub(ref: "hermes", lane: laneB, returnCapable: true, ts),
        ], ts)))

        XCTAssertFalse(reader.remoteAgentFileReturnCapable(for: "openclaw"))
        XCTAssertTrue(reader.remoteAgentFileReturnCapable(for: "hermes"),
                      "Refs must never borrow each other's verdict.")
        XCTAssertNil(WatchAudioUploader.outboxKey(
            forLane: reader.remoteAgentFileLane(for: "openclaw"), conversationID: UUID()))
        XCTAssertNotNil(WatchAudioUploader.outboxKey(
            forLane: reader.remoteAgentFileLane(for: "hermes"), conversationID: UUID()))
    }

    // MARK: - 3. Durable across a Watch relaunch

    /// A ControlWidget cold start can dispatch a turn before any envelope
    /// arrives. Without the durable slot the wrist would fall back to the capable
    /// default on exactly that launch and name a folder on the one kind of server
    /// that has already proved it can never list one. A second reader over the
    /// same App Group IS the relaunch: it hydrates from durable stores only
    /// because its own caches are empty.
    func testTheVerdictSurvivesAWatchRelaunch() {
        let reader = WatchSettingsReader.shared
        let ts = reader.lastRemoteAgentEnvelopeTimestamp + 9_500

        XCTAssertTrue(reader.updateRemoteAgents(
            multi: multi([sub(lane: laneA, returnCapable: false, ts)], ts)))
        XCTAssertEqual(
            TestStores.defaults.object(
                forKey: WatchSettingsReader.fileServerReturnCapableKey(for: openclaw)) as? Bool,
            false,
            "Accepting the envelope must write the durable slot, not only the in-memory map."
        )

        let relaunched = WatchSettingsReader(dependencies: .processDefault)

        // Asserted first so the nil-mint below can't pass vacuously: a lane that
        // failed to hydrate at all would also name no folder, for the wrong reason.
        XCTAssertEqual(relaunched.remoteAgentFileLane(for: "openclaw").laneID, laneA,
                       "precondition: the relaunched reader rehydrated the lane at all")
        XCTAssertFalse(relaunched.remoteAgentFileReturnCapable(for: "openclaw"),
                       "A fresh process must rehydrate the verdict, not re-guess it.")
        XCTAssertNil(
            WatchAudioUploader.outboxKey(
                forLane: relaunched.remoteAgentFileLane(for: "openclaw"),
                conversationID: UUID()
            ),
            "The first turn after a cold launch is exactly the one that would otherwise be mis-minted."
        )
    }

    // MARK: - 4. Lifecycle — set, replaced, cleared with its siblings

    /// A REPAIRED server must heal without anyone re-pairing the Watch. The
    /// persisted flag never gates dispatch on the phone for the same reason —
    /// the wrist's copy must be replaced, not merged, so it can never be the last
    /// holder of a verdict the user has already fixed.
    func testARepairedServerClearsTheVerdictOnTheNextEnvelope() {
        let reader = WatchSettingsReader.shared
        let base = reader.lastRemoteAgentEnvelopeTimestamp + 9_600

        XCTAssertTrue(reader.updateRemoteAgents(
            multi: multi([sub(lane: laneA, returnCapable: false, base)], base)))
        XCTAssertFalse(reader.remoteAgentFileReturnCapable(for: "openclaw"),
                       "precondition: the lane is recorded as proven-incapable")

        XCTAssertTrue(reader.updateRemoteAgents(
            multi: multi([sub(lane: laneA, returnCapable: true, base + 1)], base + 1)))
        XCTAssertTrue(reader.remoteAgentFileReturnCapable(for: "openclaw"),
                      "A user who fixes their server must not have to re-pair the Watch to get files back.")
        XCTAssertNotNil(WatchAudioUploader.outboxKey(
            forLane: reader.remoteAgentFileLane(for: "openclaw"), conversationID: UUID()))
    }

    /// A ref OMITTED from a newer envelope loses its verdict with the rest of its
    /// lane — the maps are replaced, never merged, so nothing is left pointing at
    /// a gateway this sender no longer configures.
    func testAnOmittedRefLosesItsVerdictAndItsDurableSlot() {
        let reader = WatchSettingsReader.shared
        let base = reader.lastRemoteAgentEnvelopeTimestamp + 9_700
        let laneB = String(repeating: "cd", count: 32)

        XCTAssertTrue(reader.updateRemoteAgents(multi: multi([
            sub(ref: "openclaw", lane: laneA, returnCapable: true, base),
            sub(ref: "hermes", lane: laneB, returnCapable: false, base),
        ], base)))
        XCTAssertFalse(reader.remoteAgentFileReturnCapable(for: "hermes"),
                       "precondition: hermes is recorded as proven-incapable")

        XCTAssertTrue(reader.updateRemoteAgents(
            multi: multi([sub(ref: "openclaw", lane: laneA, returnCapable: true, base + 1)], base + 1)))

        XCTAssertTrue(reader.remoteAgentFileReturnCapable(for: "hermes"),
                      "An omitted ref must fall back to the default, not retain a stale verdict.")
        XCTAssertNil(
            TestStores.defaults.object(
                forKey: WatchSettingsReader.fileServerReturnCapableKey(for: .builtin(.hermes))),
            "The durable slot must go too, or the next cold launch resurrects it."
        )
    }

    /// TEARDOWN — the user forgot their last gateway on the iPhone. Every per-ref
    /// slot goes, this one included: a verdict left behind describes a gateway
    /// that no longer exists, and this project's wrist-state scar tissue is
    /// precisely about state outliving the gateway it belonged to.
    func testTeardownClearsTheVerdictWithTheRestOfTheLane() {
        let reader = WatchSettingsReader.shared
        let base = reader.lastRemoteAgentEnvelopeTimestamp + 9_800

        XCTAssertTrue(reader.updateRemoteAgents(
            multi: multi([sub(lane: laneA, returnCapable: false, base)], base)))
        XCTAssertFalse(reader.remoteAgentFileReturnCapable(for: "openclaw"),
                       "precondition: the lane is recorded as proven-incapable")

        XCTAssertTrue(reader.updateRemoteAgents(multi: multi([], base + 1, clearAll: true)))

        XCTAssertTrue(reader.remoteAgentFileReturnCapable(for: "openclaw"),
                      "A torn-down gateway must leave no verdict behind in memory.")
        XCTAssertNil(
            TestStores.defaults.object(
                forKey: WatchSettingsReader.fileServerReturnCapableKey(for: openclaw)),
            "…nor in the durable store, which is what a relaunch reads."
        )
        XCTAssertNil(reader.remoteAgentFileLane(for: "openclaw").laneID,
                     "Sanity: the verdict is cleared by the same path that clears its siblings.")
    }

    /// OLD iPHONE (single envelope only) → NEW WATCH. A pre-multi sender cannot
    /// name the gateway a verdict described, so accepting its envelope retires
    /// the verdict along with the lane identity. Dropping it resolves to CAPABLE,
    /// which is the right answer for a sender that never stated otherwise.
    func testLegacySingleEnvelopeRetiresTheCourieredVerdict() {
        let reader = WatchSettingsReader.shared
        let base = reader.lastRemoteAgentEnvelopeTimestamp + 9_900

        XCTAssertTrue(reader.updateRemoteAgents(
            multi: multi([sub(lane: laneA, returnCapable: false, base)], base)))
        XCTAssertFalse(reader.remoteAgentFileReturnCapable(for: "openclaw"),
                       "precondition: a multi-gateway sender couriered a refusal")

        XCTAssertTrue(reader.updateRemoteAgent(
            backend: .openclaw,
            url: URL(string: "https://openclaw.example.test")!,
            fingerprint: nil,
            sessionID: nil,
            timestamp: base + 1
        ))

        XCTAssertTrue(reader.remoteAgentFileReturnCapable(for: "openclaw"),
                      "A verdict must not outlive the sender that vouched for it.")
        XCTAssertNil(
            TestStores.defaults.object(
                forKey: WatchSettingsReader.fileServerReturnCapableKey(for: openclaw)),
            "The durable slot retires in the same breath as the lane identity's."
        )
    }
}
