// SPDX-License-Identifier: Apache-2.0

// Conduck
// WatchDefaultOverrideRetentionTests.swift
//
// The Watch default override survives a TRANSIENT not-send-able verdict.
//
// Why this needs its own suite: the override is App-Group-local, never synced,
// and recreated by nothing, while the predicate that judges it
// (`configuredRemoteAgentRefs()`) fails CLOSED on an unreadable Keychain — which
// is also the reading on a device restored from backup before iCloud Keychain
// has delivered. A reader that DELETED on that verdict would reroute every wrist
// capture to the phone's default permanently, from one blackout.
//
// So the contract is ignore-but-retain, the same policy `lastUsedRemoteAgentRef()`
// documents: report the override absent while it cannot send (the broadcast
// envelope must never carry a dead ref), keep the stored string, and answer with
// it again the moment the gateway can send. Intent-driven removal stays at its
// sources — `GatewayForget` clears it for EITHER kind of ref and
// `deleteCustomGateway` clears it eagerly for the custom path, both pinned here
// so the retention rule cannot be read as "never remove".
//
// Drives an isolated `SettingsManager(dependencies: .inMemory())`: the Keychain
// is a dictionary, so "the token is not readable" is staged by deleting it and
// the case runs unsigned.

import XCTest
@testable import Conduck

final class WatchDefaultOverrideRetentionTests: XCTestCase {

    private struct Rig {
        let manager: SettingsManager
        let defaults: InMemoryDefaultsStore
    }

    private func makeRig() -> Rig {
        let defaults = InMemoryDefaultsStore()
        let manager = SettingsManager(
            dependencies: .inMemory(
                defaults: defaults,
                ubiquitous: InMemoryUbiquitousStore(),
                secrets: InMemorySecretStore()
            )
        )
        return Rig(manager: manager, defaults: defaults)
    }

    private let gatewayURL = URL(string: "https://wrist-gateway.example.com")!

    private func storedOverride(_ rig: Rig) -> String? {
        rig.defaults.string(forKey: Constants.remoteAgentWatchDefaultBackendKey)
    }

    func testOverrideSurvivesATransientUnreadableToken() async throws {
        let rig = makeRig()
        let ref = RemoteAgentRef.builtin(.openclaw)
        await rig.manager.setRemoteAgentURL(gatewayURL, for: ref)
        try await rig.manager.setRemoteAgentToken("wrist-token", for: ref)
        await rig.manager.setWatchDefaultOverrideRef(ref)

        let initial = await rig.manager.watchDefaultOverrideRef()
        XCTAssertEqual(initial, ref, "a send-able override resolves")

        // The blackout: the token is not readable. `configuredRemoteAgentRefs()`
        // fails closed, so the override is not currently send-able.
        try await rig.manager.clearRemoteAgentToken(for: ref)

        let duringBlackout = await rig.manager.watchDefaultOverrideRef()
        XCTAssertNil(duringBlackout, "a not-send-able override must not reach the envelope")
        XCTAssertEqual(
            storedOverride(rig),
            ref.rawString,
            "the stored override must SURVIVE — nothing recreates it, and it never syncs"
        )

        // iCloud Keychain finishes delivering.
        try await rig.manager.setRemoteAgentToken("wrist-token", for: ref)

        let recovered = await rig.manager.watchDefaultOverrideRef()
        XCTAssertEqual(recovered, ref, "the override returns by itself once the token lands")
        let recoveredEffective = await rig.manager.watchEffectiveDefault()
        XCTAssertEqual(recoveredEffective.ref, ref)
        XCTAssertTrue(recoveredEffective.chosen, "a Watch-specific override is always a choice")
    }

    /// The same shape one step earlier: a restored backup where the gateway URL
    /// has not synced either, so the ref has no evidence at all.
    func testOverrideSurvivesAGatewayThatHasNotSyncedYet() async throws {
        let rig = makeRig()
        let ref = RemoteAgentRef.builtin(.hermes)
        await rig.manager.setRemoteAgentURL(gatewayURL, for: ref)
        try await rig.manager.setRemoteAgentToken("wrist-token", for: ref)
        await rig.manager.setWatchDefaultOverrideRef(ref)

        await rig.manager.setRemoteAgentURL(nil, for: ref)
        try await rig.manager.clearRemoteAgentToken(for: ref)

        let duringBlackout = await rig.manager.watchDefaultOverrideRef()
        XCTAssertNil(duringBlackout)
        XCTAssertEqual(storedOverride(rig), ref.rawString)

        await rig.manager.setRemoteAgentURL(gatewayURL, for: ref)
        try await rig.manager.setRemoteAgentToken("wrist-token", for: ref)

        let recovered = await rig.manager.watchDefaultOverrideRef()
        XCTAssertEqual(recovered, ref)
    }

    /// Retention is not permanence: a Forget is a statement of intent, and it
    /// still removes the override at its source.
    func testForgettingTheGatewayStillClearsTheOverride() async throws {
        let rig = makeRig()
        let gateway = CustomGateway(id: UUID(), name: "Wrist box")
        let accepted = await rig.manager.upsertCustomGateway(gateway)
        XCTAssertTrue(accepted)
        let ref = RemoteAgentRef.custom(gateway.id)
        await rig.manager.setRemoteAgentURL(gatewayURL, for: ref)
        try await rig.manager.setRemoteAgentToken("wrist-token", for: ref)
        await rig.manager.setWatchDefaultOverrideRef(ref)
        XCTAssertEqual(storedOverride(rig), ref.rawString)

        await rig.manager.deleteCustomGateway(id: gateway.id)

        XCTAssertNil(storedOverride(rig), "an explicit Forget earns the removal the reader withholds")
        let override = await rig.manager.watchDefaultOverrideRef()
        XCTAssertNil(override)
    }

    /// The BUILT-IN arm of the same rule, which `deleteCustomGateway` cannot
    /// reach: `GatewayForget` routes both kinds through
    /// `clearWatchDefaultOverrideIfPointing(at:)`. It matters more here than for
    /// customs — `openclaw` / `hermes` / `openrouter` are stable, REUSED strings,
    /// so an override left behind would come back to life the moment the user
    /// configures that lane again, possibly against a different server, and every
    /// wrist capture would silently route to it.
    func testForgettingABuiltInGatewayClearsTheOverrideAtItsSource() async throws {
        let rig = makeRig()
        let ref = RemoteAgentRef.builtin(.openclaw)
        await rig.manager.setRemoteAgentURL(gatewayURL, for: ref)
        try await rig.manager.setRemoteAgentToken("wrist-token", for: ref)
        await rig.manager.setWatchDefaultOverrideRef(ref)
        XCTAssertEqual(storedOverride(rig), ref.rawString)

        await rig.manager.clearWatchDefaultOverrideIfPointing(at: ref)

        XCTAssertNil(storedOverride(rig), "a Forget of a built-in must remove the override, not just withhold it")
        let override = await rig.manager.watchDefaultOverrideRef()
        XCTAssertNil(override)
    }

    /// And the removal is SCOPED: forgetting one gateway must not demote a wrist
    /// pointed at another.
    func testForgettingADifferentGatewayLeavesTheOverrideAlone() async throws {
        let rig = makeRig()
        let kept = RemoteAgentRef.builtin(.openclaw)
        let forgotten = RemoteAgentRef.builtin(.hermes)
        await rig.manager.setRemoteAgentURL(gatewayURL, for: kept)
        try await rig.manager.setRemoteAgentToken("wrist-token", for: kept)
        await rig.manager.setWatchDefaultOverrideRef(kept)

        await rig.manager.clearWatchDefaultOverrideIfPointing(at: forgotten)

        XCTAssertEqual(storedOverride(rig), kept.rawString)
        let override = await rig.manager.watchDefaultOverrideRef()
        XCTAssertEqual(override, kept)
    }
}
