// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationStore+WorkDesk.swift
//
// Private CloudKit metadata for spatial organization of the canonical capture
// desk. Transactions never change a WorkMaterial, WorkItem or payload. UUID
// links tolerate imports arriving in either order; a project tombstone wins
// over every live duplicate so a late placement cannot resurrect a deletion.
// Each intent updates one item's fields, not a JSON copy of the entire desk.
// Multi-card moves validate all identities and their original scope before any
// row is inserted or normalized, then save the positions as one transaction.
// Initial capture placement reuses these metadata rows inside the material's
// own transaction; it never adds another owner or another publication step.

import Foundation
import CoreData

extension ConversationStore {
    /// Called only after the canonical writer proves the material is new. The
    /// same save publishes its placement, so process death cannot leave an
    /// otherwise successful capture waiting for a separate filing operation.
    /// A placement imported ahead of its material is already user organization;
    /// preserve it just as a replay preserves the placement of an existing card.
    nonisolated static func placeNewDeskCapture(
        _ materialID: UUID, projectID: UUID, in context: NSManagedObjectContext
    ) throws {
        let placements = try deskRows("WorkDeskPlacement", key: "materialID", id: materialID, in: context)
        guard placements.isEmpty else { return }
        _ = try liveDeskProjectRows(projectID, in: context)
        try assignDeskMaterials([materialID], projectID: projectID, in: context)
    }

    nonisolated static func validateProjectConversationDestination(
        _ projectID: UUID, in context: NSManagedObjectContext
    ) throws {
        _ = try liveDeskProjectRows(projectID, in: context)
    }

    func fetchWorkDeskOrganization() async throws -> WorkDeskOrganizationSnapshot {
        try await ensureLoaded()
        let context = newReadContext()
        return try await context.perform { try Self.deskOrganization(in: context) }
    }

    /// A fallback inserts no placement. A successfully filed capture retains
    /// its placement row even when deletion clears its membership locally or
    /// a synced project tombstone makes that membership resolve to All materials.
    /// Any later organization also wins over reconstructing a capture receipt.
    /// Read only these two identities, including their CloudKit duplicates;
    /// resolving the entire desk would make every stale voice retry expensive.
    func isUnfiledWorkCaptureFallback(materialID: UUID, projectID: UUID) async throws -> Bool {
        try await ensureLoaded()
        let context = newReadContext()
        return try await context.perform {
            let placements = try Self.deskRows(
                "WorkDeskPlacement", key: "materialID", id: materialID, in: context
            )
            guard placements.isEmpty else { return false }
            return try Self.resolvedDeskProjectID(projectID, in: context) == nil
        }
    }

    @discardableResult
    func applyWorkDeskMutation(_ mutation: WorkDeskMutation) async throws -> WorkDeskOrganizationSnapshot {
        await acquireWorkDeskMutation()
        defer { releaseWorkDeskMutation() }
        try Task.checkCancellation()
        try await ensureLoaded()
        let context = newWriteContext()
        let (snapshot, changed) = try await context.perform {
            try Self.applyDeskMutation(mutation, in: context)
            let changed = context.hasChanges
            if changed { try context.save() }
            return (try Self.deskOrganization(in: context), changed)
        }
        if changed { await postDidChange() }
        return snapshot
    }

    private func acquireWorkDeskMutation() async {
        if !workDeskMutationInProgress {
            workDeskMutationInProgress = true
            return
        }
        await withCheckedContinuation { workDeskMutationWaiters.append($0) }
    }

    private func releaseWorkDeskMutation() {
        if workDeskMutationWaiters.isEmpty { workDeskMutationInProgress = false }
        else { workDeskMutationWaiters.removeFirst().resume() }
    }

    private nonisolated static func applyDeskMutation(
        _ mutation: WorkDeskMutation, in context: NSManagedObjectContext
    ) throws {
        switch mutation {
        case let .createProject(project, materialIDs):
            try validateDeskText(title: project.title, brief: project.brief)
            try requireDeskMaterials(materialIDs, in: context)
            guard try deskRows("WorkDeskProject", key: "id", id: project.id, in: context).isEmpty else {
                throw WorkDeskStoreError.identifierCollision
            }
            let row = NSEntityDescription.insertNewObject(forEntityName: "WorkDeskProject", into: context)
            row.setValue(project.id, forKey: "id")
            row.setValue(project.title.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "title")
            row.setValue(project.brief, forKey: "brief")
            row.setValue(project.preferredGatewayRef, forKey: "preferredGatewayRef")
            row.setValue(project.isPinned, forKey: "isPinned")
            row.setValue(project.createdAt, forKey: "createdAt")
            row.setValue(Date(), forKey: "updatedAt")
            setDeskPoint(project.position, on: row)
            try assignDeskMaterials(materialIDs, projectID: project.id, in: context)
        case let .updateProject(id, title, brief, preferredGatewayRef, expectedUpdatedAt):
            try validateDeskText(title: title, brief: brief)
            let rows = try liveDeskProjectRows(id, in: context)
            if let expectedUpdatedAt,
               rows.first?.value(forKey: "updatedAt") as? Date != expectedUpdatedAt {
                throw WorkDeskStoreError.staleProject
            }
            editDeskRows(rows) { row in
                row.setValue(title.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "title")
                row.setValue(brief, forKey: "brief")
                row.setValue(preferredGatewayRef, forKey: "preferredGatewayRef")
            }
        case let .deleteProject(id):
            let rows = try deskRows("WorkDeskProject", key: "id", id: id, in: context)
            guard !rows.isEmpty else { throw WorkDeskStoreError.projectNotFound }
            editDeskRows(rows) { row in
                row.setValue(row.value(forKey: "deletedAt") ?? Date(), forKey: "deletedAt")
                // Keep only identity and dates. Deleted projects do not retain
                // the person's brief or a destination they no longer need.
                for key in ["title", "brief", "preferredGatewayRef", "positionX", "positionY", "isPinned"] {
                    row.setValue(nil, forKey: key)
                }
            }
            let request = NSFetchRequest<NSManagedObject>(entityName: "WorkDeskPlacement")
            request.predicate = NSPredicate(format: "projectID == %@", id as CVarArg)
            let affectedIDs = Set(try context.fetch(request).compactMap { $0.value(forKey: "materialID") as? UUID })
            for materialID in affectedIDs {
                // An older duplicate may still name this project after the
                // canonical placement moved elsewhere. Resolve the logical
                // placement before clearing anything, or deleting the old
                // project would erase the person's newer organization.
                let placements = try deskPlacementRows(materialID, in: context)
                editDeskRows(placements) { row in
                    if row.value(forKey: "projectID") as? UUID == id {
                        row.setValue(nil, forKey: "projectID")
                        setDeskPoint(nil, on: row)
                    }
                }
            }
        case let .assign(materialIDs, projectID):
            if let projectID { _ = try liveDeskProjectRows(projectID, in: context) }
            try requireDeskMaterials(materialIDs, in: context)
            try assignDeskMaterials(materialIDs, projectID: projectID, in: context)
        case let .moveMaterial(id, position):
            try requireDeskMaterials([id], in: context)
            let rows = try deskPlacementRows(id, in: context)
            let projectID = rows.first?.value(forKey: "projectID") as? UUID
            let resolvedProjectID = try resolvedDeskProjectID(projectID, in: context)
            let unresolved = projectID != nil && resolvedProjectID == nil
            editDeskRows(rows) { row in
                // A missing/deleted project is displayed as unfiled. An
                // explicit drag there adopts that visible state; retaining
                // its old membership would suppress the new coordinates.
                if unresolved { row.setValue(nil, forKey: "projectID") }
                setDeskPoint(position, on: row)
            }
        case let .moveMaterials(positions, expectedProjectID):
            guard !positions.isEmpty else { return }
            if let expectedProjectID,
               try resolvedDeskProjectID(expectedProjectID, in: context) == nil {
                throw WorkDeskStoreError.projectNotFound
            }
            let moves = positions.sorted { $0.key.uuidString < $1.key.uuidString }
            try requireDeskMaterials(moves.map(\.key), in: context)
            var clearUnresolvedMembership: Set<UUID> = []
            // Read without deskPlacementRows/liveDeskProjectRows: those helpers
            // normalize duplicates and may insert. No row may change until all
            // selected identities and memberships have passed this validation.
            for (id, _) in moves {
                let rows = try deskRows("WorkDeskPlacement", key: "materialID", id: id, in: context)
                let storedProjectID = rows.first?.value(forKey: "projectID") as? UUID
                let resolvedProjectID = try resolvedDeskProjectID(storedProjectID, in: context)
                guard resolvedProjectID == expectedProjectID else { throw WorkDeskStoreError.materialMoved }
                if storedProjectID != nil && resolvedProjectID == nil {
                    clearUnresolvedMembership.insert(id)
                }
            }
            for (id, position) in moves {
                let rows = try deskPlacementRows(id, in: context)
                editDeskRows(rows) { row in
                    if clearUnresolvedMembership.contains(id) { row.setValue(nil, forKey: "projectID") }
                    setDeskPoint(position, on: row)
                }
            }
        case let .moveHomeMaterials(moves):
            guard !moves.isEmpty else { return }
            try requireDeskMaterials(moves.map(\.materialID), in: context)
            for move in moves {
                let rows = try deskRows("WorkDeskPlacement", key: "materialID", id: move.materialID, in: context)
                let storedProjectID = rows.first?.value(forKey: "projectID") as? UUID
                guard try resolvedDeskProjectID(storedProjectID, in: context) == move.projectID else {
                    throw WorkDeskStoreError.materialMoved
                }
            }
            for move in moves {
                let rows = try deskPlacementRows(move.materialID, in: context)
                editDeskRows(rows) { setHomePoint(move.position, on: $0) }
            }
        case let .pinMaterial(id, isPinned):
            try requireDeskMaterials([id], in: context)
            let rows = try deskPlacementRows(id, in: context)
            editDeskRows(rows) { $0.setValue(isPinned, forKey: "isPinned") }
        case let .moveProject(id, position):
            let rows = try liveDeskProjectRows(id, in: context)
            editDeskRows(rows) { setDeskPoint(position, on: $0) }
        case let .pinProject(id, isPinned):
            let rows = try liveDeskProjectRows(id, in: context)
            editDeskRows(rows) { $0.setValue(isPinned, forKey: "isPinned") }
        case let .seedPositions(materials, projects):
            for seed in materials {
                // A layout pass is disposable. A removed card or a partially
                // arrived owner skips its slot rather than failing the rest
                // of the batch or inventing a missing capture.
                do { try requireDeskMaterials([seed.materialID], in: context) }
                catch WorkDeskStoreError.materialNotFound { continue }
                if seed.isHome {
                    let existing = try deskRows("WorkDeskPlacement", key: "materialID", id: seed.materialID, in: context)
                    let storedProjectID = existing.first?.value(forKey: "projectID") as? UUID
                    guard try resolvedDeskProjectID(storedProjectID, in: context) == seed.projectID else { continue }
                    if let row = existing.first,
                       homePoint(on: row) != nil || (storedProjectID == nil && deskPoint(on: row) != nil) { continue }
                    let rows = try deskPlacementRows(seed.materialID, in: context)
                    editDeskRows(rows) { setHomePoint(seed.position, on: $0) }
                    continue
                }
                if let projectID = seed.projectID {
                    do { _ = try liveDeskProjectRows(projectID, in: context) }
                    catch WorkDeskStoreError.projectNotFound { continue }
                }
                let existing = try deskRows("WorkDeskPlacement", key: "materialID", id: seed.materialID, in: context)
                var clearDeletedMembership = false
                if let row = existing.first {
                    let storedProjectID = row.value(forKey: "projectID") as? UUID
                    if let storedProjectID, seed.projectID == nil {
                        let projectRows = try deskRows("WorkDeskProject", key: "id", id: storedProjectID, in: context)
                        clearDeletedMembership = projectRows.contains { $0.value(forKey: "deletedAt") != nil }
                    }
                    guard storedProjectID == seed.projectID || clearDeletedMembership,
                          deskPoint(on: row) == nil || clearDeletedMembership else { continue }
                } else if seed.projectID != nil {
                    // Only an assignment may create membership. A seed that
                    // predates that assignment must wait for the row itself.
                    continue
                }
                let rows = try deskPlacementRows(seed.materialID, in: context)
                editDeskRows(rows) { row in
                    if clearDeletedMembership { row.setValue(nil, forKey: "projectID") }
                    setDeskPoint(seed.position, on: row)
                }
            }
            for (id, position) in projects {
                let rows: [NSManagedObject]
                do { rows = try liveDeskProjectRows(id, in: context) }
                catch WorkDeskStoreError.projectNotFound { continue }
                guard let row = rows.first, deskPoint(on: row) == nil else { continue }
                editDeskRows(rows) { setDeskPoint(position, on: $0) }
            }
        }
    }

    private nonisolated static func validateDeskText(title: String, brief: String) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkDeskStoreError.invalidTitle
        }
        guard title.count <= WorkItemContentLimits.maximumFieldCharacters,
              brief.count <= WorkItemContentLimits.maximumFieldCharacters else {
            throw WorkDeskStoreError.contentTooLong
        }
    }

    private nonisolated static func requireDeskMaterials(
        _ ids: [UUID], in context: NSManagedObjectContext
    ) throws {
        guard !ids.isEmpty else { return }
        let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
        request.predicate = NSPredicate(format: "id IN %@", ids)
        request.propertiesToFetch = ["id", "workItemID"]
        let rows = try context.fetch(request)
        let found = Set(rows.compactMap { $0.value(forKey: "id") as? UUID })
        guard found == Set(ids), rows.allSatisfy({
            $0.value(forKey: "workItemID") as? UUID == Constants.workboardDeskItemID
        }) else { throw WorkDeskStoreError.materialNotFound }
    }

    private nonisolated static func assignDeskMaterials(
        _ ids: [UUID], projectID: UUID?, in context: NSManagedObjectContext
    ) throws {
        for id in Set(ids) {
            let rows = try deskPlacementRows(id, in: context)
            editDeskRows(rows) { row in
                if row.value(forKey: "projectID") as? UUID != projectID {
                    // Preserve the pre-upgrade loose desk location before the
                    // project position is cleared for its new local layout.
                    if row.value(forKey: "projectID") == nil, homePoint(on: row) == nil {
                        setHomePoint(deskPoint(on: row), on: row)
                    }
                    row.setValue(projectID, forKey: "projectID")
                    setDeskPoint(nil, on: row)
                }
            }
        }
    }

    private nonisolated static func liveDeskProjectRows(
        _ id: UUID, in context: NSManagedObjectContext
    ) throws -> [NSManagedObject] {
        let rows = try deskRows("WorkDeskProject", key: "id", id: id, in: context)
        guard !rows.isEmpty, !rows.contains(where: { $0.value(forKey: "deletedAt") != nil }),
              rows.contains(where: { $0.value(forKey: "title") as? String != nil }) else {
            throw WorkDeskStoreError.projectNotFound
        }
        normalizeDeskDuplicates(rows)
        return rows
    }

    /// The membership the person sees. Missing or partially arrived projects
    /// and any tombstone resolve to the unfiled desk, without changing rows.
    private nonisolated static func resolvedDeskProjectID(
        _ id: UUID?, in context: NSManagedObjectContext
    ) throws -> UUID? {
        guard let id else { return nil }
        let rows = try deskRows("WorkDeskProject", key: "id", id: id, in: context)
        guard !rows.isEmpty, !rows.contains(where: { $0.value(forKey: "deletedAt") != nil }),
              rows.contains(where: { $0.value(forKey: "title") as? String != nil }) else { return nil }
        return id
    }

    private nonisolated static func deskPlacementRows(
        _ id: UUID, in context: NSManagedObjectContext
    ) throws -> [NSManagedObject] {
        let rows = try deskRows("WorkDeskPlacement", key: "materialID", id: id, in: context)
        if !rows.isEmpty {
            normalizeDeskDuplicates(rows)
            return rows
        }
        let row = NSEntityDescription.insertNewObject(forEntityName: "WorkDeskPlacement", into: context)
        row.setValue(id, forKey: "materialID")
        row.setValue(Date(), forKey: "updatedAt")
        return [row]
    }

    private nonisolated static func deskRows(
        _ entity: String, key: String, id: UUID, in context: NSManagedObjectContext
    ) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        request.predicate = NSPredicate(format: "%K == %@", key, id as CVarArg)
        return try context.fetch(request).sorted(by: deskRowPrecedes)
    }

    /// Equal write dates have a deterministic tie-break using synced values.
    /// Object IDs are device-local and would let peers choose different rows.
    private nonisolated static func deskRowPrecedes(_ lhs: NSManagedObject, _ rhs: NSManagedObject) -> Bool {
        let leftDate = lhs.value(forKey: "updatedAt") as? Date ?? .distantPast
        let rightDate = rhs.value(forKey: "updatedAt") as? Date ?? .distantPast
        if leftDate != rightDate { return leftDate > rightDate }
        for key in lhs.entity.attributesByName.keys.sorted() {
            let left = lhs.value(forKey: key).map { String(describing: $0) } ?? ""
            let right = rhs.value(forKey: key).map { String(describing: $0) } ?? ""
            if left != right { return left > right }
        }
        return false
    }

    private nonisolated static func normalizeDeskDuplicates(_ rows: [NSManagedObject]) {
        guard rows.count > 1, let canonical = rows.first else { return }
        for row in rows.dropFirst() {
            for key in canonical.entity.attributesByName.keys {
                row.setValue(canonical.value(forKey: key), forKey: key)
            }
        }
    }

    private nonisolated static func editDeskRows(
        _ rows: [NSManagedObject], edit: (NSManagedObject) -> Void
    ) {
        let stamp = advancedWriteStamp(Date(), notBelow: rows.compactMap { $0.value(forKey: "updatedAt") as? Date })
        for row in rows {
            edit(row)
            if row.hasChanges { row.setValue(stamp, forKey: "updatedAt") }
        }
    }

    private nonisolated static func setDeskPoint(_ position: WorkDeskPoint?, on row: NSManagedObject) {
        row.setValue(position?.x, forKey: "positionX")
        row.setValue(position?.y, forKey: "positionY")
    }

    private nonisolated static func setHomePoint(_ position: WorkDeskPoint?, on row: NSManagedObject) {
        row.setValue(position?.x, forKey: "homePositionX")
        row.setValue(position?.y, forKey: "homePositionY")
    }

    private nonisolated static func homePoint(on row: NSManagedObject) -> WorkDeskPoint? {
        guard let x = row.value(forKey: "homePositionX") as? Double,
              let y = row.value(forKey: "homePositionY") as? Double,
              x.isFinite, y.isFinite else { return nil }
        return WorkDeskPoint(x: x, y: y)
    }

    private nonisolated static func deskPoint(on row: NSManagedObject) -> WorkDeskPoint? {
        guard let x = row.value(forKey: "positionX") as? Double,
              let y = row.value(forKey: "positionY") as? Double,
              x.isFinite, y.isFinite else { return nil }
        return WorkDeskPoint(x: x, y: y)
    }

    private nonisolated static func deskOrganization(in context: NSManagedObjectContext) throws -> WorkDeskOrganizationSnapshot {
        let projectRows = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "WorkDeskProject"))
            .sorted(by: deskRowPrecedes)
        let tombstones = Set(projectRows.filter { $0.value(forKey: "deletedAt") != nil }
            .compactMap { $0.value(forKey: "id") as? UUID })
        var seen: Set<UUID> = []
        var projects: [WorkDeskProjectRecord] = []
        for row in projectRows {
            guard let id = row.value(forKey: "id") as? UUID,
                  !tombstones.contains(id), !seen.contains(id),
                  let title = row.value(forKey: "title") as? String else { continue }
            seen.insert(id)
            projects.append(WorkDeskProjectRecord(
                id: id, title: title, brief: row.value(forKey: "brief") as? String ?? "",
                preferredGatewayRef: row.value(forKey: "preferredGatewayRef") as? String,
                position: deskPoint(on: row), isPinned: row.value(forKey: "isPinned") as? Bool ?? false,
                createdAt: row.value(forKey: "createdAt") as? Date ?? .distantPast,
                updatedAt: row.value(forKey: "updatedAt") as? Date ?? .distantPast
            ))
        }
        projects.sort {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        let materials = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
        materials.propertiesToFetch = ["id"]
        materials.predicate = NSPredicate(format: "workItemID == %@", Constants.workboardDeskItemID as CVarArg)
        let materialIDs = Set(try context.fetch(materials).compactMap { $0.value(forKey: "id") as? UUID })
        let placementRows = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "WorkDeskPlacement"))
            .sorted(by: deskRowPrecedes)
        var placements: [UUID: WorkDeskPlacementRecord] = [:]
        for row in placementRows {
            guard let id = row.value(forKey: "materialID") as? UUID,
                  materialIDs.contains(id), placements[id] == nil else { continue }
            let projectID = row.value(forKey: "projectID") as? UUID
            let unresolved = projectID.map { !seen.contains($0) } ?? false
            placements[id] = WorkDeskPlacementRecord(
                materialID: id, projectID: unresolved ? nil : projectID,
                position: unresolved ? nil : deskPoint(on: row),
                homePosition: homePoint(on: row),
                isPinned: row.value(forKey: "isPinned") as? Bool ?? false,
                updatedAt: row.value(forKey: "updatedAt") as? Date ?? .distantPast
            )
        }
        return WorkDeskOrganizationSnapshot(projects: projects, placements: placements,
                                            deletedProjectIDs: tombstones)
    }
}
