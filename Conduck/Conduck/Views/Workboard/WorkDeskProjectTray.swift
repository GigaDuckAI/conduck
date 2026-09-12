// SPDX-License-Identifier: Apache-2.0

// Opening a project preserves Home's mounted board, camera and card positions.
// A bounded tray has its own remembered layout. Compact windows retain a Home
// return/drop strip; larger windows expose the desk around a movable tray.
// The tray blocks drop-through at its chrome while its content and Home remain
// independent destinations. No preview, opening or filing operation sends work.

import SwiftUI

nonisolated enum WorkDeskProjectTrayGeometry {
    static func isCompact(_ size: CGSize) -> Bool { size.width < 680 || size.height < 430 }

    static func frame(in size: CGSize, expanded: Bool, offset: CGSize = .zero) -> CGRect {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return .zero }
        let compact = isCompact(size)
        let inset: CGFloat = compact ? 8 : 18
        let top: CGFloat = compact || expanded ? 52 : 18
        let width = compact || expanded ? max(0, size.width - inset * 2)
            : min(680, max(460, size.width * 0.68), max(0, size.width - 160))
        let availableHeight = max(0, size.height - top - inset)
        let height = compact || expanded ? availableHeight : min(availableHeight, max(360, size.height * 0.86))
        let origin = CGPoint(x: size.width - width - inset, y: top)
        let proposedX = origin.x + (offset.width.isFinite ? offset.width : 0)
        let proposedY = origin.y + (offset.height.isFinite ? offset.height : 0)
        return CGRect(x: min(max(inset, proposedX), max(inset, size.width - width - inset)),
                      y: min(max(top, proposedY), max(top, size.height - height - inset)),
                      width: width, height: height)
    }
}

struct WorkDeskProjectSurface: View {
    @Bindable var viewModel: WorkboardViewModel
    let item: WorkboardItemSnapshot
    @Bindable var workspace: WorkDeskWorkspaceState
    let onOpen: (WorkboardMaterialSnapshot) -> Void
    let onShare: (WorkboardMaterialSnapshot) -> Void
    let onReattach: (WorkboardMaterialSnapshot) -> Void
    @State private var expanded = false
    @State private var trayOffset: CGSize = .zero
    @State private var dragOrigin: CGSize?
    @State private var occlusionID = UUID()
    @State private var homeTargetID = UUID()
    @State private var trayGlobalFrame: CGRect = .zero
    @State private var homeGlobalFrame: CGRect = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.workbenchDestinationIsActive) private var isActive
    @Environment(\.workDeskConversationResolver) private var conversationResolver

    private var motion: Animation? { reduceMotion ? nil : .snappy(duration: 0.28, extraBounce: 0.02) }

    var body: some View {
        GeometryReader { geometry in
            let compact = WorkDeskProjectTrayGeometry.isCompact(geometry.size) || dynamicTypeSize.isAccessibilitySize
            let trayFrame = WorkDeskProjectTrayGeometry.frame(in: geometry.size,
                expanded: expanded || dynamicTypeSize.isAccessibilitySize, offset: trayOffset)
            ZStack(alignment: .topLeading) {
                board(scope: .all, priority: 0)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                if let project = workspace.currentProject, workspace.isProjectTrayPresented {
                    if compact || expanded {
                        homeReturnStrip
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .padding(.horizontal, 8)
                            .zIndex(20)
                    }
                    projectTray(project, compact: compact)
                        .frame(width: trayFrame.width, height: trayFrame.height)
                        .background(AppColors.background, in: RoundedRectangle(cornerRadius: compact ? 18 : 22))
                        .overlay {
                            RoundedRectangle(cornerRadius: compact ? 18 : 22)
                                .strokeBorder(AppColors.brandAmber.opacity(0.28), lineWidth: 1)
                                .allowsHitTesting(false)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: compact ? 18 : 22))
                        .shadow(color: .black.opacity(0.25), radius: 22, x: 0, y: 10)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                            guard workspace.currentProject?.id == project.id else { return }
                            trayGlobalFrame = frame
                            updateTargets()
                        }
                        .onDisappear {
                            if workspace.currentProject?.id == project.id {
                                workspace.transferCoordinator.removeOcclusion(id: occlusionID)
                            }
                        }
                        .offset(x: trayFrame.minX, y: trayFrame.minY)
                        .transition(trayTransition(for: project.id, frame: trayFrame, container: geometry.frame(in: .global)))
                        .zIndex(10)
                        .id(project.id)
                }
            }
            .overlay { WorkDeskProjectPeekOverlay(coordinator: workspace.transferCoordinator) }
            .overlay { WorkDeskTransferOverlay(coordinator: workspace.transferCoordinator).allowsHitTesting(false) }
            .animation(motion, value: workspace.isProjectTrayPresented)
            .animation(motion, value: workspace.currentProject?.id)
            .animation(motion, value: expanded)
            .onChange(of: workspace.currentProject?.id) { _, _ in
                trayOffset = .zero
                expanded = false
                dragOrigin = nil
                updateTargets()
            }
        }
        .onChange(of: isActive) { _, _ in updateTargets() }
        .onChange(of: workspace.isProjectTrayPresented) { _, presented in
            if !presented { removeTargets() }
        }
        .onDisappear { removeTargets() }
    }

    private func trayTransition(for projectID: UUID, frame: CGRect, container: CGRect) -> AnyTransition {
        guard !reduceMotion, frame.width > 0,
              let folder = workspace.transferCoordinator.projectFrame(id: projectID),
              container.intersects(folder) else {
            return reduceMotion ? .opacity : .scale(scale: 0.94, anchor: .topTrailing).combined(with: .opacity)
        }
        let scale = min(1, max(0.12, folder.width / frame.width))
        let offset = CGSize(width: folder.minX - container.minX - frame.minX,
                            height: folder.minY - container.minY - frame.minY)
        return .modifier(active: WorkDeskTrayOpening(scale: scale, translation: offset, opacity: 0),
                         identity: WorkDeskTrayOpening(scale: 1, translation: .zero, opacity: 1))
    }

    private func updateTargets() {
        guard isActive, workspace.isProjectTrayPresented else { removeTargets(); return }
        workspace.transferCoordinator.registerOcclusion(id: occlusionID, frame: trayGlobalFrame, priority: 10)
        if homeGlobalFrame.width > 0 {
            workspace.transferCoordinator.register(WorkDeskTransferSurface(id: homeTargetID, location: .home,
                title: String(localized: "workdesk.all", defaultValue: "Home"), frame: homeGlobalFrame,
                priority: 30, isSpatial: false))
        }
    }

    private func removeTargets() {
        workspace.transferCoordinator.removeOcclusion(id: occlusionID)
        workspace.transferCoordinator.removeSurface(id: homeTargetID)
    }

    private func board(scope: WorkDeskScope, priority: Int) -> some View {
        WorkDeskSourceBoard(viewModel: viewModel, item: item, workspace: workspace,
            onOpen: onOpen, onShare: onShare, onReattach: onReattach,
            scopeOverride: scope, transferPriority: priority)
    }

    private var homeReturnStrip: some View {
        Button { closeProject() } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                Image(systemName: "tray")
                Text(LocalizedStringResource("workdesk.all", defaultValue: "Home"))
                Spacer()
                if workspace.transferCoordinator.isDragging {
                    Text(LocalizedStringResource("workdesk.tray.dropHome", defaultValue: "Drop here to move to Home"))
                        .font(.caption).lineLimit(1)
                }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12).frame(minHeight: 44)
            .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 12))
        }
        .choiceCardButton(cornerRadius: 12)
        .accessibilityIdentifier("workdesk-tray-home")
        .workDeskMaterialLocationDrop(location: .home, isEnabled: isActive,
            organization: workspace.organization)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            homeGlobalFrame = frame
            updateTargets()
        }
        .onDisappear {
            homeGlobalFrame = .zero
            workspace.transferCoordinator.removeSurface(id: homeTargetID)
        }
    }

    private func projectTray(_ project: WorkDeskProjectRecord, compact: Bool) -> some View {
        VStack(spacing: 0) {
            trayHeader(project, compact: compact)
            Divider().opacity(0.4)
            board(scope: .project(project.id), priority: 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityIdentifier("workdesk-project-tray")
    }

    private func trayHeader(_ project: WorkDeskProjectRecord, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    projectTitle(project)
                    Spacer(minLength: 4)
                    trayWindowControls(compact: compact)
                }
                VStack(alignment: .leading, spacing: 0) {
                    HStack { Spacer(); trayWindowControls(compact: compact) }
                    projectTitle(project)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    trayProjectActions(project)
                    Spacer(minLength: 2)
                    trayMaterialActions(project)
                }
                VStack(alignment: .leading, spacing: 0) {
                    trayProjectActions(project)
                    HStack { Spacer(); trayMaterialActions(project) }
                }
            }
            if workspace.isSelecting { traySelectionActions(project) }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(AppColors.brandAmber.opacity(0.045))
    }

    private func projectTitle(_ project: WorkDeskProjectRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill").font(.title3).foregroundStyle(AppColors.brandAmber)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: project.title).font(.headline).lineLimit(2)
                Text(WorkDeskCopy.materialCount(workspace.visibleMaterials(in: item.materials,
                    scope: .project(project.id), search: "").count))
                    .font(.caption).foregroundStyle(AppColors.textSecondary)
            }
        }
        .frame(minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func trayWindowControls(compact: Bool) -> some View {
        HStack(spacing: 0) {
            if !compact {
                Button { withAnimation(motion) { trayOffset = .zero } } label: {
                    Image(systemName: "circle.grid.2x2.fill")
                        .foregroundStyle(AppColors.textTertiary).frame(width: 44, height: 44)
                }
                    .pointerIconButton(size: 44)
                    .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                        .onChanged { value in
                            if dragOrigin == nil { dragOrigin = trayOffset }
                            let origin = dragOrigin ?? .zero
                            trayOffset = CGSize(width: origin.width + value.translation.width,
                                                height: origin.height + value.translation.height)
                        }
                        .onEnded { _ in dragOrigin = nil })
                    .accessibilityLabel(Text(LocalizedStringResource("workdesk.tray.move", defaultValue: "Move project tray")))
                    .accessibilityAction(named: Text(LocalizedStringResource("workdesk.tray.moveLeft", defaultValue: "Move tray left"))) {
                        trayOffset.width -= 80
                    }
                    .accessibilityAction(named: Text(LocalizedStringResource("workdesk.tray.moveRight", defaultValue: "Move tray right"))) {
                        trayOffset.width += 80
                    }
                Button {
                    withAnimation(motion) { expanded.toggle(); trayOffset = .zero }
                } label: {
                    Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .frame(width: 44, height: 44)
                }
                .pointerIconButton(size: 44)
                .accessibilityLabel(Text(expanded
                    ? LocalizedStringResource("workdesk.tray.restore", defaultValue: "Restore project tray")
                    : LocalizedStringResource("workdesk.tray.expand", defaultValue: "Expand project tray")))
            }
            Button { closeProject() } label: {
                Image(systemName: "xmark").frame(width: 44, height: 44)
            }
            .pointerIconButton(size: 44)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(Text(LocalizedStringResource("workdesk.tray.close", defaultValue: "Close project")))
            .accessibilityIdentifier("workdesk-tray-close")
        }
    }

    private func trayProjectActions(_ project: WorkDeskProjectRecord) -> some View {
        HStack(spacing: 4) {
            Menu {
                Button(LocalizedStringResource("workdesk.conversation.new", defaultValue: "New conversation…"),
                       systemImage: "bubble.left.and.bubble.right") { newConversation(project) }
                Button(WorkDeskCopy.projectBriefState(hasBrief: !project.brief.isEmpty), systemImage: "text.alignleft") {
                    workspace.editingContextProjectID = project.id
                }
                if !workspace.conversations(in: project.id).isEmpty {
                    Menu {
                        ForEach(workspace.conversations(in: project.id)) { conversation in
                            Button { workspace.selectConversation(conversation.id, projectID: project.id) } label: {
                                Text(verbatim: conversation.displayTitle)
                            }
                        }
                    } label: {
                        Label(LocalizedStringResource("workdesk.tray.conversations", defaultValue: "Conversations"), systemImage: "bubble.left.and.bubble.right")
                    }
                }
                Divider()
                Button(LocalizedStringResource("workdesk.project.rename", defaultValue: "Rename project"), systemImage: "pencil") {
                    workspace.editProject(project)
                }
                Button(LocalizedStringResource("workdesk.project.delete.action", defaultValue: "Delete project…"), systemImage: "trash") {
                    workspace.requestProjectDeletion(project.id)
                }
            } label: {
                Label(LocalizedStringResource("workdesk.tray.projectActions", defaultValue: "Project"), systemImage: "ellipsis.circle")
                    .font(.subheadline).padding(.horizontal, 6).frame(minHeight: 44)
            }
            .pointerIconButton(size: 44)
            .accessibilityLabel(Text(LocalizedStringResource("workdesk.tray.projectActionsLabel", defaultValue: "Project actions")))
            if !workspace.isSelecting {
                Button { newConversation(project) } label: {
                    Label(LocalizedStringResource("workdesk.conversation.new", defaultValue: "New conversation…"),
                          systemImage: "bubble.left.and.bubble.right")
                        .font(.subheadline.weight(.medium)).padding(.horizontal, 6).frame(minHeight: 44)
                }
                .inlineLinkButton()
                .foregroundStyle(AppColors.brandAmber)
                .accessibilityIdentifier("workdesk-tray-new-conversation")
            }
        }
    }

    private func trayMaterialActions(_ project: WorkDeskProjectRecord) -> some View {
        HStack(spacing: 4) {
            if !workspace.isSelecting {
                WorkDeskLayoutControl(viewModel: viewModel, supportsSpatialLayout: true,
                    compact: true, scope: .project(project.id))
            }
            Button {
                workspace.isSelecting.toggle()
                if !workspace.isSelecting { workspace.selectedIDs = [] }
            } label: {
                Text(workspace.isSelecting ? LocalizedStringResource("common.done", defaultValue: "Done")
                     : LocalizedStringResource("workdesk.select", defaultValue: "Select"))
                    .font(.subheadline).padding(.horizontal, 8).frame(minHeight: 44)
            }
            .inlineLinkButton()
        }
    }

    private func traySelectionActions(_ project: WorkDeskProjectRecord) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button(LocalizedStringResource("workdesk.select.all", defaultValue: "Select all")) {
                    workspace.selectedIDs = Set(workspace.visibleMaterials(in: item.materials,
                        scope: .project(project.id), search: "").map(\.id))
                }.buttonStyle(.bordered)
                Button(WorkDeskMaterialConversationCopy.title(count: workspace.selectedIDs.count),
                       systemImage: "bubble.left.and.bubble.right") {
                    let resolver = WorkDeskConversationResolver(resolve: { [weak workspace, conversationResolver] id in
                        workspace?.conversationModel(for: id, resolver: conversationResolver)
                    }, reportVisible: conversationResolver.reportVisible)
                    _ = workspace.beginConversation(materialIDs: workspace.selectedIDs, materials: item.materials, resolver: resolver)
                }.buttonStyle(.bordered).disabled(workspace.selectedIDs.isEmpty)
                Menu {
                    Button(LocalizedStringResource("workdesk.moveToHome", defaultValue: "Move to Home")) {
                        Task { await workspace.assignSelection(to: nil, materials: item.materials) }
                    }
                    ForEach(workspace.organization.projects.filter { $0.id != project.id }) { target in
                        Button { Task { await workspace.assignSelection(to: target.id, materials: item.materials) } }
                        label: { Text(verbatim: target.title) }
                    }
                } label: {
                    Label(LocalizedStringResource("workdesk.move", defaultValue: "Move to"), systemImage: "folder")
                }.buttonStyle(.bordered).disabled(workspace.selectedIDs.isEmpty)
                Menu {
                    ForEach(workspace.organization.projects.filter { $0.id != project.id }) { target in
                        Button {
                            let ids = Array(workspace.selectedIDs)
                            Task { _ = await workspace.organization.add(materialIDs: ids, to: .project(target.id), positions: [:]) }
                        } label: { Text(verbatim: target.title) }
                    }
                } label: {
                    Label(LocalizedStringResource("workdesk.addToAnotherProject", defaultValue: "Add to another project…"), systemImage: "folder.badge.plus")
                }.buttonStyle(.bordered).disabled(workspace.selectedIDs.isEmpty)
                Text(LocalizedStringResource("workdesk.selected.count", defaultValue: "\(workspace.selectedIDs.count) selected"))
                    .font(.caption.monospacedDigit())
            }.padding(.vertical, 4)
        }.scrollDismissesKeyboard(.interactively)
    }

    private func newConversation(_ project: WorkDeskProjectRecord) {
        let resolver = WorkDeskConversationResolver(resolve: { [weak workspace, conversationResolver] id in
            workspace?.conversationModel(for: id, resolver: conversationResolver)
        }, reportVisible: conversationResolver.reportVisible)
        _ = workspace.briefDraft(for: project, resolver: resolver)
        workspace.preparingProjectID = project.id
    }

    private func closeProject() {
        withAnimation(motion) { workspace.selectScope(.all) }
    }
}

private struct WorkDeskTrayOpening: ViewModifier {
    let scale: CGFloat
    let translation: CGSize
    let opacity: Double

    func body(content: Content) -> some View {
        content.scaleEffect(scale, anchor: .topLeading).offset(translation).opacity(opacity)
    }
}
