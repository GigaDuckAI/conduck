// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkAssetVaultTests.swift
//
// Device-local Workboard asset containment and lifecycle contracts.

import Foundation
import CoreData
import XCTest
@testable import Conduck

final class WorkAssetVaultTests: XCTestCase {
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

        let keep = try await vault.store(Data("keep".utf8), suggestedExtension: "txt")
        let remove = try await vault.store(Data("remove".utf8), suggestedExtension: "txt")
        await vault.markReferenced(keep)
        await vault.markReferenced(remove)

        let loaded = try await vault.data(for: keep)
        let reclaimed = await vault.reclaimUnreferenced(keeping: [keep])
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
        let store = ConversationStore(inMemory: true)

        let keep = try await vault.store(Data("referenced".utf8), suggestedExtension: "txt")
        let remove = try await vault.store(Data("orphan".utf8), suggestedExtension: "txt")
        await vault.markReferenced(keep)
        await vault.markReferenced(remove)

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

        let key = try await vault.store(Data("in flight".utf8), suggestedExtension: "txt")
        let reclaimedWhileStaged = await vault.reclaimUnreferenced(keeping: [])
        let existsWhileStaged = await vault.contains(key)
        await vault.markReferenced(key)
        let reclaimedAfterPublication = await vault.reclaimUnreferenced(keeping: [])
        let existsAfterPublication = await vault.contains(key)

        XCTAssertEqual(reclaimedWhileStaged, 0)
        XCTAssertTrue(existsWhileStaged)
        XCTAssertEqual(reclaimedAfterPublication, 1)
        XCTAssertFalse(existsAfterPublication)
    }

    func testInMemoryStoresUseIndependentVaults() async throws {
        let firstStore = ConversationStore(inMemory: true)
        let secondStore = ConversationStore(inMemory: true)
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
        let store = ConversationStore(inMemory: true)
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
        let original = try await vault.store(payload, suggestedExtension: "txt")
        await vault.markReferenced(original)
        let copy = try await vault.copy(key: original)
        await vault.markReferenced(copy.key)

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

        let store = ConversationStore(inMemory: true)
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

        let store = ConversationStore(inMemory: true)
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
