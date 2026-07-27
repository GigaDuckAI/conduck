// SPDX-License-Identifier: Apache-2.0

// Conduck
// RemoteAgentRoutingTests.swift
//
// Multi-gateway — the per-conversation routing resolver
// `SettingsManager.remoteAgentSnapshot(forConversationBackend:)`. A turn in a
// conversation bound to backend X must route to X's gateway even when the
// default pointer names a DIFFERENT backend (per-conversation gateway binding,
// no silent reroute to default). Covers:
//   - hermes-bound conversation routes to Hermes even when default is OpenClaw
//   - an unconfigured bound backend → nil (caller maps to remoteAgentNotConfigured)
//   - an unknown raw value → nil
//
// URL-only configuration is enough to make a backend "snapshot-able" (token is
// independently optional in the snapshot), so these tests don't need a signed
// Keychain write.

import XCTest
@testable import Conduck

final class RemoteAgentRoutingTests: XCTestCase {

    private let defaults: UserDefaults = {
        UserDefaults(suiteName: Constants.appGroupID) ?? UserDefaults.standard
    }()

    override func setUp() async throws {
        try await super.setUp()
        await wipe()
    }

    override func tearDown() async throws {
        await wipe()
        try await super.tearDown()
    }

    private func wipe() async {
        defaults.removeObject(forKey: Constants.remoteAgentDefaultBackendKVSKey)
        defaults.removeObject(forKey: Constants.remoteAgentActiveSessionKey)
        for backend in RemoteAgentBackend.allCases {
            defaults.removeObject(forKey: Constants.remoteAgentURLKey(for: backend))
            defaults.removeObject(forKey: Constants.remoteAgentCertFingerprintKey(for: backend))
            try? await SettingsManager.shared.clearRemoteAgentToken(for: backend)
        }
    }

    func testRoutesToBoundBackendNotDefault() async throws {
        // Default = OpenClaw; configure Hermes's URL; bind the conversation to Hermes.
        await SettingsManager.shared.setDefaultRemoteAgentBackend(.openclaw)
        let hURL = try XCTUnwrap(URL(string: "https://hermes.example.test:8642"))
        await SettingsManager.shared.setRemoteAgentURL(hURL, for: .hermes)

        let snapshotOptional = await SettingsManager.shared.remoteAgentSnapshot(
            forConversationBackend: RemoteAgentBackend.hermes.rawValue
        )
        let snapshot = try XCTUnwrap(snapshotOptional,
                                     "A Hermes-bound conversation must resolve Hermes's snapshot even under an OpenClaw default.")
        XCTAssertEqual(snapshot.backend, .hermes)
        XCTAssertEqual(snapshot.url, hURL,
                       "Routing must use the BOUND backend's URL, never silently reroute to the default backend.")
    }

    func testUnconfiguredBoundBackendReturnsNil() async {
        // Hermes is the bound backend but has no URL configured.
        await SettingsManager.shared.setDefaultRemoteAgentBackend(.openclaw)
        let snapshot = await SettingsManager.shared.remoteAgentSnapshot(
            forConversationBackend: RemoteAgentBackend.hermes.rawValue
        )
        XCTAssertNil(snapshot,
                     "An unconfigured bound backend must resolve nil — the caller maps nil to remoteAgentNotConfigured (no reroute).")
    }

    func testUnknownRawValueReturnsNil() async {
        let snapshot = await SettingsManager.shared.remoteAgentSnapshot(
            forConversationBackend: "some-future-backend"
        )
        XCTAssertNil(snapshot, "An unknown backend raw value must resolve nil (forward-compat).")
    }

    func testEmptyRawValueReturnsNil() async {
        // An unbound / blank conversation backend (defensive-init fallback "")
        // must not crash and must resolve nil.
        let snapshot = await SettingsManager.shared.remoteAgentSnapshot(
            forConversationBackend: ""
        )
        XCTAssertNil(snapshot)
    }
}
