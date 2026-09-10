// SPDX-License-Identifier: Apache-2.0

// A viewport onto the private desk. Positions are top-left coordinates in desk
// space; gestures alone hold transient movement, and only release calls the
// persistence owner. External file drops remain the containing Work pane's job.
// Existing material views are injected so preview, sharing and repair retain
// their original availability gates. Project piles are organization, never a
// copy of the underlying materials.

import SwiftUI

struct WorkDeskCanvasProject: Identifiable {
    let record: WorkDeskProjectRecord
    let materialCount: Int
    var id: UUID { record.id }
}

nonisolated struct WorkDeskCanvasTransform: Equatable {
    var scale: CGFloat = 1
    var offset: CGSize = .zero
}

/// Shared drawing and hit-testing arithmetic. Coordinates remain finite and
/// bounded even when imported metadata or a cancelled gesture is malformed.
nonisolated enum WorkDeskCanvasGeometry {
    static let minimumScale: CGFloat = 0.01
    static let maximumScale: CGFloat = 1.6
    static let coordinateLimit = WorkDeskPoint.coordinateLimit
    static let overviewThreshold: CGFloat = 0.35
    static let cardBodySize = CGSize(width: 232, height: 238)
    static let projectBodySize = CGSize(width: 232, height: 168)
    static let handleHeight: CGFloat = 44

    static func visibleHandleHeight(scale: CGFloat) -> CGFloat {
        scale < overviewThreshold ? 0 : handleHeight
    }

    static func boundedScale(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite else { return 1 }
        return min(max(scale, minimumScale), maximumScale)
    }

    static func bounded(_ point: WorkDeskPoint) -> WorkDeskPoint {
        WorkDeskPoint(
            x: point.x.isFinite ? min(max(point.x, 0), coordinateLimit) : 0,
            y: point.y.isFinite ? min(max(point.y, 0), coordinateLimit) : 0
        )
    }

    static func moved(_ point: WorkDeskPoint, by translation: CGSize, scale: CGFloat) -> WorkDeskPoint {
        let zoom = boundedScale(scale)
        return bounded(WorkDeskPoint(
            x: point.x + Double(translation.width / zoom),
            y: point.y + Double(translation.height / zoom)
        ))
    }

    static func defaultPoint(index: Int, columns: Int) -> WorkDeskPoint {
        let columnCount = max(1, columns)
        let slot = max(0, index)
        return WorkDeskPoint(
            x: 28 + Double(slot % columnCount) * 264,
            y: 26 + Double(slot / columnCount) * 340
        )
    }

    /// Finds an unoccupied slot using actual persisted frames, not the count of
    /// remaining cards. Deleting an early card must not put the next capture on
    /// top of a later card that retained its original position.
    static func availablePoint(occupied: [CGRect], columns: Int, bodySize: CGSize, scale: CGFloat) -> WorkDeskPoint? {
        let preferredColumns = max(1, columns)
        let rows = max(1, Int((coordinateLimit - 340) / 340))
        let totalColumns = max(1, Int((coordinateLimit - 264) / 264))
        for band in 0..<(totalColumns / preferredColumns + 1) {
            for row in 0..<rows {
                for column in 0..<preferredColumns {
                    let xColumn = band * preferredColumns + column
                    guard xColumn < totalColumns else { continue }
                    let point = WorkDeskPoint(x: 28 + Double(xColumn) * 264, y: 26 + Double(row) * 340)
                    let proposed = frame(at: point, bodySize: bodySize, scale: scale).insetBy(dx: -10, dy: -10)
                    if !occupied.contains(where: { $0.intersects(proposed) }) { return point }
                }
            }
        }
        return nil
    }

    static func frame(at point: WorkDeskPoint, bodySize: CGSize, scale: CGFloat) -> CGRect {
        let point = bounded(point)
        return CGRect(
            x: point.x, y: point.y,
            width: bodySize.width,
            height: bodySize.height + visibleHandleHeight(scale: scale) / boundedScale(scale)
        )
    }

    static func screenPoint(_ point: WorkDeskPoint, transform: WorkDeskCanvasTransform) -> CGPoint {
        CGPoint(
            x: CGFloat(point.x) * transform.scale + transform.offset.width,
            y: CGFloat(point.y) * transform.scale + transform.offset.height
        )
    }

    /// Zoom around the chosen screen point, keeping its desk point stationary.
    static func zoomed(_ transform: WorkDeskCanvasTransform, to requested: CGFloat, anchor: CGPoint) -> WorkDeskCanvasTransform {
        let oldScale = boundedScale(transform.scale)
        let scale = boundedScale(requested)
        let ratio = scale / oldScale
        return WorkDeskCanvasTransform(scale: scale, offset: CGSize(
            width: anchor.x - (anchor.x - transform.offset.width) * ratio,
            height: anchor.y - (anchor.y - transform.offset.height) * ratio
        ))
    }

    static func fit(frames: [CGRect], viewport: CGSize) -> WorkDeskCanvasTransform {
        guard viewport.width > 0, viewport.height > 0,
              let first = frames.first else { return WorkDeskCanvasTransform() }
        let bounds = frames.dropFirst().reduce(first) { $0.union($1) }
        guard !bounds.isNull, bounds.width.isFinite, bounds.height.isFinite else {
            return WorkDeskCanvasTransform()
        }
        let usable = CGSize(width: max(1, viewport.width - 48), height: max(1, viewport.height - 100))
        let scale = boundedScale(min(1, min(usable.width / max(1, bounds.width), usable.height / max(1, bounds.height))))
        return WorkDeskCanvasTransform(scale: scale, offset: CGSize(
            width: (viewport.width - bounds.width * scale) / 2 - bounds.minX * scale,
            height: 24 - bounds.minY * scale
        ))
    }

    /// Requiring the centre to enter the inner portion distinguishes purposeful
    /// stacking from merely crossing an edge while arranging nearby notes.
    static func overlapTarget(movingFrame: CGRect, candidates: [(UUID, CGRect)]) -> UUID? {
        let centre = CGPoint(x: movingFrame.midX, y: movingFrame.midY)
        return candidates.filter { _, frame in
            frame.insetBy(dx: frame.width * 0.18, dy: frame.height * 0.18).contains(centre)
        }.min { lhs, rhs in
            let left = hypot(lhs.1.midX - centre.x, lhs.1.midY - centre.y)
            let right = hypot(rhs.1.midX - centre.x, rhs.1.midY - centre.y)
            return left == right ? lhs.0.uuidString < rhs.0.uuidString : left < right
        }?.0
    }
}

struct WorkDeskCanvas<CardContent: View>: View {
    let materials: [WorkboardMaterialSnapshot]
    let placements: [UUID: WorkDeskPlacementRecord]
    var projects: [WorkDeskCanvasProject] = []
    let selectedIDs: Set<UUID>
    let isSelecting: Bool
    let onMove: (UUID, WorkDeskPoint) async -> Bool
    let onMoveProject: (UUID, WorkDeskPoint) async -> Bool
    let onGroup: ([UUID]) -> Void
    let onAssign: ([UUID], UUID) -> Void
    let onSelect: (UUID) -> Void
    let onOpenProject: (UUID) -> Void
    let onTogglePin: (UUID) -> Void
    let onSeedPositions: ([WorkDeskPositionSeed], [UUID: WorkDeskPoint]) async -> Bool
    @ViewBuilder var cardContent: (WorkboardMaterialSnapshot, CGSize) -> CardContent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.workbenchDestinationIsActive) private var isActive
    @State private var transform = WorkDeskCanvasTransform()
    @State private var viewport: CGSize = .zero
    @State private var initialized = false
    @State private var columns = 3
    @State private var coordinateSpace = UUID()
    @State private var panStart: CGSize?
    @State private var magnificationStart: WorkDeskCanvasTransform?
    @State private var drag: MovingItem?
    @State private var defaultPositions: [UUID: WorkDeskPoint] = [:]
    @State private var releasedPositions: [UUID: WorkDeskPoint] = [:]
    @State private var moveTokens: [UUID: UUID] = [:]
    @GestureState private var isPanning = false
    @GestureState private var isMagnifying = false

    private struct MovingItem {
        let id: UUID
        let isProject: Bool
        let origin: WorkDeskPoint
        var point: WorkDeskPoint
    }

    private enum DropTarget: Equatable {
        case material(UUID)
        case project(UUID)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                background
                ForEach(projects) { project in projectPile(project) }
                ForEach(materials) { material in materialCard(material) }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .coordinateSpace(name: coordinateSpace)
            .clipped()
            .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.84), value: materials.map(\.id))
            .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.84), value: projects.map(\.id))
            .overlay(alignment: .bottomTrailing) { viewportControls.padding(14) }
            .simultaneousGesture(magnifyGesture)
            .onChange(of: proxy.size, initial: true) { _, size in
                viewport = size
                guard !initialized, size.width > 0, size.height > 0 else { return }
                initialized = true
                transform.scale = size.width < 600 ? 0.72 : 1
                columns = max(2, min(4, Int((size.width - 32) / (264 * transform.scale))))
                seedDefaultPositions()
                revealDeskIfOffscreen()
            }
            .onChange(of: materials.map(\.id), initial: true) { _, ids in
                seedDefaultPositions()
                if let drag, !drag.isProject, !ids.contains(drag.id) { self.drag = nil }
            }
            .onChange(of: projects.map(\.id), initial: true) { _, ids in
                seedDefaultPositions()
                if let drag, drag.isProject, !ids.contains(drag.id) { self.drag = nil }
            }
            .onChange(of: isPanning) { _, active in if !active { panStart = nil } }
            .onChange(of: isMagnifying) { _, active in if !active { magnificationStart = nil } }
            .onChange(of: isActive) { _, active in if !active { cancelInteractions() } }
            .onDisappear { cancelInteractions() }
        }
        .accessibilityIdentifier("workdesk-spatial-canvas")
    }

    private var background: some View {
        AppColors.background
            .overlay {
                Canvas { context, size in
                    let step = max(12, 28 * transform.scale)
                    let xOrigin = transform.offset.width.truncatingRemainder(dividingBy: step)
                    let yOrigin = transform.offset.height.truncatingRemainder(dividingBy: step)
                    var dots = Path()
                    for x in stride(from: xOrigin, through: size.width, by: step) {
                        for y in stride(from: yOrigin, through: size.height, by: step) {
                            dots.addEllipse(in: CGRect(x: x, y: y, width: 1.3, height: 1.3))
                        }
                    }
                    context.fill(dots, with: .color(AppColors.textTertiary.opacity(0.23)))
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                    #if os(iOS)
                    KeyboardDismissal.dismissKeyboard()
                    #endif
                 }
            .gesture(DragGesture(minimumDistance: 4)
                .updating($isPanning) { _, active, _ in active = true }
                .onChanged { value in
                guard isActive, drag == nil else { return }
                if panStart == nil {

                    #if os(iOS)
                    KeyboardDismissal.dismissKeyboard()
                    #endif

                    panStart = transform.offset
                }
                guard let panStart else { return }
                transform.offset = CGSize(width: panStart.width + value.translation.width, height: panStart.height + value.translation.height)
            }.onEnded { _ in panStart = nil })
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .updating($isMagnifying) { _, active, _ in active = true }
            .onChanged { value in
                guard isActive, drag == nil else { return }
                if magnificationStart == nil { magnificationStart = transform }
                guard let start = magnificationStart else { return }
                transform = WorkDeskCanvasGeometry.zoomed(start, to: start.scale * value.magnification, anchor: viewportCenter)
            }
            .onEnded { _ in magnificationStart = nil }
    }

    private func materialCard(_ material: WorkboardMaterialSnapshot) -> some View {
        let point = currentPoint(id: material.id, isProject: false)
        let bodySize = WorkDeskCanvasGeometry.cardBodySize
        let screen = WorkDeskCanvasGeometry.screenPoint(point, transform: transform)
        let width = bodySize.width * transform.scale
        let height = bodySize.height * transform.scale + WorkDeskCanvasGeometry.visibleHandleHeight(scale: transform.scale)
        let lifted = drag?.id == material.id
        return Group {
            if transform.scale < WorkDeskCanvasGeometry.overviewThreshold {
                Button { focus(point: point, bodySize: bodySize) } label: {
                    cardContent(material, bodySize)
                        .frame(width: bodySize.width, height: bodySize.height)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .scaleEffect(transform.scale)
                        .frame(width: width, height: bodySize.height * transform.scale)
                        .clipped()
                        .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(selectedIDs.contains(material.id) ? AppColors.brandAmber : AppColors.border, lineWidth: 1) }
                }
                .choiceCardButton(cornerRadius: 3)
                .accessibilityLabel(Text(verbatim: material.name))
                .accessibilityHint(Text(LocalizedStringResource("workdesk.canvas.focusMaterial", defaultValue: "Zoom in to this material")))
            } else {
                WorkDeskCard(
            title: material.name,
            width: width,
            isSelected: selectedIDs.contains(material.id),
            isPinned: placements[material.id]?.isPinned == true,
            isSelecting: isSelecting,
            isLifted: lifted,
            isGroupTarget: dropTarget == .material(material.id),
            coordinateSpace: coordinateSpace,
            onSelect: { onSelect(material.id) },
            onTogglePin: { onTogglePin(material.id) },
            onDragChanged: { updateDrag(id: material.id, isProject: false, translation: $0) },
            onDragEnded: { finishDrag(id: material.id, isProject: false, translation: $0) },
            onDragCancelled: { cancelDrag(id: material.id) },
            onNudge: { nudge(id: material.id, isProject: false, translation: $0) }
        ) {
            cardContent(material, bodySize)
                .frame(width: bodySize.width, height: bodySize.height)
                .scaleEffect(transform.scale)
                .frame(width: width, height: bodySize.height * transform.scale)
                .clipped()
                .accessibilityHidden(isSelecting)
                .overlay {
                    if isSelecting {
                        Button { onSelect(material.id) } label: {
                            Color.clear.contentShape(Rectangle())
                        }
                        .choiceCardButton(cornerRadius: 16)
                        .accessibilityLabel(Text(LocalizedStringResource("workdesk.canvas.selectCard", defaultValue: "Select material")))
                        .accessibilityValue(Text(verbatim: material.name))
                    }
                }
                }
            }
        }
        .rotationEffect(.degrees(reduceMotion || lifted || isSelecting ? 0 : tilt(for: material.id)))
        .position(x: screen.x + width / 2, y: screen.y + height / 2)
        .zIndex(lifted ? 1_000 : selectedIDs.contains(material.id) ? 10 : 1)
        .transition(reduceMotion ? .opacity : .scale(scale: 0.92).combined(with: .opacity))
        .accessibilityIdentifier("workdesk-card-\(material.id.uuidString)")
    }

    private func projectPile(_ project: WorkDeskCanvasProject) -> some View {
        let point = currentPoint(id: project.id, isProject: true)
        let bodySize = WorkDeskCanvasGeometry.projectBodySize
        let screen = WorkDeskCanvasGeometry.screenPoint(point, transform: transform)
        let width = bodySize.width * transform.scale
        let bodyHeight = bodySize.height * transform.scale
        let highlighted = dropTarget == .project(project.id)
        return VStack(spacing: 0) {
            if transform.scale >= WorkDeskCanvasGeometry.overviewThreshold {
                WorkDeskDragGrip(
                title: project.record.title,
                coordinateSpace: coordinateSpace,
                onChanged: { updateDrag(id: project.id, isProject: true, translation: $0) },
                onEnded: { finishDrag(id: project.id, isProject: true, translation: $0) },
                onCancelled: { cancelDrag(id: project.id) },
                onNudge: { nudge(id: project.id, isProject: true, translation: $0) }
                )
            }
            Button { onOpenProject(project.id) } label: {
                if transform.scale < WorkDeskCanvasGeometry.overviewThreshold {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(AppColors.brandAmber.opacity(0.28))
                        .overlay { Image(systemName: "folder.fill").font(.system(size: max(5, width * 0.3))).foregroundStyle(AppColors.brandAmber) }
                        .frame(width: width, height: bodyHeight)
                } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.system(size: 23 * max(0.7, transform.scale)))
                        Spacer(minLength: 0)
                        if project.record.isPinned { Image(systemName: "pin.fill").font(.caption) }
                    }
                    .foregroundStyle(AppColors.brandAmber)
                    Spacer(minLength: 0)
                    Text(verbatim: project.record.title)
                        .font(.system(size: 19 * max(0.7, transform.scale), weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(verbatim: String(project.materialCount))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(AppColors.textTertiary)
                }
                .padding(max(12, 20 * transform.scale))
                .frame(width: width, height: bodyHeight)
                .contentShape(Rectangle())
                }
            }
            .choiceCardButton(cornerRadius: 18)
            .accessibilityLabel(Text(verbatim: project.record.title))
            .accessibilityHint(Text(LocalizedStringResource("workdesk.canvas.openProject", defaultValue: "Open project")))
        }
        .frame(width: width)
        .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(highlighted ? AppColors.brandAmber : AppColors.brandAmber.opacity(0.35), lineWidth: highlighted ? 2 : 1)
                .allowsHitTesting(false)
        }
        .background {
            RoundedRectangle(cornerRadius: 20)
                .fill(AppColors.backgroundSecondary)
                .rotationEffect(.degrees(reduceMotion ? 0 : 3))
                .offset(x: 3, y: 6)
            RoundedRectangle(cornerRadius: 20)
                .fill(AppColors.brandAmber.opacity(0.13))
                .rotationEffect(.degrees(reduceMotion ? 0 : -3))
                .offset(x: -3, y: 10)
        }
        .overlay(alignment: .bottom) {
            if highlighted {
                Text(LocalizedStringResource("workdesk.canvas.addToProject", defaultValue: "Add to project"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.background)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(AppColors.brandAmber, in: Capsule())
                    .padding(.bottom, 10)
                    .allowsHitTesting(false)
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
        .position(x: screen.x + width / 2, y: screen.y + (bodyHeight + WorkDeskCanvasGeometry.visibleHandleHeight(scale: transform.scale)) / 2)
        .zIndex(drag?.id == project.id ? 1_000 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: highlighted)
        .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
        .accessibilityIdentifier("workdesk-project-\(project.id.uuidString)")
    }

    private var viewportControls: some View {
        HStack(spacing: 2) {
            Button { changeZoom(to: transform.scale / 1.2) } label: {
                Image(systemName: "minus").frame(width: 44, height: 44)
            }
            .pointerIconButton(size: 44)
            .disabled(transform.scale <= WorkDeskCanvasGeometry.minimumScale)
            .accessibilityLabel(Text(LocalizedStringResource("workdesk.canvas.zoomOut", defaultValue: "Zoom out")))
            Text(verbatim: "\(Int((transform.scale * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .frame(minWidth: 42)
                .accessibilityLabel(Text(LocalizedStringResource("workdesk.canvas.zoom", defaultValue: "Desk zoom")))
                .accessibilityValue(Text(verbatim: "\(Int((transform.scale * 100).rounded()))%"))
            Button { changeZoom(to: transform.scale * 1.2) } label: {
                Image(systemName: "plus").frame(width: 44, height: 44)
            }
            .pointerIconButton(size: 44)
            .disabled(transform.scale >= WorkDeskCanvasGeometry.maximumScale)
            .accessibilityLabel(Text(LocalizedStringResource("workdesk.canvas.zoomIn", defaultValue: "Zoom in")))
            Rectangle().fill(AppColors.border).frame(width: 1, height: 18)
            Button(action: fitDesk) {
                Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 44)
            }
            .pointerIconButton(size: 44)
            .accessibilityLabel(Text(LocalizedStringResource("workdesk.canvas.fit", defaultValue: "Fit desk")))
        }
        .foregroundStyle(AppColors.textSecondary)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(AppColors.borderSubtle, lineWidth: 1).allowsHitTesting(false) }
        .shadow(color: .black.opacity(0.2), radius: 12, y: 5)
        .disabled(!isActive || drag != nil)
    }

    private var viewportCenter: CGPoint { CGPoint(x: viewport.width / 2, y: viewport.height / 2) }

    private func currentPoint(id: UUID, isProject: Bool) -> WorkDeskPoint {
        if let drag, drag.id == id, drag.isProject == isProject { return drag.point }
        if let point = releasedPositions[id] { return point }
        if isProject {
            if let point = projects.first(where: { $0.id == id })?.record.position { return WorkDeskCanvasGeometry.bounded(point) }
            return defaultPositions[id] ?? WorkDeskCanvasGeometry.defaultPoint(index: materials.count + (projects.firstIndex(where: { $0.id == id }) ?? 0), columns: columns)
        }
        if let point = placements[id]?.position { return WorkDeskCanvasGeometry.bounded(point) }
        return defaultPositions[id] ?? WorkDeskCanvasGeometry.defaultPoint(index: materials.firstIndex(where: { $0.id == id }) ?? 0, columns: columns)
    }

    /// Reserve a slot once for every identity in this mounted desk. Removing or
    /// grouping another note cannot move unarranged notes out from under a hand;
    /// later captures get fresh slots instead of compacting the existing pile.
    private func seedDefaultPositions() {
        guard initialized else { return }
        var materialPoints: [WorkDeskPositionSeed] = []
        var projectPoints: [UUID: WorkDeskPoint] = [:]
        let entries = materials.map { ($0.id, false, WorkDeskCanvasGeometry.cardBodySize) }
            + projects.map { ($0.id, true, WorkDeskCanvasGeometry.projectBodySize) }
        var occupied: [CGRect] = []
        // Reserve all persisted positions before assigning any missing position.
        for (id, isProject, size) in entries {
            let saved = releasedPositions[id] ?? (isProject
                ? projects.first(where: { $0.id == id })?.record.position
                : placements[id]?.position) ?? defaultPositions[id]
            if let saved {
                defaultPositions[id] = saved
                occupied.append(WorkDeskCanvasGeometry.frame(at: saved, bodySize: size, scale: transform.scale))
            }
        }
        for (id, isProject, size) in entries where defaultPositions[id] == nil {
            guard let point = WorkDeskCanvasGeometry.availablePoint(
                occupied: occupied, columns: columns, bodySize: size, scale: transform.scale
            ) else { continue }
            defaultPositions[id] = point
            occupied.append(WorkDeskCanvasGeometry.frame(at: point, bodySize: size, scale: transform.scale))
            if isProject { projectPoints[id] = point }
            else {
                materialPoints.append(WorkDeskPositionSeed(materialID: id, projectID: placements[id]?.projectID, position: point))
            }
        }
        guard !materialPoints.isEmpty || !projectPoints.isEmpty else { return }
        Task { @MainActor in _ = await onSeedPositions(materialPoints, projectPoints) }
    }

    private var draggedIDs: [UUID] {
        guard let drag, !drag.isProject else { return [] }
        let visible = materials.map(\.id)
        return selectedIDs.contains(drag.id) ? visible.filter { selectedIDs.contains($0) } : [drag.id]
    }

    private var dropTarget: DropTarget? {
        guard let drag, !drag.isProject else { return nil }
        let movingFrame = WorkDeskCanvasGeometry.frame(at: drag.point, bodySize: WorkDeskCanvasGeometry.cardBodySize, scale: transform.scale)
        let projectCandidates = projects.map { project in
            (project.id, WorkDeskCanvasGeometry.frame(at: currentPoint(id: project.id, isProject: true), bodySize: WorkDeskCanvasGeometry.projectBodySize, scale: transform.scale))
        }
        if let id = WorkDeskCanvasGeometry.overlapTarget(movingFrame: movingFrame, candidates: projectCandidates) { return .project(id) }
        let excluded = Set(draggedIDs)
        let cardCandidates = materials.filter { !excluded.contains($0.id) }.map { material in
            (material.id, WorkDeskCanvasGeometry.frame(at: currentPoint(id: material.id, isProject: false), bodySize: WorkDeskCanvasGeometry.cardBodySize, scale: transform.scale))
        }
        return WorkDeskCanvasGeometry.overlapTarget(movingFrame: movingFrame, candidates: cardCandidates).map(DropTarget.material)
    }

    private func updateDrag(id: UUID, isProject: Bool, translation: CGSize) {
        guard isActive, moveTokens[id] == nil else { return }
        if drag == nil {

                    #if os(iOS)
                    KeyboardDismissal.dismissKeyboard()
                    #endif

            let origin = currentPoint(id: id, isProject: isProject)
            drag = MovingItem(id: id, isProject: isProject, origin: origin, point: origin)
        }
        guard let current = drag, current.id == id, current.isProject == isProject else { return }
        drag?.point = WorkDeskCanvasGeometry.moved(current.origin, by: translation, scale: transform.scale)
    }

    private func finishDrag(id: UUID, isProject: Bool, translation: CGSize) {
        guard isActive, drag?.id == id else { cancelDrag(id: id); return }
        updateDrag(id: id, isProject: isProject, translation: translation)
        guard let finished = drag else { return }
        let target = dropTarget
        let ids = draggedIDs
        drag = nil
        if finished.isProject {
            commitMove(id: id, point: finished.point, isProject: true)
        } else {
            switch target {
            case .project(let targetID): onAssign(ids, targetID)
            case .material(let targetID): onGroup(ids + [targetID])
            case nil: commitMove(id: id, point: finished.point, isProject: false)
            }
        }
    }

    private func cancelDrag(id: UUID) { if drag?.id == id { drag = nil } }

    private func nudge(id: UUID, isProject: Bool, translation: CGSize) {
        guard isActive, moveTokens[id] == nil else { return }
        let point = WorkDeskCanvasGeometry.moved(currentPoint(id: id, isProject: isProject), by: translation, scale: 1)
        commitMove(id: id, point: point, isProject: isProject)
    }

    /// Hold the released position until the store answers. A failed write
    /// returns visibly to persisted truth; a successful one never snaps back
    /// for the duration of the save. The callback owns its error presentation.
    private func commitMove(id: UUID, point: WorkDeskPoint, isProject: Bool) {
        let token = UUID()
        releasedPositions[id] = point
        moveTokens[id] = token
        Task { @MainActor in
            if isProject { _ = await onMoveProject(id, point) }
            else { _ = await onMove(id, point) }
            guard moveTokens[id] == token else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                releasedPositions[id] = nil
                moveTokens[id] = nil
            }
        }
    }

    private func focus(point: WorkDeskPoint, bodySize: CGSize) {
        let scale: CGFloat = viewport.width < 600 ? 0.85 : 1
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
            transform = WorkDeskCanvasTransform(scale: scale, offset: CGSize(
                width: viewport.width / 2 - (CGFloat(point.x) + bodySize.width / 2) * scale,
                height: viewport.height / 2 - (CGFloat(point.y) + bodySize.height / 2) * scale - 22
            ))
        }
    }

    private func changeZoom(to scale: CGFloat) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            transform = WorkDeskCanvasGeometry.zoomed(transform, to: scale, anchor: viewportCenter)
        }
    }

    private func revealDeskIfOffscreen() {
        let visible = CGRect(origin: .zero, size: viewport)
        let frames = materials.map { ($0.id, false, WorkDeskCanvasGeometry.cardBodySize) }
            + projects.map { ($0.id, true, WorkDeskCanvasGeometry.projectBodySize) }
        let hasVisibleCard = frames.contains { id, isProject, size in
            let point = WorkDeskCanvasGeometry.screenPoint(currentPoint(id: id, isProject: isProject), transform: transform)
            return visible.intersects(CGRect(origin: point, size: CGSize(width: size.width * transform.scale, height: size.height * transform.scale + 44)))
        }
        if !frames.isEmpty && !hasVisibleCard { fitDesk() }
    }

    private func fitDesk() {
        // Re-evaluate after zoom: handles stay 44 screen points while ordinary
        // cards zoom, and disappear in the tiny overview. Using old-scale
        // bounds would leave the last row below the viewport on a phone.
        var fitted = transform
        for _ in 0..<3 {
            let frames = materials.map { material in
                WorkDeskCanvasGeometry.frame(at: currentPoint(id: material.id, isProject: false), bodySize: WorkDeskCanvasGeometry.cardBodySize, scale: fitted.scale)
            } + projects.map { project in
                WorkDeskCanvasGeometry.frame(at: currentPoint(id: project.id, isProject: true), bodySize: WorkDeskCanvasGeometry.projectBodySize, scale: fitted.scale)
            }
            fitted = WorkDeskCanvasGeometry.fit(frames: frames, viewport: viewport)
        }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
            transform = fitted
        }
    }

    private func cancelInteractions() {
        drag = nil
        panStart = nil
        magnificationStart = nil
    }

    private func tilt(for id: UUID) -> Double {
        let sum = id.uuidString.utf8.reduce(0) { $0 + Int($1) }
        return Double(sum % 5 - 2) * 0.35
    }
}
