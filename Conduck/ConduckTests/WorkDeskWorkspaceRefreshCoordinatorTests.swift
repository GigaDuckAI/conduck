// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkDeskWorkspaceRefreshCoordinatorTests.swift
//
// Work's retained project workspace must not turn mode changes or store
// notification bursts into overlapping refreshes. Delayed requests preserve
// hidden changes; started result work completes before a merged trailing pass.

import XCTest
@testable import Conduck

@MainActor
final class WorkDeskWorkspaceRefreshCoordinatorTests: XCTestCase {
    private typealias Request = WorkDeskWorkspaceRefreshCoordinator.Request
    private let delay = Duration.milliseconds(20)
    private let isolated = IsolatedWorkStores()

    override func tearDown() async throws {
        await isolated.cleanUp()
        try await super.tearDown()
    }

    func testReturnedFileArrivingWhileHiddenAppearsOnMetadataRefreshWithoutHistoryRescan() async throws {
        let store = isolated.make()
        let project = WorkDeskProjectRecord(title: "Research")
        _ = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        let conversation = try await store.createConversation(backend: "hermes", projectID: project.id)
        let workspace = WorkDeskWorkspaceState(organization: WorkDeskOrganization(store: store), conversationStore: store)
        var currentMaterials: [WorkboardMaterialSnapshot] = []
        workspace.startRefreshing(isActive: true, materials: { currentMaterials })
        await waitUntil { workspace.projectConversations.contains { $0.id == conversation.id } }
        workspace.selectScope(.project(project.id))
        workspace.suspend()

        let bytes = Data("Returned report".utf8)
        let attachment = AttachmentDraft(mimeType: "text/plain", filename: "report.txt", data: bytes,
            thumbnailData: nil, width: 0, height: 0, byteSize: bytes.count, sequence: 0)
        let reply = try await store.appendMessage(role: "agent", text: "Completed", conversationID: conversation.id,
            sourceDevice: "test", attachments: [attachment])
        // This waits for the pass that appendMessage scheduled. It does not
        // request reconciliation; the durable store owns the arrival trigger.
        let scansAfterArrival = await store._projectResultMessageFetchCountForTesting()
        let storedDesk = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let result = try XCTUnwrap(storedDesk?.materials.first)
        currentMaterials = [await WorkboardLiveRepository.presentationSnapshotForTesting(result)]
        workspace.requestRefresh(.organization)
        await settle()
        XCTAssertNil(workspace.results[result.id], "Hidden metadata stays deferred")

        workspace.setRefreshActive(true)
        await waitUntil { workspace.results[result.id] != nil }
        XCTAssertEqual(workspace.results[result.id]?.messageID, reply.id)
        XCTAssertEqual(workspace.organization.projectID(for: result.id), project.id)
        XCTAssertEqual(workspace.visibleMaterials(in: currentMaterials).map(\.id), [result.id])
        let scansAfterReturn = await store._projectResultMessageFetchCountForTesting()
        XCTAssertEqual(scansAfterReturn, scansAfterArrival,
                       "Returning needs the committed result receipt, not another full history scan")
        workspace.suspend()
    }

    func testMountAndActivationMergeWithIncomingChanges() async {
        var requests: [Request] = []
        let coordinator = WorkDeskWorkspaceRefreshCoordinator(delay: delay) { requests.append($0) }
        coordinator.request(.all)
        coordinator.setActive(true)
        coordinator.request(.organization)
        coordinator.request(.settings)
        await waitUntil { requests.count == 1 }
        await settle()
        XCTAssertEqual(requests, [.all])
    }

    func testCleanModeRoundTripDoesNotReadAgain() async {
        var requests: [Request] = []
        let coordinator = WorkDeskWorkspaceRefreshCoordinator(delay: delay) { requests.append($0) }
        coordinator.request(.all)
        coordinator.setActive(true)
        await waitUntil { requests.count == 1 }
        coordinator.setActive(false)
        coordinator.setActive(true)
        await settle()
        XCTAssertEqual(requests, [.all], "Returning to unchanged Work must reuse its warm data")
    }

    func testHiddenSettingsAndStoreChangesAreMergedAndDrainedOnReturn() async {
        var requests: [Request] = []
        let coordinator = WorkDeskWorkspaceRefreshCoordinator(delay: delay) { requests.append($0) }
        coordinator.request(.settings)
        for _ in 0..<20 { coordinator.request(.organization) }
        await settle()
        XCTAssertTrue(requests.isEmpty)
        coordinator.setActive(true)
        await waitUntil { requests.count == 1 }
        XCTAssertEqual(requests, [[.settings, .organization]])
        XCTAssertFalse(requests[0].contains(.results), "Ordinary Chat changes do not rescan result history")
    }

    func testLeavingDuringDebouncePreservesTheRequestWithoutReading() async {
        var requests: [Request] = []
        let coordinator = WorkDeskWorkspaceRefreshCoordinator(delay: delay) { requests.append($0) }
        coordinator.setActive(true)
        coordinator.request(.all)
        coordinator.setActive(false)
        await settle()
        XCTAssertTrue(requests.isEmpty)
        coordinator.setActive(true)
        await waitUntil { requests.count == 1 }
        XCTAssertEqual(requests, [.all])
    }

    func testCanceledDelayCannotClearReplacementAfterRapidSwitching() async {
        var requests: [Request] = []
        let coordinator = WorkDeskWorkspaceRefreshCoordinator(delay: delay) { requests.append($0) }
        coordinator.request(.organization)
        for _ in 0..<10 {
            coordinator.setActive(true)
            coordinator.setActive(false)
        }
        coordinator.request(.settings)
        coordinator.setActive(true)
        await waitUntil { requests.count == 1 }
        coordinator.request(.results)
        await waitUntil { requests.count == 2 }
        await settle()
        XCTAssertEqual(requests, [[.organization, .settings], .results])
    }

    func testBurstDuringReadProducesOneSerializedTrailingPass() async {
        let gate = RefreshGate()
        var requests: [Request] = []
        var activeReads = 0
        var maximumActiveReads = 0
        let coordinator = WorkDeskWorkspaceRefreshCoordinator(delay: delay) { request in
            requests.append(request)
            activeReads += 1
            maximumActiveReads = max(maximumActiveReads, activeReads)
            if requests.count == 1 { await gate.wait() }
            activeReads -= 1
        }
        coordinator.setActive(true)
        coordinator.request(.organization)
        await waitUntil { gate.isWaiting }
        for _ in 0..<20 { coordinator.request(.organization) }
        coordinator.request(.settings)
        coordinator.request(.results)
        XCTAssertEqual(requests, [.organization])
        gate.resume()
        await waitUntil { requests.count == 2 }
        await settle()
        XCTAssertEqual(requests, [.organization, .all])
        XCTAssertEqual(maximumActiveReads, 1)
    }

    func testHideDuringResultReadFinishesItAndDefersTheTrailingSettings() async {
        let gate = RefreshGate()
        var requests: [Request] = []
        var completed = 0
        var wasCanceled = false
        let coordinator = WorkDeskWorkspaceRefreshCoordinator(delay: delay) { request in
            requests.append(request)
            if requests.count == 1 { await gate.wait() }
            wasCanceled = wasCanceled || Task.isCancelled
            completed += 1
        }
        coordinator.setActive(true)
        coordinator.request(.results)
        await waitUntil { gate.isWaiting }
        coordinator.setActive(false)
        coordinator.request(.settings)
        gate.resume()
        await waitUntil { completed == 1 }
        await settle()
        XCTAssertEqual(requests, [.results])
        XCTAssertFalse(wasCanceled, "A result pass may own durable work once it starts")
        coordinator.setActive(true)
        await waitUntil { completed == 2 }
        XCTAssertEqual(requests, [.results, .settings])
    }

    func testReactivationDuringReadDoesNotStartAnotherPipeline() async {
        let gate = RefreshGate()
        var requests: [Request] = []
        let coordinator = WorkDeskWorkspaceRefreshCoordinator(delay: delay) { request in
            requests.append(request)
            if requests.count == 1 { await gate.wait() }
        }
        coordinator.setActive(true)
        coordinator.request(.all)
        await waitUntil { gate.isWaiting }
        coordinator.setActive(false)
        coordinator.request(.organization)
        coordinator.setActive(true)
        await settle()
        XCTAssertEqual(requests, [.all])
        gate.resume()
        await waitUntil { requests.count == 2 }
        XCTAssertEqual(requests, [.all, .organization])
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(100))
    }

    private func waitUntil(
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for workspace refresh", file: file, line: line)
    }

    private final class RefreshGate {
        private var continuation: CheckedContinuation<Void, Never>?
        var isWaiting: Bool { continuation != nil }
        func wait() async {
            await withCheckedContinuation { continuation = $0 }
        }
        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }
}
