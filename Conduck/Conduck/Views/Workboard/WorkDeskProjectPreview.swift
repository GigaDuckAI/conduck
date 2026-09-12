// SPDX-License-Identifier: Apache-2.0

// The Home contents preview reads the entire live project in its readable order.
// Row gestures carry the source appearance and frozen revision tokens through
// the same workspace coordinator as Desk cards. The
// existing destination/store lane owns moving, companion groups and Undo.
// The panel remains open during transfers. Its chrome occludes Home while the
// list is a distinct project drop target, so nothing files through the panel.
// Compact sheets provide the same explicit Move/Add actions without requiring
// a drag to a destination hidden behind the sheet. Opening a material delegates
// to the established details/availability flow after this preview dismisses.

import SwiftUI

struct WorkDeskProjectPreview: View {
    @Bindable var viewModel: WorkboardViewModel
    let item: WorkboardItemSnapshot
    @Bindable var workspace: WorkDeskWorkspaceState
    let request: WorkDeskProjectPreviewRequest
    let isCompact: Bool
    let onOpen: (WorkboardMaterialSnapshot) -> Void
    let onOpenProject: () -> Void
    let onClose: () -> Void
    @State private var panelFrame: CGRect = .zero
    @State private var listFrame: CGRect = .zero
    @State private var surfaceID = UUID()
    @State private var occlusionID = UUID()
    @State private var dragToken: UUID?
    @State private var draggingMaterialID: UUID?
    @State private var cancellationGeneration = 0
    @Environment(\.workbenchDestinationIsActive) private var isActive
    @FocusState private var closeFocused: Bool

    private var project: WorkDeskProjectRecord? { workspace.organization.project(id: request.projectID) }
    private var materials: [WorkboardMaterialSnapshot] {
        workspace.visibleMaterials(in: viewModel.desk?.materials ?? item.materials,
            scope: .project(request.projectID), search: "")
    }
    private var canInteract: Bool {
        isActive && workspace.projectPreview.request?.id == request.id && project != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(spacing: 2) {
                    if materials.isEmpty {
                        Text(LocalizedStringResource("workdesk.project.previewEmpty", defaultValue: "Drop materials into this project"))
                            .font(.subheadline).foregroundStyle(AppColors.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 110).padding(16)
                    } else {
                        ForEach(materials) { material in
                            WorkDeskProjectPreviewRow(material: material, workspace: workspace,
                                request: request, allowsDrag: !isCompact && canInteract && !viewModel.isCapturingIntoDesk,
                                cancellationGeneration: cancellationGeneration,
                                onDragChanged: { value, frame in updateDrag(material, value: value, frame: frame) },
                                onDragEnded: { value, frame in finishDrag(material, value: value, frame: frame) },
                                onDragCancelled: { cancelDrag(materialID: material.id) },
                                onOpen: { onOpen(material) })
                        }
                    }
                }.padding(.horizontal, 8).padding(.vertical, 6)
            }
            .scrollDismissesKeyboard(.interactively)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                listFrame = $0
                registerTargets()
            }
            if let error = workspace.organization.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Text(verbatim: error).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(LocalizedStringResource("common.ok", defaultValue: "OK")) {
                        workspace.organization.errorMessage = nil
                    }.inlineLinkButton()
                }
                .foregroundStyle(AppColors.textSecondary).padding(12)
            }
            Divider().opacity(0.5)
            HStack {
                Spacer(minLength: 0)
                Button(action: onOpenProject) {
                    Label(LocalizedStringResource("workdesk.project.preview.open", defaultValue: "Open project"),
                          systemImage: "arrow.up.right")
                        .font(.subheadline.weight(.semibold)).padding(.horizontal, 10).frame(minHeight: 44)
                }
                .inlineLinkButton().foregroundStyle(AppColors.brandAmber)
                .accessibilityIdentifier("workdesk-preview-open-project")
            }.padding(.horizontal, 10).padding(.vertical, 4)
        }
        .foregroundStyle(AppColors.textPrimary)
        .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 17))
        .overlay { RoundedRectangle(cornerRadius: 17).strokeBorder(AppColors.borderSubtle).allowsHitTesting(false) }
        .clipShape(RoundedRectangle(cornerRadius: 17))
        .workDeskMaterialLocationDrop(location: .project(request.projectID), isEnabled: canInteract,
            organization: workspace.organization,
            acceptsPoint: { point in
                let global = CGPoint(x: panelFrame.minX + point.x, y: panelFrame.minY + point.y)
                return listFrame.contains(global)
                    && workspace.transferCoordinator.destination(at: global)?.surfaceID == surfaceID
            }, onMoved: { _ in workspace.reconcile(materials: viewModel.desk?.materials ?? item.materials) })
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            panelFrame = frame
            workspace.projectPreview.updatePanelFrame(frame, requestID: request.id)
            registerTargets()
        }
        .onChange(of: isActive) { _, _ in registerTargets() }
        .onChange(of: project?.title) { _, _ in registerTargets() }
        .onChange(of: workspace.projectPreview.request?.id) { _, _ in registerTargets() }
        .onAppear { closeFocused = true }
        .onDisappear {
            cancelDrag()
            workspace.transferCoordinator.removeSurface(id: surfaceID)
            workspace.transferCoordinator.removeOcclusion(id: occlusionID)
        }
        .onKeyPress(.escape) {
            if draggingMaterialID != nil {
                cancellationGeneration &+= 1
                cancelDrag()
                return .handled
            }
            guard !workspace.transferCoordinator.isDragging else { return .ignored }
            onClose()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workdesk-project-preview")
    }

    private func updateDrag(_ material: WorkboardMaterialSnapshot, value: DragGesture.Value, frame: CGRect) {
        guard canInteract, !viewModel.isCapturingIntoDesk else { cancelDrag(); return }
        let coordinator = workspace.transferCoordinator
        if draggingMaterialID == nil {
            guard listFrame.minX.isFinite, listFrame.minY.isFinite,
                  listFrame.maxX.isFinite, listFrame.maxY.isFinite,
                  listFrame.width > 0, listFrame.height > 0,
                  !coordinator.isDragging,
                  workspace.organization.contains(materialID: material.id, at: .project(request.projectID)),
                  let token = workspace.projectPreview.beginDrag(requestID: request.id) else { return }
            dragToken = token
            draggingMaterialID = material.id
            registerTargets()
            // Freeze source revisions before any membership or remote refresh.
            coordinator.update(sourceSurfaceID: surfaceID, source: .project(request.projectID),
                leadMaterial: material, origins: [material.id: .init(x: 0, y: 0)],
                pointer: value.startLocation, leadFrame: frame,
                expected: workspace.organization.locationTokens(for: [material.id]))
        }
        guard draggingMaterialID == material.id else { return }
        coordinator.update(sourceSurfaceID: surfaceID, source: .project(request.projectID),
            leadMaterial: material, origins: [material.id: .init(x: 0, y: 0)],
            pointer: value.location,
            leadFrame: frame.offsetBy(dx: value.translation.width, dy: value.translation.height))
    }

    private func finishDrag(_ material: WorkboardMaterialSnapshot, value: DragGesture.Value, frame: CGRect) {
        guard draggingMaterialID == material.id else { return }
        updateDrag(material, value: value, frame: frame)
        let release = workspace.transferCoordinator.release(sourceSurfaceID: surfaceID)
        // Release ownership before an async move can remove the source row.
        workspace.projectPreview.endDrag(token: dragToken)
        dragToken = nil
        draggingMaterialID = nil
        guard case .transfer(let transfer) = release else { return }
        Task { await workspace.transfer(transfer, materials: viewModel.desk?.materials ?? item.materials) }
    }

    private func cancelDrag(materialID: UUID? = nil) {
        if let materialID, draggingMaterialID != materialID { return }
        workspace.transferCoordinator.cancel(sourceSurfaceID: surfaceID)
        workspace.projectPreview.endDrag(token: dragToken)
        dragToken = nil
        draggingMaterialID = nil
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.title3).foregroundStyle(project?.color.tint ?? AppColors.brandAmber)
                .padding(.top, 3).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: project?.title ?? "").font(.title3.weight(.semibold)).lineLimit(2)
                Text(WorkDeskCopy.materialCount(materials.count)).font(.caption).foregroundStyle(AppColors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).accessibilityAddTraits(.isHeader)
            Button(action: onClose) { Image(systemName: "xmark").frame(width: closeSize, height: closeSize) }
                .pointerIconButton(size: closeSize).focused($closeFocused)
                .accessibilityLabel(Text(LocalizedStringResource("workdesk.project.preview.close", defaultValue: "Close preview")))
        }.padding(.leading, 18).padding(.trailing, 10).padding(.top, 14).padding(.bottom, 8)
    }

    private var closeSize: CGFloat {
        #if os(macOS)
        36
        #else
        44
        #endif
    }

    private func registerTargets() {
        guard canInteract else {
            workspace.transferCoordinator.removeSurface(id: surfaceID)
            workspace.transferCoordinator.removeOcclusion(id: occlusionID)
            return
        }
        workspace.transferCoordinator.registerOcclusion(id: occlusionID, frame: panelFrame, priority: 40)
        workspace.transferCoordinator.register(.init(id: surfaceID, location: .project(request.projectID),
            title: project?.title ?? "", frame: listFrame, priority: 50, isSpatial: false))
    }
}

private struct WorkDeskProjectPreviewRow: View {
    let material: WorkboardMaterialSnapshot
    let workspace: WorkDeskWorkspaceState
    let request: WorkDeskProjectPreviewRequest
    let allowsDrag: Bool
    let cancellationGeneration: Int
    let onDragChanged: (DragGesture.Value, CGRect) -> Void
    let onDragEnded: (DragGesture.Value, CGRect) -> Void
    let onDragCancelled: () -> Void
    let onOpen: () -> Void

    private var actions: WorkDeskMaterialOrganizationActions {
        .init(workspace: workspace, materialID: material.id, sourceLocation: .project(request.projectID))
    }

    var body: some View {
        row
            .accessibilityElement(children: .contain)
            .contextMenu { organizationMenu }
            .accessibilityIdentifier("workdesk-preview-material-\(material.id.uuidString)")
    }

    private var row: some View {
        HStack(spacing: 0) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    WorkDeskProjectMaterialGlimpse(material: material)
                        .frame(width: 46, height: 46).clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: material.name).font(.subheadline.weight(.medium)).lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(material.kind.title).font(.caption).foregroundStyle(AppColors.textSecondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(10).frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            }.choiceCardButton(cornerRadius: 10)
            .modifier(WorkDeskProjectPreviewDrag(isEnabled: allowsDrag,
                cancellationGeneration: cancellationGeneration, onChanged: onDragChanged,
                onEnded: onDragEnded, onCancelled: onDragCancelled))
            Menu { organizationMenu } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 44)
            }
            .pointerIconButton(size: 44)
            .accessibilityLabel(Text(LocalizedStringResource("workdesk.project.preview.materialActions", defaultValue: "Material actions")))
            .disabled(workspace.organization.isSaving)
        }
    }

    @ViewBuilder private var organizationMenu: some View {
        if actions.canMoveHome {
            Button(LocalizedStringResource("workdesk.moveToHome", defaultValue: "Move to Home"), systemImage: "tray.and.arrow.up") {
                Task { await actions.move(to: nil) }
            }
        }
        if actions.canMove, !actions.destinations.isEmpty {
            Menu {
                ForEach(actions.destinations) { destination in
                    Button { Task { await actions.move(to: destination.id) } }
                        label: { Text(verbatim: destination.title) }
                }
            } label: { Label(LocalizedStringResource("workdesk.move", defaultValue: "Move to"), systemImage: "folder") }
        }
        if !actions.additionalDestinations.isEmpty {
            Menu {
                ForEach(actions.additionalDestinations) { destination in
                    Button { Task { await actions.add(to: destination.id) } }
                        label: { Text(verbatim: destination.title) }
                }
            } label: {
                Label(LocalizedStringResource("workdesk.addToAnotherProject", defaultValue: "Add to another project…"),
                      systemImage: "folder.badge.plus")
            }
        }
    }

}
