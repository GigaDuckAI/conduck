// SPDX-License-Identifier: Apache-2.0

// The viewport and foreground order belong to the workspace, not the lifetime
// of its pixels. Switching layouts, searching, or visiting a chat preserves
// each project's place on the desk. Gesture snapshots are deliberately local:
// a selection never gains another member halfway through a drag.
// Hidden retained canvases keep their last valid viewport, but cannot consume
// a reveal. A mount owns its active viewport so an older view disappearing
// cannot deactivate the new view that just inherited this session.

import SwiftUI
import Observation

@MainActor @Observable
final class WorkDeskCanvasSession {
    var transform = WorkDeskCanvasTransform()
    var isInitialized = false
    var columns = 3
    private(set) var viewportSize: CGSize = .zero
    private var activeViewportOwner: UUID?
    private var pendingRevealFrames: [CGRect] = []
    private(set) var layerRevision = 0
    @ObservationIgnored private var layers: [WorkDeskCanvasItemID: Int] = [:]
    @ObservationIgnored private var nextLayer = 0

    @discardableResult
    func receiveViewport(_ size: CGSize, owner: UUID, isActive: Bool) -> Bool {
        guard isActive, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else {
            suspendViewport(owner: owner)
            return false
        }
        activeViewportOwner = owner
        viewportSize = size
        return true
    }

    func suspendViewport(owner: UUID) {
        if activeViewportOwner == owner { activeViewportOwner = nil }
    }

    /// Deletion can retain a cluster while All materials is showing a list or
    /// has never opened spatially. Keep the reveal until a real active viewport exists.
    func reveal(frames: [CGRect]) {
        guard !frames.isEmpty else { return }
        pendingRevealFrames = frames
        applyPendingReveal()
    }

    func applyPendingReveal() {
        guard activeViewportOwner != nil, !pendingRevealFrames.isEmpty,
              viewportSize.width > 0, viewportSize.height > 0 else { return }
        transform = WorkDeskCanvasGeometry.fit(frames: pendingRevealFrames, viewport: viewportSize)
        pendingRevealFrames = []
        isInitialized = true
    }

    /// A new project belongs to the part of the desk the person is looking at.
    /// Convert its visible center back to world coordinates at the current zoom.
    var projectInsertionPoint: WorkDeskPoint? {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return nil }
        let camera = WorkDeskCanvasGeometry.normalized(transform)
        let size = WorkDeskCanvasGeometry.screenSize(bodySize: WorkDeskCanvasGeometry.projectBodySize, scale: camera.scale)
        return WorkDeskPoint(
            x: Double((viewportSize.width / 2 - size.width / 2 - camera.offset.width) / camera.scale),
            y: Double((viewportSize.height / 2 - size.height / 2 - camera.offset.height) / camera.scale)
        )
    }

    func layer(for id: WorkDeskCanvasItemID) -> Double {
        _ = layerRevision
        return Double(layers[id] ?? 0)
    }

    func reconcile(_ ids: [WorkDeskCanvasItemID]) {
        let visible = Set(ids)
        // A filtered or temporarily absent material is not a deletion signal.
        // Remember dormant ranks for this workspace's lifetime so clearing a
        // filter cannot silently put a previously covered card on top.
        guard !visible.isSubset(of: Set(layers.keys)) else { return }
        for id in ids where layers[id] == nil {
            nextLayer += 1
            layers[id] = nextLayer
        }
        layerRevision &+= 1
    }

    func bringToFront(_ ids: [WorkDeskCanvasItemID]) {
        guard !ids.isEmpty else { return }
        for id in ids {
            nextLayer += 1
            layers[id] = nextLayer
        }
        // Keep the reserved live-drag/HUD layers above this finite local order.
        if nextLayer > 100_000 {
            let ordered = layers.keys.sorted { (layers[$0] ?? 0) < (layers[$1] ?? 0) }
            layers = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element, $0.offset + 1) })
            nextLayer = ordered.count
        }
        layerRevision &+= 1
    }

    func raiseGroup(_ ids: [WorkDeskCanvasItemID], lead: WorkDeskCanvasItemID) {
        bringToFront(ids.filter { $0 != lead }.sorted { layer(for: $0) < layer(for: $1) } + [lead])
    }
}

nonisolated struct WorkDeskCanvasDrag {
    let lead: WorkDeskCanvasItemID
    let origins: [WorkDeskCanvasItemID: WorkDeskPoint]
    let startTransform: WorkDeskCanvasTransform
    var memberships: [UUID: UUID?] = [:]
    var expectedLocationTokens: WorkDeskLocationTokens? = nil
    var translation: CGSize = .zero

    func positions(transform: WorkDeskCanvasTransform) -> [WorkDeskCanvasItemID: WorkDeskPoint] {
        let scale = WorkDeskCanvasGeometry.boundedScale(startTransform.scale)
        // Edge panning moves the camera, not the finger. Compensating here
        // keeps the held grip under that same finger while the desk scrolls.
        let delta = CGSize(
            width: (translation.width - (transform.offset.width - startTransform.offset.width)) / scale,
            height: (translation.height - (transform.offset.height - startTransform.offset.height)) / scale
        )
        return WorkDeskCanvasGeometry.translated(origins, by: delta)
    }
}

/// A short dwell makes grouping deliberate. Crossing a card on the way to an
/// empty space never arms a drop, and leaving/re-entering requires a new dwell.
nonisolated struct WorkDeskDropHover {
    static let dwellDuration: Duration = .milliseconds(350)
    private(set) var target: WorkDeskCanvasItemID?
    private(set) var generation = UUID()
    private(set) var isReady = false

    mutating func update(_ candidate: WorkDeskCanvasItemID?) {
        guard candidate != target else { return }
        target = candidate
        generation = UUID()
        isReady = false
    }

    mutating func arm(generation: UUID) {
        guard generation == self.generation, target != nil else { return }
        isReady = true
    }

    mutating func reset() {
        guard target != nil || isReady else { return }
        target = nil
        generation = UUID()
        isReady = false
    }
}

/// Each release owns its optimistic positions. A slow completion from an
/// earlier drag cannot clear a newer drag's overlay or unlock the wrong batch.
nonisolated struct WorkDeskPendingPositions {
    private(set) var positions: [WorkDeskCanvasItemID: WorkDeskPoint] = [:]
    private var tokens: [WorkDeskCanvasItemID: UUID] = [:]

    mutating func begin(_ points: [WorkDeskCanvasItemID: WorkDeskPoint]) -> UUID {
        let token = UUID()
        for (id, point) in points { positions[id] = point; tokens[id] = token }
        return token
    }

    mutating func finish(token: UUID) -> [WorkDeskCanvasItemID: WorkDeskPoint] {
        let owned = positions.filter { tokens[$0.key] == token }
        for id in owned.keys { positions[id] = nil; tokens[id] = nil }
        return owned
    }
}
