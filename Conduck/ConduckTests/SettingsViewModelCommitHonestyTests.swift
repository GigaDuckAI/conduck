// SPDX-License-Identifier: Apache-2.0

// Conduck
// SettingsViewModelCommitHonestyTests.swift
//
// The gateway commit path must never report a success it did not achieve, and
// an editor must be able to learn that a commit happened underneath it.
//
// These four contracts hang together. A save that reports success while
// persisting less than it claims produces a ref with per-ref slots but no roster
// row — which `cancelRemoteAgentEdit` reads as a never-stored draft and WIPES,
// destroying a config the user was told had been saved. A post-import probe that
// falls back to the payload proves the server is reachable while proving nothing
// about what was stored, so the same short commit still earns a green
// "Connected". And an editor that infers "was this committed?" from the cached
// configured set can read a stale `false` for a gateway just written.
//
//   1. `setRemoteAgentURL` REPORTS a refused write (the `EndpointURLPolicy`
//      write fence) instead of returning silently.
//   2. A refused roster upsert at `Constants.maxCustomGateways` FAILS the save.
//   3. `runPairingGatewayTest` reads ONLY persisted config — no payload
//      fallback — so an incomplete commit cannot pass the connectivity stage.
//   4. `remoteAgentCommitEpoch` increments once per successful commit, giving
//      the editor a monotonic receipt with no stale value to misread.
//
// Deliberately NOT tested here: the stale-load race itself. Reproducing it needs
// a scheduler barrier that does not exist in the code; a timing-dependent test
// would be flaky and would assert nothing durable.

import XCTest
@testable import Conduck

@MainActor
final class SettingsViewModelCommitHonestyTests: XCTestCase {

    /// App Groups UserDefaults — same suite the actor uses internally.
    private let defaults: UserDefaults = {
        UserDefaults(suiteName: Constants.appGroupID) ?? UserDefaults.standard
    }()

    private let openclaw: RemoteAgentRef = .builtin(.openclaw)

    override func setUp() async throws {
        try await super.setUp()
        await wipeGatewayState()
    }

    override func tearDown() async throws {
        await wipeGatewayState()
        try await super.tearDown()
    }

    /// Wipe every slot these tests touch. Dual-write setters mean BOTH the
    /// App-Group defaults and the iCloud KVS mirror have to go (test-isolation
    /// rule) — a surviving KVS value would hydrate straight back.
    private func wipeGatewayState() async {
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
                Constants.remoteAgentTransportHintKey(for: ref)
            ] {
                defaults.removeObject(forKey: key)
                NSUbiquitousKeyValueStore.default.removeObject(forKey: key)
            }
            try? await SettingsManager.shared.clearRemoteAgentToken(for: ref)
        }

        defaults.removeObject(forKey: Constants.remoteAgentMultiGatewayMigratedKey)
        await SettingsManager.shared.resetRemoteAgentMigrationLatchForTesting()
    }

    // MARK: - 1. The URL write fence reports refusal

    /// An inadmissible URL is refused by the fence, and the setter now SAYS so.
    /// Without a return value the caller could only assume it landed — which is
    /// how a save reports success over a gateway with no endpoint.
    func testSetRemoteAgentURLReportsRefusal() async {
        let bad = URL(string: "http://gateway.example.test:18789")!   // http → inadmissible
        let accepted = await SettingsManager.shared.setRemoteAgentURL(bad, for: openclaw)
        XCTAssertFalse(accepted,
                       "The write fence refused this URL, so the setter must report false — a silent return lets a caller claim a save that never happened.")
        let stored = await SettingsManager.shared.getRemoteAgentURL(for: openclaw)
        XCTAssertNil(stored,
                     "A refused write must leave the slot untouched.")
    }

    /// The happy path still reports true, so `false` genuinely means refused
    /// rather than "this setter always returns false".
    func testSetRemoteAgentURLReportsSuccess() async {
        let good = URL(string: "https://gateway.example.test:18789")!
        let accepted = await SettingsManager.shared.setRemoteAgentURL(good, for: openclaw)
        XCTAssertTrue(accepted, "An admissible https URL must report a successful write.")
        let stored = await SettingsManager.shared.getRemoteAgentURL(for: openclaw)
        XCTAssertEqual(stored?.absoluteString, good.absoluteString)
    }

    /// Clearing is not a refusal — nil always succeeds, so a teardown path can't
    /// be misread as a failed write.
    func testSetRemoteAgentURLClearReportsSuccess() async {
        let accepted = await SettingsManager.shared.setRemoteAgentURL(nil, for: openclaw)
        XCTAssertTrue(accepted, "Clearing a URL is always a successful write.")
    }

    // MARK: - 2. A refused roster upsert fails the save

    /// `upsertCustomGateway` refuses an ADD past `Constants.maxCustomGateways`.
    /// The save path must treat that as a failed save: reporting success would
    /// leave per-ref slots with no roster row, and `cancelRemoteAgentEdit` reads
    /// exactly that shape as a never-stored draft and wipes it.
    func testRosterCapRefusalFailsTheSave() async {
        // Fill the roster to the cap.
        for index in 0..<Constants.maxCustomGateways {
            let accepted = await SettingsManager.shared.upsertCustomGateway(
                CustomGateway(id: UUID(), name: "Gateway \(index)", model: nil, colorID: nil, monogram: nil)
            )
            XCTAssertTrue(accepted, "Filling to the cap must succeed for index \(index).")
        }

        // One more ADD must be refused.
        let overflowID = UUID()
        let refused = await SettingsManager.shared.upsertCustomGateway(
            CustomGateway(id: overflowID, name: "Overflow", model: nil, colorID: nil, monogram: nil)
        )
        XCTAssertFalse(refused, "An ADD past the cap must be refused — this is the Bool the save path must not discard.")

        // And the save that would have relied on it must fail, leaving nothing.
        let vm = SettingsViewModel()
        let overflowRef = RemoteAgentRef.custom(overflowID)
        vm.remoteAgentURLStrings[overflowRef] = "https://overflow.example.test:18789"
        vm.remoteAgentAuthSchemes[overflowRef] = .none   // keyless → no Keychain dependency

        let saved = await vm.saveRemoteAgent(ref: overflowRef, name: "Overflow", stagedToken: .stored)
        XCTAssertFalse(saved,
                       "A save whose roster upsert was refused must FAIL — reporting success strands per-ref slots with no roster row, which the discard path then wipes.")

        let roster = await SettingsManager.shared.customGateways()
        XCTAssertEqual(roster.count, Constants.maxCustomGateways,
                       "The refused save must not have grown the roster.")
        let orphanedURL = await SettingsManager.shared.getRemoteAgentURL(for: overflowRef)
        XCTAssertNil(orphanedURL,
                     "A failed save must persist NOTHING — no orphaned URL slot.")
    }

    // MARK: - 3. The post-import probe reads storage only

    /// Storage holds no URL for the target, but the payload does. The probe must
    /// fail on the empty storage rather than reaching for the payload — a
    /// payload-fed probe would prove the SERVER is reachable while proving
    /// nothing about what was saved, and the flow would show "Connected" over a
    /// gateway the editor reads as unconfigured.
    func testPairingGatewayTestDoesNotFallBackToPayloadURL() async {
        let vm = SettingsViewModel()
        let payload = PairingPayload(
            kind: .builtin(.openclaw),
            url: URL(string: "https://payload-only.example.test:18789")!,
            authScheme: .bearer,
            token: "tok-payload-only",
            model: nil,
            fileServer: nil,
            transport: nil
        )

        // Nothing persisted for this ref (setUp wiped it).
        let storedURL = await SettingsManager.shared.getRemoteAgentURL(for: openclaw)
        XCTAssertNil(storedURL,
                     "Precondition: storage must be empty for this ref.")

        let outcome = await vm.runPairingGatewayTest(payload, target: openclaw)
        guard case .failed(_, let error) = outcome else {
            return XCTFail("An unreadable commit must fail the connectivity stage, not pass it from the payload. Got: \(outcome)")
        }
        XCTAssertEqual(error?.errorCode, AppError.remoteAgentNotConfigured.errorCode,
                       "The failure must be typed as not-configured so the sheet renders it as terminal — re-probing reads the same short storage.")
        XCTAssertEqual(error?.isRetryable, false,
                       "`retryStages()` never redoes the save stage, so offering a retry would reach the identical verdict.")
    }

    /// The bearer half of the same rule: a stored URL with NO stored token must
    /// not borrow the payload's token.
    func testPairingGatewayTestDoesNotFallBackToPayloadToken() async {
        let vm = SettingsViewModel()
        let url = URL(string: "https://gw.example.test:18789")!
        await SettingsManager.shared.setRemoteAgentURL(url, for: openclaw)
        await SettingsManager.shared.setRemoteAgentAuthScheme(.bearer, for: openclaw)
        try? await SettingsManager.shared.clearRemoteAgentToken(for: openclaw)

        let payload = PairingPayload(
            kind: .builtin(.openclaw),
            url: url,
            authScheme: .bearer,
            token: "tok-payload-only",
            model: nil,
            fileServer: nil,
            transport: nil
        )

        let outcome = await vm.runPairingGatewayTest(payload, target: openclaw)
        guard case .failed(_, let error) = outcome else {
            return XCTFail("A bearer lane with no STORED token must fail, not probe with the payload's token. Got: \(outcome)")
        }
        XCTAssertEqual(error?.errorCode, AppError.remoteAgentNotConfigured.errorCode,
                       "A missing stored token is a not-configured commit, not a network failure.")
    }

    // MARK: - 4. The commit receipt

    /// The editor's post-import recovery gates on this counter, so it must move
    /// exactly once per successful commit — and it must move for an ORDINARY
    /// save too, not only a pairing import (the guided cover also hosts
    /// hosted-model setup, which commits through the same method).
    func testCommitEpochIncrementsOnSuccessfulSave() async {
        let vm = SettingsViewModel()
        // Drain the init-load so a later async reload can't wipe the buffers.
        await vm.loadSettings()
        await Task.yield()

        XCTAssertNil(vm.remoteAgentCommitEpoch[openclaw],
                     "No commit yet — the epoch starts absent, which reads as 0.")

        vm.remoteAgentURLStrings[openclaw] = "https://gw.example.test:18789"
        // Keyless → no Keychain dependency on the unsigned host.
        vm.setRemoteAgentAuthSchemeBuffer(.none, for: openclaw)

        let first = await vm.saveRemoteAgent(ref: openclaw, name: nil, stagedToken: .stored)
        XCTAssertTrue(first, "Precondition: the keyless save must succeed.")
        XCTAssertEqual(vm.remoteAgentCommitEpoch[openclaw], 1,
                       "A successful commit must stamp the receipt the editor compares against.")

        let second = await vm.saveRemoteAgent(ref: openclaw, name: nil, stagedToken: .stored)
        XCTAssertTrue(second, "Precondition: the second save must also succeed.")
        XCTAssertEqual(vm.remoteAgentCommitEpoch[openclaw], 2,
                       "Every commit bumps — the editor compares against a snapshot, so a repeated save must still register as movement.")

        await vm.clearRemoteAgent(for: openclaw)
    }

    /// A FAILED save must not stamp a receipt: the editor would otherwise
    /// rehydrate from storage that was never written, wiping live buffers.
    func testCommitEpochDoesNotMoveOnFailedSave() async {
        let vm = SettingsViewModel()
        await vm.loadSettings()
        await Task.yield()
        // Empty URL buffer → the save's own URL guard rejects before any write.
        vm.remoteAgentURLStrings[openclaw] = ""
        vm.setRemoteAgentAuthSchemeBuffer(.none, for: openclaw)

        let saved = await vm.saveRemoteAgent(ref: openclaw, name: nil, stagedToken: .stored)
        XCTAssertFalse(saved, "Precondition: an empty URL must fail the save.")
        XCTAssertNil(vm.remoteAgentCommitEpoch[openclaw],
                     "A failed save must leave the receipt untouched — a bump would make the editor rehydrate from storage that holds nothing.")
    }
}
