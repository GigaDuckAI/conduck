// SPDX-License-Identifier: Apache-2.0

// Conduck
// CustomVoiceEndpointLegacyRetirementTests.swift
//
// What happens to the LEGACY singleton custom-voice-endpoint config — the bare
// `stt.custom.*` / `tts.custom.model` slots plus the synchronizable
// `stt.apiKey.custom-openai` Keychain item — once the roster migration has
// copied it into endpoint #1. Three contracts:
//
//   1. The migration COPIES, and must keep copying: a peer device still running
//      the pre-roster build has to be able to find the legacy state to complete
//      its own migration. Nothing is cleared at migration time.
//   2. Deleting the endpoint that copy was migrated INTO retires it — from both
//      stores AND from the Keychain. That delete is the only collector, because
//      the bare `custom-openai` id has no vendor row: no Settings screen can
//      show or remove what the legacy state still describes. Ownership follows
//      the uuid the migration STAMPED, never a base-URL match, because two
//      endpoints may legitimately share one self-hosted box and the Keychain
//      delete reaches every device on the account.
//   3. An id no vendor row can render is never offered as a voice-recovery
//      target and never adopted from a peer as the active preset — by ANY of the
//      three paths that read the synced pointer (the launch sync, the inbound
//      KVS mirror, and the iCloud fallback arm of `getActivePresetID()`). Each
//      alone could otherwise POST recorded audio, with the user's bearer token,
//      to an endpoint they believe they deleted.
//
// Every case drives an isolated `SettingsManager(dependencies: .inMemory())`, so
// the App Group, the iCloud KVS and the Keychain are all dictionaries private to
// that one manager — no signing, no entitlement, no shared state with any other
// suite, and the Keychain assertions run unsigned.

import XCTest
@testable import Conduck

final class CustomVoiceEndpointLegacyRetirementTests: XCTestCase {

    /// One isolated manager plus direct handles on its two non-secret stores, so
    /// a test can assert on the RAW keys a getter would hide behind a default.
    private struct Rig {
        let manager: SettingsManager
        let defaults: InMemoryDefaultsStore
        let kvs: InMemoryUbiquitousStore
    }

    /// `cloudAvailable` is opt-in because the pointer-adoption cases need the two
    /// paths that are gated on it — `performInitialSync()` and the iCloud arm of
    /// `getActivePresetID()`.
    private func makeRig(cloudAvailable: Bool = false) -> Rig {
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()
        let manager = SettingsManager(
            dependencies: .inMemory(
                defaults: defaults,
                ubiquitous: kvs,
                secrets: InMemorySecretStore(),
                cloudAvailable: cloudAvailable
            )
        )
        return Rig(manager: manager, defaults: defaults, kvs: kvs)
    }

    /// The bare (pre-roster) keys, exactly the set a delete of the migrated
    /// endpoint has to retire from BOTH stores.
    private var legacyDualWrittenKeys: [String] {
        [
            Constants.customSTTURLKey,
            Constants.customSTTModelKey,
            Constants.customSTTAuthSchemeKey,
            Constants.customTTSModelKey
        ]
    }

    private let legacyURL = URL(string: "https://legacy-voice.example.com")!

    /// Put the rig in the state a device upgrading from the single-custom build
    /// is in: a configured legacy endpoint, its key in the Keychain, and the
    /// migration not yet run.
    private func seedLegacySingleton(_ rig: Rig) async throws {
        await rig.manager.setCustomSTTURL(legacyURL)
        await rig.manager.setCustomSTTModel("legacy-whisper")
        await rig.manager.setCustomSTTAuthScheme(.bearer)
        await rig.manager.setCustomTTSModel("legacy-tts")
        await rig.manager.setCustomSTTCertFingerprint(String(repeating: "ab", count: 32))
        try await rig.manager.setAPIKey("legacy-key", forPresetID: STTProvider.customOpenAICompat.id)
    }

    /// Skip the migration outright — for the cases that stage an ORPHAN (legacy
    /// key with no legacy URL to migrate) and must not have endpoint #1 minted
    /// underneath them.
    private func markMigrationDone(_ rig: Rig) async {
        rig.defaults.set(true, forKey: Constants.customVoiceEndpointMigratedKey)
        await rig.manager.resetCustomVoiceEndpointMigrationLatchForTesting()
    }

    // MARK: - 1. The migration copies, and leaves the copy alone

    func testMigrationLeavesTheLegacyConfigInPlace() async throws {
        let rig = makeRig()
        try await seedLegacySingleton(rig)

        let migrated = await rig.manager.runCustomVoiceEndpointMigrationForTesting()
        XCTAssertTrue(migrated, "the key copy must confirm so the flag latches")

        let roster = await rig.manager.customVoiceEndpoints()
        let endpoint = try XCTUnwrap(roster.first, "the migration mints endpoint #1")

        // The per-uuid copy exists…
        let copiedURL = await rig.manager.getCustomSTTURL(for: endpoint.id)
        XCTAssertEqual(copiedURL, legacyURL)
        let copiedKey = await rig.manager.getAPIKey(forPresetID: endpoint.sttPresetID)
        XCTAssertEqual(copiedKey, "legacy-key")

        // …and the legacy original is UNTOUCHED. A second device mid-upgrade
        // still has to find it. Breaking this to fix the residue would break a
        // shipped migration.
        for key in legacyDualWrittenKeys {
            XCTAssertNotNil(rig.defaults.object(forKey: key), "\(key) must survive migration")
            XCTAssertNotNil(rig.kvs.object(forKey: key), "\(key) must survive migration in KVS")
        }
        let legacyKey = await rig.manager.getAPIKey(forPresetID: STTProvider.customOpenAICompat.id)
        XCTAssertEqual(legacyKey, "legacy-key", "the legacy Keychain item must survive migration")
    }

    // MARK: - 2. Deleting the migrated endpoint retires the copy

    func testDeletingTheMigratedEndpointRetiresTheLegacyConfig() async throws {
        let rig = makeRig()
        try await seedLegacySingleton(rig)
        _ = await rig.manager.runCustomVoiceEndpointMigrationForTesting()
        let endpoints = await rig.manager.customVoiceEndpoints()
        let endpoint = try XCTUnwrap(endpoints.first)

        await rig.manager.deleteCustomVoiceEndpoint(id: endpoint.id)

        for key in legacyDualWrittenKeys {
            XCTAssertNil(rig.defaults.object(forKey: key), "\(key) must be cleared from App Groups")
            XCTAssertNil(rig.kvs.object(forKey: key), "\(key) must be cleared from iCloud KVS")
        }
        let pin = await rig.manager.getCustomSTTCertFingerprint()
        XCTAssertNil(pin, "the legacy per-device cert pin goes with the config it pinned")

        let legacyKey = await rig.manager.getAPIKey(forPresetID: STTProvider.customOpenAICompat.id)
        XCTAssertNil(legacyKey, "the synchronizable legacy Keychain item must be deleted")

        // And the endpoint's own family is gone too, so nothing is left that a
        // later read could resolve into a live endpoint.
        let perUUIDURL = await rig.manager.getCustomSTTURL(for: endpoint.id)
        XCTAssertNil(perUUIDURL)
        let perUUIDKey = await rig.manager.getAPIKey(forPresetID: endpoint.sttPresetID)
        XCTAssertNil(perUUIDKey)
    }

    /// The verdict is per-endpoint: deleting an endpoint the legacy config was
    /// NOT copied into leaves that config alone, because a synchronizable
    /// Keychain delete reaches every device on the account and must follow the
    /// user's actual intent.
    func testDeletingAnUnrelatedEndpointLeavesTheLegacyConfigAlone() async throws {
        let rig = makeRig()
        try await seedLegacySingleton(rig)
        _ = await rig.manager.runCustomVoiceEndpointMigrationForTesting()

        let other = CustomVoiceEndpoint(id: UUID(), name: "Whisper box")
        let added = await rig.manager.upsertCustomVoiceEndpoint(other)
        XCTAssertTrue(added)
        await rig.manager.setCustomSTTURL(URL(string: "https://other-voice.example.com")!, for: other.id)

        await rig.manager.deleteCustomVoiceEndpoint(id: other.id)

        for key in legacyDualWrittenKeys {
            XCTAssertNotNil(rig.defaults.object(forKey: key), "\(key) belongs to a different endpoint")
        }
        let legacyKey = await rig.manager.getAPIKey(forPresetID: STTProvider.customOpenAICompat.id)
        XCTAssertEqual(legacyKey, "legacy-key")
    }

    /// Two endpoints can legitimately point at ONE self-hosted box — different
    /// key, different model, same base URL. Ownership of the legacy config
    /// follows the uuid the migration stamped, so deleting the COLLIDING endpoint
    /// must not reach a synchronizable Keychain item every device shares. Nothing
    /// on this device would show that damage; the peer still on the pre-roster
    /// build is the one that loses its key.
    func testDeletingAnEndpointThatMerelySharesTheLegacyURLLeavesTheLegacyConfigAlone() async throws {
        let rig = makeRig()
        try await seedLegacySingleton(rig)
        _ = await rig.manager.runCustomVoiceEndpointMigrationForTesting()
        let migratedRoster = await rig.manager.customVoiceEndpoints()
        let migrated = try XCTUnwrap(migratedRoster.first)

        // A second endpoint on the SAME box.
        let twin = CustomVoiceEndpoint(id: UUID(), name: "Same box, second key")
        let added = await rig.manager.upsertCustomVoiceEndpoint(twin)
        XCTAssertTrue(added)
        await rig.manager.setCustomSTTURL(legacyURL, for: twin.id)
        let twinURL = await rig.manager.getCustomSTTURL(for: twin.id)
        XCTAssertEqual(twinURL, legacyURL, "the collision this case exists to stage")

        await rig.manager.deleteCustomVoiceEndpoint(id: twin.id)

        for key in legacyDualWrittenKeys {
            XCTAssertNotNil(rig.defaults.object(forKey: key), "\(key) belongs to the migrated endpoint")
            XCTAssertNotNil(rig.kvs.object(forKey: key), "\(key) belongs to the migrated endpoint")
        }
        let legacyKey = await rig.manager.getAPIKey(forPresetID: STTProvider.customOpenAICompat.id)
        XCTAssertEqual(legacyKey, "legacy-key", "a synchronizable delete must follow the STAMPED owner")

        // …and the real owner still owns it: deleting THAT one does retire it.
        await rig.manager.deleteCustomVoiceEndpoint(id: migrated.id)
        let afterOwnerDelete = await rig.manager.getAPIKey(forPresetID: STTProvider.customOpenAICompat.id)
        XCTAssertNil(afterOwnerDelete, "the stamped owner's delete is still the collector")
    }

    /// A device that migrated on a build predating the ownership stamp carries
    /// the flag with no uuid. Endpoint #1 is the one that migration minted, so
    /// the stamp seeds from it once and the retirement still fires.
    func testADeviceMigratedBeforeTheStampStillRetiresTheLegacyConfig() async throws {
        let rig = makeRig()
        try await seedLegacySingleton(rig)
        _ = await rig.manager.runCustomVoiceEndpointMigrationForTesting()
        let roster = await rig.manager.customVoiceEndpoints()
        let endpoint = try XCTUnwrap(roster.first)

        // Exactly the state an already-migrated device is in: flag set, no stamp.
        rig.defaults.removeObject(forKey: Constants.customVoiceEndpointMigratedUUIDKey)

        await rig.manager.deleteCustomVoiceEndpoint(id: endpoint.id)

        let legacyKey = await rig.manager.getAPIKey(forPresetID: STTProvider.customOpenAICompat.id)
        XCTAssertNil(legacyKey, "the seeded stamp must still name endpoint #1 as the owner")
        for key in legacyDualWrittenKeys {
            XCTAssertNil(rig.defaults.object(forKey: key), "\(key) must be cleared from App Groups")
        }
    }

    // MARK: - 3a. The recovery target must be renderable

    func testRecoverySelectorSkipsAnOrphanedLegacyKey() async throws {
        let rig = makeRig()
        await markMigrationDone(rig)
        // The residue a completed migration leaves: a key at the bare id, with no
        // roster entry and therefore no vendor row anywhere in Settings.
        try await rig.manager.setAPIKey("orphan-key", forPresetID: STTProvider.customOpenAICompat.id)

        let recovery = await rig.manager.firstConfiguredCloudSTTPresetID()
        XCTAssertNil(recovery, "an id no vendor row can render must never be a recovery target")
    }

    func testRecoverySelectorStillOffersARenderableVendor() async throws {
        let rig = makeRig()
        await markMigrationDone(rig)
        let openAIPreset = try XCTUnwrap(VoiceVendorRegistry.openAI.sttPresetID)
        try await rig.manager.setAPIKey("orphan-key", forPresetID: STTProvider.customOpenAICompat.id)
        try await rig.manager.setAPIKey("openai-key", forPresetID: openAIPreset)

        let recovery = await rig.manager.firstConfiguredCloudSTTPresetID()
        XCTAssertEqual(recovery, openAIPreset, "the orphan is skipped, the real vendor is offered")
    }

    func testRecoverySelectorOffersARosteredCustomEndpoint() async throws {
        let rig = makeRig()
        await markMigrationDone(rig)
        let endpoint = CustomVoiceEndpoint(id: UUID(), name: "Whisper box")
        _ = await rig.manager.upsertCustomVoiceEndpoint(endpoint)
        try await rig.manager.setAPIKey("endpoint-key", forPresetID: endpoint.sttPresetID)

        let recovery = await rig.manager.firstConfiguredCloudSTTPresetID()
        XCTAssertEqual(recovery, endpoint.sttPresetID, "a rostered endpoint DOES render a vendor row")
    }

    // MARK: - 3b. The inbound KVS mirror must refuse an unresolvable pointer

    func testInboundMirrorRefusesAPresetIDWithNoVendorRow() async throws {
        let rig = makeRig()
        await markMigrationDone(rig)
        let openAIPreset = try XCTUnwrap(VoiceVendorRegistry.openAI.sttPresetID)
        await rig.manager.setActivePresetID(openAIPreset)

        // A peer still on the pre-roster build points the account at the bare
        // legacy id. Zero taps on this device.
        rig.kvs.set(STTProvider.customOpenAICompat.id, forKey: Constants.sttActivePresetIDKVSKey)
        await rig.manager.handleICloudChange(
            KVSChange(reason: .serverChange, changedKeys: [Constants.sttActivePresetIDKVSKey])
        )

        let active = await rig.manager.getActivePresetID()
        XCTAssertEqual(active, openAIPreset, "the local pointer stands; the unresolvable id is refused")
        XCTAssertEqual(
            rig.defaults.string(forKey: Constants.sttActivePresetIDKVSKey),
            openAIPreset,
            "nothing unresolvable may be mirrored into the durable store"
        )
    }

    func testInboundMirrorAcceptsARosteredCustomEndpoint() async throws {
        let rig = makeRig()
        await markMigrationDone(rig)
        let endpoint = CustomVoiceEndpoint(id: UUID(), name: "Whisper box")
        _ = await rig.manager.upsertCustomVoiceEndpoint(endpoint)

        rig.kvs.set(endpoint.sttPresetID, forKey: Constants.sttActivePresetIDKVSKey)
        await rig.manager.handleICloudChange(
            KVSChange(reason: .serverChange, changedKeys: [Constants.sttActivePresetIDKVSKey])
        )

        let active = await rig.manager.getActivePresetID()
        XCTAssertEqual(active, endpoint.sttPresetID)
    }

    /// The roster and the pointer that activates it can arrive in the SAME push,
    /// and the roster JSON is mirrored later in that pass — so the gate has to
    /// read the incoming iCloud copy, not just the durable one, or it would
    /// refuse a legitimate pointer for exactly the push that introduces it.
    func testInboundMirrorAcceptsAnEndpointArrivingInTheSamePush() async throws {
        let rig = makeRig()
        await markMigrationDone(rig)
        let endpoint = CustomVoiceEndpoint(id: UUID(), name: "Arrived together")
        let rosterJSON = try JSONEncoder().encode([endpoint])

        rig.kvs.set(rosterJSON, forKey: Constants.customVoiceEndpointsRegistryKey)
        rig.kvs.set(endpoint.sttPresetID, forKey: Constants.sttActivePresetIDKVSKey)
        await rig.manager.handleICloudChange(
            KVSChange(
                reason: .serverChange,
                changedKeys: [
                    Constants.customVoiceEndpointsRegistryKey,
                    Constants.sttActivePresetIDKVSKey
                ]
            )
        )

        let active = await rig.manager.getActivePresetID()
        XCTAssertEqual(active, endpoint.sttPresetID)
    }

    /// The bypass the inbound-mirror case above cannot see: on a FRESH DEVICE or
    /// after a reinstall there is no local value to mask the iCloud copy, and two
    /// other paths read that copy — the launch sync, which runs on every launch,
    /// and the iCloud fallback arm of `getActivePresetID()` itself. Both must
    /// refuse independently, or the orphan pointer becomes the active provider
    /// anyway and `activeSTTSnapshot()` posts recorded audio plus the bearer
    /// token to a config no Settings screen can show.
    func testUnresolvablePointerIsRefusedWithNoLocalValueToMaskIt() async throws {
        let rig = makeRig(cloudAvailable: true)
        await markMigrationDone(rig)
        rig.kvs.set(STTProvider.customOpenAICompat.id, forKey: Constants.sttActivePresetIDKVSKey)
        XCTAssertNil(
            rig.defaults.object(forKey: Constants.sttActivePresetIDKVSKey),
            "the local store must start empty, or it would mask the iCloud copy"
        )

        let beforeSync = await rig.manager.getActivePresetID()
        XCTAssertEqual(
            beforeSync,
            Constants.sttActivePresetIDDefault,
            "the iCloud fallback arm must refuse an id with no vendor row"
        )

        await rig.manager.performInitialSync()

        XCTAssertNil(
            rig.defaults.object(forKey: Constants.sttActivePresetIDKVSKey),
            "the launch sync must not mirror an unresolvable id into the durable store"
        )
        let afterSync = await rig.manager.getActivePresetID()
        XCTAssertEqual(afterSync, Constants.sttActivePresetIDDefault, "still Apple after a full launch sync")
    }

    /// The same two paths must still ADOPT a pointer they can resolve — the gate
    /// is a vendor-row check, not a refusal to sync.
    func testInitialSyncAdoptsAResolvablePointerWithNoLocalValue() async throws {
        let rig = makeRig(cloudAvailable: true)
        await markMigrationDone(rig)
        let endpoint = CustomVoiceEndpoint(id: UUID(), name: "Whisper box")
        _ = await rig.manager.upsertCustomVoiceEndpoint(endpoint)
        rig.defaults.removeObject(forKey: Constants.sttActivePresetIDKVSKey)
        rig.kvs.set(endpoint.sttPresetID, forKey: Constants.sttActivePresetIDKVSKey)

        let beforeSync = await rig.manager.getActivePresetID()
        XCTAssertEqual(beforeSync, endpoint.sttPresetID, "a rostered endpoint resolves through the iCloud arm")

        await rig.manager.performInitialSync()

        XCTAssertEqual(
            rig.defaults.string(forKey: Constants.sttActivePresetIDKVSKey),
            endpoint.sttPresetID,
            "the launch sync hydrates the durable store with what it can resolve"
        )
    }

    /// A cleared pointer still clears: refusing an UNRESOLVABLE id must not turn
    /// into refusing a removal.
    func testInboundMirrorStillClearsAnEmptyPointer() async throws {
        let rig = makeRig()
        await markMigrationDone(rig)
        let openAIPreset = try XCTUnwrap(VoiceVendorRegistry.openAI.sttPresetID)
        await rig.manager.setActivePresetID(openAIPreset)

        rig.kvs.removeObject(forKey: Constants.sttActivePresetIDKVSKey)
        await rig.manager.handleICloudChange(
            KVSChange(reason: .serverChange, changedKeys: [Constants.sttActivePresetIDKVSKey])
        )

        XCTAssertNil(rig.defaults.object(forKey: Constants.sttActivePresetIDKVSKey))
        let active = await rig.manager.getActivePresetID()
        XCTAssertEqual(active, Constants.sttActivePresetIDDefault, "cleared falls back to Apple")
    }
}
