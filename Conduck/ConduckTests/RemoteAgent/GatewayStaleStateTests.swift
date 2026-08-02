// SPDX-License-Identifier: Apache-2.0

// Conduck
// GatewayStaleStateTests.swift
//
// Locks the "a removed gateway stays removed" contract — the behaviours that
// together let a forgotten gateway keep haunting Diagnostics:
//
//   1. `hasStoredRemoteAgentEvidence` / `storedRemoteAgentRefs()` see a
//      half-configured gateway, so the Settings editor can offer Forget for
//      something `configuredRemoteAgentRefs()` (fail-closed) drops.
//   2. `performInitialSync` NEVER pushes a local gateway URL up into KVS. A
//      device that was offline when a peer hit Forget must not resurrect it.
//   3. The inbound mirror handles a `remoteAgent.model.*` REMOVAL, not just a
//      change — OpenRouter's URL is app-fixed, so a stale model alone is
//      enough to keep the gateway reading half-configured forever.
//   4. `defaultRemoteAgentRef()` drops a pointer at a gateway that no longer
//      exists instead of handing back a ref every send will reject.
//   5. The orphan sweep prunes per-uuid keys whose uuid left the roster, and
//      spares the ones still on it.
//
// Every test builds its own `SettingsManager` from an isolated in-memory
// dependency bundle — no shared singleton, no wipe choreography, and
// `cloudAvailable: true` where the KVS read-fallback or `performInitialSync`
// is the thing under test (production gates both on an iCloud account).

import XCTest
@testable import Conduck

final class GatewayStaleStateTests: XCTestCase {

    // Key literals pinned independently of `Constants` so a rename that would
    // orphan real user data breaks a test rather than silently re-homing keys.
    private let openclawURLKey = "remoteAgent.url.openclaw"
    private let hermesURLKey = "remoteAgent.url.hermes"
    private let openrouterModelKey = "remoteAgent.model.openrouter"
    private let defaultBackendKey = "remoteAgent.defaultBackend"
    private let gatewayRosterKey = "remoteAgent.customGateways"

    private func makeManager(
        defaults: InMemoryDefaultsStore = InMemoryDefaultsStore(),
        kvs: InMemoryUbiquitousStore = InMemoryUbiquitousStore(),
        cloudAvailable: Bool = true
    ) -> SettingsManager {
        SettingsManager(dependencies: .inMemory(
            defaults: defaults,
            ubiquitous: kvs,
            cloudAvailable: cloudAvailable
        ))
    }

    // MARK: - 1. A half-configured gateway is visible to the Forget affordance

    func testURLWithoutTokenIsStoredEvidenceButNotConfigured() async {
        let defaults = InMemoryDefaultsStore()
        // Exactly the founder's state: a URL with no token and no auth scheme.
        defaults.set("https://gateway.example.test", forKey: openclawURLKey)
        let manager = makeManager(defaults: defaults)

        let configured = await manager.configuredRemoteAgentRefs()
        XCTAssertFalse(configured.contains(.builtin(.openclaw)),
                       "A `.bearer` gateway with no token must stay fail-closed unconfigured.")

        let hasEvidence = await manager.hasStoredRemoteAgentEvidence(.builtin(.openclaw))
        XCTAssertTrue(hasEvidence,
                      "A stored URL IS evidence — otherwise there is no way to reach the leftover.")

        let stored = await manager.storedRemoteAgentRefs()
        XCTAssertTrue(stored.contains(.builtin(.openclaw)),
                      "storedRemoteAgentRefs drives the editor's Forget button; it must include the partial.")

        let partial = await manager.partiallyConfiguredRemoteAgentRefs()
        XCTAssertEqual(partial, [.builtin(.openclaw)],
                       "The Diagnostics partial count and the Forget gate must agree — one predicate, both callers.")
    }

    func testUnconfiguredGatewayWithNoStoredStateIsNotEvidence() async {
        let manager = makeManager()
        let stored = await manager.storedRemoteAgentRefs()
        XCTAssertTrue(stored.isEmpty,
                      "A fresh install stores nothing — a Forget button on every built-in would be noise.")
    }

    // MARK: - 2. performInitialSync never pushes a gateway URL up

    func testInitialSyncNeverPushesLocalGatewayURLIntoKVS() async {
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()
        // This device is offline-stale: it still holds a URL a peer already
        // forgot, so KVS has none.
        defaults.set("https://stale-openclaw.example.test", forKey: openclawURLKey)
        let manager = makeManager(defaults: defaults, kvs: kvs)

        await manager.performInitialSync()

        XCTAssertNil(kvs.string(forKey: openclawURLKey),
                     "A push-up would resurrect the forgotten gateway into KVS and ping-pong it to every device.")
        XCTAssertEqual(defaults.string(forKey: openclawURLKey), "https://stale-openclaw.example.test",
                       "…and silence in KVS is NOT evidence of a remote delete — a gateway configured while signed out, or one whose first KVS download hasn't landed, must not be wiped. A remote delete arrives as a change notification, which handleICloudChange acts on.")
    }

    func testInitialSyncStillHydratesGatewayURLFromKVS() async {
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()
        // Fresh device / reinstall: the App Group is empty, KVS holds the config.
        kvs.set("https://hermes.example.test:8642", forKey: hermesURLKey)
        let manager = makeManager(defaults: defaults, kvs: kvs)

        await manager.performInitialSync()

        XCTAssertEqual(defaults.string(forKey: hermesURLKey), "https://hermes.example.test:8642",
                       "Inbound hydration is what restores a gateway on a reinstall — it must survive the push-up removal.")
    }

    // MARK: - 3. A KVS model REMOVAL clears the local value

    func testInboundModelRemovalClearsLocalModel() async {
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()
        defaults.set("anthropic/claude-opus-4", forKey: openrouterModelKey)
        kvs.set("anthropic/claude-opus-4", forKey: openrouterModelKey)
        let manager = makeManager(defaults: defaults, kvs: kvs)

        // A peer forgot OpenRouter: the model key is removed and the removal
        // arrives as a server change.
        kvs.removeObject(forKey: openrouterModelKey)
        await manager.handleICloudChange(
            KVSChange(reason: .serverChange, changedKeys: [openrouterModelKey])
        )

        XCTAssertNil(defaults.string(forKey: openrouterModelKey),
                     "OpenRouter's URL is app-fixed, so a surviving model alone keeps it half-configured forever.")
        let evidence = await manager.hasStoredRemoteAgentEvidence(.builtin(.openrouter))
        XCTAssertFalse(evidence,
                       "With the model gone and no token, OpenRouter must read as having nothing stored.")
    }

    func testInboundModelChangeMirrorsIntoDefaults() async {
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()
        let manager = makeManager(defaults: defaults, kvs: kvs)

        kvs.set("openai/gpt-5", forKey: openrouterModelKey)
        await manager.handleICloudChange(
            KVSChange(reason: .serverChange, changedKeys: [openrouterModelKey])
        )

        XCTAssertEqual(defaults.string(forKey: openrouterModelKey), "openai/gpt-5",
                       "The model rides KVS; without an inbound mirror a peer's pick never lands here.")
    }

    // MARK: - 4. The default pointer self-heals

    func testDefaultRefDropsDanglingPointer() async {
        let defaults = InMemoryDefaultsStore()
        // A pointer at a gateway with no config behind it — what a Forget on
        // another device (or a half-completed one here) leaves.
        defaults.set("hermes", forKey: defaultBackendKey)
        let manager = makeManager(defaults: defaults)

        let resolved = await manager.defaultRemoteAgentRef()

        XCTAssertNil(defaults.string(forKey: defaultBackendKey),
                     "The dangling pointer must be dropped, not just ignored on this read.")
        XCTAssertEqual(resolved, .builtin(Constants.remoteAgentDefaultBackendDefault),
                       "With nothing configured, resolution falls through to the built-in default.")
    }

    func testDefaultRefKeepsPointerAtAConfiguredGateway() async {
        let defaults = InMemoryDefaultsStore()
        // Keyless (`.none`) Hermes is configured on URL alone — no Keychain
        // needed, so this holds on an unsigned run too.
        defaults.set("https://hermes.example.test:8642", forKey: hermesURLKey)
        defaults.set("none", forKey: "remoteAgent.authScheme.hermes")
        defaults.set("hermes", forKey: defaultBackendKey)
        let manager = makeManager(defaults: defaults)

        let resolved = await manager.defaultRemoteAgentRef()

        XCTAssertEqual(resolved, .builtin(.hermes),
                       "A pointer at a gateway that IS configured must survive — self-heal must not eat live config.")
        XCTAssertEqual(defaults.string(forKey: defaultBackendKey), "hermes",
                       "…and the stored pointer must be left alone.")
    }

    // MARK: - 5. The orphan sweep

    func testInitialSyncPrunesOffRosterUUIDSlotsAndSparesOnRosterOnes() async throws {
        let live = UUID()
        let dead = UUID()
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()

        let roster = [CustomGateway(id: live, name: "Live")]
        let rosterData = try JSONEncoder().encode(roster)
        defaults.set(rosterData, forKey: gatewayRosterKey)
        kvs.set(rosterData, forKey: gatewayRosterKey)

        // Slots for BOTH uuids, across the families that actually accumulated
        // on the founder's device.
        //
        // The suffix is LOWERCASED because that is the only form production
        // writes (`RemoteAgentRef.rawString` and the `Constants.custom*Key(for:)`
        // family all call `.lowercased()`), while `UUID.uuidString` is uppercase.
        // Seeding the uppercase form here made this test agree with a sweep that
        // compared cases raw — and therefore classified every LIVE gateway as an
        // orphan. Assert against the bytes on disk, not against a convenience.
        for uuid in [live, dead] {
            let suffix = uuid.uuidString.lowercased()
            defaults.set("https://\(suffix).example.test", forKey: "remoteAgent.url.custom_\(suffix)")
            defaults.set(true, forKey: "fileServer.available.custom_\(suffix)")
            defaults.set("recent", forKey: "imageHistory.policy.custom_\(suffix)")
            kvs.set(true, forKey: "fileServer.available.custom_\(suffix)")
        }
        // Cross-check: the literals above are exactly what production builds.
        XCTAssertEqual(Constants.remoteAgentURLKey(for: .custom(live)),
                       "remoteAgent.url.custom_\(live.uuidString.lowercased())",
                       "Key literal drifted from the production builder — the rest of this test would prove nothing.")
        // A built-in slot must never be in scope for the sweep.
        defaults.set("https://gateway.example.test", forKey: openclawURLKey)
        kvs.set("https://gateway.example.test", forKey: openclawURLKey)

        let manager = makeManager(defaults: defaults, kvs: kvs)
        await manager.performInitialSync()

        let deadSuffix = dead.uuidString.lowercased()
        let liveSuffix = live.uuidString.lowercased()
        for key in [
            "remoteAgent.url.custom_\(deadSuffix)",
            "fileServer.available.custom_\(deadSuffix)",
            "imageHistory.policy.custom_\(deadSuffix)"
        ] {
            XCTAssertNil(defaults.object(forKey: key), "Off-roster slot \(key) must be pruned from defaults.")
            XCTAssertNil(kvs.object(forKey: key), "…and from KVS, or the next sync re-hydrates it.")
        }

        XCTAssertEqual(defaults.string(forKey: "remoteAgent.url.custom_\(liveSuffix)"),
                       "https://\(liveSuffix).example.test",
                       "An ON-ROSTER gateway's slots must survive — a sweep that eats live config is worse than the orphans.")
        XCTAssertEqual(defaults.object(forKey: "fileServer.available.custom_\(liveSuffix)") as? Bool, true)
        XCTAssertEqual(defaults.string(forKey: "imageHistory.policy.custom_\(liveSuffix)"), "recent",
                       "Every family of the live gateway survives, not just the URL.")
        XCTAssertEqual(defaults.string(forKey: openclawURLKey), "https://gateway.example.test",
                       "Built-in suffixes carry no uuid and are never swept.")
    }

    func testOrphanSweepRunsOnceThenLatches() async {
        let dead = UUID()
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()
        let orphanKey = "remoteAgent.url.custom_\(dead.uuidString.lowercased())"
        defaults.set("https://dead.example.test", forKey: orphanKey)

        let manager = makeManager(defaults: defaults, kvs: kvs)
        await manager.performInitialSync()
        XCTAssertNil(defaults.object(forKey: orphanKey), "First run prunes.")
        XCTAssertEqual(defaults.integer(forKey: Constants.orphanSweepVersionKey),
                       Constants.orphanSweepVersion,
                       "…and records the revision it ran.")

        // A slot written AFTER the sweep latched is left alone — the sweep is a
        // one-time reconciliation, not a garbage collector running every launch.
        defaults.set("https://written-later.example.test", forKey: orphanKey)
        await manager.performInitialSync()
        XCTAssertEqual(defaults.string(forKey: orphanKey), "https://written-later.example.test",
                       "The version latch must hold — re-sweeping every launch would race live writes.")
    }

    /// Regression: the sweep once built its roster from `UUID.uuidString`
    /// (uppercase) and compared it against key suffixes production writes
    /// LOWERCASED, so `!roster.contains(suffix)` was true for every gateway —
    /// the sweep deleted the user's entire live configuration off every device
    /// and left the roster JSON pointing at nothing. Keys here are built by the
    /// PRODUCTION helpers, so a case regression cannot hide behind a fixture.
    func testSweepSparesLiveGatewayKeysBuiltByProductionHelpers() async throws {
        let live = UUID()
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()

        let rosterData = try JSONEncoder().encode([CustomGateway(id: live, name: "Live")])
        defaults.set(rosterData, forKey: gatewayRosterKey)
        kvs.set(rosterData, forKey: gatewayRosterKey)

        let ref = RemoteAgentRef.custom(live)
        let productionKeys = [
            Constants.remoteAgentURLKey(for: ref),
            Constants.remoteAgentAuthSchemeKey(for: ref),
            Constants.remoteAgentModelKey(for: ref),
            Constants.remoteAgentTransportHintKey(for: ref),
            Constants.imageHistoryPolicyKey(for: ref),
            Constants.fileServerURLKey(for: ref),
            Constants.fileTransferAvailableKey(for: ref),
            Constants.fileServerFolderCapableKey(for: ref)
        ]
        for key in productionKeys { defaults.set("live-value", forKey: key) }

        let manager = makeManager(defaults: defaults, kvs: kvs)
        await manager.performInitialSync()

        for key in productionKeys {
            XCTAssertEqual(defaults.string(forKey: key), "live-value",
                           "\(key) belongs to an ON-ROSTER gateway and must survive the sweep.")
        }
    }

    /// Regression: the default-pointer self-heal once tested
    /// `configuredRemoteAgentRefs()`, which fails CLOSED on a nil token — and
    /// nil means "no token OR the Keychain read failed". Secrets are
    /// `kSecAttrAccessibleAfterFirstUnlock`, so a headless capture before the
    /// first unlock reads every gateway as unconfigured; healing on that verdict
    /// deletes the user's chosen default during a transient failure.
    func testDefaultRefSurvivesUnreadableToken() async {
        let defaults = InMemoryDefaultsStore()
        // URL + `.bearer` present, but the Keychain yields nothing — exactly a
        // locked-device read. `isRemoteAgentConfigured` is false here.
        defaults.set("https://hermes.example.test:8642", forKey: hermesURLKey)
        defaults.set("bearer", forKey: "remoteAgent.authScheme.hermes")
        defaults.set("hermes", forKey: defaultBackendKey)
        let manager = makeManager(defaults: defaults)

        let configured = await manager.configuredRemoteAgentRefs()
        XCTAssertFalse(configured.contains(.builtin(.hermes)),
                       "Precondition: a bearer ref with no readable token is fail-closed unconfigured.")

        let resolved = await manager.defaultRemoteAgentRef()

        XCTAssertEqual(resolved, .builtin(.hermes),
                       "A locked Keychain must not re-point the user's default at another gateway.")
        XCTAssertEqual(defaults.string(forKey: defaultBackendKey), "hermes",
                       "…and must not delete the stored pointer, which has no undo.")
    }

    /// Regression: `deleteCustomGateway` cleared the gateway slots but left the
    /// whole `fileServer.*` family behind, and the sweep that would have
    /// collected them latches after one run — so every gateway deleted
    /// afterwards leaked the same keys permanently. That is how 135 orphan
    /// `fileServer.available.custom_*` keys accumulated against a cap of 5.
    func testDeleteCustomGatewayCollectsItsOwnFileServerSlots() async throws {
        let doomed = UUID()
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()

        let rosterData = try JSONEncoder().encode([CustomGateway(id: doomed, name: "Doomed")])
        defaults.set(rosterData, forKey: gatewayRosterKey)

        let ref = RemoteAgentRef.custom(doomed)
        let slots = [
            Constants.remoteAgentURLKey(for: ref),
            Constants.remoteAgentTransportHintKey(for: ref),
            Constants.imageHistoryPolicyKey(for: ref),
            Constants.fileServerURLKey(for: ref),
            Constants.fileTransferAvailableKey(for: ref),
            Constants.fileServerFolderCapableKey(for: ref),
            Constants.fileServerTestedLocallyKey(for: ref),
            Constants.fileServerFolderProbeRevisionKey(for: ref)
        ]
        for key in slots {
            defaults.set("value", forKey: key)
            kvs.set("value", forKey: key)
        }

        // Latch the sweep first, so this proves the DELETE collects the litter
        // rather than a sweep quietly covering for it.
        defaults.set(Constants.orphanSweepVersion, forKey: Constants.orphanSweepVersionKey)

        let manager = makeManager(defaults: defaults, kvs: kvs)
        await manager.deleteCustomGateway(id: doomed)

        for key in slots {
            XCTAssertNil(defaults.object(forKey: key), "\(key) must not outlive the gateway it belongs to.")
            XCTAssertNil(kvs.object(forKey: key), "…in BOTH stores, or a peer re-hydrates the orphan.")
        }
    }

    func testOrphanSweepSkippedWhileICloudUnavailable() async {
        let dead = UUID()
        let defaults = InMemoryDefaultsStore()
        let orphanKey = "remoteAgent.url.custom_\(dead.uuidString.lowercased())"
        defaults.set("https://dead.example.test", forKey: orphanKey)

        // Signed out: this device cannot see the cloud roster, so it must not
        // prune against a partial view.
        let manager = makeManager(defaults: defaults, cloudAvailable: false)
        await manager.performInitialSync()

        XCTAssertEqual(defaults.string(forKey: orphanKey), "https://dead.example.test",
                       "A device that can't read the cloud roster must not decide what is an orphan.")
        XCTAssertEqual(defaults.integer(forKey: Constants.orphanSweepVersionKey), 0,
                       "…and must not latch, so the sweep still runs once iCloud returns.")
    }
}
