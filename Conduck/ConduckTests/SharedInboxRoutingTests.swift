// SPDX-License-Identifier: Apache-2.0

// Conduck
// SharedInboxRoutingTests.swift
//
// Share Extension — coverage for the shared resolve-or-mint routing
// helper `SharedInboxRouting.resolveOrMint`, the SINGLE function both
// `ConverseIntent` and the future `SharedInboxDrainer` call. Covers:
//   - warm-pointer continue (a live pointer on the DEFAULT gateway → continue)
//   - warm pointer on a NON-default gateway → mint fresh on the default (the
//     quick-capture re-check; `resolveQuickCaptureConversation` covered directly)
//   - cold/expired pointer → mint a fresh conversation on the default backend
//   - explicit override → route by the overridden row's backend (bypass pointer)
//   - unconfigured default (no URL/token) → throws `.remoteAgentNotConfigured`
//
// Isolation: the helper takes injected `settings` (the live `SettingsManager`
// singleton — App Groups state wiped each test) + an in-memory `ConversationStore`
// (fresh per test, no App Group sqlite). The pointer / default-backend / URL
// slots are App-Group UserDefaults (no signing needed); the bearer TOKEN is an
// access-group Keychain item, so the token-requiring paths route through
// `setTokenOrSkip`, which `XCTSkip`s on an unsigned build (verified on the signed
// founder-gate run). The unconfigured-throws path needs no token → runs unsigned.

import XCTest
@testable import Conduck

final class SharedInboxRoutingTests: XCTestCase {

    private let defaults = TestStores.defaults

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
        defaults.removeObject(forKey: Constants.remoteAgentActiveConversationIDKey)
        defaults.removeObject(forKey: Constants.remoteAgentActiveConversationActivityKey)
        defaults.removeObject(forKey: Constants.sessionContinuationPolicyKey)
        for backend in RemoteAgentBackend.allCases {
            defaults.removeObject(forKey: Constants.remoteAgentURLKey(for: backend))
            defaults.removeObject(forKey: Constants.remoteAgentCertFingerprintKey(for: backend))
            try? await SettingsManager.shared.clearRemoteAgentToken(for: backend)
        }
        defaults.removeObject(forKey: Constants.remoteAgentMultiGatewayMigratedKey)
        await SettingsManager.shared.resetRemoteAgentMigrationLatchForTesting()
    }

    /// Configure a backend's URL + token (token write skips on unsigned).
    private func configureOrSkip(_ backend: RemoteAgentBackend, url: String, token: String) async throws {
        let u = try XCTUnwrap(URL(string: url))
        await SettingsManager.shared.setRemoteAgentURL(u, for: backend)
        do {
            try await SettingsManager.shared.setRemoteAgentToken(token, for: backend)
        } catch {
            throw XCTSkip("Keychain access-group write requires a signed build (unsigned: \(error)).")
        }
    }

    // MARK: - Unconfigured → throws (runs unsigned)

    func testUnconfiguredDefaultThrowsNotConfigured() async {
        // No default backend URL/token configured + no pointer → the mint path
        // snapshots the default backend, finds nothing, and throws.
        //
        // VERDICT: `.nothingConfigured`. Nothing can send, no ref clears the
        // non-Keychain requirements, and the wipe left no setup residue — so the
        // reading IS trustworthy and code 12's copy is exactly accurate. Code 74
        // requires OTHER gateways to be working, which this fixture never
        // arranges; flipping this expectation would assert the opposite of what
        // the test sets up.
        let store = ConversationStore(inMemory: true)
        do {
            _ = try await SharedInboxRouting.resolveOrMint(store: store)
            XCTFail("An unconfigured default must throw .remoteAgentNotConfigured.")
        } catch let error as AppError {
            XCTAssertEqual(error.errorCode, AppError.remoteAgentNotConfigured.errorCode)
        } catch {
            XCTFail("Expected AppError.remoteAgentNotConfigured, got \(error).")
        }
        // No stray conversation must have been minted.
        let convos = try? await store.fetchConversations()
        XCTAssertEqual(convos?.count ?? 0, 0,
                       "The not-configured path must NOT mint a stray empty thread.")
    }

    func testURLButNoTokenThrowsWithoutMinting() async throws {
        // Default backend has a URL but NO token → not-configured, no mint.
        //
        // VERDICT: `.readingUnreliable`. Nothing can send, and the default meets
        // every non-Keychain requirement while waiting only on a token that does
        // not read back — which is exactly what an after-first-unlock blackout
        // looks like. The mint therefore runs with the UNVERIFIED role and fails
        // closed on code 12: naming a broken default here would be an accusation
        // made by a device that cannot see its own secrets.
        let store = ConversationStore(inMemory: true)
        await SettingsManager.shared.setDefaultRemoteAgentBackend(.openclaw)
        let u = try XCTUnwrap(URL(string: "https://openclaw.example.test:18789"))
        await SettingsManager.shared.setRemoteAgentURL(u, for: .openclaw)

        do {
            _ = try await SharedInboxRouting.resolveOrMint(store: store)
            XCTFail("URL-but-no-token must throw .remoteAgentNotConfigured.")
        } catch let error as AppError {
            XCTAssertEqual(error.errorCode, AppError.remoteAgentNotConfigured.errorCode)
        }
        let convos = try? await store.fetchConversations()
        XCTAssertEqual(convos?.count ?? 0, 0,
                       "A default with URL-but-no-token must NOT mint a stray empty thread.")
    }

    // MARK: - Cold pointer → mint on default (signed gate)

    func testColdPointerMintsFreshOnDefault() async throws {
        let store = ConversationStore(inMemory: true)
        await SettingsManager.shared.setDefaultRemoteAgentBackend(.openclaw)
        try await configureOrSkip(.openclaw, url: "https://openclaw.example.test:18789", token: "tok-oc")

        // No pointer stored → cold → mint.
        let resolved = try await SharedInboxRouting.resolveOrMint(store: store)
        XCTAssertEqual(resolved.snapshot.backend, .openclaw)
        XCTAssertEqual(resolved.token, "tok-oc")

        // A fresh conversation bound to the default ref must now exist.
        let convo = try await store.fetchConversation(id: resolved.conversationID)
        XCTAssertEqual(convo?.backend, RemoteAgentRef.builtin(.openclaw).rawString)
    }

    // MARK: - Warm pointer → continue existing row's backend (signed gate)

    func testWarmPointerContinuesExistingRowBackend() async throws {
        let store = ConversationStore(inMemory: true)
        // The row is bound to the CURRENT default (Hermes) — the only shape the
        // quick-capture re-check continues; a row on a non-default gateway
        // mints fresh instead (see
        // testWarmPointerOnNonDefaultGatewayMintsFreshOnDefault).
        await SettingsManager.shared.setDefaultRemoteAgentBackend(.hermes)
        try await configureOrSkip(.hermes, url: "https://hermes.example.test:8642", token: "tok-h")

        let existing = try await store.createConversation(backend: RemoteAgentBackend.hermes.rawValue)
        // Stamp the pointer + a fresh activity so the (default .minutes30) policy
        // resolves "continue".
        await SettingsManager.shared.recordActiveConversation(existing.id)

        let resolved = try await SharedInboxRouting.resolveOrMint(store: store)
        XCTAssertEqual(resolved.conversationID, existing.id,
                       "A warm pointer on the default gateway must continue the existing conversation.")
        XCTAssertEqual(resolved.snapshot.backend, .hermes,
                       "Routing must follow the continued row's bound backend.")
        XCTAssertEqual(resolved.token, "tok-h")
    }

    // MARK: - Quick-capture default-gateway re-check

    func testWarmPointerOnNonDefaultGatewayMintsFreshOnDefault() async throws {
        // A TTL-fresh pointer whose row is bound to Hermes while the DEFAULT is
        // OpenClaw: the re-check treats it like "no pointer" (the default was
        // re-pointed since the stamp, e.g. remotely via the KVS mirror) → mint
        // fresh ON THE DEFAULT, never continue the old gateway's thread.
        let store = ConversationStore(inMemory: true)
        await SettingsManager.shared.setDefaultRemoteAgentBackend(.openclaw)
        try await configureOrSkip(.openclaw, url: "https://openclaw.example.test:18789", token: "tok-oc")

        let hermesRow = try await store.createConversation(backend: RemoteAgentBackend.hermes.rawValue)
        await SettingsManager.shared.recordActiveConversation(hermesRow.id)

        let resolved = try await SharedInboxRouting.resolveOrMint(store: store)
        XCTAssertNotEqual(resolved.conversationID, hermesRow.id,
                          "A warm pointer on a NON-default gateway must not be continued.")
        XCTAssertEqual(resolved.snapshot.backend, .openclaw)
        let convo = try await store.fetchConversation(id: resolved.conversationID)
        XCTAssertEqual(convo?.backend, RemoteAgentRef.builtin(.openclaw).rawString,
                       "The fresh mint must land on the current default.")
    }

    // The three `resolveQuickCaptureConversation` tests below need NO tokens —
    // the helper reads only the pointer + the conversation row + the default
    // ref, never a gateway snapshot — so they run unsigned.

    func testResolveQuickCaptureNilOnGatewayMismatch() async throws {
        let store = ConversationStore(inMemory: true)
        await SettingsManager.shared.setDefaultRemoteAgentBackend(.openclaw)
        let hermesRow = try await store.createConversation(backend: RemoteAgentBackend.hermes.rawValue)
        await SettingsManager.shared.recordActiveConversation(hermesRow.id)

        let record = await SharedInboxRouting.resolveQuickCaptureConversation(store: store)
        XCTAssertNil(record,
                     "A pointer bound to a non-default gateway must resolve nil (caller mints on the default).")
    }

    func testResolveQuickCaptureReturnsRecordOnGatewayMatch() async throws {
        let store = ConversationStore(inMemory: true)
        await SettingsManager.shared.setDefaultRemoteAgentBackend(.openclaw)
        let row = try await store.createConversation(backend: RemoteAgentBackend.openclaw.rawValue)
        await SettingsManager.shared.recordActiveConversation(row.id)

        let record = await SharedInboxRouting.resolveQuickCaptureConversation(store: store)
        XCTAssertEqual(record?.id, row.id,
                       "A TTL-fresh pointer on the default gateway must return the fetched record.")
        XCTAssertEqual(record?.backend, RemoteAgentRef.builtin(.openclaw).rawString)
    }

    func testResolveQuickCaptureNilOnMissingRow() async throws {
        // The pointer names a deleted / never-imported row → nil (never a
        // ghost — mirrors resolveOrMint's append-to-no-ghost rule).
        let store = ConversationStore(inMemory: true)
        await SettingsManager.shared.setDefaultRemoteAgentBackend(.openclaw)
        await SettingsManager.shared.recordActiveConversation(UUID())

        let record = await SharedInboxRouting.resolveQuickCaptureConversation(store: store)
        XCTAssertNil(record, "A pointer to a missing row must resolve nil.")
    }

    // MARK: - Explicit override → route by overridden row (signed gate)

    func testExplicitOverrideRoutesByOverriddenRowBypassingPointer() async throws {
        let store = ConversationStore(inMemory: true)
        await SettingsManager.shared.setDefaultRemoteAgentBackend(.openclaw)
        try await configureOrSkip(.openclaw, url: "https://openclaw.example.test:18789", token: "tok-oc")
        try await configureOrSkip(.hermes, url: "https://hermes.example.test:8642", token: "tok-h")

        // The active pointer names an OpenClaw row, but the override names a
        // DIFFERENT Hermes row — the override must win.
        let pointerRow = try await store.createConversation(backend: RemoteAgentBackend.openclaw.rawValue)
        await SettingsManager.shared.recordActiveConversation(pointerRow.id)
        let overrideRow = try await store.createConversation(backend: RemoteAgentBackend.hermes.rawValue)

        let resolved = try await SharedInboxRouting.resolveOrMint(
            overrideConversationID: overrideRow.id,
            store: store
        )
        XCTAssertEqual(resolved.conversationID, overrideRow.id,
                       "An explicit override must bypass the pointer.")
        XCTAssertEqual(resolved.snapshot.backend, .hermes)
        XCTAssertEqual(resolved.token, "tok-h")
    }

    // MARK: - New precedence: deleted-conversation fallback (#2)

    func testDeletedConversationWithConfiguredBackendHintMintsOnThatRef() async throws {
        // The user picked an EXISTING Hermes conversation; it was deleted before
        // the drain. With the selectedBackendRef hint (Hermes, still configured),
        // routing must MINT a fresh Hermes thread — NOT silently reroute to the
        // OpenClaw default, and NOT fall through to the pointer.
        let store = ConversationStore(inMemory: true)
        await SettingsManager.shared.setDefaultRemoteAgentBackend(.openclaw)
        try await configureOrSkip(.openclaw, url: "https://openclaw.example.test:18789", token: "tok-oc")
        try await configureOrSkip(.hermes, url: "https://hermes.example.test:8642", token: "tok-h")

        let resolved = try await SharedInboxRouting.resolveOrMint(
            overrideConversationID: UUID(),   // names no local row (deleted)
            selectedBackendRef: RemoteAgentRef.builtin(.hermes).rawString,
            store: store
        )
        XCTAssertEqual(resolved.snapshot.backend, .hermes,
                       "A deleted conversation must mint on its captured backend hint, not the default.")
        XCTAssertEqual(resolved.token, "tok-h")
        let convo = try await store.fetchConversation(id: resolved.conversationID)
        XCTAssertEqual(convo?.backend, RemoteAgentRef.builtin(.hermes).rawString)
    }

    func testDeletedConversationWithUnconfiguredBackendHintThrows() async throws {
        // The captured backend hint is for a gateway that is NOT configured →
        // throw (drainer fails the share), never reroute to the default.
        //
        // STAYS CODE 12, and never reaches the resolver at all: this is
        // precedence #2, an `.explicitPick`. The user NAMED Hermes, so the
        // refusal is about Hermes — "your default AI isn't set up" would be a
        // lie about a gateway (OpenClaw) that is working perfectly here.
        let store = ConversationStore(inMemory: true)
        await SettingsManager.shared.setDefaultRemoteAgentBackend(.openclaw)
        try await configureOrSkip(.openclaw, url: "https://openclaw.example.test:18789", token: "tok-oc")
        // Hermes intentionally NOT configured.

        do {
            _ = try await SharedInboxRouting.resolveOrMint(
                overrideConversationID: UUID(),
                selectedBackendRef: RemoteAgentRef.builtin(.hermes).rawString,
                store: store
            )
            XCTFail("An unconfigured backend hint must throw, not reroute to default.")
        } catch let error as AppError {
            XCTAssertEqual(error.errorCode, AppError.remoteAgentNotConfigured.errorCode)
        }
        let convos = try? await store.fetchConversations()
        XCTAssertEqual(convos?.count ?? 0, 0, "No stray thread must be minted on the throw path.")
    }

    func testDeletedConversationWithNoBackendHintThrows() async throws {
        // No selectedBackendRef hint + the row is gone → throw (drainer fails the share). Runs
        // unsigned (no token needed — the throw fires before any snapshot read
        // when the default itself is unconfigured; here we leave default
        // unconfigured so it's deterministic without a token).
        //
        // STAYS CODE 12: precedence #2's no-hint arm throws directly, before any
        // resolution is computed. The user targeted a specific CONVERSATION and
        // it is gone — nothing about this device's default is in question, so 74
        // would answer a question nobody asked.
        let store = ConversationStore(inMemory: true)
        do {
            _ = try await SharedInboxRouting.resolveOrMint(
                overrideConversationID: UUID(),
                selectedBackendRef: nil,
                store: store
            )
            XCTFail("A deleted conversation with no backend hint must throw.")
        } catch let error as AppError {
            XCTAssertEqual(error.errorCode, AppError.remoteAgentNotConfigured.errorCode)
        }
    }

    // MARK: - New precedence: new-conversation-on-gateway (#3 / #4)

    func testNewConversationOnConfiguredGatewayMints() async throws {
        // The picker's "New conversation in Hermes" pick → mint a fresh Hermes
        // thread bound to that ref, even though the default is OpenClaw.
        let store = ConversationStore(inMemory: true)
        await SettingsManager.shared.setDefaultRemoteAgentBackend(.openclaw)
        try await configureOrSkip(.hermes, url: "https://hermes.example.test:8642", token: "tok-h")

        let resolved = try await SharedInboxRouting.resolveOrMint(
            newConversationGatewayRef: RemoteAgentRef.builtin(.hermes).rawString,
            store: store
        )
        XCTAssertEqual(resolved.snapshot.backend, .hermes,
                       "New-on-gateway must bind to the picked ref, not the default.")
        XCTAssertEqual(resolved.token, "tok-h")
        let convo = try await store.fetchConversation(id: resolved.conversationID)
        XCTAssertEqual(convo?.backend, RemoteAgentRef.builtin(.hermes).rawString)
    }

    func testNewConversationOnUnconfiguredGatewayThrowsWithoutMinting() async throws {
        // "New conversation in Hermes" but Hermes is not configured → throw
        // (drainer fails the share), no stray thread. Runs unsigned (no token write needed —
        // the unconfigured Hermes snapshot is nil before any token check).
        //
        // STAYS CODE 12: precedence #3/#4 is an `.explicitPick` too. The pick is
        // the user's, not the pointer's, so the refusal must not describe the
        // default.
        let store = ConversationStore(inMemory: true)
        do {
            _ = try await SharedInboxRouting.resolveOrMint(
                newConversationGatewayRef: RemoteAgentRef.builtin(.hermes).rawString,
                store: store
            )
            XCTFail("New-on-unconfigured-gateway must throw .remoteAgentNotConfigured.")
        } catch let error as AppError {
            XCTAssertEqual(error.errorCode, AppError.remoteAgentNotConfigured.errorCode)
        }
        let convos = try? await store.fetchConversations()
        XCTAssertEqual(convos?.count ?? 0, 0, "No stray thread on the new-on-unconfigured throw path.")
    }

    func testMalformedNewGatewayRefThrows() async throws {
        // A new-gateway ref string that parses to no RemoteAgentRef → throw
        // (drainer fails the share), never reroute. Runs unsigned.
        //
        // STAYS CODE 12: a malformed target is not a statement about the
        // default, and this arm throws before any resolution is computed.
        let store = ConversationStore(inMemory: true)
        do {
            _ = try await SharedInboxRouting.resolveOrMint(
                newConversationGatewayRef: "not-a-real-ref",
                store: store
            )
            XCTFail("A malformed new-gateway ref must throw, not reroute.")
        } catch let error as AppError {
            XCTAssertEqual(error.errorCode, AppError.remoteAgentNotConfigured.errorCode)
        }
    }

    func testOverrideToUnknownRowFallsThroughToPointer() async throws {
        // An override id that doesn't resolve to a local row, with NO backend hint,
        // falls through... but precedence #2 now throws when the row is gone and
        // there's no hint. To preserve the LEGACY pointer-fallthrough behavior the
        // caller must supply NEITHER override NOR hint — i.e. the headless capture
        // passes nil override. This test pins the pure pointer path (no override).
        let store = ConversationStore(inMemory: true)
        await SettingsManager.shared.setDefaultRemoteAgentBackend(.openclaw)
        try await configureOrSkip(.openclaw, url: "https://openclaw.example.test:18789", token: "tok-oc")

        let pointerRow = try await store.createConversation(backend: RemoteAgentBackend.openclaw.rawValue)
        await SettingsManager.shared.recordActiveConversation(pointerRow.id)

        let resolved = try await SharedInboxRouting.resolveOrMint(store: store)
        XCTAssertEqual(resolved.conversationID, pointerRow.id,
                       "With no override + no new-gateway pick, routing follows the pointer (legacy path).")
    }
}
