// SPDX-License-Identifier: Apache-2.0

// Exercises the real preference reconciler with isolated storage, including
// absent/late KVS, reordered Watch delivery, and explicit-write recovery.

import XCTest
@testable import Conduck

final class ContentSyncPreferenceTests: XCTestCase {
    private func preference(_ enabled: Bool, revision: Int64) -> ContentSyncPreference {
        ContentSyncPreference(enabled: enabled, revision: revision, identifier: UUID())
    }

    func testAbsentDefaultsOnWithoutPublishingAnything() {
        let deps = SettingsDependencies.inMemory()
        let store = ContentSyncPreferenceStore(dependencies: deps)
        XCTAssertTrue(store.isEnabled)
        XCTAssertNil(store.currentPreference())
        XCTAssertTrue(deps.defaults.dictionaryRepresentation().isEmpty)
        XCTAssertTrue(deps.ubiquitous.dictionaryRepresentation().isEmpty)
    }

    func testCachedCloudOffLoadsEvenWhenDriveUnavailable() throws {
        let deps = SettingsDependencies.inMemory(cloudAvailable: false)
        let off = preference(false, revision: 7)
        deps.ubiquitous.set(try JSONEncoder().encode(off), forKey: ContentSyncPreferenceStore.storageKey)
        let store = ContentSyncPreferenceStore(dependencies: deps)
        XCTAssertFalse(store.isEnabled)
        XCTAssertEqual(ContentSyncPreference.decode(deps.defaults.data(forKey: ContentSyncPreferenceStore.storageKey)), off)
    }

    func testExplicitChoicePersistsLocallyAndPublishesWhileDriveUnavailable() throws {
        let deps = SettingsDependencies.inMemory(cloudAvailable: false)
        let store = ContentSyncPreferenceStore(dependencies: deps)
        let off = try store.setEnabled(false)
        XCTAssertEqual(store.currentPreference(), off)
        XCTAssertEqual(ContentSyncPreference.decode(deps.ubiquitous.data(forKey: ContentSyncPreferenceStore.storageKey)), off)
        XCTAssertFalse(ContentSyncPreferenceStore(dependencies: deps).isEnabled)
    }

    func testAbsentAndMalformedCloudNeverEraseKnownOff() throws {
        let deps = SettingsDependencies.inMemory()
        let off = preference(false, revision: 10)
        deps.defaults.set(try JSONEncoder().encode(off), forKey: ContentSyncPreferenceStore.storageKey)
        let store = ContentSyncPreferenceStore(dependencies: deps)
        XCTAssertFalse(store.isEnabled)
        deps.ubiquitous.set(Data("malformed".utf8), forKey: ContentSyncPreferenceStore.storageKey)
        XCTAssertFalse(store.isEnabled)
        XCTAssertEqual(store.currentPreference(), off)
    }

    func testStalePhoneOnCannotReplaceNewerOff() {
        let store = ContentSyncPreferenceStore(dependencies: .inMemory())
        XCTAssertTrue(store.adopt(preference(false, revision: 20)))
        XCTAssertFalse(store.adopt(preference(true, revision: 19)))
        XCTAssertFalse(store.isEnabled)
    }

    func testEqualRevisionOffWinsRegardlessOfTransportOrder() {
        let on = preference(true, revision: 30)
        let off = preference(false, revision: 30)
        for sequence in [[on, off], [off, on]] {
            let store = ContentSyncPreferenceStore(dependencies: .inMemory())
            for value in sequence { _ = store.adopt(value) }
            XCTAssertEqual(store.currentPreference(), off)
        }
    }

    func testNewerExplicitEnableIsAdoptedAndInboundIsNotRepublished() {
        let deps = SettingsDependencies.inMemory()
        let store = ContentSyncPreferenceStore(dependencies: deps)
        XCTAssertTrue(store.adopt(preference(false, revision: 1)))
        XCTAssertTrue(store.adopt(preference(true, revision: 2)))
        XCTAssertTrue(store.isEnabled)
        XCTAssertTrue(deps.ubiquitous.dictionaryRepresentation().isEmpty)
    }

    func testLateInitialSyncDoesNotLosePendingExplicitOff() throws {
        let deps = SettingsDependencies.inMemory()
        let store = ContentSyncPreferenceStore(dependencies: deps)
        let off = try store.setEnabled(false)
        deps.ubiquitous.set(try JSONEncoder().encode(preference(true, revision: 1)), forKey: ContentSyncPreferenceStore.storageKey)
        XCTAssertFalse(store.isEnabled)
        XCTAssertEqual(ContentSyncPreference.decode(deps.ubiquitous.data(forKey: ContentSyncPreferenceStore.storageKey)), off)
    }

    func testRemoteNewerChoiceRetiresOldPendingPublication() throws {
        let deps = SettingsDependencies.inMemory()
        let store = ContentSyncPreferenceStore(dependencies: deps)
        let off = try store.setEnabled(false)
        let on = preference(true, revision: off.revision + 1)
        deps.ubiquitous.set(try JSONEncoder().encode(on), forKey: ContentSyncPreferenceStore.storageKey)
        XCTAssertTrue(store.isEnabled)
        deps.ubiquitous.removeObject(forKey: ContentSyncPreferenceStore.storageKey)
        XCTAssertTrue(store.isEnabled)
        XCTAssertNil(deps.ubiquitous.data(forKey: ContentSyncPreferenceStore.storageKey))
    }

    func testRapidExplicitChoicesAlwaysAdvanceRevision() throws {
        let store = ContentSyncPreferenceStore(dependencies: .inMemory())
        let first = try store.setEnabled(false)
        let second = try store.setEnabled(true)
        let third = try store.setEnabled(false)
        XCTAssertGreaterThan(second.revision, first.revision)
        XCTAssertGreaterThan(third.revision, second.revision)
        XCTAssertEqual(store.currentPreference(), third)
    }

    func testUnknownSchemaAndNegativeRevisionAreRefused() {
        let store = ContentSyncPreferenceStore(dependencies: .inMemory())
        XCTAssertTrue(store.adopt(preference(false, revision: 10)))
        var future = preference(true, revision: 20)
        future.schemaVersion = 2
        XCTAssertFalse(store.adopt(future))
        XCTAssertFalse(store.adopt(preference(true, revision: -1)))
        XCTAssertFalse(store.isEnabled)
    }

    func testFailedPolicyLockCannotEnableOrPublish() {
        let base = SettingsDependencies.inMemory()
        let deps = SettingsDependencies(defaults: base.defaults, ubiquitous: base.ubiquitous,
            secrets: base.secrets, cloudAvailability: base.cloudAvailability, changes: base.changes,
            contentSyncPolicyLock: RefusedLock())
        let store = ContentSyncPreferenceStore(dependencies: deps)
        XCTAssertFalse(store.isEnabled)
        XCTAssertThrowsError(try store.setEnabled(true))
        XCTAssertTrue(deps.defaults.dictionaryRepresentation().isEmpty)
        XCTAssertTrue(deps.ubiquitous.dictionaryRepresentation().isEmpty)
    }

    func testPreferenceDoesNotChangeExistingSettingsOrCredentials() throws {
        let deps = SettingsDependencies.inMemory()
        deps.ubiquitous.set("de", forKey: "stt.preferredLanguage")
        deps.defaults.set("local", forKey: "remoteAgent.sessionPolicy")
        let store = ContentSyncPreferenceStore(dependencies: deps)
        _ = try store.setEnabled(false)
        XCTAssertEqual(deps.ubiquitous.string(forKey: "stt.preferredLanguage"), "de")
        XCTAssertEqual(deps.defaults.string(forKey: "remoteAgent.sessionPolicy"), "local")
    }

    private nonisolated struct RefusedLock: ContentSyncPolicyLock {
        func lock() -> Bool { false }
        func unlock() { XCTFail("An unacquired lock must not be released") }
    }
}
