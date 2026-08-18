// SPDX-License-Identifier: Apache-2.0

// Conduck
// CustomVoiceEndpointMigrationTests.swift
//
// Phase B — the single-custom → roster migration
// (`SettingsManager.migrateCustomVoiceEndpoint()`). Covers:
//   - fresh install (no legacy URL) → flag set, no endpoint minted
//   - legacy single custom → endpoint #1 minted, non-secret slots copied,
//     active pointers repointed (bare → per-uuid)
//   - retry idempotency: a second run reuses the SAME uuid (no duplicate)
//
// Runs against the `.shared` singleton via the
// `runCustomVoiceEndpointMigrationForTesting()` seam (the static singleton can't
// be reconstructed per test; the in-process latch fires once per process — the
// seam resets it for a deterministic re-run).
//
// The legacy-key Keychain COPY is signing-gated (read legacy synchronizable item
// + `SecItemAdd` per-uuid). On an unsigned headless build the read returns
// errSecItemNotFound (no legacy key seeded here), so the copy is a no-op → the
// flag is still set (the no-key path returns true). The live key-copy is a
// signed founder gate.

import XCTest
@testable import Conduck

final class CustomVoiceEndpointMigrationTests: XCTestCase {

    private let defaults = TestStores.defaults

    override func setUp() async throws {
        try await super.setUp()
        // Suspend iCloud for THIS suite first: it drives the live `.shared`
        // singleton, and when the sim is signed into iCloud the read-fallback +
        // the async `handleICloudChange` mirror leak cross-suite KVS state in,
        // making the empty-list fresh-install assertions flaky. Suspending makes
        // the suite exercise migration purely against App-Group `defaults`.
        await SettingsManager.shared.setICloudSyncSuspendedForTesting(true)
        await wipeAll()
    }

    override func tearDown() async throws {
        await wipeAll()
        // Restore: the flag lives on the shared singleton, so the next suite
        // (e.g. SettingsManagerICloudSyncTests, which needs the mirror live) must
        // see iCloud un-suspended.
        await SettingsManager.shared.setICloudSyncSuspendedForTesting(false)
        try await super.tearDown()
    }

    private func wipeAll() async {
        // Clear BOTH stores. Production setters (e.g. setCustomSTTURL) dual-write
        // App-Group defaults AND iCloud KVS. With iCloud now SUSPENDED for this
        // suite (setUp → setICloudSyncSuspendedForTesting(true)), reads resolve
        // App-Group-only and the async handleICloudChange mirror is inert, so the
        // KVS leg of this wipe is belt-and-suspenders — the App-Group wipe is what
        // makes the suite deterministic. (Pre-suspension, a defaults-only wipe let
        // a prior suite's KVS residue short-circuit the migration → "0 endpoints
        // minted" when the sim was signed into iCloud — the documented flake
        // (docs/ai-context/spec.md).)
        let kvs = TestStores.kvs
        for key in [
            Constants.customVoiceEndpointMigratedKey,
            Constants.customVoiceEndpointMigratedUUIDKey,
            Constants.customVoiceEndpointsRegistryKey,
            Constants.customSTTURLKey,
            Constants.customSTTModelKey,
            Constants.customSTTAuthSchemeKey,
            Constants.customTTSModelKey,
            Constants.customSTTCertFingerprintKey,
            Constants.sttActivePresetIDKVSKey,
            Constants.ttsActiveProviderIDKVSKey,
        ] {
            defaults.removeObject(forKey: key)
            kvs.removeObject(forKey: key)
        }
        await SettingsManager.shared.resetCustomVoiceEndpointMigrationLatchForTesting()
    }

    /// Close the spurious-migration race before a MINTING run. `CarPlaySettings`
    /// is a process singleton whose `.settingsDidChangeRemotely` observer (fired
    /// by ANY suite's settings writes — e.g. `ConversationStoreTests`'
    /// `clearActiveConversation()` in its setUp/tearDown) schedules an async
    /// `activeSTTSnapshot()` → `ensureCustomVoiceEndpointMigrated()`. If one of
    /// those lingering tasks lands in the post-`wipeAll` window (flag cleared,
    /// the legacy URL not yet seeded by the test body) it runs a NO-URL migration
    /// and sets the persistent flag — which makes the real minting run below a
    /// no-op (0 endpoints). Calling this AFTER seeding the URL clears the flag +
    /// latch with the URL present, so the run below (or any racing migration)
    /// actually mints. Only the URL-seeding (minting) tests need this; the
    /// fresh-install / already-migrated tests are immune by construction.
    private func clearMigrationGateForMinting() async {
        defaults.removeObject(forKey: Constants.customVoiceEndpointMigratedKey)
        await SettingsManager.shared.resetCustomVoiceEndpointMigrationLatchForTesting()
    }

    // MARK: - Fresh install

    func testFreshInstallSetsFlagWithoutMintingEndpoint() async {
        // No legacy URL configured.
        let flagSet = await SettingsManager.shared.runCustomVoiceEndpointMigrationForTesting()
        XCTAssertTrue(flagSet, "Fresh install must mark the migration flag so it never re-scans.")
        let list = await SettingsManager.shared.customVoiceEndpoints()
        XCTAssertTrue(list.isEmpty, "Fresh install must not mint any endpoint.")
    }

    // MARK: - Legacy single custom → endpoint #1

    func testLegacyCustomMintsEndpointCopiesSlotsAndRepoints() async {
        // Seed a legacy single-custom config (non-secret parts).
        defaults.set("https://legacy-whisper.example.test:9000", forKey: Constants.customSTTURLKey)
        defaults.set("whisper-large-v3", forKey: Constants.customSTTModelKey)
        defaults.set("none", forKey: Constants.customSTTAuthSchemeKey)
        defaults.set("kokoro", forKey: Constants.customTTSModelKey)
        // Active pointers on the bare legacy ids.
        defaults.set(STTProvider.customOpenAICompat.id, forKey: Constants.sttActivePresetIDKVSKey)
        defaults.set(TTSProvider.customOpenAITTS.id, forKey: Constants.ttsActiveProviderIDKVSKey)

        // Re-clear the migrated flag + latch AFTER seeding (see helper note). A
        // concurrent `CarPlaySettings` refresh can have run a spurious no-URL
        // migration in the post-`wipeAll` window and set the flag; clear it here,
        // with the URL now present, so the run below actually mints.
        await clearMigrationGateForMinting()

        _ = await SettingsManager.shared.runCustomVoiceEndpointMigrationForTesting()

        // One endpoint minted.
        let list = await SettingsManager.shared.customVoiceEndpoints()
        XCTAssertEqual(list.count, 1, "Legacy custom must mint exactly one roster endpoint.")
        guard let endpoint = list.first else { return XCTFail("no endpoint minted") }

        // Per-uuid slots copied from the legacy singleton slots.
        let url = await SettingsManager.shared.getCustomSTTURL(for: endpoint.id)
        XCTAssertEqual(url?.absoluteString, "https://legacy-whisper.example.test:9000")
        let sttModel = await SettingsManager.shared.getCustomSTTModel(for: endpoint.id)
        XCTAssertEqual(sttModel, "whisper-large-v3")
        let ttsModel = await SettingsManager.shared.getCustomTTSModel(for: endpoint.id)
        XCTAssertEqual(ttsModel, "kokoro")
        let auth = await SettingsManager.shared.getCustomSTTAuthScheme(for: endpoint.id)
        XCTAssertEqual(auth, .none, "Legacy auth scheme must be copied to the per-uuid slot.")

        // Active pointers repointed from the bare legacy ids to the per-uuid ids.
        let activeSTT = await SettingsManager.shared.getActivePresetID()
        let activeTTS = await SettingsManager.shared.getActiveTTSProviderID()
        XCTAssertEqual(activeSTT, STTProvider.customEndpointID(for: endpoint.id),
                       "Active STT pointer must be repointed to the per-uuid id.")
        XCTAssertEqual(activeTTS, TTSProvider.customEndpointID(for: endpoint.id),
                       "Active TTS pointer must be repointed to the per-uuid id.")
    }

    // MARK: - Retry idempotency (no duplicate endpoint)

    func testRetryReusesSameUUIDNoDuplicate() async {
        defaults.set("https://legacy.example.test:9000", forKey: Constants.customSTTURLKey)
        await clearMigrationGateForMinting()

        _ = await SettingsManager.shared.runCustomVoiceEndpointMigrationForTesting()
        let firstList = await SettingsManager.shared.customVoiceEndpoints()
        XCTAssertEqual(firstList.count, 1)
        let firstUUID = firstList.first?.id

        // Force a re-run as if a prior partial pass left the flag unset: clear the
        // flag, reset the latch, run again. The persisted roster keeps the same
        // uuid so no duplicate endpoint is created.
        defaults.removeObject(forKey: Constants.customVoiceEndpointMigratedKey)
        await SettingsManager.shared.resetCustomVoiceEndpointMigrationLatchForTesting()
        _ = await SettingsManager.shared.runCustomVoiceEndpointMigrationForTesting()

        let secondList = await SettingsManager.shared.customVoiceEndpoints()
        XCTAssertEqual(secondList.count, 1, "A retried migration must NOT create a duplicate endpoint.")
        XCTAssertEqual(secondList.first?.id, firstUUID, "The retried pass must reuse the SAME uuid.")
    }

    // MARK: - Already-migrated re-run is a no-op

    func testAlreadyMigratedReRunIsNoOp() async {
        // Flag set, a stale legacy URL still present (kept — never deleted).
        defaults.set(true, forKey: Constants.customVoiceEndpointMigratedKey)
        defaults.set("https://stale.example.test", forKey: Constants.customSTTURLKey)

        let stillMigrated = await SettingsManager.shared.runCustomVoiceEndpointMigrationForTesting()
        XCTAssertTrue(stillMigrated, "Flag stays set on a no-op (already-migrated) re-run.")
        let list = await SettingsManager.shared.customVoiceEndpoints()
        XCTAssertTrue(list.isEmpty, "A flag-guarded re-run must early-return — no endpoint minted from the stale URL.")
    }
}
