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

        let removable = await manager.removableRemoteAgentRefs()
        XCTAssertTrue(removable.contains(.builtin(.openclaw)),
                      "removableRemoteAgentRefs drives the editor's Forget button; it must include the partial.")

        let partial = await manager.partiallyConfiguredRemoteAgentRefs()
        XCTAssertEqual(partial, [.builtin(.openclaw)],
                       "The Diagnostics row and the Forget gate must agree about this gateway — "
                       + "incomplete implies removable (see RemoteAgentInventoryTests).")
    }

    func testUnconfiguredGatewayWithNoStoredStateIsNotEvidence() async {
        let manager = makeManager()
        let removable = await manager.removableRemoteAgentRefs()
        XCTAssertTrue(removable.isEmpty,
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

    /// ONLY A CUSTOM REF CAN DANGLE. The self-heal exists for a pointer at a
    /// gateway that stopped existing — which only a custom can do.
    func testDefaultRefDropsDanglingCustomPointer() async {
        let defaults = InMemoryDefaultsStore()
        // A pointer at a custom with no roster entry and no config behind it —
        // what a Forget on another device leaves.
        defaults.set(RemoteAgentRef.custom(UUID()).rawString, forKey: defaultBackendKey)
        let manager = makeManager(defaults: defaults)

        let resolved = await manager.defaultRemoteAgentRef()

        XCTAssertNil(defaults.string(forKey: defaultBackendKey),
                     "The dangling pointer must be dropped, not just ignored on this read.")
        XCTAssertEqual(resolved, .builtin(Constants.remoteAgentDefaultBackendDefault),
                       "With nothing configured, resolution falls through to the built-in default.")
    }

    /// A BUILT-IN pointer is never dangling, so it survives with no config
    /// behind it. This is a deliberate contract, not an oversight: built-ins
    /// cannot be deleted, so an unconfigured one means "set this up", and
    /// `deleteCustomGateway` RELIES on it — it re-points at a built-in precisely
    /// so the user picks their next gateway. Healing that fresh pointer sent the
    /// adopt-first bootstrap to the surviving custom instead, silently moving
    /// every subsequent message to a different server.
    func testDefaultRefKeepsAnUnconfiguredBuiltInPointer() async {
        let defaults = InMemoryDefaultsStore()
        defaults.set("hermes", forKey: defaultBackendKey)
        let manager = makeManager(defaults: defaults)

        let resolved = await manager.defaultRemoteAgentRef()

        XCTAssertEqual(resolved, .builtin(.hermes),
                       "An explicitly chosen built-in must not be silently swapped for another.")
        XCTAssertEqual(defaults.string(forKey: defaultBackendKey), "hermes",
                       "…and the pointer stays put; nothing about it is stale.")
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

    // MARK: - 5. Per-uuid slots are NEVER deleted by a roster comparison

    /// THE CONTRACT: `performInitialSync` hydrates, it does not collect.
    ///
    /// An earlier revision swept every per-uuid key whose uuid was absent from
    /// the roster, out of BOTH stores. Both roster readers are FAIL-OPEN — a
    /// `try?` decode failure and "nothing stored anywhere yet" each surface as
    /// `[]`, indistinguishable from "this user has no gateways" — so that sweep
    /// could delete a user's entire gateway configuration off every device on
    /// evidence it never had, with no journal and no undo. Losing the roster
    /// alone is RECOVERABLE: the slots outlive it and come back with it. These
    /// two tests exist to keep deletion out of the launch path entirely.
    func testInitialSyncNeverDeletesOffRosterSlots() async throws {
        let live = UUID()
        let orphan = UUID()
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()

        let rosterData = try JSONEncoder().encode([CustomGateway(id: live, name: "Live")])
        defaults.set(rosterData, forKey: gatewayRosterKey)
        kvs.set(rosterData, forKey: gatewayRosterKey)

        // `orphan` is absent from the roster — the exact input the old sweep
        // deleted on. It must survive: an absent roster entry is not proof the
        // slot is garbage, only that this device cannot currently see its owner.
        for uuid in [live, orphan] {
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
        defaults.set("https://gateway.example.test", forKey: openclawURLKey)

        let manager = makeManager(defaults: defaults, kvs: kvs)
        await manager.performInitialSync()

        for uuid in [live, orphan] {
            let suffix = uuid.uuidString.lowercased()
            XCTAssertEqual(defaults.string(forKey: "remoteAgent.url.custom_\(suffix)"),
                           "https://\(suffix).example.test",
                           "Launch must never delete a per-uuid slot — on-roster or not.")
            XCTAssertEqual(defaults.object(forKey: "fileServer.available.custom_\(suffix)") as? Bool, true)
            XCTAssertEqual(defaults.string(forKey: "imageHistory.policy.custom_\(suffix)"), "recent")
            XCTAssertEqual(kvs.object(forKey: "fileServer.available.custom_\(suffix)") as? Bool, true,
                           "…and must never delete from KVS, where it would propagate to every device.")
        }
        XCTAssertEqual(defaults.string(forKey: openclawURLKey), "https://gateway.example.test")
    }

    /// The fail-open case, stated on its own because it is the one that fires
    /// without any user or sync mistake: one malformed record, or a roster
    /// written by a newer build, and every reader returns `[]`.
    func testInitialSyncNeverDeletesSlotsWhenRosterIsUndecodable() async {
        let gateway = UUID()
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()

        let garbage = Data("{not json at all".utf8)
        defaults.set(garbage, forKey: gatewayRosterKey)
        kvs.set(garbage, forKey: gatewayRosterKey)

        let suffix = gateway.uuidString.lowercased()
        let urlKey = "remoteAgent.url.custom_\(suffix)"
        defaults.set("https://live.example.test", forKey: urlKey)
        kvs.set("https://live.example.test", forKey: urlKey)

        let manager = makeManager(defaults: defaults, kvs: kvs)
        await manager.performInitialSync()

        XCTAssertEqual(defaults.string(forKey: urlKey), "https://live.example.test",
                       "An undecodable roster means UNKNOWN, never zero gateways.")
        XCTAssertEqual(kvs.string(forKey: urlKey), "https://live.example.test",
                       "…and above all must not delete from the store that syncs.")
    }

    /// Regression: `deleteCustomGateway` promises the default falls back to a
    /// BUILT-IN, "never silently to another custom". The pointer self-heal made
    /// that dead code — every clear in the delete strips this ref's evidence, so
    /// asking `defaultRemoteAgentRef()` afterwards already returned some other
    /// gateway and the `== ref` test could never fire.
    func testDeletingTheDefaultCustomFallsBackToABuiltInNotAnotherCustom() async throws {
        let doomed = UUID()
        let sibling = UUID()
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()

        let rosterData = try JSONEncoder().encode([
            CustomGateway(id: doomed, name: "Doomed"),
            CustomGateway(id: sibling, name: "Sibling")
        ])
        defaults.set(rosterData, forKey: gatewayRosterKey)

        // Both keyless, so both are CONFIGURED without a Keychain token — the
        // sibling has to be genuinely configured or the bug cannot reproduce.
        for uuid in [doomed, sibling] {
            let ref = RemoteAgentRef.custom(uuid)
            defaults.set("https://\(uuid.uuidString.lowercased()).example.test",
                         forKey: Constants.remoteAgentURLKey(for: ref))
            defaults.set("none", forKey: Constants.remoteAgentAuthSchemeKey(for: ref))
        }
        defaults.set(RemoteAgentRef.custom(doomed).rawString,
                     forKey: Constants.remoteAgentDefaultBackendKVSKey)

        let manager = makeManager(defaults: defaults, kvs: kvs)
        await manager.deleteCustomGateway(id: doomed)

        let resolved = await manager.defaultRemoteAgentRef()
        XCTAssertNotEqual(resolved, .custom(sibling),
                          "Forgetting the default gateway must not silently re-point at another custom.")
        XCTAssertTrue(resolved.isBuiltin,
                      "The documented fallback is the first configured BUILT-IN, else the built-in default.")
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

        // The delete is the ONLY collector — nothing sweeps for orphans — so
        // every family it misses leaks forever.
        let manager = makeManager(defaults: defaults, kvs: kvs)
        await manager.deleteCustomGateway(id: doomed)

        for key in slots {
            XCTAssertNil(defaults.object(forKey: key), "\(key) must not outlive the gateway it belongs to.")
            XCTAssertNil(kvs.object(forKey: key), "…in BOTH stores, or a peer re-hydrates the orphan.")
        }
    }

    // MARK: - 6. A peer's Forget retires the DEFAULT pointer too

    // The gap the local paths leave: `clearRemoteAgent` re-points the default when
    // the user forgets a gateway HERE, and `deleteCustomGateway` does the same for
    // a custom — but a peer's Forget arrives as bare key removals, so the pointer
    // stayed on a built-in with nothing behind it, which `defaultRemoteAgentRef()`
    // honours forever by design.

    private let openclawAuthKey = "remoteAgent.authScheme.openclaw"
    private let hermesAuthKey = "remoteAgent.authScheme.hermes"
    private let openclawCertKey = "remoteAgent.certFingerprint.openclaw"
    private let activeConversationIDKey = "remoteAgent.activeConversationID"

    /// Keyless (`.none` + URL) so the gateway is send-able without a Keychain
    /// write — the suite runs unsigned, and the point here is the pointer, not
    /// token storage.
    private func seedKeylessGateway(_ defaults: InMemoryDefaultsStore, urlKey: String, authKey: String) {
        defaults.set("https://gateway.example.test", forKey: urlKey)
        defaults.set(RemoteAgentAuthScheme.none.rawValue, forKey: authKey)
    }

    func testPeerForgetOfTheDefaultBuiltInDropsThePointer() async {
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()
        seedKeylessGateway(defaults, urlKey: openclawURLKey, authKey: openclawAuthKey)
        seedKeylessGateway(defaults, urlKey: hermesURLKey, authKey: hermesAuthKey)
        defaults.set("openclaw", forKey: defaultBackendKey)
        // The LEGACY synced copy, from before the default went device-local.
        // Nothing ever removes it, and the one-time migration seeds an absent
        // local pointer from it — so a drop that leaves that migration pending
        // hands the dead gateway straight back and can never be re-detected.
        kvs.set("openclaw", forKey: defaultBackendKey)
        let manager = makeManager(defaults: defaults, kvs: kvs)

        // The peer's Forget: OpenClaw's sync-owned slots are gone from KVS, and
        // their removal is what arrives here.
        await manager.handleICloudChange(
            KVSChange(reason: .serverChange, changedKeys: [openclawURLKey, openclawAuthKey])
        )

        XCTAssertNil(defaults.string(forKey: defaultBackendKey),
                     "The pointer names a gateway that no longer exists — dropped, exactly as a dangling CUSTOM pointer is.")

        // …and the legacy KVS fossil is not seeded back in over the drop. Note
        // WHY, because it is not this case's send-ability guard: the local pointer
        // was still present when `handleICloudChange` settled the device-local
        // migration, so it took its local-wins arm and burned the one-shot before
        // the drop. Arm 2's guard is covered separately, by the cases in §6 that
        // start from a device with no local pointer at all.
        //
        // What this case locks is the verdict on the other side of the drop. The
        // resolver ASKS rather than guessing: nothing is stored, so it offers
        // the survivor as a candidate and persists nothing. (The old expectation
        // here was that a config-sync bootstrap silently adopted Hermes. That
        // bootstrap is deleted on purpose — a pointer the device invented is
        // indistinguishable one launch later from one the user chose, and only the
        // user can tell them apart. Hermes is keyless here, so nothing proves the
        // Keychain readable either, which is the second reason adoption is
        // refused.)
        let resolution = await manager.resolveDefaultGateway()
        XCTAssertEqual(resolution, .selectionRequired(candidates: [.builtin(.hermes)]))
        XCTAssertNil(defaults.string(forKey: defaultBackendKey),
                     "Resolving must persist nothing here — least of all the fossil the drop just removed.")
    }

    /// The shape the built-ins-only version of this fix got wrong: a user whose
    /// surviving gateways are all CUSTOM. A survivor that is a custom must be
    /// treated exactly like a survivor that is a built-in — the outcome must not
    /// depend on which kind of gateway happened to live through the Forget.
    ///
    /// "Treated the same" now means OFFERED, not promoted: the pointer is dropped
    /// and the custom appears as the candidate the user is asked to pick. The old
    /// expectation — silent promotion — was the unannounced guess this whole
    /// design deletes; a headless capture no longer dead-ends on it either,
    /// because it is refused with a named 74 instead of minting onto a gateway
    /// that cannot answer.
    func testPeerForgetHealsWhenOnlyCustomGatewaysSurvive() async throws {
        let survivor = UUID()
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()
        seedKeylessGateway(defaults, urlKey: openclawURLKey, authKey: openclawAuthKey)
        defaults.set("openclaw", forKey: defaultBackendKey)

        let ref = RemoteAgentRef.custom(survivor)
        defaults.set(try JSONEncoder().encode([CustomGateway(id: survivor, name: "Work")]),
                     forKey: gatewayRosterKey)
        seedKeylessGateway(defaults,
                           urlKey: Constants.remoteAgentURLKey(for: ref),
                           authKey: Constants.remoteAgentAuthSchemeKey(for: ref))
        let manager = makeManager(defaults: defaults, kvs: kvs)

        await manager.handleICloudChange(
            KVSChange(reason: .serverChange, changedKeys: [openclawURLKey, openclawAuthKey])
        )

        XCTAssertNil(defaults.string(forKey: defaultBackendKey),
                     "The pointer names a built-in the peer forgot — dropped here too.")

        let resolution = await manager.resolveDefaultGateway()
        XCTAssertEqual(resolution, .selectionRequired(candidates: [ref]),
                       "A surviving CUSTOM is a candidate exactly as a surviving built-in is — "
                       + "the user is asked, and nothing is written on their behalf.")
        XCTAssertNil(defaults.string(forKey: defaultBackendKey),
                     "…and asking persists nothing.")
    }

    func testInitialSyncDoesNotRepointTheDefault() async {
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()
        seedKeylessGateway(defaults, urlKey: openclawURLKey, authKey: openclawAuthKey)
        seedKeylessGateway(defaults, urlKey: hermesURLKey, authKey: hermesAuthKey)
        defaults.set("openclaw", forKey: defaultBackendKey)
        let manager = makeManager(defaults: defaults, kvs: kvs)

        await manager.handleICloudChange(
            KVSChange(reason: .initialSyncChange, changedKeys: [openclawURLKey, openclawAuthKey])
        )

        XCTAssertEqual(defaults.string(forKey: defaultBackendKey), "openclaw",
                       "An initial sync can deliver state OLDER than this device's own setup — "
                       + "indistinguishable from a deletion, and re-pointing has no undo.")
    }

    /// Regression guard for the predicate choice. A certificate pin is DEVICE-LOCAL
    /// and never syncs away, so testing the transition with the broad
    /// `hasStoredRemoteAgentEvidence` would leave anyone who ever pinned a cert for
    /// that gateway permanently un-healable — the evidence can never disappear.
    func testLingeringLocalCertDoesNotMaskThePeerForget() async {
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()
        seedKeylessGateway(defaults, urlKey: openclawURLKey, authKey: openclawAuthKey)
        defaults.set("AA:BB:CC", forKey: openclawCertKey)
        seedKeylessGateway(defaults, urlKey: hermesURLKey, authKey: hermesAuthKey)
        defaults.set("openclaw", forKey: defaultBackendKey)
        let manager = makeManager(defaults: defaults, kvs: kvs)

        await manager.handleICloudChange(
            KVSChange(reason: .serverChange, changedKeys: [openclawURLKey, openclawAuthKey])
        )

        XCTAssertNil(defaults.string(forKey: defaultBackendKey),
                     "The pin is local residue, not proof the gateway still exists.")
    }

    /// Choosing a replacement AT THIS INSTANT would key on the send-ability
    /// predicate, which fails closed on an unreadable Keychain — one locked-device
    /// moment would consume the one-shot transition and strand the pointer for
    /// good. Dropping the key instead defers the choice to the lazy bootstrap,
    /// which re-runs on every read and therefore settles once secrets unlock.
    func testHealSurvivesAKeychainThatIsUnreadableAtChangeTime() async {
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()
        seedKeylessGateway(defaults, urlKey: openclawURLKey, authKey: openclawAuthKey)
        // Hermes is `.bearer` with no readable token — a locked device reads it as
        // unconfigured, so it is NOT an eligible replacement at this instant.
        defaults.set("https://hermes.example.test:8642", forKey: hermesURLKey)
        defaults.set(RemoteAgentAuthScheme.bearer.rawValue, forKey: hermesAuthKey)
        defaults.set("openclaw", forKey: defaultBackendKey)
        let manager = makeManager(defaults: defaults, kvs: kvs)

        let configured = await manager.configuredRemoteAgentRefs()
        XCTAssertFalse(configured.contains(.builtin(.hermes)),
                       "Precondition: the only survivor is fail-closed unconfigured right now.")

        await manager.handleICloudChange(
            KVSChange(reason: .serverChange, changedKeys: [openclawURLKey, openclawAuthKey])
        )

        XCTAssertNil(defaults.string(forKey: defaultBackendKey),
                     "The pointer is dropped regardless — the deletion is proven, and nothing re-detects it later.")
    }

    /// The active-conversation pointer goes with the default: the thread it names
    /// is bound to a gateway that no longer exists, and a survivor could silently
    /// continue that thread if the built-in is later set up against a DIFFERENT
    /// server.
    func testPeerForgetOfTheDefaultClearsTheSessionPointer() async {
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()
        seedKeylessGateway(defaults, urlKey: openclawURLKey, authKey: openclawAuthKey)
        defaults.set("openclaw", forKey: defaultBackendKey)
        defaults.set(UUID().uuidString, forKey: activeConversationIDKey)
        let manager = makeManager(defaults: defaults, kvs: kvs)

        await manager.handleICloudChange(
            KVSChange(reason: .serverChange, changedKeys: [openclawURLKey, openclawAuthKey])
        )

        XCTAssertNil(defaults.string(forKey: activeConversationIDKey),
                     "A live pointer into a deleted gateway's thread must not outlive it.")
    }

    /// A pointer that is undefined the whole way through is a restore still
    /// downloading, not a deletion. Only a present-before/absent-after TRANSITION
    /// counts — the same rule the last-used retire already follows.
    func testPointerWithNoDefinitionEitherSideIsLeftAlone() async {
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()
        seedKeylessGateway(defaults, urlKey: hermesURLKey, authKey: hermesAuthKey)
        defaults.set("openclaw", forKey: defaultBackendKey)   // never configured here
        let activeID = UUID().uuidString
        defaults.set(activeID, forKey: activeConversationIDKey)
        let manager = makeManager(defaults: defaults, kvs: kvs)

        await manager.handleICloudChange(
            KVSChange(reason: .serverChange, changedKeys: [openclawURLKey])
        )

        XCTAssertEqual(defaults.string(forKey: defaultBackendKey), "openclaw",
                       "Nothing was deleted — this is the deliberate 'set this up' pointer.")
        XCTAssertEqual(defaults.string(forKey: activeConversationIDKey), activeID,
                       "…so nothing may be cleared either.")
    }

    /// Forgetting a NON-default gateway must not move the pointer.
    func testPeerForgetOfANonDefaultBuiltInLeavesTheDefaultAlone() async {
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()
        seedKeylessGateway(defaults, urlKey: openclawURLKey, authKey: openclawAuthKey)
        seedKeylessGateway(defaults, urlKey: hermesURLKey, authKey: hermesAuthKey)
        defaults.set("openclaw", forKey: defaultBackendKey)
        let manager = makeManager(defaults: defaults, kvs: kvs)

        await manager.handleICloudChange(
            KVSChange(reason: .serverChange, changedKeys: [hermesURLKey, hermesAuthKey])
        )

        XCTAssertEqual(defaults.string(forKey: defaultBackendKey), "openclaw",
                       "The default still works; a sibling's deletion is not its business.")
    }

    // MARK: - 6. The legacy default seed inherits only a gateway that can SEND

    // Nothing ever deletes the legacy synced default from iCloud KVS, so every
    // fresh install on the account inherits whatever some device chose some time
    // ago — including a gateway nobody has set up since. That fossil is how a
    // restored device comes back pointing at a dead gateway beside working ones,
    // and how the pointer then survives forever (arm 1 wins on every later
    // launch). The send-ability guard on arm 2 is the whole fix, so it needs a
    // case that actually REACHES arm 2.
    //
    // Reaching it is the subtle part: whenever a local pointer is present, arm 1
    // settles first and burns the one-shot flag, and every sibling case above
    // stages a local pointer. These start from a fresh `InMemoryDefaultsStore`
    // with NO local pointer and no flag, which is the restored-install shape.

    /// The migration flag key, pinned as a literal for the same reason every other
    /// key in this file is: a rename that would silently re-run a one-shot
    /// migration on real devices must break a test, not pass quietly.
    private var deviceLocalMigratedKey: String { "remoteAgentDefaultBackendDeviceLocalMigrated" }

    func testTheLegacyFossilIsRefusedWhenItsGatewayCannotSend() async {
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()
        // The fossil names OpenClaw, which has nothing behind it on this device.
        kvs.set("openclaw", forKey: defaultBackendKey)
        // …beside a gateway that genuinely works. This is the founder's iPad.
        seedKeylessGateway(defaults, urlKey: hermesURLKey, authKey: hermesAuthKey)
        let manager = makeManager(defaults: defaults, kvs: kvs)

        let resolution = await manager.resolveDefaultGateway()

        XCTAssertNil(defaults.string(forKey: defaultBackendKey),
                     "A pointer that cannot send is worth less than no pointer at all — nothing is DELETED on this path, so send-ability is the right bar.")
        XCTAssertEqual(resolution, .selectionRequired(candidates: [.builtin(.hermes)]),
                       "Refusing the fossil degrades to asking the user, which is the designed behaviour.")
        XCTAssertFalse(defaults.bool(forKey: deviceLocalMigratedKey),
                       "An inconclusive read must leave the one-shot UNSET, or a token that arrives later can never be honoured.")
    }

    /// The control that keeps the case above from passing vacuously: the same
    /// shape with a fossil that CAN send is inherited, exactly as it always was.
    func testTheLegacyFossilIsInheritedWhenItsGatewayCanSend() async {
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()
        kvs.set("openclaw", forKey: defaultBackendKey)
        seedKeylessGateway(defaults, urlKey: openclawURLKey, authKey: openclawAuthKey)
        seedKeylessGateway(defaults, urlKey: hermesURLKey, authKey: hermesAuthKey)
        let manager = makeManager(defaults: defaults, kvs: kvs)

        let resolution = await manager.resolveDefaultGateway()

        XCTAssertEqual(defaults.string(forKey: defaultBackendKey), "openclaw",
                       "The guard narrows arm 2; it must not disable it. A working fossil IS the user's own earlier choice.")
        XCTAssertTrue(defaults.bool(forKey: deviceLocalMigratedKey),
                      "A conclusive outcome burns the one-shot.")
        XCTAssertEqual(resolution, .usable(.builtin(.openclaw)))
    }

    /// The deferred retry, which is the only reason refusing the fossil is safe.
    /// The in-process latch holds the migration to one attempt per launch — right
    /// for a migration, wrong for a seed that is WAITING for iCloud — so an
    /// inbound change re-arms it once the gateway becomes send-able.
    func testTheRefusedFossilIsSeededOnceItsGatewayArrives() async {
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()
        kvs.set("openclaw", forKey: defaultBackendKey)
        seedKeylessGateway(defaults, urlKey: hermesURLKey, authKey: hermesAuthKey)
        let manager = makeManager(defaults: defaults, kvs: kvs)

        _ = await manager.resolveDefaultGateway()
        XCTAssertNil(defaults.string(forKey: defaultBackendKey), "Precondition: the fossil was refused.")
        XCTAssertFalse(defaults.bool(forKey: deviceLocalMigratedKey),
                       "Precondition: the one-shot is still armed, which is what makes the retry possible.")

        // iCloud finishes delivering the gateway the fossil names. Seeded into
        // KVS, not `defaults`, because that IS the delivery: the inbound mirror
        // in `handleICloudChange` copies a changed key down from the cloud store,
        // and a value staged only locally would be removed by that same mirror as
        // an absence.
        kvs.set("https://gateway.example.test", forKey: openclawURLKey)
        kvs.set(RemoteAgentAuthScheme.none.rawValue, forKey: openclawAuthKey)
        await manager.handleICloudChange(
            KVSChange(reason: .initialSyncChange, changedKeys: [openclawURLKey, openclawAuthKey])
        )

        XCTAssertEqual(defaults.string(forKey: defaultBackendKey), "openclaw",
                       "The seed is retried on the bulk arrival it was waiting for — `.initialSyncChange` IS the fresh-install download.")
        XCTAssertTrue(defaults.bool(forKey: deviceLocalMigratedKey))
    }
}
