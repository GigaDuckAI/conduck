// SPDX-License-Identifier: Apache-2.0

// A viewport onto the private desk. Direct input updates only local presentation;
// releasing an object persists one atomic movement. Pan and zoom compose incremental
// screen deltas, while cards keep a stable world position and foreground order.
// Drop feedback is a separate foreground layer, never a child hidden by the card
// being held. Existing previews retain ownership of playback, sharing and repair.

import SwiftUI

struct WorkDeskCanvas<CardContent: View>: View {
    let materials: [WorkboardMaterialSnapshot]
    let placements: [UUID: WorkDeskPlacementRecord]
    var projects: [WorkDeskCanvasProject] = []
    @Bindable var session: WorkDeskCanvasSession
    let selectedIDs: Set<UUID>
    let isSelecting: Bool
    let onMoveMaterials: ([UUID: WorkDeskPoint], [UUID: UUID?]) async -> Bool
    let onMoveProject: (UUID, WorkDeskPoint) async -> Bool
    let onGroup: ([UUID], WorkDeskPoint) -> Void
    let onAssign: ([UUID], UUID) async -> Bool
    let onSelect: (UUID) -> Void
    let onOpenProject: (UUID) -> Void
    let onSeedPositions: ([WorkDeskPositionSeed], [UUID: WorkDeskPoint]) async -> Bool
    var onCreateProject: ((WorkDeskPoint) -> Void)? = nil
    @ViewBuilder var cardContent: (WorkboardMaterialSnapshot, CGSize) -> CardContent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.workbenchDestinationIsActive) private var isActive
    @State private var viewport: CGSize = .zero
    @State private var controlsFrame: CGRect = .zero
    @State private var coordinateSpace = UUID()
    @State private var nativeNavigation = false
    @State private var cancellationGeneration = 0
    @State private var lastPanTranslation: CGSize = .zero
    @State private var suppressPanUntilRelease = false
    @State private var drag: WorkDeskCanvasDrag?
    @State private var dragPointer: CGPoint?
    @State private var livePositions: [WorkDeskCanvasItemID: WorkDeskPoint] = [:]
    @State private var savedPositions: [WorkDeskCanvasItemID: WorkDeskPoint] = [:]
    @State private var defaultPositions: [WorkDeskCanvasItemID: WorkDeskPoint] = [:]
    @State private var hasLoadedLayout = false
    @State private var visibleIDs: Set<WorkDeskCanvasItemID> = []
    @State private var materialIndices: [UUID: Int] = [:]
    @State private var pending = WorkDeskPendingPositions()
    @State private var dropCandidates: [WorkDeskDropCandidate] = []
    @State private var hover = WorkDeskDropHover()
    @State private var edgePanTask: Task<Void, Never>?
    @State private var backgroundPointer = WorkDeskCanvasBackgroundPointer()
    @GestureState private var isPanning = false

    private var transform: WorkDeskCanvasTransform { session.transform }
    private var motion: Animation? { reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86) }
    private var viewportCenter: CGPoint { CGPoint(x: viewport.width / 2, y: viewport.height / 2) }

    var body: some View {
        GeometryReader { proxy in
            canvasLayers
                .frame(width: proxy.size.width, height: proxy.size.height)
                .workDeskViewportInput(
                    isEnabled: isActive,
                    excludedRects: [controlsFrame],
                    onPan: panViewport,
                    onZoom: zoomViewport,
                    onInteractionChanged: nativeInteractionChanged
                )
                .overlay { dropFeedback }
                .overlay(alignment: .bottomTrailing) {
                    viewportControls
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(coordinateSpace)) }
                        action: { controlsFrame = $0 }
                        .padding(14)
                }
                .clipped()
                .coordinateSpace(name: coordinateSpace)
                .onChange(of: proxy.size, initial: true) { _, size in
                    viewport = size
                    session.viewportSize = size
                    guard size.width > 0, size.height > 0 else { return }
                    if !session.isInitialized {
                        session.isInitialized = true
                        session.transform.scale = size.width < 600 ? 0.72 : 1
                        session.columns = max(2, min(4, Int((size.width - 32) / (264 * transform.scale))))
                        refreshLayout()
                        revealDeskIfOffscreen()
                    } else { refreshLayout() }
                }
                .onChange(of: materials.map(\.id), initial: true) { _, _ in refreshLayout() }
                .onChange(of: projects.map(\.record), initial: true) { _, _ in refreshLayout() }
                .onChange(of: placements) { _, _ in refreshLayout() }
                .onChange(of: isPanning) { _, active in
                    if !active { lastPanTranslation = .zero; suppressPanUntilRelease = false }
                }
                .onChange(of: isActive) { _, active in if !active { cancelInteractions() } }
                .onDisappear { cancelInteractions() }
                .task(id: hover.generation) { await armDropAfterDwell() }
        }
        .accessibilityIdentifier("workdesk-spatial-canvas")
    }

    private var canvasLayers: some View {
        ZStack(alignment: .topLeading) {
            background
            ForEach(projects) { project in
                let id = WorkDeskCanvasItemID.project(project.id)
                if shouldRender(id) { projectPile(project) }
            }
            ForEach(materials) { material in
                let id = WorkDeskCanvasItemID.material(material.id)
                if shouldRender(id) { materialCard(material) }
            }
        }
        .animation(motion, value: materials.map(\.id))
        .animation(motion, value: projects.map(\.id))
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
            .onTapGesture(coordinateSpace: .named(coordinateSpace), perform: backgroundTapped)
            #if os(macOS)
            .onContinuousHover(coordinateSpace: .named(coordinateSpace)) { phase in
                if case .active(let point) = phase { backgroundPointer.point = point }
            }
            .contextMenu {
                if let onCreateProject {
                    Button(LocalizedStringResource("workdesk.project.new", defaultValue: "New project"), systemImage: "folder.badge.plus") {
                        let point = backgroundPointer.point.map { WorkDeskCanvasGeometry.worldPoint($0, transform: transform) }
                            ?? session.projectInsertionPoint
                        if let point { onCreateProject(point) }
                    }
                }
            }
            #endif
            .gesture(
                DragGesture(minimumDistance: 4)
                    .updating($isPanning) { _, active, _ in active = true }
                    .onChanged { value in
                        guard isActive, drag == nil, !nativeNavigation, !suppressPanUntilRelease else { return }
                        if lastPanTranslation == .zero { dismissCaptureKeyboard() }
                        let delta = CGSize(width: value.translation.width - lastPanTranslation.width,
                                           height: value.translation.height - lastPanTranslation.height)
                        lastPanTranslation = value.translation
                        panViewport(delta)
                    }
                    .onEnded { _ in lastPanTranslation = .zero; suppressPanUntilRelease = false }
            )
            #if os(macOS)
            .pointerStyle(isPanning ? .grabActive : .grabIdle)
            #endif
    }

    private func materialCard(_ material: WorkboardMaterialSnapshot) -> some View {
        let id = WorkDeskCanvasItemID.material(material.id)
        let frame = screenFrame(for: id)
        let bodySize = WorkDeskCanvasGeometry.cardBodySize
        let lifted = livePositions[id] != nil
        let overview = transform.scale < WorkDeskCanvasGeometry.overviewThreshold
        return WorkDeskCard(scale: transform.scale, isSelected: selectedIDs.contains(material.id),
                            isLifted: lifted, isGroupTarget: hover.target == id) {
            materialPreview(material, bodySize: bodySize, scale: transform.scale)
                .allowsHitTesting(!isSelecting && !overview)
                .accessibilityHidden(isSelecting || overview)
                .overlay {
                    if isSelecting || overview {
                        Button {
                            activate(id)
                            if isSelecting { onSelect(material.id) }
                            else { focus(id) }
                        } label: { Color.clear.contentShape(Rectangle()) }
                        .choiceCardButton(cornerRadius: 13 * transform.scale)
                        .accessibilityLabel(Text(verbatim: material.name))
                        .accessibilityAddTraits(selectedIDs.contains(material.id) ? .isSelected : [])
                        .accessibilityHint(Text(isSelecting
                            ? LocalizedStringResource("workdesk.canvas.selectCard", defaultValue: "Select material")
                            : LocalizedStringResource("workdesk.canvas.focusMaterial", defaultValue: "Zoom in to this material")))
                    }
                }
        }
        .simultaneousGesture(TapGesture().onEnded { activate(id) })
        .accessibilityElement(children: .contain)
        .workDeskObjectDrag(
            coordinateSpace: coordinateSpace, isEnabled: isActive && !nativeNavigation,
            cancellationGeneration: cancellationGeneration,
            onChanged: { updateDrag(id: id, translation: $0) },
            onEnded: { finishDrag(id: id, translation: $0) },
            onCancelled: { cancelDrag(id: id) },
            onNudge: { nudge(id: id, translation: $0) },
            onLocation: recordDragPointer, onActivate: { activate(id) }
        )
        .position(x: frame.midX, y: frame.midY)
        .zIndex(session.layer(for: id) + (lifted ? WorkDeskCanvasGeometry.liftedLayer : 0))
        .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
        .accessibilityIdentifier("workdesk-card-\(material.id.uuidString)")
    }

    private func materialPreview(_ material: WorkboardMaterialSnapshot, bodySize: CGSize, scale: CGFloat) -> some View {
        WorkDeskStablePreview(material: material, size: bodySize, isSelecting: isSelecting,
                              ordinal: materialIndices[material.id] ?? 1, totalCount: materials.count, content: cardContent)
            .equatable()
            .frame(width: bodySize.width, height: bodySize.height)
            .scaleEffect(scale)
            .frame(width: bodySize.width * scale, height: bodySize.height * scale)
    }

    private func projectPile(_ project: WorkDeskCanvasProject) -> some View {
        let id = WorkDeskCanvasItemID.project(project.id)
        let frame = screenFrame(for: id)
        let highlighted = hover.target == id
        let lifted = livePositions[id] != nil
        let isOverview = transform.scale < WorkDeskCanvasGeometry.overviewThreshold
        return Button {
            activate(id)
            if isOverview { focus(id) } else { onOpenProject(project.id) }
        } label: {
            projectFace(project)
                .scaleEffect(transform.scale)
                .frame(width: frame.width, height: frame.height)
        }
        .choiceCardButton(cornerRadius: 13 * transform.scale)
        .frame(width: frame.width, height: frame.height)
        .accessibilityLabel(Text(verbatim: project.record.title))
        .accessibilityHint(Text(isOverview
            ? LocalizedStringResource("workdesk.canvas.focusMaterial", defaultValue: "Zoom in to this material")
            : LocalizedStringResource("workdesk.canvas.openProject", defaultValue: "Open project")))
        .overlay {
            RoundedRectangle(cornerRadius: 13 * transform.scale)
                .strokeBorder(highlighted || lifted ? AppColors.brandAmber : .clear, lineWidth: 2)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(lifted ? 0.38 : 0.20),
                radius: lifted ? 19 : 8 * transform.scale, y: lifted ? 11 : 4 * transform.scale)
        .animation(motion, value: lifted)
        .animation(motion, value: highlighted)
        .workDeskObjectDrag(
            coordinateSpace: coordinateSpace, isEnabled: isActive && !nativeNavigation,
            cancellationGeneration: cancellationGeneration,
            onChanged: { updateDrag(id: id, translation: $0) },
            onEnded: { finishDrag(id: id, translation: $0) },
            onCancelled: { cancelDrag(id: id) },
            onNudge: { nudge(id: id, translation: $0) },
            onLocation: recordDragPointer, onActivate: { activate(id) }
        )
        .position(x: frame.midX, y: frame.midY)
        .zIndex(session.layer(for: id) + (lifted ? WorkDeskCanvasGeometry.liftedLayer : 0))
        .transition(reduceMotion ? .opacity : .scale(scale: 0.86).combined(with: .opacity))
        .accessibilityIdentifier("workdesk-project-\(project.id.uuidString)")
    }

    private func projectFace(_ project: WorkDeskCanvasProject) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "folder.fill").font(.system(size: 23))
                .foregroundStyle(AppColors.brandAmber)
            Spacer(minLength: 0)
            Text(verbatim: project.record.title).font(.system(size: 19, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary).lineLimit(2).multilineTextAlignment(.leading)
            Text(WorkDeskCopy.materialCount(project.materialCount))
                .font(.caption.monospacedDigit()).foregroundStyle(AppColors.textTertiary)
        }
        .padding(20)
        .frame(width: WorkDeskCanvasGeometry.projectBodySize.width, height: WorkDeskCanvasGeometry.projectBodySize.height, alignment: .leading)
        .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(AppColors.brandAmber.opacity(0.35), lineWidth: 1) }
        .contentShape(Rectangle())
    }

    private func backgroundTapped(_ location: CGPoint) {
        dismissCaptureKeyboard()
        guard isActive, !nativeNavigation, drag == nil,
              transform.scale < WorkDeskCanvasGeometry.overviewThreshold else { return }
        let candidates = visibleIDs.map {
            WorkDeskDropCandidate(id: $0, frame: screenFrame(for: $0), layer: session.layer(for: $0))
        }
        guard let id = WorkDeskCanvasGeometry.overviewTarget(at: location, candidates: candidates) else { return }
        activate(id)
        if isSelecting, case .material(let materialID) = id { onSelect(materialID) }
        else { focus(id) }
    }

    /// One overlay above every card and project. The title remains readable
    /// even when the dragged card completely covers its intended destination.
    @ViewBuilder private var dropFeedback: some View {
        if let target = hover.target, let drag {
            let bounds = WorkDeskCanvasGeometry.feedbackFrame(near: screenFrame(for: drag.lead), viewport: viewport)
            VStack(alignment: .leading, spacing: 5) {
                Label(dropInstruction, systemImage: hover.isReady ? "checkmark.circle.fill" : "square.stack.3d.up")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(verbatim: title(for: target))
                    .font(.caption).lineLimit(1).foregroundStyle(AppColors.textSecondary)
            }
            .frame(width: bounds.width - 28, height: bounds.height - 20, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .foregroundStyle(hover.isReady ? AppColors.brandAmber : AppColors.textPrimary)
            .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(AppColors.brandAmber.opacity(hover.isReady ? 0.9 : 0.4), lineWidth: 1.5) }
            .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
            .position(x: bounds.midX, y: bounds.midY)
            .zIndex(WorkDeskCanvasGeometry.feedbackLayer)
            .allowsHitTesting(false)
            .transition(.opacity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hover.isReady)
            .accessibilityIdentifier("workdesk-drop-feedback")
        }
    }

    private var dropInstruction: LocalizedStringResource {
        guard hover.isReady else {
            return LocalizedStringResource("workdesk.canvas.holdToGroup", defaultValue: "Hold here to group")
        }
        if hover.target?.isProject == true {
            return LocalizedStringResource("workdesk.canvas.releaseToAdd", defaultValue: "Release to add to project")
        }
        return LocalizedStringResource("workdesk.canvas.releaseToGroup", defaultValue: "Release to create project")
    }

    private var viewportControls: some View {
        HStack(spacing: 2) {
            Button { changeZoom(to: transform.scale / 1.2) } label: { Image(systemName: "minus").frame(width: 44, height: 44) }
                .pointerIconButton(size: 44)
                .disabled(transform.scale <= WorkDeskCanvasGeometry.minimumScale)
                .accessibilityLabel(Text(LocalizedStringResource("workdesk.canvas.zoomOut", defaultValue: "Zoom out")))
            Button { changeZoom(to: 1) } label: {
                Text(verbatim: zoomLabel)
                    .font(.caption.monospacedDigit()).frame(minWidth: 44, minHeight: 44)
            }
            .pointerIconButton(size: 44, horizontalPadding: 4)
            .accessibilityLabel(Text(LocalizedStringResource("workdesk.canvas.resetZoom", defaultValue: "Reset zoom")))
            .accessibilityValue(Text(verbatim: zoomLabel))
            .help(Text(LocalizedStringResource("workdesk.canvas.resetZoom", defaultValue: "Reset zoom")))
            Button { changeZoom(to: transform.scale * 1.2) } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
                .pointerIconButton(size: 44)
                .disabled(transform.scale >= WorkDeskCanvasGeometry.maximumScale)
                .accessibilityLabel(Text(LocalizedStringResource("workdesk.canvas.zoomIn", defaultValue: "Zoom in")))
            Rectangle().fill(AppColors.border).frame(width: 1, height: 18)
            Button(action: fitDesk) { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 44) }
                .pointerIconButton(size: 44)
                .accessibilityLabel(Text(LocalizedStringResource("workdesk.canvas.fit", defaultValue: "Fit desk")))
        }
        .foregroundStyle(AppColors.textSecondary)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(AppColors.borderSubtle, lineWidth: 1).allowsHitTesting(false) }
        .shadow(color: .black.opacity(0.2), radius: 12, y: 5)
        .disabled(!isActive || drag != nil || nativeNavigation)
    }

    private var zoomLabel: String {
        transform.scale < 0.01 ? String(format: "%.1f%%", transform.scale * 100) : "\(Int((transform.scale * 100).rounded()))%"
    }

    private func currentPoint(_ id: WorkDeskCanvasItemID) -> WorkDeskPoint {
        livePositions[id] ?? pending.positions[id] ?? savedPositions[id] ?? defaultPositions[id] ?? .init(x: 28, y: 26)
    }

    private func bodySize(for id: WorkDeskCanvasItemID) -> CGSize {
        id.isProject ? WorkDeskCanvasGeometry.projectBodySize : WorkDeskCanvasGeometry.cardBodySize
    }

    private func screenFrame(for id: WorkDeskCanvasItemID) -> CGRect {
        WorkDeskCanvasGeometry.screenFrame(at: currentPoint(id), bodySize: bodySize(for: id), transform: transform)
    }

    private func shouldRender(_ id: WorkDeskCanvasItemID) -> Bool {
        WorkDeskCanvasGeometry.shouldRender(screenFrame(for: id), viewport: viewport,
            isInteracting: livePositions[id] != nil || hover.target == id)
    }

    private func title(for id: WorkDeskCanvasItemID) -> String {
        switch id {
        case .material(let value): materials.first { $0.id == value }?.name ?? ""
        case .project(let value): projects.first { $0.id == value }?.record.title ?? ""
        }
    }

    private func refreshLayout() {
        // A remount after search/layout changes must preserve the saved camera,
        // even if it points at blank space. Only a live empty-to-first-item
        // transition needs to reveal a capture seeded outside the viewport.
        let wasEmpty = hasLoadedLayout && visibleIDs.isEmpty
        hasLoadedLayout = true
        let ids = projects.map { WorkDeskCanvasItemID.project($0.id) } + materials.map { WorkDeskCanvasItemID.material($0.id) }
        visibleIDs = Set(ids)
        materialIndices = Dictionary(materials.enumerated().map { ($0.element.id, $0.offset + 1) }, uniquingKeysWith: { first, _ in first })
        if let drag, !Set(drag.origins.keys).isSubset(of: visibleIDs) { cancelInteractions() }
        session.reconcile(ids)
        var saved: [WorkDeskCanvasItemID: WorkDeskPoint] = [:]
        for material in materials { saved[.material(material.id)] = placements[material.id]?.position }
        for project in projects { saved[.project(project.id)] = project.record.position }
        savedPositions = saved
        defaultPositions = defaultPositions.filter { visibleIDs.contains($0.key) }
        seedDefaultPositions(ids)
        if wasEmpty, !ids.isEmpty, session.isInitialized { revealDeskIfOffscreen() }
        if drag != nil { cacheDropCandidates(); updateDropTarget() }
    }

    private func seedDefaultPositions(_ ids: [WorkDeskCanvasItemID]) {
        guard session.isInitialized else { return }
        var materialPoints: [WorkDeskPositionSeed] = []
        var projectPoints: [UUID: WorkDeskPoint] = [:]
        var occupied: [CGRect] = []
        for id in ids {
            if let saved = pending.positions[id] ?? savedPositions[id] ?? defaultPositions[id] {
                defaultPositions[id] = saved
                occupied.append(WorkDeskCanvasGeometry.frame(at: saved, bodySize: bodySize(for: id), scale: 1))
            }
        }
        for id in ids where defaultPositions[id] == nil {
            guard let point = WorkDeskCanvasGeometry.availablePoint(occupied: occupied,
                columns: session.columns, bodySize: bodySize(for: id), scale: 1) else { continue }
            defaultPositions[id] = point
            occupied.append(WorkDeskCanvasGeometry.frame(at: point, bodySize: bodySize(for: id), scale: 1))
            switch id {
            case .material(let value): materialPoints.append(.init(materialID: value, projectID: placements[value]?.projectID, position: point))
            case .project(let value): projectPoints[value] = point
            }
        }
        guard !materialPoints.isEmpty || !projectPoints.isEmpty else { return }
        Task { @MainActor in _ = await onSeedPositions(materialPoints, projectPoints) }
    }

    private func activate(_ id: WorkDeskCanvasItemID) {
        guard isActive, !nativeNavigation else { return }
        session.bringToFront([id])
    }

    private func updateDrag(id: WorkDeskCanvasItemID, translation: CGSize) {
        guard isActive, !nativeNavigation else { return }
        if drag == nil {
            dismissCaptureKeyboard()
            lastPanTranslation = .zero
            suppressPanUntilRelease = true
            var ids = [id]
            if !id.isProject, selectedIDs.contains(id.id) {
                ids = materials.map { WorkDeskCanvasItemID.material($0.id) }.filter { selectedIDs.contains($0.id) && $0 != id }
                    .sorted { session.layer(for: $0) < session.layer(for: $1) } + [id]
            }
            session.raiseGroup(ids, lead: id)
            let origins = Dictionary(uniqueKeysWithValues: ids.map { ($0, currentPoint($0)) })
            drag = WorkDeskCanvasDrag(lead: id, origins: origins, startTransform: transform,
                memberships: Dictionary(uniqueKeysWithValues: ids.filter { !$0.isProject }.map {
                    ($0.id, placements[$0.id]?.projectID)
                }))
            cacheDropCandidates()
            startEdgePanning()
        }
        guard drag?.lead == id else { return }
        drag?.translation = translation
        if let drag { livePositions = drag.positions(transform: transform) }
        updateDropTarget()
    }

    private func cacheDropCandidates() {
        let excluded = Set(drag?.origins.keys.map { $0 } ?? [])
        dropCandidates = visibleIDs.filter { !excluded.contains($0) }.map { id in
            WorkDeskDropCandidate(id: id,
                frame: WorkDeskCanvasGeometry.frame(at: currentPoint(id), bodySize: bodySize(for: id), scale: transform.scale),
                layer: session.layer(for: id))
        }
    }

    private func updateDropTarget() {
        guard let drag, !drag.lead.isProject, let point = livePositions[drag.lead] else { hover.reset(); return }
        let frame = WorkDeskCanvasGeometry.frame(at: point, bodySize: bodySize(for: drag.lead), scale: transform.scale)
        hover.update(WorkDeskCanvasGeometry.foregroundTarget(movingFrame: frame, candidates: dropCandidates))
    }

    private func armDropAfterDwell() async {
        guard hover.target != nil, drag != nil else { return }
        let generation = hover.generation
        do { try await Task.sleep(for: WorkDeskDropHover.dwellDuration) } catch { return }
        guard !Task.isCancelled, isActive, drag != nil else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { hover.arm(generation: generation) }
    }

    private func finishDrag(id: WorkDeskCanvasItemID, translation: CGSize) {
        guard isActive, !nativeNavigation, drag?.lead == id else { cancelDrag(id: id); return }
        updateDrag(id: id, translation: translation)
        guard let finished = drag else { return }
        let points = livePositions
        let target = hover.isReady ? hover.target : nil
        let materialIDs = finished.origins.keys.filter { !$0.isProject }.map(\.id).sorted { $0.uuidString < $1.uuidString }
        session.raiseGroup(Array(finished.origins.keys), lead: id)
        edgePanTask?.cancel(); edgePanTask = nil
        drag = nil
        dragPointer = nil
        hover.reset()
        if let target, !id.isProject {
            switch target {
            case .material(let value):
                withAnimation(motion) { livePositions = [:] }
                onGroup(materialIDs + [value], currentPoint(target))
            case .project(let projectID):
                // Filing changes membership, not the home arrangement. Keep
                // the original positions while the assignment commits.
                withAnimation(motion) { commitAssignment(materialIDs, to: projectID, points: finished.origins); livePositions = [:] }
            }
        } else {
            commitMove(points, memberships: finished.memberships)
            livePositions = [:]
        }
    }

    private func cancelDrag(id: WorkDeskCanvasItemID) {
        guard drag?.lead == id else { return }
        edgePanTask?.cancel(); edgePanTask = nil
        drag = nil
        dragPointer = nil
        hover.reset()
        withAnimation(motion) { livePositions = [:] }
    }

    private func nudge(id: WorkDeskCanvasItemID, translation: CGSize) {
        guard isActive, !nativeNavigation, drag == nil else { return }
        var ids = [id]
        if !id.isProject, selectedIDs.contains(id.id) {
            ids = materials.map { WorkDeskCanvasItemID.material($0.id) }.filter { selectedIDs.contains($0.id) }
        }
        let origins = Dictionary(uniqueKeysWithValues: ids.map { ($0, currentPoint($0)) })
        let points = WorkDeskCanvasGeometry.translated(origins, by: translation)
        session.raiseGroup(ids, lead: id)
        withAnimation(motion) { commitMove(points) }
    }

    private func commitMove(_ points: [WorkDeskCanvasItemID: WorkDeskPoint], memberships: [UUID: UUID?]? = nil) {
        let expectedMemberships = memberships ?? Dictionary(uniqueKeysWithValues: points.keys.filter { !$0.isProject }.map {
            ($0.id, placements[$0.id]?.projectID)
        })
        let token = pending.begin(points)
        Task { @MainActor in
            let success: Bool
            if let entry = points.first, entry.key.isProject { success = await onMoveProject(entry.key.id, entry.value) }
            else { success = await onMoveMaterials(Dictionary(uniqueKeysWithValues: points.map { ($0.key.id, $0.value) }), expectedMemberships) }
            withAnimation(motion) {
                let owned = pending.finish(token: token)
                if success {
                    // The parent publishes before returning, but its next body
                    // pass may still be queued. Bridge that one frame using the
                    // confirmed positions, then accept subsequent synced truth.
                    for (id, point) in owned where visibleIDs.contains(id) { savedPositions[id] = point; defaultPositions[id] = point }
                }
                if drag != nil { cacheDropCandidates(); updateDropTarget() }
            }
        }
    }

    private func commitAssignment(_ ids: [UUID], to projectID: UUID, points: [WorkDeskCanvasItemID: WorkDeskPoint]) {
        let token = pending.begin(points)
        Task { @MainActor in
            _ = await onAssign(ids, projectID)
            withAnimation(motion) {
                _ = pending.finish(token: token)
                if drag != nil { cacheDropCandidates(); updateDropTarget() }
            }
        }
    }

    private func nativeInteractionChanged(_ active: Bool) {
        nativeNavigation = active
        if active {
            dismissCaptureKeyboard()
            if let drag { cancellationGeneration &+= 1; cancelDrag(id: drag.lead) }
            suppressPanUntilRelease = isPanning
            lastPanTranslation = .zero
        }
    }

    private func panViewport(_ delta: CGSize) {
        guard isActive, drag == nil else { return }
        withTransaction(Transaction(animation: nil)) { session.transform = WorkDeskCanvasGeometry.panned(transform, by: delta) }
    }

    private func zoomViewport(_ factor: CGFloat, _ anchor: CGPoint) {
        guard isActive, drag == nil, factor.isFinite, factor > 0 else { return }
        withTransaction(Transaction(animation: nil)) {
            session.transform = WorkDeskCanvasGeometry.zoomed(transform, to: transform.scale * factor, anchor: anchor)
        }
    }

    private func startEdgePanning() {
        edgePanTask?.cancel()
        edgePanTask = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { break }
                guard isActive, let drag, !nativeNavigation else { break }
                guard let dragPointer else { continue }
                let velocity = WorkDeskCanvasGeometry.edgePanVelocity(at: dragPointer, viewport: viewport)
                guard velocity != .zero else { continue }
                var next = WorkDeskCanvasGeometry.panned(transform, by: CGSize(width: velocity.width * 0.016, height: velocity.height * 0.016))
                let shifted = drag.positions(transform: next)
                if shifted[drag.lead]?.x == livePositions[drag.lead]?.x { next.offset.width = transform.offset.width }
                if shifted[drag.lead]?.y == livePositions[drag.lead]?.y { next.offset.height = transform.offset.height }
                withTransaction(Transaction(animation: nil)) {
                    session.transform = next
                    livePositions = drag.positions(transform: next)
                    updateDropTarget()
                }
            }
        }
    }

    private func focus(_ id: WorkDeskCanvasItemID) {
        let point = currentPoint(id), size = bodySize(for: id)
        let scale: CGFloat = viewport.width < 600 ? 0.85 : 1
        withAnimation(motion) {
            session.transform = WorkDeskCanvasTransform(scale: scale, offset: CGSize(
                width: viewport.width / 2 - (CGFloat(point.x) + size.width / 2) * scale,
                height: viewport.height / 2 - (CGFloat(point.y) + size.height / 2) * scale))
        }
    }

    private func changeZoom(to scale: CGFloat) {
        withAnimation(motion) { session.transform = WorkDeskCanvasGeometry.zoomed(transform, to: scale, anchor: viewportCenter) }
    }

    private func revealDeskIfOffscreen() {
        if !visibleIDs.isEmpty && !visibleIDs.contains(where: { CGRect(origin: .zero, size: viewport).intersects(screenFrame(for: $0)) }) { fitDesk() }
    }

    private func fitDesk() {
        let frames = visibleIDs.map {
            WorkDeskCanvasGeometry.frame(at: currentPoint($0), bodySize: bodySize(for: $0), scale: 1)
        }
        let fitted = WorkDeskCanvasGeometry.fit(frames: frames, viewport: viewport)
        withAnimation(motion) { session.transform = fitted }
    }

    private func cancelInteractions() {
        if drag != nil { cancellationGeneration &+= 1 }
        edgePanTask?.cancel(); edgePanTask = nil
        drag = nil
        dragPointer = nil
        livePositions = [:]
        hover.reset()
        nativeNavigation = false
        lastPanTranslation = .zero
        suppressPanUntilRelease = false
    }

    private func recordDragPointer(_ point: CGPoint) {
        guard isActive, !nativeNavigation, point.x.isFinite, point.y.isFinite else { return }
        dragPointer = point
    }

    private func dismissCaptureKeyboard() {
        #if os(iOS)
        KeyboardDismissal.dismissKeyboard()
        #endif
    }
}

/// Hover only supplies the next background menu's creation point. Keeping it
/// out of observation avoids rebuilding every card while the pointer moves.
@MainActor private final class WorkDeskCanvasBackgroundPointer {
    var point: CGPoint?
}

/// Camera movement changes the surrounding frame, not the preview's inputs.
/// Keep expensive thumbnails and nested playback controls out of pan-rate body
/// rebuilding while still invalidating for revised captures and selection mode.
struct WorkDeskStablePreview<Content: View>: View, Equatable {
    let material: WorkboardMaterialSnapshot
    let size: CGSize
    let isSelecting: Bool
    let ordinal: Int
    let totalCount: Int
    let content: (WorkboardMaterialSnapshot, CGSize) -> Content

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.material == rhs.material && lhs.size == rhs.size && lhs.isSelecting == rhs.isSelecting
            && lhs.ordinal == rhs.ordinal && lhs.totalCount == rhs.totalCount
    }

    var body: some View { content(material, size) }
}
