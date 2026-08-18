// SPDX-License-Identifier: Apache-2.0

// Conduck
// DefaultGatewayTokenProbeTests.swift
//
// The default gateway as a `KeyArrivalMonitor` subject, in two halves:
//
//   - The eight-verdict → three-reading MAPPING. Pure, so it is asserted
//     exhaustively over constructed resolutions rather than through storage.
//     Two of the eight arms are load-bearing and neither is obvious from the
//     call site: a PARKED unavailable pointer must read `.notRequired` (nobody
//     is waiting on a placeholder the app wrote itself, and a window spent on it
//     is a window the real subject does not get), and `.readingUnreliable` must
//     read `.degraded` (it is the one verdict a bounded poll exists to repair).
//     Flip either and nothing else in the app fails.
//
//   - The probe's PURITY. The monitor polls on a background timer and from a
//     `.settingsDidChangeRemotely` handler, and `resolveDefaultGateway()`'s own
//     doc forbids exactly that: it can adopt a default, drop a dangling pointer
//     or bootstrap one, then post the notification whose handler called it. So
//     the probe reads through `defaultGatewayVerdictWithoutRepair()`, and the
//     tests below pin that it writes nothing on the two arms that otherwise
//     would.

import XCTest
@testable import Conduck

@MainActor
final class DefaultGatewayTokenProbeTests: XCTestCase {

    private var defaults: InMemoryDefaultsStore { TestStores.defaults }

    override func setUp() async throws {
        try await super.setUp()
        TestStores.removeAll()
    }

    override func tearDown() async throws {
        TestStores.removeAll()
        try await super.tearDown()
    }

    /// A gateway that can send, with a BEARER token rather than the keyless
    /// scheme the sibling suites use. That is required, not incidental: adoption
    /// and bootstrap both gate on `isKeychainProvenReadable`, which is true only
    /// when some configured gateway carries a token-bearing scheme. A keyless
    /// fixture never reaches the repair arms these tests exist to pin.
    private func makeSendable(_ backend: RemoteAgentBackend) async throws {
        let ref = RemoteAgentRef.builtin(backend)
        defaults.set("https://\(backend.rawValue).example.test",
                     forKey: Constants.remoteAgentURLKey(for: ref))
        defaults.set(RemoteAgentAuthScheme.bearer.rawValue,
                     forKey: Constants.remoteAgentAuthSchemeKey(for: ref))
        try await SettingsManager.shared.setRemoteAgentToken("probe-token", for: ref)
    }

    private func storeDefaultPointer(_ ref: RemoteAgentRef) {
        defaults.set(ref.rawString, forKey: Constants.remoteAgentDefaultBackendKVSKey)
    }

    // MARK: - The mapping

    /// Every verdict that means "the pointer can send" ends a window rather than
    /// opening one — including the two repair arms, which are already answers.
    func testASendablePointerReadsAsArrived() {
        let openclaw = RemoteAgentRef.builtin(.openclaw)
        let hermes = RemoteAgentRef.builtin(.hermes)

        XCTAssertEqual(DefaultGatewayTokenProbe(resolution: .usable(openclaw)).reading, .arrived)
        XCTAssertEqual(
            DefaultGatewayTokenProbe(resolution: .adopted(ref: hermes, replacing: openclaw)).reading,
            .arrived,
            "an adopted default can send; nothing is in flight"
        )
        XCTAssertEqual(DefaultGatewayTokenProbe(resolution: .bootstrapped(hermes)).reading, .arrived)
    }

    /// THE case the monitor exists for: a pointer the USER chose that cannot send
    /// here. A token still crossing iCloud Keychain reads exactly like one that is
    /// gone, and only time tells them apart.
    func testAnUnavailableChosenPointerReadsAsDegraded() {
        let openclaw = RemoteAgentRef.builtin(.openclaw)
        let probe = DefaultGatewayTokenProbe(resolution: .defaultUnavailable(
            pointer: openclaw, candidates: [.builtin(.hermes)], pointerIsParked: false
        ))
        XCTAssertEqual(probe.reading, .degraded)
        XCTAssertEqual(probe.ref, openclaw, "the window is identified by the pointer it is waiting on")
    }

    /// The same verdict, PARKED, must not poll. The app wrote the pointer itself
    /// as a placeholder after a Forget, so there is no user choice to restore —
    /// the screens are already asking the user to pick. A window spent here is a
    /// window spent on nobody's question.
    func testAParkedUnavailablePointerReadsAsNotRequired() {
        let probe = DefaultGatewayTokenProbe(resolution: .defaultUnavailable(
            pointer: .builtin(.openclaw), candidates: [.builtin(.hermes)], pointerIsParked: true
        ))
        XCTAssertEqual(probe.reading, .notRequired,
                       "a placeholder the app wrote is not a secret anyone is waiting for")
    }

    /// `.readingUnreliable` is a gateway that meets every non-Keychain
    /// requirement and is waiting only on a token that will not read back — a
    /// blackout or a half-arrived sync. It is the one verdict on which nothing
    /// else in the app may act, and the one a bounded poll repairs.
    func testAnUnreadableKeychainReadsAsDegraded() {
        XCTAssertEqual(
            DefaultGatewayTokenProbe(resolution: .readingUnreliable(pointer: .builtin(.openclaw))).reading,
            .degraded
        )
    }

    /// Nothing is in flight in any of these: the user has a choice to make, has
    /// configured nothing, or left a setup unfinished.
    func testVerdictsWithNoSecretInFlightReadAsNotRequired() {
        let openclaw = RemoteAgentRef.builtin(.openclaw)
        for resolution: DefaultGatewayResolution in [
            .selectionRequired(candidates: [openclaw, .builtin(.hermes)]),
            .nothingConfigured(pointer: openclaw),
            .setupUnfinished(pointer: openclaw)
        ] {
            XCTAssertEqual(DefaultGatewayTokenProbe(resolution: resolution).reading, .notRequired,
                           "\(resolution) has no secret in flight")
        }
    }

    /// The requirement key is the pointer, so re-pointing the default retires any
    /// window open on the old one — the user has answered the question it asked.
    func testTheRequirementKeyTracksThePointer() {
        let openclaw = DefaultGatewayTokenProbe(resolution: .readingUnreliable(pointer: .builtin(.openclaw)))
        let hermes = DefaultGatewayTokenProbe(resolution: .readingUnreliable(pointer: .builtin(.hermes)))
        XCTAssertNotEqual(openclaw.arrivalReading.requirementKey, hermes.arrivalReading.requirementKey)
        XCTAssertEqual(openclaw.arrivalReading.reading, .degraded,
                       "the erased reading carries the same verdict the probe computed")
    }

    // MARK: - Purity (the probe must never repair)

    /// One send-able gateway plus a stored pointer that cannot send is the
    /// ADOPTION arm: the repairing resolver rewrites the stored default and files
    /// an adoption notice. A poll must do neither — and must still report that
    /// nothing is waiting, so it does not open a window on a resolved question.
    func testProbingDoesNotAdoptTheOnlyWorkingGateway() async throws {
        try await makeSendable(.hermes)
        storeDefaultPointer(.builtin(.openclaw))

        let probe = await SettingsManager.shared.defaultGatewayTokenProbe()

        XCTAssertEqual(probe.reading, .arrived,
                       "the verdict is unchanged by not writing — this device has a working answer")
        XCTAssertEqual(defaults.string(forKey: Constants.remoteAgentDefaultBackendKVSKey),
                       RemoteAgentRef.builtin(.openclaw).rawString,
                       "the stored pointer must survive a poll untouched")
        XCTAssertNil(defaults.data(forKey: Constants.remoteAgentAdoptedDefaultNoticeKey),
                     "and a background poll must not file a notice a screen will later announce")
    }

    /// The BOOTSTRAP arm: no pointer stored, exactly one gateway that can send.
    /// The repairing resolver writes the pointer; a poll may not.
    func testProbingDoesNotBootstrapAPointer() async throws {
        try await makeSendable(.hermes)

        let probe = await SettingsManager.shared.defaultGatewayTokenProbe()

        XCTAssertEqual(probe.reading, .arrived)
        XCTAssertNil(defaults.string(forKey: Constants.remoteAgentDefaultBackendKVSKey),
                     "a poll must not invent a default the user never chose")
    }

    /// The repairing entry point still repairs — the guard above must not have
    /// been bought by breaking the behaviour every real surface depends on.
    func testTheRepairingResolverStillAdopts() async throws {
        try await makeSendable(.hermes)
        storeDefaultPointer(.builtin(.openclaw))

        let resolution = await SettingsManager.shared.resolveDefaultGateway()

        XCTAssertEqual(resolution, .adopted(ref: .builtin(.hermes), replacing: .builtin(.openclaw)))
        XCTAssertEqual(defaults.string(forKey: Constants.remoteAgentDefaultBackendKVSKey),
                       RemoteAgentRef.builtin(.hermes).rawString,
                       "the ordinary path writes the adoption through")
    }
}
