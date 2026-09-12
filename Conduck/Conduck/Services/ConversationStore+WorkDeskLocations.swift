// SPDX-License-Identifier: Apache-2.0

// Equal material locations are independently mirrored rows, never a whole-list
// blob. Absence is a durable per-location tombstone, so an offline older row
// cannot resurrect a removed reference. A newer explicit add can restore it.
// Legacy single-project placement is adopted lazily inside the first write.
// Its projected location/date also bridge older clients: a later legacy move
// replaces only that projected location, preserving other project references.
// Reads never migrate or normalize rows. Missing projects fall back to Home,
// without destroying memberships whose project record is still in transit.

import Foundation
import CoreData

private nonisolated struct StoredDeskLocation {
    var record: WorkDeskLocationRecord
    var isPresent: Bool
}

private nonisolated struct DeskLocationAppearance: Equatable {
    let position: WorkDeskPoint?
    let sortRank: Double?
    let positionWasSeeded: Bool
}

extension ConversationStore {
    private nonisolated static func deskLocationRowPrecedes(_ lhs: NSManagedObject, _ rhs: NSManagedObject) -> Bool {
        let leftDate = lhs.value(forKey: "updatedAt") as? Date ?? .distantPast
        let rightDate = rhs.value(forKey: "updatedAt") as? Date ?? .distantPast
        if leftDate != rightDate { return leftDate > rightDate }
        let left = lhs.value(forKey: "isPresent") as? Bool ?? false
        let right = rhs.value(forKey: "isPresent") as? Bool ?? false
        if left != right { return !left }
        return deskRowPrecedes(lhs, rhs)
    }

    /// Includes material-less organization when no IDs are supplied, because a
    /// project deletion must review placements that arrived ahead of a capture.
    nonisolated static func deskLocationState(
        materialIDs requested: Set<UUID>? = nil, in context: NSManagedObjectContext
    ) throws -> WorkDeskLocationTokens {
        let legacyRequest = NSFetchRequest<NSManagedObject>(entityName: "WorkDeskPlacement")
        let locationRequest = NSFetchRequest<NSManagedObject>(entityName: "WorkDeskLocation")
        if let requested {
            guard !requested.isEmpty else { return [:] }
            let predicate = NSPredicate(format: "materialID IN %@", Array(requested))
            legacyRequest.predicate = predicate
            locationRequest.predicate = predicate
        }
        let legacyRows = try context.fetch(legacyRequest).sorted(by: deskRowPrecedes)
        let locationRows = try context.fetch(locationRequest).sorted(by: deskLocationRowPrecedes)
        let legacy = Dictionary(legacyRows.compactMap { row in
            (row.value(forKey: "materialID") as? UUID).map { ($0, row) }
        }, uniquingKeysWith: { first, _ in first })
        var stored: [UUID: [WorkDeskLocation: StoredDeskLocation]] = [:]
        for row in locationRows {
            guard let id = row.value(forKey: "materialID") as? UUID,
                  let present = row.value(forKey: "isPresent") as? Bool else { continue }
            let location = (row.value(forKey: "projectID") as? UUID).map(WorkDeskLocation.project) ?? .home
            guard stored[id]?[location] == nil else { continue }
            stored[id, default: [:]][location] = .init(record: .init(materialID: id, location: location,
                position: deskPoint(on: row), sortRank: finiteDeskSortRank(on: row),
                positionWasSeeded: row.value(forKey: "positionWasSeeded") as? Bool ?? false,
                updatedAt: row.value(forKey: "updatedAt") as? Date ?? .distantPast,
                revision: row.value(forKey: "revision") as? UUID), isPresent: present)
        }
        let projects = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "WorkDeskProject"))
        let deleted = Set(projects.filter { $0.value(forKey: "deletedAt") != nil }
            .compactMap { $0.value(forKey: "id") as? UUID })
        let live = Set(projects.filter { $0.value(forKey: "title") as? String != nil }
            .compactMap { $0.value(forKey: "id") as? UUID }).subtracting(deleted)
        let ids = requested ?? Set(legacy.keys).union(stored.keys)
        var result: WorkDeskLocationTokens = [:]
        for id in ids {
            var entries = stored[id] ?? [:]
            if let row = legacy[id] {
                let current = (row.value(forKey: "projectID") as? UUID).map(WorkDeskLocation.project) ?? .home
                let stamp = row.value(forKey: "updatedAt") as? Date ?? .distantPast
                let projectedStamp = row.value(forKey: "locationsProjectedAt") as? Date
                let projected = projectedStamp == nil ? current
                    : (row.value(forKey: "locationsProjectID") as? UUID).map(WorkDeskLocation.project) ?? .home
                // CloudKit may deliver the compatibility projection before its
                // new location rows. Keep that known location visible meanwhile.
                if entries[projected] == nil {
                    let position = projected == current
                        ? (current == .home ? homePoint(on: row) ?? deskPoint(on: row) : deskPoint(on: row)) : nil
                    entries[projected] = .init(record: .init(materialID: id, location: projected,
                        position: position, updatedAt: projectedStamp ?? stamp), isPresent: true)
                }
                if let projectedStamp, stamp > projectedStamp {
                    // Old clients update only legacy fields. They cannot erase
                    // independent locations written after that legacy operation.
                    if projected != current, let source = entries[projected], source.record.updatedAt <= stamp {
                        entries[projected] = .init(record: source.record, isPresent: false)
                    }
                    let position = current == .home ? homePoint(on: row) ?? deskPoint(on: row) : deskPoint(on: row)
                    let changesLocation = projected != current || entries[current]?.isPresent != true
                        || entries[current]?.record.position != position
                    if changesLocation, entries[current].map({ $0.record.updatedAt <= stamp }) ?? true {
                        entries[current] = .init(record: .init(materialID: id, location: current,
                            position: position, sortRank: entries[current]?.record.sortRank,
                            updatedAt: stamp), isPresent: true)
                    }
                }
            }
            var visible = entries.values.filter { entry in
                entry.isPresent && (entry.record.location.projectID.map(live.contains) ?? true)
            }.map(\.record)
            if visible.isEmpty {
                visible = [.init(materialID: id, location: .home,
                    position: entries[.home]?.record.position ?? legacy[id].flatMap { homePoint(on: $0) },
                    sortRank: entries[.home]?.record.sortRank,
                    positionWasSeeded: entries[.home]?.record.positionWasSeeded ?? false,
                    updatedAt: entries.values.map(\.record.updatedAt).max() ?? .distantPast,
                    revision: entries[.home]?.record.revision)]
            }
            result[id] = visible.sorted { $0.location.sortKey < $1.location.sortKey }
        }
        return result
    }

    nonisolated static func deskLocationMutationMaterialIDs(_ mutation: WorkDeskMutation) -> Set<UUID> {
        switch mutation {
        case let .moveLocations(ids, _, _, _, _), let .addLocations(ids, _, _, _), let .removeLocations(ids, _, _): Set(ids)
        case let .positionLocations(positions, _, _): Set(positions.keys)
        case let .restoreLocations(saved, _): Set(saved.keys)
        case let .reorderLocations(_, _, _, _, ids, _): Set(ids)
        case let .moveAndReorderLocations(ids, _, _, _, _, ordered, _): Set(ids).union(ordered)
        default: []
        }
    }

    nonisolated static func applyDeskLocationMutation(
        _ mutation: WorkDeskMutation, access: ProAccessSnapshot, in context: NSManagedObjectContext
    ) throws {
        if case let .moveAndReorderLocations(ids, source, destination, target, placement, ordered, expected) = mutation {
            guard !ids.isEmpty, !ids.contains(target), ordered.contains(target) else { throw WorkDeskStoreError.materialMoved }
            try validateDeskLocationOrder(ordered, at: destination, in: context)
            let before = try deskLocationState(materialIDs: Set(ids).union(ordered), in: context)
            if let expected {
                for (id, token) in expected {
                    guard let current = before[id], Set(current) == Set(token) else { throw WorkDeskStoreError.materialMoved }
                }
            }
            try applyDeskLocationMutation(.moveLocations(materialIDs: ids, from: source, to: destination,
                                                        positions: [:], expected: expected), access: access, in: context)
            var result = ordered.filter { !ids.contains($0) }
            guard let targetIndex = result.firstIndex(of: target) else { throw WorkDeskStoreError.materialMoved }
            let moving = ids.reduce(into: [UUID]()) { result, id in if !result.contains(id) { result.append(id) } }
            result.insert(contentsOf: moving, at: targetIndex + (placement == .after ? 1 : 0))
            try validateDeskLocationOrder(result, at: destination, in: context)
            let current = try deskLocationState(materialIDs: Set(result), in: context)
            var ranked = current
            for (rank, id) in result.enumerated() {
                guard let index = ranked[id]?.firstIndex(where: { $0.location == destination }) else { throw WorkDeskStoreError.materialMoved }
                ranked[id]?[index].sortRank = Double(rank)
            }
            try applyDeskLocationMutation(.restoreLocations(ranked, expected: current), access: access, in: context)
            return
        }
        let ids: [UUID]
        let expected: WorkDeskLocationTokens?
        switch mutation {
        case let .moveLocations(materialIDs, _, _, _, tokens), let .addLocations(materialIDs, _, _, tokens),
             let .removeLocations(materialIDs, _, tokens): ids = materialIDs; expected = tokens
        case let .positionLocations(positions, _, tokens): ids = Array(positions.keys); expected = tokens
        case let .restoreLocations(saved, tokens):
            guard Set(saved.keys) == Set(tokens.keys) else { throw WorkDeskStoreError.materialMoved }
            ids = Array(saved.keys); expected = tokens
        case let .reorderLocations(_, _, _, _, ordered, tokens): ids = ordered; expected = tokens
        default: return
        }
        guard !ids.isEmpty else { return }
        try requireDeskMaterials(ids, in: context)
        let companions = try deskLocationCompanions(for: ids, in: context)
        let expanded = Set(ids).union(companions.values)
        try requireDeskMaterials(Array(expanded), in: context)
        let before = try deskLocationState(materialIDs: expanded, in: context)
        if let expected {
            for id in ids {
                guard let token = expected[id], let current = before[id] else { throw WorkDeskStoreError.materialMoved }
                let matches: Bool
                if case .restoreLocations = mutation { matches = deskUndoTokensMatch(current, expected: token) }
                else { matches = Set(token) == Set(current) }
                guard matches else {
                    throw WorkDeskStoreError.materialMoved
                }
            }
        }
        var desired: WorkDeskLocationTokens = [:]
        var reorderedRanks: [UUID: Int] = [:]
        if case let .reorderLocations(moving, target, placement, location, ordered, _) = mutation {
            guard Set(ordered).count == ordered.count, ordered.contains(moving), ordered.contains(target) else {
                throw WorkDeskStoreError.materialMoved
            }
            try validateDeskLocationOrder(ordered, at: location, in: context)
            if moving == target { return }
            var result = ordered.filter { $0 != moving }
            guard let targetIndex = result.firstIndex(of: target) else { throw WorkDeskStoreError.materialMoved }
            result.insert(moving, at: targetIndex + (placement == .after ? 1 : 0))
            if result == ordered { return }
            // Resolve every rank once; looking up each material by scanning
            // the ordered array makes rank assignment quadratic in board size.
            reorderedRanks = Dictionary(uniqueKeysWithValues: result.enumerated().map { ($0.element, $0.offset) })
        }
        for id in Set(ids) {
            var records = before[id] ?? []
            switch mutation {
            case let .moveLocations(_, source, target, positions, _):
                guard records.contains(where: { $0.location == source }) else { throw WorkDeskStoreError.materialMoved }
                if source != target { records.removeAll { $0.location == source } }
                if let index = records.firstIndex(where: { $0.location == target }) {
                    if source == target, let point = positions[id] {
                        records[index].position = point
                        records[index].positionWasSeeded = false
                    }
                } else { records.append(.init(materialID: id, location: target, position: positions[id])) }
            case let .addLocations(_, target, positions, _):
                if !records.contains(where: { $0.location == target }) {
                    records.append(.init(materialID: id, location: target, position: positions[id]))
                }
            case let .removeLocations(_, source, _):
                guard records.contains(where: { $0.location == source }) else { throw WorkDeskStoreError.materialMoved }
                records.removeAll { $0.location == source }
            case let .positionLocations(positions, location, _):
                guard let index = records.firstIndex(where: { $0.location == location }) else { throw WorkDeskStoreError.materialMoved }
                records[index].position = positions[id]
                records[index].positionWasSeeded = false
            case let .restoreLocations(saved, _):
                records = saved[id] ?? []
                guard !records.isEmpty, records.allSatisfy({ $0.materialID == id }),
                      Set(records.map(\.location)).count == records.count else { throw WorkDeskStoreError.materialMoved }
            case let .reorderLocations(_, _, _, location, _, _):
                guard let index = records.firstIndex(where: { $0.location == location }),
                      let rank = reorderedRanks[id] else { throw WorkDeskStoreError.materialMoved }
                records[index].sortRank = Double(rank)
            default: break
            }
            if records.isEmpty { records = [.init(materialID: id, location: .home, position: nil)] }
            for record in records {
                guard record.sortRank?.isFinite ?? true else { throw WorkDeskStoreError.materialMoved }
                if let projectID = record.location.projectID {
                    guard try resolvedDeskProjectID(projectID, in: context) != nil else { throw WorkDeskStoreError.projectNotFound }
                    // Adding membership is new project activity, including
                    // source-aware moves and undo. Existing membership may be
                    // reordered or removed while the project is paused.
                    if !(before[id] ?? []).contains(where: { $0.location == record.location }) {
                        try requireActiveDeskProject(projectID, access: access, in: context)
                    }
                }
            }
            desired[id] = records
        }
        // The picture is the visible organizational unit. A folded companion
        // follows the complete location set, even when an older build left its
        // hidden membership behind. Validate everything before touching rows.
        for (parent, child) in companions where desired[child] == nil {
            desired[child] = desired[parent]?.map { record in
                .init(materialID: child, location: record.location, position: record.position, sortRank: record.sortRank)
            }
        }
        for id in desired.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            try writeDeskLocationState(materialID: id, desired: desired[id]!, previous: before[id] ?? [], in: context)
        }
    }

    private nonisolated static func validateDeskLocationOrder(
        _ ordered: [UUID], at location: WorkDeskLocation, in context: NSManagedObjectContext
    ) throws {
        guard Set(ordered).count == ordered.count else { throw WorkDeskStoreError.materialMoved }
        let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
        request.predicate = NSPredicate(format: "workItemID == %@", Constants.workboardDeskItemID as CVarArg)
        let allIDs = Set(try context.fetch(request).compactMap { $0.value(forKey: "id") as? UUID })
        let allLocations = try deskLocationState(materialIDs: allIDs, in: context)
        let hidden = Set(try deskLocationCompanions(for: Array(allIDs), in: context).values)
        let visible = Set(allLocations.filter { $0.value.contains(where: { $0.location == location }) }.keys).subtracting(hidden)
        guard visible == Set(ordered) else { throw WorkDeskStoreError.materialMoved }
    }

    private nonisolated static func deskUndoTokensMatch(
        _ current: [WorkDeskLocationRecord], expected: [WorkDeskLocationRecord]
    ) -> Bool {
        guard current.count == expected.count else { return false }
        return expected.allSatisfy { earlier in
            guard let now = current.first(where: { $0.location == earlier.location && $0.materialID == earlier.materialID }) else { return false }
            return now.matchesForUndo(earlier)
        }
    }

    nonisolated static func deskLocationCompanions(
        for ids: [UUID], in context: NSManagedObjectContext
    ) throws -> [UUID: UUID] {
        guard !ids.isEmpty else { return [:] }
        let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
        request.predicate = NSPredicate(format: "workItemID == %@", Constants.workboardDeskItemID as CVarArg)
        var grouped: [UUID: [NSManagedObject]] = [:]
        for row in try context.fetch(request) {
            if let id = row.value(forKey: "id") as? UUID { grouped[id, default: []].append(row) }
        }
        let selected = Set(ids)
        return deskFoldedCompanions(canonical: grouped.compactMapValues { canonicalRow(among: $0) })
            .filter { selected.contains($0.key) }
    }

    /// Compatibility and capture callers intentionally replace all locations.
    /// Source-aware UI operations go through applyDeskLocationMutation instead.
    nonisolated static func replaceDeskLocations(
        materialIDs: [UUID], projectID: UUID?, in context: NSManagedObjectContext
    ) throws {
        let ids = Set(materialIDs)
        let state = try deskLocationState(materialIDs: ids, in: context)
        let target = projectID.map(WorkDeskLocation.project) ?? .home
        for id in ids {
            let previous = state[id] ?? []
            let rows = try deskRows("WorkDeskPlacement", key: "materialID", id: id, in: context)
            let position = previous.first { $0.location == target }?.position
                ?? (target == .home ? rows.first.flatMap { homePoint(on: $0) } : nil)
            try writeDeskLocationState(materialID: id,
                desired: [.init(materialID: id, location: target, position: position)], previous: previous, in: context)
        }
    }

    nonisolated static func writeDeskLocationState(
        materialID: UUID, desired: [WorkDeskLocationRecord], previous: [WorkDeskLocationRecord],
        seedingPositions: Bool = false, in context: NSManagedObjectContext
    ) throws {
        // Comparing content avoids writing merely because the caller supplied
        // older opaque revision tokens (undo uses new revisions when it writes).
        func appearances(_ records: [WorkDeskLocationRecord]) -> [WorkDeskLocation: DeskLocationAppearance] {
            Dictionary(uniqueKeysWithValues: records.map { ($0.location, .init(position: $0.position, sortRank: $0.sortRank,
                                                                            positionWasSeeded: $0.positionWasSeeded)) })
        }
        guard appearances(desired) != appearances(previous) else { return }
        let legacy = try deskPlacementRows(materialID, in: context)
        if let priorHome = previous.first(where: { $0.location == .home })?.position {
            for row in legacy where homePoint(on: row) == nil { setHomePoint(priorHome, on: row) }
        }
        let rows = try deskRows("WorkDeskLocation", key: "materialID", id: materialID, in: context)
            .sorted(by: deskLocationRowPrecedes)
        var grouped = Dictionary(grouping: rows) { row in
            (row.value(forKey: "projectID") as? UUID).map(WorkDeskLocation.project) ?? .home
        }
        let priorLocations = Set(previous.map(\.location))
        let stamp = advancedWriteStamp(Date(), notBelow: (rows + legacy).compactMap { $0.value(forKey: "updatedAt") as? Date }
            + previous.map(\.updatedAt))
        let pendingProject = try grouped.keys.sorted(by: { $0.sortKey < $1.sortKey }).first { location in
            guard let projectID = location.projectID,
                  grouped[location]?.first?.value(forKey: "isPresent") as? Bool == true else { return false }
            return try resolvedDeskProjectID(projectID, in: context) == nil
        }
        if previous.count == 1, previous.first?.location == .home,
           desired.count == 1, let home = desired.first, home.location == .home,
           grouped[.home]?.first?.value(forKey: "isPresent") as? Bool != true,
           let pending = pendingProject {
            // Automatic fallback layout must not become a real Home reference
            // or remove a project whose record has not arrived. Remember only
            // the safe camera coordinates until that project can be rendered.
            var homeRows = grouped[.home] ?? []
            if homeRows.isEmpty {
                let row = NSEntityDescription.insertNewObject(forEntityName: "WorkDeskLocation", into: context)
                row.setValue(materialID, forKey: "materialID")
                homeRows = [row]
            }
            let revision = seedingPositions ? grouped[.home]?.first?.value(forKey: "revision") as? UUID : UUID()
            for row in homeRows {
                // A missing Home reference may remember layout for orphan
                // presentation without acquiring membership of its own.
                row.setValue(false, forKey: "isPresent")
                setDeskPoint(home.position, on: row)
                row.setValue(home.sortRank, forKey: "sortRank")
                row.setValue(seedingPositions || home.positionWasSeeded, forKey: "positionWasSeeded")
                row.setValue(stamp, forKey: "updatedAt")
                row.setValue(revision, forKey: "revision")
            }
            for row in legacy {
                row.setValue(pending.projectID, forKey: "projectID")
                row.setValue(pending.projectID, forKey: "locationsProjectID")
                row.setValue(stamp, forKey: "locationsProjectedAt")
                row.setValue(stamp, forKey: "updatedAt")
                setHomePoint(home.position, on: row)
                setDeskPoint(grouped[pending]?.first.flatMap { deskPoint(on: $0) }, on: row)
            }
            return
        }
        // Adopt the prior location, including an implicit loose Home, before a
        // move removes it. Its tombstone survives an older client's sync.
        for record in previous where grouped[record.location] == nil {
            let row = NSEntityDescription.insertNewObject(forEntityName: "WorkDeskLocation", into: context)
            row.setValue(materialID, forKey: "materialID")
            row.setValue(record.location.projectID, forKey: "projectID")
            row.setValue(true, forKey: "isPresent")
            row.setValue(record.updatedAt, forKey: "updatedAt")
            row.setValue(record.revision, forKey: "revision")
            row.setValue(record.sortRank, forKey: "sortRank")
            row.setValue(record.positionWasSeeded, forKey: "positionWasSeeded")
            setDeskPoint(record.position, on: row)
            grouped[record.location] = [row]
        }
        let desiredByLocation = Dictionary(uniqueKeysWithValues: desired.map { ($0.location, $0) })
        let locations = Set(grouped.keys).union(desiredByLocation.keys)
        for location in locations {
            let record = desiredByLocation[location]
            let present = record != nil
            let seedsThisPosition = seedingPositions && record?.position != nil
                && previous.first(where: { $0.location == location })?.position == nil
            var entries = grouped[location] ?? []
            // A filtered-out location is not consent to remove it. In
            // particular, an independently arriving project may still be on
            // its way to this device when Home generates its fallback layout.
            if !present, !priorLocations.contains(location), let projectID = location.projectID,
               try resolvedDeskProjectID(projectID, in: context) == nil { continue }
            if let first = entries.first,
               first.value(forKey: "isPresent") as? Bool == present,
               !present || (deskPoint(on: first) == record?.position && finiteDeskSortRank(on: first) == record?.sortRank
                    && (first.value(forKey: "positionWasSeeded") as? Bool ?? false) == (seedsThisPosition || record?.positionWasSeeded == true)) { continue }
            if entries.isEmpty {
                let row = NSEntityDescription.insertNewObject(forEntityName: "WorkDeskLocation", into: context)
                row.setValue(materialID, forKey: "materialID")
                row.setValue(location.projectID, forKey: "projectID")
                entries = [row]
            }
            let revision = seedsThisPosition ? entries.first?.value(forKey: "revision") as? UUID : UUID()
            for row in entries {
                row.setValue(present, forKey: "isPresent")
                setDeskPoint(record?.position, on: row)
                row.setValue(record?.sortRank, forKey: "sortRank")
                row.setValue(seedsThisPosition || record?.positionWasSeeded == true, forKey: "positionWasSeeded")
                row.setValue(stamp, forKey: "updatedAt")
                row.setValue(revision, forKey: "revision")
            }
        }
        // Older clients can render one representative location. Their later
        // edits are interpreted as moves of this representative only.
        guard let projected = desired.sorted(by: { $0.location.sortKey < $1.location.sortKey }).first else { return }
        for row in legacy {
            row.setValue(projected.location.projectID, forKey: "projectID")
            setDeskPoint(projected.location == .home ? nil : projected.position, on: row)
            if let home = desired.first(where: { $0.location == .home }) { setHomePoint(home.position, on: row) }
            row.setValue(projected.location.projectID, forKey: "locationsProjectID")
            row.setValue(stamp, forKey: "locationsProjectedAt")
            row.setValue(stamp, forKey: "updatedAt")
        }
    }

    private nonisolated static func finiteDeskSortRank(on row: NSManagedObject) -> Double? {
        guard let rank = row.value(forKey: "sortRank") as? Double, rank.isFinite else { return nil }
        return rank
    }
}
