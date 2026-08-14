// SPDX-License-Identifier: Apache-2.0

// Conduck
// LastUsedGatewayTests.swift
//
// Locks the sticky new-chat gateway pointer — the memory that lets a new chat
// continue on the gateway the last one was started on.
//
// Two contracts are easy to break by "tidying" and are each pinned by a test that
// names the reason:
//
//   1. The pointer is a HINT. It self-heals by IGNORING a ref with no evidence,
//      never by deleting it — a restored backup whose gateway URL is still coming
//      down from iCloud reads evidence-free on first launch, and deleting there
//      would lose the pointer permanently. Deletion happens only where the user
//      states fresh intent.
//   2. It never outlives that intent. Choosing a default clears it — INCLUDING a
//      re-tap of the default already set, which is exactly how a user reacts to a
//      setting that appears to be ignored. Forgetting a gateway clears it too, for
//      both built-ins and customs.
//
// Same isolation as `GatewayStaleStateTests`: every test builds its own
// `SettingsManager` from an in-memory dependency bundle, and key literals are
// pinned here independently of `Constants` so a rename that would orphan real user
// data breaks a test instead of silently re-homing the key.

import XCTest
@testable import Conduck

final class LastUsedGatewayTests: XCTestCase {

    private let lastUsedKey = "remoteAgent.lastUsedBackend"
    private let defaultBackendKey = "remoteAgent.defaultBackend"
    private let hermesURLKey = "remoteAgent.url.hermes"
    private let hermesAuthKey = "remoteAgent.authScheme.hermes"
    private let openclawURLKey = "remoteAgent.url.openclaw"

    private func makeManager(
        defaults: InMemoryDefaultsStore = InMemoryDefaultsStore(),
        kvs: InMemoryUbiquitousStore = InMemoryUbiquitousStore(),
        cloudAvailable: Bool = true
    ) -> SettingsManager {
        SettingsManager(dependencies: .inMemory(
            defaults: defaults,
            ubiquitous: kvs,
            cloudAvailable: cloudAvailable
        ))
    }

    /// A keyless Hermes is configured on URL alone — no Keychain, so it holds on
    /// an unsigned run too.
    private func configureKeylessHermes(_ defaults: InMemoryDefaultsStore) {
        defaults.set("https://hermes.example.test:8642", forKey: hermesURLKey)
        defaults.set("none", forKey: hermesAuthKey)
    }

    // MARK: - Reading

    func testLastUsedIsNilOnAFreshInstall() async {
        let manager = makeManager()

        let lastUsed = await manager.lastUsedRemoteAgentRef()

        XCTAssertNil(lastUsed, "Absent means 'no chat started here yet' — a legitimate answer the seed falls back from.")
    }

    func testSetThenReadRoundTrips() async {
        let defaults = InMemoryDefaultsStore()
        configureKeylessHermes(defaults)
        let manager = makeManager(defaults: defaults)

        await manager.setLastUsedRemoteAgentRef(.builtin(.hermes))

        let lastUsed = await manager.lastUsedRemoteAgentRef()
        XCTAssertEqual(lastUsed, .builtin(.hermes))
    }

    func testSetLastUsedDoesNotTouchTheDefaultPointer() async {
        let defaults = InMemoryDefaultsStore()
        configureKeylessHermes(defaults)
        defaults.set("openclaw", forKey: defaultBackendKey)
        let manager = makeManager(defaults: defaults)

        await manager.setLastUsedRemoteAgentRef(.builtin(.hermes))

        XCTAssertEqual(defaults.string(forKey: defaultBackendKey), "openclaw",
                       "The two pointers are independent — starting a chat must never re-point the Settings default.")
    }

    /// THE LOAD-BEARING ONE. Evidence is App-Group-backed and cannot be faked
    /// absent by a locked Keychain, which is why the getter tests evidence rather
    /// than `configuredRemoteAgentRefs().contains` (that predicate fails CLOSED on
    /// an unreadable token). Mirrors `testDefaultRefSurvivesUnreadableToken`.
    func testLastUsedSurvivesAnUnreadableToken() async {
        let defaults = InMemoryDefaultsStore()
        // A `.bearer` gateway with a URL but no reachable token: unconfigured to
        // the fail-closed predicate, but plainly evidenced.
        defaults.set("https://gateway.example.test", forKey: openclawURLKey)
        defaults.set("openclaw", forKey: lastUsedKey)
        let manager = makeManager(defaults: defaults)

        let configured = await manager.configuredRemoteAgentRefs()
        XCTAssertFalse(configured.contains(.builtin(.openclaw)))

        let lastUsed = await manager.lastUsedRemoteAgentRef()
        XCTAssertEqual(lastUsed, .builtin(.openclaw),
                       "A transient Keychain failure must not erase where the user last worked.")
    }

    /// The DELIBERATE DIVERGENCE from `defaultRemoteAgentRef()`, which keeps an
    /// unconfigured built-in pointer (see
    /// `GatewayStaleStateTests.testDefaultRefKeepsAnUnconfiguredBuiltInPointer`).
    ///
    /// That exemption exists because `deleteCustomGateway` deliberately re-points
    /// the DEFAULT at a built-in so the user chooses their next gateway. Nothing
    /// ever re-points last-used, so an evidence-free built-in here is just a stale
    /// suggestion — and built-in refs are reused when the lane is set up again, so
    /// honouring it could pre-select a ref that now means a different server.
    ///
    /// If you are here because this looks inconsistent: it is intentional. Do not
    /// "fix" it by adding `ref.isBuiltin ||` to the guard.
    func testLastUsedDropsAnUnconfiguredBuiltInPointer() async {
        let defaults = InMemoryDefaultsStore()
        defaults.set("hermes", forKey: lastUsedKey)  // no URL, no model → no evidence
        let manager = makeManager(defaults: defaults)

        let lastUsed = await manager.lastUsedRemoteAgentRef()

        XCTAssertNil(lastUsed, "An evidence-free built-in is a stale suggestion, not a live pre-selection.")
    }

    /// Self-heal by IGNORING, not removing. Compare
    /// `GatewayStaleStateTests.testDefaultRefDropsDanglingCustomPointer`, which
    /// asserts the opposite STORAGE outcome for the default pointer.
    func testLastUsedIgnoresADanglingCustomPointerWithoutDeletingIt() async {
        let defaults = InMemoryDefaultsStore()
        let dangling = RemoteAgentRef.custom(UUID())
        defaults.set(dangling.rawString, forKey: lastUsedKey)
        let manager = makeManager(defaults: defaults)

        let lastUsed = await manager.lastUsedRemoteAgentRef()

        XCTAssertNil(lastUsed, "No evidence → not offered as a pre-selection.")
        XCTAssertEqual(defaults.string(forKey: lastUsedKey), dangling.rawString,
                       """
                       …but the stored string SURVIVES. A restored backup whose gateway URL is still \
                       downloading from iCloud reads evidence-free on first launch; deleting here would \
                       lose the pointer permanently, and it would never come back when KVS lands.
                       """)
    }

    /// The getter's contract is "a hint, not a routable ref". A half-configured
    /// gateway is returned deliberately — the picker seed is what filters it —
    /// so nothing may hand this value straight to a dispatch.
    func testLastUsedReturnsAHalfConfiguredRefSoTheSeedSiteCanRejectIt() async {
        let defaults = InMemoryDefaultsStore()
        defaults.set("https://gateway.example.test", forKey: openclawURLKey)
        defaults.set("openclaw", forKey: lastUsedKey)
        let manager = makeManager(defaults: defaults)

        let lastUsed = await manager.lastUsedRemoteAgentRef()
        let configured = await manager.configuredRemoteAgentRefs()

        XCTAssertEqual(lastUsed, .builtin(.openclaw))
        XCTAssertFalse(configured.contains(.builtin(.openclaw)),
                       "The seed ladder rejects it via `configured.contains`; the getter is not the gate.")
    }

    // MARK: - Clearing on explicit intent

    /// THE HEADLINE REGRESSION TEST. Without this the Settings row is inert: the
    /// picker keeps seeding from last-used and "Default for new chats" appears to
    /// do nothing at all.
    func testChoosingADefaultClearsLastUsed() async {
        let defaults = InMemoryDefaultsStore()
        configureKeylessHermes(defaults)
        defaults.set("hermes", forKey: lastUsedKey)
        defaults.set("hermes", forKey: defaultBackendKey)
        let manager = makeManager(defaults: defaults)

        await manager.applyUserChosenDefault(.builtin(.openclaw))

        XCTAssertNil(defaults.string(forKey: lastUsedKey),
                     "Choosing a default is a fresh statement of intent; last-used must not outlive it.")
    }

    /// The re-tap case. A user whose setting looks ignored taps the gateway already
    /// checked; if the setter's no-op guard swallowed that, the app would be
    /// unfixable from its own UI.
    func testReChoosingTheCurrentDefaultStillClearsLastUsed() async {
        let defaults = InMemoryDefaultsStore()
        configureKeylessHermes(defaults)
        defaults.set("openclaw", forKey: defaultBackendKey)
        defaults.set("hermes", forKey: lastUsedKey)
        let manager = makeManager(defaults: defaults)

        // Same value that is already stored — the inner setter early-returns.
        await manager.applyUserChosenDefault(.builtin(.openclaw))

        XCTAssertNil(defaults.string(forKey: lastUsedKey),
                     "A redundant re-choice must still retire the sticky pointer.")
        XCTAssertEqual(defaults.string(forKey: defaultBackendKey), "openclaw",
                       "…while the default itself is untouched by the early return.")
    }

    /// THE SEPARATION THAT MAKES FORGET SAFE. `setDefaultRemoteAgentRef` is also
    /// the app's PROGRAMMATIC re-point — the Forget fallbacks and the first-gateway
    /// bootstrap — and those must not touch last-used.
    ///
    /// Forgetting gateway A re-points the default away from A. If that re-point
    /// cleared unconditionally, it would also discard a last-used naming a
    /// different, still-configured gateway B that the user never gave up. Only the
    /// user's own choice retires the pointer.
    func testAProgrammaticDefaultRepointLeavesLastUsedAlone() async {
        let defaults = InMemoryDefaultsStore()
        configureKeylessHermes(defaults)
        defaults.set("openclaw", forKey: defaultBackendKey)
        defaults.set("hermes", forKey: lastUsedKey)  // a DIFFERENT, live gateway
        let manager = makeManager(defaults: defaults)

        await manager.setDefaultRemoteAgentRef(.builtin(.openrouter))

        XCTAssertEqual(defaults.string(forKey: lastUsedKey), "hermes",
                       """
                       A Forget fallback or bootstrap re-point is the app choosing for the user; it must \
                       not throw away the gateway they actually last worked on.
                       """)
    }

    func testClearOnlyFiresWhenThePointerNamesTheGatewayInQuestion() async {
        let defaults = InMemoryDefaultsStore()
        configureKeylessHermes(defaults)
        defaults.set("hermes", forKey: lastUsedKey)
        let manager = makeManager(defaults: defaults)

        await manager.clearLastUsedRemoteAgentRefIfPointing(at: .custom(UUID()))

        XCTAssertEqual(defaults.string(forKey: lastUsedKey), "hermes",
                       "A deletion invalidates only its own gateway, never someone else's pointer.")
    }

    /// A custom Forget must not take an unrelated pointer with it.
    func testForgettingACustomClearsOnlyItsOwnPointer() async {
        let defaults = InMemoryDefaultsStore()
        let victim = UUID()
        defaults.set(RemoteAgentRef.custom(victim).rawString, forKey: lastUsedKey)
        let manager = makeManager(defaults: defaults)

        await manager.clearLastUsedRemoteAgentRefIfPointing(at: .custom(victim))

        XCTAssertNil(defaults.string(forKey: lastUsedKey))
    }

    /// Built-in Forget needs its own clear. `SettingsViewModel`'s built-in branch
    /// only re-points the DEFAULT when the forgotten gateway was the default, so
    /// nothing else would retire a pointer at a non-default built-in — and
    /// built-in refs are reused when the lane is configured again.
    func testForgettingABuiltInThatIsNotTheDefaultStillClearsThePointer() async {
        let defaults = InMemoryDefaultsStore()
        configureKeylessHermes(defaults)
        defaults.set("openclaw", forKey: defaultBackendKey)  // hermes is NOT the default
        defaults.set("hermes", forKey: lastUsedKey)
        let manager = makeManager(defaults: defaults)

        await manager.clearLastUsedRemoteAgentRefIfPointing(at: .builtin(.hermes))

        XCTAssertNil(defaults.string(forKey: lastUsedKey))
    }

    // MARK: - Sync boundary

    func testLastUsedIsAppGroupOnlyNeverKVS() async {
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()
        configureKeylessHermes(defaults)
        let manager = makeManager(defaults: defaults, kvs: kvs)

        await manager.setLastUsedRemoteAgentRef(.builtin(.hermes))

        XCTAssertEqual(defaults.string(forKey: lastUsedKey), "hermes")
        XCTAssertNil(kvs.string(forKey: lastUsedKey),
                     "Device-local: a gateway picked on one device must never re-aim another device's picker.")
    }
}
