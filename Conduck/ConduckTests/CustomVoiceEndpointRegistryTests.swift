// SPDX-License-Identifier: Apache-2.0

// Conduck
// CustomVoiceEndpointRegistryTests.swift
//
// Phase B — the `SettingsManager` custom voice-endpoint ROSTER (the JSON list
// under `Constants.customVoiceEndpointsRegistryKey`). Clone of
// `CustomGatewayRegistryTests`: roster CRUD + ADD-only cap + delete clears the
// per-uuid (non-secret) slots and falls the active pointer back to Apple. All
// UserDefaults-backed (App Group), so they run UNSIGNED. The per-uuid Keychain
// key clear on delete is signing-gated and verified on the signed founder run.
//
// Isolation: the actor is a `static let shared` singleton, so each test wipes
// the registry + active-pointer keys + the migration flag in setUp/tearDown —
// the dual-written keys in BOTH App-Group defaults and iCloud KVS.

import XCTest
@testable import Conduck

final class CustomVoiceEndpointRegistryTests: XCTestCase {

    private let defaults = TestStores.defaults

    override func setUp() async throws {
        try await super.setUp()
        await wipe()
    }

    override func tearDown() async throws {
        await wipe()
        try await super.tearDown()
    }

    private func wipe() async {
        // Production setters dual-write App-Group defaults AND iCloud KVS, so the
        // KVS leg must be cleared too or a signed run's read-fallback resurrects a
        // prior test's roster.
        let kvs = TestStores.kvs
        for key in [
            Constants.customVoiceEndpointsRegistryKey,
            Constants.sttActivePresetIDKVSKey,
            Constants.ttsActiveProviderIDKVSKey,
            Constants.customSTTURLKey,
        ] {
            defaults.removeObject(forKey: key)
            kvs.removeObject(forKey: key)
        }
        // Flag the migration as done so it doesn't auto-mint endpoint #1 from any
        // stale singleton URL left by another suite.
        defaults.set(true, forKey: Constants.customVoiceEndpointMigratedKey)
        await SettingsManager.shared.resetCustomVoiceEndpointMigrationLatchForTesting()
    }

    private func endpoint(_ name: String) -> CustomVoiceEndpoint {
        CustomVoiceEndpoint(id: UUID(), name: name)
    }

    /// Persist a roster STRAIGHT into the App-Group JSON, bypassing the capped
    /// `upsertCustomVoiceEndpoint` write path — the only way to stage a roster the
    /// compiled cap would never let `upsert` build.
    private func seedPersistedRoster(_ list: [CustomVoiceEndpoint]) {
        guard let data = try? JSONEncoder().encode(list) else {
            return XCTFail("roster encode failed")
        }
        defaults.set(data, forKey: Constants.customVoiceEndpointsRegistryKey)
    }

    func testEmptyInitially() async {
        let list = await SettingsManager.shared.customVoiceEndpoints()
        XCTAssertTrue(list.isEmpty)
        let count = await SettingsManager.shared.customVoiceEndpointCount()
        XCTAssertEqual(count, 0)
    }

    func testUpsertAddsAndReadsBack() async {
        let e = endpoint("Deepgram")
        let ok = await SettingsManager.shared.upsertCustomVoiceEndpoint(e)
        XCTAssertTrue(ok)
        let fetched = await SettingsManager.shared.customVoiceEndpoint(id: e.id)
        XCTAssertEqual(fetched?.name, "Deepgram")
        let count = await SettingsManager.shared.customVoiceEndpointCount()
        XCTAssertEqual(count, 1)
    }

    func testPersistedRosterRoundTripsThroughJSON() async {
        let e = endpoint("Persisted")
        _ = await SettingsManager.shared.upsertCustomVoiceEndpoint(e)
        let again = await SettingsManager.shared.customVoiceEndpoints()
        XCTAssertEqual(again.first?.id, e.id)
        XCTAssertEqual(again.first?.name, "Persisted")
    }

    func testUpdateSameIDDoesNotIncreaseCount() async {
        var e = endpoint("A")
        _ = await SettingsManager.shared.upsertCustomVoiceEndpoint(e)
        e.name = "A renamed"
        let ok = await SettingsManager.shared.upsertCustomVoiceEndpoint(e)
        XCTAssertTrue(ok)
        let count = await SettingsManager.shared.customVoiceEndpointCount()
        XCTAssertEqual(count, 1)
        let fetched = await SettingsManager.shared.customVoiceEndpoint(id: e.id)
        XCTAssertEqual(fetched?.name, "A renamed")
    }

    func testCapRejectsBeyondMax() async {
        for index in 0..<Constants.maxCustomVoiceEndpoints {
            let ok = await SettingsManager.shared.upsertCustomVoiceEndpoint(endpoint("E\(index)"))
            XCTAssertTrue(ok, "Add #\(index) within the cap must succeed")
        }
        let overflow = await SettingsManager.shared.upsertCustomVoiceEndpoint(endpoint("Overflow"))
        XCTAssertFalse(overflow, "Adding beyond maxCustomVoiceEndpoints must be rejected")
        let count = await SettingsManager.shared.customVoiceEndpointCount()
        XCTAssertEqual(count, Constants.maxCustomVoiceEndpoints)
    }

    func testUpdateAtCapStillSucceeds() async {
        var first: CustomVoiceEndpoint?
        for index in 0..<Constants.maxCustomVoiceEndpoints {
            let e = endpoint("E\(index)")
            if index == 0 { first = e }
            _ = await SettingsManager.shared.upsertCustomVoiceEndpoint(e)
        }
        guard var e = first else { return XCTFail("seed missing") }
        e.name = "updated"
        let ok = await SettingsManager.shared.upsertCustomVoiceEndpoint(e)
        XCTAssertTrue(ok)
        let count = await SettingsManager.shared.customVoiceEndpointCount()
        XCTAssertEqual(count, Constants.maxCustomVoiceEndpoints)
    }

    func testDeleteRemovesFromRosterAndClearsSlots() async {
        let e = endpoint("ToDelete")
        _ = await SettingsManager.shared.upsertCustomVoiceEndpoint(e)
        // Seed the per-uuid non-secret slots.
        await SettingsManager.shared.setCustomSTTURL(URL(string: "https://x.example.test")!, for: e.id)
        await SettingsManager.shared.setCustomSTTModel("whisper-large", for: e.id)
        await SettingsManager.shared.setCustomTTSModel("kokoro", for: e.id)

        await SettingsManager.shared.deleteCustomVoiceEndpoint(id: e.id)

        let deleted = await SettingsManager.shared.customVoiceEndpoint(id: e.id)
        XCTAssertNil(deleted)
        // All per-uuid non-secret slots cleared.
        let url = await SettingsManager.shared.getCustomSTTURL(for: e.id)
        XCTAssertNil(url, "Delete must clear the per-uuid URL slot.")
        let sttModel = await SettingsManager.shared.getCustomSTTModel(for: e.id)
        XCTAssertEqual(sttModel, "whisper-1", "STT model falls back to the default after delete.")
        let ttsModel = await SettingsManager.shared.getCustomTTSModel(for: e.id)
        XCTAssertEqual(ttsModel, "tts-1", "TTS model falls back to the default after delete.")
        // Freed slot → a fresh add succeeds.
        let readd = await SettingsManager.shared.upsertCustomVoiceEndpoint(endpoint("New"))
        XCTAssertTrue(readd)
    }

    /// Deleting the ACTIVE endpoint falls the STT + TTS pointers back to Apple
    /// (stricter than the gateway fallback — no built-in sibling to inherit).
    func testDeleteActiveEndpointFallsBackToApple() async {
        let e = endpoint("Active")
        _ = await SettingsManager.shared.upsertCustomVoiceEndpoint(e)
        await SettingsManager.shared.setActivePresetID(e.sttPresetID)
        await SettingsManager.shared.setActiveTTSProviderID(e.ttsProviderID)

        await SettingsManager.shared.deleteCustomVoiceEndpoint(id: e.id)

        let activeSTT = await SettingsManager.shared.getActivePresetID()
        let activeTTS = await SettingsManager.shared.getActiveTTSProviderID()
        XCTAssertEqual(activeSTT, Constants.sttActivePresetIDDefault,
                       "Deleting the active-STT endpoint must fall the pointer back to Apple.")
        XCTAssertEqual(activeTTS, Constants.ttsActiveProviderIDDefault,
                       "Deleting the active-TTS endpoint must fall the pointer back to Apple.")
    }

    func testCapConstantIsFive() {
        XCTAssertEqual(Constants.maxCustomVoiceEndpoints, 5)
    }

    /// The cap is enforced on ADD only — every reader decodes the persisted array
    /// whole. A roster synced down from a future, higher-cap build must therefore
    /// survive intact on an older binary: nothing truncates it, updates still
    /// land, and only NEW adds are refused until a delete frees a slot.
    func testOverCapRosterReadsFullyAndRejectsOnlyNewAdds() async {
        let overCap = Constants.maxCustomVoiceEndpoints + 2
        let seeded = (0..<overCap).map { endpoint("Synced\($0)") }
        seedPersistedRoster(seeded)

        let list = await SettingsManager.shared.customVoiceEndpoints()
        XCTAssertEqual(list.map(\.id), seeded.map(\.id),
                       "Readers must return EVERY persisted entry in order — never truncate to the compiled cap.")
        let count = await SettingsManager.shared.customVoiceEndpointCount()
        XCTAssertEqual(count, overCap)

        // UPDATE bypasses the cap even while the roster sits above it.
        guard var first = seeded.first else { return XCTFail("seed missing") }
        first.name = "updated"
        let updated = await SettingsManager.shared.upsertCustomVoiceEndpoint(first)
        XCTAssertTrue(updated, "Updating an existing entry must succeed on an over-cap roster.")
        let refetched = await SettingsManager.shared.customVoiceEndpoint(id: first.id)
        XCTAssertEqual(refetched?.name, "updated")
        let countAfterUpdate = await SettingsManager.shared.customVoiceEndpointCount()
        XCTAssertEqual(countAfterUpdate, overCap, "An update must neither grow nor shrink the over-cap roster.")

        let overflow = await SettingsManager.shared.upsertCustomVoiceEndpoint(endpoint("Overflow"))
        XCTAssertFalse(overflow, "Adding to an over-cap roster must be rejected.")

        // Delete back below the cap — `overCap - 3 == maxCustomVoiceEndpoints - 1`.
        for entry in seeded.suffix(3) {
            await SettingsManager.shared.deleteCustomVoiceEndpoint(id: entry.id)
        }
        let countAfterDeletes = await SettingsManager.shared.customVoiceEndpointCount()
        XCTAssertEqual(countAfterDeletes, Constants.maxCustomVoiceEndpoints - 1)
        let readd = await SettingsManager.shared.upsertCustomVoiceEndpoint(endpoint("New"))
        XCTAssertTrue(readd, "A freed slot below the cap accepts a fresh add again.")
    }

    // MARK: - Snapshot resolution (active per-uuid endpoint builds per-uuid config)

    /// With a per-uuid endpoint active for STT, `activeSTTSnapshot()` resolves the
    /// FULL transcribe URL + model + auth from the per-uuid slots (not the
    /// singleton), and the synthesized provider carries the per-uuid dynamic key.
    func testActiveSTTSnapshotBuildsPerUUIDConfig() async {
        let e = endpoint("Active STT")
        _ = await SettingsManager.shared.upsertCustomVoiceEndpoint(e)
        await SettingsManager.shared.setCustomSTTURL(URL(string: "https://w.example.test:8443")!, for: e.id)
        await SettingsManager.shared.setCustomSTTModel("whisper-pro", for: e.id)
        await SettingsManager.shared.setCustomSTTAuthScheme(.none, for: e.id)
        await SettingsManager.shared.setActivePresetID(e.sttPresetID)

        let snapshot = await SettingsManager.shared.activeSTTSnapshot()
        XCTAssertEqual(snapshot.presetID, e.sttPresetID)
        XCTAssertEqual(snapshot.provider.dynamicEndpointKey, Constants.customSTTURLKey(for: e.id))
        XCTAssertEqual(snapshot.customConfig?.url?.absoluteString,
                       "https://w.example.test:8443/v1/audio/transcriptions",
                       "Snapshot must build the per-uuid transcribe URL.")
        XCTAssertEqual(snapshot.customConfig?.model, "whisper-pro")
        XCTAssertEqual(snapshot.customConfig?.auth, STTAuthScheme.none)
    }

    /// With a per-uuid endpoint active for TTS, `activeTTSSnapshot()` resolves the
    /// per-uuid synthesis URL + model, and the synthesized provider's shared key
    /// maps to the per-uuid STT slot (one key, both directions).
    func testActiveTTSSnapshotBuildsPerUUIDConfigAndSharedKeyLink() async {
        let e = endpoint("Active TTS")
        _ = await SettingsManager.shared.upsertCustomVoiceEndpoint(e)
        await SettingsManager.shared.setCustomSTTURL(URL(string: "https://t.example.test")!, for: e.id)
        await SettingsManager.shared.setCustomTTSModel("kokoro-82m", for: e.id)
        await SettingsManager.shared.setActiveTTSProviderID(e.ttsProviderID)

        let snapshot = await SettingsManager.shared.activeTTSSnapshot()
        XCTAssertEqual(snapshot.providerID, e.ttsProviderID)
        XCTAssertEqual(snapshot.customConfig?.url?.absoluteString,
                       "https://t.example.test/v1/audio/speech",
                       "Snapshot must build the per-uuid speech URL.")
        XCTAssertEqual(snapshot.customConfig?.model, "kokoro-82m")
        // The synthesized provider's shared key points at the per-uuid STT slot.
        let provider = TTSProvider.lookup(id: e.ttsProviderID)
        XCTAssertEqual(provider.sharedKeySTTPresetID, e.sttPresetID)
    }
}
