// SPDX-License-Identifier: Apache-2.0

// Drawing, navigation and hit testing share screen-to-desk arithmetic. Tiny
// overview cards retain an accessible focus target; live movement is clamped
// as one group so reaching an edge never changes spacing between selected cards.

import SwiftUI

struct WorkDeskCanvasProject: Identifiable {
    let record: WorkDeskProjectRecord
    let materialCount: Int
    var id: UUID { record.id }
}

nonisolated struct WorkDeskCanvasTransform: Equatable {
    var scale: CGFloat = 1
    var offset: CGSize = .zero
}

/// Shared drawing and hit-testing arithmetic. Coordinates remain finite and
/// bounded even when imported metadata or a cancelled gesture is malformed.
nonisolated enum WorkDeskCanvasGeometry {
    static let minimumScale: CGFloat = 0.001
    static let maximumScale: CGFloat = 1.6
    static let coordinateLimit = WorkDeskPoint.coordinateLimit
    static let overviewThreshold: CGFloat = 0.60
    static let cardBodySize = CGSize(width: 232, height: 238)
    static let projectBodySize = CGSize(width: 232, height: 168)
    static let handleHeight: CGFloat = 44
    static let minimumFocusSize: CGFloat = 44
    static let feedbackLayer: Double = 2_000_000
    static let liftedLayer: Double = 1_000_000

    static func previewScale(_ scale: CGFloat, bodySize: CGSize) -> CGFloat {
        let zoom = boundedScale(scale)
        guard zoom < overviewThreshold else { return zoom }
        return max(zoom, minimumFocusSize / min(bodySize.width, bodySize.height))
    }

    static func screenSize(bodySize: CGSize, scale: CGFloat) -> CGSize {
        let zoom = previewScale(scale, bodySize: bodySize)
        return CGSize(width: bodySize.width * zoom,
                      height: bodySize.height * zoom + visibleHandleHeight(scale: scale))
    }

    static func visibleHandleHeight(scale: CGFloat) -> CGFloat {
        // The read-only overview header folds away continuously; crossing the
        // interactive threshold must not jump every card by one handle height.
        handleHeight * min(1, max(0, (boundedScale(scale) - 0.35) / (overviewThreshold - 0.35)))
    }

    static func boundedScale(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite else { return 1 }
        return min(max(scale, minimumScale), maximumScale)
    }

    static func bounded(_ point: WorkDeskPoint) -> WorkDeskPoint {
        WorkDeskPoint(
            x: point.x.isFinite ? min(max(point.x, -coordinateLimit), coordinateLimit) : 0,
            y: point.y.isFinite ? min(max(point.y, -coordinateLimit), coordinateLimit) : 0
        )
    }

    static func moved(_ point: WorkDeskPoint, by translation: CGSize, scale: CGFloat) -> WorkDeskPoint {
        let zoom = boundedScale(scale)
        return bounded(WorkDeskPoint(
            x: point.x + Double(translation.width / zoom),
            y: point.y + Double(translation.height / zoom)
        ))
    }

    static func defaultPoint(index: Int, columns: Int) -> WorkDeskPoint {
        let columnCount = max(1, columns)
        let slot = max(0, index)
        return WorkDeskPoint(
            x: 28 + Double(slot % columnCount) * 264,
            y: 26 + Double(slot / columnCount) * 340
        )
    }

    /// Finds an unoccupied slot using actual persisted frames, not the count of
    /// remaining cards. Deleting an early card must not put the next capture on
    /// top of a later card that retained its original position.
    static func availablePoint(occupied: [CGRect], columns: Int, bodySize: CGSize, scale: CGFloat) -> WorkDeskPoint? {
        let preferredColumns = max(1, columns)
        let rows = max(1, Int((coordinateLimit - 340) / 340))
        let totalColumns = max(1, Int((coordinateLimit - 264) / 264))
        for band in 0..<(totalColumns / preferredColumns + 1) {
            for row in 0..<rows {
                for column in 0..<preferredColumns {
                    let xColumn = band * preferredColumns + column
                    guard xColumn < totalColumns else { continue }
                    let point = WorkDeskPoint(x: 28 + Double(xColumn) * 264, y: 26 + Double(row) * 340)
                    let proposed = frame(at: point, bodySize: bodySize, scale: scale).insetBy(dx: -10, dy: -10)
                    if !occupied.contains(where: { $0.intersects(proposed) }) { return point }
                }
            }
        }
        return nil
    }

    static func frame(at point: WorkDeskPoint, bodySize: CGSize, scale: CGFloat) -> CGRect {
        let point = bounded(point)
        let size = screenSize(bodySize: bodySize, scale: scale)
        return CGRect(
            x: point.x, y: point.y,
            width: size.width / boundedScale(scale),
            height: size.height / boundedScale(scale)
        )
    }

    static func screenFrame(at point: WorkDeskPoint, bodySize: CGSize, transform: WorkDeskCanvasTransform) -> CGRect {
        CGRect(origin: screenPoint(point, transform: transform), size: screenSize(bodySize: bodySize, scale: transform.scale))
    }

    static func shouldRender(_ frame: CGRect, viewport: CGSize, isInteracting: Bool) -> Bool {
        isInteracting || CGRect(origin: .zero, size: viewport).insetBy(dx: -120, dy: -120).intersects(frame)
    }

    static func normalized(_ transform: WorkDeskCanvasTransform) -> WorkDeskCanvasTransform {
        let limit = CGFloat(coordinateLimit) * maximumScale + 10_000
        func finite(_ value: CGFloat) -> CGFloat { value.isFinite ? min(max(value, -limit), limit) : 0 }
        return WorkDeskCanvasTransform(scale: boundedScale(transform.scale),
            offset: CGSize(width: finite(transform.offset.width), height: finite(transform.offset.height)))
    }

    static func panned(_ transform: WorkDeskCanvasTransform, by delta: CGSize) -> WorkDeskCanvasTransform {
        let start = normalized(transform)
        guard delta.width.isFinite, delta.height.isFinite else { return start }
        return normalized(WorkDeskCanvasTransform(scale: start.scale,
            offset: CGSize(width: start.offset.width + delta.width, height: start.offset.height + delta.height)))
    }

    static func screenPoint(_ point: WorkDeskPoint, transform: WorkDeskCanvasTransform) -> CGPoint {
        let transform = normalized(transform)
        return CGPoint(
            x: CGFloat(point.x) * transform.scale + transform.offset.width,
            y: CGFloat(point.y) * transform.scale + transform.offset.height
        )
    }

    static func worldPoint(_ point: CGPoint, transform: WorkDeskCanvasTransform) -> WorkDeskPoint {
        let camera = normalized(transform)
        return WorkDeskPoint(x: Double((point.x - camera.offset.width) / camera.scale),
                             y: Double((point.y - camera.offset.height) / camera.scale))
    }

    /// Zoom around the chosen screen point, keeping its desk point stationary.
    static func zoomed(_ transform: WorkDeskCanvasTransform, to requested: CGFloat, anchor: CGPoint) -> WorkDeskCanvasTransform {
        let transform = normalized(transform)
        guard requested.isFinite, anchor.x.isFinite, anchor.y.isFinite else { return transform }
        let oldScale = boundedScale(transform.scale)
        let scale = boundedScale(requested)
        let ratio = scale / oldScale
        return normalized(WorkDeskCanvasTransform(scale: scale, offset: CGSize(
            width: anchor.x - (anchor.x - transform.offset.width) * ratio,
            height: anchor.y - (anchor.y - transform.offset.height) * ratio
        )))
    }

    static func fit(frames: [CGRect], viewport: CGSize) -> WorkDeskCanvasTransform {
        guard viewport.width > 0, viewport.height > 0,
              let first = frames.first else { return WorkDeskCanvasTransform() }
        let bounds = frames.dropFirst().reduce(first) { $0.union($1) }
        guard !bounds.isNull, bounds.width.isFinite, bounds.height.isFinite else {
            return WorkDeskCanvasTransform()
        }
        let usable = CGSize(width: max(1, viewport.width - 48), height: max(1, viewport.height - 100))
        let scale = boundedScale(min(1, min(usable.width / max(1, bounds.width), usable.height / max(1, bounds.height))))
        return WorkDeskCanvasTransform(scale: scale, offset: CGSize(
            width: (viewport.width - bounds.width * scale) / 2 - bounds.minX * scale,
            height: 24 - bounds.minY * scale
        ))
    }

    /// Requiring the centre to enter the inner portion distinguishes purposeful
    /// stacking from merely crossing an edge while arranging nearby notes.
    static func overlapTarget(movingFrame: CGRect, candidates: [(UUID, CGRect)]) -> UUID? {
        let centre = CGPoint(x: movingFrame.midX, y: movingFrame.midY)
        return candidates.filter { _, frame in
            frame.insetBy(dx: frame.width * 0.18, dy: frame.height * 0.18).contains(centre)
        }.min { lhs, rhs in
            let left = hypot(lhs.1.midX - centre.x, lhs.1.midY - centre.y)
            let right = hypot(rhs.1.midX - centre.x, rhs.1.midY - centre.y)
            return left == right ? lhs.0.uuidString < rhs.0.uuidString : left < right
        }?.0
    }

    /// Clamp one delta for the whole selection. Clamping cards independently
    /// bunches them together against the edge and destroys their arrangement.
    static func translated<ID: Hashable>(_ origins: [ID: WorkDeskPoint], by delta: CGSize) -> [ID: WorkDeskPoint] {
        guard !origins.isEmpty, delta.width.isFinite, delta.height.isFinite else { return origins }
        let points = Array(origins.values)
        let dx = min(max(Double(delta.width), -coordinateLimit - (points.map(\.x).min() ?? 0)), coordinateLimit - (points.map(\.x).max() ?? 0))
        let dy = min(max(Double(delta.height), -coordinateLimit - (points.map(\.y).min() ?? 0)), coordinateLimit - (points.map(\.y).max() ?? 0))
        return origins.mapValues { WorkDeskPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    /// The frontmost surface under the moving centre owns the drop. Its outer
    /// edge also blocks dropping through it into a hidden project underneath.
    static func foregroundTarget(movingFrame: CGRect, candidates: [WorkDeskDropCandidate]) -> WorkDeskCanvasItemID? {
        let centre = CGPoint(x: movingFrame.midX, y: movingFrame.midY)
        var front: WorkDeskDropCandidate?
        for candidate in candidates where candidate.frame.contains(centre) {
            if let current = front {
                if candidate.layer > current.layer || (candidate.layer == current.layer && candidate.id.sortKey > current.id.sortKey) {
                    front = candidate
                }
            } else { front = candidate }
        }
        guard let front,
              front.frame.insetBy(dx: front.frame.width * 0.18, dy: front.frame.height * 0.18).contains(centre) else { return nil }
        return front.id
    }

    static func feedbackFrame(near frame: CGRect, viewport: CGSize) -> CGRect {
        let size = CGSize(width: min(280, max(1, viewport.width - 24)), height: 72)
        let x = min(max(12, frame.midX - size.width / 2), max(12, viewport.width - size.width - 12))
        let above = frame.minY - size.height - 14
        let preferredY = above >= 12 ? above : frame.maxY + 14
        let y = min(max(12, preferredY), max(12, viewport.height - size.height - 78))
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    static func edgePanVelocity(at point: CGPoint, viewport: CGSize) -> CGSize {
        guard viewport.width > 120, viewport.height > 160 else { return .zero }
        let margin: CGFloat = 48
        func speed(_ value: CGFloat, length: CGFloat) -> CGFloat {
            if value < margin { return 360 * min(1, max(0, (margin - value) / margin)) }
            if value > length - margin { return -360 * min(1, max(0, (value - length + margin) / margin)) }
            return 0
        }
        return CGSize(width: speed(point.x, length: viewport.width), height: speed(point.y, length: viewport.height - 64))
    }
}

nonisolated enum WorkDeskCanvasItemID: Hashable, Sendable {
    case material(UUID), project(UUID)
    var id: UUID { switch self { case .material(let id), .project(let id): id } }
    var isProject: Bool { if case .project = self { true } else { false } }
    var sortKey: String { (isProject ? "project-" : "material-") + id.uuidString }
}

nonisolated struct WorkDeskDropCandidate {
    let id: WorkDeskCanvasItemID
    let frame: CGRect
    let layer: Double
}
