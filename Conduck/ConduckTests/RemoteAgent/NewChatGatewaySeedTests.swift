// SPDX-License-Identifier: Apache-2.0

// Conduck
// NewChatGatewaySeedTests.swift
//
// The new-chat picker's pre-selection ladder. Pure input → output, which is the
// whole point of the resolver living outside the two SwiftUI views that consume it
// (`ContentView.refreshGatewayRoster` / `MainWindowView.refreshConfiguredBackends`,
// neither reachable from a unit test, and both previously carrying their own copy
// of this logic).
//
// SCOPE WARNING: these tests cover the ladder, NOT its call sites. They cannot
// catch the mistake the call sites actually risk — a suspension introduced between
// the hand-pick flag being read and the picker being written, which is the race the
// flag exists to close. That one is guarded by comments at both call sites only.

import XCTest
@testable import Conduck

final class NewChatGatewaySeedTests: XCTestCase {

    private let openclaw = RemoteAgentRef.builtin(.openclaw)
    private let hermes = RemoteAgentRef.builtin(.hermes)
    private let openrouter = RemoteAgentRef.builtin(.openrouter)

    func testLastUsedWinsOverTheDefault() {
        let seed = NewChatGatewaySeed.resolve(
            configured: [openclaw, hermes],
            lastUsed: hermes,
            persistedDefault: openclaw
        )

        XCTAssertEqual(seed, hermes, "Continue where the user left off — the feature in one assertion.")
    }

    /// Locks today's behaviour as the untouched fallback: with no last-used, the
    /// picker still opens on the Settings default exactly as it always did.
    func testNoLastUsedFallsBackToTheDefault() {
        let seed = NewChatGatewaySeed.resolve(
            configured: [openclaw, hermes],
            lastUsed: nil,
            persistedDefault: openclaw
        )

        XCTAssertEqual(seed, openclaw)
    }

    /// The forgotten-gateway and half-configured cases both land here: the getter
    /// hands back a hint, and THIS is the gate that rejects it.
    func testUnconfiguredLastUsedFallsBackToTheDefault() {
        let seed = NewChatGatewaySeed.resolve(
            configured: [openclaw],
            lastUsed: hermes,
            persistedDefault: openclaw
        )

        XCTAssertEqual(seed, openclaw, "A suggestion that cannot send must never be pre-selected.")
    }

    func testNeitherConfiguredFallsBackToTheFirstConfigured() {
        let seed = NewChatGatewaySeed.resolve(
            configured: [openrouter],
            lastUsed: hermes,
            persistedDefault: openclaw
        )

        XCTAssertEqual(seed, openrouter, "Never present a selection the user cannot send on.")
    }

    /// Reached only when the picker is hidden anyway; the caller still needs a
    /// non-optional value to hold, so this must not crash or invent one.
    func testEmptyConfiguredFallsBackToTheDefault() {
        let seed = NewChatGatewaySeed.resolve(
            configured: [],
            lastUsed: hermes,
            persistedDefault: openclaw
        )

        XCTAssertEqual(seed, openclaw)
    }

    func testLastUsedEqualToTheDefaultIsStable() {
        let seed = NewChatGatewaySeed.resolve(
            configured: [openclaw, hermes],
            lastUsed: openclaw,
            persistedDefault: openclaw
        )

        XCTAssertEqual(seed, openclaw)
    }
}
