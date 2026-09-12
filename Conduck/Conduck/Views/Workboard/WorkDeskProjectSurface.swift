// SPDX-License-Identifier: Apache-2.0

// One location fills the Work detail area. Camera, layout and composer sessions
// live in the workspace, so returning Home restores its arrangement without
// retaining a hidden board's focus, gestures, zoom controls or drop targets.
// Global search temporarily displays Home's aggregate results while retaining
// the selected project. An explicit contents preview shares Home's navigation,
// but its list owns project drops. Sheets hand off material/project opening only
// after dismissal so native presentations never compete for the same presenter.

import SwiftUI

struct WorkDeskProjectSurface: View {
    @Bindable var viewModel: WorkboardViewModel
    let item: WorkboardItemSnapshot
    @Bindable var workspace: WorkDeskWorkspaceState
    let onOpen: (WorkboardMaterialSnapshot) -> Void
    let onShare: (WorkboardMaterialSnapshot) -> Void
    let onReattach: (WorkboardMaterialSnapshot) -> Void
    @State private var pendingAction: PreviewAction?
    @Environment(\.workbenchDestinationIsActive) private var isActive
    @Environment(\.undoManager) private var undoManager
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private enum PreviewAction {
        case material(WorkboardMaterialSnapshot)
        case project(UUID)
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = usesSheet(in: geometry.size)
            WorkDeskSourceBoard(viewModel: viewModel, item: item, workspace: workspace,
                onOpen: onOpen, onShare: onShare, onReattach: onReattach,
                scopeOverride: workspace.displayedScope)
                // Location-local gestures disappear while the saved sessions survive.
                .id(workspace.displayedScope)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    if !compact, isActive, let request = workspace.projectPreview.request,
                       workspace.organization.project(id: request.projectID) != nil {
                        let global = geometry.frame(in: .global)
                        let anchor = request.anchor.offsetBy(dx: -global.minX, dy: -global.minY)
                        // Content stays live; the panel footprint stays steady as rows
                        // arrive or leave, including before a drag finishes.
                        let frame = WorkDeskProjectPreviewGeometry.frame(anchor: anchor, viewport: geometry.size,
                            materialCount: request.initialMaterialCount)
                        preview(request, compact: false)
                            .frame(width: frame.width, height: frame.height)
                            .shadow(color: .black.opacity(0.32), radius: 22, y: 9)
                            .offset(x: frame.minX, y: frame.minY)
                            .id(request.id)
                    }
                }
                .overlay { WorkDeskTransferOverlay(coordinator: workspace.transferCoordinator).allowsHitTesting(false) }
                .sheet(isPresented: Binding(
                    get: { isActive && compact && workspace.projectPreview.request != nil },
                    set: { presented in
                        // A resize may move the same preview back to the desk.
                        if !presented && compact { workspace.projectPreview.dismiss(force: true) }
                    }
                ), onDismiss: performPendingAction) {
                    if let request = workspace.projectPreview.request {
                        preview(request, compact: true)
                            .modifier(WorkDeskOrganizationUndo(workspace: workspace, undoManagerProvider: { undoManager }))
                            .presentationDetents([.medium, .large])
                            .presentationDragIndicator(.visible)
                    }
                }
                .onChange(of: workspace.scope) { _, _ in pendingAction = nil }
                .onChange(of: workspace.search) { _, _ in pendingAction = nil }
                .onChange(of: workspace.selectedConversationID) { _, _ in pendingAction = nil }
                .onChange(of: isActive) { _, active in
                    if !active { pendingAction = nil; workspace.projectPreview.dismiss(force: true) }
                }
                .accessibilityIdentifier("workdesk-project-surface")
        }
    }

    private func usesSheet(in size: CGSize) -> Bool {
        #if os(iOS)
        horizontalSizeClass == .compact || size.width < 600 || size.height < 350 || dynamicTypeSize.isAccessibilitySize
        #else
        false
        #endif
    }

    private func preview(_ request: WorkDeskProjectPreviewRequest, compact: Bool) -> some View {
        WorkDeskProjectPreview(viewModel: viewModel, item: item, workspace: workspace, request: request, isCompact: compact,
            onOpen: { open(.material($0), afterSheet: compact) },
            onOpenProject: { open(.project(request.projectID), afterSheet: compact) },
            onClose: { workspace.projectPreview.dismiss() })
    }

    private func open(_ action: PreviewAction, afterSheet: Bool) {
        guard workspace.projectPreview.dragToken == nil, !workspace.transferCoordinator.isDragging else { return }
        if afterSheet { pendingAction = action }
        workspace.projectPreview.dismiss(force: true)
        if !afterSheet { perform(action) }
    }

    private func performPendingAction() {
        let action = pendingAction
        pendingAction = nil
        if let action { perform(action) }
    }

    private func perform(_ action: PreviewAction) {
        guard workspace.isActive else { return }
        switch action {
        case .material(let material):
            guard let current = (viewModel.desk?.materials ?? item.materials).first(where: { $0.id == material.id }) else { return }
            onOpen(current)
        case .project(let id):
            guard workspace.organization.project(id: id) != nil else { return }
            workspace.selectScope(.project(id))
        }
    }
}
