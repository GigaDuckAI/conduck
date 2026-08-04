// SPDX-License-Identifier: Apache-2.0

// Conduck
// WatchTeardownEnvelopeTests.swift
//
// The iPhone half of the Watch teardown contract: forgetting your LAST gateway
// must reach the wrist, and NOTHING else may ever look like that instruction.
//
// The bug this locks: `currentRemoteAgentMultiEnvelope()` returned nil for an
// empty configured set, so `PhoneSessionManager` omitted the gateway slot from
// the payload entirely — on BOTH the push broadcast and the Watch-initiated
// pull, which share one composition site. The wrist therefore kept a live route
// (URL + auth scheme + Keychain token) to a gateway the user had forgotten,
// across relaunches, and Forget is local to the phone so the token stayed valid
// at the server.
//
// The half that matters more is the guard, not the fix. "Nothing is configured"
// is ALSO what a restored device reads before iCloud KVS downloads, what a
// locked Keychain reads before first unlock (the bearer predicate fails
// closed), and what a device with an unsynced custom roster reads. Broadcast a
// teardown on that reading and a healthy Watch loses its credentials. So
// destruction is authorized by a recorded user action
// (`Constants.remoteAgentUserClearedAllKey`) and by nothing else — these tests
// exist mainly to keep that distinction from being "simplified" away.
//
// iCloud is suspended for the suite (the `.shared` singleton dual-writes KVS;
// a signed-in sim leaks cross-suite state into the absence assertions).
//
// Keychain-free by construction: every fixture gateway is KEYLESS
// (`.none` + URL), which `isRemoteAgentConfigured` accepts without a token —
// so the whole suite runs on an unsigned build instead of skipping.
//
// Privacy: synthetic fixtures only (`*.example.test`) — never logged.

import XCTest
@testable import Conduck

final class WatchTeardownEnvelopeTests: XCTestCase {

    private let defaults = TestStores.defaults
    private let openclaw: RemoteAgentRef = .builtin(.openclaw)

    override func setUp() async throws {
        try await super.setUp()
        await SettingsManager.shared.setICloudSyncSuspendedForTesting(true)
        await wipeAll()
    }

    override func tearDown() async throws {
        await wipeAll()
        await SettingsManager.shared.setICloudSyncSuspendedForTesting(false)
        try await super.tearDown()
    }

    private func wipeAll() async {
        for gateway in await SettingsManager.shared.customGateways() {
            await SettingsManager.shared.deleteCustomGateway(id: gateway.id)
        }
        defaults.removeObject(forKey: Constants.customGatewaysRegistryKey)
        TestStores.kvs.removeObject(forKey: Constants.customGatewaysRegistryKey)
        defaults.removeObject(forKey: Constants.remoteAgentUserClearedAllKey)
        defaults.removeObject(forKey: Constants.remoteAgentDefaultBackendKVSKey)
        TestStores.kvs.removeObject(forKey: Constants.remoteAgentDefaultBackendKVSKey)
        defaults.removeObject(forKey: Constants.remoteAgentActiveSessionKey)

        for backend in RemoteAgentBackend.allCases {
            let ref = RemoteAgentRef.builtin(backend)
            for key in [
                Constants.remoteAgentURLKey(for: ref),
                Constants.remoteAgentCertFingerprintKey(for: ref),
                Constants.remoteAgentAuthSchemeKey(for: ref),
                Constants.remoteAgentModelKey(for: ref)
            ] {
                defaults.removeObject(forKey: key)
                TestStores.kvs.removeObject(forKey: key)
            }
            try? await SettingsManager.shared.clearRemoteAgentToken(for: ref)
        }
    }

    /// Configure a KEYLESS gateway — URL + an explicit `.none` auth scheme is
    /// enough for `isRemoteAgentConfigured`, so no Keychain write is involved
    /// and the test runs unsigned.
    private func configureKeyless(_ ref: RemoteAgentRef) async {
        await SettingsManager.shared.setRemoteAgentURL(
            URL(string: "https://gateway.example.test")!, for: ref
        )
        await SettingsManager.shared.setRemoteAgentAuthScheme(.none, for: ref)
    }

    // MARK: - The latch is the only authority

    func testNothingConfiguredAndLatchDisarmedSendsNoEnvelope() async {
        let envelope = await SettingsManager.shared.currentRemoteAgentMultiEnvelope()

        XCTAssertNil(envelope,
                     "An empty configured set is NOT evidence of deletion — it is also a restored device before KVS lands, and a locked Keychain before first unlock. Inferring teardown here wipes a healthy Watch.")
    }

    func testLatchArmedSendsAnExplicitTeardownEnvelope() async {
        await SettingsManager.shared.setUserClearedAllGateways(true)

        let envelope = await SettingsManager.shared.currentRemoteAgentMultiEnvelope()

        XCTAssertNotNil(envelope,
                        "A recorded user Forget must reach the wrist — this is the whole point of the fix.")
        XCTAssertEqual(envelope?.backends.count, 0)
        XCTAssertEqual(envelope?.clearAll, true,
                       "Teardown rides an EXPLICIT flag; the Watch must never have to infer it from an empty array.")
    }

    func testTeardownEnvelopeCarriesADecodableDefaultRef() async throws {
        await SettingsManager.shared.setUserClearedAllGateways(true)

        let built = await SettingsManager.shared.currentRemoteAgentMultiEnvelope()
        let envelope = try XCTUnwrap(built)

        XCTAssertFalse(envelope.defaultBackendRef.isEmpty,
                       "`decode` REJECTS an empty `defaultBackend`, so a teardown carrying one would be silently discarded by the Watch and the gateway would live on.")
        let roundTripped = RemoteAgentMultiBroadcastEnvelope.decode(from: envelope.encodedDict())
        XCTAssertEqual(roundTripped?.clearAll, true,
                       "The teardown must survive the plist wire round-trip.")
    }

    // MARK: - Disarming

    func testAConfiguredGatewayDisarmsTheLatchAndSendsANormalEnvelope() async {
        await SettingsManager.shared.setUserClearedAllGateways(true)
        await configureKeyless(openclaw)

        let envelope = await SettingsManager.shared.currentRemoteAgentMultiEnvelope()

        XCTAssertEqual(envelope?.backends.count, 1)
        XCTAssertNil(envelope?.clearAll,
                     "A normal envelope must carry no teardown flag.")
        let stillArmed = await SettingsManager.shared.userClearedAllGateways()
        XCTAssertFalse(stillArmed,
                       "Composing a real envelope proves the phone has gateways again — a latch left armed would courier a teardown at every subsequent broadcast.")
    }

    func testLatchSurvivesRepeatedBroadcastsWhileStillEmpty() async {
        await SettingsManager.shared.setUserClearedAllGateways(true)

        _ = await SettingsManager.shared.currentRemoteAgentMultiEnvelope()
        let second = await SettingsManager.shared.currentRemoteAgentMultiEnvelope()

        XCTAssertEqual(second?.clearAll, true,
                       "Re-broadcasting a genuine teardown is correct: it keeps advancing the Watch's high-water mark so an OLD queued full envelope can't resurrect the credentials.")
    }

    // MARK: - Arming condition

    func testForgettingTheLastGatewayArmsTheLatch() async {
        await configureKeyless(openclaw)
        let vm = await SettingsViewModel()
        await vm.loadSettings()

        await vm.clearRemoteAgent(for: openclaw)

        let armed = await SettingsManager.shared.userClearedAllGateways()
        XCTAssertTrue(armed,
                      "Forgetting the last gateway is the ONLY moment the intent exists; if it isn't recorded here the wrist keeps a working route forever.")
    }

    func testForgettingOneOfTwoGatewaysDoesNotArmTheLatch() async {
        await configureKeyless(openclaw)
        await configureKeyless(.builtin(.hermes))
        let vm = await SettingsViewModel()
        await vm.loadSettings()

        await vm.clearRemoteAgent(for: openclaw)

        let armed = await SettingsManager.shared.userClearedAllGateways()
        XCTAssertFalse(armed,
                       "Hermes is still there — a teardown would destroy ITS Watch credentials too.")
    }
}
