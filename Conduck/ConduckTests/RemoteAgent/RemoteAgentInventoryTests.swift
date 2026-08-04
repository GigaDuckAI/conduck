// SPDX-License-Identifier: Apache-2.0

// Conduck
// RemoteAgentInventoryTests.swift
//
// Locks the two-axis gateway state model that `remoteAgentInventory()` produces:
//
//   READINESS     — untouched / incomplete / configured. "Can this gateway
//                   send?" Drives the Diagnostics row and the Personal AI
//                   "Needs setup" mark.
//   REMOVABILITY  — "would Forget erase anything?" Drives the editor's
//                   destructive section.
//
// The load-bearing property is the implication between them:
//
//     readiness == .incomplete  ⇒  hasRemovableState == true
//
// A Diagnostics row that says "open it in Personal AI to finish, or forget it"
// must always find a Forget button waiting when the user gets there. The reverse
// deliberately does NOT hold: auxiliary residue is worth offering to remove
// without claiming the gateway is broken.
//
// Every test builds its own `SettingsManager` from an isolated in-memory
// dependency bundle — no shared singleton, no wipe choreography.

import XCTest
@testable import Conduck

final class RemoteAgentInventoryTests: XCTestCase {

    // Key literals pinned independently of `Constants`, matching
    // `GatewayStaleStateTests`: a rename that would orphan real user data must
    // break a test rather than silently re-home keys.
    private let openclawURLKey = "remoteAgent.url.openclaw"
    private let openclawSchemeKey = "remoteAgent.authScheme.openclaw"
    private let openclawHintKey = "remoteAgent.transportHint.openclaw"
    private let openclawAvailableKey = "fileServer.available.openclaw"
    private let openclawFolderCapableKey = "fileServer.folderCapable.openclaw"
    private let openrouterModelKey = "remoteAgent.model.openrouter"
    private let gatewayRosterKey = "remoteAgent.customGateways"

    private func makeManager(
        defaults: InMemoryDefaultsStore = InMemoryDefaultsStore(),
        kvs: InMemoryUbiquitousStore = InMemoryUbiquitousStore(),
        secrets: InMemorySecretStore = InMemorySecretStore(),
        cloudAvailable: Bool = true
    ) -> SettingsManager {
        SettingsManager(dependencies: .inMemory(
            defaults: defaults,
            ubiquitous: kvs,
            secrets: secrets,
            cloudAvailable: cloudAvailable
        ))
    }

    /// Seed a one-gateway custom roster and return its ref.
    private func seedRoster(_ defaults: InMemoryDefaultsStore, name: String = "LiteLLM") -> RemoteAgentRef {
        let gateway = CustomGateway(id: UUID(), name: name, model: nil, colorID: "indigo")
        let data = try! JSONEncoder().encode([gateway])
        defaults.set(data, forKey: gatewayRosterKey)
        return .custom(gateway.id)
    }

    // MARK: - The invariant

    /// `incomplete ⇒ removable`, checked across every shape that can produce an
    /// incomplete gateway. This is the assertion that keeps Diagnostics' advice
    /// ("…or forget it") from pointing at an editor with no Forget button.
    func testIncompleteAlwaysImpliesRemovable() async {
        let defaults = InMemoryDefaultsStore()
        defaults.set("https://gateway.example.test", forKey: openclawURLKey)       // URL, no token
        defaults.set("bearer", forKey: "remoteAgent.authScheme.hermes")            // scheme only, no URL
        defaults.set("gpt-5-mini", forKey: openrouterModelKey)                     // model, no token
        _ = seedRoster(defaults)                                                   // roster entry, no slots
        let manager = makeManager(defaults: defaults)

        let inventory = await manager.remoteAgentInventory()
        let incomplete = inventory.entries.filter { $0.readiness == .incomplete }

        XCTAssertFalse(incomplete.isEmpty, "the seeds above must produce incomplete gateways to test against")
        for entry in incomplete {
            XCTAssertTrue(entry.hasRemovableState,
                          "\(entry.ref.rawString) reads incomplete but offers nothing to Forget — "
                          + "the Diagnostics row would send the user to a dead end")
        }
    }

    /// Readiness is a partition: one classification pass produces both arrays, so
    /// no ref can be send-able and half-finished at the same time. The old
    /// two-query shape could report exactly that when a sync landed between them.
    func testConfiguredAndIncompleteAreDisjoint() async {
        let defaults = InMemoryDefaultsStore()
        defaults.set("https://gateway.example.test", forKey: openclawURLKey)
        defaults.set("none", forKey: "remoteAgent.authScheme.hermes")
        defaults.set("https://hermes.example.test", forKey: "remoteAgent.url.hermes")
        _ = seedRoster(defaults)
        let manager = makeManager(defaults: defaults)

        let inventory = await manager.remoteAgentInventory()
        let configured = Set(inventory.configuredRefs)
        let incomplete = Set(inventory.incompleteRefs)

        XCTAssertTrue(configured.isDisjoint(with: incomplete),
                      "a ref classified once cannot land in both projections")
        XCTAssertEqual(inventory.entries.count, Set(inventory.entries.map(\.ref)).count,
                       "each ref appears exactly once in the inventory")
    }

    // MARK: - Readiness classification

    /// The founder's reported state: a built-in holding a URL with no bearer
    /// token. Incomplete, removable, and NOT send-able.
    func testURLWithoutTokenIsIncomplete() async {
        let defaults = InMemoryDefaultsStore()
        defaults.set("https://gateway.example.test", forKey: openclawURLKey)
        let manager = makeManager(defaults: defaults)

        let inventory = await manager.remoteAgentInventory()
        XCTAssertEqual(inventory.readiness(for: .builtin(.openclaw)), .incomplete)
        XCTAssertFalse(inventory.configuredRefs.contains(.builtin(.openclaw)))
        XCTAssertTrue(inventory.removableRefs.contains(.builtin(.openclaw)))
    }

    /// A URL the user really did save but `EndpointURLPolicy` rejects. The
    /// resolved getter drops it, so classifying on the RESOLVED value alone read
    /// this as "never touched" — leaving a gateway that can never work with no
    /// row in Diagnostics and no mark in Settings. The RAW slot is the evidence.
    func testMalformedStoredURLIsStillIncomplete() async {
        let defaults = InMemoryDefaultsStore()
        defaults.set("not a url at all", forKey: openclawURLKey)
        let manager = makeManager(defaults: defaults)

        let resolved = await manager.getRemoteAgentURL(for: .builtin(.openclaw))
        XCTAssertNil(resolved, "precondition: the policy must reject this string")

        let inventory = await manager.remoteAgentInventory()
        XCTAssertEqual(inventory.readiness(for: .builtin(.openclaw)), .incomplete,
                       "a saved-but-unusable URL is a broken setup, not an absent one")
    }

    /// A custom whose roster entry has synced but whose per-ref URL slot hasn't.
    /// `performInitialSync` hydrates the roster and the slots on separate keys, so
    /// this ordering is reachable in practice — and the gateway must be visible
    /// rather than silently absent.
    func testRosterEntryWithoutItsURLSlotIsIncomplete() async {
        let defaults = InMemoryDefaultsStore()
        let ref = seedRoster(defaults)
        let manager = makeManager(defaults: defaults)

        let inventory = await manager.remoteAgentInventory()
        XCTAssertEqual(inventory.readiness(for: ref), .incomplete,
                       "a roster entry IS evidence the user set this gateway up somewhere")
        XCTAssertTrue(inventory.removableRefs.contains(ref))
    }

    /// A keyless gateway is send-able on its URL alone — it must not be dragged
    /// into `.incomplete` by the absence of a token it never needed.
    func testKeylessGatewayWithURLIsConfigured() async {
        let defaults = InMemoryDefaultsStore()
        defaults.set("https://gateway.example.test", forKey: openclawURLKey)
        defaults.set("none", forKey: openclawSchemeKey)
        let manager = makeManager(defaults: defaults)

        let inventory = await manager.remoteAgentInventory()
        XCTAssertEqual(inventory.readiness(for: .builtin(.openclaw)), .configured)
        XCTAssertFalse(inventory.incompleteRefs.contains(.builtin(.openclaw)))
    }

    /// A fixed-endpoint built-in's URL is synthesized by the app, so URL presence
    /// proves nothing. An untouched OpenRouter must read `.untouched` — otherwise
    /// every fresh install shows a permanent "Needs setup" on a gateway the user
    /// has never opened.
    func testUntouchedFixedEndpointGatewayIsUntouched() async {
        let manager = makeManager()
        let inventory = await manager.remoteAgentInventory()

        XCTAssertEqual(inventory.readiness(for: .builtin(.openrouter)), .untouched)
        XCTAssertTrue(inventory.incompleteRefs.isEmpty,
                      "a fresh install has nothing half-configured")
        XCTAssertTrue(inventory.removableRefs.isEmpty,
                      "…and nothing to Forget, so no destructive button on any built-in")
    }

    /// OpenRouter with a stored model but no token: the two ride different sync
    /// channels (KVS vs. Keychain), so they land unevenly. Evidence exists, the
    /// gateway can't send.
    func testFixedEndpointWithModelButNoTokenIsIncomplete() async {
        let defaults = InMemoryDefaultsStore()
        defaults.set("gpt-5-mini", forKey: openrouterModelKey)
        let manager = makeManager(defaults: defaults)

        let inventory = await manager.remoteAgentInventory()
        XCTAssertEqual(inventory.readiness(for: .builtin(.openrouter)), .incomplete)
    }

    // MARK: - Removability is wider than readiness — but not unboundedly

    /// Auxiliary residue alone: something for Forget to erase, but no claim that
    /// the gateway's setup is unfinished. This is the one direction of the
    /// implication that must NOT hold.
    func testAuxiliaryResidueIsRemovableButNotIncomplete() async {
        let defaults = InMemoryDefaultsStore()
        defaults.set("tailscale", forKey: openclawHintKey)
        let manager = makeManager(defaults: defaults)

        let inventory = await manager.remoteAgentInventory()
        XCTAssertEqual(inventory.readiness(for: .builtin(.openclaw)), .untouched,
                       "a transport hint is not a setup attempt")
        XCTAssertTrue(inventory.removableRefs.contains(.builtin(.openclaw)),
                      "…but there is still a byte to erase, so Forget stays reachable")
    }

    /// The derived file-server probe flags are WRITTEN (`available = false`,
    /// `folderCapable = true`) by a built-in Forget rather than removed. Probing
    /// them for removability would pin a destructive button onto every gateway
    /// the user already forgot, forever.
    func testDerivedProbeFlagsDoNotMakeAForgottenGatewayRemovable() async {
        let defaults = InMemoryDefaultsStore()
        defaults.set(false, forKey: openclawAvailableKey)
        defaults.set(true, forKey: openclawFolderCapableKey)
        let manager = makeManager(defaults: defaults)

        let inventory = await manager.remoteAgentInventory()
        XCTAssertEqual(inventory.readiness(for: .builtin(.openclaw)), .untouched)
        XCTAssertFalse(inventory.removableRefs.contains(.builtin(.openclaw)),
                       "post-Forget probe residue must not resurrect the Forget button")
    }

    /// The removability probe list must stay a SUBSET of the list the wipe
    /// actually deletes. A prefix that is probed but never purged would leave a
    /// Forget button that does nothing.
    func testUserStatePrefixesAreSubsetOfWipedPrefixes() {
        let owned = Set(SettingsManager.gatewayOwnedKeyPrefixes)
        let probed = Set(SettingsManager.gatewayUserStateKeyPrefixes)
        XCTAssertTrue(probed.isSubset(of: owned),
                      "probed-but-never-wiped prefixes: \(probed.subtracting(owned).sorted())")
    }

    /// Keys only the CUSTOM-gateway prefix sweep erases must stay OUT of the
    /// probe list. `clearFileTransferConfig` (the built-in Forget path) doesn't
    /// touch them, so probing one would pin a destructive button onto a built-in
    /// with nothing left to remove — on any device upgraded from a build that
    /// wrote it.
    func testRetiredCustomOnlyKeysAreNotProbedForRemovability() {
        XCTAssertFalse(SettingsManager.gatewayUserStateKeyPrefixes.contains("fileServer.keepImagesInline."),
                       "the retired legacy bool is swept only by deleteCustomGateway; "
                       + "probing it strands the Forget button on built-ins")
    }

    /// The cheap `configuredRemoteAgentRefs()` query and the inventory's
    /// `configuredRefs` projection are separate code paths for cost reasons — the
    /// warm one short-circuits before the Keychain. They share
    /// `isRemoteAgentSendable`, and this proves they cannot drift apart, ordering
    /// included.
    func testCheapConfiguredQueryMatchesTheInventory() async {
        let defaults = InMemoryDefaultsStore()
        defaults.set("https://gateway.example.test", forKey: openclawURLKey)      // bearer, no token → not send-able
        defaults.set("https://hermes.example.test", forKey: "remoteAgent.url.hermes")
        defaults.set("none", forKey: "remoteAgent.authScheme.hermes")             // keyless → send-able
        defaults.set("gpt-5-mini", forKey: openrouterModelKey)                    // model, no token → not send-able
        let ref = seedRoster(defaults)
        defaults.set("https://litellm.example.test", forKey: "remoteAgent.url.\(ref.storageKeySuffix)")
        defaults.set("none", forKey: "remoteAgent.authScheme.\(ref.storageKeySuffix)")
        let manager = makeManager(defaults: defaults)

        let cheap = await manager.configuredRemoteAgentRefs()
        let projected = await manager.remoteAgentInventory().configuredRefs
        XCTAssertEqual(cheap, projected,
                       "the warm query and the inventory must agree on send-ability AND order")
        XCTAssertEqual(cheap, [.builtin(.hermes), ref], "sanity: exactly the keyless pair, built-in first")
    }

    // MARK: - Projections keep the ordering their callers rely on

    /// Built-ins in `allCases` order first, then customs in roster order — the
    /// contract the picker and the Diagnostics row order both assume.
    func testConfiguredProjectionKeepsBuiltinsBeforeCustoms() async {
        let defaults = InMemoryDefaultsStore()
        defaults.set("https://gateway.example.test", forKey: openclawURLKey)
        defaults.set("none", forKey: openclawSchemeKey)
        let ref = seedRoster(defaults)
        defaults.set("https://litellm.example.test", forKey: "remoteAgent.url.\(ref.storageKeySuffix)")
        defaults.set("none", forKey: "remoteAgent.authScheme.\(ref.storageKeySuffix)")
        let manager = makeManager(defaults: defaults)

        let configured = await manager.configuredRemoteAgentRefs()
        XCTAssertEqual(configured, [.builtin(.openclaw), ref],
                       "built-ins first, then customs in roster order")
    }
}
