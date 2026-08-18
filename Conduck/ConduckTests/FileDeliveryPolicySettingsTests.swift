// SPDX-License-Identifier: Apache-2.0

// Conduck
// FileDeliveryPolicySettingsTests.swift
//
// Locks the two per-gateway delivery PROPERTIES — `fileServer.autoDeliver.*`
// (may this gateway put files on my device automatically) and
// `fileServer.filenamePolicy.*` (how a delivered name is treated). They exist
// with no UI so a later policy layer changes behaviour without touching
// storage, sync, the payload, or the Watch envelope again. Pins:
//   • unset reads the permissive default, so no existing ref changes behaviour;
//   • both ride `FileTransferSnapshot`, so dispatch reads them in the SAME actor
//     hop as readiness and can never pair one moment's permission with another
//     moment's readiness;
//   • the ONLY writers are the atomic commit hops — there is no per-key setter,
//     because two loose hops are exactly the half-state those hops exist to
//     prevent;
//   • an unrecognised filename policy is refused on write and resolves to the
//     default on read, so a newer device's value can never strand an older one.
//
// Isolated in-memory `SettingsManager` per test — no shared singleton, no App
// Group, no KVS of the founder's.

import XCTest
@testable import Conduck

final class FileDeliveryPolicySettingsTests: XCTestCase {

    private let ref = RemoteAgentRef.custom(UUID())

    private func makeManager(
        defaults: InMemoryDefaultsStore = InMemoryDefaultsStore(),
        kvs: InMemoryUbiquitousStore = InMemoryUbiquitousStore()
    ) -> SettingsManager {
        SettingsManager(dependencies: .inMemory(
            defaults: defaults,
            ubiquitous: kvs,
            secrets: InMemorySecretStore(),
            cloudAvailable: true
        ))
    }

    // MARK: - Defaults

    func testUnsetAutoDeliverIsPermissive() async {
        let manager = makeManager()
        let value = await manager.getFileServerAutoDeliver(for: ref)
        XCTAssertTrue(value, "an existing ref must keep today's behaviour without any stored value")
    }

    func testUnsetFilenamePolicyIsPreserve() async {
        let manager = makeManager()
        let value = await manager.getFileServerFilenamePolicy(for: ref)
        XCTAssertEqual(value, Constants.fileServerFilenamePolicyPreserve)
    }

    // MARK: - The commit hop

    func testCommitDeliveryPolicyDualWritesBothStores() async {
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()
        let manager = makeManager(defaults: defaults, kvs: kvs)

        await manager.commitFileDeliveryPolicy(
            autoDeliver: false,
            filenamePolicy: Constants.fileServerFilenamePolicyPreserve,
            for: ref
        )

        let autoKey = Constants.fileServerAutoDeliverKey(for: ref)
        let policyKey = Constants.fileServerFilenamePolicyKey(for: ref)
        XCTAssertEqual(defaults.object(forKey: autoKey) as? Bool, false)
        XCTAssertEqual(kvs.object(forKey: autoKey) as? Bool, false,
                       "a per-gateway policy must reach the user's other devices")
        XCTAssertEqual(defaults.string(forKey: policyKey), Constants.fileServerFilenamePolicyPreserve)
        XCTAssertEqual(kvs.object(forKey: policyKey) as? String, Constants.fileServerFilenamePolicyPreserve)

        let read = await manager.getFileServerAutoDeliver(for: ref)
        XCTAssertFalse(read)
    }

    func testCommitDeliveryPolicyLeavesOmittedFieldsAlone() async {
        let manager = makeManager()

        await manager.commitFileDeliveryPolicy(autoDeliver: false, for: ref)
        await manager.commitFileDeliveryPolicy(
            filenamePolicy: Constants.fileServerFilenamePolicyPreserve,
            for: ref
        )

        // nil means unchanged: changing one field must not silently reset the
        // other back to its default.
        let autoDeliver = await manager.getFileServerAutoDeliver(for: ref)
        XCTAssertFalse(autoDeliver, "the second commit must not have reset the permission")
    }

    func testUnknownFilenamePolicyIsRefusedOnWrite() async {
        let defaults = InMemoryDefaultsStore()
        let manager = makeManager(defaults: defaults)

        await manager.commitFileDeliveryPolicy(filenamePolicy: "shorten-and-hash", for: ref)

        XCTAssertNil(defaults.string(forKey: Constants.fileServerFilenamePolicyKey(for: ref)),
                     "storing a value no build understands only creates a lie in the store")
        let read = await manager.getFileServerFilenamePolicy(for: ref)
        XCTAssertEqual(read, Constants.fileServerFilenamePolicyPreserve)
    }

    func testUnknownStoredFilenamePolicyResolvesToTheDefault() async {
        let defaults = InMemoryDefaultsStore()
        // A newer build wrote a policy this one does not know.
        defaults.set("shorten-and-hash", forKey: Constants.fileServerFilenamePolicyKey(for: ref))
        let manager = makeManager(defaults: defaults)

        let read = await manager.getFileServerFilenamePolicy(for: ref)

        XCTAssertEqual(read, Constants.fileServerFilenamePolicyPreserve,
                       "resolving forward to the known default is what keeps the lane usable")
    }

    // MARK: - The config / verdict hops carry it too

    func testCommitFileTransferConfigCarriesTheDeliveryPolicy() async {
        let defaults = InMemoryDefaultsStore()
        let manager = makeManager(defaults: defaults)

        await manager.commitFileTransferConfig(
            url: URL(string: "https://files.example.test/dav")!,
            pin: nil,
            folderCapable: true,
            available: true,
            autoDeliver: false,
            for: ref
        )

        XCTAssertEqual(defaults.object(forKey: Constants.fileServerAutoDeliverKey(for: ref)) as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: Constants.fileTransferAvailableKey(for: ref)) as? Bool, true)
    }

    func testCommitFileTransferVerdictCarriesTheDeliveryPolicy() async {
        let defaults = InMemoryDefaultsStore()
        let manager = makeManager(defaults: defaults)

        await manager.commitFileTransferVerdict(
            available: true,
            folderCapable: true,
            autoDeliver: false,
            for: ref
        )

        XCTAssertEqual(defaults.object(forKey: Constants.fileServerAutoDeliverKey(for: ref)) as? Bool, false)
    }

    func testExistingCommitCallSitesLeaveTheDeliveryPolicyUntouched() async {
        let defaults = InMemoryDefaultsStore()
        let manager = makeManager(defaults: defaults)
        await manager.commitFileDeliveryPolicy(autoDeliver: false, for: ref)

        // A staged Test Connection carries no policy — it must not reset one.
        await manager.commitFileTransferVerdict(available: true, folderCapable: true, for: ref)

        XCTAssertEqual(defaults.object(forKey: Constants.fileServerAutoDeliverKey(for: ref)) as? Bool, false)
    }

    // MARK: - The snapshot

    func testSnapshotCarriesTheDeliveryPolicy() async {
        let defaults = InMemoryDefaultsStore()
        let manager = makeManager(defaults: defaults)
        try? await manager.setFileServerCredential(String(repeating: "a", count: 32), for: ref)
        await manager.setFileServerURL(URL(string: "https://files.example.test/dav")!, for: ref)
        await manager.commitFileDeliveryPolicy(autoDeliver: false, for: ref)

        let snapshot = await manager.fileTransferSnapshot(for: ref)

        // Riding the snapshot is what lets dispatch decide without a second
        // actor hop, and without observing a permission and a readiness from
        // two different moments.
        XCTAssertEqual(snapshot?.autoDeliver, false)
        XCTAssertEqual(snapshot?.filenamePolicy, Constants.fileServerFilenamePolicyPreserve)
    }

    func testSyntheticSnapshotDefaultsMatchTheStoredDefaults() {
        // The staged Test Connection assembles a snapshot from a DRAFT tuple; it
        // must describe the same permission a stored one would.
        let snapshot = SettingsManager.FileTransferSnapshot(
            baseURL: URL(string: "https://files.example.test/dav")!,
            username: Constants.fileServerUsername,
            credential: String(repeating: "a", count: 32),
            certFingerprintHex: nil,
            available: false,
            folderCapable: true
        )

        XCTAssertTrue(snapshot.autoDeliver)
        XCTAssertEqual(snapshot.filenamePolicy, Constants.fileServerFilenamePolicyPreserve)
    }

    func testDeliveryPolicyIsOutsideTheLaneIdentity() {
        // `identitySignature` and `durableLaneID` describe WHICH server this is.
        // A permission change is not a different server, so a stamped lane must
        // still match after one — otherwise every toggle would orphan every
        // pending output scan.
        let base = SettingsManager.FileTransferSnapshot(
            baseURL: URL(string: "https://files.example.test/dav")!,
            username: Constants.fileServerUsername,
            credential: String(repeating: "a", count: 32),
            certFingerprintHex: nil,
            available: true,
            folderCapable: true
        )
        let restricted = SettingsManager.FileTransferSnapshot(
            baseURL: base.baseURL,
            username: base.username,
            credential: base.credential,
            certFingerprintHex: base.certFingerprintHex,
            available: base.available,
            folderCapable: base.folderCapable,
            autoDeliver: false
        )

        XCTAssertEqual(base.identitySignature, restricted.identitySignature)
        XCTAssertEqual(base.durableLaneID, restricted.durableLaneID)
    }
}
