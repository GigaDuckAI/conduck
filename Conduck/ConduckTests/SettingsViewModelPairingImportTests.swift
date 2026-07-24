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
    private let defaults: UserDefaults = {
        UserDefaults(suiteName: Constants.appGroupID) ?? UserDefaults.standard
    }()

    private let openclaw: RemoteAgentRef = .builtin(.openclaw)
    private let hermes: RemoteAgentRef = .builtin(.hermes)

    /// Synthetic 64-hex SPKI fingerprint (the parser requires exactly 64 hex).
    private let gatewayFP = String(repeating: "ab", count: 32)

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
        NSUbiquitousKeyValueStore.default.removeObject(forKey: Constants.customGatewaysRegistryKey)

        // Default pointer + active session.
        defaults.removeObject(forKey: Constants.remoteAgentDefaultBackendKVSKey)
        NSUbiquitousKeyValueStore.default.removeObject(forKey: Constants.remoteAgentDefaultBackendKVSKey)
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
                Constants.fileTransferAvailableKey(for: ref)
            ] {
                defaults.removeObject(forKey: key)
                NSUbiquitousKeyValueStore.default.removeObject(forKey: key)
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
        certFP: String? = nil,
        model: String? = nil,
        fileServer: [String: Any]? = nil,
        transport: String? = nil
    ) throws -> String {
        var gateway: [String: Any] = ["kind": kind, "url": url]
        if let name { gateway["name"] = name }
        if let auth { gateway["auth"] = auth }
        if let token { gateway["token"] = token }
        if let certFP { gateway["certFP"] = certFP }
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
        certFP: String? = nil,
        model: String? = nil,
        fileServer: [String: Any]? = nil,
        transport: String? = nil
    ) throws -> PairingPayload {
        let string = try makePairingString(
            kind: kind, name: name, url: url, auth: auth, token: token,
            certFP: certFP, model: model, fileServer: fileServer, transport: transport
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
            certFP: gatewayFP,
            transport: "tailscale"
        )

        let outcome = await vm.executePairingImport(payload, target: openclaw)
        XCTAssertEqual(outcome, .committed, "A complete builtin payload must commit.")

        let storedURL = await SettingsManager.shared.getRemoteAgentURL(for: openclaw)
        XCTAssertEqual(storedURL?.absoluteString, "https://gw.example.test:18789")
        let scheme = await SettingsManager.shared.getRemoteAgentAuthScheme(for: openclaw)
        XCTAssertEqual(scheme, .bearer, "Auth scheme must persist EXPLICITLY (never inferred downstream).")
        let token = await SettingsManager.shared.getRemoteAgentToken(for: openclaw)
        XCTAssertEqual(token, "tok-pairing-test")
        let cert = await SettingsManager.shared.getRemoteAgentCertFingerprint(for: openclaw)
        XCTAssertEqual(cert, gatewayFP, "The payload pin must land in the per-ref cert slot (lowercase 64-hex).")

        // Transport hint: readable via the accessor AND App-Group ONLY — the
        // raw key must be ABSENT from iCloud KVS (per-device guidance hint).
        let hint = await SettingsManager.shared.getRemoteAgentTransportHint(for: openclaw)
        XCTAssertEqual(hint, "tailscale")
        let hintKey = Constants.remoteAgentTransportHintKey(for: openclaw)
        XCTAssertEqual(defaults.string(forKey: hintKey), "tailscale",
                       "The hint lives in the App-Group defaults.")
        XCTAssertNil(NSUbiquitousKeyValueStore.default.object(forKey: hintKey),
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

        let outcome = await vm.executePairingImport(payload, target: target)
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

        let outcome = await vm.executePairingImport(payload, target: target)
        XCTAssertEqual(outcome, .committed)

        let roster = await SettingsManager.shared.customGateway(id: id)
        XCTAssertEqual(roster?.model, model)
        XCTAssertGreaterThan(model.count, 100, "The fixture must cross the retired cap.")
    }

    // MARK: - Execute: keyless

    func testExecuteKeylessPersistsExplicitNoneAndNoToken() async throws {
        let vm = await makeVM()
        let payload = try makePayload(kind: "openclaw", auth: "none", token: nil)

        let outcome = await vm.executePairingImport(payload, target: openclaw)
        XCTAssertEqual(outcome, .committed, "A keyless builtin payload must commit with no Keychain dependency.")

        let scheme = await SettingsManager.shared.getRemoteAgentAuthScheme(for: openclaw)
        XCTAssertEqual(scheme, .none,
                       "Keyless must persist as the EXPLICIT `.none` scheme — never inferred from a missing token.")
        let token = await SettingsManager.shared.getRemoteAgentToken(for: openclaw)
        XCTAssertNil(token, "No token may be written for a keyless import.")
    }

    /// Overwrite-execute semantics: importing over an already-configured ref
    /// must REPLACE the URL and clear a stale cert pin when the new payload
    /// carries none (the riskier half of the explicit-overwrite contract).
    func testExecuteOverwriteReplacesURLAndClearsStalePin() async throws {
        await SettingsManager.shared.setRemoteAgentURL(URL(string: "https://old.example.test:18789")!, for: openclaw)
        await SettingsManager.shared.setRemoteAgentAuthScheme(.none, for: openclaw)
        await SettingsManager.shared.setRemoteAgentCertFingerprint(gatewayFP, for: openclaw)

        let vm = await makeVM()
        let payload = try makePayload(kind: "openclaw", url: "https://new.example.test:18789",
                                      auth: "none", token: nil)

        // Plan must demand the explicit confirm…
        let plan = await vm.planPairingImport(payload, lockedTarget: nil)
        XCTAssertEqual(plan, .needsOverwriteConfirm(target: openclaw,
                                                    existingURL: "https://old.example.test:18789",
                                                    newURL: "https://new.example.test:18789"))

        // …and a confirmed execute replaces the slots wholesale.
        let outcome = await vm.executePairingImport(payload, target: openclaw)
        XCTAssertEqual(outcome, .committed)
        let url = await SettingsManager.shared.getRemoteAgentURL(for: openclaw)
        XCTAssertEqual(url?.absoluteString, "https://new.example.test:18789")
        let pin = await SettingsManager.shared.getRemoteAgentCertFingerprint(for: openclaw)
        XCTAssertNil(pin,
                     "A payload WITHOUT certFP must clear the stale pin — keeping it would fail TLS against the new host's cert.")
    }

    // MARK: - Execute: file-server block

    func testExecuteFileServerPersistsURLCredentialAndSelfsignedPinCopy() async throws {
        try await requireFileServerKeychainOrSkip(for: openclaw)

        let vm = await makeVM()
        // Self-signed recipe, file-server on the SAME host as the gateway, no
        // explicit file-server pin → the gateway pin must be copied across.
        let payload = try makePayload(
            kind: "openclaw",
            url: "https://gw.example.test:18789",
            auth: "none", token: nil,
            certFP: gatewayFP,
            fileServer: [
                "url": "https://gw.example.test:8443",
                "credential": "feedfacecafebeeffeedfacecafebeef"
            ],
            transport: "selfsigned"
        )

        let outcome = await vm.executePairingImport(payload, target: openclaw)
        XCTAssertEqual(outcome, .committed, "A payload with a complete fileServer block must commit on a Keychain-capable host.")

        let fsURL = await SettingsManager.shared.getFileServerURL(for: openclaw)
        XCTAssertEqual(fsURL?.absoluteString, "https://gw.example.test:8443")
        let credential = await SettingsManager.shared.getFileServerCredential(for: openclaw)
        XCTAssertEqual(credential, "feedfacecafebeeffeedfacecafebeef")
        let fsPin = await SettingsManager.shared.getFileServerCertFingerprint(for: openclaw)
        XCTAssertEqual(fsPin, gatewayFP,
                       "selfsigned + same-host + no explicit fs pin → the GATEWAY pin must cover the file-server too.")
        let available = await SettingsManager.shared.getFileTransferAvailable(for: openclaw)
        XCTAssertFalse(available,
                       "Import must NOT mark file transfer available — only a passing staged Test Connection does (Decision C).")
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
        let outcome = await vm.executePairingImport(payload, target: hermes)
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
        let outcome = await vm.executePairingImport(payload, target: hermes)
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
}
