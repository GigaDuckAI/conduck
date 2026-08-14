// SPDX-License-Identifier: Apache-2.0

// Conduck
// SettingsViewModelPairingImportTests.swift
//
// Pairing-import lifecycle (`SettingsViewModel+PairingImport`): plan
// resolution (ready / overwrite-confirm / blocked), persist-only execute
// round-trips (gateway slots, transport hint, custom roster, keyless,
// file-server, default rule), and draft discard.
//
// Test isolation mirrors `SettingsManagerRemoteAgentTests`: every test wipes
// the App-Group defaults + per-ref slots (incl. the iCloud-KVS mirrors and
// the persistent migration latch) in setUp/tearDown. Keychain-dependent
// writes ride the `setTokenOrSkip`-style XCTSkip-on-errSecMissingEntitlement
// pattern — the access-group Keychain write needs the entitlement, absent on
// an unsigned headless build; those paths verify fully on the signed
// founder-gate run.
//
// Payloads are built from locally-constructed strings (JSONSerialization →
// base64 → `PairingPayload.parse`) — NO network anywhere; the network-bound
// `runPairingGatewayTest` is deliberately NOT covered here (it's the
// signed/sim QA gate's job). Privacy: synthetic fixtures only, never logged.

import XCTest
@testable import Conduck

@MainActor
final class SettingsViewModelPairingImportTests: XCTestCase {

    /// App Groups UserDefaults — same suite the actor uses internally.
    private let defaults = TestStores.defaults

    private let openclaw: RemoteAgentRef = .builtin(.openclaw)
    private let hermes: RemoteAgentRef = .builtin(.hermes)

    override func setUp() async throws {
        try await super.setUp()
        await wipePairingState()
    }

    override func tearDown() async throws {
        await wipePairingState()
        try await super.tearDown()
    }

    /// Wipe persistent state touched by the pairing-import paths. Runs in
    /// setUp + tearDown so individual tests start from a clean slate.
    private func wipePairingState() async {
        // Customs first — `deleteCustomGateway` clears each one's per-ref
        // slots (url/token/cert/authScheme + transport hint) AND the roster.
        for gateway in await SettingsManager.shared.customGateways() {
            await SettingsManager.shared.deleteCustomGateway(id: gateway.id)
        }
        defaults.removeObject(forKey: Constants.customGatewaysRegistryKey)
        TestStores.kvs.removeObject(forKey: Constants.customGatewaysRegistryKey)

        // Default pointer + active session.
        defaults.removeObject(forKey: Constants.remoteAgentDefaultBackendKVSKey)
        TestStores.kvs.removeObject(forKey: Constants.remoteAgentDefaultBackendKVSKey)
        defaults.removeObject(forKey: Constants.remoteAgentActiveSessionKey)

        // Legacy single-slot keys — the migration reads them; left-over values
        // from older runs would pollute per-backend slots after the latch reset.
        defaults.removeObject(forKey: Constants.remoteAgentBackendKey)
        defaults.removeObject(forKey: Constants.remoteAgentURLKey)
        defaults.removeObject(forKey: Constants.remoteAgentCertFingerprintKey)
        try? await SettingsManager.shared.clearRemoteAgentToken()

        // Per-builtin gateway + file-server slots (defaults AND the KVS mirror
        // for dual-written keys; the transport hint + cert pins are App-Group
        // only, but remove their KVS keys too so the absence assertions can't
        // be poisoned by an older build's stray write).
        for backend in RemoteAgentBackend.allCases {
            let ref = RemoteAgentRef.builtin(backend)
            for key in [
                Constants.remoteAgentURLKey(for: ref),
                Constants.remoteAgentCertFingerprintKey(for: ref),
                Constants.remoteAgentAuthSchemeKey(for: ref),
                Constants.remoteAgentTransportHintKey(for: ref),
                Constants.fileServerURLKey(for: ref),
                Constants.fileServerCertFingerprintKey(for: ref),
                Constants.fileTransferAvailableKey(for: ref),
                // The lane's delivery properties: an import states them, so a
                // left-over value from a previous case would let an assertion pass
                // on state the code under test never wrote.
                Constants.fileServerFolderCapableKey(for: ref),
                // The listing verdict: a case that seeds a proven-incapable lane
                // would otherwise hand the next case an amber badge it never set
                // up, and the key is absent-means-capable so only a wipe restores
                // the unmeasured state.
                Constants.fileServerReturnCapableKey(for: ref),
                Constants.fileServerAutoDeliverKey(for: ref),
                Constants.fileServerFilenamePolicyKey(for: ref),
                Constants.fileServerTestedLocallyKey(for: ref),
                // The identity stamp that turns that flag into per-SERVER proof.
                // A stray one from an earlier case would let an assertion pass on
                // provenance the code under test never wrote.
                Constants.fileServerTestedLocallyStampKey(for: ref)
            ] {
                defaults.removeObject(forKey: key)
                TestStores.kvs.removeObject(forKey: key)
            }
            try? await SettingsManager.shared.clearRemoteAgentToken(for: ref)
            try? await SettingsManager.shared.clearFileServerCredential(for: ref)
        }

        // Migration latch (persistent flag + in-process latch) — mirrors
        // `SettingsManagerRemoteAgentTests.wipeRemoteAgentState()`.
        defaults.removeObject(forKey: Constants.remoteAgentMultiGatewayMigratedKey)
        await SettingsManager.shared.resetRemoteAgentMigrationLatchForTesting()
    }

    // MARK: - Fixtures

    /// Build a raw `conduck-setup:v1:` pairing string from locally-constructed
    /// JSON (synthetic values only — nothing real, nothing logged).
    private func makePairingString(
        kind: String,
        name: String? = nil,
        url: String = "https://gw.example.test:18789",
        auth: String? = nil,
        token: String? = "tok-pairing-test",
        model: String? = nil,
        fileServer: [String: Any]? = nil,
        transport: String? = nil
    ) throws -> String {
        var gateway: [String: Any] = ["kind": kind, "url": url]
        if let name { gateway["name"] = name }
        if let auth { gateway["auth"] = auth }
        if let token { gateway["token"] = token }
        if let model { gateway["model"] = model }
        var dict: [String: Any] = ["v": 1, "gateway": gateway]
        if let fileServer { dict["fileServer"] = fileServer }
        if let transport { dict["transport"] = transport }
        let data = try JSONSerialization.data(withJSONObject: dict)
        return "conduck-setup:v1:" + data.base64EncodedString()
    }

    /// Parse a fixture string into a payload, failing the test on a reject.
    private func makePayload(
        kind: String,
        name: String? = nil,
        url: String = "https://gw.example.test:18789",
        auth: String? = nil,
        token: String? = "tok-pairing-test",
        model: String? = nil,
        fileServer: [String: Any]? = nil,
        transport: String? = nil
    ) throws -> PairingPayload {
        let string = try makePairingString(
            kind: kind, name: name, url: url, auth: auth, token: token,
            model: model, fileServer: fileServer, transport: transport
        )
        return try XCTUnwrap(
            try? PairingPayload.parse(string).get(),
            "Fixture pairing string must parse — the fixture builder and the parser have drifted."
        )
    }

    /// Fresh VM with the init-load drained (mirrors
    /// `SettingsViewModelRemoteAgentURLTests`) so a late async reload can't
    /// wipe an in-memory draft mid-test.
    private func makeVM() async -> SettingsViewModel {
        let vm = SettingsViewModel()
        await vm.loadSettings()
        await Task.yield()
        return vm
    }

    /// Probe the access-group Keychain GATEWAY-TOKEN slot, skipping the test
    /// on an unsigned build (errSecMissingEntitlement) — same posture as
    /// `setTokenOrSkip` in `SettingsManagerRemoteAgentTests`.
    private func requireGatewayKeychainOrSkip(for ref: RemoteAgentRef) async throws {
        do {
            try await SettingsManager.shared.setRemoteAgentToken("probe-token", for: ref)
            try await SettingsManager.shared.clearRemoteAgentToken(for: ref)
        } catch {
            throw XCTSkip("Keychain access-group write requires a signed build (unsigned: \(error)).")
        }
    }

    /// Same probe for the FILE-SERVER credential slot (mirrors the skip gate
    /// in `SettingsManagerFileTransferTests`).
    private func requireFileServerKeychainOrSkip(for ref: RemoteAgentRef) async throws {
        do {
            try await SettingsManager.shared.setFileServerCredential("probe-credential", for: ref)
            try await SettingsManager.shared.clearFileServerCredential(for: ref)
        } catch {
            throw XCTSkip("Keychain access-group write requires a signed build (unsigned: \(error)).")
        }
    }

    // MARK: - Plan resolution

    func testPlanUnconfiguredBuiltinIsReady() async throws {
        let vm = await makeVM()
        let payload = try makePayload(kind: "openclaw")

        let plan = await vm.planPairingImport(payload, lockedTarget: nil)

        XCTAssertEqual(plan, .ready(target: openclaw),
                       "A builtin payload with an empty URL slot must resolve to .ready at that builtin's ref.")
    }

    func testPlanConfiguredURLNeedsOverwriteConfirm() async throws {
        let existingURL = "https://old-gateway.example.test:18789"
        await SettingsManager.shared.setRemoteAgentURL(URL(string: existingURL)!, for: openclaw)

        let vm = await makeVM()
        let payload = try makePayload(kind: "openclaw", url: "https://new-gateway.example.test:18789")

        let plan = await vm.planPairingImport(payload, lockedTarget: nil)

        XCTAssertEqual(
            plan,
            .needsOverwriteConfirm(
                target: openclaw,
                existingURL: existingURL,
                newURL: "https://new-gateway.example.test:18789"
            ),
            "A stored URL on the resolved target must surface BOTH URLs for the overwrite confirm."
        )
    }

    func testPlanCustomPayloadBlockedAtCap() async throws {
        let vm = await makeVM()
        // Fill the roster to the cap with in-memory drafts (drafts count —
        // `newCustomGatewayDraftID` gates on the cached roster size).
        for _ in 0..<Constants.maxCustomGateways {
            XCTAssertNotNil(vm.newCustomGatewayDraftID(), "Pre-cap mints must succeed.")
        }

        let payload = try makePayload(kind: "custom", name: "Home LLM")
        let plan = await vm.planPairingImport(payload, lockedTarget: nil)

        XCTAssertEqual(plan, .blocked(.customGatewayCapReached),
                       "A custom payload with a full roster must block at the cap, not mint an over-cap slot.")
    }

    func testPlanLockedBuiltinRejectsOtherBuiltinPayload() async throws {
        let vm = await makeVM()
        let payload = try makePayload(kind: "hermes")

        let plan = await vm.planPairingImport(payload, lockedTarget: openclaw)

        XCTAssertEqual(
            plan,
            .blocked(.kindMismatch(expectedDisplayName: RemoteAgentBackend.hermes.displayName)),
            "A Hermes payload must not import into a locked OpenClaw target — the mismatch names the payload's gateway."
        )
    }

    func testPlanLockedBuiltinRejectsCustomPayload() async throws {
        let vm = await makeVM()
        let payload = try makePayload(kind: "custom", name: "Home LLM")

        let plan = await vm.planPairingImport(payload, lockedTarget: openclaw)

        XCTAssertEqual(plan, .blocked(.kindMismatch(expectedDisplayName: "Home LLM")),
                       "A custom payload must not import into a locked builtin target — the mismatch names the payload's custom name.")
    }

    func testPlanLockedCustomReusesThatRefWithoutMinting() async throws {
        let vm = await makeVM()
        guard let id = vm.newCustomGatewayDraftID() else {
            return XCTFail("Expected a fresh VM to mint a custom draft below the cap.")
        }
        let lockedRef = RemoteAgentRef.custom(id)
        let rosterCountBefore = vm.customGateways.count

        let payload = try makePayload(kind: "custom", name: "Home LLM")
        let plan = await vm.planPairingImport(payload, lockedTarget: lockedRef)

        XCTAssertEqual(plan, .ready(target: lockedRef),
                       "A custom payload with a locked custom target must import into THAT ref.")
        XCTAssertEqual(vm.customGateways.count, rosterCountBefore,
                       "A locked custom target must NOT mint a new roster entry.")
    }

    // MARK: - Execute: builtin round-trip (bearer + cert + transport hint)

    func testExecuteBuiltinRoundTripPersistsSlotsAndTransportHint() async throws {
        try await requireGatewayKeychainOrSkip(for: openclaw)

        let vm = await makeVM()
        let payload = try makePayload(
            kind: "openclaw",
            url: "https://gw.example.test:18789",
            token: "tok-pairing-test",
            transport: "tailscale"
        )

        let outcome = await vm.executePairingImportWithResolvedTrust(payload, target: openclaw)
        XCTAssertEqual(outcome, .committed, "A complete builtin payload must commit.")

        let storedURL = await SettingsManager.shared.getRemoteAgentURL(for: openclaw)
        XCTAssertEqual(storedURL?.absoluteString, "https://gw.example.test:18789")
        let scheme = await SettingsManager.shared.getRemoteAgentAuthScheme(for: openclaw)
        XCTAssertEqual(scheme, .bearer, "Auth scheme must persist EXPLICITLY (never inferred downstream).")
        let token = await SettingsManager.shared.getRemoteAgentToken(for: openclaw)
        XCTAssertEqual(token, "tok-pairing-test")
        let cert = await SettingsManager.shared.getRemoteAgentCertFingerprint(for: openclaw)
        XCTAssertNil(cert,
                     "A resolved import stores no pin — the payload carries none and the trust gate never produces one.")

        // Transport hint: readable via the accessor AND App-Group ONLY — the
        // raw key must be ABSENT from iCloud KVS (per-device guidance hint).
        let hint = await SettingsManager.shared.getRemoteAgentTransportHint(for: openclaw)
        XCTAssertEqual(hint, "tailscale")
        let hintKey = Constants.remoteAgentTransportHintKey(for: openclaw)
        XCTAssertEqual(defaults.string(forKey: hintKey), "tailscale",
                       "The hint lives in the App-Group defaults.")
        XCTAssertNil(TestStores.kvs.object(forKey: hintKey),
                     "The transport hint must NEVER be dual-written to iCloud KVS (per-device only).")
    }

    // MARK: - Execute: custom roster + model

    func testExecuteCustomPersistsRosterRowAndModel() async throws {
        let vm = await makeVM()
        // Keyless custom → no Keychain dependency, runs on the unsigned host.
        let payload = try makePayload(
            kind: "custom", name: "Home LLM",
            url: "https://llm.example.test:8080",
            auth: "none", token: nil,
            model: "llama-3-70b"
        )

        let plan = await vm.planPairingImport(payload, lockedTarget: nil)
        guard case .ready(let target) = plan, case .custom(let id) = target else {
            return XCTFail("Expected a minted custom draft target, got \(plan).")
        }

        let outcome = await vm.executePairingImportWithResolvedTrust(payload, target: target)
        XCTAssertEqual(outcome, .committed, "A named keyless custom payload must commit.")

        let roster = await SettingsManager.shared.customGateway(id: id)
        XCTAssertEqual(roster?.name, "Home LLM", "The roster row must carry the payload's name.")
        XCTAssertEqual(roster?.model, "llama-3-70b", "The payload's model override must persist on the roster row.")
        let storedURL = await SettingsManager.shared.getRemoteAgentURL(for: target)
        XCTAssertEqual(storedURL?.absoluteString, "https://llm.example.test:8080")
    }

    /// Pairing imports share the manual editor's single save path. A model ID
    /// longer than the retired 100-character cap must survive that handoff
    /// exactly after the parser trims its surrounding whitespace.
    func testExecuteCustomPreservesLongModelIdentifierExactly() async throws {
        let vm = await makeVM()
        let model = "litellm/team/" + String(repeating: "provider-route-segment-", count: 7)
        let payload = try makePayload(
            kind: "custom", name: "Long Route",
            url: "https://llm.example.test:8080",
            auth: "none", token: nil,
            model: "  \(model)  "
        )

        let plan = await vm.planPairingImport(payload, lockedTarget: nil)
        guard case .ready(let target) = plan, case .custom(let id) = target else {
            return XCTFail("Expected a minted custom draft target, got \(plan).")
        }

        let outcome = await vm.executePairingImportWithResolvedTrust(payload, target: target)
        XCTAssertEqual(outcome, .committed)

        let roster = await SettingsManager.shared.customGateway(id: id)
        XCTAssertEqual(roster?.model, model)
        XCTAssertGreaterThan(model.count, 100, "The fixture must cross the retired cap.")
    }

    // MARK: - Execute: keyless

    func testExecuteKeylessPersistsExplicitNoneAndNoToken() async throws {
        let vm = await makeVM()
        let payload = try makePayload(kind: "openclaw", auth: "none", token: nil)

        let outcome = await vm.executePairingImportWithResolvedTrust(payload, target: openclaw)
        XCTAssertEqual(outcome, .committed, "A keyless builtin payload must commit with no Keychain dependency.")

        let scheme = await SettingsManager.shared.getRemoteAgentAuthScheme(for: openclaw)
        XCTAssertEqual(scheme, .none,
                       "Keyless must persist as the EXPLICIT `.none` scheme — never inferred from a missing token.")
        let token = await SettingsManager.shared.getRemoteAgentToken(for: openclaw)
        XCTAssertNil(token, "No token may be written for a keyless import.")
    }

    /// Overwrite-execute semantics: importing over an already-configured ref
    /// must REPLACE the URL and clear the pin the user had typed in manually for
    /// the OLD certificate (the riskier half of the explicit-overwrite
    /// contract — keeping it would fail TLS against the new host).
    func testExecuteOverwriteReplacesURLAndClearsStalePin() async throws {
        await SettingsManager.shared.setRemoteAgentURL(URL(string: "https://old.example.test:18789")!, for: openclaw)
        await SettingsManager.shared.setRemoteAgentAuthScheme(.none, for: openclaw)
        // A pin the user typed into the Settings editor for the old host's
        // certificate — the only way a pin can exist at all.
        await SettingsManager.shared.setRemoteAgentCertFingerprint(
            String(repeating: "ab", count: 32), for: openclaw)

        let vm = await makeVM()
        let payload = try makePayload(kind: "openclaw", url: "https://new.example.test:18789",
                                      auth: "none", token: nil)

        // Plan must demand the explicit confirm…
        let plan = await vm.planPairingImport(payload, lockedTarget: nil)
        XCTAssertEqual(plan, .needsOverwriteConfirm(target: openclaw,
                                                    existingURL: "https://old.example.test:18789",
                                                    newURL: "https://new.example.test:18789"))

        // …and a confirmed execute replaces the slots wholesale.
        let outcome = await vm.executePairingImportWithResolvedTrust(payload, target: openclaw)
        XCTAssertEqual(outcome, .committed)
        let url = await SettingsManager.shared.getRemoteAgentURL(for: openclaw)
        XCTAssertEqual(url?.absoluteString, "https://new.example.test:18789")
        let pin = await SettingsManager.shared.getRemoteAgentCertFingerprint(for: openclaw)
        XCTAssertNil(pin,
                     "An import replaces the gateway wholesale, so a manually typed pin for the OLD certificate must go with it.")
    }

    // MARK: - Execute: file-server block

    func testExecuteFileServerPersistsURLAndCredentialWithNoPin() async throws {
        try await requireFileServerKeychainOrSkip(for: openclaw)

        let vm = await makeVM()
        let payload = try makePayload(
            kind: "openclaw",
            url: "https://gw.example.test:18789",
            auth: "none", token: nil,
            fileServer: [
                "url": "https://gw.example.test:8443",
                "credential": "feedfacecafebeeffeedfacecafebeef"
            ],
            transport: "tailscale"
        )

        let outcome = await vm.executePairingImportWithResolvedTrust(payload, target: openclaw)
        XCTAssertEqual(outcome, .committed, "A payload with a complete fileServer block must commit on a Keychain-capable host.")

        let fsURL = await SettingsManager.shared.getFileServerURL(for: openclaw)
        XCTAssertEqual(fsURL?.absoluteString, "https://gw.example.test:8443")
        let credential = await SettingsManager.shared.getFileServerCredential(for: openclaw)
        XCTAssertEqual(credential, "feedfacecafebeeffeedfacecafebeef")
        let fsPin = await SettingsManager.shared.getFileServerCertFingerprint(for: openclaw)
        XCTAssertNil(fsPin,
                     "No pin rides in from a setup code, so the file lane commits under ordinary system trust.")
        let available = await SettingsManager.shared.getFileTransferAvailable(for: openclaw)
        XCTAssertFalse(available,
                       "Import must NOT mark file transfer available — only a passing staged Test Connection does (Decision C).")
    }

    /// A code that STATES the lane's delivery properties must land them, so the
    /// scanning device does not have to rediscover a server fact the exporting
    /// device already measured. `folderCapable:false` is the one that costs real
    /// money to get wrong: the default is true, so an unstated import would mint
    /// nested keys against a server that rejects them until the first Test
    /// Connection re-probed.
    func testExecuteFileServerAppliesStatedDeliveryProperties() async throws {
        try await requireFileServerKeychainOrSkip(for: openclaw)

        let vm = await makeVM()
        let payload = try makePayload(
            kind: "openclaw",
            auth: "none", token: nil,
            fileServer: [
                "url": "https://gw.example.test:8443",
                "credential": "feedfacecafebeeffeedfacecafebeef",
                "folderCapable": false,
                "autoDeliver": false,
                "filenamePolicy": Constants.fileServerFilenamePolicyPreserve
            ]
        )

        let outcome = await vm.executePairingImportWithResolvedTrust(payload, target: openclaw)
        XCTAssertEqual(outcome, .committed)

        let folderCapable = await SettingsManager.shared.getFileServerFolderCapable(for: openclaw)
        XCTAssertFalse(folderCapable,
                       "A stated folderCapable:false must reach storage — it is a fact about the SERVER, so it is the same answer on any device.")
        let autoDeliver = await SettingsManager.shared.getFileServerAutoDeliver(for: openclaw)
        XCTAssertFalse(autoDeliver,
                       "A stated autoDeliver:false must reach storage — the permission is a decision about the gateway, not about the device it was typed on, and RESTRICTING is the direction a code may move it.")
        let policy = await SettingsManager.shared.getFileServerFilenamePolicy(for: openclaw)
        XCTAssertEqual(policy, Constants.fileServerFilenamePolicyPreserve)

        let available = await SettingsManager.shared.getFileTransferAvailable(for: openclaw)
        XCTAssertFalse(available,
                       "A code may state a CAPABILITY; it may never assert READINESS. Only a staged Test Connection on THIS device does that.")
        let testedLocally = await SettingsManager.shared.getFileServerTestedLocally(for: openclaw)
        XCTAssertFalse(testedLocally,
                       "An import is not a local test — the device-local proof must not be forged by a scan.")
        XCTAssertNil(defaults.string(forKey: Constants.fileServerTestedLocallyStampKey(for: openclaw)),
                     "…and no identity stamp either. A scanned code names a server this device has never "
                     + "connected to, so it may not arm the silent probes — one of which WRITES to that server.")
    }

    /// A code minted BEFORE the delivery properties existed — the shape every
    /// `conduck-connect` release has emitted so far — must import cleanly and leave
    /// the destination's own stored values exactly where they were. An absent key is
    /// "unstated", never a coerced default that would silently rewrite a permission
    /// the user set, and readiness still has to be earned locally.
    func testExecuteFileServerWithoutDeliveryPropertiesLeavesStoredValuesAlone() async throws {
        try await requireFileServerKeychainOrSkip(for: openclaw)

        // Pre-existing per-gateway state, both sides deliberately non-default.
        await SettingsManager.shared.setFileServerFolderCapable(false, for: openclaw)
        await SettingsManager.shared.commitFileDeliveryPolicy(autoDeliver: false, for: openclaw)

        let vm = await makeVM()
        let payload = try makePayload(
            kind: "openclaw",
            auth: "none", token: nil,
            fileServer: [
                "url": "https://gw.example.test:8443",
                "credential": "feedfacecafebeeffeedfacecafebeef"
            ]
        )

        let outcome = await vm.executePairingImportWithResolvedTrust(payload, target: openclaw)
        XCTAssertEqual(outcome, .committed,
                       "An old-shape code must import, not fail — the block it carries is one this build has always understood.")

        let folderCapable = await SettingsManager.shared.getFileServerFolderCapable(for: openclaw)
        XCTAssertFalse(folderCapable,
                       "An unstated folderCapable leaves the stored flag untouched; it is not a claim that the server accepts folders.")
        let autoDeliver = await SettingsManager.shared.getFileServerAutoDeliver(for: openclaw)
        XCTAssertFalse(autoDeliver,
                       "An unstated autoDeliver must not switch a user's permission back on.")
        let available = await SettingsManager.shared.getFileTransferAvailable(for: openclaw)
        XCTAssertFalse(available,
                       "Not-yet-verified is the safe default for a lane no local test has proved.")
    }

    /// A code may RESTRICT the automatic-delivery permission and may never GRANT it.
    /// A setup code is attacker-craftable and the review card the user approves names
    /// the destination, not the permissions — so a scanned `autoDeliver:true` must
    /// not switch delivery back on for a gateway where it was deliberately off.
    func testExecuteFileServerRefusesToGrantAutoDeliver() async throws {
        try await requireFileServerKeychainOrSkip(for: openclaw)

        await SettingsManager.shared.commitFileDeliveryPolicy(autoDeliver: false, for: openclaw)

        let vm = await makeVM()
        let payload = try makePayload(
            kind: "openclaw",
            auth: "none", token: nil,
            fileServer: [
                "url": "https://gw.example.test:8443",
                "credential": "feedfacecafebeeffeedfacecafebeef",
                "autoDeliver": true
            ]
        )

        let outcome = await vm.executePairingImportWithResolvedTrust(payload, target: openclaw)
        XCTAssertEqual(outcome, .committed,
                       "A refused permission claim must not fail the import — the rest of the code is honoured.")

        let autoDeliver = await SettingsManager.shared.getFileServerAutoDeliver(for: openclaw)
        XCTAssertFalse(autoDeliver,
                       "A code claiming autoDeliver:true must not overwrite a stored false.")
    }

    /// `folderCapable` is applied in BOTH directions, and the asymmetry with its
    /// monotonic sibling above is the design rather than an oversight: it is a
    /// MEASUREMENT of the server (does a nested PUT land) rather than a permission
    /// granted to the gateway, the value it overwrites describes the server this
    /// very commit is replacing, and the staged Test Connection the import leaves
    /// the lane waiting for re-measures it anyway. Locking the widening direction
    /// so a future reader cannot "fix" the asymmetry into a clamp.
    func testExecuteFileServerAppliesAStatedFolderCapableInBothDirections() async throws {
        try await requireFileServerKeychainOrSkip(for: openclaw)

        // The destination was measured FLAT against its previous server.
        await SettingsManager.shared.setFileServerFolderCapable(false, for: openclaw)

        let vm = await makeVM()
        let payload = try makePayload(
            kind: "openclaw",
            auth: "none", token: nil,
            fileServer: [
                "url": "https://gw.example.test:8443",
                "credential": "feedfacecafebeeffeedfacecafebeef",
                "folderCapable": true
            ]
        )

        let outcome = await vm.executePairingImportWithResolvedTrust(payload, target: openclaw)
        XCTAssertEqual(outcome, .committed)

        let folderCapable = await SettingsManager.shared.getFileServerFolderCapable(for: openclaw)
        XCTAssertTrue(folderCapable,
                      "A stated folderCapable:true must land: it is a measurement, not a permission, and the false it replaces described the server this import just swapped out.")
        let available = await SettingsManager.shared.getFileTransferAvailable(for: openclaw)
        XCTAssertFalse(available,
                       "The widening is safe precisely BECAUSE the lane stays unready — the staged test that must run next re-measures the nested probe for itself.")
    }

    // MARK: - Execute: the published mirrors the badges render

    /// THE MIRROR THE IMPORT FORGOT. The commit resets the stored listing verdict
    /// (a new tuple makes the old server's verdict meaningless), so the published
    /// set the amber "Uploads only" badge reads has to drop with it. Without this,
    /// a user who scans a code repointing a previously upload-only gateway at a
    /// fully capable server keeps being told their new server cannot return files,
    /// on every surface that reads the badge, until the next relaunch reloads the
    /// mirror from a store that no longer says it.
    func testExecuteFileServerClearsTheUploadOnlyMirror() async throws {
        try await requireFileServerKeychainOrSkip(for: openclaw)

        // The state a user who tested a plain-nginx server is in: store and
        // mirror both saying "proven unable to list".
        await SettingsManager.shared.setFileServerReturnCapable(false, for: openclaw)
        let vm = await makeVM()
        vm.fileTransferUploadOnlyRefSet.insert(openclaw)
        XCTAssertTrue(vm.isFileTransferUploadOnly(openclaw), "Precondition: the badge says uploads-only.")

        let payload = try makePayload(
            kind: "openclaw",
            auth: "none", token: nil,
            fileServer: [
                "url": "https://files.example.test:8443",
                "credential": "feedfacecafebeeffeedfacecafebeef"
            ]
        )

        let outcome = await vm.executePairingImportWithResolvedTrust(payload, target: openclaw)
        XCTAssertEqual(outcome, .committed)

        let storedReturnCapable = await SettingsManager.shared.getFileServerReturnCapable(for: openclaw)
        XCTAssertTrue(storedReturnCapable,
                      "Precondition for the real assertion: the commit reset the verdict to unknown, which resolves CAPABLE.")
        XCTAssertFalse(vm.isFileTransferUploadOnly(openclaw),
                       "The published mirror must follow the store the same commit reset — a badge that outlives its verdict states a limitation of a server that is no longer configured.")
        XCTAssertEqual(vm.fileLaneStatus(for: openclaw), .saved,
                       "URL + credential saved and nothing tested yet — the badge an import earns. The first staged test is what may narrow it again.")
    }

    // MARK: - Default rule

    func testDefaultAssignedWhenNothingConfiguredBefore() async throws {
        let vm = await makeVM()
        let preconditions = await SettingsManager.shared.configuredRemoteAgentRefs()
        XCTAssertTrue(preconditions.isEmpty, "Precondition: clean slate.")

        // Import HERMES (not the fallback default) so the assertion proves the
        // pointer was actually SET, not just falling back to `.openclaw`.
        let payload = try makePayload(kind: "hermes", url: "https://hermes.example.test:8642",
                                      auth: "none", token: nil)
        let outcome = await vm.executePairingImportWithResolvedTrust(payload, target: hermes)
        XCTAssertEqual(outcome, .committed)

        let defaultRef = await SettingsManager.shared.defaultRemoteAgentRef()
        XCTAssertEqual(defaultRef, hermes,
                       "First gateway ever configured must become the default (bootstrap rule).")
        XCTAssertEqual(vm.defaultRemoteAgentRef, hermes,
                       "The VM's cached default must reflect the bootstrap assignment.")
    }

    func testDefaultUntouchedWhenAnotherRefWasConfiguredBefore() async throws {
        // Pre-configure OpenClaw (keyless → configured on URL alone) and pin
        // the default pointer to it.
        await SettingsManager.shared.setRemoteAgentURL(URL(string: "https://oc.example.test:18789")!, for: openclaw)
        await SettingsManager.shared.setRemoteAgentAuthScheme(.none, for: openclaw)
        await SettingsManager.shared.setDefaultRemoteAgentRef(openclaw)

        let vm = await makeVM()
        let payload = try makePayload(kind: "hermes", url: "https://hermes.example.test:8642",
                                      auth: "none", token: nil)
        let outcome = await vm.executePairingImportWithResolvedTrust(payload, target: hermes)
        XCTAssertEqual(outcome, .committed)

        let defaultRef = await SettingsManager.shared.defaultRemoteAgentRef()
        XCTAssertEqual(defaultRef, openclaw,
                       "With a gateway already configured, an import must NEVER re-point the default.")
    }

    // MARK: - Discard draft

    func testDiscardPairingDraftRemovesUnsavedDraft() async throws {
        let vm = await makeVM()
        let payload = try makePayload(kind: "custom", name: "Home LLM")

        let plan = await vm.planPairingImport(payload, lockedTarget: nil)
        guard case .ready(let target) = plan, case .custom(let id) = target else {
            return XCTFail("Expected a minted custom draft target, got \(plan).")
        }
        XCTAssertTrue(vm.customGateways.contains { $0.id == id },
                      "Precondition: the minted draft row must be present before discard.")

        vm.discardPairingDraft(target)

        // The discard routes through an actor-hop store check — poll briefly
        // for the main-actor removal to land.
        for _ in 0..<100 where vm.customGateways.contains(where: { $0.id == id }) {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(vm.customGateways.contains { $0.id == id },
                       "Discarding an unsaved pairing draft must drop its in-memory roster row.")
        let storedURL = await SettingsManager.shared.getRemoteAgentURL(for: target)
        XCTAssertNil(storedURL, "A discarded draft must leave nothing in the store.")
        let roster = await SettingsManager.shared.customGateway(id: id)
        XCTAssertNil(roster, "A discarded draft must have no persisted roster entry.")
    }

    // MARK: - Review (what the card is told, before anything is written)

    /// THE assertion the whole card rests on: the address the user was shown is
    /// the address that ends up in storage. A card that renders anything else —
    /// the raw payload URL, a bare host, a prettified form — is showing a
    /// destination the app is not going to use, on the one screen whose job is
    /// to be believed.
    func testReviewedDestinationIsExactlyWhatGetsPersisted() async throws {
        let vm = await makeVM()
        // A URL that normalization changes, so an unnormalized card would fail.
        let payload = try makePayload(
            kind: "custom", name: "Home LLM",
            url: "https://llm.example.test:8080/tenant/v1/chat/completions",
            auth: "none", token: nil
        )

        let plan = await vm.planPairingImport(payload, lockedTarget: nil)
        guard case .ready(let target) = plan else {
            return XCTFail("Expected a minted custom draft target, got \(plan).")
        }
        let review = await vm.pairingReview(for: payload, target: target, freshlyMinted: true)

        let outcome = await vm.executePairingImportWithResolvedTrust(payload, target: target)
        XCTAssertEqual(outcome, .committed)

        let storedURL = await SettingsManager.shared.getRemoteAgentURL(for: target)
        XCTAssertEqual(
            review.gatewayDestination, storedURL?.absoluteString,
            "The reviewed destination and the persisted URL must be byte-identical."
        )
        XCTAssertEqual(review.gatewayDestination, "https://llm.example.test:8080/tenant")
    }

    /// A review taken BEFORE the import must not describe the state the import
    /// creates — the whole point is that it describes what would happen.
    func testReviewOfAFreshTargetReportsNothingToReplaceAndBecomingDefault() async throws {
        let vm = await makeVM()
        let payload = try makePayload(kind: "openclaw", auth: "none", token: nil)

        let review = await vm.pairingReview(for: payload, target: openclaw, freshlyMinted: false)

        XCTAssertNil(review.previousGatewayDestination)
        XCTAssertTrue(review.becomesDefault,
                      "With no gateway configured, this import also becomes the default.")
        XCTAssertNil(review.fileLane, "No incoming block and no existing lane — no row.")
    }

    /// The overwrite case, read from the STORE rather than from the plan's
    /// snapshot — which is what lets the card be re-read at Connect and compared.
    func testReviewOfAConfiguredTargetReportsTheAddressItReplaces() async throws {
        let vm = await makeVM()
        let first = try makePayload(kind: "openclaw", url: "https://old.example.test:18789",
                                    auth: "none", token: nil)
        let firstOutcome = await vm.executePairingImportWithResolvedTrust(first, target: openclaw)
        XCTAssertEqual(firstOutcome, .committed)

        let second = try makePayload(kind: "openclaw", url: "https://new.example.test:18789",
                                     auth: "none", token: nil)
        let review = await vm.pairingReview(for: second, target: openclaw, freshlyMinted: false)

        XCTAssertEqual(review.previousGatewayDestination, "https://old.example.test:18789")
        XCTAssertTrue(review.gatewayDestinationChanges)
        XCTAssertFalse(review.becomesDefault,
                       "A gateway is already configured, so this import does not re-point the default.")
    }

    /// A gateway-only code over a target with a configured lane must say the lane
    /// survives. Silence here reads as "my file transfer is gone" — and the
    /// keep-existing rule is exactly the kind of behaviour a user cannot infer.
    func testReviewNamesTheFileLaneAGatewayOnlyCodeKeeps() async throws {
        try await requireFileServerKeychainOrSkip(for: openclaw)
        let vm = await makeVM()
        let withFiles = try makePayload(
            kind: "openclaw", auth: "none", token: nil,
            fileServer: ["url": "https://files.example.test", "credential": "cred"]
        )
        let seedOutcome = await vm.executePairingImportWithResolvedTrust(withFiles, target: openclaw)
        XCTAssertEqual(seedOutcome, .committed)

        let gatewayOnly = try makePayload(kind: "openclaw", url: "https://gw2.example.test",
                                          auth: "none", token: nil)
        let review = await vm.pairingReview(for: gatewayOnly, target: openclaw, freshlyMinted: false)

        guard case .keepsExisting(let destination) = review.fileLane else {
            return XCTFail("Expected the existing lane to be named, got \(String(describing: review.fileLane)).")
        }
        XCTAssertEqual(destination, "https://files.example.test")
    }

    /// A freshly minted custom stays nameless: the only name available is the one
    /// the CODE chose, and the card must never render it.
    func testReviewOfAFreshlyMintedCustomCarriesNoName() async throws {
        let vm = await makeVM()
        let payload = try makePayload(kind: "custom", name: "Definitely Your Own Server",
                                      auth: "none", token: nil)

        let plan = await vm.planPairingImport(payload, lockedTarget: nil)
        guard case .ready(let target) = plan else {
            return XCTFail("Expected a minted custom draft target, got \(plan).")
        }
        let review = await vm.pairingReview(for: payload, target: target, freshlyMinted: true)

        XCTAssertNil(review.targetName)
        vm.discardPairingDraft(target)
    }

    /// The card doubles as the snapshot the commit is checked against, so it has
    /// to read STORAGE. A change made without this view model's knowledge — a
    /// second window, a peer's iCloud sync — lands in storage before any cached
    /// reload reaches here, and a card built from caches would describe a
    /// configuration that had already moved.
    func testReviewReadsStorageNotTheViewModelsCaches() async throws {
        let vm = await makeVM()
        // Write through the manager directly, bypassing the VM entirely.
        await SettingsManager.shared.setRemoteAgentURL(
            URL(string: "https://peer-set.example.test")!, for: openclaw
        )
        let payload = try makePayload(kind: "openclaw", url: "https://scanned.example.test",
                                      auth: "none", token: nil)

        let review = await vm.pairingReview(for: payload, target: openclaw, freshlyMinted: false)

        XCTAssertEqual(review.previousGatewayDestination, "https://peer-set.example.test",
                       "A change that reached storage without a VM reload must still show on the card.")
        // A bare URL with no usable credential is not a SEND-ABLE gateway, and
        // `becomesDefault` is deliberately computed with the same predicate
        // `saveRemoteAgent`'s first-gateway bootstrap uses — so this import would
        // still become the default, and the card says so.
        XCTAssertTrue(review.becomesDefault)
    }

    /// The mechanism the commit gate rests on: the card is rebuilt immediately
    /// before persisting and must not compare equal if the target moved while the
    /// user was reading, probing, or deliberating over a certificate alert.
    func testRebuiltReviewDoesNotCompareEqualAfterTheTargetMoves() async throws {
        let vm = await makeVM()
        let payload = try makePayload(kind: "openclaw", url: "https://scanned.example.test",
                                      auth: "none", token: nil)

        let reviewed = await vm.pairingReview(for: payload, target: openclaw, freshlyMinted: false)
        await SettingsManager.shared.setRemoteAgentURL(
            URL(string: "https://production.example.test")!, for: openclaw
        )
        let fresh = await vm.pairingReview(for: payload, target: openclaw, freshlyMinted: false)

        XCTAssertNotEqual(reviewed, fresh,
                          "The commit gate compares exactly these two — a slot that moved must break the comparison.")
    }

    /// Reviewing is a READ. If it wrote anything, the card would have persisted
    /// the very configuration it exists to ask permission for.
    func testReviewPersistsNothing() async throws {
        let vm = await makeVM()
        let payload = try makePayload(kind: "openclaw", auth: "none", token: nil)

        _ = await vm.pairingReview(for: payload, target: openclaw, freshlyMinted: false)

        let storedURL = await SettingsManager.shared.getRemoteAgentURL(for: openclaw)
        XCTAssertNil(storedURL, "Building the review card must not configure the gateway.")
        // `defaultRemoteAgentRef()` always resolves to something, so assert on
        // the stored pointer itself: nothing may have been written.
        XCTAssertNil(defaults.string(forKey: Constants.remoteAgentDefaultBackendKVSKey),
                     "Building the review card must not point the default anywhere.")
        let configured = await SettingsManager.shared.configuredRemoteAgentRefs()
        XCTAssertTrue(configured.isEmpty,
                      "Building the review card must leave the configured set untouched.")
    }
}
