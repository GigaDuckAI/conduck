// Conduck
// RemoteAgentBackendTests.swift
//
// Tests for the `RemoteAgentBackend` enum. Raw values are LOAD-BEARING
// — they round-trip through UserDefaults / Codable to persist the user's
// Settings selection across launches. Renaming `"openclaw"` or `"hermes"`
// orphans every install's existing config.

import XCTest
@testable import Conduck

final class RemoteAgentBackendTests: XCTestCase {

    func testRawValuesAreStable() {
        // Persisted in UserDefaults via `Constants.remoteAgentBackendKey`;
        // round-tripped via Codable. A rename here = silent regression for
        // every user on their next launch.
        XCTAssertEqual(RemoteAgentBackend.openclaw.rawValue, "openclaw")
        XCTAssertEqual(RemoteAgentBackend.hermes.rawValue, "hermes")
    }

    func testDefaultPortsMatchUpstreamDefaults() {
        XCTAssertEqual(RemoteAgentBackend.openclaw.defaultPort, 18789,
                       "OpenClaw default port is upstream-documented as 18789")
        XCTAssertEqual(RemoteAgentBackend.hermes.defaultPort, 8642,
                       "Hermes default port is upstream-documented as 8642")
    }

    func testCodableRoundTrip() throws {
        for backend in RemoteAgentBackend.allCases {
            let encoded = try JSONEncoder().encode(backend)
            let decoded = try JSONDecoder().decode(RemoteAgentBackend.self, from: encoded)
            XCTAssertEqual(decoded, backend, "Codable round-trip must preserve backend identity")
        }
    }
}
