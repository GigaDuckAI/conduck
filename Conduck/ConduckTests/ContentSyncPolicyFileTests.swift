// SPDX-License-Identifier: Apache-2.0

// Exercises the production filesystem adapter in disposable directories, with
// isolated defaults/KVS. A failed UserDefaults flush must never hide readable
// policy, while a failed policy-file commit must never publish a new choice.

import XCTest
@testable import Conduck

final class ContentSyncPolicyFileTests: XCTestCase {
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func dependencies(
        directory: URL,
        defaults: InMemoryDefaultsStore = InMemoryDefaultsStore(synchronizationSucceeds: false),
        persistence: (any ContentSyncPolicyLock)? = nil
    ) -> SettingsDependencies {
        let base = SettingsDependencies.inMemory(defaults: defaults)
        return SettingsDependencies(defaults: base.defaults, ubiquitous: base.ubiquitous,
            secrets: base.secrets, cloudAvailability: base.cloudAvailability, changes: base.changes,
            contentSyncPolicyLock: persistence ?? ContentSyncPolicyFile(directoryURL: directory))
    }

    func testFreshDirectoryReadsDefaultWithoutPublishingOrSavingSynthesizedOn() throws {
        let url = directory()
        let deps = dependencies(directory: url)
        let store = ContentSyncPreferenceStore(dependencies: deps)
        XCTAssertTrue(try store.readEnabled())
        XCTAssertNil(store.currentPreference())
        XCTAssertTrue(deps.ubiquitous.dictionaryRepresentation().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("ContentSyncPreference.json").path))
    }

    func testFailedDefaultsFlushStillMigratesKnownOffAndAllowsExplicitChange() throws {
        let url = directory()
        let defaults = InMemoryDefaultsStore(synchronizationSucceeds: false)
        let off = ContentSyncPreference(enabled: false, revision: 7, identifier: UUID())
        defaults.set(try JSONEncoder().encode(off), forKey: ContentSyncPreferenceStore.storageKey)
        let store = ContentSyncPreferenceStore(dependencies: dependencies(directory: url, defaults: defaults))
        XCTAssertFalse(try store.readEnabled())

        // Independent defaults and KVS prove this came from the committed file.
        let reopened = ContentSyncPreferenceStore(dependencies: dependencies(directory: url))
        XCTAssertEqual(reopened.currentPreference(), off)
        let on = try reopened.setEnabled(true)
        XCTAssertEqual(store.currentPreference(), on)
    }

    func testFailedDefaultsFlushWithoutFileDependencyStillReadsCachedOff() throws {
        let defaults = InMemoryDefaultsStore(synchronizationSucceeds: false)
        let off = ContentSyncPreference(enabled: false, revision: 8, identifier: UUID())
        defaults.set(try JSONEncoder().encode(off), forKey: ContentSyncPreferenceStore.storageKey)
        let store = ContentSyncPreferenceStore(dependencies: .inMemory(defaults: defaults))
        XCTAssertFalse(try store.readEnabled())
    }

    func testExplicitOffSurvivesReopenAndRetriesPublicationWithoutDefaultsCache() throws {
        let url = directory()
        let first = ContentSyncPreferenceStore(dependencies: dependencies(directory: url))
        let off = try first.setEnabled(false)
        let secondDependencies = dependencies(directory: url)
        let second = ContentSyncPreferenceStore(dependencies: secondDependencies)
        XCTAssertEqual(second.currentPreference(), off)
        XCTAssertEqual(ContentSyncPreference.decode(secondDependencies.ubiquitous.data(
            forKey: ContentSyncPreferenceStore.storageKey)), off)
    }

    func testFileWinsOverAStaleDefaultsCache() throws {
        let url = directory()
        let first = ContentSyncPreferenceStore(dependencies: dependencies(directory: url))
        let off = try first.setEnabled(false)
        let stale = InMemoryDefaultsStore()
        stale.set(try JSONEncoder().encode(ContentSyncPreference(enabled: true,
            revision: off.revision + 1, identifier: UUID())), forKey: ContentSyncPreferenceStore.storageKey)
        let reopened = ContentSyncPreferenceStore(dependencies: dependencies(directory: url, defaults: stale))
        XCTAssertEqual(reopened.currentPreference(), off)
    }

    func testAtomicSnapshotReplacementDoesNotReplaceTheLockInode() throws {
        let url = directory()
        let first = ContentSyncPolicyFile(directoryURL: url)
        let second = ContentSyncPolicyFile(directoryURL: url)
        XCTAssertTrue(first.lock())
        XCTAssertFalse(second.lock())
        try first.writeSnapshot(Data("first".utf8))
        try first.writeSnapshot(Data("second".utf8))
        XCTAssertFalse(second.lock())
        first.unlock()
        XCTAssertTrue(second.lock())
        XCTAssertEqual(try second.readSnapshot(), Data("second".utf8))
        second.unlock()
    }

    func testCorruptSnapshotIsUnavailableAndCannotFallBackToDefaultOn() throws {
        let url = directory()
        let file = ContentSyncPolicyFile(directoryURL: url)
        XCTAssertTrue(file.lock())
        try file.writeSnapshot(Data("damaged".utf8))
        file.unlock()
        let deps = dependencies(directory: url)
        let store = ContentSyncPreferenceStore(dependencies: deps)
        XCTAssertThrowsError(try store.readEnabled())
        XCTAssertThrowsError(try store.setEnabled(true))
        XCTAssertTrue(deps.ubiquitous.dictionaryRepresentation().isEmpty)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("ContentSyncPreference.json")), Data("damaged".utf8))
    }

    func testSnapshotReadErrorIsNotTreatedAsAnAbsentPreference() throws {
        let url = directory()
        try FileManager.default.createDirectory(at: url.appendingPathComponent("ContentSyncPreference.json"), withIntermediateDirectories: true)
        let store = ContentSyncPreferenceStore(dependencies: dependencies(directory: url))
        XCTAssertThrowsError(try store.readEnabled())
    }

    func testFailedCommitCannotPublishOrCacheNewChoice() throws {
        let url = directory()
        let deps = dependencies(directory: url, persistence: RefusedCommit())
        let store = ContentSyncPreferenceStore(dependencies: deps)
        XCTAssertThrowsError(try store.setEnabled(false))
        XCTAssertTrue(deps.ubiquitous.dictionaryRepresentation().isEmpty)
        XCTAssertTrue(deps.defaults.dictionaryRepresentation().isEmpty)
    }

    private nonisolated struct RefusedCommit: ContentSyncPolicyPersistence {
        func lock() -> Bool { true }
        func unlock() {}
        func readSnapshot() throws -> Data? { nil }
        func writeSnapshot(_ data: Data) throws { throw CocoaError(.fileWriteNoPermission) }
    }
}
