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
    var activeProjects: [WorkDeskProjectRecord] { projects.filter { !$0.isArchived } }
    var archivedProjects: [WorkDeskProjectRecord] { projects.filter(\.isArchived) }
    var hasProAccess: Bool { proAccessProvider().hasProAccess }
    var hasExpiredSubscription: Bool { proAccessProvider().hasExpiredSubscription }
    var hasLoadedProAccess: Bool { accessLoadedProvider() }
    var canPresentFreeProjectSelection: Bool { hasLoadedProAccess && requiresFreeProjectSelection }
    var canCreateProject: Bool { hasProAccess || activeProjects.count < Constants.maxActiveWorkProjects }
    var requiresFreeProjectSelection: Bool {
        let access = proAccessProvider()
        return !access.hasProAccess && activeProjects.count > Constants.maxActiveWorkProjects
    }
    var availableProjectDestinations: [WorkDeskProjectRecord] {
        requiresFreeProjectSelection ? [] : activeProjects
    }
    var projectLimitRequested = false
    var projectSelectionRequested = false
    private(set) var placements: [UUID: WorkDeskPlacementRecord] = [:]
    private(set) var materialLocations: WorkDeskLocationTokens = [:]
    private(set) var lastLocationUndo: WorkDeskLocationUndo?
    private(set) var isSaving = false
    var errorMessage: String?
    private var projectsByID: [UUID: WorkDeskProjectRecord] = [:]

    @ObservationIgnored private let fetch: @Sendable () async throws -> WorkDeskOrganizationSnapshot
    @ObservationIgnored private let apply: @Sendable (WorkDeskMutation) async throws -> WorkDeskOrganizationSnapshot
    @ObservationIgnored private let reviewDeletion: @Sendable (UUID) async throws -> WorkDeskProjectDeletionReview
    @ObservationIgnored private let proAccessProvider: @MainActor () -> ProAccessSnapshot
    @ObservationIgnored private let accessLoadedProvider: @MainActor () -> Bool
    @ObservationIgnored private let awaitAccess: @MainActor () async -> Void
    @ObservationIgnored private var mutationTail: Task<Bool, Never>?
    @ObservationIgnored private var pendingMutationCount = 0
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var reloadPending = false

    init(store: ConversationStore = .shared, proAccessProvider: (@MainActor () -> ProAccessSnapshot)? = nil) {
        if let proAccessProvider {
            self.proAccessProvider = proAccessProvider
            accessLoadedProvider = { true }
            awaitAccess = { }
        } else if store.usesSharedProAccess {
            self.proAccessProvider = {
                .init(hasProAccess: ProSubscriptionStore.shared.hasProAccess,
                      hasExpiredSubscription: ProSubscriptionStore.shared.hasExpiredSubscription)
            }
            accessLoadedProvider = { ProSubscriptionStore.shared.hasLoadedAccess }
            awaitAccess = { await ProSubscriptionStore.shared.awaitInitialAccess() }
        } else {
            self.proAccessProvider = { store.proAccessProvider() }
            accessLoadedProvider = { true }
            awaitAccess = { }
        }
        fetch = { try await store.fetchWorkDeskOrganization() }
        apply = { try await store.applyWorkDeskMutation($0) }
        reviewDeletion = { try await store.reviewWorkDeskProjectDeletion(id: $0) }
    }

    /// Isolated behavior seam for delayed-load and failure tests. Production
    /// uses the store initializer so no alternate persistent store is exposed.
    init(
        fetch: @escaping @Sendable () async throws -> WorkDeskOrganizationSnapshot,
        apply: @escaping @Sendable (WorkDeskMutation) async throws -> WorkDeskOrganizationSnapshot,
        reviewDeletion: @escaping @Sendable (UUID) async throws -> WorkDeskProjectDeletionReview = { _ in throw WorkDeskStoreError.projectNotFound },
        proAccessProvider: @escaping @MainActor () -> ProAccessSnapshot = { .init() }
    ) {
        self.proAccessProvider = proAccessProvider
        accessLoadedProvider = { true }
        awaitAccess = { }
        self.fetch = fetch
        self.apply = apply
        self.reviewDeletion = reviewDeletion
    }

    func projectID(for materialID: UUID) -> UUID? {
        guard let id = placements[materialID]?.projectID,
              projectsByID[id] != nil else { return nil }
        return id
    }

    func project(id: UUID) -> WorkDeskProjectRecord? { projectsByID[id] }

    func requestProjectLimit() {
        errorMessage = nil
        projectLimitRequested = true
    }

    func awaitInitialProAccess() async { await awaitAccess() }

    @discardableResult
    func selectFreeProjects(keeping: Set<UUID>, expectedActiveProjectIDs: Set<UUID>) async -> Bool {
        await enqueue(.selectFreeProjects(keeping: keeping, expectedActiveProjectIDs: expectedActiveProjectIDs))
    }

    func locations(for materialID: UUID) -> [WorkDeskLocationRecord] {
        snapshot.locations(for: materialID)
    }

    func contains(materialID: UUID, at location: WorkDeskLocation) -> Bool {
        locations(for: materialID).contains { $0.location == location }
    }

    func locationTokens(for materialIDs: [UUID]) -> WorkDeskLocationTokens {
        Dictionary(uniqueKeysWithValues: Set(materialIDs).map { ($0, locations(for: $0)) })
    }

    /// Existing card rendering accepts one placement per material. Resolve only
    /// the requested location so a different project's coordinates never leak.
    func placements(at location: WorkDeskLocation) -> [UUID: WorkDeskPlacementRecord] {
        let ids = Set(placements.keys).union(materialLocations.keys)
        return ids.reduce(into: [:]) { result, id in
            guard let record = locations(for: id).first(where: { $0.location == location }) else { return }
            result[id] = .init(materialID: id, projectID: location.projectID, position: record.position,
                               homePosition: location == .home ? record.position : placements[id]?.homePosition,
                               isPinned: placements[id]?.isPinned ?? false, updatedAt: record.updatedAt)
        }
    }

    private var snapshot: WorkDeskOrganizationSnapshot {
        .init(projects: projects, placements: placements, materialLocations: materialLocations)
    }

    /// Count the visible capture groups in one pass. Project rails must not
    /// rescan every card and project for each row on a pointer-driven refresh.
    /// A missing project's cards belong to the loose desk, just as in the canvas.
    func materialCounts(in materials: [WorkboardMaterialSnapshot]) -> [UUID?: Int] {
        var counts: [UUID?: Int] = [:]
        for material in materials {
            for location in locations(for: material.id) { counts[location.location.projectID, default: 0] += 1 }
        }
        return counts
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
        await awaitInitialProAccess()
        let project = WorkDeskProjectRecord(title: title, brief: brief, position: position)
        let saved = await enqueue(.createProject(project, materialIDs: materialIDs))
        return saved ? project.id : nil
    }

    @discardableResult
    func createProject(title: String, brief: String = "", materialIDs: [UUID], position: WorkDeskPoint? = nil,
                       from source: WorkDeskLocation, expected: WorkDeskLocationTokens? = nil) async -> UUID? {
        await awaitInitialProAccess()
        let project = WorkDeskProjectRecord(title: title, brief: brief, position: position)
        let saved = await enqueue(.createProjectFrom(project, materialIDs: materialIDs, source: source, expected: expected))
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
    func setProjectArchived(_ isArchived: Bool, id: UUID) async -> Bool {
        if !isArchived { await awaitInitialProAccess() }
        return await enqueue(.archiveProject(id: id, isArchived: isArchived))
    }

    func reviewProjectDeletion(id: UUID) async -> WorkDeskProjectDeletionReview? {
        _ = await mutationTail?.value
        do {
            let review = try await reviewDeletion(id)
            errorMessage = nil
            return review
        } catch {
            report(error)
            return nil
        }
    }

    @discardableResult
    func deleteProject(review: WorkDeskProjectDeletionReview, deleteMaterials: Bool) async -> Bool {
        await enqueue(.deleteReviewedProject(review, deleteMaterials: deleteMaterials))
    }

    @discardableResult
    func assign(materialIDs: [UUID], to projectID: UUID?) async -> Bool {
        if projectID != nil { await awaitInitialProAccess() }
        return await enqueue(.assign(materialIDs: materialIDs, projectID: projectID))
    }

    @discardableResult
    func move(materialIDs: [UUID], from source: WorkDeskLocation, to destination: WorkDeskLocation,
              positions: [UUID: WorkDeskPoint] = [:], expected: WorkDeskLocationTokens? = nil) async -> Bool {
        if source != destination, destination.projectID != nil { await awaitInitialProAccess() }
        return await enqueue(.moveLocations(materialIDs: materialIDs, from: source, to: destination,
                                     positions: positions, expected: expected))
    }

    @discardableResult
    func add(materialIDs: [UUID], to destination: WorkDeskLocation, positions: [UUID: WorkDeskPoint] = [:],
             expected: WorkDeskLocationTokens? = nil) async -> Bool {
        if destination.projectID != nil { await awaitInitialProAccess() }
        return await enqueue(.addLocations(materialIDs: materialIDs, to: destination, positions: positions, expected: expected))
    }

    @discardableResult
    func remove(materialIDs: [UUID], from source: WorkDeskLocation,
                expected: WorkDeskLocationTokens? = nil) async -> Bool {
        await enqueue(.removeLocations(materialIDs: materialIDs, from: source, expected: expected))
    }

    @discardableResult
    func moveLocations(positions: [UUID: WorkDeskPoint], at location: WorkDeskLocation,
                       expected: WorkDeskLocationTokens? = nil) async -> Bool {
        await enqueue(.positionLocations(positions: positions, at: location, expected: expected))
    }

    @discardableResult
    func restoreLocations(_ saved: WorkDeskLocationTokens, expected: WorkDeskLocationTokens) async -> Bool {
        await awaitInitialProAccess()
        return await enqueue(.restoreLocations(saved, expected: expected))
    }

    @discardableResult
    func undo(_ change: WorkDeskLocationUndo) async -> Bool {
        await restoreLocations(change.before, expected: change.after)
    }

    func clearLastLocationUndo() { lastLocationUndo = nil }

    @discardableResult
    func reorder(materialID: UUID, relativeTo targetID: UUID, placement: WorkboardReorderPlacement,
                 at location: WorkDeskLocation, orderedMaterialIDs: [UUID],
                 expected: WorkDeskLocationTokens? = nil) async -> Bool {
        await enqueue(.reorderLocations(materialID: materialID, relativeTo: targetID, placement: placement,
                                         at: location, orderedMaterialIDs: orderedMaterialIDs,
                                         expected: expected ?? locationTokens(for: orderedMaterialIDs)))
    }

    @discardableResult
    func moveAndReorder(materialIDs: [UUID], from source: WorkDeskLocation, to destination: WorkDeskLocation,
                        relativeTo targetID: UUID, placement: WorkboardReorderPlacement,
                        orderedMaterialIDs: [UUID], expected: WorkDeskLocationTokens? = nil) async -> Bool {
        if source != destination, destination.projectID != nil { await awaitInitialProAccess() }
        return await enqueue(.moveAndReorderLocations(materialIDs: materialIDs, from: source, to: destination,
            relativeTo: targetID, placement: placement, orderedMaterialIDs: orderedMaterialIDs,
            expected: expected ?? locationTokens(for: materialIDs + orderedMaterialIDs)))
    }

    @discardableResult
    func move(materialID: UUID, to position: WorkDeskPoint?) async -> Bool {
        await enqueue(.moveMaterial(id: materialID, position: position))
    }

    @discardableResult
    func moveMaterials(positions: [UUID: WorkDeskPoint], expectedProjectID: UUID?) async -> Bool {
        guard !positions.isEmpty else { return true }
        return await enqueue(.moveMaterials(positions: positions, expectedProjectID: expectedProjectID))
    }

    @discardableResult
    func moveHomeMaterials(_ moves: [WorkDeskPositionSeed]) async -> Bool {
        guard !moves.isEmpty else { return true }
        return await enqueue(.moveHomeMaterials(moves))
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
                errorMessage = nil
                // Publishing can report a local draft cleanup failure after
                // the organization mutation succeeds. Keep that remedy visible.
                publish(snapshot)
                switch mutation {
                case .moveLocations, .addLocations, .removeLocations, .positionLocations, .restoreLocations, .reorderLocations, .moveAndReorderLocations:
                    lastLocationUndo = snapshot.locationUndo
                default: break
                }
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
        // Only tombstones prune process-wide preferences. Another window may
        // create a project while this instance awaits its snapshot, so absence
        // from the returned live list is not evidence of deletion. Successful
        // loads and mutations carry local/synced tombstones; navigation and
        // failed reads never write, and unseen deletions still reclaim slots.
        // The process-wide pruner handles each ID once across all windows.
        WorkboardLayoutMode.pruneProjectPreferences(deletedProjectIDs: snapshot.deletedProjectIDs)
        // Retry local request cleanup on every confirmed tombstone snapshot.
        // The preference pruner itself deliberately runs once per project.
        WorkDeskWorkspaceState.pruneProjectSessions(deletedProjectIDs: snapshot.deletedProjectIDs)
        // A position seed often finds that all its slots are already saved.
        // Publishing identical arrays still invalidates the whole desk's views.
        if projects != snapshot.projects {
            projects = snapshot.projects
            projectsByID = snapshot.projects.reduce(into: [:]) { $0[$1.id] = $1 }
        }
        if placements != snapshot.placements { placements = snapshot.placements }
        if materialLocations != snapshot.materialLocations { materialLocations = snapshot.materialLocations }
    }

    private func report(_ error: Error) {
        if error as? WorkDeskStoreError == .activeProjectLimitReached {
            requestProjectLimit()
            return
        }
        if error as? WorkDeskStoreError == .projectSelectionRequired {
            errorMessage = nil
            projectSelectionRequested = true
            return
        }
        errorMessage = (error as? WorkDeskStoreError)?.localizedDescription ?? String(
            localized: "workdesk.error.save",
            defaultValue: "The desk couldn’t save that change. Try again."
        )
    }
}
