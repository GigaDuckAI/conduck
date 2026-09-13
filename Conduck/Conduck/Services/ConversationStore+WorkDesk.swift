// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationStore+WorkDesk.swift
//
// Private CloudKit metadata for spatial organization of the canonical capture
// desk. Ordinary organization never changes a material or payload. An explicitly
// reviewed project-and-material deletion also reclaims paired payload rows. UUID
// links tolerate imports arriving in either order; a project tombstone wins
// over every live duplicate so a late placement cannot resurrect a deletion.
// Each intent updates one item's fields, not a JSON copy of the entire desk.
// Multi-card moves validate all identities and their original scope before any
// row is inserted or normalized, then save the positions as one transaction.
// Initial capture placement reuses these metadata rows inside the material's
// own transaction; it never adds another owner or another publication step.
// Creation and restoration count canonical active projects inside the same
// serialized/file-locked write as insertion. Sync may import extra projects;
// they remain intact and usable, while subsequent slot-consuming writes fail.

import Foundation
import CoreData
import CoreGraphics

extension ConversationStore {
    /// Called only after the canonical writer proves the material is new. The
    /// same save publishes its placement, so process death cannot leave an
    /// otherwise successful capture waiting for a separate filing operation.
    /// A placement imported ahead of its material is already user organization;
    /// preserve it just as a replay preserves the placement of an existing card.
    nonisolated static func placeNewDeskCapture(
        _ materialID: UUID, projectID: UUID, isVerifiedProjectResult: Bool = false,
        access: ProAccessSnapshot,
        in context: NSManagedObjectContext
    ) throws {
        let placements = try deskRows("WorkDeskPlacement", key: "materialID", id: materialID, in: context)
        guard placements.isEmpty else { return }
        if isVerifiedProjectResult {
            // Only the publisher may set this after insertWorkDeskResult has
            // verified the existing assistant attachment and its conversation
            // in this same transaction. Archiving cannot suppress a late reply.
            _ = try liveDeskProjectRows(projectID, in: context)
        } else {
            try requireActiveDeskProject(projectID, access: access, in: context)
        }
        try assignDeskMaterials([materialID], projectID: projectID, in: context)
    }

    nonisolated static func validateProjectConversationDestination(
        _ projectID: UUID, access: ProAccessSnapshot, in context: NSManagedObjectContext
    ) throws {
        try requireActiveDeskProject(projectID, access: access, in: context)
    }

    /// A reviewed handoff can outlive its project's active status. Refuse it
    /// before uploading files; conversation insertion rechecks inside its write.
    func validateWorkDeskProjectActivity(projectID: UUID) async throws {
        if usesSharedProAccess { await ProSubscriptionStore.shared.awaitInitialAccess() }
        try await ensureLoaded()
        let lease = try await newReadContextLease()
        defer { lease.finish() }
        let context = lease.context
        try await context.perform {
            try Self.validateProjectConversationDestination(projectID, access: self.proAccessProvider(), in: context)
        }
    }

    /// Already-created conversations remain readable and accepted replies can
    /// finish. A fresh user turn in an over-limit active project waits while
    /// the person has not chosen their free active set or verified Pro access.
    nonisolated static func validateWorkDeskProjectSelection(
        _ projectID: UUID, access: ProAccessSnapshot, in context: NSManagedObjectContext
    ) throws {
        if try workDeskProjectSelectionIsRequired(projectID, access: access, in: context) {
            throw WorkDeskStoreError.projectSelectionRequired
        }
    }

    func fetchWorkDeskOrganization() async throws -> WorkDeskOrganizationSnapshot {
        try await ensureLoaded()
        let contextLease = try await newReadContextLease()
        defer { contextLease.finish() }
        let context = contextLease.context
        return try await context.perform { try Self.deskOrganization(in: context) }
    }

    func fetchWorkProjectMarks() async throws -> WorkProjectMarkSet {
        try await ensureLoaded()
        let contextLease = try await newReadContextLease()
        defer { contextLease.finish() }
        let context = contextLease.context
        return try await context.perform { [context] in try Self.workProjectMarks(in: context) }
    }

    /// One thread's project standing for the screen that shows it: the mark to
    /// draw and, for a live project, why a new turn would be refused. One hop.
    /// Throws rather than answering "ordinary chat" on a read failure or a
    /// missing conversation — a screen that cannot know keeps what it last
    /// knew, and the write path still refuses on its own.
    struct WorkProjectThreadMark: Equatable, Sendable {
        let resolution: WorkProjectMarkResolution
        let refusal: WorkProjectAccessError?
    }

    enum WorkProjectThreadMarkError: Error, Equatable {
        case conversationMissing
    }

    func workProjectThreadMark(conversationID: UUID) async throws -> WorkProjectThreadMark {
        if usesSharedProAccess { await ProSubscriptionStore.shared.awaitInitialAccess() }
        try await ensureLoaded()
        let contextLease = try await newReadContextLease()
        defer { contextLease.finish() }
        let context = contextLease.context
        let access = proAccessProvider()
        return try await context.perform { [context] in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Conversation")
            request.predicate = NSPredicate(format: "id == %@", conversationID as CVarArg)
            request.fetchLimit = 1
            guard let row = try context.fetch(request).first else { throw WorkProjectThreadMarkError.conversationMissing }
            let projectID = row.entity.attributesByName["projectID"] == nil
                ? nil : row.value(forKey: "projectID") as? UUID
            let resolution = try Self.workProjectMarks(in: context).resolve(projectID)
            var refusal: WorkProjectAccessError?
            if let mark = resolution.liveMark {
                refusal = try Self.workDeskProjectActivityError(mark.id, access: access, in: context)
            }
            return WorkProjectThreadMark(resolution: resolution, refusal: refusal)
        }
    }

    func reviewWorkDeskProjectDeletion(id: UUID) async throws -> WorkDeskProjectDeletionReview {
        try await ensureLoaded()
        let contextLease = try await newReadContextLease()
        defer { contextLease.finish() }
        let context = contextLease.context
        return try await context.perform {
            try Self.pinProjectDeletionReads(in: context)
            return try Self.projectDeletionReview(id: id, in: context)
        }
    }

    /// CloudKit imports bypass application advisory locks. A fixed SQLite
    /// generation keeps later refetches from adding a newly imported physical
    /// duplicate to the rows this confirmation validated. NSErrorMergePolicy
    /// still refuses changes to the reviewed rows themselves. In-memory test
    /// stores do not support query generations and never import CloudKit data.
    private nonisolated static func pinProjectDeletionReads(in context: NSManagedObjectContext) throws {
        guard let stores = context.persistentStoreCoordinator?.persistentStores,
              !stores.isEmpty, stores.allSatisfy({ $0.type == NSSQLiteStoreType }) else { return }
        try context.setQueryGenerationFrom(.current)
    }

    /// Reads canonical placement and material identities without normalizing
    /// duplicates. Even a refused confirmation must leave the store untouched.
    private nonisolated static func projectDeletionReview(
        id: UUID, in context: NSManagedObjectContext
    ) throws -> WorkDeskProjectDeletionReview {
        let organization = try deskOrganization(in: context)
        guard let project = organization.projects.first(where: { $0.id == id }) else {
            throw WorkDeskStoreError.projectNotFound
        }
        let placementRows = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "WorkDeskPlacement"))
            .sorted(by: deskRowPrecedes)
        var placements: [UUID: WorkDeskPlacementRecord] = [:]
        for row in placementRows {
            guard let materialID = row.value(forKey: "materialID") as? UUID, placements[materialID] == nil else { continue }
            placements[materialID] = WorkDeskPlacementRecord(materialID: materialID,
                projectID: row.value(forKey: "projectID") as? UUID, position: deskPoint(on: row),
                homePosition: homePoint(on: row), isPinned: row.value(forKey: "isPinned") as? Bool ?? false,
                updatedAt: row.value(forKey: "updatedAt") as? Date ?? .distantPast)
        }
        // Include placements whose material is still in transit. If that row
        // arrives while the dialog is open, its new content token invalidates
        // the review instead of being swept into a destructive choice.
        let locations = try deskLocationState(in: context)
        let assigned = Set(locations.filter { $0.value.contains(where: { $0.location == .project(id) }) }.keys)
        let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
        request.predicate = NSPredicate(format: "workItemID == %@", Constants.workboardDeskItemID as CVarArg)
        var rowsByID: [UUID: [NSManagedObject]] = [:]
        for row in try context.fetch(request) {
            if let materialID = row.value(forKey: "id") as? UUID { rowsByID[materialID, default: []].append(row) }
        }
        let canonical = rowsByID.compactMapValues { canonicalRow(among: $0) }
        let childByParent = deskFoldedCompanions(canonical: canonical)
        // A displayed picture is the organizational unit. Older builds moved
        // only its parent placement, so a hidden child's raw project may be
        // stale. Resolve its home through the visible parent: deleting the old
        // project must not delete words that now draw inside another project.
        let hiddenChildren = Set(childByParent.values)
        var included = assigned.intersection(canonical.keys).subtracting(hiddenChildren)
        for (parent, child) in childByParent where included.contains(parent) { included.insert(child) }
        if !included.isEmpty {
            let ownership = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
            ownership.predicate = NSPredicate(format: "id IN %@", Array(included))
            guard try context.fetch(ownership).allSatisfy({
                $0.value(forKey: "workItemID") as? UUID == Constants.workboardDeskItemID
            }) else { throw WorkDeskStoreError.staleProjectDeletion }
        }
        let ordered = included.sorted { lhs, rhs in
            let left = (canonical[lhs]?.value(forKey: "sequence") as? NSNumber)?.intValue ?? 0
            let right = (canonical[rhs]?.value(forKey: "sequence") as? NSNumber)?.intValue ?? 0
            return left != right ? left < right : lhs.uuidString < rhs.uuidString
        }
        let hidden = Set(childByParent.filter { included.contains($0.key) }.values)
        let visible = ordered.filter { !hidden.contains($0) }
        let positions = releasedProjectPositions(project: project, visibleIDs: visible,
            allMemberIDs: included, childByParent: childByParent, organization: organization)
        let conversations = NSFetchRequest<NSManagedObject>(entityName: "Conversation")
        conversations.predicate = NSPredicate(format: "projectID == %@", id as CVarArg)
        let reviewedPlacements = assigned.union(included)
        return WorkDeskProjectDeletionReview(id: UUID(), projectID: id, projectTitle: project.title,
            materialIDs: ordered, visibleMaterialIDs: visible, conversationCount: try context.count(for: conversations),
            retainedPositions: positions, focusPoint: visible.first.flatMap { positions[$0] } ?? project.position ?? .init(x: 28, y: 26),
            project: project, assignedMaterialIDs: assigned,
            placementTokens: placements.filter { reviewedPlacements.contains($0.key) },
            materialTokens: canonical.filter { included.contains($0.key) }.mapValues { canonicalOrder(of: $0) },
            locationTokens: locations.filter { reviewedPlacements.contains($0.key) },
            sharedMaterialIDs: Set(visible.filter { materialID in
                locations[materialID]?.contains(where: { $0.location != .project(id) }) ?? false
            }))
    }

    private nonisolated static func releasedProjectPositions(
        project: WorkDeskProjectRecord, visibleIDs: [UUID], allMemberIDs: Set<UUID>,
        childByParent: [UUID: UUID], organization: WorkDeskOrganizationSnapshot
    ) -> [UUID: WorkDeskPoint] {
        guard !visibleIDs.isEmpty else { return [:] }
        let card = WorkDeskCanvasGeometry.cardBodySize
        let gap: CGFloat = 24
        let columns = max(1, Int(ceil(sqrt(Double(visibleIDs.count)))))
        let rows = Int(ceil(Double(visibleIDs.count) / Double(columns)))
        let block = CGSize(width: CGFloat(columns) * (card.width + gap) - gap,
                           height: CGFloat(rows) * (card.height + gap) - gap)
        let desired = project.position ?? .init(x: 28, y: 26)
        var occupied = organization.placements.values.compactMap { placement -> CGRect? in
            guard !allMemberIDs.contains(placement.materialID), let point = placement.resolvedHomePosition else { return nil }
            return WorkDeskCanvasGeometry.frame(at: point, bodySize: card, scale: 1)
        }
        occupied += organization.projects.compactMap { other -> CGRect? in
            guard other.id != project.id, let point = other.position else { return nil }
            return WorkDeskCanvasGeometry.frame(at: point, bodySize: WorkDeskCanvasGeometry.projectBodySize, scale: 1)
        }
        // The whole block must fit inside the coordinate range. Clamping each
        // card independently at an edge would stack several cards on one point.
        let limit = WorkDeskPoint.coordinateLimit
        let maximumX = limit - Double(columns - 1) * Double(card.width + gap)
        let maximumY = limit - Double(rows - 1) * Double(card.height + gap)
        func boundedOrigin(_ point: WorkDeskPoint) -> WorkDeskPoint {
            .init(x: min(max(-limit, point.x), maximumX), y: min(max(-limit, point.y), maximumY))
        }
        let preferred = boundedOrigin(desired)
        var candidates = [preferred]
        for obstacle in occupied {
            let xs = [obstacle.minX - block.width - 24, CGFloat(preferred.x), obstacle.maxX + 24]
            let ys = [obstacle.minY - block.height - 24, CGFloat(preferred.y), obstacle.maxY + 24]
            for x in xs { for y in ys { candidates.append(boundedOrigin(.init(x: Double(x), y: Double(y)))) } }
        }
        let origin = Set(candidates).filter { point in
            let frame = CGRect(x: point.x, y: point.y, width: block.width, height: block.height).insetBy(dx: -10, dy: -10)
            return !occupied.contains { $0.intersects(frame) }
        }.min { lhs, rhs in
            let left = hypot(lhs.x - desired.x, lhs.y - desired.y), right = hypot(rhs.x - desired.x, rhs.y - desired.y)
            if left != right { return left < right }
            if lhs.x != rhs.x { return lhs.x < rhs.x }
            return lhs.y < rhs.y
        } ?? preferred
        var result: [UUID: WorkDeskPoint] = [:]
        for (index, materialID) in visibleIDs.enumerated() {
            let point = WorkDeskPoint(x: origin.x + Double(index % columns) * Double(card.width + gap),
                                     y: origin.y + Double(index / columns) * Double(card.height + gap))
            result[materialID] = point
            if let child = childByParent[materialID] { result[child] = point }
        }
        return result
    }

    private nonisolated static func applyReviewedProjectDeletion(
        _ review: WorkDeskProjectDeletionReview, deleteMaterials: Bool, in context: NSManagedObjectContext,
        afterValidation: (@Sendable () -> Void)? = nil
    ) throws -> [String] {
        let current = try projectDeletionReview(id: review.projectID, in: context)
        guard current.project == review.project,
              current.assignedMaterialIDs == review.assignedMaterialIDs,
              current.materialTokens == review.materialTokens,
              current.placementTokens == review.placementTokens,
              current.locationTokens == review.locationTokens,
              current.visibleMaterialIDs == review.visibleMaterialIDs else {
            throw WorkDeskStoreError.staleProjectDeletion
        }
        afterValidation?()
        // The metadata tombstone remains the authority for a placement that
        // imports later. Conversations and result receipts deliberately remain.
        try applyDeskMutation(.deleteProject(id: review.projectID), in: context)
        if !deleteMaterials {
            let released = try deskLocationState(materialIDs: Set(current.materialIDs), in: context)
            for materialID in current.materialIDs {
                guard var locations = released[materialID],
                      let home = locations.firstIndex(where: { $0.location == .home }),
                      !current.sharedMaterialIDs.contains(materialID) else { continue }
                locations[home].position = current.retainedPositions[materialID]
                try writeDeskLocationState(materialID: materialID, desired: locations,
                    previous: released[materialID] ?? [], in: context)
            }
        }
        if deleteMaterials { return try deleteReviewedDeskMaterials(ids: current.materialIDs, in: context) }
        return []
    }

    /// A fallback inserts no placement. A successfully filed capture retains
    /// its placement row even when deletion clears its membership locally or
    /// a synced project tombstone makes that membership resolve to All materials.
    /// Any later organization also wins over reconstructing a capture receipt.
    /// Read only these two identities, including their CloudKit duplicates;
    /// resolving the entire desk would make every stale voice retry expensive.
    func isUnfiledWorkCaptureFallback(materialID: UUID, projectID: UUID) async throws -> Bool {
        try await ensureLoaded()
        let contextLease = try await newReadContextLease()
        defer { contextLease.finish() }
        let context = contextLease.context
        return try await context.perform {
            let placements = try Self.deskRows(
                "WorkDeskPlacement", key: "materialID", id: materialID, in: context
            )
            guard placements.isEmpty else { return false }
            if try Self.resolvedDeskProjectID(projectID, in: context) == nil { return true }
            if try Self.deskRows("WorkDeskProject", key: "id", id: projectID, in: context)
                .first?.value(forKey: "archivedAt") != nil { return true }
            do {
                try Self.validateWorkDeskProjectSelection(projectID, access: self.proAccessProvider(), in: context)
                return false
            } catch WorkDeskStoreError.projectSelectionRequired { return true }
        }
    }

    @discardableResult
    func applyWorkDeskMutation(_ mutation: WorkDeskMutation) async throws -> WorkDeskOrganizationSnapshot {
        // Material -> organization is the shared order with initial captures.
        // Claim the complete reviewed set at once so two deletions cannot each
        // retain one material while waiting forever for the other's claim.
        let reviewedIDs: Set<UUID>
        if case let .deleteReviewedProject(review, _) = mutation { reviewedIDs = Set(review.materialIDs) }
        else { reviewedIDs = [] }
        while !workMaterialPublicationClaims.isDisjoint(with: reviewedIDs) {
            try await Task.sleep(for: .milliseconds(40))
        }
        workMaterialPublicationClaims.formUnion(reviewedIDs)
        defer { workMaterialPublicationClaims.subtract(reviewedIDs) }
        try await ensureLoaded()
        var materialHolds: [WorkMaterialPublicationLock.Hold] = []
        defer { materialHolds.forEach { $0.release() } }
        for id in reviewedIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            if let hold = try await workMaterialPublicationLock?.acquire(materialID: id) { materialHolds.append(hold) }
        }
        await acquireWorkDeskMutation()
        defer { releaseWorkDeskMutation() }
        try Task.checkCancellation()
        let organizationHold = try await workMaterialPublicationLock?.acquireOrganization()
        defer { organizationHold?.release() }
        let contextLease = try await newWriteContextLease()
        defer { contextLease.finish() }
        let context = contextLease.context
        context.mergePolicy = NSErrorMergePolicy
        #if CONDUCK_TESTING
        let afterValidation = workDeskDeletionValidationHookForTesting
        #else
        let afterValidation: (@Sendable () -> Void)? = nil
        #endif
        let (snapshot, changed, vaultKeys) = try await context.perform {
            var vaultKeys: [String] = []
            switch mutation {
            case .moveLocations, .addLocations, .removeLocations, .positionLocations, .restoreLocations, .createProjectFrom, .reorderLocations, .moveAndReorderLocations:
                try Self.pinProjectDeletionReads(in: context)
            default: break
            }
            let locationIDs = Self.deskLocationMutationMaterialIDs(mutation)
            let companionIDs = try Self.deskLocationCompanions(for: Array(locationIDs), in: context).values
            let affectedLocations = locationIDs.union(companionIDs)
            let locationBefore = try Self.deskLocationState(materialIDs: affectedLocations, in: context)
            if case let .deleteReviewedProject(review, deleteMaterials) = mutation {
                try Self.pinProjectDeletionReads(in: context)
                vaultKeys = try Self.applyReviewedProjectDeletion(review, deleteMaterials: deleteMaterials, in: context,
                    afterValidation: afterValidation)
            }
            try Self.applyDeskMutation(mutation, access: self.proAccessProvider(), in: context)
            let changed = context.hasChanges
            if changed { try context.save() }
            var snapshot = try Self.deskOrganization(in: context)
            let locationAfter = try Self.deskLocationState(materialIDs: affectedLocations, in: context)
            let changedLocations = affectedLocations.filter { locationBefore[$0] != locationAfter[$0] }
            if !changedLocations.isEmpty {
                let restoring: Bool
                if case .restoreLocations = mutation { restoring = true } else { restoring = false }
                snapshot.locationUndo = .init(
                    before: locationBefore.filter { changedLocations.contains($0.key) },
                    after: locationAfter.filter { changedLocations.contains($0.key) },
                    isRestoration: restoring)
            }
            return (snapshot, changed, vaultKeys)
        }
        contextLease.finish()
        for key in vaultKeys { try? await workAssetVault.remove(key) }
        if changed { await postDidChange() }
        return snapshot
    }

    func acquireWorkDeskMutation() async {
        if !workDeskMutationInProgress {
            workDeskMutationInProgress = true
            return
        }
        await withCheckedContinuation { workDeskMutationWaiters.append($0) }
    }

    func releaseWorkDeskMutation() {
        if workDeskMutationWaiters.isEmpty { workDeskMutationInProgress = false }
        else { workDeskMutationWaiters.removeFirst().resume() }
    }

    private nonisolated static func applyDeskMutation(
        _ mutation: WorkDeskMutation, access: ProAccessSnapshot = .init(), in context: NSManagedObjectContext
    ) throws {
        switch mutation {
        case let .createProjectFrom(project, materialIDs, source, expected, automaticallyAssignColor):
            try applyDeskMutation(.createProject(project, materialIDs: [], automaticallyAssignColor: automaticallyAssignColor), access: access, in: context)
            try applyDeskLocationMutation(.moveLocations(materialIDs: materialIDs, from: source, to: .project(project.id),
                                                        positions: [:], expected: expected), access: access, in: context)
        case .moveLocations, .addLocations, .removeLocations, .positionLocations, .restoreLocations, .reorderLocations, .moveAndReorderLocations:
            try applyDeskLocationMutation(mutation, access: access, in: context)
        case .deleteReviewedProject:
            // Validated and applied before this metadata-only switch.
            break
        case let .createProject(project, materialIDs, automaticallyAssignColor):
            try validateDeskText(title: project.title, brief: project.brief)
            try requireDeskMaterials(materialIDs, in: context)
            guard try deskRows("WorkDeskProject", key: "id", id: project.id, in: context).isEmpty else {
                throw WorkDeskStoreError.identifierCollision
            }
            // A caller cannot bypass the allowance by creating an archived
            // record directly. Every new project starts active.
            try requireAvailableDeskProjectSlot(access: access, in: context)
            let color = automaticallyAssignColor
                ? WorkDeskProjectColor.leastUsed(in: try deskOrganization(in: context).projects.map(\.color))
                : project.color
            let row = NSEntityDescription.insertNewObject(forEntityName: "WorkDeskProject", into: context)
            row.setValue(project.id, forKey: "id")
            row.setValue(project.title.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "title")
            row.setValue(project.brief, forKey: "brief")
            row.setValue(project.preferredGatewayRef, forKey: "preferredGatewayRef")
            row.setValue(color.rawValue, forKey: "colorID")
            row.setValue(project.isPinned, forKey: "isPinned")
            row.setValue(project.createdAt, forKey: "createdAt")
            row.setValue(Date(), forKey: "updatedAt")
            setDeskPoint(project.position, on: row)
            try assignDeskMaterials(materialIDs, projectID: project.id, in: context)
        case let .archiveProject(id, isArchived):
            // Validate without normalizing duplicates: a refused restoration
            // must not modify even an older physical duplicate row.
            let rows = try deskRows("WorkDeskProject", key: "id", id: id, in: context)
            guard !rows.isEmpty, !rows.contains(where: { $0.value(forKey: "deletedAt") != nil }),
                  rows.contains(where: { $0.value(forKey: "title") as? String != nil }) else {
                throw WorkDeskStoreError.projectNotFound
            }
            let archived = rows.first?.value(forKey: "archivedAt") != nil
            guard archived != isArchived else { break }
            if !isArchived { try requireAvailableDeskProjectSlot(access: access, in: context) }
            normalizeDeskDuplicates(rows)
            let archivedAt: Date? = isArchived ? Date() : nil
            editDeskRows(rows) { $0.setValue(archivedAt, forKey: "archivedAt") }
        case let .selectFreeProjects(keeping, expectedActiveProjectIDs):
            let activeIDs = Set(try deskOrganization(in: context).projects.filter { !$0.isArchived }.map(\.id))
            guard !access.hasProAccess,
                  activeIDs.count > Constants.maxActiveWorkProjects,
                  keeping.count <= Constants.maxActiveWorkProjects,
                  keeping.isSubset(of: activeIDs), activeIDs == expectedActiveProjectIDs else {
                throw WorkDeskStoreError.projectSelectionChanged
            }
            // Only the explicit confirmation reaches here. Zero selected is
            // valid: the person may choose to archive all completed projects.
            let archivedAt = Date()
            for id in activeIDs.subtracting(keeping) {
                let rows = try liveDeskProjectRows(id, in: context)
                editDeskRows(rows) { $0.setValue(archivedAt, forKey: "archivedAt") }
            }
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
        case let .setProjectColor(id, color, expectedUpdatedAt):
            let rows = try liveDeskProjectRows(id, in: context)
            if let expectedUpdatedAt,
               rows.first?.value(forKey: "updatedAt") as? Date != expectedUpdatedAt {
                throw WorkDeskStoreError.staleProject
            }
            editDeskRows(rows) { row in
                // Core Data can mark an equal KVC assignment as changed.
                // Choosing the current swatch must not advance the revision
                // and invalidate an editor that still has the same project.
                guard row.value(forKey: "colorID") as? String != color.rawValue else { return }
                row.setValue(color.rawValue, forKey: "colorID")
            }
        case let .deleteProject(id):
            let locationState = try deskLocationState(in: context)
            let rows = try deskRows("WorkDeskProject", key: "id", id: id, in: context)
            guard !rows.isEmpty else { throw WorkDeskStoreError.projectNotFound }
            editDeskRows(rows) { row in
                row.setValue(row.value(forKey: "deletedAt") ?? Date(), forKey: "deletedAt")
                // Keep only identity and dates. Deleted projects do not retain
                // the person's brief or a destination they no longer need.
                for key in ["title", "brief", "preferredGatewayRef", "colorID", "positionX", "positionY", "isPinned", "archivedAt"] {
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
            for (materialID, locations) in locationState where locations.contains(where: { $0.location == .project(id) }) {
                var remaining = locations.filter { $0.location != .project(id) }
                if remaining.isEmpty { remaining = [.init(materialID: materialID, location: .home, position: nil)] }
                try writeDeskLocationState(materialID: materialID, desired: remaining, previous: locations, in: context)
            }
        case let .assign(materialIDs, projectID):
            if let projectID { try requireActiveDeskProject(projectID, access: access, in: context) }
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
                if try !deskRows("WorkDeskLocation", key: "materialID", id: seed.materialID, in: context).isEmpty {
                    let location = seed.isHome ? WorkDeskLocation.home : seed.projectID.map(WorkDeskLocation.project) ?? .home
                    let current = try deskLocationState(materialIDs: [seed.materialID], in: context)[seed.materialID] ?? []
                    guard let index = current.firstIndex(where: { $0.location == location }), current[index].position == nil else { continue }
                    var desired = current
                    desired[index].position = seed.position
                    try writeDeskLocationState(materialID: seed.materialID, desired: desired, previous: current,
                                               seedingPositions: true, in: context)
                    continue
                }
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

    nonisolated static func requireDeskMaterials(
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
        let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
        request.predicate = NSPredicate(format: "workItemID == %@ AND id IN %@", Constants.workboardDeskItemID as CVarArg, ids)
        var grouped: [UUID: [NSManagedObject]] = [:]
        for row in try context.fetch(request) {
            if let id = row.value(forKey: "id") as? UUID { grouped[id, default: []].append(row) }
        }
        var expanded = Set(ids)
        let hasPicture = grouped.values.contains { rows in
            guard let row = canonicalRow(among: rows) else { return false }
            return WorkMaterialKind(stored: row.value(forKey: "kind") as? String) == .image
                && row.value(forKey: "attachedToMaterialID") == nil
        }
        if hasPicture {
            // New capture placement happens before its material insert and
            // cannot have a displayed companion yet. Notes/files also bypass
            // this scan; only moving an existing picture needs the global fold.
            request.predicate = NSPredicate(format: "workItemID == %@", Constants.workboardDeskItemID as CVarArg)
            grouped.removeAll(keepingCapacity: true)
            for row in try context.fetch(request) {
                if let id = row.value(forKey: "id") as? UUID { grouped[id, default: []].append(row) }
            }
            let children = deskFoldedCompanions(canonical: grouped.compactMapValues { canonicalRow(among: $0) })
            for parent in ids { if let child = children[parent] { expanded.insert(child) } }
        }
        try replaceDeskLocations(materialIDs: Array(expanded), projectID: projectID, in: context)
        for id in expanded {
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

    /// Same eligibility and lowest-child identity rule as the visible fold.
    /// A duplicate or late linked note cannot invent a second displayed child.
    nonisolated static func deskFoldedCompanions(
        canonical: [UUID: NSManagedObject]
    ) -> [UUID: UUID] {
        var childByParent: [UUID: UUID] = [:]
        for (childID, row) in canonical {
            let kind = WorkMaterialKind(stored: row.value(forKey: "kind") as? String)
            guard kind == .audio || kind == .transcript,
                  let link = row.value(forKey: "attachedToMaterialID") as? UUID, link != childID else { continue }
            for parentID in [link, WorkMaterialCollisionEscape.materialID(forCapture: link)] {
                guard parentID != childID, let parent = canonical[parentID],
                      WorkMaterialKind(stored: parent.value(forKey: "kind") as? String) == .image,
                      parent.value(forKey: "attachedToMaterialID") == nil else { continue }
                if childByParent[parentID].map({ childID.uuidString < $0.uuidString }) ?? true {
                    childByParent[parentID] = childID
                }
                break
            }
        }
        return childByParent
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

    nonisolated static func requireActiveDeskProject(
        _ id: UUID, access: ProAccessSnapshot, in context: NSManagedObjectContext
    ) throws {
        let rows = try liveDeskProjectRows(id, in: context)
        guard rows.first?.value(forKey: "archivedAt") == nil else {
            throw WorkDeskStoreError.projectArchived
        }
        try validateWorkDeskProjectSelection(id, access: access, in: context)
    }

    private nonisolated static func requireAvailableDeskProjectSlot(access: ProAccessSnapshot, in context: NSManagedObjectContext) throws {
        guard !access.hasProAccess else { return }
        // Counting the resolved snapshot deduplicates CloudKit rows and honors
        // tombstones. Archived projects still resolve their materials normally.
        let activeCount = try deskOrganization(in: context).projects.filter { !$0.isArchived }.count
        guard activeCount < Constants.maxActiveWorkProjects else {
            throw WorkDeskStoreError.activeProjectLimitReached
        }
    }

    /// The membership the person sees. Missing or partially arrived projects
    /// and any tombstone resolve to the unfiled desk, without changing rows.
    nonisolated static func resolvedDeskProjectID(
        _ id: UUID?, in context: NSManagedObjectContext
    ) throws -> UUID? {
        guard let id else { return nil }
        let rows = try deskRows("WorkDeskProject", key: "id", id: id, in: context)
        guard !rows.isEmpty, !rows.contains(where: { $0.value(forKey: "deletedAt") != nil }),
              rows.contains(where: { $0.value(forKey: "title") as? String != nil }) else { return nil }
        return id
    }

    nonisolated static func deskPlacementRows(
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

    nonisolated static func deskRows(
        _ entity: String, key: String, id: UUID, in context: NSManagedObjectContext
    ) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        request.predicate = NSPredicate(format: "%K == %@", key, id as CVarArg)
        return try context.fetch(request).sorted(by: deskRowPrecedes)
    }

    private nonisolated static func normalizeDeskDuplicates(_ rows: [NSManagedObject]) {
        guard rows.count > 1, let canonical = rows.first else { return }
        for row in rows.dropFirst() {
            for key in canonical.entity.attributesByName.keys {
                row.setValue(canonical.value(forKey: key), forKey: key)
            }
        }
    }

    nonisolated static func editDeskRows(
        _ rows: [NSManagedObject], edit: (NSManagedObject) -> Void
    ) {
        let stamp = advancedWriteStamp(Date(), notBelow: rows.compactMap { $0.value(forKey: "updatedAt") as? Date })
        for row in rows {
            edit(row)
            if row.hasChanges { row.setValue(stamp, forKey: "updatedAt") }
        }
    }

    nonisolated static func setDeskPoint(_ position: WorkDeskPoint?, on row: NSManagedObject) {
        row.setValue(position?.x, forKey: "positionX")
        row.setValue(position?.y, forKey: "positionY")
    }

    nonisolated static func setHomePoint(_ position: WorkDeskPoint?, on row: NSManagedObject) {
        row.setValue(position?.x, forKey: "homePositionX")
        row.setValue(position?.y, forKey: "homePositionY")
    }

    nonisolated static func homePoint(on row: NSManagedObject) -> WorkDeskPoint? {
        guard let x = row.value(forKey: "homePositionX") as? Double,
              let y = row.value(forKey: "homePositionY") as? Double,
              x.isFinite, y.isFinite else { return nil }
        return WorkDeskPoint(x: x, y: y)
    }

    nonisolated static func deskPoint(on row: NSManagedObject) -> WorkDeskPoint? {
        guard let x = row.value(forKey: "positionX") as? Double,
              let y = row.value(forKey: "positionY") as? Double,
              x.isFinite, y.isFinite else { return nil }
        return WorkDeskPoint(x: x, y: y)
    }

    /// Every live project as a record, in creation order, legacy colours
    /// resolved. The one reader of `canonicalLiveProjectRows` that names and
    /// colours projects — the desk snapshot and the list marks both build on
    /// it, so a project can never be amber on the desk and sage in Chats.
    private nonisolated static func resolvedDeskProjects(
        in context: NSManagedObjectContext
    ) throws -> (projects: [WorkDeskProjectRecord], tombstonedIDs: Set<UUID>) {
        let rows = try canonicalLiveProjectRows(in: context)
        var projects: [WorkDeskProjectRecord] = []
        var uncoloredProjectIDs: Set<UUID> = []
        for row in rows.live {
            guard let id = row.value(forKey: "id") as? UUID,
                  let title = row.value(forKey: "title") as? String else { continue }
            if row.value(forKey: "colorID") == nil { uncoloredProjectIDs.insert(id) }
            projects.append(WorkDeskProjectRecord(
                id: id, title: title, brief: row.value(forKey: "brief") as? String ?? "",
                preferredGatewayRef: row.value(forKey: "preferredGatewayRef") as? String,
                color: WorkDeskProjectColor(storedID: row.value(forKey: "colorID") as? String),
                position: deskPoint(on: row), isPinned: row.value(forKey: "isPinned") as? Bool ?? false,
                archivedAt: row.value(forKey: "archivedAt") as? Date,
                createdAt: row.value(forKey: "createdAt") as? Date ?? .distantPast,
                updatedAt: row.value(forKey: "updatedAt") as? Date ?? .distantPast
            ))
        }
        projects.sort {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        // Old projects have no stored color. Resolve in stable creation order,
        // never from randomized Swift hashes or sidebar title sorting. Later
        // projects cannot recolor earlier ones merely by being created.
        var earlierColors: [WorkDeskProjectColor] = []
        for index in projects.indices {
            if uncoloredProjectIDs.contains(projects[index].id) {
                projects[index].color = .leastUsed(in: earlierColors)
            }
            earlierColors.append(projects[index].color)
        }
        return (projects, rows.tombstonedIDs)
    }

    /// The marks every Chats surface draws beside a project's conversation.
    nonisolated static func workProjectMarks(in context: NSManagedObjectContext) throws -> WorkProjectMarkSet {
        let resolved = try resolvedDeskProjects(in: context)
        var marks: [UUID: WorkProjectMark] = [:]
        for project in resolved.projects {
            marks[project.id] = WorkProjectMark(
                id: project.id, title: project.title, color: project.color, isArchived: project.isArchived
            )
        }
        return WorkProjectMarkSet(marks: marks, tombstonedIDs: resolved.tombstonedIDs)
    }

    private nonisolated static func deskOrganization(in context: NSManagedObjectContext) throws -> WorkDeskOrganizationSnapshot {
        let (projects, tombstones) = try resolvedDeskProjects(in: context)
        let seen = Set(projects.map(\.id))
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
        let explicitRequest = NSFetchRequest<NSManagedObject>(entityName: "WorkDeskLocation")
        explicitRequest.propertiesToFetch = ["materialID"]
        let explicitIDs = Set(try context.fetch(explicitRequest).compactMap { $0.value(forKey: "materialID") as? UUID })
            .intersection(materialIDs)
        let locations = try deskLocationState(materialIDs: explicitIDs, in: context)
        return WorkDeskOrganizationSnapshot(projects: projects, placements: placements,
                                            deletedProjectIDs: tombstones, materialLocations: locations)
    }
}
