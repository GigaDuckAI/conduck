// SPDX-License-Identifier: Apache-2.0

// Conduck
// SettingsViewModelMakeDefaultTests.swift
//
// The post-save "Make this your default gateway?" feature, two halves:
//   1. `SettingsViewModel.shouldPromptToSetDefault` — the pure decision the
//      editor consults after a save (exhaustive matrix, no I/O).
//   2. `saveRemoteAgent`'s first-gateway-ever default BOOTSTRAP via the MANUAL
//      save path (parity with the pairing-import bootstrap, which is covered in
//      `SettingsViewModelPairingImportTests`). The bootstrap is category-
//      agnostic — a Hermes-first / custom-first / OpenRouter-first user must NOT
//      dead-end on the unconfigured `.openclaw` fallback default.
//
// Isolation mirrors `SettingsViewModelPairingImportTests`: wipe App-Group
// defaults + per-ref slots + the KVS mirrors + the migration latch in
// setUp/tearDown. Keyless (`.none`) gateways are used wherever possible so the
// save persists on URL alone — no Keychain, so these run on the unsigned sim;
// the lone bearer case (OpenRouter) is gated behind the access-group skip.
// Synthetic values only; nothing real, nothing logged.

import XCTest
@testable import Conduck

@MainActor
final class SettingsViewModelMakeDefaultTests: XCTestCase {

    private let defaults: UserDefaults = {
        UserDefaults(suiteName: Constants.appGroupID) ?? UserDefaults.standard
    }()

    private let openclaw: RemoteAgentRef = .builtin(.openclaw)
    private let hermes: RemoteAgentRef = .builtin(.hermes)
    private let openrouter: RemoteAgentRef = .builtin(.openrouter)

    override func setUp() async throws {
        try await super.setUp()
        await wipeState()
    }

    override func tearDown() async throws {
        await wipeState()
        try await super.tearDown()
    }

    private func wipeState() async {
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
                Constants.remoteAgentModelKey(for: ref)
            ] {
                defaults.removeObject(forKey: key)
                NSUbiquitousKeyValueStore.default.removeObject(forKey: key)
            }
            try? await SettingsManager.shared.clearRemoteAgentToken(for: ref)
        }

        defaults.removeObject(forKey: Constants.remoteAgentMultiGatewayMigratedKey)
        await SettingsManager.shared.resetRemoteAgentMigrationLatchForTesting()
    }

    private func makeVM() async -> SettingsViewModel {
        let vm = SettingsViewModel()
        await vm.loadSettings()
        await Task.yield()
        return vm
    }

    private func requireGatewayKeychainOrSkip(for ref: RemoteAgentRef) async throws {
        do {
            try await SettingsManager.shared.setRemoteAgentToken("probe-token", for: ref)
            try await SettingsManager.shared.clearRemoteAgentToken(for: ref)
        } catch {
            throw XCTSkip("Keychain access-group write requires a signed build (unsigned: \(error)).")
        }
    }

    /// Seed the editor buffers a keyless save commits from, then save. Sets
    /// `editorHasUnsavedChanges` first — faithfully modelling the open, dirty
    /// editor a real Save runs under, which FENCES the `.settingsDidChangeRemotely`
    /// reload that would otherwise rebuild (and clobber) the seeded buffers
    /// mid-test.
    @discardableResult
    private func saveKeyless(_ vm: SettingsViewModel, ref: RemoteAgentRef, name: String? = nil,
                             url: String = "https://gw.example.test:18789") async -> Bool {
        vm.editorHasUnsavedChanges = true
        vm.remoteAgentURLStrings[ref] = url
        // Fully qualify — bare `.none` would resolve to `Optional.none` (nil) and
        // REMOVE the key instead of storing the keyless scheme.
        vm.remoteAgentAuthSchemes[ref] = RemoteAgentAuthScheme.none
        return await vm.saveRemoteAgent(ref: ref, name: name, stagedToken: .stored)
    }

    // MARK: - shouldPromptToSetDefault (pure matrix)

    func testPredicate_caseA_firstGatewayEver_noPrompt() {
        // No gateway configured before → bootstrap is silent → never prompt,
        // regardless of whether the resolved default already equals the ref.
        XCTAssertFalse(SettingsViewModel.shouldPromptToSetDefault(
            savedRef: hermes, defaultRef: openclaw,
            wasConfiguredBefore: false, hadAnyConfiguredBefore: false))
        XCTAssertFalse(SettingsViewModel.shouldPromptToSetDefault(
            savedRef: openclaw, defaultRef: openclaw,
            wasConfiguredBefore: false, hadAnyConfiguredBefore: false))
    }

    func testPredicate_caseB_editingExisting_noPrompt() {
        // Re-saving an already-configured gateway is an edit, never a new
        // configuration — no prompt even when it isn't the default.
        XCTAssertFalse(SettingsViewModel.shouldPromptToSetDefault(
            savedRef: hermes, defaultRef: openclaw,
            wasConfiguredBefore: true, hadAnyConfiguredBefore: true))
    }

    func testPredicate_caseC_newAdditionalNonDefault_prompts() {
        // A genuinely new additional gateway that isn't already the default.
        XCTAssertTrue(SettingsViewModel.shouldPromptToSetDefault(
            savedRef: hermes, defaultRef: openclaw,
            wasConfiguredBefore: false, hadAnyConfiguredBefore: true))
        // Hosted-model OpenRouter is included — an explicit tap isn't "auto-default".
        XCTAssertTrue(SettingsViewModel.shouldPromptToSetDefault(
            savedRef: openrouter, defaultRef: openclaw,
            wasConfiguredBefore: false, hadAnyConfiguredBefore: true))
    }

    func testPredicate_caseCPrime_newButAlreadyDefault_noPrompt() {
        // Configuring the ref the unset-pointer fallback already resolves to
        // (e.g. OpenClaw) — making it default would be a no-op, so no prompt.
        XCTAssertFalse(SettingsViewModel.shouldPromptToSetDefault(
            savedRef: openclaw, defaultRef: openclaw,
            wasConfiguredBefore: false, hadAnyConfiguredBefore: true))
    }

    // MARK: - Manual-save bootstrap (category-agnostic, no dead-end)

    func testBootstrap_firstGatewayHermes_becomesDefault() async throws {
        let vm = await makeVM()
        let preconditions = await SettingsManager.shared.configuredRemoteAgentRefs()
        XCTAssertTrue(preconditions.isEmpty, "Precondition: clean slate.")

        let ok = await saveKeyless(vm, ref: hermes)
        XCTAssertTrue(ok, "A keyless Hermes save must commit on URL alone.")

        // Asserting HERMES (not the `.openclaw` fallback) proves the pointer was
        // actually SET by the bootstrap, not merely resolving to the fallback.
        let defaultRef = await SettingsManager.shared.defaultRemoteAgentRef()
        XCTAssertEqual(defaultRef, hermes,
                       "First gateway ever (Hermes) must become the default — no dead-end.")
        XCTAssertEqual(vm.defaultRemoteAgentRef, hermes,
                       "The VM's cached default must reflect the bootstrap.")
    }

    func testBootstrap_firstGatewayCustom_becomesDefault() async throws {
        let vm = await makeVM()
        let customRef: RemoteAgentRef = .custom(UUID())

        let ok = await saveKeyless(vm, ref: customRef, name: "Home LLM")
        XCTAssertTrue(ok, "A keyless custom save must commit on URL + name.")

        let defaultRef = await SettingsManager.shared.defaultRemoteAgentRef()
        XCTAssertEqual(defaultRef, customRef,
                       "First gateway ever (a custom) must become the default — bootstrap is category-agnostic.")
    }

    func testBootstrap_secondGateway_leavesDefaultUntouched() async throws {
        let vm = await makeVM()

        // First gateway = HERMES (a NON-fallback ref) so the post-second assertion
        // genuinely distinguishes "default untouched" from the `.openclaw` fallback.
        let firstOK = await saveKeyless(vm, ref: hermes, url: "https://hermes.example.test:8642")
        XCTAssertTrue(firstOK)
        let afterFirst = await SettingsManager.shared.defaultRemoteAgentRef()
        XCTAssertEqual(afterFirst, hermes, "First gateway must bootstrap the default.")

        // Second gateway → must NOT re-point the default (that's the prompt's job).
        let secondOK = await saveKeyless(vm, ref: openclaw)
        XCTAssertTrue(secondOK)
        let defaultRef = await SettingsManager.shared.defaultRemoteAgentRef()
        XCTAssertEqual(defaultRef, hermes,
                       "Saving an additional gateway must never silently re-point the default.")
    }

    func testBootstrap_firstGatewayOpenRouter_becomesDefault() async throws {
        // OpenRouter is bearer-locked, so this case needs the access-group
        // Keychain (signed build); skip cleanly on the unsigned sim.
        try await requireGatewayKeychainOrSkip(for: openrouter)
        let vm = await makeVM()

        // Model the open, dirty editor a real Save runs under (fences the reload
        // that would clobber the seeded model buffer).
        vm.editorHasUnsavedChanges = true
        vm.remoteAgentModelStrings[openrouter] = "openai/gpt-4o-mini"
        let ok = await vm.saveRemoteAgent(ref: openrouter, name: nil, stagedToken: .typed("sk-or-test-token"))
        XCTAssertTrue(ok, "An OpenRouter save with a token + model must commit.")

        let defaultRef = await SettingsManager.shared.defaultRemoteAgentRef()
        XCTAssertEqual(defaultRef, openrouter,
                       "First gateway ever (OpenRouter) must become the default — the hosted-model lane is not exempt when it's the only gateway.")
    }

    func testOpenRouterSavePreservesLongModelIdentifierExactly() async throws {
        try await requireGatewayKeychainOrSkip(for: openrouter)
        let vm = await makeVM()
        let model = "provider/team/" + String(repeating: "opaque-model-segment-", count: 8)
        XCTAssertGreaterThan(model.count, 100, "The fixture must cross the retired cap.")

        vm.editorHasUnsavedChanges = true
        vm.remoteAgentModelStrings[openrouter] = "  \(model)  "
        let ok = await vm.saveRemoteAgent(
            ref: openrouter,
            name: nil,
            stagedToken: .typed("sk-or-test-long-model")
        )

        XCTAssertTrue(ok, "A valid OpenRouter token + model must commit.")
        let storedModel = await SettingsManager.shared.getRemoteAgentModel(for: openrouter)
        XCTAssertEqual(
            storedModel,
            model,
            "OpenRouter model identifiers are opaque: Save may trim surrounding whitespace but must preserve the full value."
        )
    }
}
