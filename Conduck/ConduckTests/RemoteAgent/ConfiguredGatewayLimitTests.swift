// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConfiguredGatewayLimitTests.swift
//
// Admission is about saved definitions, not momentary send readiness. Exercise
// every built-in/custom split, credential failures, concurrent admissions and
// uncapped iCloud restoration against isolated in-memory stores.

import XCTest
import Security
@testable import Conduck

final class ConfiguredGatewayLimitTests: XCTestCase {
    private struct Rig {
        let manager: SettingsManager
        let defaults: InMemoryDefaultsStore
        let kvs: InMemoryUbiquitousStore
        let secrets: InMemorySecretStore
        let secretReads: GatewaySecretReadCounter
    }

    private func makeRig(unreadableSecrets: Bool = false,
                         access: @escaping @Sendable () -> ProAccessSnapshot = { ProAccessSnapshot() }) -> Rig {
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()
        let secrets = InMemorySecretStore()
        let secretReads = GatewaySecretReadCounter()
        let readableStore: any SecretStore = unreadableSecrets ? UnreadableSecrets(base: secrets) : secrets
        let secretStore = CountingGatewaySecrets(base: readableStore, counter: secretReads)
        let manager = SettingsManager(dependencies: SettingsDependencies(
            defaults: defaults, ubiquitous: kvs, secrets: secretStore,
            cloudAvailability: StubCloudAvailability(available: true),
            changes: InMemoryKVSChangeSource(store: kvs)
        ), proAccess: access)
        return Rig(manager: manager, defaults: defaults, kvs: kvs, secrets: secrets, secretReads: secretReads)
    }

    private func save(
        _ ref: RemoteAgentRef, in rig: Rig,
        url: String = "https://gateway.example.test", token: String? = nil,
        name: String = "Saved server"
    ) async -> SettingsManager.GatewayConfigurationCommitResult {
        // Match the editor's validated input: hosted lanes use the descriptor's
        // fixed endpoint, even on their first save. Comparing an arbitrary test
        // URL against that synthesized endpoint would report a host change the
        // real OpenRouter editor cannot request.
        let resolvedURL: URL
        if case .builtin(let backend) = ref {
            resolvedURL = RemoteAgentBackendRegistry.lookup(id: backend).fixedURL ?? URL(string: url)!
        } else {
            resolvedURL = URL(string: url)!
        }
        return await rig.manager.commitRemoteAgentConfiguration(
            ref: ref, url: resolvedURL,
            authScheme: token == nil ? .none : .bearer, token: token,
            fingerprint: nil, model: ref == .builtin(.openrouter) ? "test/model" : nil,
            customGateway: ref.customID.map { CustomGateway(id: $0, name: name) }
        )
    }

    func testEveryBuiltinCustomSplitSharesOneAllowanceAndOpenRouterIsExempt() async {
        for builtinCount in 0...2 {
            let rig = makeRig()
            let initial = await rig.manager.remoteAgentInventory()
            XCTAssertEqual(initial.allowanceRefs.count, 0, "Untouched built-ins consume no slots")
            let builtins: [RemoteAgentRef] = [.builtin(.openclaw), .builtin(.hermes)]
            for ref in builtins.prefix(builtinCount) {
                let result = await save(ref, in: rig)
                XCTAssertEqual(result, .committed(urlChanged: true))
            }
            for _ in builtinCount..<Constants.maxConfiguredGateways {
                let result = await save(.custom(UUID()), in: rig)
                XCTAssertEqual(result, .committed(urlChanged: true))
            }
            let overflow = await save(.custom(UUID()), in: rig, token: "never-written")
            XCTAssertEqual(overflow, .limitReached)
            if builtinCount < 2 {
                let builtinOverflow = await save(builtins[builtinCount], in: rig)
                XCTAssertEqual(builtinOverflow, .limitReached)
            }
            let hosted = await save(.builtin(.openrouter), in: rig, token: "hosted-key")
            XCTAssertEqual(hosted, .committed(urlChanged: false))
            let after = await rig.manager.remoteAgentInventory()
            XCTAssertEqual(after.allowanceRefs.count, Constants.maxConfiguredGateways)
            XCTAssertTrue(after.configuredRefs.contains(.builtin(.openrouter)))
        }
    }

    func testMissingBearerTokenKeepsSlotWhileSendingStaysFailClosed() async {
        let rig = makeRig()
        let ref: RemoteAgentRef = .builtin(.openclaw)
        _ = await save(ref, in: rig, token: "saved-key")
        try? await rig.manager.clearRemoteAgentToken(for: ref)
        let inventory = await rig.manager.remoteAgentInventory()
        XCTAssertTrue(inventory.allowanceRefs.contains(ref))
        XCTAssertFalse(inventory.configuredRefs.contains(ref))
        _ = await save(.custom(UUID()), in: rig)
        _ = await save(.custom(UUID()), in: rig)
        let refused = await save(.builtin(.hermes), in: rig)
        XCTAssertEqual(refused, .limitReached)
        let repair = await save(ref, in: rig, token: "repaired-key")
        XCTAssertEqual(repair, .committed(urlChanged: false))
    }

    func testUnreadableKeychainDoesNotFreeSavedGatewaySlots() async {
        let rig = makeRig(unreadableSecrets: true)
        _ = await save(.builtin(.openclaw), in: rig, token: "saved-key")
        _ = await save(.custom(UUID()), in: rig, token: "saved-key")
        _ = await save(.custom(UUID()), in: rig, token: "saved-key")
        let inventory = await rig.manager.remoteAgentInventory()
        XCTAssertEqual(inventory.allowanceRefs.count, Constants.maxConfiguredGateways)
        XCTAssertTrue(inventory.configuredRefs.isEmpty)
        let refused = await save(.builtin(.hermes), in: rig)
        XCTAssertEqual(refused, .limitReached)
    }

    func testCapRejectionWritesNeitherTokenNorDefinitionNorRoutingState() async {
        let rig = makeRig()
        for _ in 0..<Constants.maxConfiguredGateways { _ = await save(.custom(UUID()), in: rig) }
        let ref: RemoteAgentRef = .builtin(.hermes)
        rig.defaults.set("preserved-session", forKey: Constants.remoteAgentActiveSessionKey)
        let before = rig.defaults.dictionaryRepresentation() as NSDictionary
        let cloudBefore = rig.kvs.dictionaryRepresentation() as NSDictionary
        let refused = await save(ref, in: rig, token: "must-not-persist")
        XCTAssertEqual(refused, .limitReached)
        XCTAssertEqual(rig.defaults.dictionaryRepresentation() as NSDictionary, before)
        XCTAssertEqual(rig.kvs.dictionaryRepresentation() as NSDictionary, cloudBefore)
        let token = await rig.manager.getRemoteAgentToken(for: ref)
        XCTAssertNil(token)
    }

    func testCredentialFailureLeavesExistingDefinitionUnchangedAndFreesFreshSlot() async {
        let rig = makeRig()
        let ref: RemoteAgentRef = .custom(UUID())
        rig.secrets.failWrites(for: Constants.remoteAgentTokenKeychainAccount(for: ref))
        let failed = await save(ref, in: rig, token: "cannot-save")
        XCTAssertEqual(failed, .credentialWriteFailed)
        let empty = await rig.manager.remoteAgentInventory()
        XCTAssertEqual(empty.allowanceRefs.count, 0)
        XCTAssertTrue(empty.customGateways.isEmpty)
        rig.secrets.failWrites(for: nil)
        _ = await save(ref, in: rig, token: "old-token", name: "Original")
        _ = await save(.builtin(.openclaw), in: rig)
        _ = await save(.builtin(.hermes), in: rig)
        rig.secrets.failWrites(for: Constants.remoteAgentTokenKeychainAccount(for: ref))
        let edit = await save(ref, in: rig, url: "https://changed.example.test", token: "new-token", name: "Changed")
        XCTAssertEqual(edit, .credentialWriteFailed)
        let url = await rig.manager.getRemoteAgentURL(for: ref)
        let token = await rig.manager.getRemoteAgentToken(for: ref)
        let row = await rig.manager.customGateway(id: ref.customID!)
        XCTAssertEqual(url?.absoluteString, "https://gateway.example.test")
        XCTAssertEqual(token, "old-token")
        XCTAssertEqual(row?.name, "Original")
    }

    func testRemovingCustomFreesSlotForPreviouslyUntouchedBuiltin() async {
        let rig = makeRig()
        let custom: RemoteAgentRef = .custom(UUID())
        _ = await save(.builtin(.openclaw), in: rig)
        _ = await save(custom, in: rig)
        _ = await save(.custom(UUID()), in: rig)
        await rig.manager.deleteCustomGateway(id: custom.customID!)
        let result = await save(.builtin(.hermes), in: rig)
        XCTAssertEqual(result, .committed(urlChanged: true))
        let inventory = await rig.manager.remoteAgentInventory()
        XCTAssertEqual(inventory.allowanceRefs.count, Constants.maxConfiguredGateways)
    }

    func testConcurrentWindowsCannotBothClaimTheLastSlot() async {
        let rig = makeRig()
        _ = await save(.builtin(.openclaw), in: rig)
        _ = await save(.builtin(.hermes), in: rig)
        let refs = [RemoteAgentRef.custom(UUID()), .custom(UUID())]
        let results = await withTaskGroup(of: SettingsManager.GatewayConfigurationCommitResult.self) { group in
            for ref in refs {
                group.addTask {
                    await rig.manager.commitRemoteAgentConfiguration(
                        ref: ref, url: URL(string: "https://gateway.example.test")!,
                        authScheme: .none, token: nil, fingerprint: nil, model: nil,
                        customGateway: CustomGateway(id: ref.customID!, name: "Contender")
                    )
                }
            }
            var all: [SettingsManager.GatewayConfigurationCommitResult] = []
            for await result in group { all.append(result) }
            return all
        }
        XCTAssertEqual(results.filter { $0 == .committed(urlChanged: true) }.count, 1)
        XCTAssertEqual(results.filter { $0 == .limitReached }.count, 1)
        let inventory = await rig.manager.remoteAgentInventory()
        XCTAssertEqual(inventory.allowanceRefs.count, Constants.maxConfiguredGateways)
    }

    func testCloudOverCapRosterRemainsReadableRepairableAndBlocksOnlyNewDefinitions() async throws {
        let rig = makeRig()
        let rows = (0..<(Constants.maxConfiguredGateways + 2)).map { CustomGateway(id: UUID(), name: "Synced \($0)") }
        let roster = try JSONEncoder().encode(rows)
        rig.kvs.set(roster, forKey: Constants.customGatewaysRegistryKey)
        await rig.manager.handleICloudChange(KVSChange(
            reason: .serverChange, changedKeys: [Constants.customGatewaysRegistryKey]
        ))
        let restored = await rig.manager.remoteAgentInventory()
        XCTAssertEqual(restored.customGateways.map(\.id), rows.map(\.id))
        XCTAssertEqual(restored.allowanceRefs.count, rows.count)
        let repair = await save(.custom(rows[0].id), in: rig, name: "Repaired")
        XCTAssertEqual(repair, .committed(urlChanged: true))
        let blocked = await save(.builtin(.openclaw), in: rig)
        XCTAssertEqual(blocked, .limitReached)
        let hosted = await save(.builtin(.openrouter), in: rig, token: "hosted-key")
        XCTAssertEqual(hosted, .committed(urlChanged: false))
        let final = await rig.manager.customGateways()
        XCTAssertEqual(final.map(\.id), rows.map(\.id))
    }
    func testLateBadgeEditCannotResurrectForgottenGatewayAfterSlotWasReused() async {
        let rig = makeRig()
        let oldID = UUID()
        _ = await save(.custom(oldID), in: rig)
        _ = await save(.builtin(.openclaw), in: rig)
        _ = await save(.builtin(.hermes), in: rig)
        await rig.manager.deleteCustomGateway(id: oldID)
        let replacementID = UUID()
        _ = await save(.custom(replacementID), in: rig)
        let updated = await rig.manager.updateExistingCustomGatewayBadge(id: oldID, colorID: "teal", monogram: "OLD")
        XCTAssertFalse(updated)
        let roster = await rig.manager.customGateways()
        XCTAssertEqual(roster.map(\.id), [replacementID])
        let inventory = await rig.manager.remoteAgentInventory()
        XCTAssertEqual(inventory.allowanceRefs.count, Constants.maxConfiguredGateways)
    }

    func testBadgeEditPreservesLatestNameAndModelAtCap() async {
        let rig = makeRig()
        let id = UUID()
        _ = await save(.custom(id), in: rig, name: "Latest name")
        _ = await save(.builtin(.openclaw), in: rig)
        _ = await save(.builtin(.hermes), in: rig)
        let updated = await rig.manager.updateExistingCustomGatewayBadge(id: id, colorID: "teal", monogram: "AI")
        XCTAssertTrue(updated)
        let row = await rig.manager.customGateway(id: id)
        XCTAssertEqual(row?.name, "Latest name")
        XCTAssertEqual(row?.colorID, "teal")
        XCTAssertEqual(row?.monogram, "AI")
    }

    func testProAdmitsUnlimitedGatewaysAndExpiryRequiresExplicitSelection() async {
        let access = GatewayTestAccess(ProAccessSnapshot(hasProAccess: true))
        let rig = makeRig(access: { access.value })
        let refs = [RemoteAgentRef.builtin(.openclaw), .builtin(.hermes)] + (0..<5).map { _ in .custom(UUID()) }
        for ref in refs {
            let result = await save(ref, in: rig, token: "saved-key")
            XCTAssertEqual(result, .committed(urlChanged: true))
        }
        _ = await save(.builtin(.openrouter), in: rig, token: "hosted-key")
        access.value = ProAccessSnapshot(hasExpiredSubscription: true)
        let pending = await rig.manager.gatewayActivationState()
        XCTAssertTrue(pending.requiresSelection)
        let blocked = await rig.manager.remoteAgentSnapshot(forConversationBackend: refs[0].rawString)
        XCTAssertNil(blocked)
        let choice = Set(refs.prefix(3))
        let chosen = await rig.manager.chooseActiveRemoteAgents(choice)
        XCTAssertTrue(chosen)
        let state = await rig.manager.gatewayActivationState()
        XCTAssertEqual(state.activeRefs, choice)
        let sendable = await rig.manager.configuredRemoteAgentRefs()
        XCTAssertEqual(Set(sendable), choice.union([.builtin(.openrouter)]))
        let inactive = refs.last!
        let blockedInactive = await rig.manager.remoteAgentSnapshot(for: inactive)
        let preserved = await rig.manager.remoteAgentConfigurationSnapshot(for: inactive)
        let token = await rig.manager.getRemoteAgentToken(for: inactive)
        XCTAssertNil(blockedInactive)
        XCTAssertNotNil(preserved)
        XCTAssertEqual(token, "saved-key")
        let edit = await save(inactive, in: rig, name: "Edited while inactive")
        XCTAssertEqual(edit, .committed(urlChanged: false))
        let afterEdit = await rig.manager.isRemoteAgentActive(inactive)
        XCTAssertFalse(afterEdit, "Editing must never implicitly reactivate a gateway")
    }

    func testSelectionCannotExceedThreeAndLaterProExpansionRequiresNewChoice() async {
        let access = GatewayTestAccess(ProAccessSnapshot(hasProAccess: true))
        let rig = makeRig(access: { access.value })
        let refs = (0..<5).map { _ in RemoteAgentRef.custom(UUID()) }
        for ref in refs { _ = await save(ref, in: rig) }
        access.value = ProAccessSnapshot(hasExpiredSubscription: true)
        let tooMany = await rig.manager.chooseActiveRemoteAgents(Set(refs.prefix(4)))
        XCTAssertFalse(tooMany)
        let chosen = await rig.manager.chooseActiveRemoteAgents(Set(refs.prefix(3)))
        XCTAssertTrue(chosen)
        access.value = ProAccessSnapshot(hasProAccess: true)
        let expanded = await save(.custom(UUID()), in: rig)
        XCTAssertEqual(expanded, .committed(urlChanged: true))
        access.value = ProAccessSnapshot(hasExpiredSubscription: true)
        let state = await rig.manager.gatewayActivationState()
        XCTAssertTrue(state.requiresSelection)
        XCTAssertTrue(state.activeRefs.isEmpty)
    }

    func testFreeSelectionSyncsWithoutGrantingProAndEnvelopeKeepsInactiveConfigurations() async throws {
        let access = GatewayTestAccess(ProAccessSnapshot(hasProAccess: true))
        let rig = makeRig(access: { access.value })
        let refs = (0..<5).map { _ in RemoteAgentRef.custom(UUID()) }
        for ref in refs { _ = await save(ref, in: rig) }
        access.value = ProAccessSnapshot(hasExpiredSubscription: true)
        let selection = GatewayFreeSelection(selectedRefs: Set(refs.prefix(2).map(\.rawString)),
            reviewedRefs: Set(refs.map(\.rawString)))
        rig.kvs.set(try JSONEncoder().encode(selection), forKey: GatewayFreeSelection.storageKey)
        await rig.manager.handleICloudChange(KVSChange(reason: .serverChange, changedKeys: [GatewayFreeSelection.storageKey]))
        let state = await rig.manager.gatewayActivationState()
        XCTAssertEqual(state.activeRefs, Set(refs.prefix(2)))
        let envelope = await rig.manager.currentRemoteAgentMultiEnvelope()
        XCTAssertEqual(envelope?.backends.count, refs.count, "Selection must not look like Forget to the wrist")
        XCTAssertEqual(envelope?.freeGatewaySelection, selection)
        XCTAssertEqual(envelope?.requiresFreeGatewaySelection, true)
        let raw = try XCTUnwrap(envelope?.encodedDict())
        XCTAssertEqual(RemoteAgentMultiBroadcastEnvelope.decode(from: raw)?.freeGatewaySelection, selection)
        let fourth = await save(.custom(UUID()), in: rig)
        XCTAssertEqual(fourth, .committed(urlChanged: true), "A free active slot can be used without deleting inactive history")
        let full = await rig.manager.gatewayActivationState()
        XCTAssertEqual(full.activeRefs.count, Constants.maxConfiguredGateways)
        XCTAssertFalse(full.requiresSelection)
        let overflow = await save(.custom(UUID()), in: rig)
        XCTAssertEqual(overflow, .limitReached)
    }

    func testColdUnverifiedProAndExpiryNeverReplaceSavedDefaultWithOpenRouter() async {
        for defaultIsCustom in [false, true] {
            let access = GatewayTestAccess(ProAccessSnapshot(hasProAccess: true))
            let rig = makeRig(access: { access.value })
            let refs = [RemoteAgentRef.builtin(.openclaw), .builtin(.hermes), .custom(UUID()), .custom(UUID())]
            for ref in refs { _ = await save(ref, in: rig, token: "readable-token") }
            _ = await save(.builtin(.openrouter), in: rig, token: "hosted-token")
            let original = defaultIsCustom ? refs.last! : refs[0]
            let conversationID = UUID()
            rig.defaults.set(original.rawString, forKey: Constants.remoteAgentDefaultBackendKVSKey)
            rig.defaults.set(conversationID.uuidString, forKey: Constants.remoteAgentActiveConversationIDKey)

            // A cold process starts with no verified evidence, even for a paid
            // subscriber. Expiry later has the same non-destructive obligation.
            for unavailableAccess in [ProAccessSnapshot(), ProAccessSnapshot(hasExpiredSubscription: true)] {
                access.value = unavailableAccess
                let snapshot = await rig.manager.newChatPickerSnapshot()
                XCTAssertEqual(snapshot.configuredRefs, [.builtin(.openrouter)])
                XCTAssertEqual(snapshot.resolution, .defaultUnavailable(
                    pointer: original, candidates: [.builtin(.openrouter)], pointerIsParked: false))
                XCTAssertEqual(rig.defaults.string(forKey: Constants.remoteAgentDefaultBackendKVSKey), original.rawString)
                XCTAssertEqual(rig.defaults.string(forKey: Constants.remoteAgentActiveConversationIDKey), conversationID.uuidString)
                let adoption = await rig.manager.pendingDefaultAdoptionNotice()
                XCTAssertNil(adoption)

                access.value = ProAccessSnapshot(hasProAccess: true)
                let restored = await rig.manager.resolveDefaultGateway()
                XCTAssertEqual(restored, .usable(original))
                XCTAssertEqual(rig.defaults.string(forKey: Constants.remoteAgentActiveConversationIDKey), conversationID.uuidString)
            }
        }
    }

    func testExplicitFreeSelectionRetainsInactiveDefaultAndActiveConversation() async {
        let access = GatewayTestAccess(ProAccessSnapshot(hasProAccess: true))
        let rig = makeRig(access: { access.value })
        let refs = (0..<4).map { _ in RemoteAgentRef.custom(UUID()) }
        for ref in refs { _ = await save(ref, in: rig, token: "readable-token") }
        let original = refs[0]
        let conversationID = UUID()
        rig.defaults.set(original.rawString, forKey: Constants.remoteAgentDefaultBackendKVSKey)
        rig.defaults.set(conversationID.uuidString, forKey: Constants.remoteAgentActiveConversationIDKey)
        access.value = ProAccessSnapshot(hasExpiredSubscription: true)
        let chosen = await rig.manager.chooseActiveRemoteAgents([refs[1]])
        XCTAssertTrue(chosen)
        let result = await rig.manager.resolveDefaultGateway()
        XCTAssertEqual(result, .defaultUnavailable(pointer: original, candidates: [refs[1]], pointerIsParked: false))
        XCTAssertEqual(rig.defaults.string(forKey: Constants.remoteAgentDefaultBackendKVSKey), original.rawString)
        XCTAssertEqual(rig.defaults.string(forKey: Constants.remoteAgentActiveConversationIDKey), conversationID.uuidString)
    }

    func testUnchosenDefaultIsNotBootstrappedFromPlanFilteredRoster() async {
        let access = GatewayTestAccess(ProAccessSnapshot(hasProAccess: true))
        let rig = makeRig(access: { access.value })
        for _ in 0..<4 { _ = await save(.custom(UUID()), in: rig, token: "readable-token") }
        _ = await save(.builtin(.openrouter), in: rig, token: "hosted-token")
        access.value = ProAccessSnapshot()
        let result = await rig.manager.resolveDefaultGateway()
        XCTAssertEqual(result, .selectionRequired(candidates: [.builtin(.openrouter)]))
        XCTAssertNil(rig.defaults.string(forKey: Constants.remoteAgentDefaultBackendKVSKey))
    }

    func testMissingDefinitionStillAdoptsTheOnlyConfiguredGateway() async {
        let rig = makeRig()
        _ = await save(.builtin(.hermes), in: rig, token: "readable-token")
        rig.defaults.set(RemoteAgentRef.builtin(.openclaw).rawString, forKey: Constants.remoteAgentDefaultBackendKVSKey)
        let result = await rig.manager.resolveDefaultGateway()
        XCTAssertEqual(result, .adopted(ref: .builtin(.hermes), replacing: .builtin(.openclaw)))
        XCTAssertEqual(rig.defaults.string(forKey: Constants.remoteAgentDefaultBackendKVSKey), RemoteAgentRef.builtin(.hermes).rawString)
    }

    func testRetainedFreeRosterUsesLinearSecretReadsForConfiguredProjection() async {
        for count in [8, 32] {
            let access = GatewayTestAccess(ProAccessSnapshot(hasProAccess: true))
            let rig = makeRig(access: { access.value })
            let refs = (0..<count).map { _ in RemoteAgentRef.custom(UUID()) }
            for ref in refs { _ = await save(ref, in: rig, token: "readable-token") }
            access.value = ProAccessSnapshot(hasExpiredSubscription: true)
            let chosen = await rig.manager.chooseActiveRemoteAgents(Set(refs.prefix(3)))
            XCTAssertTrue(chosen)
            rig.secretReads.reset()
            let active = await rig.manager.configuredRemoteAgentRefs()
            XCTAssertEqual(Set(active), Set(refs.prefix(3)))
            XCTAssertLessThanOrEqual(rig.secretReads.count, count * 4 + 12,
                "Every retained gateway must not trigger another complete Keychain scan")
        }
    }

    func testExpiredSubscriptionWithThreeDefinitionsKeepsThemActive() async {
        let rig = makeRig(access: { ProAccessSnapshot(hasExpiredSubscription: true) })
        let refs = [RemoteAgentRef.builtin(.openclaw), .builtin(.hermes), .custom(UUID())]
        for ref in refs { _ = await save(ref, in: rig) }
        let state = await rig.manager.gatewayActivationState()
        XCTAssertFalse(state.requiresSelection)
        XCTAssertEqual(state.activeRefs, Set(refs))
    }

}

/// Models a locked/read-failing Keychain while preserving writes, so admission
/// cannot accidentally depend on bearer readiness. No real Keychain is touched.
private final class UnreadableSecrets: SecretStore, @unchecked Sendable {
    let base: InMemorySecretStore
    init(base: InMemorySecretStore) { self.base = base }
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?) {
        (errSecInteractionNotAllowed, nil)
    }
    func add(_ attributes: [String: Any]) -> OSStatus { base.add(attributes) }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        base.update(query, attributes: attributes)
    }
    func delete(_ query: [String: Any]) -> OSStatus { base.delete(query) }
}

/// A mutable entitlement source local to one test rig; never grants access to
/// the application singleton or the developer's signed-in App Store account.
private final class GatewayTestAccess: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ProAccessSnapshot
    init(_ value: ProAccessSnapshot) { stored = value }
    var value: ProAccessSnapshot {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

/// Counts real calls through the injected storage seam, without a time-based
/// performance threshold or a production-only query hook.
private final class GatewaySecretReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return reads }
    func record() { lock.lock(); defer { lock.unlock() }; reads += 1 }
    func reset() { lock.lock(); defer { lock.unlock() }; reads = 0 }
}

private final class CountingGatewaySecrets: SecretStore, @unchecked Sendable {
    let base: any SecretStore
    let counter: GatewaySecretReadCounter
    init(base: any SecretStore, counter: GatewaySecretReadCounter) {
        self.base = base
        self.counter = counter
    }
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?) {
        counter.record()
        return base.copyMatching(query)
    }
    func add(_ attributes: [String: Any]) -> OSStatus { base.add(attributes) }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        base.update(query, attributes: attributes)
    }
    func delete(_ query: [String: Any]) -> OSStatus { base.delete(query) }
}
