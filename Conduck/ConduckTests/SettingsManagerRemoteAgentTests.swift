// Conduck
// SettingsManagerRemoteAgentTests.swift
//
// Settings: Personal AI. Covers the `SettingsManager` accessors
// + atomic snapshot + envelope composition for the Personal AI gateway.
// Mirrors STT-side `SettingsManager` coverage shape (notification posting
// + snapshot atomicity + envelope optionality).
//
// Test isolation: every test wipes the App Groups UserDefaults +
// Keychain slots in `setUp` so persisted state from a previous run
// can't leak in. The actor is a `static let shared` singleton so we
// can't construct a fresh instance per test — wiping is the alternative.
//
// Signing gate: the 3 token-write tests route through `setTokenOrSkip`,
// which `XCTSkip`s on an unsigned build (the access-group Keychain write
// needs the entitlement → only present on a signed run). Unsigned: skipped;
// signed founder-gate run: executed.

import XCTest
@testable import Conduck

final class SettingsManagerRemoteAgentTests: XCTestCase {

    /// App Groups UserDefaults — same suite the actor uses internally.
    private let defaults: UserDefaults = {
        UserDefaults(suiteName: Constants.appGroupID) ?? UserDefaults.standard
    }()

    override func setUp() async throws {
        try await super.setUp()
        await wipeRemoteAgentState()
    }

    override func tearDown() async throws {
        await wipeRemoteAgentState()
        try await super.tearDown()
    }

    /// Wipe persistent state for the remote-agent slots. Runs in setUp
    /// + tearDown so individual tests start from a clean slate without
    /// having to coordinate.
    private func wipeRemoteAgentState() async {
        defaults.removeObject(forKey: Constants.remoteAgentBackendKey)
        defaults.removeObject(forKey: Constants.remoteAgentURLKey)
        defaults.removeObject(forKey: Constants.remoteAgentCertFingerprintKey)
        defaults.removeObject(forKey: Constants.remoteAgentActiveSessionKey)
        try? await SettingsManager.shared.clearRemoteAgentToken()

        // Multi-gateway slots: default pointer + per-backend URL / cert / token.
        defaults.removeObject(forKey: Constants.remoteAgentDefaultBackendKVSKey)
        for backend in RemoteAgentBackend.allCases {
            defaults.removeObject(forKey: Constants.remoteAgentURLKey(for: backend))
            defaults.removeObject(forKey: Constants.remoteAgentCertFingerprintKey(for: backend))
            try? await SettingsManager.shared.clearRemoteAgentToken(for: backend)
        }

        // Test-isolation hazard fix: the single-slot → per-backend migration
        // (`migrateRemoteAgentToPerBackend()`) latches a PERSISTENT App-Group
        // flag (and an in-process latch). Once set in the sim plist, it survives
        // across tests AND across test-process runs, so a per-backend read
        // (e.g. `remoteAgentSnapshot()` → `defaultRemoteAgentBackend()`) would
        // skip re-evaluation. Clear BOTH so each test starts from a truly clean
        // migration state — mirrors `RemoteAgentMigrationTests.wipeAll()`.
        defaults.removeObject(forKey: Constants.remoteAgentMultiGatewayMigratedKey)
        await SettingsManager.shared.resetRemoteAgentMigrationLatchForTesting()
    }

    /// Per-backend token setter, skipping on an unsigned build (same posture as
    /// `setTokenOrSkip` — the access-group Keychain write needs the entitlement).
    private func setTokenOrSkip(_ token: String, for backend: RemoteAgentBackend) async throws {
        do {
            try await SettingsManager.shared.setRemoteAgentToken(token, for: backend)
        } catch {
            throw XCTSkip("Keychain access-group write requires a signed build (unsigned: \(error)).")
        }
    }

    /// Set the remote-agent token, skipping the test when the Keychain write
    /// fails. The token slot lives in an access-group Keychain item, which
    /// requires the `keychain-access-groups` entitlement — absent on an
    /// unsigned headless build (`CODE_SIGNING_ALLOWED=NO`), so `SecItemAdd`
    /// returns `errSecMissingEntitlement` (→ `settingsLoadFailed`). These
    /// token paths are verified on the signed founder-gate run; unsigned runs
    /// skip rather than red-flag a constraint they structurally cannot satisfy.
    private func setTokenOrSkip(_ token: String) async throws {
        do {
            try await SettingsManager.shared.setRemoteAgentToken(token)
        } catch {
            throw XCTSkip("Keychain access-group write requires a signed build (unsigned: \(error)).")
        }
    }

    // MARK: - Atomic snapshot

    func testSnapshotReturnsNilWhenBackendMissing() async {
        let snapshot = await SettingsManager.shared.remoteAgentSnapshot()
        XCTAssertNil(snapshot,
                     "Snapshot must be nil when backend not configured — the converse path treats nil as `.remoteAgentNotConfigured`.")
    }

    func testSnapshotReturnsNilWhenURLMissing() async {
        await SettingsManager.shared.setRemoteAgentBackend(.openclaw)
        let snapshot = await SettingsManager.shared.remoteAgentSnapshot()
        XCTAssertNil(snapshot,
                     "Snapshot must be nil when URL not configured (backend alone is not enough).")
    }

    func testSnapshotReturnsFullTupleAfterWrites() async throws {
        // Multi-gateway reality: the zero-arg `remoteAgentSnapshot()` forwards to
        // `remoteAgentSnapshot(for: defaultRemoteAgentBackend())`, which reads the
        // PER-BACKEND slots. Production writes config exclusively via the
        // per-backend setters (`validateAndSaveRemoteAgent`); the legacy
        // single-slot setters survive only for the migration to READ. So this
        // test writes the way the app actually stores config now: point the
        // default at OpenClaw + populate OpenClaw's per-backend URL / token / cert.
        let url = try XCTUnwrap(URL(string: "https://gateway.example.test:18789"))
        await SettingsManager.shared.setDefaultRemoteAgentBackend(.openclaw)
        await SettingsManager.shared.setRemoteAgentURL(url, for: .openclaw)
        try await setTokenOrSkip("bearer-snapshot-test", for: .openclaw)
        await SettingsManager.shared.setRemoteAgentCertFingerprint("DEADBEEF1234", for: .openclaw)
        await SettingsManager.shared.setRemoteAgentActiveSession("session-uuid-123")

        let snapshotOptional = await SettingsManager.shared.remoteAgentSnapshot()
        let snapshot = try XCTUnwrap(snapshotOptional,
                                     "Snapshot must surface a full tuple once backend + URL are configured.")
        XCTAssertEqual(snapshot.backend, .openclaw)
        XCTAssertEqual(snapshot.url, url)
        XCTAssertEqual(snapshot.token, "bearer-snapshot-test")
        XCTAssertEqual(snapshot.certFingerprintHex, "deadbeef1234",
                       "Fingerprint must be stored lowercase — the trust evaluator does a lowercased compare, persisting canonical-form keeps tests / debugging from drifting.")
        XCTAssertEqual(snapshot.activeSessionID, "session-uuid-123")
    }

    // MARK: - Envelope composition

    func testEnvelopeReturnsNilWhenBackendMissing() async {
        let envelope = await SettingsManager.shared.currentRemoteAgentEnvelope()
        XCTAssertNil(envelope,
                     "currentRemoteAgentEnvelope must be nil when backend is missing — PhoneSessionManager uses that signal to skip the transferUserInfo enqueue.")
    }

    func testEnvelopeReflectsConfiguredGateway() async throws {
        // `currentRemoteAgentEnvelope()` rides on the zero-arg snapshot, which
        // forwards to the default backend's PER-BACKEND slots (see
        // `testSnapshotReturnsFullTupleAfterWrites`). Write via the per-backend
        // API the app actually uses: default → OpenClaw + OpenClaw's URL / token.
        let url = try XCTUnwrap(URL(string: "https://gateway.example.test:8642"))
        await SettingsManager.shared.setDefaultRemoteAgentBackend(.openclaw)
        await SettingsManager.shared.setRemoteAgentURL(url, for: .openclaw)
        try await setTokenOrSkip("envelope-token", for: .openclaw)

        let envelopeOptional = await SettingsManager.shared.currentRemoteAgentEnvelope()
        let envelope = try XCTUnwrap(envelopeOptional)
        XCTAssertEqual(envelope.backendRef, "openclaw")
        XCTAssertEqual(envelope.url, url)
        XCTAssertEqual(envelope.token, "envelope-token")
        XCTAssertNil(envelope.certFingerprintHex,
                     "No fingerprint configured → envelope.certFingerprintHex must be nil, NOT empty string.")
        XCTAssertNil(envelope.activeSessionID,
                     "No active session → envelope.activeSessionID must be nil.")
        XCTAssertGreaterThan(envelope.timestamp, 0,
                             "Envelope timestamp must be a real monotonic value, not 0.")
    }

    // MARK: - Notification posting

    func testSetBackendPostsNotification() async {
        let expectation = XCTNSNotificationExpectation(name: .settingsDidChangeRemotely)
        await SettingsManager.shared.setRemoteAgentBackend(.openclaw)
        await fulfillment(of: [expectation], timeout: 1.0)
    }

    func testSetURLPostsNotification() async throws {
        let url = try XCTUnwrap(URL(string: "https://gateway.example.test"))
        let expectation = XCTNSNotificationExpectation(name: .settingsDidChangeRemotely)
        await SettingsManager.shared.setRemoteAgentURL(url)
        await fulfillment(of: [expectation], timeout: 1.0)
    }

    func testSetTokenPostsNotification() async throws {
        let expectation = XCTNSNotificationExpectation(name: .settingsDidChangeRemotely)
        try await setTokenOrSkip("trigger-broadcast-token")
        await fulfillment(of: [expectation], timeout: 1.0)
    }

    // MARK: - Multi-gateway: per-backend Keychain round-trip + isolation

    func testPerBackendTokensAreIsolated() async throws {
        try await setTokenOrSkip("token-openclaw", for: .openclaw)
        try await setTokenOrSkip("token-hermes", for: .hermes)

        let oc = await SettingsManager.shared.getRemoteAgentToken(for: .openclaw)
        let h = await SettingsManager.shared.getRemoteAgentToken(for: .hermes)
        XCTAssertEqual(oc, "token-openclaw")
        XCTAssertEqual(h, "token-hermes",
                       "Each backend's token lives in its own Keychain slot — writing one must not overwrite the other.")
    }

    func testClearingOneBackendLeavesTheOther() async throws {
        try await setTokenOrSkip("token-openclaw", for: .openclaw)
        try await setTokenOrSkip("token-hermes", for: .hermes)

        try await SettingsManager.shared.clearRemoteAgentToken(for: .openclaw)

        let oc = await SettingsManager.shared.getRemoteAgentToken(for: .openclaw)
        let h = await SettingsManager.shared.getRemoteAgentToken(for: .hermes)
        XCTAssertNil(oc, "Cleared backend's token must be gone.")
        XCTAssertEqual(h, "token-hermes", "Clearing one backend must not touch the other's token.")
    }

    func testPerBackendURLAndCertAreIsolated() async throws {
        let ocURL = try XCTUnwrap(URL(string: "https://openclaw.example.test:18789"))
        let hURL = try XCTUnwrap(URL(string: "https://hermes.example.test:8642"))
        await SettingsManager.shared.setRemoteAgentURL(ocURL, for: .openclaw)
        await SettingsManager.shared.setRemoteAgentURL(hURL, for: .hermes)
        await SettingsManager.shared.setRemoteAgentCertFingerprint("AABB", for: .openclaw)
        await SettingsManager.shared.setRemoteAgentCertFingerprint("CCDD", for: .hermes)

        let ocURLRead = await SettingsManager.shared.getRemoteAgentURL(for: .openclaw)
        let hURLRead = await SettingsManager.shared.getRemoteAgentURL(for: .hermes)
        XCTAssertEqual(ocURLRead, ocURL)
        XCTAssertEqual(hURLRead, hURL)

        let ocCert = await SettingsManager.shared.getRemoteAgentCertFingerprint(for: .openclaw)
        let hCert = await SettingsManager.shared.getRemoteAgentCertFingerprint(for: .hermes)
        XCTAssertEqual(ocCert, "aabb", "Cert must persist lowercase.")
        XCTAssertEqual(hCert, "ccdd")
    }

    // MARK: - Multi-gateway: default-backend pointer

    func testDefaultBackendFallsBackToOpenClawWhenUnset() async {
        let backend = await SettingsManager.shared.defaultRemoteAgentBackend()
        XCTAssertEqual(backend, .openclaw,
                       "With no stored default pointer, the default backend must be OpenClaw (the reference gateway).")
    }

    func testSetDefaultBackendDualWritesAndReadsDefaultsFirst() async {
        await SettingsManager.shared.setDefaultRemoteAgentBackend(.hermes)

        // App Groups defaults is the durable read source — confirm it holds the
        // value (read-defaults-first semantics, mirrors getActivePresetID).
        XCTAssertEqual(defaults.string(forKey: Constants.remoteAgentDefaultBackendKVSKey), "hermes")
        let backend = await SettingsManager.shared.defaultRemoteAgentBackend()
        XCTAssertEqual(backend, .hermes)
    }

    func testSetDefaultBackendNoOpWhenUnchanged() async {
        await SettingsManager.shared.setDefaultRemoteAgentBackend(.hermes)

        // A second identical set must NOT post a notification (no-op guard).
        let expectation = XCTNSNotificationExpectation(name: .settingsDidChangeRemotely)
        expectation.isInverted = true
        await SettingsManager.shared.setDefaultRemoteAgentBackend(.hermes)
        await fulfillment(of: [expectation], timeout: 0.5)
    }

    func testSetDefaultBackendPostsNotificationOnChange() async {
        let expectation = XCTNSNotificationExpectation(name: .settingsDidChangeRemotely)
        await SettingsManager.shared.setDefaultRemoteAgentBackend(.hermes)
        await fulfillment(of: [expectation], timeout: 1.0)
    }

    // MARK: - Multi-gateway: per-backend snapshot

    func testPerBackendSnapshotNilWhenURLMissing() async {
        let snapshot = await SettingsManager.shared.remoteAgentSnapshot(for: .hermes)
        XCTAssertNil(snapshot, "Per-backend snapshot must be nil when that backend's URL is missing.")
    }

    func testPerBackendSnapshotUsesGlobalActiveSession() async throws {
        let url = try XCTUnwrap(URL(string: "https://hermes.example.test:8642"))
        await SettingsManager.shared.setRemoteAgentURL(url, for: .hermes)
        await SettingsManager.shared.setRemoteAgentActiveSession("global-session-xyz")

        let snapshotOptional = await SettingsManager.shared.remoteAgentSnapshot(for: .hermes)
        let snapshot = try XCTUnwrap(snapshotOptional,
                                     "URL present → snapshot must surface (token is independently optional).")
        XCTAssertEqual(snapshot.backend, .hermes)
        XCTAssertEqual(snapshot.url, url)
        XCTAssertEqual(snapshot.activeSessionID, "global-session-xyz",
                       "activeSessionID must come from the GLOBAL session slot (pointer is not per-backend).")
    }

    // MARK: - Multi-gateway: configuredRemoteAgentBackends

    func testConfiguredBackendsEmptyWhenNothingSet() async {
        let configured = await SettingsManager.shared.configuredRemoteAgentBackends()
        XCTAssertTrue(configured.isEmpty, "No URL + no token → no configured backends.")
    }

    func testConfiguredBackendsRequiresTokenAndURL() async throws {
        let url = try XCTUnwrap(URL(string: "https://openclaw.example.test:18789"))
        await SettingsManager.shared.setRemoteAgentURL(url, for: .openclaw)
        try await setTokenOrSkip("oc-token", for: .openclaw)

        let configured = await SettingsManager.shared.configuredRemoteAgentBackends()
        XCTAssertEqual(configured, [.openclaw],
                       "A backend with BOTH token and URL is configured.")
    }

    func testConfiguredBackendsIgnoresTokenWithoutURL() async throws {
        // Token present but NO URL → half-state, must NOT be offered.
        try await setTokenOrSkip("oc-token", for: .openclaw)

        let configured = await SettingsManager.shared.configuredRemoteAgentBackends()
        XCTAssertFalse(configured.contains(.openclaw),
                       "A token without a URL is a half-state and must not count as configured.")
    }

    // MARK: - Stored-URL resolution (KVS fallback)
    //
    // `resolveStoredURL` is the pure core of `getRemoteAgentURL(for:)` /
    // `getRemoteAgentURL()`. It encodes the defaults-first-then-KVS-fallback
    // rule that lets the gateway URL survive a reinstall / hydrate on a fresh
    // device (the previous defaults-only read vanished on uninstall even though
    // the setter dual-writes to KVS). Pure + static so the `iCloudAvailable`
    // branch is testable headless — the live KVS path can't run unsigned.

    func testResolveStoredURLLocalWins() {
        let url = SettingsManager.resolveStoredURL(
            local: "https://local.example.test:18789",
            iCloud: "https://cloud.example.test:18789",
            iCloudAvailable: true
        )
        XCTAssertEqual(url?.absoluteString, "https://local.example.test:18789",
                       "Local App Groups value must win over iCloud when both are present.")
    }

    func testResolveStoredURLFallsBackToiCloudWhenLocalEmpty() {
        let url = SettingsManager.resolveStoredURL(
            local: nil,
            iCloud: "https://cloud.example.test:18789",
            iCloudAvailable: true
        )
        XCTAssertEqual(url?.absoluteString, "https://cloud.example.test:18789",
                       "With no local value, the iCloud KVS value must be used (the reinstall-restore path).")
    }

    func testResolveStoredURLIgnoresiCloudWhenUnavailable() {
        let url = SettingsManager.resolveStoredURL(
            local: nil,
            iCloud: "https://cloud.example.test:18789",
            iCloudAvailable: false
        )
        XCTAssertNil(url,
                     "iCloud value must be ignored when iCloud is unavailable (matches the `iCloudAvailable` guard on every other KVS read).")
    }

    func testResolveStoredURLEmptyStringIsNotAValue() {
        XCTAssertNil(SettingsManager.resolveStoredURL(local: "", iCloud: "", iCloudAvailable: true),
                     "Empty strings are not configured values — must yield nil, not an empty URL.")
        let url = SettingsManager.resolveStoredURL(
            local: "",
            iCloud: "https://cloud.example.test:18789",
            iCloudAvailable: true
        )
        XCTAssertEqual(url?.absoluteString, "https://cloud.example.test:18789",
                       "An empty local value must fall through to the iCloud value.")
    }

    func testResolveStoredURLBothNilYieldsNil() {
        XCTAssertNil(SettingsManager.resolveStoredURL(local: nil, iCloud: nil, iCloudAvailable: true),
                     "No stored value anywhere → not configured.")
    }

    // MARK: - Stored-URL read fence (`EndpointURLPolicy`)
    //
    // `resolveStoredURL` is the read fence for EVERY persisted endpoint URL —
    // gateway (legacy + per-ref), file server, and custom voice endpoint. The
    // write-side guards only bind THIS build; a value can still be sitting in
    // the store from before the policy existed, or arrive through iCloud KVS
    // from a peer device running an older build. The fence is what makes such a
    // value unrequestable regardless.

    func testResolveStoredURLRejectsUserinfoInLocalValue() {
        XCTAssertNil(
            SettingsManager.resolveStoredURL(
                local: "https://u:p@gw.example.test",
                iCloud: nil,
                iCloudAvailable: true
            ),
            "A stored `user:password@` URL must never resolve — that password is in App-Group defaults and iCloud KVS, and resolving it would also send it on the wire."
        )
    }

    func testResolveStoredURLRejectsUserinfoInICloudValue() {
        XCTAssertNil(
            SettingsManager.resolveStoredURL(
                local: nil,
                iCloud: "https://u:p@gw.example.test",
                iCloudAvailable: true
            ),
            "The KVS side is the version-skew path — a peer on an older build is exactly how a contaminated value arrives on an upgraded device."
        )
    }

    func testResolveStoredURLRejectsHostlessValue() {
        XCTAssertNil(
            SettingsManager.resolveStoredURL(local: "https://", iCloud: nil, iCloudAvailable: true),
            "`https://` parses but has no host — resolving it yields a gateway that reports itself configured and fails every request."
        )
        XCTAssertNil(
            SettingsManager.resolveStoredURL(local: "https:///v1", iCloud: nil, iCloudAvailable: true)
        )
    }

    func testResolveStoredURLRejectsNonHTTPSValue() {
        XCTAssertNil(
            SettingsManager.resolveStoredURL(local: "http://gw.example.test", iCloud: nil, iCloudAvailable: true),
            "https-only is a storage invariant, not just a save-time one."
        )
    }

    /// An inadmissible value must be SKIPPED, not terminal. A contaminated local
    /// slot masking a perfectly good synced one would turn a privacy fix into a
    /// config-loss bug on the device that happens to hold the bad copy.
    func testResolveStoredURLFallsThroughAContaminatedLocalToACleaniCloudValue() {
        let url = SettingsManager.resolveStoredURL(
            local: "https://u:p@gw.example.test",
            iCloud: "https://cloud.example.test:18789",
            iCloudAvailable: true
        )
        XCTAssertEqual(url?.absoluteString, "https://cloud.example.test:18789",
                       "A rejected local value must fall through to the iCloud value, exactly as an empty one does.")
    }

    func testResolveStoredURLCleanLocalStillWinsOverContaminatediCloud() {
        let url = SettingsManager.resolveStoredURL(
            local: "https://local.example.test:18789",
            iCloud: "https://u:p@gw.example.test",
            iCloudAvailable: true
        )
        XCTAssertEqual(url?.absoluteString, "https://local.example.test:18789",
                       "Defaults-first is unchanged; the fence only removes candidates, it never reorders them.")
    }

    func testResolveStoredURLBothSidesContaminatedYieldsNil() {
        XCTAssertNil(
            SettingsManager.resolveStoredURL(
                local: "https://u:p@gw.example.test",
                iCloud: "https://admin@gw.example.test",
                iCloudAvailable: true
            ),
            "With no admissible candidate anywhere the ref reads as not configured — the same state an upgraded peer reports, so the two devices agree."
        )
    }
}
