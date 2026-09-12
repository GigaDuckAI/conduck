// SPDX-License-Identifier: Apache-2.0

// One workspace-owned drag crosses independent canvases without replacing their
// whole-card placement gesture. Global rectangles are the shared coordinate
// system; each destination alone converts a release back to its own desk.
// Tray chrome occludes the underlying desk, and invalid/outside releases cancel
// instead of filing through a panel or persisting an offscreen source position.

import SwiftUI
import Observation

struct WorkDeskTransferRequest: Equatable {
    let materialIDs: [UUID]
    let source: WorkDeskLocation
    let destination: WorkDeskLocation
    let positions: [UUID: WorkDeskPoint]
    var expected: WorkDeskLocationTokens? = nil
}

struct WorkDeskTransferItemTarget: Equatable {
    let id: WorkDeskCanvasItemID
    let title: String
    let frame: CGRect
    let layer: Double
}

struct WorkDeskTransferSurface: Equatable {
    let id: UUID
    let location: WorkDeskLocation
    let title: String
    let frame: CGRect
    var transform = WorkDeskCanvasTransform()
    var priority = 0
    var isSpatial = true
    var items: [WorkDeskTransferItemTarget] = []
    var exclusions: [CGRect] = []
}

struct WorkDeskTransferDestination: Equatable {
    let surfaceID: UUID
    let location: WorkDeskLocation
    let title: String
    let frame: CGRect
    let transform: WorkDeskCanvasTransform
    let isSpatial: Bool
    let itemID: WorkDeskCanvasItemID?
}

struct WorkDeskTransferDrag {
    let sourceSurfaceID: UUID
    let source: WorkDeskLocation
    let leadMaterial: WorkboardMaterialSnapshot
    let origins: [UUID: WorkDeskPoint]
    let gripFraction: CGPoint
    var expected: WorkDeskLocationTokens? = nil
    var pointer: CGPoint
    var leadFrame: CGRect
    var materialIDs: [UUID] { origins.keys.sorted { $0.uuidString < $1.uuidString } }
}

enum WorkDeskTransferRelease {
    case local
    case transfer(WorkDeskTransferRequest)
    case cancelled
}

@MainActor @Observable
final class WorkDeskTransferCoordinator {
    private(set) var drag: WorkDeskTransferDrag?
    private(set) var destination: WorkDeskTransferDestination?
    private(set) var geometryRevision = 0
    @ObservationIgnored private var surfaces: [UUID: WorkDeskTransferSurface] = [:]
    @ObservationIgnored private var occlusions: [UUID: (frame: CGRect, priority: Int)] = [:]

    var isDragging: Bool { drag != nil }

    func projectFrame(id: UUID) -> CGRect? {
        _ = geometryRevision
        return surfaces.values.sorted { $0.priority > $1.priority }
            .flatMap(\.items).first { $0.id == .project(id) }?.frame
    }

    func containsSurface(at point: CGPoint) -> Bool {
        _ = geometryRevision
        return surfaces.values.contains { $0.frame.contains(point) }
    }

    func isOccluded(at point: CGPoint) -> Bool {
        _ = geometryRevision
        return occlusions.values.contains { $0.frame.contains(point) }
    }

    func register(_ surface: WorkDeskTransferSurface) {
        guard surface.frame.isFiniteAndPositive else { removeSurface(id: surface.id); return }
        guard surfaces[surface.id] != surface else { return }
        surfaces[surface.id] = surface
        geometryRevision &+= 1
        resolveDrag()
    }

    func removeSurface(id: UUID) {
        guard surfaces.removeValue(forKey: id) != nil else { return }
        geometryRevision &+= 1
        if drag?.sourceSurfaceID == id { cancel() }
        else { resolveDrag() }
    }

    func registerOcclusion(id: UUID, frame: CGRect, priority: Int) {
        guard frame.isFiniteAndPositive else { removeOcclusion(id: id); return }
        guard occlusions[id]?.frame != frame || occlusions[id]?.priority != priority else { return }
        occlusions[id] = (frame, priority)
        geometryRevision &+= 1
        resolveDrag()
    }

    func removeOcclusion(id: UUID) {
        guard occlusions.removeValue(forKey: id) != nil else { return }
        geometryRevision &+= 1
        resolveDrag()
    }

    /// Used by native file drops as well as custom material movement. A header,
    /// control, or foreground material blocks a project that happens to be below it.
    func destination(at point: CGPoint, excluding materialIDs: Set<UUID> = []) -> WorkDeskTransferDestination? {
        _ = geometryRevision
        guard point.x.isFinite, point.y.isFinite,
              let surface = surfaces.values.filter({ $0.frame.contains(point) }).max(by: {
                  $0.priority == $1.priority ? $0.id.uuidString < $1.id.uuidString : $0.priority < $1.priority
              }) else { return nil }
        guard !occlusions.values.contains(where: { $0.priority >= surface.priority && $0.frame.contains(point) }),
              !surface.exclusions.contains(where: { $0.contains(point) }) else { return nil }
        let front = surface.items.filter { item in
            item.frame.contains(point) && (item.id.isProject || !materialIDs.contains(item.id.id))
        }.max { $0.layer == $1.layer ? $0.id.sortKey < $1.id.sortKey : $0.layer < $1.layer }
        if let front, case .project(let projectID) = front.id {
            return WorkDeskTransferDestination(surfaceID: surface.id, location: .project(projectID),
                title: front.title, frame: front.frame, transform: surface.transform,
                isSpatial: false, itemID: front.id)
        }
        return WorkDeskTransferDestination(surfaceID: surface.id, location: surface.location,
            title: surface.title, frame: surface.frame, transform: surface.transform,
            isSpatial: surface.isSpatial, itemID: nil)
    }

    /// Input monitors use these rectangles too, so scrolling over a tray never
    /// changes the camera of the desk behind it.
    func occludedRects(above priority: Int, in frame: CGRect) -> [CGRect] {
        _ = geometryRevision
        let blockers = occlusions.values.filter { $0.priority > priority }.map(\.frame)
            + surfaces.values.filter { $0.priority > priority }.map(\.frame)
        return blockers.filter { $0.intersects(frame) }.map {
            $0.offsetBy(dx: -frame.minX, dy: -frame.minY)
        }
    }

    func update(sourceSurfaceID: UUID, source: WorkDeskLocation, leadMaterial: WorkboardMaterialSnapshot,
                origins: [UUID: WorkDeskPoint], pointer: CGPoint, leadFrame: CGRect,
                expected: WorkDeskLocationTokens? = nil) {
        guard pointer.x.isFinite, pointer.y.isFinite, leadFrame.isFiniteAndPositive,
              origins[leadMaterial.id] != nil, surfaces[sourceSurfaceID] != nil else { return }
        if let active = drag {
            guard active.sourceSurfaceID == sourceSurfaceID else { return }
            drag?.pointer = pointer
            drag?.leadFrame = leadFrame
        } else {
            let grip = CGPoint(x: min(1, max(0, (pointer.x - leadFrame.minX) / leadFrame.width)),
                               y: min(1, max(0, (pointer.y - leadFrame.minY) / leadFrame.height)))
            drag = WorkDeskTransferDrag(sourceSurfaceID: sourceSurfaceID, source: source,
                leadMaterial: leadMaterial, origins: origins, gripFraction: grip,
                expected: expected, pointer: pointer, leadFrame: leadFrame)
        }
        resolveDrag()
    }

    func isLocal(to surfaceID: UUID) -> Bool {
        guard let drag, let destination else { return false }
        return drag.sourceSurfaceID == surfaceID && destination.surfaceID == surfaceID
            && destination.location == drag.source && destination.itemID == nil
    }

    func highlightedProject(in surfaceID: UUID) -> UUID? {
        guard drag != nil, let destination, destination.surfaceID == surfaceID,
              case .project(let id) = destination.itemID else { return nil }
        return id
    }

    func release(sourceSurfaceID: UUID) -> WorkDeskTransferRelease {
        guard let drag, drag.sourceSurfaceID == sourceSurfaceID else { return .local }
        defer { cancel() }
        guard let destination else { return .cancelled }
        if isLocal(to: sourceSurfaceID) { return .local }
        // Dropping onto another representation of the same container cannot
        // remove and recreate its membership or silently reset its arrangement.
        guard destination.location != drag.source else { return .cancelled }
        return .transfer(WorkDeskTransferRequest(materialIDs: drag.materialIDs, source: drag.source,
            destination: destination.location, positions: Self.positions(for: drag, at: destination), expected: drag.expected))
    }

    func cancel(sourceSurfaceID: UUID? = nil) {
        if let sourceSurfaceID, drag?.sourceSurfaceID != sourceSurfaceID { return }
        drag = nil
        destination = nil
    }

    private func resolveDrag() {
        guard let drag else { destination = nil; return }
        destination = destination(at: drag.pointer, excluding: Set(drag.materialIDs))
    }

    static func positions(for drag: WorkDeskTransferDrag, at destination: WorkDeskTransferDestination) -> [UUID: WorkDeskPoint] {
        guard destination.isSpatial, let lead = drag.origins[drag.leadMaterial.id] else { return [:] }
        let size = WorkDeskCanvasGeometry.screenSize(bodySize: WorkDeskCanvasGeometry.cardBodySize,
                                                   scale: destination.transform.scale)
        let local = CGPoint(x: drag.pointer.x - destination.frame.minX - size.width * drag.gripFraction.x,
                            y: drag.pointer.y - destination.frame.minY - size.height * drag.gripFraction.y)
        let point = WorkDeskCanvasGeometry.worldPoint(local, transform: destination.transform)
        return WorkDeskCanvasGeometry.translated(drag.origins,
            by: CGSize(width: point.x - lead.x, height: point.y - lead.y))
    }
}

/// The source canvas clips its contents. This noninteractive workspace overlay
/// keeps the held material visible over another canvas, including blocked chrome.
struct WorkDeskTransferOverlay: View {
    let coordinator: WorkDeskTransferCoordinator

    var body: some View {
        GeometryReader { proxy in
            if let drag = coordinator.drag, !coordinator.isLocal(to: drag.sourceSurfaceID) {
                let local = CGPoint(x: drag.pointer.x - proxy.frame(in: .global).minX,
                                    y: drag.pointer.y - proxy.frame(in: .global).minY)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: drag.leadMaterial.kind.systemImage)
                            .font(.title3).foregroundStyle(AppColors.brandAmber)
                        Text(verbatim: drag.leadMaterial.name)
                            .font(.subheadline.weight(.semibold)).lineLimit(2)
                        if drag.materialIDs.count > 1 {
                            Text(verbatim: "+\(drag.materialIDs.count - 1)")
                                .font(.caption.monospacedDigit())
                        }
                    }
                    if let destination = coordinator.destination, destination.location != drag.source {
                        Label {
                            Text(LocalizedStringResource("workdesk.transfer.moveTo", defaultValue: "Move to \(destination.title)"))
                        } icon: { Image(systemName: "arrow.turn.down.right") }
                        .font(.caption).foregroundStyle(AppColors.brandAmber)
                    } else {
                        Text(LocalizedStringResource("workdesk.transfer.cancelHint", defaultValue: "Release here to cancel"))
                            .font(.caption).foregroundStyle(AppColors.textSecondary)
                    }
                }
                .foregroundStyle(AppColors.textPrimary)
                .padding(14)
                .frame(width: min(252, max(120, proxy.size.width - 24)), alignment: .leading)
                .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 15))
                .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(AppColors.brandAmber.opacity(0.65)) }
                .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
                .position(x: min(max(138, local.x + 32), max(138, proxy.size.width - 138)),
                          y: min(max(55, local.y - 58), max(55, proxy.size.height - 55)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private extension CGRect {
    var isFiniteAndPositive: Bool {
        minX.isFinite && minY.isFinite && width.isFinite && height.isFinite && width > 0 && height > 0
    }
}
