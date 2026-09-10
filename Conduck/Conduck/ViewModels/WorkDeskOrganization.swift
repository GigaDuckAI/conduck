// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkDeskOrganization.swift
//
// Observable organization beside the existing capture ViewModel. Mutations
// are queued in gesture order and publish only committed snapshots. A reload
// begun before a mutation cannot overwrite its result; reloads during a write
// are deferred until the last queued intent completes. All store dependencies
// can be replaced with isolated in-memory operations in tests.

import Foundation
import Observation

@MainActor @Observable
final class WorkDeskOrganization {
    private(set) var projects: [WorkDeskProjectRecord] = []
    private(set) var placements: [UUID: WorkDeskPlacementRecord] = [:]
    private(set) var isSaving = false
    var errorMessage: String?

    @ObservationIgnored private let fetch: @Sendable () async throws -> WorkDeskOrganizationSnapshot
    @ObservationIgnored private let apply: @Sendable (WorkDeskMutation) async throws -> WorkDeskOrganizationSnapshot
    @ObservationIgnored private var mutationTail: Task<Bool, Never>?
    @ObservationIgnored private var pendingMutationCount = 0
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var reloadPending = false

    init(store: ConversationStore = .shared) {
        fetch = { try await store.fetchWorkDeskOrganization() }
        apply = { try await store.applyWorkDeskMutation($0) }
    }

    /// Isolated behavior seam for delayed-load and failure tests. Production
    /// uses the store initializer so no alternate persistent store is exposed.
    init(
        fetch: @escaping @Sendable () async throws -> WorkDeskOrganizationSnapshot,
        apply: @escaping @Sendable (WorkDeskMutation) async throws -> WorkDeskOrganizationSnapshot
    ) {
        self.fetch = fetch
        self.apply = apply
    }

    func projectID(for materialID: UUID) -> UUID? {
        guard let id = placements[materialID]?.projectID,
              projects.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    func reload() async {
        guard pendingMutationCount == 0 else {
            reloadPending = true
            return
        }
        generation &+= 1
        let requestedGeneration = generation
        do {
            let snapshot = try await fetch()
            guard requestedGeneration == generation, pendingMutationCount == 0 else { return }
            publish(snapshot)
        } catch {
            guard requestedGeneration == generation else { return }
            report(error)
        }
    }

    @discardableResult
    func createProject(
        title: String, brief: String = "", materialIDs: [UUID] = [], position: WorkDeskPoint? = nil
    ) async -> UUID? {
        let project = WorkDeskProjectRecord(title: title, brief: brief, position: position)
        let saved = await enqueue(.createProject(project, materialIDs: materialIDs))
        return saved ? project.id : nil
    }

    @discardableResult
    func updateProject(id: UUID, title: String, brief: String, preferredGatewayRef: String?, expectedUpdatedAt: Date? = nil) async -> Bool {
        await enqueue(.updateProject(id: id, title: title, brief: brief, preferredGatewayRef: preferredGatewayRef,
                                     expectedUpdatedAt: expectedUpdatedAt))
    }

    @discardableResult
    func deleteProject(id: UUID) async -> Bool { await enqueue(.deleteProject(id: id)) }

    @discardableResult
    func assign(materialIDs: [UUID], to projectID: UUID?) async -> Bool {
        await enqueue(.assign(materialIDs: materialIDs, projectID: projectID))
    }

    @discardableResult
    func move(materialID: UUID, to position: WorkDeskPoint?) async -> Bool {
        await enqueue(.moveMaterial(id: materialID, position: position))
    }

    @discardableResult
    func moveProject(id: UUID, to position: WorkDeskPoint?) async -> Bool {
        await enqueue(.moveProject(id: id, position: position))
    }

    @discardableResult
    func setPinned(_ isPinned: Bool, materialID: UUID) async -> Bool {
        await enqueue(.pinMaterial(id: materialID, isPinned: isPinned))
    }

    @discardableResult
    func setProjectPinned(_ isPinned: Bool, id: UUID) async -> Bool {
        await enqueue(.pinProject(id: id, isPinned: isPinned))
    }

    @discardableResult
    func seedPositions(materials: [WorkDeskPositionSeed], projects: [UUID: WorkDeskPoint] = [:]) async -> Bool {
        guard !materials.isEmpty || !projects.isEmpty else { return true }
        return await enqueue(.seedPositions(materials: materials, projects: projects))
    }

    private func enqueue(_ mutation: WorkDeskMutation) async -> Bool {
        generation &+= 1
        pendingMutationCount += 1
        isSaving = true
        let prior = mutationTail
        let task = Task { @MainActor [self] in
            _ = await prior?.value
            let saved: Bool
            do {
                let snapshot = try await apply(mutation)
                publish(snapshot)
                errorMessage = nil
                saved = true
            } catch {
                report(error)
                saved = false
            }
            pendingMutationCount -= 1
            isSaving = pendingMutationCount > 0
            if pendingMutationCount == 0 {
                mutationTail = nil
                if reloadPending {
                    reloadPending = false
                    await reload()
                }
            }
            return saved
        }
        mutationTail = task
        return await task.value
    }

    private func publish(_ snapshot: WorkDeskOrganizationSnapshot) {
        projects = snapshot.projects
        placements = snapshot.placements
    }

    private func report(_ error: Error) {
        errorMessage = (error as? WorkDeskStoreError)?.localizedDescription ?? String(
            localized: "workdesk.error.save",
            defaultValue: "The desk couldn’t save that change. Try again."
        )
    }
}
