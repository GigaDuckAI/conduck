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

/// Built with the board projection, not by each overlay on every pointer tick.
struct WorkDeskReadableOrderIndex {
    let ids: [UUID]
    let indices: [UUID: Int]

    init(_ ids: [UUID]) {
        self.ids = ids
        indices = Dictionary(ids.enumerated().map { ($0.element, $0.offset) },
                             uniquingKeysWith: { first, _ in first })
    }
}

struct WorkDeskReadableDropTarget: Equatable {
    let materialID: UUID
    let placement: WorkboardReorderPlacement
    var isTrailing = false
    var edge: WorkDeskReadableInsertionEdge? = nil
    // Captured only at release; hover targets stay independent of pointer
    // movement so insertion feedback does not needlessly redraw on every tick.
    var globalPoint: CGPoint? = nil
}

/// The visual edge is independent of persisted reading order. Top/bottom
/// remain before/after in either language direction; side edges follow it.
enum WorkDeskReadableInsertionEdge: Equatable {
    case top, bottom, leading, trailing

    var placement: WorkboardReorderPlacement {
        switch self {
        case .top, .leading: .before
        case .bottom, .trailing: .after
        }
    }

    var alignment: Alignment {
        switch self {
        case .top: .top
        case .bottom: .bottom
        case .leading: .leading
        case .trailing: .trailing
        }
    }

    var isHorizontal: Bool { self == .top || self == .bottom }
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
    private final class WeakInstance {
        weak var value: WorkDeskReadableReorder?
        init(_ value: WorkDeskReadableReorder) { self.value = value }
    }
    private static var instances: [WeakInstance] = []

    init() {
        Self.instances.removeAll { $0.value == nil }
        Self.instances.append(WeakInstance(self))
    }

    /// A native drag has one source across all windows. SwiftUI onDrag has no
    /// end callback, so every native source clears the previous session's
    /// feedback when it begins. Accepted provider requests keep their ownership.
    static func clearDragFeedback() {
        instances.removeAll { $0.value == nil }
        for instance in instances {
            instance.value?.target = nil
            instance.value?.sourceID = nil
        }
    }

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
        Self.clearDragFeedback()
        cancel()
        sourceID = materialID
    }

    func hover(_ proposed: WorkDeskReadableDropTarget) {
        guard pending == nil else { return }
        let next = proposed.materialID == sourceID ? nil : proposed
        guard target != next else { return }
        target = next
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

    /// The source will occupy this existing grid cell after its own removal
    /// shifts the insertion index. Only a known same-board drag has a fixed
    /// destination count; cross-location drops retain their edge/append cue.
    static func landingSlot(sourceID: UUID?, target: WorkDeskReadableDropTarget?, order: WorkDeskReadableOrderIndex) -> UUID? {
        guard let sourceID, let target,
              let sourceIndex = order.indices[sourceID],
              let targetIndex = order.indices[target.materialID] else { return nil }
        let slot = targetIndex + (target.placement == .after ? 1 : 0)
        let destination = slot > sourceIndex ? slot - 1 : slot
        guard destination != sourceIndex, order.ids.indices.contains(destination) else { return nil }
        return order.ids[destination]
    }

    static func placement(at point: CGPoint, size: CGSize, layout: WorkboardLayoutMode,
                          direction: LayoutDirection) -> WorkboardReorderPlacement? {
        insertionEdge(at: point, size: size, layout: layout, direction: direction)?.placement
    }

    /// Stable top/bottom strips give a deliberate vertical destination. The
    /// middle stays split in reading direction instead of changing diagonally
    /// as the pointer crosses a tall tile. No layout or order changes on hover.
    static func insertionEdge(at point: CGPoint, size: CGSize, layout: WorkboardLayoutMode,
                              direction: LayoutDirection) -> WorkDeskReadableInsertionEdge? {
        guard point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              point.x >= 0, point.y >= 0, point.x <= size.width, point.y <= size.height else { return nil }
        if layout == .list { return point.y < size.height / 2 ? .top : .bottom }
        guard layout == .tiles else { return nil }
        if point.y < size.height * 0.22 { return .top }
        if point.y > size.height * 0.78 { return .bottom }
        let inFirstHalf = point.x < size.width / 2
        return (direction == .leftToRight ? inFirstHalf : !inFirstHalf) ? .leading : .trailing
    }
}

/// The modifier encloses the complete card. It
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
    var dragPreviewTitle = ""
    var dragPreviewSymbol = "doc"
    var orderIndex = WorkDeskReadableOrderIndex([])
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var geometry = WorkDeskNativeDropGeometry()

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onGeometryChange(for: WorkDeskNativeDropGeometry.self) {
                .init(localSize: $0.size, globalFrame: $0.frame(in: .global))
            } action: { geometry = $0 }
            .onDrag { isEnabled ? onBegin() : NSItemProvider() } preview: {
                WorkDeskReadableDragPreview(title: dragPreviewTitle, symbol: dragPreviewSymbol)
            }
            .onDrop(of: [.conduckWorkboardMaterial], delegate: WorkboardReorderDropDelegate(
                isEnabled: isEnabled && !reorder.isResolving,
                onLocation: { point in
                    guard let point, let globalPoint = geometry.globalPoint(for: point),
                          acceptsPoint(globalPoint), let edge = insertionEdge(at: point) else {
                        reorder.leave(materialID: materialID)
                        return
                    }
                    reorder.hover(.init(materialID: materialID, placement: edge.placement, edge: edge))
                },
                onDrop: { provider, point in
                    guard let globalPoint = geometry.globalPoint(for: point), acceptsPoint(globalPoint),
                          let edge = insertionEdge(at: point) else { return false }
                    return onDrop(provider, .init(materialID: materialID, placement: edge.placement,
                                                 edge: edge, globalPoint: globalPoint))
                }
            ))
            .overlay {
                WorkDeskReadableInsertionIndicator(materialID: materialID, layout: layout, reorder: reorder)
            }
            .overlay {
                if layout == .tiles {
                    WorkDeskReadableLandingIndicator(materialID: materialID, orderIndex: orderIndex, reorder: reorder)
                }
            }
            #if os(macOS)
            .pointerStyle(isEnabled ? .grabIdle : .default)
            #endif
    }

    private func insertionEdge(at point: CGPoint) -> WorkDeskReadableInsertionEdge? {
        WorkDeskReadableReorder.insertionEdge(at: point, size: geometry.localSize,
                                             layout: layout, direction: layoutDirection)
    }
}

/// Only this small layer observes the changing insertion target. Pointer
/// movement must not rebuild the card's menus, media or board projection.
private struct WorkDeskReadableInsertionIndicator: View {
    let materialID: UUID
    let layout: WorkboardLayoutMode
    let reorder: WorkDeskReadableReorder
    var isTrailing = false

    var body: some View {
        if let target = reorder.target, target.materialID == materialID, target.isTrailing == isTrailing {
            let edge = target.edge ?? (isTrailing ? .top : layout == .list
                ? (target.placement == .before ? .top : .bottom)
                : (target.placement == .before ? .leading : .trailing))
            Capsule().fill(AppColors.accent.opacity(layout == .tiles ? 0.55 : 1))
                .frame(width: edge.isHorizontal ? nil : 3, height: edge.isHorizontal ? 3 : nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edge.alignment)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// The edge communicates before/after; this outline marks the actual landing
/// cell in a row-major grid. It reads hover state without rebuilding card media.
private struct WorkDeskReadableLandingIndicator: View {
    let materialID: UUID
    let orderIndex: WorkDeskReadableOrderIndex
    let reorder: WorkDeskReadableReorder

    var body: some View {
        if WorkDeskReadableReorder.landingSlot(sourceID: reorder.sourceID,
            target: reorder.target, order: orderIndex) == materialID {
            RoundedRectangle(cornerRadius: 13)
                .fill(AppColors.accent.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: 13)
                        .strokeBorder(AppColors.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// A bounded lightweight native preview avoids snapshotting a full-width row
/// or its host hierarchy. It never decodes media or creates playback controls.
private struct WorkDeskReadableDragPreview: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(AppColors.accent)
            Text(verbatim: title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(12)
        .frame(width: 200, alignment: .leading)
        .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 13))
    }
}

/// A final append destination remains in the scroll content for native
/// autoscroll. It owns its measured geometry and hover observation locally.
struct WorkDeskReadableTrailingDropTarget: View {
    let materialID: UUID
    let isEnabled: Bool
    let reorder: WorkDeskReadableReorder
    let acceptsPoint: (CGPoint) -> Bool
    let onDrop: (NSItemProvider, WorkDeskReadableDropTarget) -> Bool
    @State private var geometry = WorkDeskNativeDropGeometry()

    private var target: WorkDeskReadableDropTarget {
        .init(materialID: materialID, placement: .after, isTrailing: true)
    }

    var body: some View {
        Color.clear
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onGeometryChange(for: WorkDeskNativeDropGeometry.self) {
                .init(localSize: $0.size, globalFrame: $0.frame(in: .global))
            } action: { geometry = $0 }
            .onDrop(of: [.conduckWorkboardMaterial], delegate: WorkboardReorderDropDelegate(
                isEnabled: isEnabled && !reorder.isResolving,
                onLocation: { point in
                    if let point, let global = geometry.globalPoint(for: point), acceptsPoint(global) {
                        reorder.hover(target)
                    } else {
                        reorder.leave(materialID: materialID, isTrailing: true)
                    }
                },
                onDrop: { provider, point in
                    guard let global = geometry.globalPoint(for: point), acceptsPoint(global) else { return false }
                    var released = target
                    released.globalPoint = global
                    return onDrop(provider, released)
                }
            ))
            .overlay {
                WorkDeskReadableInsertionIndicator(materialID: materialID, layout: .list,
                                                   reorder: reorder, isTrailing: true)
            }
            .accessibilityHidden(true)
    }
}
