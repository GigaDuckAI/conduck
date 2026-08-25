// SPDX-License-Identifier: Apache-2.0

// Conduck
// SettingsManagerVoiceEndpointRosterSyncTests.swift
//
// Locks the custom VOICE-ENDPOINT roster's inbound sync — the path that removes
// a BYO STT/TTS row on this device when a peer device deletes the endpoint.
// Twin of `SettingsManagerGatewayRosterSyncTests`; the two rosters travel the
// same way and failed the same way. Three inbound paths must all adopt a
// shrunken roster:
//
//   1. `handleICloudChange` — the live change notification (app running).
//   2. `performInitialSync` → `reconcileCustomVoiceEndpointsFromKVSCache` —
//      cold launch, UNGATED by `iCloudAvailable`: a delta `syncdefaultsd`
//      applied while the app was quit produces no notification at next launch,
//      and a nil ubiquity token (iCloud Drive off) must not disable the
//      catch-up.
//   3. `catchUpSyncedRostersOnActivate` — foreground activation.
//
// And the reconcile must stay HYDRATE-ONLY: an absent KVS key is never a delete
// (signed-out no-wipe) and neither the roster nor a per-uuid slot is ever
// pushed up (resurrection bug — this path used to push, unlike the gateway
// twin). The write path must flag its KVS delta for upload (`synchronize()`).
//
// One thing the gateway twin does not need: a CONFIRMED peer delete has to
// retire this device's active STT/TTS pointers. `getActivePresetID()` returns
// the local value verbatim and `getActiveTTSProviderID()` gates neither arm, so
// a pointer left naming a deleted endpoint keeps resolving — and voice
// endpoints carry no badge record, so the pointer fallback is the only repair.
//
// Isolation: every case drives its own `SettingsManager(dependencies:
// .inMemory(...))` with fresh stores — nothing touches the shared singleton
// (unlike the older `CustomVoiceEndpoint*Tests`, which suspend iCloud instead).

import XCTest
@testable import Conduck

final class SettingsManagerVoiceEndpointRosterSyncTests: XCTestCase {

    // Pinned literals, independently grepped from production source so a
    // rename of the constant breaks the test (same policy as the gateway twin).
    private let rosterKey = "stt.customVoiceEndpoints"   // Constants.customVoiceEndpointsRegistryKey
    private let sttActiveKey = "stt.activePresetID"      // Constants.sttActivePresetIDKVSKey
    private let ttsActiveKey = "tts.activeProviderID"    // Constants.ttsActiveProviderIDKVSKey
    private let appleSTT = "apple-on-device"             // Constants.sttActivePresetIDDefault
    private let appleTTS = "apple-tts"                   // Constants.ttsActiveProviderIDDefault
    private let languageLocalKey = "preferred_language"  // Constants.preferredLanguageKey
    private let languageKVSKey = "stt.preferredLanguage" // Constants.sttPreferredLanguageKVSKey

    // Migration latches, pre-seeded so no case reaches the real Keychain: every
    // roster read runs `ensureCustomVoiceEndpointMigrated()`, which chains into
    // `ensureKeychainMigrated()`. Both short-circuit on their durable flag.
    private let voiceMigratedKey = "customVoiceEndpointMigrated" // Constants.customVoiceEndpointMigratedKey
    private let keychainMigratedKey = "keychainSyncMigrated"     // Constants.keychainSyncMigratedKey

    private let idA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-00000000000A")!
    private let idB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-00000000000B")!

    private var endpointA: CustomVoiceEndpoint { CustomVoiceEndpoint(id: idA, name: "Whisper box") }
    private var endpointB: CustomVoiceEndpoint { CustomVoiceEndpoint(id: idB, name: "Deepgram box") }

    private func encoded(_ list: [CustomVoiceEndpoint]) -> Data {
        try! JSONEncoder().encode(list)
    }

    /// Per-uuid slot key literals (lowercased uuid, BARE — no `custom_`
    /// prefix, unlike the gateway families).
    private func urlKey(_ id: UUID) -> String { "stt.custom.url.\(id.uuidString.lowercased())" }
    private func sttModelKey(_ id: UUID) -> String { "stt.custom.model.\(id.uuidString.lowercased())" }
    private func authKey(_ id: UUID) -> String { "stt.custom.authScheme.\(id.uuidString.lowercased())" }
    private func ttsModelKey(_ id: UUID) -> String { "tts.custom.model.\(id.uuidString.lowercased())" }

    /// Synthesized provider ids for an endpoint uuid.
    private func sttPresetID(_ id: UUID) -> String { "custom-openai_\(id.uuidString.lowercased())" }
    private func ttsProviderID(_ id: UUID) -> String { "custom-openai-tts_\(id.uuidString.lowercased())" }

    private struct Rig {
        let manager: SettingsManager
        let defaults: InMemoryDefaultsStore
        let kvs: InMemoryUbiquitousStore
    }

    private func makeRig(cloudAvailable: Bool = false) -> Rig {
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()
        defaults.set(true, forKey: voiceMigratedKey)
        defaults.set(true, forKey: keychainMigratedKey)
        let manager = SettingsManager(dependencies: .inMemory(
            defaults: defaults,
            ubiquitous: kvs,
            cloudAvailable: cloudAvailable
        ))
        return Rig(manager: manager, defaults: defaults, kvs: kvs)
    }

    // MARK: - Live change notification (path 1)

    func testServerChangeRosterShrinkRemovesRow() async {
        let rig = makeRig()
        rig.defaults.set(encoded([endpointA, endpointB]), forKey: rosterKey)
        rig.kvs.set(encoded([endpointA]), forKey: rosterKey)

        await rig.manager.handleICloudChange(
            KVSChange(reason: .serverChange, changedKeys: [rosterKey])
        )

        let roster = await rig.manager.customVoiceEndpoints()
        XCTAssertEqual(roster.map(\.id), [idA], "peer's delete of B must remove B's row")
    }

    func testServerChangeEmptyRosterRemovesLastRow() async {
        let rig = makeRig()
        rig.defaults.set(encoded([endpointA]), forKey: rosterKey)
        rig.kvs.set(encoded([CustomVoiceEndpoint]()), forKey: rosterKey)

        await rig.manager.handleICloudChange(
            KVSChange(reason: .serverChange, changedKeys: [rosterKey])
        )

        let roster = await rig.manager.customVoiceEndpoints()
        XCTAssertTrue(roster.isEmpty, "delete-last arrives as PRESENT [] data and must clear the roster")
    }

    func testServerChangeMalformedRosterPreservesLocal() async {
        let rig = makeRig()
        rig.defaults.set(encoded([endpointA]), forKey: rosterKey)
        rig.kvs.set(Data("not json".utf8), forKey: rosterKey)

        await rig.manager.handleICloudChange(
            KVSChange(reason: .serverChange, changedKeys: [rosterKey])
        )

        let roster = await rig.manager.customVoiceEndpoints()
        XCTAssertEqual(roster.map(\.id), [idA],
                       "undecodable KVS bytes are 'unknown', never an overwrite")
    }

    func testServerChangeWrongTypedRosterValuePreservesLocal() async {
        let rig = makeRig()
        rig.defaults.set(encoded([endpointA]), forKey: rosterKey)
        // A future schema could store a non-Data value under the roster key.
        // `data(forKey:)` returns nil for it — which must read as UNKNOWN,
        // never as "key absent = peer deleted everything".
        rig.kvs.set("future-schema", forKey: rosterKey)

        await rig.manager.handleICloudChange(
            KVSChange(reason: .serverChange, changedKeys: [rosterKey])
        )

        let roster = await rig.manager.customVoiceEndpoints()
        XCTAssertEqual(roster.map(\.id), [idA],
                       "a present-but-wrong-typed KVS value must not enter the deletion branch")
    }

    // MARK: - Active-pointer retirement on a CONFIRMED peer delete

    func testServerChangeRemoteDeleteRetiresActiveSTTAndTTSPointers() async {
        let rig = makeRig()
        rig.defaults.set(encoded([endpointA, endpointB]), forKey: rosterKey)
        rig.defaults.set(sttPresetID(idB), forKey: sttActiveKey)
        rig.defaults.set(ttsProviderID(idB), forKey: ttsActiveKey)
        rig.kvs.set(encoded([endpointA]), forKey: rosterKey)

        await rig.manager.handleICloudChange(
            KVSChange(reason: .serverChange, changedKeys: [rosterKey])
        )

        let stt = await rig.manager.getActivePresetID()
        let tts = await rig.manager.getActiveTTSProviderID()
        XCTAssertEqual(stt, appleSTT,
                       "a dangling STT pointer keeps resolving — activeSTTSnapshot() is roster-blind and would POST audio to the deleted endpoint")
        XCTAssertEqual(tts, appleTTS,
                       "getActiveTTSProviderID() gates neither arm, so the dead id must be retired here")
    }

    func testServerChangeRemoteDeleteLeavesSurvivingEndpointPointersAlone() async {
        let rig = makeRig()
        rig.defaults.set(encoded([endpointA, endpointB]), forKey: rosterKey)
        rig.defaults.set(sttPresetID(idA), forKey: sttActiveKey)
        rig.defaults.set(ttsProviderID(idA), forKey: ttsActiveKey)
        rig.kvs.set(encoded([endpointA]), forKey: rosterKey)

        await rig.manager.handleICloudChange(
            KVSChange(reason: .serverChange, changedKeys: [rosterKey])
        )

        let stt = await rig.manager.getActivePresetID()
        let tts = await rig.manager.getActiveTTSProviderID()
        XCTAssertEqual(stt, sttPresetID(idA), "A survived — its pointer must stand")
        XCTAssertEqual(tts, ttsProviderID(idA))
    }

    func testActivationAloneDoesNotRetireActivePointers() async {
        let rig = makeRig()
        rig.defaults.set(encoded([endpointA, endpointB]), forKey: rosterKey)
        rig.defaults.set(sttPresetID(idB), forKey: sttActiveKey)
        rig.kvs.set(encoded([endpointA]), forKey: rosterKey)

        await rig.manager.catchUpSyncedRostersOnActivate()

        let stt = await rig.manager.getActivePresetID()
        XCTAssertEqual(stt, sttPresetID(idB),
                       "activation adopts a roster GUESS — only a confirmed .serverChange may retire a pointer")
    }

    // MARK: - Cold-launch catch-up (path 2) — THE regression tests: the
    // notification was missed while quit, and `iCloudAvailable` is false (nil
    // ubiquity token), yet launch must adopt the KVS cache applied silently.

    func testInitialSyncCloudUnavailableAdoptsShrunkenRoster() async {
        let rig = makeRig(cloudAvailable: false)
        rig.defaults.set(encoded([endpointA, endpointB]), forKey: rosterKey)
        rig.kvs.set(encoded([endpointA]), forKey: rosterKey)

        await rig.manager.performInitialSync()

        let roster = await rig.manager.customVoiceEndpoints()
        XCTAssertEqual(roster.map(\.id), [idA],
                       "launch reconcile must run without an iCloud account signal")
    }

    func testInitialSyncCloudUnavailableEmptyKVSRosterClearsLocal() async {
        let rig = makeRig(cloudAvailable: false)
        rig.defaults.set(encoded([endpointA]), forKey: rosterKey)
        rig.kvs.set(encoded([CustomVoiceEndpoint]()), forKey: rosterKey)

        await rig.manager.performInitialSync()

        let roster = await rig.manager.customVoiceEndpoints()
        XCTAssertTrue(roster.isEmpty, "peer's delete-last must land at launch too")
    }

    func testInitialSyncAbsentKVSRosterKeyPreservesLocalAndDoesNotPushUp() async {
        let rig = makeRig(cloudAvailable: false)
        rig.defaults.set(encoded([endpointA]), forKey: rosterKey)
        // KVS roster key deliberately absent (signed out / never downloaded).

        await rig.manager.performInitialSync()

        let roster = await rig.manager.customVoiceEndpoints()
        XCTAssertEqual(roster.map(\.id), [idA],
                       "an absent KVS key is NOT evidence of a delete — no wipe")
        XCTAssertNil(rig.kvs.data(forKey: rosterKey),
                     "the reconcile must never publish the local roster upward (resurrection bug)")
    }

    func testInitialSyncCloudUnavailableHydratesPerUUIDSlots() async {
        let rig = makeRig(cloudAvailable: false)
        rig.kvs.set(encoded([endpointA]), forKey: rosterKey)
        rig.kvs.set("https://voice.example.com", forKey: urlKey(idA))
        rig.kvs.set("whisper-large", forKey: sttModelKey(idA))
        rig.kvs.set("bearer", forKey: authKey(idA))
        rig.kvs.set("tts-1-hd", forKey: ttsModelKey(idA))

        await rig.manager.performInitialSync()

        XCTAssertEqual(rig.defaults.string(forKey: urlKey(idA)), "https://voice.example.com")
        XCTAssertEqual(rig.defaults.string(forKey: sttModelKey(idA)), "whisper-large")
        XCTAssertEqual(rig.defaults.string(forKey: authKey(idA)), "bearer")
        XCTAssertEqual(rig.defaults.string(forKey: ttsModelKey(idA)), "tts-1-hd")
    }

    func testInitialSyncNeverPushesPerUUIDSlotsUpEvenWithCloudAvailable() async {
        // This block USED to be iCloud-wins-then-PUSH. A device whose KVS cache
        // had not downloaded yet would republish its stale roster and slots,
        // resurrecting an endpoint a peer deleted. Lock the removal at the
        // strongest setting — an account IS present here.
        let rig = makeRig(cloudAvailable: true)
        rig.defaults.set(encoded([endpointA]), forKey: rosterKey)
        rig.defaults.set("https://local-only.example.com", forKey: urlKey(idA))
        rig.defaults.set("whisper-1", forKey: sttModelKey(idA))

        await rig.manager.performInitialSync()

        XCTAssertNil(rig.kvs.data(forKey: rosterKey),
                     "the roster must never be published upward from a launch pass")
        XCTAssertNil(rig.kvs.string(forKey: urlKey(idA)),
                     "nor may a per-uuid slot be — that is how a deleted endpoint's URL comes back")
        XCTAssertNil(rig.kvs.string(forKey: sttModelKey(idA)))
    }

    func testInitialSyncChangedRosterPostsExactlyOnce() async {
        let rig = makeRig(cloudAvailable: false)
        rig.defaults.set(encoded([endpointA, endpointB]), forKey: rosterKey)
        rig.kvs.set(encoded([endpointA]), forKey: rosterKey)

        let counter = VoiceRosterNotificationCounter(name: .settingsDidChangeRemotely)

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
        rig.defaults.set(encoded([endpointA]), forKey: rosterKey)
        rig.kvs.set(Data("not json".utf8), forKey: rosterKey)

        await rig.manager.performInitialSync()

        let roster = await rig.manager.customVoiceEndpoints()
        XCTAssertEqual(roster.map(\.id), [idA],
                       "undecodable KVS bytes must not overwrite a valid local roster")
    }

    func testInitialSyncCloudUnavailableDoesNotRunPushUpArms() async {
        let rig = makeRig(cloudAvailable: false)
        rig.defaults.set("de-DE", forKey: languageLocalKey)

        await rig.manager.performInitialSync()

        XCTAssertNil(rig.kvs.string(forKey: languageKVSKey),
                     "everything push-up-bearing stays behind the iCloudAvailable guard")
    }

    // MARK: - Activation / live-handler overlap (both orders)

    func testActivationThenServerChangeStillRetiresPointers() async {
        let rig = makeRig()
        rig.defaults.set(encoded([endpointA, endpointB]), forKey: rosterKey)
        rig.defaults.set(sttPresetID(idB), forKey: sttActiveKey)
        rig.kvs.set(encoded([endpointA]), forKey: rosterKey)

        // Activation adopts the shrink FIRST — a guess, so the pointer stays.
        await rig.manager.catchUpSyncedRostersOnActivate()
        let afterActivation = await rig.manager.getActivePresetID()
        XCTAssertEqual(afterActivation, sttPresetID(idB),
                       "activation alone must retain the pointer")

        // The queued confirmed notification lands after: the roster transition
        // is gone by now, but the confirmation still authorizes the retirement.
        await rig.manager.handleICloudChange(
            KVSChange(reason: .serverChange, changedKeys: [rosterKey])
        )
        let afterConfirmation = await rig.manager.getActivePresetID()
        XCTAssertEqual(afterConfirmation, appleSTT,
                       "a confirmed serverChange must retire the pointer even when activation adopted the bytes first")
    }

    func testServerChangeThenActivationRetiresPointerAndStaysQuietOnTheSecondPass() async {
        let rig = makeRig()
        rig.defaults.set(encoded([endpointA, endpointB]), forKey: rosterKey)
        rig.defaults.set(sttPresetID(idB), forKey: sttActiveKey)
        rig.kvs.set(encoded([endpointA]), forKey: rosterKey)

        await rig.manager.handleICloudChange(
            KVSChange(reason: .serverChange, changedKeys: [rosterKey])
        )
        let stt = await rig.manager.getActivePresetID()
        XCTAssertEqual(stt, appleSTT)

        let counter = VoiceRosterNotificationCounter(name: .settingsDidChangeRemotely)
        // The stores agree by now — the activation pass must adopt nothing and
        // must not fire a second token-bearing Watch broadcast.
        await rig.manager.catchUpSyncedRostersOnActivate()

        await MainActor.run {}
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(counter.count, 0,
                       "the activation pass after the live handler already adopted must stay silent")
        counter.cancel()
    }

    // MARK: - Write path flags its delta for upload

    func testUpsertAndDeleteFlushKVS() async {
        let rig = makeRig()
        let baseline = rig.kvs.synchronizeCallCount

        _ = await rig.manager.upsertCustomVoiceEndpoint(endpointA)
        let afterUpsert = rig.kvs.synchronizeCallCount
        XCTAssertGreaterThan(afterUpsert, baseline, "upsert must flag its KVS write for upload")

        rig.kvs.set("https://voice.example.com", forKey: urlKey(idA))
        await rig.manager.deleteCustomVoiceEndpoint(id: idA)
        XCTAssertGreaterThan(rig.kvs.synchronizeCallCount, afterUpsert,
                             "delete must flag its KVS removals for upload")

        // The FINAL flush must cover the whole delete — a count alone would
        // still pass if only the mid-operation roster flush survived and the
        // later per-uuid removals stayed dirty.
        let snapshot = rig.kvs.lastSynchronizedSnapshot ?? [:]
        let snapshotRoster = (snapshot[rosterKey] as? Data)
            .flatMap { try? JSONDecoder().decode([CustomVoiceEndpoint].self, from: $0) }
        XCTAssertEqual(snapshotRoster, [],
                       "the last flush must see the shrunken (empty) roster")
        XCTAssertNil(snapshot[urlKey(idA)],
                     "the last flush must run after the per-uuid slot removals")
    }

    // MARK: - Foreground activation catch-up (path 3)

    func testCatchUpOnActivatePostsChangeOnlyWhenRosterChanged() async {
        let rig = makeRig()
        rig.defaults.set(encoded([endpointA, endpointB]), forKey: rosterKey)
        rig.kvs.set(encoded([endpointA]), forKey: rosterKey)

        let counter = VoiceRosterNotificationCounter(name: .settingsDidChangeRemotely)

        await rig.manager.catchUpSyncedRostersOnActivate()
        // Second activation with an unchanged cache must stay silent — the post
        // wakes a token-bearing Watch broadcast and must not fire every activation.
        await rig.manager.catchUpSyncedRostersOnActivate()

        await MainActor.run {}
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(counter.count, 1)
        let roster = await rig.manager.customVoiceEndpoints()
        XCTAssertEqual(roster.map(\.id), [idA])
        counter.cancel()
    }

    func testCatchUpOnActivateSlotOnlyChangePosts() async {
        let rig = makeRig()
        // Roster identical in both stores; the peer edited ONLY the URL.
        rig.defaults.set(encoded([endpointA]), forKey: rosterKey)
        rig.kvs.set(encoded([endpointA]), forKey: rosterKey)
        rig.defaults.set("https://old.example.com", forKey: urlKey(idA))
        rig.kvs.set("https://new.example.com", forKey: urlKey(idA))

        let counter = VoiceRosterNotificationCounter(name: .settingsDidChangeRemotely)

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
}

/// Main-thread-safe notification tally. File-local twin of the gateway suite's
/// counter — the two files each own one so neither depends on the other.
private final class VoiceRosterNotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var observed = 0
    private var token: NSObjectProtocol?

    init(name: Notification.Name) {
        token = NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            lock.lock()
            observed += 1
            lock.unlock()
        }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return observed
    }

    func cancel() {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
        token = nil
    }
}
