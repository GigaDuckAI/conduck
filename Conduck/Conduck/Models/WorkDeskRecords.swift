// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkDeskRecords.swift
//
// Organization is metadata over the existing capture desk. A project never
// owns a material or its bytes; each material's placement is an independently
// mirrored row. Missing projects therefore cannot hide captured work. Project
// deletion leaves an identity-only tombstone so an offline placement arriving
// later cannot bring a deleted project back. Desk positions extend in every
// direction from the origin, with finite bounds for malformed imported values.

import Foundation

nonisolated struct WorkDeskPoint: Codable, Hashable, Sendable {
    static let coordinateLimit: Double = 20_000
    let x: Double
    let y: Double

    init(x: Double, y: Double) {
        self.x = Self.bounded(x)
        self.y = Self.bounded(y)
    }

    private static func bounded(_ value: Double) -> Double {
        value.isFinite ? min(max(value, -coordinateLimit), coordinateLimit) : 0
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(x: try values.decode(Double.self, forKey: .x),
                  y: try values.decode(Double.self, forKey: .y))
    }
}

nonisolated struct WorkDeskProjectRecord: Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    var brief: String
    var preferredGatewayRef: String?
    var position: WorkDeskPoint?
    var isPinned: Bool
    let createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), title: String, brief: String = "",
         preferredGatewayRef: String? = nil, position: WorkDeskPoint? = nil,
         isPinned: Bool = false, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.brief = brief
        self.preferredGatewayRef = preferredGatewayRef
        self.position = position
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

nonisolated struct WorkDeskPlacementRecord: Identifiable, Hashable, Sendable {
    var id: UUID { materialID }
    let materialID: UUID
    var projectID: UUID?
    var position: WorkDeskPoint?
    var homePosition: WorkDeskPoint?
    var isPinned: Bool
    var updatedAt: Date

    init(materialID: UUID, projectID: UUID? = nil, position: WorkDeskPoint? = nil,
         homePosition: WorkDeskPoint? = nil, isPinned: Bool = false, updatedAt: Date = Date()) {
        self.materialID = materialID
        self.projectID = projectID
        self.position = position
        self.homePosition = homePosition
        self.isPinned = isPinned
        self.updatedAt = updatedAt
    }
    /// Older loose placements are already in home coordinates. Project-local
    /// coordinates must never be interpreted as positions on All materials.
    var resolvedHomePosition: WorkDeskPoint? {
        homePosition ?? (projectID == nil ? position : nil)
    }
}

nonisolated struct WorkDeskOrganizationSnapshot: Sendable, Equatable {
    var projects: [WorkDeskProjectRecord] = []
    var placements: [UUID: WorkDeskPlacementRecord] = [:]
    // Absence from a snapshot can mean another window just created a project.
    // Only durable deletion evidence may erase process-wide preferences.
    var deletedProjectIDs: Set<UUID> = []
}

/// A generated slot belongs to the project scope that generated it. A late
/// layout pass cannot put a card into that slot after the user moved it to a
/// different project, or overwrite a position another device already saved.
nonisolated struct WorkDeskPositionSeed: Sendable, Hashable {
    let materialID: UUID
    let projectID: UUID?
    let position: WorkDeskPoint
    var isHome: Bool = false
}

/// Intent-specific writes change only the fields the person acted on. Moving
/// a card must not write an old copy of its project membership or pin state.
nonisolated enum WorkDeskMutation: Sendable {
    case createProject(WorkDeskProjectRecord, materialIDs: [UUID])
    case updateProject(id: UUID, title: String, brief: String, preferredGatewayRef: String?, expectedUpdatedAt: Date? = nil)
    case deleteProject(id: UUID)
    case assign(materialIDs: [UUID], projectID: UUID?)
    case moveMaterial(id: UUID, position: WorkDeskPoint?)
    /// A selected group moves only while every member still belongs to the
    /// scope where its drag began. One stale member refuses the whole move.
    case moveMaterials(positions: [UUID: WorkDeskPoint], expectedProjectID: UUID?)
    /// All materials spans projects. Each captured membership is validated
    /// before this atomic move writes only the independent home coordinates.
    case moveHomeMaterials([WorkDeskPositionSeed])
    case pinMaterial(id: UUID, isPinned: Bool)
    case moveProject(id: UUID, position: WorkDeskPoint?)
    case pinProject(id: UUID, isPinned: Bool)
    case seedPositions(materials: [WorkDeskPositionSeed], projects: [UUID: WorkDeskPoint])
}

nonisolated enum WorkDeskStoreError: Error, Equatable, LocalizedError {
    case projectNotFound
    case materialNotFound
    case materialMoved
    case invalidTitle
    case contentTooLong
    case identifierCollision
    case staleProject

    var errorDescription: String? {
        switch self {
        case .projectNotFound:
            String(localized: "workdesk.error.projectMissing", defaultValue: "That project is no longer available. Your ideas are still on the desk.")
        case .materialNotFound:
            String(localized: "workdesk.error.materialMissing", defaultValue: "An item has changed or been removed. Refresh the desk and try again.")
        case .materialMoved:
            String(localized: "workdesk.error.materialMoved", defaultValue: "An item moved to another project. Refresh the desk and try again.")
        case .invalidTitle:
            String(localized: "workdesk.error.title", defaultValue: "Give the project a name.")
        case .contentTooLong:
            String(localized: "workdesk.error.textLength", defaultValue: "Shorten the project name or brief, then try again.")
        case .identifierCollision:
            String(localized: "workdesk.error.conflict", defaultValue: "The desk changed. Try that action again.")
        case .staleProject:
            String(localized: "workdesk.error.projectChanged", defaultValue: "This project changed while you were editing. Reopen it to use the latest version.")
        }
    }
}
