// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkAssetVaultTests.swift
//
// Device-local Workboard asset containment and lifecycle contracts, including
// the cross-process publication guard: the App Group vault is written by the
// app, the share extensions and the headless intent process, so reclamation
// must never mistake a leaf another process is publishing for a crash orphan.
//
// The other half of the same boundary: serving a payload means opening it, not
// stating it, and a row records the length the leaf measured rather than the
// one its caller declared — so these cases pin what an unreadable leaf, an
// intentionally empty one, and each write path are allowed to claim.

import Foundation
import CoreData
import XCTest
@testable import Conduck

final class WorkAssetVaultTests: XCTestCase {
    /// Every store here mints a vault directory of its own that nothing else
    /// removes, and the cases below deliberately write real payload leaves into
    /// them; the fixture empties them when the class is done. No case leaves a
    /// task running, so teardown cannot race a vault operation.
    private let isolated = IsolatedWorkStores()

    override func tearDown() async throws {
        await isolated.cleanUp()
        try await super.tearDown()
    }

    /// Age a vault leaf or marker on disk. Reclamation judges by timestamp, so
    /// a test fixture has to be genuinely old rather than merely unreferenced.
    private func backdate(_ url: URL, by interval: TimeInterval) throws {
        let stamp = Date().addingTimeInterval(-interval)
        try FileManager.default.setAttributes(
            [.creationDate: stamp, .modificationDate: stamp],
            ofItemAtPath: url.path
        )
    }

    private func stagingMarkerURL(in directory: URL, for key: String) -> URL {
        directory.appendingPathComponent(
            key + WorkAssetVault.stagingMarkerSuffix,
            isDirectory: false
        )
    }

    private var pastTheHorizon: Date {
        Date().addingTimeInterval(WorkAssetVault.stagingHorizon + 60)
    }

    /// Write the claim a process that died mid-publication leaves behind: a
    /// legible marker naming another instance, dated far enough back that no
    /// clock skew can still be holding it open.
    private func writeStaleClaim(at url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let claim = WorkAssetVault.StagingClaim(
            owner: UUID(),
            stagedAt: Date().addingTimeInterval(-WorkAssetVault.stagingHorizon * 2)
        )
        try encoder.encode(claim).write(to: url, options: .atomic)
    }

    func testGeneratedKeysAreOpaqueSafeLeaves() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let key = WorkAssetVault.makeKey(id: id, suggestedExtension: "../../PDF")

        XCTAssertEqual(key, "11111111-2222-3333-4444-555555555555.dat")
        XCTAssertTrue(WorkAssetVault.isSafeKey(key))
        XCTAssertFalse(WorkAssetVault.isSafeKey("../\(key)"))
        XCTAssertFalse(WorkAssetVault.isSafeKey("not-a-uuid.pdf"))
    }

    func testRoundTripAndSelectiveReclamation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("work-vault-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = WorkAssetVault(baseURL: directory)

        let keep = try await vault.store(bytes: Data("keep".utf8), suggestedExtension: "txt").key
        let remove = try await vault.store(bytes: Data("remove".utf8), suggestedExtension: "txt").key
        await vault.confirmPublication(of: keep)
        await vault.confirmPublication(of: remove)

        let loaded = try await vault.data(for: keep)
        // Judged from beyond the horizon: both leaves are unreferenced, and only
        // the database key set may decide which one survives.
        let reclaimed = await vault.reclaimUnreferenced(keeping: [keep], now: pastTheHorizon)
        let containsKept = await vault.contains(keep)
        let containsRemoved = await vault.contains(remove)

        XCTAssertEqual(loaded, Data("keep".utf8))
        XCTAssertEqual(reclaimed, 1)
        XCTAssertTrue(containsKept)
        XCTAssertFalse(containsRemoved)
    }

    func testReconciliationUsesPersistedKeysAndReclaimsOnlyOrphans() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("work-vault-reconcile-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = WorkAssetVault(baseURL: directory)
        let store = isolated.make()

        let keep = try await vault.store(bytes: Data("referenced".utf8), suggestedExtension: "txt").key
        let remove = try await vault.store(bytes: Data("orphan".utf8), suggestedExtension: "txt").key
        await vault.confirmPublication(of: keep)
        await vault.confirmPublication(of: remove)
        // The orphan predates the publication horizon; a leaf younger than that
        // is protected by age alone and would prove nothing about the fetch.
        try backdate(
            try await vault.url(for: remove),
            by: WorkAssetVault.stagingHorizon * 2
        )

        try await store.ensureLoaded()
        let context = await store.newWriteContext()
        try await context.perform { [context] in
            let row = NSEntityDescription.insertNewObject(
                forEntityName: "WorkMaterial",
                into: context
            )
            row.setValue(UUID(), forKey: "id")
            row.setValue(keep, forKey: "localVaultKey")
            row.setValue("localVault", forKey: "storageMode")
            try context.save()
        }

        let reclaimed = try await store.reconcileWorkAssetVault(using: vault)
        let containsKept = await vault.contains(keep)
        let containsRemoved = await vault.contains(remove)

        XCTAssertEqual(reclaimed, 1)
        XCTAssertTrue(containsKept, "a committed localVaultKey is authoritative")
        XCTAssertFalse(containsRemoved)
    }

    func testReconciliationProtectsAFileUntilItsDatabaseReferenceCommits() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("work-vault-staging-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = WorkAssetVault(baseURL: directory)

        // Judged from beyond the horizon throughout, so the staged key — not the
        // file's age — is what has to hold the leaf.
        let key = try await vault.store(bytes: Data("in flight".utf8), suggestedExtension: "txt").key
        let reclaimedWhileStaged = await vault.reclaimUnreferenced(
            keeping: [],
            now: pastTheHorizon
        )
        let existsWhileStaged = await vault.contains(key)
        await vault.confirmPublication(of: key)
        let reclaimedAfterPublication = await vault.reclaimUnreferenced(
            keeping: [],
            now: pastTheHorizon
        )
        let existsAfterPublication = await vault.contains(key)

        XCTAssertEqual(reclaimedWhileStaged, 0)
        XCTAssertTrue(existsWhileStaged)
        XCTAssertEqual(reclaimedAfterPublication, 1)
        XCTAssertFalse(existsAfterPublication)
    }

    // MARK: - Cross-process publication guard

    func testAYoungUnreferencedLeafSurvivesUntilThePublicationHorizonPasses() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("work-vault-young-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = WorkAssetVault(baseURL: directory)

        let key = try await vault.store(bytes: Data("fresh".utf8), suggestedExtension: "txt").key
        // Both in-process guards released: only the leaf's age can protect it,
        // which is the state a leaf staged by another process presents.
        await vault.confirmPublication(of: key)

        let reclaimedWhileYoung = await vault.reclaimUnreferenced(keeping: [])
        let survivesWhileYoung = await vault.contains(key)
        let reclaimedAfterHorizon = await vault.reclaimUnreferenced(
            keeping: [],
            now: pastTheHorizon
        )
        let survivesAfterHorizon = await vault.contains(key)

        XCTAssertEqual(reclaimedWhileYoung, 0,
                       "a leaf this young may be a payload whose row has not committed yet")
        XCTAssertTrue(survivesWhileYoung)
        XCTAssertEqual(reclaimedAfterHorizon, 1)
        XCTAssertFalse(survivesAfterHorizon)
    }

    func testAnOrphanOlderThanTheHorizonIsStillReclaimed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("work-vault-orphan-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = WorkAssetVault(baseURL: directory)

        let key = try await vault.store(
            bytes: Data("left by a crash".utf8),
            suggestedExtension: "txt"
        ).key
        await vault.confirmPublication(of: key)
        try backdate(try await vault.url(for: key), by: WorkAssetVault.stagingHorizon * 4)

        let reclaimed = await vault.reclaimUnreferenced(keeping: [])
        let survives = await vault.contains(key)

        XCTAssertEqual(reclaimed, 1, "the grace delays reclamation, it does not cancel it")
        XCTAssertFalse(survives)
    }

    func testALeafStagedByAnotherProcessIsNeverReclaimed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("work-vault-cross-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Two instances on one App Group directory: the headless publisher and
        // the foreground launch that reconciles while its row is in flight.
        let publisher = WorkAssetVault(baseURL: directory)
        let reconciler = WorkAssetVault(baseURL: directory)

        let key = try await publisher.store(
            bytes: Data("mid-publication".utf8),
            suggestedExtension: "txt"
        ).key
        let marker = stagingMarkerURL(in: directory, for: key)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path),
                      "the claim must be legible to any other process")
        // Age the leaf past the horizon so the marker alone can save it — the
        // exact case a slow publication or a stale clock would produce.
        try backdate(try await publisher.url(for: key), by: WorkAssetVault.stagingHorizon * 2)

        let reclaimedMidPublication = await reconciler.reclaimUnreferenced(keeping: [])
        let survivesMidPublication = await reconciler.contains(key)

        // The row commits, the publisher proves the leaf and releases its claim,
        // and the database now names the leaf.
        let confirmed = await publisher.confirmPublication(of: key)
        let markerCleared = FileManager.default.fileExists(atPath: marker.path)
        let reclaimedAfterCommit = await reconciler.reclaimUnreferenced(
            keeping: [key],
            now: pastTheHorizon
        )
        let survivesAfterCommit = await reconciler.contains(key)
        let bytes = try await reconciler.data(for: key)

        XCTAssertEqual(reclaimedMidPublication, 0,
                       "another process's staging claim outranks the leaf's age")
        XCTAssertTrue(survivesMidPublication)
        XCTAssertTrue(confirmed)
        XCTAssertFalse(markerCleared, "a published claim leaves no marker behind")
        XCTAssertEqual(reclaimedAfterCommit, 0)
        XCTAssertTrue(survivesAfterCommit)
        XCTAssertEqual(bytes, Data("mid-publication".utf8))
    }

    func testAnAbandonedStagingClaimStopsProtectingItsLeaf() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("work-vault-abandoned-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let crashed = WorkAssetVault(baseURL: directory)
        let reconciler = WorkAssetVault(baseURL: directory)

        let expired = try await crashed.store(
            bytes: Data("never published".utf8),
            suggestedExtension: "txt"
        ).key
        let live = try await crashed.store(
            bytes: Data("still publishing".utf8),
            suggestedExtension: "txt"
        ).key
        let expiredMarker = stagingMarkerURL(in: directory, for: expired)
        // Undecodable bytes still prove someone claimed the leaf, so the claim
        // is aged by its file — and an unrefreshed one expires.
        try Data("{ truncated".utf8).write(to: expiredMarker, options: .atomic)
        try backdate(expiredMarker, by: WorkAssetVault.stagingHorizon * 2)
        try backdate(try await crashed.url(for: expired), by: WorkAssetVault.stagingHorizon * 2)
        try backdate(try await crashed.url(for: live), by: WorkAssetVault.stagingHorizon * 2)

        let reclaimed = await reconciler.reclaimUnreferenced(keeping: [])
        let expiredSurvives = await reconciler.contains(expired)
        let liveSurvives = await reconciler.contains(live)

        XCTAssertEqual(reclaimed, 1, "a claim no process is refreshing expires with its leaf")
        XCTAssertFalse(expiredSurvives)
        XCTAssertTrue(liveSurvives, "a live claim still outranks an aged leaf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: expiredMarker.path),
                       "the expired claim leaves no marker to protect nothing")
    }

    func testStagingMarkersAreNeverConfusedWithPayloadLeaves() {
        let key = WorkAssetVault.makeKey(id: UUID(), suggestedExtension: "staging")

        XCTAssertTrue(WorkAssetVault.isSafeKey(key),
                      "`staging` is a legal path extension and stays payload")
        XCTAssertNil(WorkAssetVault.stagedKey(forMarkerNamed: key))
        XCTAssertEqual(
            WorkAssetVault.stagedKey(forMarkerNamed: key + WorkAssetVault.stagingMarkerSuffix),
            key
        )
        XCTAssertFalse(WorkAssetVault.isSafeKey(key + WorkAssetVault.stagingMarkerSuffix),
                       "a marker must never be readable as a vault object")
        XCTAssertNil(WorkAssetVault.stagedKey(forMarkerNamed: "not-a-uuid.txt.staging"))
    }

    func testAPublicationIsUnconfirmedWhenItsLeafIsMissingOrTheWrongSize() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("work-vault-confirm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = WorkAssetVault(baseURL: directory)

        let payload = Data("durable bytes".utf8)
        let published = try await vault.store(bytes: payload, suggestedExtension: "txt").key
        let confirmed = await vault.confirmPublication(
            of: published,
            expectedByteCount: Int64(payload.count)
        )

        let truncated = try await vault.store(bytes: Data("short".utf8), suggestedExtension: "txt").key
        let confirmedTruncated = await vault.confirmPublication(
            of: truncated,
            expectedByteCount: 4_096
        )
        // A refused confirmation keeps the guard, so the reclamation that
        // follows a failed publication cannot delete what is left of it.
        let reclaimed = await vault.reclaimUnreferenced(
            keeping: [published],
            now: pastTheHorizon
        )
        let truncatedSurvives = await vault.contains(truncated)

        let absent = await vault.confirmPublication(
            of: WorkAssetVault.makeKey(id: UUID(), suggestedExtension: "txt"),
            expectedByteCount: 12
        )

        XCTAssertTrue(confirmed)
        XCTAssertFalse(confirmedTruncated, "a row must not promise bytes the vault cannot serve")
        XCTAssertEqual(reclaimed, 0)
        XCTAssertTrue(truncatedSurvives)
        XCTAssertFalse(absent)
    }

    func testAnAbandonedClaimBesideAReferencedLeafIsSweptWithoutItsPayload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("work-vault-stranded-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let publisher = WorkAssetVault(baseURL: directory)
        let reconciler = WorkAssetVault(baseURL: directory)

        let payload = Data("committed elsewhere".utf8)
        let write = try await publisher.store(bytes: payload, suggestedExtension: "txt")
        let marker = stagingMarkerURL(in: directory, for: write.key)
        // The row committed in another process, so the database names this leaf
        // for as long as its card lives; only the marker removal failed, and a
        // claim nobody is refreshing then ages out.
        try writeStaleClaim(at: marker)

        let reclaimed = await reconciler.reclaimUnreferenced(keeping: [write.key])
        let markerSurvives = FileManager.default.fileExists(atPath: marker.path)
        let bytes = try await reconciler.data(for: write.key)

        XCTAssertEqual(reclaimed, 0, "a referenced leaf is never a reclamation candidate")
        XCTAssertFalse(
            markerSurvives,
            "an abandoned claim beside a permanently referenced leaf is reconsidered, not kept forever"
        )
        XCTAssertEqual(bytes, payload, "sweeping a claim never touches the payload it sat beside")
    }

    // MARK: - Readable bytes, not a stat-able path

    func testAnUnreadableLeafIsNeitherServedNorConfirmable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("work-vault-unreadable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = WorkAssetVault(baseURL: directory)

        let write = try await vault.store(bytes: Data("shut away".utf8), suggestedExtension: "txt")
        let leaf = directory.appendingPathComponent(write.key, isDirectory: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: leaf.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: leaf.path
            )
        }

        let contained = await vault.contains(write.key)
        let resolved = await vault.urls(for: [write.key])
        let readable = await vault.readableKeys(among: [write.key])
        let confirmed = await vault.confirmPublication(
            of: write.key,
            expectedByteCount: write.byteCount
        )
        // A refused confirmation keeps the guard, and reclamation judges by
        // existence: the bytes are still on disk and another process may well
        // open them, so the pass that follows must not take them away.
        let reclaimed = await vault.reclaimUnreferenced(keeping: [], now: pastTheHorizon)
        let stillOnDisk = FileManager.default.fileExists(atPath: leaf.path)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: leaf.path
        )
        let containedOnceReadable = await vault.contains(write.key)
        let confirmedOnceReadable = await vault.confirmPublication(
            of: write.key,
            expectedByteCount: write.byteCount
        )

        XCTAssertFalse(contained, "a path that only stats is not payload this device can serve")
        XCTAssertTrue(resolved.isEmpty)
        XCTAssertTrue(readable.isEmpty)
        XCTAssertFalse(
            confirmed,
            "a capture must not be acknowledged against a leaf `data(for:)` cannot open"
        )
        XCTAssertEqual(reclaimed, 0)
        XCTAssertTrue(stillOnDisk, "unreadable here is not deletable — it may be readable elsewhere")
        XCTAssertTrue(containedOnceReadable)
        XCTAssertTrue(confirmedOnceReadable)
    }

    func testAReadableEmptyLeafIsValidPayload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("work-vault-empty-leaf-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = WorkAssetVault(baseURL: directory)

        let write = try await vault.store(bytes: Data(), suggestedExtension: "bin")
        let contained = await vault.contains(write.key)
        let readable = await vault.readableKeys(among: [write.key])
        let resolved = await vault.urls(for: [write.key])
        let confirmed = await vault.confirmPublication(of: write.key, expectedByteCount: 0)
        let bytes = try await vault.data(for: write.key)

        XCTAssertEqual(write.byteCount, 0)
        XCTAssertTrue(contained, "a payload the person chose to attach is a payload at any length")
        XCTAssertEqual(readable, [write.key])
        XCTAssertEqual(resolved.count, 1)
        XCTAssertTrue(confirmed)
        XCTAssertEqual(bytes, Data())
    }

    func testEveryWritePathReportsTheLengthItsLeafActuallyHolds() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("work-vault-measured-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = WorkAssetVault(baseURL: directory)

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("work-vault-measured-source-\(UUID().uuidString).bin")
        let payload = Data(repeating: 0x5A, count: 3_003)
        try payload.write(to: source, options: .atomic)
        defer { try? FileManager.default.removeItem(at: source) }

        let stored = try await vault.store(bytes: payload, suggestedExtension: "bin")
        let copied = try await vault.storeFile(at: source, suggestedExtension: "bin")
        let streamed = try await vault.storeFileStreaming(
            at: source,
            suggestedExtension: "bin",
            expectedByteCount: Int64(payload.count),
            onProgress: { _ in }
        )
        let duplicated = try await vault.copy(key: stored.key)

        for write in [stored, copied, streamed, duplicated] {
            let leaf = directory.appendingPathComponent(write.key, isDirectory: false)
            let attributes = try FileManager.default.attributesOfItem(atPath: leaf.path)
            let onDisk = try XCTUnwrap((attributes[.size] as? NSNumber)?.int64Value)

            XCTAssertEqual(
                write.byteCount, onDisk,
                "a row records what the leaf holds, so every lane must measure it"
            )
            XCTAssertEqual(write.byteCount, Int64(payload.count))
            let confirmed = await vault.confirmPublication(
                of: write.key,
                expectedByteCount: write.byteCount
            )
            XCTAssertTrue(confirmed, "the measured length is what confirmation compares against")
        }
    }

    func testInMemoryStoresUseIndependentVaults() async throws {
        let firstStore = isolated.make()
        let secondStore = isolated.make()
        let sharedMaterialID = UUID()
        let firstItem = try await firstStore.createWorkItem()
        let secondItem = try await secondStore.createWorkItem()

        let firstMaterial = try await firstStore.addWorkMaterial(
            WorkMaterialDraft(
                id: sharedMaterialID,
                kind: .file,
                filename: "same.txt",
                payload: Data("first store".utf8)
            ),
            to: firstItem.id
        )
        let secondMaterial = try await secondStore.addWorkMaterial(
            WorkMaterialDraft(
                id: sharedMaterialID,
                kind: .file,
                filename: "same.txt",
                payload: Data("second store".utf8)
            ),
            to: secondItem.id
        )

        let firstPayloadBeforeReconcile = try await firstStore.loadWorkMaterialPayload(
            id: firstMaterial.id
        )
        let secondPayloadBeforeReconcile = try await secondStore.loadWorkMaterialPayload(
            id: secondMaterial.id
        )
        let firstReclaimed = try await firstStore.reconcileWorkAssetVault()
        try await firstStore.deleteWorkMaterial(id: firstMaterial.id)
        let secondPayloadAfterFirstDelete = try await secondStore.loadWorkMaterialPayload(
            id: secondMaterial.id
        )

        XCTAssertEqual(firstPayloadBeforeReconcile, Data("first store".utf8))
        XCTAssertEqual(secondPayloadBeforeReconcile, Data("second store".utf8))
        XCTAssertEqual(firstReclaimed, 0)
        XCTAssertEqual(secondPayloadAfterFirstDelete, Data("second store".utf8))
    }

    func testFilePayloadsNeverEnterTheMirroredModel() async throws {
        let store = isolated.make()
        let item = try await store.createWorkItem()
        let large = try await store.addWorkMaterial(
            WorkMaterialDraft(
                kind: .file,
                filename: "large.bin",
                payload: Data(repeating: 0xAB, count: 1_024 * 1_024)
            ),
            to: item.id
        )
        let tiny = try await store.addWorkMaterial(
            WorkMaterialDraft(
                kind: .image,
                filename: "tiny.jpg",
                payload: Data([0xFF, 0xD8, 0xFF]),
                thumbnailData: Data([0x01, 0x02])
            ),
            to: item.id
        )

        XCTAssertEqual(large.storageMode, .localVault)
        XCTAssertEqual(tiny.storageMode, .localVault,
                       "size is not a lane: every payload is device-local")
        XCTAssertNil(tiny.thumbnailData,
                     "a thumbnail is file content and stays off the shared model")
    }

    func testVaultCopyDuplicatesBytesUnderAFreshKey() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("work-vault-copy-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = WorkAssetVault(baseURL: directory)

        let payload = Data("bytes to duplicate".utf8)
        let original = try await vault.store(bytes: payload, suggestedExtension: "txt").key
        await vault.confirmPublication(of: original)
        let copy = try await vault.copy(key: original)
        await vault.confirmPublication(of: copy.key)

        XCTAssertNotEqual(copy.key, original)
        XCTAssertEqual(copy.byteCount, Int64(payload.count))
        let copiedData = try await vault.data(for: copy.key)
        XCTAssertEqual(copiedData, payload)

        try await vault.remove(copy.key)
        let originalSurvives = try await vault.data(for: original)
        XCTAssertEqual(originalSurvives, payload)

        do {
            _ = try await vault.copy(key: WorkAssetVault.makeKey(id: UUID(), suggestedExtension: "txt"))
            XCTFail("Copying an absent key must fail rather than publish an empty leaf")
        } catch WorkAssetVault.VaultError.missing {
            // Expected.
        }
    }

    func testUnknownSizeFileStreamsLocallyAndPersistsObservedByteCount() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("work-vault-unknown-size-\(UUID().uuidString).txt")
        let payload = Data("size discovered while streaming".utf8)
        try payload.write(to: sourceURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let store = isolated.make()
        let item = try await store.createWorkItem()
        let material = try await store.addWorkMaterialFile(
            WorkMaterialDraft(
                kind: .file,
                title: "Unknown size",
                filename: sourceURL.lastPathComponent,
                mimeType: "text/plain"
            ),
            from: sourceURL,
            byteSize: -1,
            to: item.id
        )

        XCTAssertEqual(material.storageMode, .localVault)
        XCTAssertEqual(material.availability, .availableLocally)
        XCTAssertEqual(material.byteSize, Int64(payload.count))
        let loadedPayload = try await store.loadWorkMaterialPayload(id: material.id)
        XCTAssertEqual(loadedPayload, payload)
    }

    func testZeroByteFileStillUsesStreamingLocalVaultLane() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("work-vault-empty-\(UUID().uuidString).txt")
        try Data().write(to: sourceURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let store = isolated.make()
        let item = try await store.createWorkItem()
        let material = try await store.addWorkMaterialFile(
            WorkMaterialDraft(
                kind: .file,
                title: "Empty file",
                filename: sourceURL.lastPathComponent,
                mimeType: "text/plain"
            ),
            from: sourceURL,
            byteSize: 0,
            to: item.id
        )

        XCTAssertEqual(material.storageMode, .localVault)
        XCTAssertEqual(material.availability, .availableLocally)
        XCTAssertEqual(material.byteSize, 0)
        let loadedPayload = try await store.loadWorkMaterialPayload(id: material.id)
        XCTAssertEqual(loadedPayload, Data())
    }
}
