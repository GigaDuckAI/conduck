// Conduck
// RemoteAgentMigrationTests.swift
//
// Multi-gateway — the single-slot → per-backend migration
// (`SettingsManager.migrateRemoteAgentToPerBackend()`). Covers:
//   - fresh install (no legacy config) → flag set, no per-backend slots created
//   - legacy single-slot config → copied into the legacy backend's per-backend
//     slots + the default pointer promoted to that backend
//   - idempotency (a second run is a no-op once the flag is set)
//
// Migration runs against the `.shared` singleton via the
// `runRemoteAgentMigrationForTesting()` seam (the static singleton can't be
// reconstructed per test, and the in-process latch fires once per process —
// the seam resets it for a deterministic re-run).
//
// Signing gate: the legacy-token COPY exercises the Keychain (read legacy
// synchronizable item + `SecItemAdd` per-backend). On an unsigned headless
// build the access-group write needs the entitlement, so those assertions
// route through `setTokenOrSkip` / `XCTSkip`. The pure-UserDefaults parts
// (URL / cert / default pointer / fresh-install / idempotency) run unsigned.

import XCTest
@testable import Conduck

final class RemoteAgentMigrationTests: XCTestCase {

    private let defaults: UserDefaults = {
        UserDefaults(suiteName: Constants.appGroupID) ?? UserDefaults.standard
    }()

    override func setUp() async throws {
        try await super.setUp()
        await wipeAll()
    }

    override func tearDown() async throws {
        await wipeAll()
        try await super.tearDown()
    }

    /// Wipe legacy + per-backend slots AND the migration flag so each test runs
    /// a fresh migration pass.
    private func wipeAll() async {
        defaults.removeObject(forKey: Constants.remoteAgentMultiGatewayMigratedKey)
        defaults.removeObject(forKey: Constants.remoteAgentBackendKey)
        defaults.removeObject(forKey: Constants.remoteAgentURLKey)
        defaults.removeObject(forKey: Constants.remoteAgentCertFingerprintKey)
        defaults.removeObject(forKey: Constants.remoteAgentDefaultBackendKVSKey)
        try? await SettingsManager.shared.clearRemoteAgentToken()
        for backend in RemoteAgentBackend.allCases {
            defaults.removeObject(forKey: Constants.remoteAgentURLKey(for: backend))
            defaults.removeObject(forKey: Constants.remoteAgentCertFingerprintKey(for: backend))
            try? await SettingsManager.shared.clearRemoteAgentToken(for: backend)
        }
    }

    private func setLegacyTokenOrSkip(_ token: String) async throws {
        do {
            try await SettingsManager.shared.setRemoteAgentToken(token)
        } catch {
            throw XCTSkip("Keychain access-group write requires a signed build (unsigned: \(error)).")
        }
    }

    // MARK: - Fresh install

    func testFreshInstallSetsFlagWithoutCreatingPerBackendSlots() async {
        // No legacy backend configured.
        let flagSet = await SettingsManager.shared.runRemoteAgentMigrationForTesting()
        XCTAssertTrue(flagSet, "Fresh install must mark the migration flag so it never re-scans.")

        // No per-backend URL slot WRITTEN. Assert the stored slot directly, not
        // `getRemoteAgentURL(for:)`: hosted-model backends (OpenRouter) resolve to
        // a descriptor-fixed URL that is authoritative over any slot, so the
        // resolved getter is non-nil BY DESIGN even with no slot written. The
        // migration invariant is about the persisted slot, which must stay empty.
        for backend in RemoteAgentBackend.allCases {
            let storedSlot = defaults.string(forKey: Constants.remoteAgentURLKey(for: backend))
            XCTAssertNil(storedSlot, "Fresh install must not WRITE any per-backend URL slot (backend: \(backend.rawValue)).")
        }
    }

    // MARK: - Legacy → per-backend copy

    func testLegacyURLAndCertCopiedAndDefaultPromoted() async {
        // Seed a legacy single-slot config (Hermes), pure-UserDefaults parts.
        defaults.set(RemoteAgentBackend.hermes.rawValue, forKey: Constants.remoteAgentBackendKey)
        defaults.set("https://legacy.example.test:8642", forKey: Constants.remoteAgentURLKey)
        defaults.set("deadbeef", forKey: Constants.remoteAgentCertFingerprintKey)

        _ = await SettingsManager.shared.runRemoteAgentMigrationForTesting()

        // URL + cert copied into Hermes's per-backend slots.
        let hURL = await SettingsManager.shared.getRemoteAgentURL(for: .hermes)
        XCTAssertEqual(hURL?.absoluteString, "https://legacy.example.test:8642")
        let hCert = await SettingsManager.shared.getRemoteAgentCertFingerprint(for: .hermes)
        XCTAssertEqual(hCert, "deadbeef")

        // OpenClaw left untouched.
        let ocURL = await SettingsManager.shared.getRemoteAgentURL(for: .openclaw)
        XCTAssertNil(ocURL)

        // Default pointer promoted to the legacy backend.
        let def = await SettingsManager.shared.defaultRemoteAgentBackend()
        XCTAssertEqual(def, .hermes, "Migration must promote the legacy backend to the default pointer.")
    }

    func testLegacyTokenCopiedToPerBackendSlot() async throws {
        // Signing-gated: needs a real Keychain write.
        try await setLegacyTokenOrSkip("legacy-bearer")
        defaults.set(RemoteAgentBackend.openclaw.rawValue, forKey: Constants.remoteAgentBackendKey)
        defaults.set("https://legacy-oc.example.test:18789", forKey: Constants.remoteAgentURLKey)

        let flagSet = await SettingsManager.shared.runRemoteAgentMigrationForTesting()
        XCTAssertTrue(flagSet, "With a legacy token present, a successful copy must set the flag.")

        let ocToken = await SettingsManager.shared.getRemoteAgentToken(for: .openclaw)
        XCTAssertEqual(ocToken, "legacy-bearer",
                       "Legacy token must be copied into the per-backend slot.")

        // Legacy token is KEPT (Decision C — not deleted).
        let legacyToken = await SettingsManager.shared.getRemoteAgentToken()
        XCTAssertEqual(legacyToken, "legacy-bearer",
                       "Legacy token must be preserved (copy, not move) so a mid-migration second device isn't stranded.")
    }

    // MARK: - Idempotency

    func testSecondRunIsNoOp() async {
        // Simulate an ALREADY-migrated device: the persistent flag is set, and a
        // legacy single-slot config still sits in defaults (Decision C keeps it).
        // The per-backend slot holds a USER-EDITED value made after migration.
        // A re-run must early-return on the flag and NOT clobber that edit with
        // the stale legacy value.
        //
        // (This validates the flag-guard idempotency unsigned. The flag-being-set
        // path after a token copy is covered by the signing-gated
        // `testLegacyTokenCopiedToPerBackendSlot`; the no-token flag-set path by
        // `testFreshInstallSetsFlagWithoutCreatingPerBackendSlots`.)
        defaults.set(true, forKey: Constants.remoteAgentMultiGatewayMigratedKey)
        defaults.set(RemoteAgentBackend.hermes.rawValue, forKey: Constants.remoteAgentBackendKey)
        defaults.set("https://legacy.example.test:8642", forKey: Constants.remoteAgentURLKey)

        let userEditedURL = URL(string: "https://user-edited.example.test:9999")!
        await SettingsManager.shared.setRemoteAgentURL(userEditedURL, for: .hermes)

        let stillMigrated = await SettingsManager.shared.runRemoteAgentMigrationForTesting()
        XCTAssertTrue(stillMigrated, "Flag stays set on a no-op (already-migrated) re-run.")

        let hURL = await SettingsManager.shared.getRemoteAgentURL(for: .hermes)
        XCTAssertEqual(hURL, userEditedURL,
                       "A flag-guarded re-run must early-return — the stale legacy URL must not clobber the user-edited per-backend value.")
    }

    // NOTE: the locked-keychain partial-pass (token read fails → flag stays
    // unset → retried next launch) cannot be simulated headlessly without a
    // Keychain-locking seam — exercising it would require either physically
    // locking the device Keychain or injecting a SecItem failure, neither of
    // which is available in an XCTest unsigned run. Verified on the signed
    // founder-gate run; the flag-gating logic is unit-asserted indirectly by
    // `testLegacyTokenCopiedToPerBackendSlot` (flag set only after copy confirms)
    // and `testFreshInstallSetsFlagWithoutCreatingPerBackendSlots` (no-token path).
}
