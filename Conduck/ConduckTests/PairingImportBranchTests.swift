// Conduck
// PairingImportBranchTests.swift
//
// Locks the UNDER-tested branches of the pairing-import lifecycle
// (`SettingsViewModel+PairingImport` + `PairingPayload.parse`) that the broad
// round-trip suite (`SettingsViewModelPairingImportTests`) does not pin:
//
//   1. FAIL-CLOSED AUTH (security-load-bearing) — a payload whose `auth` field
//      is garbage/unknown must resolve to `.bearer` (token REQUIRED), NEVER
//      keyless. Asserted end-to-end through the PARSER, distinct from the
//      `RemoteAgentAuthScheme.from(rawValue:)` unit test: this proves the
//      pairing-import path can never let an unrecognized scheme silently strip
//      auth, and that a garbage-auth payload WITHOUT a token is rejected.
//   2. TRANSPORT-HINT CLEARING — a re-import that omits the transport hint
//      nil-removes the prior hint (App-Group only), never leaves it stale.
//   3. FILE-SERVER PIN RESOLUTION — explicit-pin-wins; a non-self-signed
//      recipe OR a different-host file-server yields NO spurious pin.
//
// `committedGatewayOnly` (the gateway-committed / file-server-credential-failed
// partial state) is NOT covered: `setFileServerCredential` writes straight to
// the access-group Keychain with no injection seam, and on an unsigned headless
// build the gateway-token write fails FIRST (→ `.failed`, never the partial
// state). It is verified on the signed founder-gate run — see `skipped`.
//
// Test isolation mirrors `SettingsViewModelPairingImportTests`: wipe App-Group
// defaults + per-ref slots (+ KVS mirrors + migration latch) in setUp/tearDown.
// Keychain-bound writes ride the `requireFileServerKeychainOrSkip` XCTSkip gate
// (errSecMissingEntitlement on an unsigned build). Payloads are built from
// locally-constructed JSON strings (no network); privacy: synthetic only.

import XCTest
@testable import Conduck

@MainActor
final class PairingImportBranchTests: XCTestCase {

    /// App Groups UserDefaults — same suite the actor uses internally.
    private let defaults: UserDefaults = {
        UserDefaults(suiteName: Constants.appGroupID) ?? UserDefaults.standard
    }()

    private let openclaw: RemoteAgentRef = .builtin(.openclaw)

    /// Synthetic 64-hex SPKI fingerprints (the parser requires exactly 64 hex).
    private let gatewayFP = String(repeating: "ab", count: 32)
    private let explicitFSFP = String(repeating: "cd", count: 32)

    override func setUp() async throws {
        try await super.setUp()
        await wipePairingState()
    }

    override func tearDown() async throws {
        await wipePairingState()
        try await super.tearDown()
    }

    /// Wipe persistent state touched by the pairing-import paths (mirrors
    /// `SettingsViewModelPairingImportTests.wipePairingState`).
    private func wipePairingState() async {
        for gateway in await SettingsManager.shared.customGateways() {
            await SettingsManager.shared.deleteCustomGateway(id: gateway.id)
        }
        defaults.removeObject(forKey: Constants.customGatewaysRegistryKey)
        NSUbiquitousKeyValueStore.default.removeObject(forKey: Constants.customGatewaysRegistryKey)

        defaults.removeObject(forKey: Constants.remoteAgentDefaultBackendKVSKey)
        NSUbiquitousKeyValueStore.default.removeObject(forKey: Constants.remoteAgentDefaultBackendKVSKey)
        defaults.removeObject(forKey: Constants.remoteAgentActiveSessionKey)

        defaults.removeObject(forKey: Constants.remoteAgentBackendKey)
        defaults.removeObject(forKey: Constants.remoteAgentURLKey)
        defaults.removeObject(forKey: Constants.remoteAgentCertFingerprintKey)
        try? await SettingsManager.shared.clearRemoteAgentToken()

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

        defaults.removeObject(forKey: Constants.remoteAgentMultiGatewayMigratedKey)
        await SettingsManager.shared.resetRemoteAgentMigrationLatchForTesting()
    }

    // MARK: - Fixtures

    /// Build a raw `conduck-setup:v1:` pairing string from locally-constructed
    /// JSON (synthetic values only). Built as a literal-keyed dict so the
    /// fixture does NOT reconstruct the parser's expectations from shared
    /// symbols — the JSON keys/values are hardcoded here.
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

    /// Parse a fixture string into a payload (fails the test on a reject).
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

    /// Fresh VM with the init-load drained (mirrors the sibling harness).
    private func makeVM() async -> SettingsViewModel {
        let vm = SettingsViewModel()
        await vm.loadSettings()
        await Task.yield()
        return vm
    }

    /// Probe the FILE-SERVER credential Keychain slot, skipping on an unsigned
    /// build (errSecMissingEntitlement) — same posture as the sibling suite.
    private func requireFileServerKeychainOrSkip(for ref: RemoteAgentRef) async throws {
        do {
            try await SettingsManager.shared.setFileServerCredential("probe-credential", for: ref)
            try await SettingsManager.shared.clearFileServerCredential(for: ref)
        } catch {
            throw XCTSkip("Keychain access-group write requires a signed build (unsigned: \(error)).")
        }
    }

    // MARK: - 1. Fail-closed auth (parser is the security boundary)

    /// A payload whose `auth` field is an unrecognized string must NOT be
    /// treated as keyless: the parser fails closed to `.bearer`, which REQUIRES
    /// a token. The token-bearing payload therefore parses as a bearer gateway
    /// carrying its token — never as a token-free keyless gateway.
    func testGarbageAuthFieldResolvesToBearerNotKeyless() throws {
        let payload = try makePayload(
            kind: "openclaw",
            auth: "totally-bogus-scheme",
            token: "tok-pairing-test"
        )

        XCTAssertEqual(payload.authScheme, .bearer,
                       "An unknown `auth` value MUST fail closed to .bearer — never silently keyless.")
        XCTAssertEqual(payload.token, "tok-pairing-test",
                       "A garbage-auth payload resolves to .bearer, so its token is REQUIRED and retained.")
    }

    /// The fail-closed corollary: a garbage `auth` value WITHOUT a token cannot
    /// produce a keyless gateway — `.bearer` requires a token, so the whole
    /// payload is rejected as malformed (no keyless escape hatch via a missing
    /// token + an unrecognized scheme).
    func testGarbageAuthFieldWithoutTokenIsRejected() throws {
        let string = try makePairingString(
            kind: "openclaw",
            auth: "totally-bogus-scheme",
            token: nil
        )

        let result = PairingPayload.parse(string)
        guard case .failure(let error) = result else {
            return XCTFail("A garbage-auth + token-less payload must be rejected, not parsed.")
        }
        XCTAssertEqual(error, .malformed,
                       "Unknown auth fails closed to .bearer; .bearer with no token is malformed — never a keyless gateway.")
    }

    /// Keyless is reachable ONLY via the EXPLICIT `"none"` scheme — the one
    /// value that drops the token. This pins the boundary the two tests above
    /// guard: only `"none"` (not absence, not garbage) opts out of auth.
    func testExplicitNoneIsTheOnlyKeylessPath() throws {
        let keyless = try makePayload(kind: "openclaw", auth: "none", token: nil)
        XCTAssertEqual(keyless.authScheme, .none, "An explicit `none` scheme is keyless.")
        XCTAssertNil(keyless.token, "Keyless drops the token entirely.")

        // A stray token under explicit `.none` is DROPPED (keyless stays a
        // token-free state — a leftover token must not survive).
        let keylessWithStrayToken = try makePayload(kind: "openclaw", auth: "none", token: "stray")
        XCTAssertEqual(keylessWithStrayToken.authScheme, .none)
        XCTAssertNil(keylessWithStrayToken.token,
                     "A stray token under explicit `.none` MUST be dropped — keyless stays token-free.")
    }

    // MARK: - 2. Transport-hint clearing on re-import

    /// A re-import that omits the transport hint must NIL-REMOVE a previously
    /// imported hint, not leave the stale value behind. Keyless payloads so the
    /// path carries no Keychain dependency (runs on the unsigned host). The
    /// transport hint is App-Group only — the raw key must never appear in KVS.
    func testReimportWithoutTransportClearsStaleHint() async throws {
        let vm = await makeVM()

        // First import — keyless, carries a tailscale hint.
        let withHint = try makePayload(
            kind: "openclaw",
            auth: "none", token: nil,
            transport: "tailscale"
        )
        let firstOutcome = await vm.executePairingImportUsingPayloadPins(withHint, target: openclaw)
        XCTAssertEqual(firstOutcome, .committed, "A keyless builtin payload must commit.")

        let hintAfterFirst = await SettingsManager.shared.getRemoteAgentTransportHint(for: openclaw)
        XCTAssertEqual(hintAfterFirst, "tailscale", "Precondition: the first import lands the hint.")

        // Independent literal pin: the hint lives ONLY in App-Group defaults at
        // the hardcoded per-ref key, never in iCloud KVS (per-device guidance).
        let hintKey = "remoteAgent.transportHint.openclaw"
        XCTAssertEqual(Constants.remoteAgentTransportHintKey(for: openclaw), hintKey,
                       "The transport-hint key format is LOCKED (Keychain/UserDefaults suffix depends on it).")
        XCTAssertEqual(defaults.string(forKey: hintKey), "tailscale")
        XCTAssertNil(NSUbiquitousKeyValueStore.default.object(forKey: hintKey),
                     "The transport hint must NEVER be dual-written to iCloud KVS.")

        // Re-import the SAME gateway with NO transport hint → must clear it.
        let withoutHint = try makePayload(
            kind: "openclaw",
            auth: "none", token: nil,
            transport: nil
        )
        let secondOutcome = await vm.executePairingImportUsingPayloadPins(withoutHint, target: openclaw)
        XCTAssertEqual(secondOutcome, .committed)

        let hintAfterSecond = await SettingsManager.shared.getRemoteAgentTransportHint(for: openclaw)
        XCTAssertNil(hintAfterSecond,
                     "A re-import that omits the transport hint MUST nil-remove the stale hint, not leave it.")
        XCTAssertNil(defaults.string(forKey: hintKey),
                     "The App-Group key must be removed, not merely shadowed.")
    }

    // MARK: - 3. File-server pin resolution

    /// Explicit-pin-wins: when the fileServer block carries its OWN certFP, that
    /// pin lands verbatim — independent of the gateway pin / transport recipe.
    /// (Keychain-bound — the credential must land for the pin branch to run.)
    func testFileServerExplicitPinWins() async throws {
        try await requireFileServerKeychainOrSkip(for: openclaw)

        let vm = await makeVM()
        // Self-signed + same host (the conditions that WOULD copy the gateway
        // pin) BUT an explicit fs pin is present → the explicit pin must win.
        let payload = try makePayload(
            kind: "openclaw",
            url: "https://gw.example.test:18789",
            auth: "none", token: nil,
            certFP: gatewayFP,
            fileServer: [
                "url": "https://gw.example.test:8443",
                "credential": "feedfacecafebeeffeedfacecafebeef",
                "certFP": explicitFSFP
            ],
            transport: "selfsigned"
        )

        let outcome = await vm.executePairingImportUsingPayloadPins(payload, target: openclaw)
        XCTAssertEqual(outcome, .committed, "A payload with a complete fileServer block must commit on a Keychain-capable host.")

        let fsPin = await SettingsManager.shared.getFileServerCertFingerprint(for: openclaw)
        XCTAssertEqual(fsPin, explicitFSFP,
                       "An explicit fileServer certFP MUST win over the copyable gateway pin.")
        XCTAssertNotEqual(fsPin, gatewayFP,
                          "The gateway pin must NOT shadow an explicit fileServer pin.")
    }

    /// No spurious pin when the recipe is NOT self-signed: a `tailscale`
    /// transport on the SAME host carries no public reason to copy a pin, so the
    /// file-server pin must resolve to nil even though a gateway pin exists.
    func testFileServerNoPinWhenTransportNotSelfsigned() async throws {
        try await requireFileServerKeychainOrSkip(for: openclaw)

        let vm = await makeVM()
        let payload = try makePayload(
            kind: "openclaw",
            url: "https://gw.example.test:18789",
            auth: "none", token: nil,
            certFP: gatewayFP,
            fileServer: [
                "url": "https://gw.example.test:8443",
                "credential": "feedfacecafebeeffeedfacecafebeef"
            ],
            transport: "tailscale"
        )

        let outcome = await vm.executePairingImportUsingPayloadPins(payload, target: openclaw)
        XCTAssertEqual(outcome, .committed)

        let fsPin = await SettingsManager.shared.getFileServerCertFingerprint(for: openclaw)
        XCTAssertNil(fsPin,
                     "A non-self-signed recipe must NOT copy the gateway pin to the file-server — no spurious pin.")
    }

    /// No spurious pin when the file-server rides a DIFFERENT host: even under a
    /// self-signed recipe, the gateway pin only covers its own host, so a
    /// different-host file-server gets no pin.
    func testFileServerNoPinWhenDifferentHost() async throws {
        try await requireFileServerKeychainOrSkip(for: openclaw)

        let vm = await makeVM()
        let payload = try makePayload(
            kind: "openclaw",
            url: "https://gw.example.test:18789",
            auth: "none", token: nil,
            certFP: gatewayFP,
            fileServer: [
                "url": "https://files.example.test:8443",
                "credential": "feedfacecafebeeffeedfacecafebeef"
            ],
            transport: "selfsigned"
        )

        let outcome = await vm.executePairingImportUsingPayloadPins(payload, target: openclaw)
        XCTAssertEqual(outcome, .committed)

        let fsPin = await SettingsManager.shared.getFileServerCertFingerprint(for: openclaw)
        XCTAssertNil(fsPin,
                     "A self-signed gateway pin covers only its own host — a different-host file-server gets NO pin.")
    }
}
