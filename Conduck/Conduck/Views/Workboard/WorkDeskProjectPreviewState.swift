// SPDX-License-Identifier: Apache-2.0

// An explicitly opened contents preview is independent of navigation and drag
// destinations. It holds identifiers and an anchor, never a three-item material
// snapshot. Presentation and drag tokens prevent late gesture callbacks from
// closing a newer preview. A folder scrolling away leaves its explicitly opened
// contents available; navigation and project deletion always end ownership.

import SwiftUI

struct WorkDeskProjectPreviewRequest: Identifiable, Equatable {
    let id = UUID()
    let projectID: UUID
    let anchor: CGRect
    let initialMaterialCount: Int
}

@MainActor @Observable
final class WorkDeskProjectPreviewState {
    private(set) var request: WorkDeskProjectPreviewRequest?
    private(set) var dragToken: UUID?
    private(set) var panelFrame: CGRect = .zero

    func toggle(projectID: UUID, anchor: CGRect, materialCount: Int = 0) {
        guard dragToken == nil, anchor.minX.isFinite, anchor.minY.isFinite,
              anchor.width.isFinite, anchor.height.isFinite, anchor.maxX.isFinite, anchor.maxY.isFinite,
              anchor.width > 0, anchor.height > 0 else { return }
        if request?.projectID == projectID { dismiss(); return }
        request = .init(projectID: projectID, anchor: anchor, initialMaterialCount: materialCount)
        panelFrame = .zero
    }

    func updatePanelFrame(_ frame: CGRect, requestID: UUID) {
        guard request?.id == requestID, panelFrame != frame,
              frame.minX.isFinite, frame.minY.isFinite, frame.maxX.isFinite, frame.maxY.isFinite,
              frame.width > 0, frame.height > 0 else { return }
        panelFrame = frame
    }

    func dismiss(force: Bool = false) {
        guard force || dragToken == nil else { return }
        request = nil
        dragToken = nil
        panelFrame = .zero
    }

    func dismissOutside(_ point: CGPoint) {
        guard let request, panelFrame.width > 0,
              !panelFrame.contains(point), !request.anchor.contains(point) else { return }
        dismiss()
    }

    func beginDrag(requestID: UUID) -> UUID? {
        guard request?.id == requestID, dragToken == nil else { return nil }
        let token = UUID()
        dragToken = token
        return token
    }

    func endDrag(token: UUID?) {
        guard let token, dragToken == token else { return }
        dragToken = nil
    }
}

nonisolated enum WorkDeskProjectPreviewGeometry {
    static func frame(anchor: CGRect, viewport: CGSize, materialCount: Int) -> CGRect {
        guard viewport.width.isFinite, viewport.height.isFinite, viewport.width > 0, viewport.height > 0,
              anchor.minX.isFinite, anchor.minY.isFinite, anchor.maxX.isFinite, anchor.maxY.isFinite else { return .zero }
        let inset: CGFloat = min(12, min(viewport.width, viewport.height) / 4)
        let width = min(380, viewport.width - inset * 2)
        let height = min(max(220, 126 + CGFloat(min(5, max(0, materialCount))) * 76),
                         viewport.height - inset * 2)
        let right = anchor.maxX + 14
        let x = right + width <= viewport.width - inset ? right : anchor.minX - width - 14
        return CGRect(x: min(max(inset, x), max(inset, viewport.width - width - inset)),
                      y: min(max(inset, anchor.minY), max(inset, viewport.height - height - inset)),
                      width: width, height: height)
    }
}
