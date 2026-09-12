// SPDX-License-Identifier: Apache-2.0

// The spatial and accessible list presentations share the existing mature card
// controls: opening, availability, repair, sharing and folded voice materials.
// Organization only passes identifiers to its own metadata store. Destructive
// removal retains the capture store's exact parent/companion confirmation.
// Every layout draws the material's own surface and menu. Selection overlays
// that surface; it never adds a second card or a permanent organization bar.
// Readable layouts share the desk's stored order. Whole-card native drags
// preview an insertion edge and commit only on release; they never file a
// material, create a project or enter the external-file import lane.

import SwiftUI
import UniformTypeIdentifiers

struct WorkDeskSourceBoard: View {
    @Bindable var viewModel: WorkboardViewModel
    let item: WorkboardItemSnapshot
    @Bindable var workspace: WorkDeskWorkspaceState
    let onOpen: (WorkboardMaterialSnapshot) -> Void
    let onShare: (WorkboardMaterialSnapshot) -> Void
    let onReattach: (WorkboardMaterialSnapshot) -> Void
    @State private var pendingRemoval: WorkboardMaterialSnapshot?
    @State private var readableReorder = WorkDeskReadableReorder()
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.workbenchDestinationIsActive) private var workbenchDestinationIsActive

    private var materials: [WorkboardMaterialSnapshot] { workspace.visibleMaterials(in: item.materials) }

    private var projects: [WorkDeskCanvasProject] {
        let query = workspace.search.trimmingCharacters(in: .whitespacesAndNewlines)
        let counts = workspace.organization.materialCounts(in: item.materials)
        return workspace.organization.projects.filter { project in
            if !query.isEmpty { return project.title.localizedStandardContains(query) }
            switch workspace.scope {
            case .all: return renderedLayout == .desk && !project.isArchived
            case .project: return false
            }
        }.map { WorkDeskCanvasProject(record: $0, materialCount: counts[$0.id] ?? 0) }
    }

    private var renderedLayout: WorkboardLayoutMode {
        WorkDeskLayoutPresentation.resolved(preference: viewModel.layoutMode,
            supportsSpatialLayout: workspace.supportsSpatialLayout,
            requiresAccessibleList: dynamicTypeSize.isAccessibilitySize)
    }

    var body: some View {
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
        .confirmationDialog(
            Text(LocalizedStringResource("workboard.material.remove.confirm.title", defaultValue: "Remove this material?")),
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible, presenting: pendingRemoval
        ) { material in
            Button(LocalizedStringResource("workboard.material.remove.action", defaultValue: "Remove Material"), role: .destructive) {
                pendingRemoval = nil
                Task {
                    if let child = material.companion {
                        _ = await viewModel.removeGroupFromBoard(parentID: material.id, childID: child.id)
                    } else { _ = await viewModel.removeMaterialFromBoard(material.id) }
                }
            }
        } message: { material in
            Text(material.companion == nil
                ? LocalizedStringResource("workdesk.material.delete.message", defaultValue: "This material will be removed from Work and its project.")
                : LocalizedStringResource("workdesk.material.delete.pair", defaultValue: "This picture and the voice note inside it will be removed from Work and its project."))
        }
        .onChange(of: workspace.scope) { _, _ in readableReorder.cancel() }
        .onChange(of: workspace.search) { _, _ in readableReorder.cancel() }
        .onChange(of: renderedLayout) { _, _ in readableReorder.cancel() }
        .onChange(of: workspace.isSelecting) { _, _ in readableReorder.cancel() }
        .onChange(of: workbenchDestinationIsActive) { _, active in
            if !active { readableReorder.cancel() }
        }
        .onDisappear { readableReorder.cancel() }
    }

    private var spatialBoard: some View {
        let visible = materials
        let visibleIDs = visible.map(\.id)
        let indices = Dictionary(visible.enumerated().map { ($0.element.id, $0.offset + 1) }, uniquingKeysWith: { first, _ in first })
        let projectID = workspace.currentProject?.id
        let isHome = workspace.scope == .all
        let placements = workspace.organization.placements.mapValues { placement in
            var displayed = placement
            if isHome { displayed.position = placement.resolvedHomePosition }
            return displayed
        }
        return WorkDeskCanvas(
            materials: visible,
            placements: placements,
            projects: projects,
            session: workspace.canvasSession(for: workspace.scope),
            selectedIDs: workspace.selectedIDs,
            isSelecting: workspace.isSelecting,
            onMoveMaterials: { positions, memberships in
                if isHome {
                    return await workspace.organization.moveHomeMaterials(positions.map { id, point in
                        .init(materialID: id, projectID: memberships[id] ?? nil, position: point, isHome: true)
                    })
                }
                return await workspace.organization.moveMaterials(positions: positions, expectedProjectID: projectID)
            },
            onMoveProject: { id, point in await workspace.organization.moveProject(id: id, to: point) },
            onGroup: isHome ? { ids, point in workspace.beginProject(materialIDs: ids, position: point) } : nil,
            onAssign: { ids, projectID in
                let saved = await workspace.organization.assign(materialIDs: ids, to: projectID)
                if saved { workspace.selectedIDs.subtract(ids) }
                return saved
            },
            onSelect: workspace.toggleSelection,
            onOpenProject: { workspace.selectScope(.project($0)) },
            onSeedPositions: { materials, projects in
                await workspace.organization.seedPositions(materials: materials.map { seed in
                    var scoped = seed
                    scoped.isHome = isHome
                    return scoped
                }, projects: projects)
            },
            onCreateProject: workspace.scope == .all ? { point in
                workspace.beginProject(position: point)
            } : nil
        ) { material, size in
            sourceCard(material, spatial: true, position: indices[material.id] ?? 1, visibleIDs: visibleIDs)
                .frame(width: size.width, height: size.height)
        }
        .id(workspace.scope)
    }

    private var readableBoard: some View {
        let visible = materials
        let visibleIDs = visible.map(\.id)
        let indices = Dictionary(visibleIDs.enumerated().map { ($0.element, $0.offset + 1) }, uniquingKeysWith: { first, _ in first })
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(projects) { project in
                        Button { workspace.selectScope(.project(project.record.id)) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill").foregroundStyle(AppColors.accent)
                                Text(verbatim: project.record.title).font(.headline)
                                Spacer()
                                Text(verbatim: String(project.materialCount)).foregroundStyle(AppColors.textSecondary)
                                Image(systemName: "chevron.right").font(.caption)
                            }
                            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 14))
                        }.choiceCardButton(cornerRadius: 14)
                    }
                    if renderedLayout == .tiles {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 250), spacing: 16)], spacing: 16) {
                            ForEach(visible) { material in
                                sourceCard(material, position: indices[material.id] ?? 1, visibleIDs: visibleIDs)
                                    .id(material.id)
                                    .frame(height: WorkDeskCanvasGeometry.cardBodySize.height)
                                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(workspace.selectedIDs.contains(material.id) ? AppColors.accent : .clear, lineWidth: 2)
                                        .allowsHitTesting(false))
                                    .overlay(alignment: .topLeading) { selectionIndicator(material) }
                                    .modifier(readableReorderCard(material))
                            }
                        }
                    } else {
                        ForEach(visible) { material in
                            sourceRow(material, position: indices[material.id] ?? 1, visibleIDs: visibleIDs)
                                .id(material.id)
                                .overlay(RoundedRectangle(cornerRadius: 13).stroke(workspace.selectedIDs.contains(material.id) ? AppColors.accent : .clear, lineWidth: 2)
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

    private var canReorderReadableMaterials: Bool {
        workbenchDestinationIsActive && !workspace.isSelecting
            && !viewModel.isCapturingIntoDesk && renderedLayout != .desk
    }

    private var readableReorderContext: WorkDeskReadableReorderContext {
        let live = workspace.visibleMaterials(in: viewModel.desk?.materials ?? item.materials)
        return .init(scope: workspace.scope, search: workspace.search, layout: renderedLayout,
                     visibleIDs: live.map(\.id), projectIDs: Dictionary(live.compactMap { material in
                         workspace.organization.projectID(for: material.id).map { (material.id, $0) }
                     }, uniquingKeysWith: { first, _ in first }))
    }

    private func readableReorderCard(_ material: WorkboardMaterialSnapshot) -> WorkDeskReadableReorderCard {
        .init(materialID: material.id, layout: renderedLayout, isEnabled: canReorderReadableMaterials,
              reorder: readableReorder, onBegin: {
                  guard canReorderReadableMaterials else { return NSItemProvider() }
                  readableReorder.begin(material.id)
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
                guard let target = readableReorder.resolve(payload, token: token,
                    current: readableReorderContext, isEnabled: canReorderReadableMaterials),
                      let payload else { return }
                _ = await viewModel.reorderMaterial(payload.materialID, relativeTo: target.materialID,
                                                   placement: target.placement)
            }
        }
        return true
    }

    @ViewBuilder
    private func selectionIndicator(_ material: WorkboardMaterialSnapshot) -> some View {
        if workspace.isSelecting {
            Image(systemName: workspace.selectedIDs.contains(material.id) ? "checkmark.circle.fill" : "circle")
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
            onOpen: { if workspace.isSelecting { workspace.toggleSelection(material.id) } else { onOpen(material) } },
            onShare: { onShare(material) },
            onReattach: { onReattach(material) },
            onMoveEarlier: spatial ? nil : moveAction(material, direction: .earlier, position: position, visibleIDs: visibleIDs),
            onMoveLater: spatial ? nil : moveAction(material, direction: .later, position: position, visibleIDs: visibleIDs),
            onRemove: { pendingRemoval = material },
            onOpenCompanion: material.companion.map { companion in { onOpen(companion.material) } },
            onShareCompanion: material.companion.map { companion in { onShare(companion.material) } },
            onReattachCompanion: material.companion.map { companion in { onReattach(companion.material) } },
            organizationActions: .init(workspace: workspace, materialID: material.id)
        )
        .allowsHitTesting(!workspace.isSelecting)
        .overlay { if workspace.isSelecting { selectionShield(material) } }
    }

    private func sourceRow(_ material: WorkboardMaterialSnapshot, position: Int, visibleIDs: [UUID]) -> some View {
        WorkboardMaterialListRow(
            material: material,
            boardPosition: position,
            boardCount: visibleIDs.count,
            onOpen: { if workspace.isSelecting { workspace.toggleSelection(material.id) } else { onOpen(material) } },
            onShare: { onShare(material) },
            onReattach: { onReattach(material) },
            onMoveEarlier: moveAction(material, direction: .earlier, position: position, visibleIDs: visibleIDs),
            onMoveLater: moveAction(material, direction: .later, position: position, visibleIDs: visibleIDs),
            onRemove: { pendingRemoval = material },
            onOpenCompanion: material.companion.map { companion in { onOpen(companion.material) } },
            onShareCompanion: material.companion.map { companion in { onShare(companion.material) } },
            onReattachCompanion: material.companion.map { companion in { onReattach(companion.material) } },
            organizationActions: .init(workspace: workspace, materialID: material.id)
        )
        .allowsHitTesting(!workspace.isSelecting)
        .overlay { if workspace.isSelecting { selectionShield(material) } }
    }

    private func selectionShield(_ material: WorkboardMaterialSnapshot) -> some View {
        let actions = WorkDeskMaterialOrganizationActions(workspace: workspace, materialID: material.id)
        return Button { workspace.toggleSelection(material.id) } label: {
            Color.clear.contentShape(Rectangle())
        }
        .choiceCardButton(cornerRadius: 14)
        .accessibilityLabel(Text(LocalizedStringResource("workdesk.material.select", defaultValue: "Select material")))
        .accessibilityValue(Text(verbatim: material.name))
        .accessibilityAddTraits(workspace.selectedIDs.contains(material.id) ? .isSelected : [])
        .contextMenu {
            if workspace.selectedIDs.contains(material.id), actions.canStartConversation {
                Button(actions.conversationTitle, systemImage: "bubble.left.and.bubble.right") {
                    actions.startConversation()
                }
            }
        }
        .accessibilityActions {
            if workspace.selectedIDs.contains(material.id), actions.canStartConversation {
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
                _ = await viewModel.reorderMaterial(material.id, relativeTo: target,
                    placement: direction == .earlier ? .before : .after)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: !workspace.isSearching ? "square.stack.3d.up" : "magnifyingglass")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(AppColors.accent)
            Text(workspace.isSearching
                 ? LocalizedStringResource("workdesk.search.empty.title", defaultValue: "Nothing found")
                 : workspace.currentProject != nil
                    ? LocalizedStringResource("workdesk.project.empty.title", defaultValue: "This project is ready for ideas")
                    : LocalizedStringResource("workdesk.empty.title", defaultValue: "Room to think"))
                .font(.title2.weight(.semibold))
            Text(workspace.isSearching
                ? LocalizedStringResource("workdesk.search.empty", defaultValue: "No ideas, files or projects match this search. Try another word.")
                : workspace.currentProject != nil
                    ? LocalizedStringResource("workdesk.project.empty.message", defaultValue: "Capture a thought below, or move materials into this project from All materials.")
                    : LocalizedStringResource("workdesk.all.empty.message", defaultValue: "Capture a thought or add a file below. Everything you collect appears here, including materials in projects."))
                .font(.subheadline).foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 340)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dismissesKeyboardOnEmptySpaceInteraction()
    }
}
