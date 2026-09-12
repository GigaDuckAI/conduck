// SPDX-License-Identifier: Apache-2.0

// Exercises real isolated SQLite reopen, context admission, and kernel mirror
// leases. CloudKit is deliberately absent: these tests prove data preservation
// and coordination, not that Apple's daemon stopped or resumed cloud traffic.

import XCTest
@testable import Conduck

final class ContentSyncPersistenceTests: XCTestCase {
    private struct Fixture: Sendable {
        let store: ConversationStore
        let preference: ContentSyncPreferenceStore
        let url: URL
    }

    private func fixture(
        enabled: Bool? = false,
        policyLock: (any ContentSyncPolicyLock)? = nil,
        defaults: InMemoryDefaultsStore = InMemoryDefaultsStore()
    ) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-sync-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Conversations.sqlite")
        let memory = SettingsDependencies.inMemory(defaults: defaults)
        let dependencies = SettingsDependencies(
            defaults: memory.defaults, ubiquitous: memory.ubiquitous, secrets: memory.secrets,
            cloudAvailability: memory.cloudAvailability, changes: memory.changes,
            contentSyncPolicyLock: policyLock
        )
        let preference = ContentSyncPreferenceStore(dependencies: dependencies)
        if let enabled { try preference.setEnabled(enabled) }
        let store = ConversationStore(storeURL: url, contentSyncPreferenceStore: preference)
        addTeardownBlock {
            try? await store._unloadForTesting()
            await store._removeIsolatedVaultDirectoryForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        return Fixture(store: store, preference: preference, url: url)
    }

    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for the isolated persistence transition")
                throw ConversationStore.ContentSyncTransitionError.unavailable
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testReopenKeepsBothFilesRowsPayloadsAndHistory() async throws {
        let fixture = try fixture()
        let store = fixture.store
        let conversation = try await store.createConversation(backend: "openclaw")
        _ = try await store.appendMessage(
            role: "user", text: "Saved before the change", conversationID: conversation.id,
            sourceDevice: "iphone"
        )
        let materialID = UUID()
        let payload = Data(repeating: 0x71, count: 300_000)
        let locations = try await store._writeMaterialAndBlobForTesting(
            materialID: materialID, title: "Local material", payload: payload
        )
        let firstGeneration = await store._contentSyncGenerationForTesting()

        try fixture.preference.setEnabled(true)
        await store.reconcileContentSyncPreference(forceRetry: true)
        try fixture.preference.setEnabled(false)
        await store.reconcileContentSyncPreference(forceRetry: true)

        let generation = await store._contentSyncGenerationForTesting()
        let conversations = try await store.fetchConversations()
        let messages = try await store.fetchMessages(for: conversation.id)
        let material = try await store._materialAndBlobForTesting(materialID: materialID)
        let mounted = try await store._mountedStoresForTesting()
        let history = await store._contentSyncHistoryOptionsForTesting()
        let state = await store.currentContentSyncState()
        XCTAssertGreaterThanOrEqual(generation, firstGeneration + 2)
        XCTAssertEqual(conversations.map(\.id), [conversation.id])
        XCTAssertEqual(messages.map(\.text), ["Saved before the change"])
        XCTAssertEqual(material.blobPayload, payload)
        XCTAssertEqual(Set(mounted.compactMap(\.url)), Set([locations.materialStoreURL, locations.blobStoreURL].compactMap { $0 }))
        XCTAssertEqual(history, [true, true])
        XCTAssertFalse(state.desiredEnabled)
    }

    func testAContextHeldAcrossAwaitsDrainsBeforeReopenAndLatestToggleWins() async throws {
        let fixture = try fixture()
        let conversation = try await fixture.store.createConversation(backend: "openclaw")
        let generation = await fixture.store._contentSyncGenerationForTesting()
        let lease = try await fixture.store.newReadContextLease()
        defer { lease.finish() }
        try fixture.preference.setEnabled(true)
        let transition = Task { await fixture.store.reconcileContentSyncPreference(forceRetry: true) }
        try await waitUntil { await fixture.store._contentSyncTransitionIsRunningForTesting() }
        let beforeRelease = await fixture.store._contentSyncGenerationForTesting()
        XCTAssertEqual(beforeRelease, generation)

        // A later OFF supersedes an ON that has not yet opened a new session.
        try fixture.preference.setEnabled(false)
        let read = Task { try await fixture.store.fetchConversation(id: conversation.id) }
        lease.finish()
        await transition.value
        let saved = try await read.value
        let state = await fixture.store.currentContentSyncState()
        XCTAssertEqual(saved?.id, conversation.id)
        XCTAssertFalse(state.desiredEnabled)
        XCTAssertEqual(state.phase, .off)
    }

    func testOtherProcessLeaseKeepsOffPendingButLocalSavesContinue() async throws {
        let fixture = try fixture(enabled: true)
        try await fixture.store.ensureLoaded()
        let otherMirror = try ContentSyncProcessLease(beside: fixture.url).acquireMirror()
        defer { otherMirror.release() }
        try fixture.preference.setEnabled(false)
        await fixture.store.reconcileContentSyncPreference(forceRetry: true)
        let waiting = await fixture.store.currentContentSyncState()
        XCTAssertEqual(waiting.failure, .anotherProcess)
        let saved = try await fixture.store.createConversation(backend: "openclaw")

        otherMirror.release()
        await fixture.store.reconcileContentSyncPreference(forceRetry: true)
        let settled = await fixture.store.currentContentSyncState()
        let retained = try await fixture.store.fetchConversation(id: saved.id)
        XCTAssertEqual(settled.phase, .off)
        XCTAssertEqual(retained?.id, saved.id)
    }

    func testAdmissionRechecksAfterAwaitWhenTransitionHasAlreadyDrained() async throws {
        let fixture = try fixture()
        let saved = try await fixture.store.createConversation(backend: "openclaw")
        let drained = ContentSyncTestGate()
        let release = ContentSyncTestGate()
        let completed = ContentSyncTestGate()
        defer { Task { await release.open() } }
        await fixture.store._setContentSyncDrainedHookForTesting {
            await drained.open()
            await release.wait()
        }
        await fixture.store._setContentSyncAdmissionHookForTesting {
            try? fixture.preference.setEnabled(true)
            Task { await fixture.store.reconcileContentSyncPreference(forceRetry: true) }
            await drained.wait()
        }
        let read = Task {
            let result = try await fixture.store.fetchConversation(id: saved.id)
            await completed.open()
            return result
        }
        try await waitUntil { await drained.isOpen }
        try await Task.sleep(for: .milliseconds(30))
        let completedBeforeRelease = await completed.isOpen
        XCTAssertFalse(completedBeforeRelease, "A drained session may not admit a late context")
        await release.open()
        let retained = try await read.value
        XCTAssertEqual(retained?.id, saved.id)
    }

    func testWorkPublicationRollbackResolvesItsRowAfterReopenBetweenDurableSteps() async throws {
        let fixture = try fixture()
        _ = try await fixture.store.upsertDeskMaterial(
            WorkMaterialDraft(kind: .note, title: "Desk", textContent: "Existing note")
        )
        let value = try await fixture.store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(value)
        let stale = WorkboardRevision.value(for: desk.updatedAt) - 1
        let materialID = UUID()
        let crossed = ContentSyncTestGate()
        let initialGeneration = await fixture.store._contentSyncGenerationForTesting()
        await fixture.store._setWorkMaterialPublicationLockHoldForTesting { id in
            guard id == materialID else { return }
            try? fixture.preference.setEnabled(true)
            await fixture.store.reconcileContentSyncPreference(forceRetry: true)
            await crossed.open()
        }
        let payload = Data("Payload whose rejected publication must be rolled back".utf8)
        do {
            _ = try await fixture.store.upsertDeskMaterial(
                WorkMaterialDraft(
                    id: materialID, kind: .file, title: "receipt.txt", filename: "receipt.txt",
                    mimeType: "text/plain", payload: payload, byteSize: Int64(payload.count)
                ),
                expectedOwnerRevision: stale
            )
            XCTFail("The stale project revision must refuse the material")
        } catch { }
        await fixture.store._setWorkMaterialPublicationLockHoldForTesting(nil)
        let blobs = await fixture.store._workMaterialBlobRowsForTesting(materialID: materialID)
        let material = try await fixture.store.fetchWorkMaterial(id: materialID)
        let crossedBoundary = await crossed.isOpen
        let generation = await fixture.store._contentSyncGenerationForTesting()
        XCTAssertTrue(crossedBoundary)
        XCTAssertGreaterThan(generation, initialGeneration)
        XCTAssertTrue(blobs.isEmpty, "Rollback must resolve its permanent row URI in the replacement coordinator")
        XCTAssertNil(material)
    }

    func testFailedEnableFallsBackLocallyAndExplicitRetryPreservesRows() async throws {
        let fixture = try fixture()
        let saved = try await fixture.store.createConversation(backend: "openclaw")
        await fixture.store._failNextContentSyncLoadForTesting()
        try fixture.preference.setEnabled(true)
        await fixture.store.reconcileContentSyncPreference()
        let failed = await fixture.store.currentContentSyncState()
        XCTAssertTrue(failed.desiredEnabled)
        XCTAssertEqual(failed.failure, .storage)
        let retained = try await fixture.store.fetchConversation(id: saved.id)
        XCTAssertEqual(retained?.id, saved.id)
        _ = try await fixture.store.appendMessage(
            role: "user", text: "Saved during unavailable sync", conversationID: saved.id,
            sourceDevice: "iphone"
        )

        await fixture.store.reconcileContentSyncPreference(forceRetry: true)
        let rows = try await fixture.store.fetchMessages(for: saved.id)
        XCTAssertEqual(rows.map(\.text), ["Saved during unavailable sync"])
    }

    func testFailedDisableKeepsOffPreferenceAndCanReopenExistingFiles() async throws {
        let fixture = try fixture(enabled: true)
        let saved = try await fixture.store.createConversation(backend: "openclaw")
        await fixture.store._failNextContentSyncLoadForTesting()
        try fixture.preference.setEnabled(false)
        await fixture.store.reconcileContentSyncPreference()
        let failed = await fixture.store.currentContentSyncState()
        XCTAssertFalse(failed.desiredEnabled)
        XCTAssertEqual(failed.failure, .storage)

        await fixture.store.reconcileContentSyncPreference(forceRetry: true)
        let state = await fixture.store.currentContentSyncState()
        let retained = try await fixture.store.fetchConversation(id: saved.id)
        XCTAssertEqual(state.phase, .off)
        XCTAssertEqual(retained?.id, saved.id)
    }

    func testPolicyReadFailurePreservesKnownChoiceAndDoesNotReopenAsOff() async throws {
        let policyLock = ContentSyncSwitchablePolicyLock()
        let fixture = try fixture(enabled: true, policyLock: policyLock)
        let saved = try await fixture.store.createConversation(backend: "openclaw")
        let generation = await fixture.store._contentSyncGenerationForTesting()
        let existingLease = try await fixture.store.newReadContextLease()
        defer { existingLease.finish() }
        policyLock.setAvailable(false)
        await fixture.store.reconcileContentSyncPreference(forceRetry: true)
        let uncertain = await fixture.store.currentContentSyncState()
        let unchangedGeneration = await fixture.store._contentSyncGenerationForTesting()
        XCTAssertTrue(uncertain.desiredEnabled)
        XCTAssertEqual(uncertain.failure, .policyUnavailable)
        XCTAssertEqual(unchangedGeneration, generation)
        // The existing container is physically local. Policy uncertainty must
        // neither reopen it nor lock the person out of their saved content,
        // even while another local context remains admitted.
        let localLease = try await fixture.store.newReadContextLease()
        localLease.finish()
        _ = try await fixture.store.appendMessage(
            role: "user", text: "Local save while the preference is unreadable",
            conversationID: saved.id, sourceDevice: "iphone"
        )
        existingLease.finish()

        policyLock.setAvailable(true)
        await fixture.store.reconcileContentSyncPreference(forceRetry: true)
        let finalGeneration = await fixture.store._contentSyncGenerationForTesting()
        let retained = try await fixture.store.fetchConversation(id: saved.id)
        XCTAssertEqual(finalGeneration, generation)
        XCTAssertEqual(retained?.id, saved.id)
    }

    func testColdUnreadablePolicyOpensExistingLocalFilesAndPreservesSavesThroughRecovery() async throws {
        let policyLock = ContentSyncSwitchablePolicyLock()
        let fixture = try fixture(enabled: true, policyLock: policyLock)

        // Seed the exact files before this preference-owning instance has ever
        // loaded them, matching an upgrade of an existing installed library.
        let previous = ConversationStore(storeURL: fixture.url)
        let conversation = try await previous.createConversation(backend: "openclaw")
        _ = try await previous.appendMessage(
            role: "user", text: "Existing conversation", conversationID: conversation.id,
            sourceDevice: "mac"
        )
        let materialID = UUID()
        let payload = Data(repeating: 0x35, count: 300_000)
        let locations = try await previous._writeMaterialAndBlobForTesting(
            materialID: materialID, title: "Existing file", payload: payload
        )
        try await previous._unloadForTesting()
        await previous._removeIsolatedVaultDirectoryForTesting()

        policyLock.setAvailable(false)
        async let loadedConversations = fixture.store.fetchConversations()
        async let loadedMaterial = fixture.store._materialAndBlobForTesting(materialID: materialID)
        let (conversations, material) = try await (loadedConversations, loadedMaterial)
        let mounted = try await fixture.store._mountedStoresForTesting()
        let waiting = await fixture.store.currentContentSyncState()
        let coldGeneration = await fixture.store._contentSyncGenerationForTesting()
        XCTAssertEqual(conversations.map(\.id), [conversation.id])
        XCTAssertEqual(material.blobPayload, payload)
        XCTAssertEqual(Set(mounted.compactMap(\.url)), Set([locations.materialStoreURL, locations.blobStoreURL].compactMap { $0 }))
        XCTAssertEqual(waiting.failure, .policyUnavailable)
        XCTAssertNotEqual(waiting.phase, .off, "An unreadable preference is not an applied OFF")
        XCTAssertEqual(coldGeneration, 1, "Concurrent callers share the one local fallback load")

        _ = try await fixture.store.appendMessage(
            role: "user", text: "Saved while sync settings are unavailable",
            conversationID: conversation.id, sourceDevice: "mac"
        )
        let note = try await fixture.store.upsertDeskMaterial(
            WorkMaterialDraft(kind: .note, title: "New local note", textContent: "Still available")
        )
        let writtenMessages = try await fixture.store.fetchMessages(for: conversation.id)
        XCTAssertEqual(writtenMessages.count, 2)

        policyLock.setAvailable(true)
        await fixture.store.reconcileContentSyncPreference(forceRetry: true)
        let recovered = await fixture.store.currentContentSyncState()
        let retainedMessages = try await fixture.store.fetchMessages(for: conversation.id)
        let retainedNote = try await fixture.store.fetchWorkMaterial(id: note.id)
        let retainedMaterial = try await fixture.store._materialAndBlobForTesting(materialID: materialID)
        XCTAssertTrue(recovered.desiredEnabled)
        XCTAssertNotEqual(recovered.failure, .policyUnavailable)
        XCTAssertEqual(retainedMessages.map(\.id), writtenMessages.map(\.id))
        XCTAssertEqual(retainedNote?.textContent, "Still available")
        XCTAssertEqual(retainedMaterial.blobPayload, payload)
    }

    func testRealPolicyFileAndFailedDefaultsFlushPreserveExistingStoresAndDurableOff() async throws {
        let policyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-policy-integration-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: policyDirectory) }
        let fixture = try fixture(
            enabled: nil,
            policyLock: ContentSyncPolicyFile(directoryURL: policyDirectory),
            defaults: InMemoryDefaultsStore(synchronizationSucceeds: false)
        )
        let previous = ConversationStore(storeURL: fixture.url)
        let conversation = try await previous.createConversation(backend: "openclaw")
        _ = try await previous.appendMessage(
            role: "user", text: "Before the update", conversationID: conversation.id, sourceDevice: "mac"
        )
        let materialID = UUID()
        let payload = Data(repeating: 0x24, count: 300_000)
        let originalLocations = try await previous._writeMaterialAndBlobForTesting(
            materialID: materialID, title: "Existing payload", payload: payload
        )
        try await previous._unloadForTesting()
        await previous._removeIsolatedVaultDirectoryForTesting()

        XCTAssertTrue(try fixture.preference.readEnabled())
        XCTAssertNil(fixture.preference.currentPreference(), "Reading default ON must not author a choice")
        let loaded = try await fixture.store.fetchConversation(id: conversation.id)
        let loadedMaterial = try await fixture.store._materialAndBlobForTesting(materialID: materialID)
        XCTAssertEqual(loaded?.id, conversation.id)
        XCTAssertEqual(loadedMaterial.blobPayload, payload)

        let off = try fixture.preference.setEnabled(false)
        await fixture.store.reconcileContentSyncPreference(forceRetry: true)
        let afterOff = await fixture.store.currentContentSyncState()
        XCTAssertEqual(afterOff.phase, .off)
        _ = try await fixture.store.appendMessage(
            role: "user", text: "After turning sync off", conversationID: conversation.id, sourceDevice: "mac"
        )
        try await fixture.store._unloadForTesting()

        // Neither defaults nor KVS is shared with the first preference object.
        // The production file adapter is the only path by which OFF can arrive.
        let independent = SettingsDependencies.inMemory(
            defaults: InMemoryDefaultsStore(synchronizationSucceeds: false)
        )
        let reopenedPreferences = ContentSyncPreferenceStore(dependencies: SettingsDependencies(
            defaults: independent.defaults, ubiquitous: independent.ubiquitous, secrets: independent.secrets,
            cloudAvailability: independent.cloudAvailability, changes: independent.changes,
            contentSyncPolicyLock: ContentSyncPolicyFile(directoryURL: policyDirectory)
        ))
        XCTAssertEqual(reopenedPreferences.currentPreference(), off)
        let reopened = ConversationStore(storeURL: fixture.url, contentSyncPreferenceStore: reopenedPreferences)
        addTeardownBlock {
            try? await reopened._unloadForTesting()
            await reopened._removeIsolatedVaultDirectoryForTesting()
        }
        let messages = try await reopened.fetchMessages(for: conversation.id)
        let material = try await reopened._materialAndBlobForTesting(materialID: materialID)
        let mounted = try await reopened._mountedStoresForTesting()
        let state = await reopened.currentContentSyncState()
        XCTAssertEqual(messages.map(\.text), ["Before the update", "After turning sync off"])
        XCTAssertEqual(material.blobPayload, payload)
        XCTAssertEqual(state.phase, .off)
        XCTAssertEqual(Set(mounted.compactMap(\.url)), Set([originalLocations.materialStoreURL, originalLocations.blobStoreURL].compactMap { $0 }))
    }

    func testMirrorLeaseBlocksExclusiveProofUntilEveryHolderReleases() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-sync-lock-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let lock = ContentSyncProcessLease(beside: directory.appendingPathComponent("Conversations.sqlite"))
        let first = try lock.acquireMirror()
        let second = try lock.acquireMirror()
        defer { first.release(); second.release() }
        XCTAssertThrowsError(try lock.confirmNoMirrors())
        first.release()
        XCTAssertThrowsError(try lock.confirmNoMirrors())
        second.release()
        XCTAssertNoThrow(try lock.confirmNoMirrors())
        let replacement = try lock.acquireMirror()
        replacement.release()
        XCTAssertNoThrow(try lock.confirmNoMirrors())
    }
}

private actor ContentSyncTestGate {
    private(set) var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private nonisolated final class ContentSyncSwitchablePolicyLock: ContentSyncPolicyLock, @unchecked Sendable {
    private let state = NSLock()
    private var available = true
    func setAvailable(_ value: Bool) { state.withLock { available = value } }
    func lock() -> Bool { state.withLock { available } }
    func unlock() {}
}
