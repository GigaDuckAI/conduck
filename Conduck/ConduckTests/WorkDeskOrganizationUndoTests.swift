// SPDX-License-Identifier: Apache-2.0

// Native Undo/Redo groups are synchronous while organization restoration is
// asynchronous. Controlled store completions verify ordering, busy state and
// failed inverses without relying on animation timing or a physical keyboard.

import XCTest
import Foundation
@testable import Conduck

@MainActor
final class WorkDeskOrganizationUndoTests: XCTestCase {
    func testRapidUndoRedoWaitsForTheFirstRestoreAndKeepsBusyUntilBothFinish() async throws {
        let fixture = Fixture()
        let store = DeferredRestoreStore(snapshot: fixture.afterSnapshot)
        let organization = WorkDeskOrganization(fetch: { await store.snapshot }, apply: { try await store.apply($0) })
        await organization.reload()
        let controller = WorkDeskOrganizationUndoController()
        let manager = UndoManager()
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        controller.receive(fixture.receipt, organization: organization, manager: manager)
        manager.endUndoGrouping()
        XCTAssertTrue(manager.canUndo)
        manager.undo()
        XCTAssertTrue(manager.canRedo, "The inverse must register inside the native undo group.")
        manager.redo()
        XCTAssertTrue(controller.isApplying)
        try await waitUntil { await store.startedCount == 1 }
        XCTAssertTrue(controller.isApplying)
        await store.completeNext()
        try await waitUntil { await store.startedCount == 2 }
        XCTAssertTrue(controller.isApplying, "The second restore is still pending after the first completes.")
        await store.completeNext()
        try await waitUntil { !controller.isApplying }
        assertSameAppearances(organization.locationTokens(for: [fixture.material]), fixture.receipt.after)
        XCTAssertTrue(manager.canUndo)
        XCTAssertFalse(manager.canRedo)
    }

    func testTwoRapidUndosAndRedosPreserveNativeHistoryOrder() async throws {
        let fixture = Fixture()
        let finalProject = UUID()
        let secondReceipt = WorkDeskLocationUndo(before: fixture.receipt.after,
            after: [fixture.material: [.init(materialID: fixture.material, location: .project(finalProject), position: nil)]])
        var snapshot = fixture.afterSnapshot
        snapshot.projects.append(.init(id: finalProject, title: "Second project"))
        snapshot.materialLocations = secondReceipt.after
        let store = DeferredRestoreStore(snapshot: snapshot)
        let organization = WorkDeskOrganization(fetch: { await store.snapshot }, apply: { try await store.apply($0) })
        await organization.reload()
        let controller = WorkDeskOrganizationUndoController()
        let manager = UndoManager()
        manager.groupsByEvent = false
        for receipt in [fixture.receipt, secondReceipt] {
            manager.beginUndoGrouping()
            controller.receive(receipt, organization: organization, manager: manager)
            manager.endUndoGrouping()
        }
        manager.undo()
        manager.undo()
        manager.redo()
        manager.redo()
        for expectedCount in 1...4 {
            try await waitUntil { await store.startedCount == expectedCount }
            XCTAssertTrue(controller.isApplying)
            await store.completeNext()
        }
        try await waitUntil { !controller.isApplying }
        XCTAssertNil(organization.errorMessage)
        assertSameAppearances(organization.locationTokens(for: [fixture.material]), secondReceipt.after)
        XCTAssertTrue(manager.canUndo)
        XCTAssertFalse(manager.canRedo)
    }

    func testAutomaticFirstLayoutAfterFilingKeepsNativeRedo() async throws {
        let fixture = Fixture()
        var seeded = fixture.afterSnapshot
        seeded.materialLocations[fixture.material]?[0].position = .init(x: 300, y: 180)
        seeded.materialLocations[fixture.material]?[0].positionWasSeeded = true
        seeded.materialLocations[fixture.material]?[0].updatedAt = Date()
        let store = DeferredRestoreStore(snapshot: seeded)
        let organization = WorkDeskOrganization(fetch: { await store.snapshot }, apply: { try await store.apply($0) })
        await organization.reload()
        let controller = WorkDeskOrganizationUndoController()
        let manager = UndoManager()
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        controller.receive(fixture.receipt, organization: organization, manager: manager)
        manager.endUndoGrouping()
        manager.undo()
        try await waitUntil { await store.startedCount == 1 }
        await store.completeNext()
        try await waitUntil { !controller.isApplying }
        XCTAssertNil(organization.errorMessage)
        assertSameAppearances(organization.locationTokens(for: [fixture.material]), fixture.receipt.before)
        manager.redo()
        try await waitUntil { await store.startedCount == 2 }
        await store.completeNext()
        try await waitUntil { !controller.isApplying }
        XCTAssertNil(organization.errorMessage)
        assertSameAppearances(organization.locationTokens(for: [fixture.material]), seeded.materialLocations)
    }

    func testSeededIntermediateLocationsRemainInTheTrustedMultiLevelUndoChain() async throws {
        let fixture = Fixture()
        var seededFirst = fixture.receipt.after
        seededFirst[fixture.material]?[0].position = .init(x: 300, y: 180)
        seededFirst[fixture.material]?[0].positionWasSeeded = true
        seededFirst[fixture.material]?[0].updatedAt = Date()
        let secondProject = UUID()
        let secondReceipt = WorkDeskLocationUndo(before: seededFirst,
            after: [fixture.material: [.init(materialID: fixture.material, location: .project(secondProject), position: nil)]])
        var snapshot = fixture.afterSnapshot
        snapshot.projects.append(.init(id: secondProject, title: "Second project"))
        snapshot.materialLocations = secondReceipt.after
        snapshot.materialLocations[fixture.material]?[0].position = .init(x: 500, y: 280)
        snapshot.materialLocations[fixture.material]?[0].positionWasSeeded = true
        snapshot.materialLocations[fixture.material]?[0].updatedAt = Date()
        let store = DeferredRestoreStore(snapshot: snapshot)
        let organization = WorkDeskOrganization(fetch: { await store.snapshot }, apply: { try await store.apply($0) })
        await organization.reload()
        let controller = WorkDeskOrganizationUndoController()
        let manager = UndoManager()
        manager.groupsByEvent = false
        for receipt in [fixture.receipt, secondReceipt] {
            manager.beginUndoGrouping()
            controller.receive(receipt, organization: organization, manager: manager)
            manager.endUndoGrouping()
        }
        manager.undo()
        manager.undo()
        manager.redo()
        manager.redo()
        for expectedCount in 1...4 {
            try await waitUntil { await store.startedCount == expectedCount }
            XCTAssertTrue(controller.isApplying)
            await store.completeNext()
        }
        try await waitUntil { !controller.isApplying }
        XCTAssertNil(organization.errorMessage)
        assertSameAppearances(organization.locationTokens(for: [fixture.material]), snapshot.materialLocations)
    }

    func testTrustedUndoRebasingStillRefusesAnOutsideEditWithTheSameAppearance() async throws {
        let fixture = Fixture()
        let secondProject = UUID()
        let secondReceipt = WorkDeskLocationUndo(before: fixture.receipt.after,
            after: [fixture.material: [.init(materialID: fixture.material, location: .project(secondProject), position: nil)]])
        var snapshot = fixture.afterSnapshot
        snapshot.projects.append(.init(id: secondProject, title: "Second project"))
        snapshot.materialLocations = secondReceipt.after
        let store = DeferredRestoreStore(snapshot: snapshot)
        let organization = WorkDeskOrganization(fetch: { await store.snapshot }, apply: { try await store.apply($0) })
        await organization.reload()
        let controller = WorkDeskOrganizationUndoController()
        let manager = UndoManager()
        manager.groupsByEvent = false
        for receipt in [fixture.receipt, secondReceipt] {
            manager.beginUndoGrouping()
            controller.receive(receipt, organization: organization, manager: manager)
            manager.endUndoGrouping()
        }
        manager.undo()
        try await waitUntil { await store.startedCount == 1 }
        await store.completeNext()
        try await waitUntil { !controller.isApplying }
        // Another writer can leave the same appearance with a newer revision.
        // Only our confirmed restoration belongs to the native undo chain.
        await store.replaceRevision(materialID: fixture.material)
        await organization.reload()
        let outsideEdit = organization.locationTokens(for: [fixture.material])
        manager.undo()
        try await waitUntil { await store.startedCount == 2 }
        await store.completeNext()
        try await waitUntil { !controller.isApplying }
        XCTAssertNotNil(organization.errorMessage)
        XCTAssertEqual(organization.locationTokens(for: [fixture.material]), outsideEdit)
        assertSameAppearances(outsideEdit, fixture.receipt.after)
    }

    func testFailedUndoFollowedByImmediateRedoCannotLeaveControllerBusy() async throws {
        let fixture = Fixture()
        let store = DeferredRestoreStore(snapshot: fixture.afterSnapshot, failNext: true)
        let organization = WorkDeskOrganization(fetch: { await store.snapshot }, apply: { try await store.apply($0) })
        await organization.reload()
        let controller = WorkDeskOrganizationUndoController()
        let manager = UndoManager()
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        controller.receive(fixture.receipt, organization: organization, manager: manager)
        manager.endUndoGrouping()
        manager.undo()
        manager.redo()
        try await waitUntil { await store.startedCount == 1 }
        await store.completeNext()
        try await waitUntil { !controller.isApplying }
        assertSameAppearances(organization.locationTokens(for: [fixture.material]), fixture.receipt.after)
        XCTAssertNotNil(organization.errorMessage)
        let restoreAttempts = await store.startedCount
        XCTAssertEqual(restoreAttempts, 1, "A failed inverse cannot supply a second restoration.")
    }

    func testDuplicateReceiptDoesNotRegisterAnotherUndoOperation() async throws {
        let fixture = Fixture()
        let store = DeferredRestoreStore(snapshot: fixture.afterSnapshot)
        let organization = WorkDeskOrganization(fetch: { await store.snapshot }, apply: { try await store.apply($0) })
        await organization.reload()
        let controller = WorkDeskOrganizationUndoController()
        let manager = UndoManager()
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        controller.receive(fixture.receipt, organization: organization, manager: manager)
        controller.receive(fixture.receipt, organization: organization, manager: manager)
        manager.endUndoGrouping()
        manager.undo()
        try await waitUntil { await store.startedCount == 1 }
        await store.completeNext()
        try await waitUntil { !controller.isApplying }
        let restoreAttempts = await store.startedCount
        XCTAssertEqual(restoreAttempts, 1)
        XCTAssertFalse(manager.canUndo)
    }

    func testRestorationReceiptNeverRegistersASecondUserAction() async throws {
        let fixture = Fixture()
        let store = DeferredRestoreStore(snapshot: fixture.afterSnapshot)
        let organization = WorkDeskOrganization(fetch: { await store.snapshot }, apply: { try await store.apply($0) })
        await organization.reload()
        let controller = WorkDeskOrganizationUndoController()
        let manager = UndoManager()
        manager.groupsByEvent = false
        var restored = fixture.receipt
        restored.isRestoration = true
        controller.receive(restored, organization: organization, manager: manager)
        XCTAssertFalse(manager.canUndo)
        XCTAssertFalse(controller.showsUndo)
        XCTAssertNil(controller.receipt)
    }

    func testToastUndoPreservesLaterEditorHistoryAndRetiresItsOwnEntry() async throws {
        let fixture = Fixture()
        let store = DeferredRestoreStore(snapshot: fixture.afterSnapshot)
        let organization = WorkDeskOrganization(fetch: { await store.snapshot }, apply: { try await store.apply($0) })
        await organization.reload()
        let controller = WorkDeskOrganizationUndoController()
        let manager = UndoManager()
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        controller.receive(fixture.receipt, organization: organization, manager: manager)
        manager.endUndoGrouping()
        let editor = EditorTarget()
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: editor) { $0.restoreCount += 1 }
        manager.setActionName("Edit text")
        manager.endUndoGrouping()
        let undo = Task { await controller.undoLatest(organization: organization, manager: manager) }
        try await waitUntil { await store.startedCount == 1 }
        XCTAssertEqual(editor.restoreCount, 0)
        await store.completeNext()
        await undo.value
        assertSameAppearances(organization.locationTokens(for: [fixture.material]), fixture.receipt.before)
        XCTAssertEqual(manager.undoActionName, "Edit text")
        manager.undo()
        XCTAssertEqual(editor.restoreCount, 1)
        XCTAssertFalse(manager.canUndo, "The obsolete filing entry cannot replay after direct toast restoration.")
    }

    func testToastUsesNativeHistoryWhenFilingIsTheLatestAction() async throws {
        let fixture = Fixture()
        let store = DeferredRestoreStore(snapshot: fixture.afterSnapshot)
        let organization = WorkDeskOrganization(fetch: { await store.snapshot }, apply: { try await store.apply($0) })
        await organization.reload()
        let controller = WorkDeskOrganizationUndoController()
        let manager = UndoManager()
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        controller.receive(fixture.receipt, organization: organization, manager: manager)
        manager.endUndoGrouping()
        await controller.undoLatest(organization: organization, manager: manager)
        XCTAssertTrue(manager.canRedo)
        try await waitUntil { await store.startedCount == 1 }
        await store.completeNext()
        try await waitUntil { !controller.isApplying }
        assertSameAppearances(organization.locationTokens(for: [fixture.material]), fixture.receipt.before)
        XCTAssertTrue(manager.canRedo, "Touch Undo preserves the same Redo as the keyboard command.")
    }

    private func assertSameAppearances(_ actual: WorkDeskLocationTokens, _ expected: WorkDeskLocationTokens,
                                       file: StaticString = #filePath, line: UInt = #line) {
        struct Appearance: Equatable {
            let position: WorkDeskPoint?
            let rank: Double?
        }
        func appearances(_ tokens: WorkDeskLocationTokens) -> [UUID: [WorkDeskLocation: Appearance]] {
            tokens.mapValues { records in
                Dictionary(uniqueKeysWithValues: records.map { ($0.location, Appearance(position: $0.position, rank: $0.sortRank)) })
            }
        }
        XCTAssertEqual(appearances(actual), appearances(expected), file: file, line: line)
    }

    private final class EditorTarget { var restoreCount = 0 }

    private func waitUntil(_ condition: @escaping @MainActor () async -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the controlled restore", file: file, line: line)
        throw WorkDeskStoreError.materialMoved
    }

    private struct Fixture {
        let material: UUID
        let project: UUID
        let receipt: WorkDeskLocationUndo
        init() {
            material = UUID()
            project = UUID()
            receipt = .init(before: [material: [.init(materialID: material, location: .home, position: nil)]],
                            after: [material: [.init(materialID: material, location: .project(project), position: nil)]])
        }
        var afterSnapshot: WorkDeskOrganizationSnapshot {
            .init(projects: [.init(id: project, title: "Project")], materialLocations: receipt.after)
        }
    }

    private actor DeferredRestoreStore {
        private(set) var snapshot: WorkDeskOrganizationSnapshot
        private(set) var startedCount = 0
        private var completions: [CheckedContinuation<Void, Never>] = []
        private var failNext: Bool

        init(snapshot: WorkDeskOrganizationSnapshot, failNext: Bool = false) {
            self.snapshot = snapshot
            self.failNext = failNext
        }

        func apply(_ mutation: WorkDeskMutation) async throws -> WorkDeskOrganizationSnapshot {
            guard case .restoreLocations(let restored, let expected) = mutation else {
                throw WorkDeskStoreError.identifierCollision
            }
            startedCount += 1
            await withCheckedContinuation { completions.append($0) }
            if failNext {
                failNext = false
                throw WorkDeskStoreError.materialMoved
            }
            for (id, tokens) in expected {
                let current = snapshot.locations(for: id)
                guard current.count == tokens.count,
                      current.allSatisfy({ record in tokens.contains { record.matchesForUndo($0) } }) else {
                    throw WorkDeskStoreError.materialMoved
                }
            }
            let before = Dictionary(uniqueKeysWithValues: restored.keys.map { ($0, snapshot.locations(for: $0)) })
            for (id, tokens) in restored {
                // Production restoration writes fresh opaque revisions; copying
                // old tokens here would conceal failures in multi-level Undo.
                snapshot.materialLocations[id] = tokens.map { record in
                    var committed = record
                    committed.updatedAt = Date()
                    committed.revision = UUID()
                    return committed
                }
            }
            let after = Dictionary(uniqueKeysWithValues: restored.keys.map { ($0, snapshot.locations(for: $0)) })
            snapshot.locationUndo = .init(before: before, after: after, isRestoration: true)
            return snapshot
        }

        func replaceRevision(materialID: UUID) {
            snapshot.materialLocations[materialID] = snapshot.locations(for: materialID).map { record in
                var changed = record
                changed.updatedAt = Date()
                changed.revision = UUID()
                return changed
            }
            snapshot.locationUndo = nil
        }

        func completeNext() {
            guard !completions.isEmpty else { return }
            completions.removeFirst().resume()
        }
    }
}
