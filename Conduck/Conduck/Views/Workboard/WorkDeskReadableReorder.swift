// SPDX-License-Identifier: Apache-2.0

// Tiles and List reorder by a visible neighbour, never by a stale array index.
// Hover draws an insertion edge without reflowing the lazy layout or writing
// order. A cancelled drag therefore needs no rollback and an unmeasured row
// cannot turn a drop into a move to the beginning. Provider decoding is scoped
// to the view that accepted it; a late callback cannot reorder another project.
// The existing desk mutation lane owns rank persistence and folded companions.
// A typed drag from another location first files that same material here; an
// older reorder-only payload never guesses which membership should be removed.

import SwiftUI
import Observation
import UniformTypeIdentifiers

struct WorkDeskReadableDropTarget: Equatable {
    let materialID: UUID
    let placement: WorkboardReorderPlacement
    var isTrailing = false
    // Captured only at release; hover targets stay independent of pointer
    // movement so insertion feedback does not needlessly redraw on every tick.
    var globalPoint: CGPoint? = nil
}

/// Native delegates report points local to their receiving card. A preview's
/// occlusion is registered globally, so both readable cards and scaled canvas
/// folders translate through measured geometry before accepting a destination.
nonisolated struct WorkDeskNativeDropGeometry: Equatable, Sendable {
    var localSize: CGSize = .zero
    var globalFrame: CGRect = .zero

    func globalPoint(for point: CGPoint) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite,
              localSize.width.isFinite, localSize.height.isFinite,
              localSize.width > 0, localSize.height > 0,
              globalFrame.minX.isFinite, globalFrame.minY.isFinite,
              globalFrame.width.isFinite, globalFrame.height.isFinite,
              globalFrame.width > 0, globalFrame.height > 0,
              point.x >= 0, point.y >= 0,
              point.x <= localSize.width, point.y <= localSize.height else { return nil }
        let globalPoint = CGPoint(x: globalFrame.minX + point.x / localSize.width * globalFrame.width,
                                  y: globalFrame.minY + point.y / localSize.height * globalFrame.height)
        return globalPoint.x.isFinite && globalPoint.y.isFinite ? globalPoint : nil
    }
}

struct WorkDeskReadableReorderContext: Equatable {
    let scope: WorkDeskScope
    let search: String
    let layout: WorkboardLayoutMode
    let visibleIDs: [UUID]
    let projectIDs: [UUID: UUID]
    var locationTokens: WorkDeskLocationTokens? = nil

    func stillContains(_ materialID: UUID, asIn previous: Self) -> Bool {
        guard scope == previous.scope && search == previous.search && layout == previous.layout
            && visibleIDs.contains(materialID) && previous.visibleIDs.contains(materialID)
            && projectIDs[materialID] == previous.projectIDs[materialID] else { return false }
        if let current = locationTokens, let earlier = previous.locationTokens {
            return Set(current[materialID] ?? []) == Set(earlier[materialID] ?? [])
        }
        return true
    }
}

enum WorkDeskReadableDropOperation: Equatable {
    case reorder(WorkDeskReadableDropTarget)
    case move(WorkDeskReadableDropTarget, WorkDeskMaterialLocationMove)
}

@Observable @MainActor
final class WorkDeskReadableReorder {
    private(set) var target: WorkDeskReadableDropTarget?
    private(set) var sourceID: UUID?
    private var pending: Pending?

    private struct Pending {
        let id: UUID
        let target: WorkDeskReadableDropTarget
        let context: WorkDeskReadableReorderContext
    }

    var isResolving: Bool { pending != nil }

    func begin(_ materialID: UUID) {
        cancel()
        sourceID = materialID
    }

    func hover(_ proposed: WorkDeskReadableDropTarget) {
        guard pending == nil else { return }
        target = proposed.materialID == sourceID ? nil : proposed
    }

    func leave(materialID: UUID, isTrailing: Bool = false) {
        guard target?.materialID == materialID, target?.isTrailing == isTrailing else { return }
        target = nil
    }

    func cancel() {
        target = nil
        sourceID = nil
        pending = nil
    }

    func accept(_ target: WorkDeskReadableDropTarget, context: WorkDeskReadableReorderContext) -> UUID? {
        guard pending == nil, context.visibleIDs.contains(target.materialID) else { return nil }
        let id = UUID()
        pending = Pending(id: id, target: target, context: context)
        self.target = nil
        sourceID = nil
        return id
    }

    /// Taking the pending request before returning makes even a provider that
    /// calls its completion twice incapable of applying two moves. Cancelling
    /// and beginning another drag also leaves its newer pending request alone.
    func resolve(_ payload: WorkMaterialDragPayload?, token: UUID,
                 current: WorkDeskReadableReorderContext, isEnabled: Bool) -> WorkDeskReadableDropTarget? {
        guard case .reorder(let target) = resolveOperation(payload, token: token, current: current,
            isEnabled: isEnabled, locations: current.locationTokens ?? [:]) else { return nil }
        return target
    }

    func resolveOperation(_ payload: WorkMaterialDragPayload?, token: UUID,
                          current: WorkDeskReadableReorderContext, isEnabled: Bool,
                          locations: WorkDeskLocationTokens) -> WorkDeskReadableDropOperation? {
        guard let accepted = pending, accepted.id == token else { return nil }
        pending = nil
        guard isEnabled, let payload,
              payload.itemID == Constants.workboardDeskItemID,
              !payload.materialIDs.contains(accepted.target.materialID),
              current.stillContains(accepted.target.materialID, asIn: accepted.context) else { return nil }
        if let source = payload.sourceLocation {
            guard let move = payload.validatedLocationMove(to: current.scope.location, current: locations) else { return nil }
            if source != current.scope.location {
                guard current.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return .move(accepted.target, move)
            }
        }
        guard payload.materialIDs.count == 1,
              current.stillContains(payload.materialID, asIn: accepted.context) else { return nil }
        return .reorder(accepted.target)
    }

    static func placement(at point: CGPoint, size: CGSize, layout: WorkboardLayoutMode,
                          direction: LayoutDirection) -> WorkboardReorderPlacement? {
        guard point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        if layout == .list { return point.y < size.height / 2 ? .before : .after }
        guard layout == .tiles else { return nil }
        let inFirstHalf = point.x < size.width / 2
        return (direction == .leftToRight ? inFirstHalf : !inFirstHalf) ? .before : .after
    }
}

/// The modifier encloses the complete card, including its visible grip. It
/// adds native drag-and-drop rather than a competing tap/drag recognizer, so
/// the card's menu, playback and metadata buttons retain their own actions.
struct WorkDeskReadableReorderCard: ViewModifier {
    let materialID: UUID
    let layout: WorkboardLayoutMode
    let isEnabled: Bool
    let reorder: WorkDeskReadableReorder
    let onBegin: () -> NSItemProvider
    let onDrop: (NSItemProvider, WorkDeskReadableDropTarget) -> Bool
    var acceptsPoint: (CGPoint) -> Bool = { _ in true }
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var geometry = WorkDeskNativeDropGeometry()

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onGeometryChange(for: WorkDeskNativeDropGeometry.self) {
                .init(localSize: $0.size, globalFrame: $0.frame(in: .global))
            } action: { geometry = $0 }
            .onDrag { isEnabled ? onBegin() : NSItemProvider() }
            .onDrop(of: [.conduckWorkboardMaterial], delegate: WorkboardReorderDropDelegate(
                isEnabled: isEnabled && !reorder.isResolving,
                onLocation: { point in
                    guard let point, let globalPoint = geometry.globalPoint(for: point),
                          acceptsPoint(globalPoint), let placement = placement(at: point) else {
                        reorder.leave(materialID: materialID)
                        return
                    }
                    reorder.hover(.init(materialID: materialID, placement: placement))
                },
                onDrop: { provider, point in
                    guard let globalPoint = geometry.globalPoint(for: point), acceptsPoint(globalPoint),
                          let placement = placement(at: point) else { return false }
                    return onDrop(provider, .init(materialID: materialID, placement: placement,
                                                 globalPoint: globalPoint))
                }
            ))
            .overlay(alignment: insertionAlignment) {
                if let target = reorder.target, target.materialID == materialID, !target.isTrailing {
                    Capsule().fill(AppColors.accent)
                        .frame(width: layout == .tiles ? 3 : nil, height: layout == .list ? 3 : nil)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            #if os(macOS)
            .pointerStyle(isEnabled ? .grabIdle : .default)
            #endif
    }

    private func placement(at point: CGPoint) -> WorkboardReorderPlacement? {
        WorkDeskReadableReorder.placement(at: point, size: geometry.localSize,
                                         layout: layout, direction: layoutDirection)
    }

    private var insertionAlignment: Alignment {
        let isBefore = reorder.target?.placement == .before
        if layout == .list { return isBefore ? .top : .bottom }
        return isBefore ? .leading : .trailing
    }
}
