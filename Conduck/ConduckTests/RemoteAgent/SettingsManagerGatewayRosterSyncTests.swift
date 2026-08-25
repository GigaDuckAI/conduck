// SPDX-License-Identifier: Apache-2.0

// Conduck
// SettingsManagerGatewayRosterSyncTests.swift
//
// Locks the custom-gateway ROSTER's inbound sync — the path that removes a
// Personal AI row on this device when a peer device Forgets the gateway.
// The roster travels over iCloud KVS while the token travels over iCloud
// Keychain, so a peer's Forget whose KVS half never lands leaves a stale row
// with no checkmark. Three inbound paths must all adopt a shrunken roster:
//
//   1. `handleICloudChange` — the live change notification (app running).
//   2. `performInitialSync` → `reconcileCustomGatewaysFromKVSCache` — cold
//      launch, UNGATED by `iCloudAvailable`: a delta `syncdefaultsd` applied
//      while the app was quit produces no notification at next launch, and a
//      nil ubiquity token (iCloud Drive off) must not disable the catch-up.
//   3. `catchUpSyncedRostersOnActivate` — foreground activation.
//
// And the reconcile must stay HYDRATE-ONLY: an absent KVS key is never a
// delete (signed-out no-wipe) and the local roster is never pushed up
// (resurrection bug). The write path must flag its KVS delta for upload
// (`synchronize()`) so the peers' rows come off promptly.
//
// Isolation: every case drives its own `SettingsManager(dependencies:
// .inMemory(...))` with fresh stores — nothing touches the shared singleton.

import XCTest
@testable import Conduck

final class SettingsManagerGatewayRosterSyncTests: XCTestCase {

    // Pinned literals, independently grepped from production source so a
    // rename of the constant breaks the test (same policy as
    // SettingsManagerICloudSyncTests).
    private let rosterKey = "remoteAgent.customGateways" // Constants.customGatewaysRegistryKey
    private let languageLocalKey = "preferred_language"  // Constants.preferredLanguageKey
    private let languageKVSKey = "stt.preferredLanguage" // Constants.sttPreferredLanguageKVSKey
    private let lastUsedKey = "remoteAgent.lastUsedBackend" // Constants.remoteAgentLastUsedBackendKey

    private let idA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private let idB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!

    private var gatewayA: CustomGateway { CustomGateway(id: idA, name: "Alpha") }
    private var gatewayB: CustomGateway { CustomGateway(id: idB, name: "Bravo") }

    private func encoded(_ list: [CustomGateway]) -> Data {
        try! JSONEncoder().encode(list)
    }

    /// Per-ref slot key literals for a custom uuid (lowercased, per
    /// `RemoteAgentRef.rawString`).
    private func urlKey(_ id: UUID) -> String { "remoteAgent.url.custom_\(id.uuidString.lowercased())" }
    private func authKey(_ id: UUID) -> String { "remoteAgent.authScheme.custom_\(id.uuidString.lowercased())" }
    private func modelKey(_ id: UUID) -> String { "remoteAgent.model.custom_\(id.uuidString.lowercased())" }

    private struct Rig {
        let manager: SettingsManager
        let defaults: InMemoryDefaultsStore
        let kvs: InMemoryUbiquitousStore
    }

    private func makeRig(cloudAvailable: Bool = false) -> Rig {
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()
        let manager = SettingsManager(dependencies: .inMemory(
            defaults: defaults,
            ubiquitous: kvs,
            cloudAvailable: cloudAvailable
        ))
        return Rig(manager: manager, defaults: defaults, kvs: kvs)
    }

    // MARK: - Live change notification (path 1)

    func testServerChangeRosterShrinkRemovesRowAndRetiresBadge() async {
        let rig = makeRig()
        rig.defaults.set(encoded([gatewayA, gatewayB]), forKey: rosterKey)
        rig.kvs.set(encoded([gatewayA]), forKey: rosterKey)

        await rig.manager.handleICloudChange(
            KVSChange(reason: .serverChange, changedKeys: [rosterKey])
        )

        let roster = await rig.manager.customGateways()
        XCTAssertEqual(roster.map(\.id), [idA], "peer's Forget of B must remove B's row")
        let badges = await rig.manager.retiredGatewayBadges()
        XCTAssertTrue(badges.contains { $0.id == idB }, "vanished B keeps its badge tombstone")
        XCTAssertFalse(badges.contains { $0.id == idA }, "surviving A must not be retired")
    }

    func testServerChangeEmptyRosterRemovesLastRow() async {
        let rig = makeRig()
        rig.defaults.set(encoded([gatewayA]), forKey: rosterKey)
        rig.kvs.set(encoded([CustomGateway]()), forKey: rosterKey)

        await rig.manager.handleICloudChange(
            KVSChange(reason: .serverChange, changedKeys: [rosterKey])
        )

        let roster = await rig.manager.customGateways()
        XCTAssertTrue(roster.isEmpty, "delete-last arrives as PRESENT [] data and must clear the roster")
        let badges = await rig.manager.retiredGatewayBadges()
        XCTAssertTrue(badges.contains { $0.id == idA })
    }

    // MARK: - Cold-launch catch-up (path 2) — THE regression tests for the
    // stale-row-on-the-Mac bug: the notification was missed while quit, and
    // `iCloudAvailable` is false (nil ubiquity token), yet launch must adopt
    // the KVS cache the system applied silently.

    func testInitialSyncCloudUnavailableAdoptsShrunkenRoster() async {
        let rig = makeRig(cloudAvailable: false)
        rig.defaults.set(encoded([gatewayA, gatewayB]), forKey: rosterKey)
        rig.kvs.set(encoded([gatewayA]), forKey: rosterKey)

        await rig.manager.performInitialSync()

        let roster = await rig.manager.customGateways()
        XCTAssertEqual(roster.map(\.id), [idA],
                       "launch reconcile must run without an iCloud account signal")
        let badges = await rig.manager.retiredGatewayBadges()
        XCTAssertTrue(badges.contains { $0.id == idB })
    }

    func testInitialSyncCloudUnavailableEmptyKVSRosterClearsLocal() async {
        let rig = makeRig(cloudAvailable: false)
        rig.defaults.set(encoded([gatewayA]), forKey: rosterKey)
        rig.kvs.set(encoded([CustomGateway]()), forKey: rosterKey)

        await rig.manager.performInitialSync()

        let roster = await rig.manager.customGateways()
        XCTAssertTrue(roster.isEmpty, "peer's delete-last must land at launch too")
    }

    func testInitialSyncAbsentKVSRosterKeyPreservesLocalAndDoesNotPushUp() async {
        let rig = makeRig(cloudAvailable: false)
        rig.defaults.set(encoded([gatewayA]), forKey: rosterKey)
        // KVS roster key deliberately absent (signed out / never downloaded).

        await rig.manager.performInitialSync()

        let roster = await rig.manager.customGateways()
        XCTAssertEqual(roster.map(\.id), [idA],
                       "an absent KVS key is NOT evidence of a delete — no wipe")
        XCTAssertNil(rig.kvs.data(forKey: rosterKey),
                     "the reconcile must never publish the local roster upward (resurrection bug)")
    }

    func testInitialSyncCloudUnavailableHydratesPerRefGatewaySlots() async {
        let rig = makeRig(cloudAvailable: false)
        rig.kvs.set(encoded([gatewayA]), forKey: rosterKey)
        rig.kvs.set("https://gw.example.com", forKey: urlKey(idA))
        rig.kvs.set("bearer", forKey: authKey(idA))
        rig.kvs.set("luna-mini", forKey: modelKey(idA))

        await rig.manager.performInitialSync()

        XCTAssertEqual(rig.defaults.string(forKey: urlKey(idA)), "https://gw.example.com")
        XCTAssertEqual(rig.defaults.string(forKey: authKey(idA)), "bearer")
        XCTAssertEqual(rig.defaults.string(forKey: modelKey(idA)), "luna-mini")
    }

    func testInitialSyncChangedRosterPostsExactlyOnce() async {
        let rig = makeRig(cloudAvailable: false)
        rig.defaults.set(encoded([gatewayA, gatewayB]), forKey: rosterKey)
        rig.kvs.set(encoded([gatewayA]), forKey: rosterKey)

        let counter = NotificationCounter(name: .settingsDidChangeRemotely)

        // A view model that loaded the STALE roster before this launch task ran
        // has no other way to hear about the adoption — the activation catch-up
        // finds the stores already agreeing and stays quiet.
        await rig.manager.performInitialSync()
        // A second, no-op launch sync must stay silent.
        await rig.manager.performInitialSync()

        await MainActor.run {}
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(counter.count, 1)
        counter.cancel()
    }

    func testInitialSyncMalformedKVSRosterPreservesLocal() async {
        let rig = makeRig(cloudAvailable: false)
        rig.defaults.set(encoded([gatewayA]), forKey: rosterKey)
        rig.kvs.set(Data("not json".utf8), forKey: rosterKey)

        await rig.manager.performInitialSync()

        let roster = await rig.manager.customGateways()
        XCTAssertEqual(roster.map(\.id), [idA],
                       "undecodable KVS bytes are 'unknown', never an overwrite — both reads failing open to [] would retire every gateway")
        let badges = await rig.manager.retiredGatewayBadges()
        XCTAssertTrue(badges.isEmpty, "nothing vanished, nothing may be retired")
    }

    func testServerChangeWrongTypedRosterValuePreservesLocal() async {
        let rig = makeRig()
        rig.defaults.set(encoded([gatewayA]), forKey: rosterKey)
        // A future schema could store a non-Data value under the roster key.
        // `data(forKey:)` returns nil for it — which must read as UNKNOWN,
        // never as "key absent = peer deleted everything".
        rig.kvs.set("future-schema", forKey: rosterKey)

        await rig.manager.handleICloudChange(
            KVSChange(reason: .serverChange, changedKeys: [rosterKey])
        )

        let roster = await rig.manager.customGateways()
        XCTAssertEqual(roster.map(\.id), [idA],
                       "a present-but-wrong-typed KVS value must not enter the deletion branch")
        let badges = await rig.manager.retiredGatewayBadges()
        XCTAssertTrue(badges.isEmpty)
    }

    func testServerChangeMalformedRosterPreservesLocal() async {
        let rig = makeRig()
        rig.defaults.set(encoded([gatewayA]), forKey: rosterKey)
        rig.kvs.set(Data("not json".utf8), forKey: rosterKey)

        await rig.manager.handleICloudChange(
            KVSChange(reason: .serverChange, changedKeys: [rosterKey])
        )

        let roster = await rig.manager.customGateways()
        XCTAssertEqual(roster.map(\.id), [idA])
        let badges = await rig.manager.retiredGatewayBadges()
        XCTAssertTrue(badges.isEmpty)
    }

    func testInitialSyncCloudUnavailableDoesNotRunPushUpArms() async {
        let rig = makeRig(cloudAvailable: false)
        rig.defaults.set("de-DE", forKey: languageLocalKey)

        await rig.manager.performInitialSync()

        XCTAssertNil(rig.kvs.string(forKey: languageKVSKey),
                     "everything push-up-bearing stays behind the iCloudAvailable guard")
    }

    // MARK: - Activation / live-handler overlap (both orders)

    func testActivationThenServerChangeStillClearsLastUsedPointer() async {
        let rig = makeRig()
        rig.defaults.set(encoded([gatewayA, gatewayB]), forKey: rosterKey)
        rig.defaults.set("custom_\(idB.uuidString.lowercased())", forKey: lastUsedKey)
        rig.kvs.set(encoded([gatewayA]), forKey: rosterKey)

        // Activation adopts the shrink FIRST — a guess, so the pointer stays.
        await rig.manager.catchUpSyncedRostersOnActivate()
        XCTAssertNotNil(rig.defaults.string(forKey: lastUsedKey),
                        "activation alone must retain the pointer (ignore-but-retain)")

        // The queued confirmed notification lands after: the roster transition
        // is gone by now, but the confirmation still authorizes the clear.
        await rig.manager.handleICloudChange(
            KVSChange(reason: .serverChange, changedKeys: [rosterKey])
        )
        XCTAssertNil(rig.defaults.string(forKey: lastUsedKey),
                     "a confirmed serverChange shrink must clear the pointer even when activation adopted the bytes first")
    }

    func testServerChangeThenActivationClearsPointerAndPostsOnce() async {
        let rig = makeRig()
        rig.defaults.set(encoded([gatewayA, gatewayB]), forKey: rosterKey)
        rig.defaults.set("custom_\(idB.uuidString.lowercased())", forKey: lastUsedKey)
        rig.kvs.set(encoded([gatewayA]), forKey: rosterKey)

        let counter = NotificationCounter(name: .settingsDidChangeRemotely)

        await rig.manager.handleICloudChange(
            KVSChange(reason: .serverChange, changedKeys: [rosterKey])
        )
        await rig.manager.catchUpSyncedRostersOnActivate()

        await MainActor.run {}
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(rig.defaults.string(forKey: lastUsedKey))
        XCTAssertEqual(counter.count, 1,
                       "the activation pass after the live handler already adopted must stay silent")
        counter.cancel()
    }

    // MARK: - Write path flags its delta for upload

    func testUpsertAndDeleteFlushKVS() async {
        let rig = makeRig()
        let baseline = rig.kvs.synchronizeCallCount

        _ = await rig.manager.upsertCustomGateway(gatewayA)
        let afterUpsert = rig.kvs.synchronizeCallCount
        XCTAssertGreaterThan(afterUpsert, baseline, "upsert must flag its KVS write for upload")

        rig.kvs.set("https://gw.example.com", forKey: urlKey(idA))
        await rig.manager.deleteCustomGateway(id: idA)
        XCTAssertGreaterThan(rig.kvs.synchronizeCallCount, afterUpsert,
                             "delete must flag its KVS removals for upload")

        // The FINAL flush must cover the whole delete — a count alone would
        // still pass if only the mid-operation roster flush survived and the
        // later per-uuid removals stayed dirty.
        let snapshot = rig.kvs.lastSynchronizedSnapshot ?? [:]
        let snapshotRoster = (snapshot[rosterKey] as? Data)
            .flatMap { try? JSONDecoder().decode([CustomGateway].self, from: $0) }
        XCTAssertEqual(snapshotRoster, [],
                       "the last flush must see the shrunken (empty) roster")
        XCTAssertNil(snapshot[urlKey(idA)],
                     "the last flush must run after the per-uuid slot removals")
    }

    func testCatchUpOnActivateSlotOnlyChangePosts() async {
        let rig = makeRig()
        // Roster identical in both stores; the peer edited ONLY the URL.
        rig.defaults.set(encoded([gatewayA]), forKey: rosterKey)
        rig.kvs.set(encoded([gatewayA]), forKey: rosterKey)
        rig.defaults.set("https://old.example.com", forKey: urlKey(idA))
        rig.kvs.set("https://new.example.com", forKey: urlKey(idA))

        let counter = NotificationCounter(name: .settingsDidChangeRemotely)

        await rig.manager.catchUpSyncedRostersOnActivate()
        // Second pass: stores agree now — must stay silent.
        await rig.manager.catchUpSyncedRostersOnActivate()

        await MainActor.run {}
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(rig.defaults.string(forKey: urlKey(idA)), "https://new.example.com")
        XCTAssertEqual(counter.count, 1,
                       "a slot-only edit is a visible change — open Settings screens must hear about it, but a quiet pass must not broadcast")
        counter.cancel()
    }

    // MARK: - Foreground activation catch-up (path 3)

    func testCatchUpOnActivatePostsChangeOnlyWhenRosterChanged() async {
        let rig = makeRig()
        rig.defaults.set(encoded([gatewayA, gatewayB]), forKey: rosterKey)
        rig.kvs.set(encoded([gatewayA]), forKey: rosterKey)

        let counter = NotificationCounter(name: .settingsDidChangeRemotely)

        await rig.manager.catchUpSyncedRostersOnActivate()
        // Second activation with an unchanged cache must stay silent — the post
        // wakes a token-bearing Watch broadcast and must not fire every activation.
        await rig.manager.catchUpSyncedRostersOnActivate()

        // The post lands via the main queue; drain it before counting.
        await MainActor.run {}
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(counter.count, 1)
        let roster = await rig.manager.customGateways()
        XCTAssertEqual(roster.map(\.id), [idA])
        counter.cancel()
    }
}

/// Main-thread-safe notification tally.
private final class NotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var observed = 0
    private var token: NSObjectProtocol?

    init(name: Notification.Name) {
        token = NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.observed += 1
            self.lock.unlock()
        }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return observed
    }

    func cancel() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }
}
