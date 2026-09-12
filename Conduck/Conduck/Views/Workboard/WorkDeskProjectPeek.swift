// SPDX-License-Identifier: Apache-2.0

// Readable project peeks live above the scrolling content, so the first or
// last row cannot clip its own preview. The same bounded placement as Desk
// keeps the peek within the workspace. A peek never receives focus or input;
// navigation, source disappearance and dragging dismiss its exact owner.

import SwiftUI

struct WorkDeskProjectPeek {
    let ownerID: UUID
    let project: WorkDeskCanvasProject
    let frame: CGRect
}

struct WorkDeskProjectPeekOverlay: View {
    let coordinator: WorkDeskTransferCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            if let peek = coordinator.projectPeek, !coordinator.isDragging {
                let global = geometry.frame(in: .global)
                let source = peek.frame.offsetBy(dx: -global.minX, dy: -global.minY)
                let bounds = WorkDeskCanvasGeometry.projectPreviewFrame(near: source,
                    viewport: geometry.size, itemCount: peek.project.materialCount)
                WorkDeskProjectHoverPreview(project: peek.project)
                    .frame(width: bounds.width, height: bounds.height, alignment: .top)
                    .position(x: bounds.midX, y: bounds.midY)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.97).combined(with: .opacity))
                    .accessibilityIdentifier("workdesk-readable-project-preview")
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
