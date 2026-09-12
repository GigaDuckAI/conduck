// SPDX-License-Identifier: Apache-2.0

// The spatial and accessible list presentations share the existing mature card
// controls: opening, availability, repair, sharing and folded voice materials.
// Organization only passes identifiers to its own metadata store. Destructive
// removal retains the capture store's exact parent/companion confirmation.
// Every layout draws the material's own surface and menu. Selection overlays
// that surface; it never adds a second card or a permanent organization bar.
// Each location keeps its own readable order as well as spatial positions.
// Whole-card native drags preview an insertion edge; a cross-location release
// files and orders atomically, outside the external-file import lane.

import SwiftUI
import UniformTypeIdentifiers

struct WorkDeskSourceBoard: View {
    @Bindable var viewModel: WorkboardViewModel
    let item: WorkboardItemSnapshot
    @Bindable var workspace: WorkDeskWorkspaceState
    let onOpen: (WorkboardMaterialSnapshot) -> Void
    let onShare: (WorkboardMaterialSnapshot) -> Void
    let onReattach: (WorkboardMaterialSnapshot) -> Void
    var scopeOverride: WorkDeskScope? = nil
    var transferPriority = 0
    @State private var boardGlobalFrame: CGRect = .zero
    @State private var readableSurfaceID = UUID()
    @State private var pendingRemoval: WorkboardMaterialSnapshot?
    @State private var readableReorder = WorkDeskReadableReorder()
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.workbenchDestinationIsActive) private var workbenchDestinationIsActive

    private var boardScope: WorkDeskScope { scopeOverride ?? workspace.scope }
    private var boardSearch: String { boardScope == .all ? workspace.search : "" }
    private var isSearching: Bool { !boardSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var isBoardSelecting: Bool { workspace.isSelecting && (workspace.scope == boardScope || isSearching) }
    private var materials: [WorkboardMaterialSnapshot] {
        workspace.visibleMaterials(in: item.materials, scope: boardScope, search: boardSearch)
    }
    private var sourceLocation: WorkDeskLocation? { isSearching ? nil : boardScope.location }
    private var project: WorkDeskProjectRecord? {
        guard case .project(let id) = boardScope else { return nil }
        return workspace.organization.project(id: id)
    }
    private var selectedIDs: Set<UUID> { isBoardSelecting ? workspace.selectedIDs : [] }
    private func selectMaterial(_ id: UUID) {
        if workspace.scope != boardScope { workspace.selectScope(boardScope) }
        workspace.toggleSelection(id)
    }

    private var projects: [WorkDeskCanvasProject] {
        let query = boardSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let counts = workspace.organization.materialCounts(in: item.materials)
        return workspace.organization.projects.filter { project in
            if !query.isEmpty { return project.title.localizedStandardContains(query) }
            switch boardScope {
            case .all: return !project.isArchived
            case .project: return false
            }
        }.map { record in
            WorkDeskCanvasProject(record: record, materialCount: counts[record.id] ?? 0,
                previewMaterials: Array(item.materials.filter {
                    workspace.organization.contains(materialID: $0.id, at: .project(record.id))
                }.prefix(3)))
        }
    }

    private var renderedLayout: WorkboardLayoutMode {
        WorkDeskLayoutPresentation.resolved(preference: workspace.layoutSession(for: boardScope).mode,
            supportsSpatialLayout: !isSearching,
            requiresAccessibleList: dynamicTypeSize.isAccessibilitySize)
    }

    var body: some View {
        let dropTransform = workspace.canvasSession(for: boardScope).transform
        Group {
            if renderedLayout == .desk {
                spatialBoard
                    .overlay {
                        if materials.isEmpty && projects.isEmpty {
                            emptyState.allowsHitTesting(false)
                        }
                    }
            } else if materials.isEmpty && projects.isEmpty {
                emptyState
            } else {
                readableBoard
            }
        }
        .workDeskMaterialLocationDrop(location: boardScope.location,
            isEnabled: workbenchDestinationIsActive && !isSearching,
            organization: workspace.organization,
            acceptsPoint: { point in
                let global = CGPoint(x: boardGlobalFrame.minX + point.x, y: boardGlobalFrame.minY + point.y)
                return workspace.transferCoordinator.destination(at: global)?.location == boardScope.location
            },
            positions: { payload, point in
                guard renderedLayout == .desk else { return [:] }
                return [payload.materialID: WorkDeskCanvasGeometry.worldPoint(point, transform: dropTransform)]
            }, onMoved: { _ in workspace.reconcile(materials: viewModel.desk?.materials ?? item.materials) })
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            boardGlobalFrame = frame
            updateReadableSurface()
        }
        .onChange(of: renderedLayout) { _, _ in updateReadableSurface() }
        .confirmationDialog(
            Text(LocalizedStringResource("workdesk.material.delete.title", defaultValue: "Delete this material everywhere?")),
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible, presenting: pendingRemoval
        ) { material in
            Button(LocalizedStringResource("workdesk.material.delete.everywhere", defaultValue: "Delete Everywhere"), role: .destructive) {
                pendingRemoval = nil
                Task {
                    if let child = material.companion {
                        _ = await viewModel.removeGroupFromBoard(parentID: material.id, childID: child.id)
                    } else { _ = await viewModel.removeMaterialFromBoard(material.id) }
                }
            }
        } message: { material in
            Text(material.companion == nil
                ? LocalizedStringResource("workdesk.material.delete.message", defaultValue: "This material will be deleted from Home and every project that contains it.")
                : LocalizedStringResource("workdesk.material.delete.pair", defaultValue: "This picture and its voice note will be deleted from Home and every project that contains them."))
        }
        .onChange(of: workspace.scope) { _, _ in readableReorder.cancel() }
        .onChange(of: workspace.search) { _, _ in readableReorder.cancel() }
        .onChange(of: renderedLayout) { _, _ in readableReorder.cancel() }
        .onChange(of: workspace.isSelecting) { _, _ in readableReorder.cancel() }
        .onChange(of: workbenchDestinationIsActive) { _, active in
            if !active { readableReorder.cancel() }
            updateReadableSurface()
        }
        .onDisappear { readableReorder.cancel(); workspace.transferCoordinator.removeSurface(id: readableSurfaceID) }
    }

    private var spatialBoard: some View {
        let visible = materials
        let visibleIDs = visible.map(\.id)
        let indices = Dictionary(visible.enumerated().map { ($0.element.id, $0.offset + 1) }, uniquingKeysWith: { first, _ in first })
        let projectID = project?.id
        let isHome = boardScope == .all
        let placements = workspace.organization.placements(at: boardScope.location)
        return WorkDeskCanvas(
            materials: visible,
            placements: placements,
            projects: projects,
            session: workspace.canvasSession(for: boardScope),
            selectedIDs: selectedIDs,
            isSelecting: isBoardSelecting,
            onMoveMaterials: { positions, _ in
                await workspace.organization.moveLocations(positions: positions, at: boardScope.location)
            },
            onMoveProject: { id, point in await workspace.organization.moveProject(id: id, to: point) },
            onGroup: isHome ? { ids, point in workspace.beginProject(materialIDs: ids, position: point) } : nil,
            onAssign: { ids, projectID in
                let saved = await workspace.organization.move(materialIDs: ids, from: boardScope.location, to: .project(projectID), positions: [:])
                if saved { workspace.selectedIDs.subtract(ids) }
                return saved
            },
            onSelect: selectMaterial,
            onOpenProject: { workspace.selectScope(.project($0)) },
            onSeedPositions: { materials, projects in
                await workspace.organization.seedPositions(materials: materials.map { seed in
                    var scoped = seed
                    scoped.isHome = isHome
                    return scoped
                }, projects: projects)
            },
            onCreateProject: boardScope == .all ? { point in
                workspace.beginProject(position: point)
            } : nil,
            transferCoordinator: workspace.transferCoordinator,
            transferLocation: boardScope.location,
            transferTitle: project?.title ?? String(localized: "workdesk.all", defaultValue: "Home"),
            transferPriority: transferPriority,
            onTransfer: { request in
                await workspace.transfer(request, materials: viewModel.desk?.materials ?? item.materials)
            },
            organization: workspace.organization,
            onNativeTransfer: { _ in workspace.reconcile(materials: viewModel.desk?.materials ?? item.materials) },
            onEditProject: workspace.editProject,
            onDeleteProject: workspace.requestProjectDeletion
        ) { material, size in
            sourceCard(material, spatial: true, position: indices[material.id] ?? 1, visibleIDs: visibleIDs)
                .frame(width: size.width, height: size.height)
        }
        .id(boardScope)
    }

    private var readableBoard: some View {
        let visible = materials
        let visibleIDs = visible.map(\.id)
        let indices = Dictionary(visibleIDs.enumerated().map { ($0.element, $0.offset + 1) }, uniquingKeysWith: { first, _ in first })
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if !projects.isEmpty {
                        if renderedLayout == .tiles {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 290), spacing: 16)], spacing: 16) {
                                ForEach(projects) { project in projectButton(project, row: false) }
                            }
                        } else {
                            ForEach(projects) { project in projectButton(project, row: true) }
                        }
                        if !visible.isEmpty {
                            Text(LocalizedStringResource("workdesk.home.loose", defaultValue: "On Home"))
                                .font(.caption.weight(.semibold)).foregroundStyle(AppColors.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
                        }
                    }
                    if renderedLayout == .tiles {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 250), spacing: 16)], spacing: 16) {
                            ForEach(visible) { material in
                                sourceCard(material, position: indices[material.id] ?? 1, visibleIDs: visibleIDs)
                                    .id(material.id)
                                    .frame(height: WorkDeskCanvasGeometry.cardBodySize.height)
                                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(selectedIDs.contains(material.id) ? AppColors.accent : .clear, lineWidth: 2)
                                        .allowsHitTesting(false))
                                    .overlay(alignment: .topLeading) { selectionIndicator(material) }
                                    .modifier(readableReorderCard(material))
                            }
                        }
                    } else {
                        ForEach(visible) { material in
                            sourceRow(material, position: indices[material.id] ?? 1, visibleIDs: visibleIDs)
                                .id(material.id)
                                .overlay(RoundedRectangle(cornerRadius: 13).stroke(selectedIDs.contains(material.id) ? AppColors.accent : .clear, lineWidth: 2)
                                    .allowsHitTesting(false))
                                .overlay(alignment: .topLeading) { selectionIndicator(material) }
                                .modifier(readableReorderCard(material))
                        }
                    }
                    if let lastID = visibleIDs.last { trailingReorderTarget(after: lastID) }
                }
                .padding(16)
                .frame(maxWidth: .infinity)
            }
            .dismissesKeyboardOnScrollOrTap()
            .onChange(of: workspace.materialRevealRequest?.id, initial: true) { _, _ in
                guard let request = workspace.materialRevealRequest,
                      visibleIDs.contains(request.materialID) else { return }
                proxy.scrollTo(request.materialID, anchor: .top)
                workspace.materialRevealRequest = nil
            }
        }
    }

    private func updateReadableSurface() {
        guard workbenchDestinationIsActive, renderedLayout != .desk, !isSearching else {
            workspace.transferCoordinator.removeSurface(id: readableSurfaceID)
            return
        }
        workspace.transferCoordinator.register(WorkDeskTransferSurface(id: readableSurfaceID,
            location: boardScope.location,
            title: project?.title ?? String(localized: "workdesk.all", defaultValue: "Home"),
            frame: boardGlobalFrame, priority: transferPriority, isSpatial: false))
    }

    private func projectButton(_ project: WorkDeskCanvasProject, row: Bool) -> some View {
        WorkDeskReadableProject(project: project, row: row, workspace: workspace,
            priority: transferPriority + 1)
    }

    private var canReorderReadableMaterials: Bool {
        workbenchDestinationIsActive && !isBoardSelecting
            && !viewModel.isCapturingIntoDesk && renderedLayout != .desk
    }

    private var readableReorderContext: WorkDeskReadableReorderContext {
        let live = workspace.visibleMaterials(in: viewModel.desk?.materials ?? item.materials, scope: boardScope, search: boardSearch)
        return .init(scope: boardScope, search: boardSearch, layout: renderedLayout,
                     visibleIDs: live.map(\.id), projectIDs: Dictionary(live.compactMap { material in
                         workspace.organization.projectID(for: material.id).map { (material.id, $0) }
                     }, uniquingKeysWith: { first, _ in first }),
                     locationTokens: workspace.organization.locationTokens(for: live.map(\.id)))
    }

    private func readableReorderCard(_ material: WorkboardMaterialSnapshot) -> WorkDeskReadableReorderCard {
        .init(materialID: material.id, layout: renderedLayout, isEnabled: canReorderReadableMaterials,
              reorder: readableReorder, onBegin: {
                  guard canReorderReadableMaterials else { return NSItemProvider() }
                  workspace.transferCoordinator.cancel()
                  readableReorder.begin(material.id)
                  if let sourceLocation, let payload = WorkMaterialDragPayload.deskMaterial(materialID: material.id,
                      materialIDs: [material.id], source: sourceLocation, organization: workspace.organization) {
                      return payload.itemProvider()
                  }
                  return WorkMaterialDragPayload(itemID: Constants.workboardDeskItemID, materialID: material.id).itemProvider()
              }, onDrop: dropReadableMaterial)
    }

    /// A complete final grid row still has a place to append. This stays in
    /// the scroll content so native drag autoscroll can reach the last card.
    private func trailingReorderTarget(after materialID: UUID) -> some View {
        let target = WorkDeskReadableDropTarget(materialID: materialID, placement: .after, isTrailing: true)
        return Color.clear
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onDrop(of: [.conduckWorkboardMaterial], delegate: WorkboardReorderDropDelegate(
                isEnabled: canReorderReadableMaterials && !readableReorder.isResolving,
                onLocation: { point in
                    if point != nil { readableReorder.hover(target) }
                    else { readableReorder.leave(materialID: materialID, isTrailing: true) }
                },
                onDrop: { provider, _ in dropReadableMaterial(provider, target) }
            ))
            .overlay(alignment: .top) {
                if readableReorder.target == target {
                    Capsule().fill(AppColors.accent).frame(height: 3).allowsHitTesting(false)
                }
            }
            .accessibilityHidden(true)
    }

    private func dropReadableMaterial(_ provider: NSItemProvider, _ target: WorkDeskReadableDropTarget) -> Bool {
        guard canReorderReadableMaterials,
              let token = readableReorder.accept(target, context: readableReorderContext) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.conduckWorkboardMaterial.identifier) { data, _ in
            let payload = data.flatMap { try? JSONDecoder().decode(WorkMaterialDragPayload.self, from: $0) }
            Task { @MainActor in
                guard let operation = readableReorder.resolveOperation(payload, token: token,
                    current: readableReorderContext, isEnabled: canReorderReadableMaterials,
                    locations: workspace.organization.locationTokens(for: payload?.materialIDs ?? [])),
                      let payload else { return }
                switch operation {
                case .reorder(let target):
                    _ = await reorderMaterial(payload.materialID, relativeTo: target.materialID,
                                                       placement: target.placement)
                case .move(let target, let move):
                    let ordered = readableReorderContext.visibleIDs
                    var expected = workspace.organization.locationTokens(for: ordered)
                    expected.merge(move.expected, uniquingKeysWith: { _, source in source })
                    let saved = await workspace.organization.moveAndReorder(materialIDs: move.materialIDs,
                        from: move.source, to: move.destination, relativeTo: target.materialID,
                        placement: target.placement, orderedMaterialIDs: ordered, expected: expected)
                    if saved { workspace.reconcile(materials: viewModel.desk?.materials ?? item.materials) }

                }

            }
        }
        return true
    }

    @ViewBuilder
    private func selectionIndicator(_ material: WorkboardMaterialSnapshot) -> some View {
        if isBoardSelecting {
            Image(systemName: selectedIDs.contains(material.id) ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AppColors.accent)
                .padding(6)
                .background(AppColors.cardBackgroundElevated, in: Circle())
                .padding(6)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func sourceCard(_ material: WorkboardMaterialSnapshot, spatial: Bool = false, position: Int, visibleIDs: [UUID]) -> some View {
        WorkboardSourceCard(
            material: material,
            boardPosition: position,
            boardCount: visibleIDs.count,
            onOpen: { if isBoardSelecting { selectMaterial(material.id) } else { onOpen(material) } },
            onShare: { onShare(material) },
            onReattach: { onReattach(material) },
            onMoveEarlier: spatial ? nil : moveAction(material, direction: .earlier, position: position, visibleIDs: visibleIDs),
            onMoveLater: spatial ? nil : moveAction(material, direction: .later, position: position, visibleIDs: visibleIDs),
            onRemove: { pendingRemoval = material },
            onOpenCompanion: material.companion.map { companion in { onOpen(companion.material) } },
            onShareCompanion: material.companion.map { companion in { onShare(companion.material) } },
            onReattachCompanion: material.companion.map { companion in { onReattach(companion.material) } },
            organizationActions: .init(workspace: workspace, materialID: material.id, sourceLocation: sourceLocation)
        )
        .allowsHitTesting(!isBoardSelecting)
        .overlay { if isBoardSelecting { selectionShield(material) } }
    }

    private func sourceRow(_ material: WorkboardMaterialSnapshot, position: Int, visibleIDs: [UUID]) -> some View {
        WorkboardMaterialListRow(
            material: material,
            boardPosition: position,
            boardCount: visibleIDs.count,
            onOpen: { if isBoardSelecting { selectMaterial(material.id) } else { onOpen(material) } },
            onShare: { onShare(material) },
            onReattach: { onReattach(material) },
            onMoveEarlier: moveAction(material, direction: .earlier, position: position, visibleIDs: visibleIDs),
            onMoveLater: moveAction(material, direction: .later, position: position, visibleIDs: visibleIDs),
            onRemove: { pendingRemoval = material },
            onOpenCompanion: material.companion.map { companion in { onOpen(companion.material) } },
            onShareCompanion: material.companion.map { companion in { onShare(companion.material) } },
            onReattachCompanion: material.companion.map { companion in { onReattach(companion.material) } },
            organizationActions: .init(workspace: workspace, materialID: material.id, sourceLocation: sourceLocation)
        )
        .allowsHitTesting(!isBoardSelecting)
        .overlay { if isBoardSelecting { selectionShield(material) } }
    }

    private func selectionShield(_ material: WorkboardMaterialSnapshot) -> some View {
        let actions = WorkDeskMaterialOrganizationActions(workspace: workspace, materialID: material.id, sourceLocation: sourceLocation)
        return Button { selectMaterial(material.id) } label: {
            Color.clear.contentShape(Rectangle())
        }
        .choiceCardButton(cornerRadius: 14)
        .accessibilityLabel(Text(LocalizedStringResource("workdesk.material.select", defaultValue: "Select material")))
        .accessibilityValue(Text(verbatim: material.name))
        .accessibilityAddTraits(selectedIDs.contains(material.id) ? .isSelected : [])
        .contextMenu {
            if selectedIDs.contains(material.id), actions.canStartConversation {
                Button(actions.conversationTitle, systemImage: "bubble.left.and.bubble.right") {
                    actions.startConversation()
                }
            }
        }
        .accessibilityActions {
            if selectedIDs.contains(material.id), actions.canStartConversation {
                Button(actions.conversationTitle) { actions.startConversation() }
            }
        }
    }

    private func moveAction(_ material: WorkboardMaterialSnapshot, direction: WorkboardMoveDirection, position: Int, visibleIDs: [UUID]) -> (() -> Void)? {
        let targetIndex = direction == .earlier ? position - 2 : position
        guard visibleIDs.indices.contains(targetIndex) else { return nil }
        let target = visibleIDs[targetIndex]
        return {
            Task {
                _ = await reorderMaterial(material.id, relativeTo: target,
                    placement: direction == .earlier ? .before : .after)
            }
        }
    }

    private func reorderMaterial(_ materialID: UUID, relativeTo targetID: UUID,
                                 placement: WorkboardReorderPlacement) async -> Bool {
        if isSearching { return await viewModel.reorderMaterial(materialID, relativeTo: targetID, placement: placement) }
        let current = workspace.visibleMaterials(in: viewModel.desk?.materials ?? item.materials,
            scope: boardScope, search: boardSearch).map(\.id)
        return await workspace.organization.reorder(materialID: materialID, relativeTo: targetID,
            placement: placement, at: boardScope.location, orderedMaterialIDs: current,
            expected: workspace.organization.locationTokens(for: current))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: !isSearching ? "square.stack.3d.up" : "magnifyingglass")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(AppColors.accent)
            Text(isSearching
                 ? LocalizedStringResource("workdesk.search.empty.title", defaultValue: "Nothing found")
                 : project != nil
                    ? LocalizedStringResource("workdesk.project.empty.title", defaultValue: "This project is ready for ideas")
                    : LocalizedStringResource("workdesk.empty.title", defaultValue: "Room to think"))
                .font(.title2.weight(.semibold))
            Text(isSearching
                ? LocalizedStringResource("workdesk.search.empty", defaultValue: "No ideas, files or projects match this search. Try another word.")
                : project != nil
                    ? LocalizedStringResource("workdesk.project.empty.message", defaultValue: "Capture a thought below, or move materials here from Home or another project.")
                    : LocalizedStringResource("workdesk.all.empty.message", defaultValue: "Capture a thought or add a file below. Move related materials into projects to make room on your desk."))
                .font(.subheadline).foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 340)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dismissesKeyboardOnEmptySpaceInteraction()
    }
}

/// Readable layouts keep projects as explicit containers. Registering their
/// visible bounds lets a card from a spatial project land in a Tiles/List
/// folder without replacing the native reorder path of readable material cards.
private struct WorkDeskReadableProject: View {
    let project: WorkDeskCanvasProject
    let row: Bool
    let workspace: WorkDeskWorkspaceState
    let priority: Int
    @State private var targetID = UUID()
    @State private var targetFrame: CGRect = .zero
    @State private var hovered = false
    @Environment(\.workbenchDestinationIsActive) private var isActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var highlighted: Bool {
        workspace.transferCoordinator.isDragging
            && workspace.transferCoordinator.destination?.location == .project(project.id)
    }

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) { workspace.selectScope(.project(project.id)) }
        } label: {
            WorkDeskProjectFolder(project: project, style: row ? .row : .tile, isTargeted: highlighted)
                .frame(minHeight: row ? nil : 214)
        }
        .choiceCardButton(cornerRadius: 14)
        .accessibilityHint(Text(LocalizedStringResource("workdesk.canvas.openProject", defaultValue: "Open project")))
        .accessibilityIdentifier("workdesk-project-\(project.id.uuidString)")
        .workDeskMaterialLocationDrop(location: .project(project.id), isEnabled: isActive,
            organization: workspace.organization)
        .contextMenu {
            Button(LocalizedStringResource("workdesk.project.rename", defaultValue: "Rename project"), systemImage: "pencil") {
                workspace.editProject(project.record)
            }
            WorkDeskProjectArchiveButton(project: project.record, organization: workspace.organization)
            Button(LocalizedStringResource("workdesk.project.delete.action", defaultValue: "Delete project…"), systemImage: "trash") {
                workspace.requestProjectDeletion(project.id)
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            if targetFrame != frame { workspace.transferCoordinator.hideProjectPeek(ownerID: targetID) }
            targetFrame = frame
            updateTarget()
        }
        .onHover { hovered = $0 }
        .task(id: hovered && isActive && !workspace.transferCoordinator.isDragging) {
            workspace.transferCoordinator.hideProjectPeek(ownerID: targetID)
            guard hovered, isActive, !workspace.transferCoordinator.isDragging,
                  let requestID = workspace.transferCoordinator.beginProjectPeek(ownerID: targetID) else { return }
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                workspace.transferCoordinator.showProjectPeek(ownerID: targetID, requestID: requestID, project: project, frame: targetFrame)
            }
        }
        .onChange(of: isActive) { _, active in
            if !active { hovered = false }
            updateTarget()
        }
        .onDisappear { workspace.transferCoordinator.removeSurface(id: targetID) }
    }
    private func updateTarget() {
        guard isActive else { workspace.transferCoordinator.removeSurface(id: targetID); return }
        workspace.transferCoordinator.register(WorkDeskTransferSurface(id: targetID,
            location: .project(project.id), title: project.record.title, frame: targetFrame,
            priority: priority, isSpatial: false))
    }

}
