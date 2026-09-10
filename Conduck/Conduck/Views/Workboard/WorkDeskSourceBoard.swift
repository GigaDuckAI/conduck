// SPDX-License-Identifier: Apache-2.0

// The spatial and accessible list presentations share the existing mature card
// controls: opening, availability, repair, sharing and folded voice materials.
// Organization only passes identifiers to its own metadata store. Destructive
// removal retains the capture store's exact parent/companion confirmation.
// Every layout draws the material's own surface and menu. Selection overlays
// that surface; it never adds a second card or a permanent organization bar.

import SwiftUI

struct WorkDeskSourceBoard: View {
    @Bindable var viewModel: WorkboardViewModel
    let item: WorkboardItemSnapshot
    @Bindable var workspace: WorkDeskWorkspaceState
    let onOpen: (WorkboardMaterialSnapshot) -> Void
    let onShare: (WorkboardMaterialSnapshot) -> Void
    let onReattach: (WorkboardMaterialSnapshot) -> Void
    @State private var pendingRemoval: WorkboardMaterialSnapshot?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var materials: [WorkboardMaterialSnapshot] { workspace.visibleMaterials(in: item.materials) }

    private var projects: [WorkDeskCanvasProject] {
        let query = workspace.search.trimmingCharacters(in: .whitespacesAndNewlines)
        let counts = workspace.organization.materialCounts(in: item.materials)
        return workspace.organization.projects.filter { project in
            if !query.isEmpty { return project.title.localizedStandardContains(query) }
            switch workspace.scope {
            case .desk: return true
            case .pinned: return project.isPinned
            case .all, .project: return false
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
    }

    private var spatialBoard: some View {
        let visible = materials
        let visibleIDs = visible.map(\.id)
        let indices = Dictionary(visible.enumerated().map { ($0.element.id, $0.offset + 1) }, uniquingKeysWith: { first, _ in first })
        let projectID = workspace.currentProject?.id
        return WorkDeskCanvas(
            materials: visible,
            placements: workspace.organization.placements,
            projects: projects,
            session: workspace.canvasSession(for: workspace.scope),
            selectedIDs: workspace.selectedIDs,
            isSelecting: workspace.isSelecting,
            onMoveMaterials: { positions in
                await workspace.organization.moveMaterials(positions: positions, expectedProjectID: projectID)
            },
            onMoveProject: { id, point in await workspace.organization.moveProject(id: id, to: point) },
            onGroup: { ids, point in workspace.beginProject(materialIDs: ids, position: projectID == nil ? point : nil) },
            onAssign: { ids, projectID in
                let saved = await workspace.organization.assign(materialIDs: ids, to: projectID)
                if saved { workspace.selectedIDs.subtract(ids) }
                return saved
            },
            onSelect: workspace.toggleSelection,
            onOpenProject: { workspace.selectScope(.project($0)) },
            onSeedPositions: { materials, projects in
                await workspace.organization.seedPositions(materials: materials, projects: projects)
            },
            onCreateProject: workspace.scope == .desk ? { point in
                workspace.beginProject(position: point)
            } : nil,
            onToggleProjectPin: { id in
                guard let project = workspace.organization.project(id: id) else { return }
                Task { await workspace.organization.setProjectPinned(!project.isPinned, id: id) }
            }
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
        return ScrollView {
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
                                .frame(height: 190)
                                .overlay(RoundedRectangle(cornerRadius: 13).stroke(workspace.selectedIDs.contains(material.id) ? AppColors.accent : .clear, lineWidth: 2)
                                    .allowsHitTesting(false))
                                .overlay(alignment: .topLeading) { selectionIndicator(material) }
                        }
                    }
                } else {
                    ForEach(visible) { material in
                        sourceRow(material, position: indices[material.id] ?? 1, visibleIDs: visibleIDs)
                            .overlay(RoundedRectangle(cornerRadius: 13).stroke(workspace.selectedIDs.contains(material.id) ? AppColors.accent : .clear, lineWidth: 2)
                                .allowsHitTesting(false))
                            .overlay(alignment: .topLeading) { selectionIndicator(material) }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .dismissesKeyboardOnScrollOrTap()
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
        Button { workspace.toggleSelection(material.id) } label: {
            Color.clear.contentShape(Rectangle())
        }
        .choiceCardButton(cornerRadius: 14)
        .accessibilityLabel(Text(LocalizedStringResource("workdesk.material.select", defaultValue: "Select material")))
        .accessibilityValue(Text(verbatim: material.name))
        .accessibilityAddTraits(workspace.selectedIDs.contains(material.id) ? .isSelected : [])
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
                 : LocalizedStringResource("workdesk.empty.title", defaultValue: "Room to think"))
                .font(.title2.weight(.semibold))
            Text(!workspace.isSearching
                ? LocalizedStringResource("workdesk.empty.message", defaultValue: "Capture a thought below, or bring ideas together in a project. Everything starts on your desk.")
                : LocalizedStringResource("workdesk.search.empty", defaultValue: "No ideas, files or projects match this search. Try another word."))
                .font(.subheadline).foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 340)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dismissesKeyboardOnEmptySpaceInteraction()
    }
}
