// SPDX-License-Identifier: Apache-2.0

// Conduck
// FileServerReturnCapabilitySettingsTests.swift
//
// Locks the per-gateway RETURN-capability verdict — `fileServer.returnCapable.*`,
// the stored answer to "can this file server list a folder at all". It is the
// whole return direction: every file an agent produces reaches the device
// through a PROPFIND of the per-dispatch output box, so a lane with this false
// moves bytes up perfectly and can never bring one back.
//
// What is pinned here, and why each one is a bug that shipped or nearly did:
//   • ABSENT READS CAPABLE. The flag is a narrowing applied only on a structural
//     `405`/`501`, so "no stored value" is the absence of evidence. Defaulting
//     false would silently demote every install that has not re-tested — telling
//     users with capable servers that files cannot come back, and switching off
//     wrist file return across a whole paired watch.
//   • IT SURVIVES THE PROCESS. Held only in memory, an upload-only verdict
//     vanished on relaunch and the badge went green again, asserting both
//     directions on a server that had just told us it has one.
//   • AN IDENTITY CHANGE FORGETS IT. The verdict describes a SERVER. A lane
//     repointed at a new URL, or given a rotated credential, that kept the old
//     server's `false` would display — and courier to the wrist — a limitation
//     of a machine that is no longer there.
//   • ONLY A SETTLED VERDICT IS WRITTEN. A probe that learned nothing must
//     neither narrow nor widen; `.preserve` exists so "leave it alone" and
//     "forget it" cannot be spelled the same way.
//
// Isolated in-memory `SettingsManager` per test — no shared singleton, no App
// Group, no KVS of the founder's.

import XCTest
@testable import Conduck

final class FileServerReturnCapabilitySettingsTests: XCTestCase {

    private let ref = RemoteAgentRef.custom(UUID())
    private let url = URL(string: "https://files.example.test")!

    private func makeManager(
        defaults: InMemoryDefaultsStore = InMemoryDefaultsStore(),
        kvs: InMemoryUbiquitousStore = InMemoryUbiquitousStore(),
        secrets: InMemorySecretStore = InMemorySecretStore()
    ) -> SettingsManager {
        SettingsManager(dependencies: .inMemory(
            defaults: defaults,
            ubiquitous: kvs,
            secrets: secrets,
            cloudAvailable: true
        ))
    }

    private var key: String { Constants.fileServerReturnCapableKey(for: ref) }

    // MARK: - The default

    func testUnsetReturnCapabilityReadsCapable() async {
        let manager = makeManager()
        let value = await manager.getFileServerReturnCapable(for: ref)
        XCTAssertTrue(value,
                      "no stored value is the absence of evidence, and only a structural refusal "
                      + "is evidence — an install that predates the key must not be demoted")
    }

    // MARK: - Surviving the process

    /// THE RELAUNCH BUG. The user tests plain nginx, correctly sees "uploads
    /// only", quits, reopens Settings — and the badge must NOT have gone green.
    func testAnUploadOnlyVerdictSurvivesARelaunch() async {
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()
        // The SECRET store is shared across both managers too, because the
        // credential is half of what makes a lane configured at all —
        // `fileTransferSnapshot` returns nil when either the URL or the
        // credential is missing, and a relaunch that forgot the Keychain would
        // model a device wipe, not a relaunch.
        let secrets = InMemorySecretStore()
        let first = makeManager(defaults: defaults, kvs: kvs, secrets: secrets)

        // Save the server, then test it — the real order in Settings. Without
        // the tuple there is nothing for a snapshot to describe, so asserting
        // on `snapshot?.returnCapable` below would compare nil against nil and
        // pass no matter what the verdict did.
        try? await first.setFileServerCredential(String(repeating: "a", count: 32), for: ref)
        await first.setFileServerURL(url, for: ref)

        await first.commitFileTransferVerdict(
            available: true, folderCapable: true, returnCapable: .set(false), for: ref)

        // A brand-new manager over the SAME stores is the relaunch.
        let relaunched = makeManager(defaults: defaults, kvs: kvs, secrets: secrets)
        let value = await relaunched.getFileServerReturnCapable(for: ref)
        XCTAssertFalse(value, "the verdict the user was shown must outlive the process that took it")

        let snapshot = await relaunched.fileTransferSnapshot(for: ref)
        XCTAssertNotNil(snapshot, "the lane is configured, so a snapshot must exist to be read")
        XCTAssertEqual(snapshot?.returnCapable, false,
                       "and it must ride the SAME atomic read as readiness, so no surface can "
                       + "pair one moment's readiness with another moment's capability")
    }

    /// A fact about the SERVER, not about this device — so it syncs, exactly
    /// like `folderCapable`. A second device must not have to re-measure before
    /// it stops claiming file return works.
    func testTheVerdictDualWritesBothStores() async {
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()
        let manager = makeManager(defaults: defaults, kvs: kvs)

        await manager.commitFileTransferVerdict(
            available: true, folderCapable: true, returnCapable: .set(false), for: ref)

        XCTAssertEqual(defaults.object(forKey: key) as? Bool, false)
        XCTAssertEqual(kvs.object(forKey: key) as? Bool, false)
    }

    // MARK: - Only a settled verdict is written

    func testPreserveLeavesAProvenIncapabilityAlone() async {
        let manager = makeManager()
        await manager.commitFileTransferVerdict(
            available: true, folderCapable: true, returnCapable: .set(false), for: ref)

        // A later test whose listing stage settled nothing (a proxy 502, a
        // timeout) preserves rather than widens.
        await manager.commitFileTransferVerdict(
            available: true, folderCapable: true, returnCapable: .preserve, for: ref)

        let value = await manager.getFileServerReturnCapable(for: ref)
        XCTAssertFalse(value, "widening on a probe that learned nothing is as wrong as narrowing on one")
    }

    func testASettledPassWidensAPreviouslyProvenIncapability() async {
        let manager = makeManager()
        await manager.commitFileTransferVerdict(
            available: true, folderCapable: true, returnCapable: .set(false), for: ref)

        await manager.commitFileTransferVerdict(
            available: true, folderCapable: true, returnCapable: .set(true), for: ref)

        let value = await manager.getFileServerReturnCapable(for: ref)
        XCTAssertTrue(value,
                      "a user who has just enabled the DAV module must stop being told their "
                      + "server cannot list folders — the flag moves on proof in BOTH directions")
    }

    // MARK: - An identity change forgets it

    /// A tuple commit RESETS by default: the verdict described whatever server
    /// the old tuple pointed at, and a replacement that lists folders perfectly
    /// must not inherit its predecessor's limitation.
    func testSavingANewTupleForgetsTheOldServersVerdict() async {
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()
        let manager = makeManager(defaults: defaults, kvs: kvs)
        await manager.commitFileTransferVerdict(
            available: true, folderCapable: true, returnCapable: .set(false), for: ref)

        await manager.commitFileTransferConfig(
            url: URL(string: "https://replacement.example.test")!,
            pin: nil,
            folderCapable: nil,
            available: false,
            for: ref
        )

        XCTAssertNil(defaults.object(forKey: key), "removed, not set true — unknown is the truth")
        XCTAssertNil(kvs.object(forKey: key), "and the reset has to reach the user's other devices")
        let value = await manager.getFileServerReturnCapable(for: ref)
        XCTAssertTrue(value, "which resolves to capable, because nothing has measured the new server")
    }

    /// A pass earned against EXACTLY the tuple being committed is the one thing
    /// that may state a verdict through this hop.
    func testACarriedSettledPassStatesTheVerdictThroughATupleCommit() async {
        let manager = makeManager()

        await manager.commitFileTransferConfig(
            url: url, pin: nil, folderCapable: true, returnCapable: .set(false),
            available: true, for: ref
        )

        let value = await manager.getFileServerReturnCapable(for: ref)
        XCTAssertFalse(value)
    }

    // MARK: - One conclusion per staged test

    /// `commitStagedFileTransferResult` is the SINGLE durable conclusion of a
    /// staged test, whichever screen ran it — the repair for two screens that
    /// each spelled their own persistence and drifted, one of them dropping the
    /// listing verdict entirely. Table-driven over the three things the listing
    /// stage can conclude, because a caller passes the RESULT and no longer has
    /// a place to forget one of them.
    func testAStagedResultCommitsOneConclusionForEveryListingOutcome() async {
        // verification → the stored verdict afterwards, starting from unknown
        let cases: [(FileTransferReturnVerification, Bool?)] = [
            (.verified, true),                                  // proven both ways
            (.methodUnavailable, false),                        // the amber uploads-only lane
            (.unverified(.fileTransferServerError), nil),       // settled nothing → nothing written
            (.notMeasured, nil)                                 // never got there → likewise
        ]
        for (verification, expected) in cases {
            let defaults = InMemoryDefaultsStore()
            let manager = makeManager(defaults: defaults)
            let result = FileTransferTestResult(
                reachedStage: .listing, success: true, failure: nil,
                returnVerification: verification)

            await manager.commitStagedFileTransferResult(result, for: ref)

            XCTAssertEqual(defaults.object(forKey: key) as? Bool, expected,
                           "listing outcome \(verification)")
            let available = await manager.getFileTransferAvailable(for: ref)
            XCTAssertTrue(available,
                          "and no listing outcome may revoke the upload half the byte-echo proved")
        }
    }

    /// A FAILED staged test never touches folder capability: the nested probe
    /// runs only after the read stage passes, so the result's optimistic default
    /// must not overwrite a previously-measured false.
    func testAFailedStagedResultLeavesFolderCapabilityAlone() async {
        let defaults = InMemoryDefaultsStore()
        let manager = makeManager(defaults: defaults)
        await manager.setFileServerFolderCapable(false, for: ref)

        await manager.commitStagedFileTransferResult(
            FileTransferTestResult(reachedStage: .write, success: false, failure: nil), for: ref)

        XCTAssertEqual(defaults.object(forKey: Constants.fileServerFolderCapableKey(for: ref)) as? Bool,
                       false, "an unrun probe is not a measurement")
        let available = await manager.getFileTransferAvailable(for: ref)
        XCTAssertFalse(available, "a failed test still fails the lane closed")
    }

    /// Every identity mutation funnels through the revoke choke point — a
    /// credential rotation, a Forget, a pairing import — so the reset cannot be
    /// forgotten at one of them.
    func testRevokingReadinessForgetsTheVerdict() async {
        let defaults = InMemoryDefaultsStore()
        let manager = makeManager(defaults: defaults)
        await manager.commitFileTransferVerdict(
            available: true, folderCapable: true, returnCapable: .set(false), for: ref)

        await manager.revokeFileTransferReadiness(for: ref)

        XCTAssertNil(defaults.object(forKey: key))
    }
}
