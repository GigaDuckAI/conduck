// SPDX-License-Identifier: Apache-2.0

// The spatial and accessible list presentations share the existing mature card
// controls: opening, availability, repair, sharing and folded voice materials.
// Organization only passes identifiers to its own metadata store. Destructive
// removal retains the capture store's exact parent/companion confirmation.

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
        guard workspace.scope == .desk else { return [] }
        return workspace.organization.projects.filter { project in
            workspace.search.isEmpty || project.title.localizedStandardContains(workspace.search)
        }.map { project in
            WorkDeskCanvasProject(record: project, materialCount: item.materials.filter {
                workspace.organization.projectID(for: $0.id) == project.id
            }.count)
        }
    }

    private var renderedLayout: WorkboardLayoutMode {
        WorkDeskLayoutPresentation.resolved(preference: viewModel.layoutMode,
            supportsSpatialLayout: workspace.supportsSpatialLayout,
            requiresAccessibleList: dynamicTypeSize.isAccessibilitySize)
    }

    var body: some View {
        Group {
            if materials.isEmpty && projects.isEmpty {
                emptyState
            } else if renderedLayout == .desk {
                spatialBoard
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
            onTogglePin: togglePin,
            onSeedPositions: { materials, projects in
                await workspace.organization.seedPositions(materials: materials, projects: projects)
            }
        ) { material, size in
            sourceCard(material, spatial: true, position: indices[material.id] ?? 1, count: visible.count)
                .frame(width: size.width, height: size.height)
        }
        .id(workspace.scope)
    }

    private var readableBoard: some View {
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
                        ForEach(materials) { material in
                            VStack(spacing: 0) {
                                organizationControls(material)
                                sourceCard(material).frame(height: 190)
                            }
                            .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(workspace.selectedIDs.contains(material.id) ? AppColors.accent : .clear, lineWidth: 2))
                        }
                    }
                } else {
                    ForEach(materials) { material in
                        VStack(spacing: 0) {
                            organizationControls(material)
                            sourceRow(material)
                        }
                        .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(workspace.selectedIDs.contains(material.id) ? AppColors.accent : .clear, lineWidth: 2))
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .dismissesKeyboardOnScrollOrTap()
    }

    private func organizationControls(_ material: WorkboardMaterialSnapshot) -> some View {
        HStack(spacing: 4) {
            Button { workspace.toggleSelection(material.id) } label: {
                Image(systemName: workspace.selectedIDs.contains(material.id) ? "checkmark.circle.fill" : "circle")
                    .frame(width: 44, height: 44)
            }
            .pointerIconButton(size: 44)
            .accessibilityLabel(Text(LocalizedStringResource("workdesk.material.select", defaultValue: "Select material")))
            Spacer()
            Button { togglePin(material.id) } label: {
                Image(systemName: workspace.organization.placements[material.id]?.isPinned == true ? "pin.fill" : "pin")
                    .frame(width: 44, height: 44)
            }
            .pointerIconButton(size: 44)
            .accessibilityLabel(Text(LocalizedStringResource("workdesk.pin.toggle", defaultValue: "Toggle pin")))
            Menu {
                Button(LocalizedStringResource("workdesk.group", defaultValue: "Create project")) {
                    workspace.beginProject(materialIDs: [material.id])
                }
                Button(LocalizedStringResource("workdesk.return", defaultValue: "Return to desk")) {
                    Task { await workspace.organization.assign(materialIDs: [material.id], to: nil) }
                }
                ForEach(workspace.organization.projects) { project in
                    Button { Task { await workspace.organization.assign(materialIDs: [material.id], to: project.id) } }
                    label: { Text(verbatim: project.title) }
                }
            } label: { Image(systemName: "folder").frame(width: 44, height: 44) }
            .pointerIconButton(size: 44)
            .accessibilityLabel(Text(LocalizedStringResource("workdesk.move", defaultValue: "Move to")))
        }
        .font(.caption)
        .foregroundStyle(AppColors.accent)
        .padding(.horizontal, 4)
    }

    private func togglePin(_ id: UUID) {
        let pinned = workspace.organization.placements[id]?.isPinned == true
        Task { await workspace.organization.setPinned(!pinned, materialID: id) }
    }

    private func sourceCard(_ material: WorkboardMaterialSnapshot, spatial: Bool = false, position: Int? = nil, count: Int? = nil) -> some View {
        WorkboardSourceCard(
            material: material,
            boardPosition: position ?? ((materials.firstIndex(where: { $0.id == material.id }) ?? 0) + 1),
            boardCount: count ?? materials.count,
            onOpen: { if workspace.isSelecting { workspace.toggleSelection(material.id) } else { onOpen(material) } },
            onShare: { onShare(material) },
            onReattach: { onReattach(material) },
            onMoveEarlier: spatial ? nil : moveAction(material, direction: .earlier),
            onMoveLater: spatial ? nil : moveAction(material, direction: .later),
            onRemove: { pendingRemoval = material },
            onOpenCompanion: material.companion.map { companion in { onOpen(companion.material) } },
            onShareCompanion: material.companion.map { companion in { onShare(companion.material) } },
            onReattachCompanion: material.companion.map { companion in { onReattach(companion.material) } }
        )
        .allowsHitTesting(!workspace.isSelecting)
        .overlay { if workspace.isSelecting { selectionShield(material) } }
    }

    private func sourceRow(_ material: WorkboardMaterialSnapshot) -> some View {
        WorkboardMaterialListRow(
            material: material,
            boardPosition: (materials.firstIndex(where: { $0.id == material.id }) ?? 0) + 1,
            boardCount: materials.count,
            onOpen: { if workspace.isSelecting { workspace.toggleSelection(material.id) } else { onOpen(material) } },
            onShare: { onShare(material) },
            onReattach: { onReattach(material) },
            onMoveEarlier: moveAction(material, direction: .earlier),
            onMoveLater: moveAction(material, direction: .later),
            onRemove: { pendingRemoval = material },
            onOpenCompanion: material.companion.map { companion in { onOpen(companion.material) } },
            onShareCompanion: material.companion.map { companion in { onShare(companion.material) } },
            onReattachCompanion: material.companion.map { companion in { onReattach(companion.material) } }
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

    private func moveAction(_ material: WorkboardMaterialSnapshot, direction: WorkboardMoveDirection) -> (() -> Void)? {
        guard let target = WorkDeskWorkspaceState.moveTarget(material.id, direction: direction, visibleIDs: materials.map(\.id)) else { return nil }
        return {
            Task {
                _ = await viewModel.reorderMaterial(material.id, relativeTo: target,
                    placement: direction == .earlier ? .before : .after)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: workspace.search.isEmpty ? "square.stack.3d.up" : "magnifyingglass")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(AppColors.accent)
            Text(LocalizedStringResource("workdesk.empty.title", defaultValue: "Room to think"))
                .font(.title2.weight(.semibold))
            Text(workspace.search.isEmpty
                ? LocalizedStringResource("workdesk.empty.message", defaultValue: "Capture a thought below, or bring ideas together in a project. Everything starts on your desk.")
                : LocalizedStringResource("workdesk.search.empty", defaultValue: "No matching materials here. Try another word or look in All materials."))
                .font(.subheadline).foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 340)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dismissesKeyboardOnEmptySpaceInteraction()
    }
}
