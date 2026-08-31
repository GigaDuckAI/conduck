// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardMosaicLayout.swift
//
// Unit-grid mosaic placement for the material board. The placement engine is a
// pure value type so it can be exercised without a view hierarchy; the SwiftUI
// `Layout` is a thin shell that resolves a width from the proposal, memoises one
// engine result per (spans, width, metrics) key and mirrors x for right-to-left.
//
// Reading order is a hard invariant: a later card is never placed above an
// earlier one. Placement is a plain row-band fill — a band's height is the
// tallest span in it, and unused units stay empty. Backfilling those holes would
// need to lift a later card above an earlier one, so holes are the correct
// trade.

import SwiftUI

// MARK: - Unit span

/// Footprint in grid units. Both dimensions are forced to at least one unit so
/// a malformed span can never collapse a row band to zero height.
nonisolated struct WorkboardMosaicSpan: Sendable, Hashable {
    let columns: Int
    let rows: Int

    init(columns: Int, rows: Int) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
    }

    static let small = WorkboardMosaicSpan(columns: 1, rows: 1)
    static let standard = WorkboardMosaicSpan(columns: 2, rows: 2)
    static let large = WorkboardMosaicSpan(columns: 4, rows: 2)
}

extension WorkMaterialCardSize {
    /// Standard is the 2x2 anchor of the grid; small is its quarter tile and
    /// large is a double-width banner on the same two-unit row band.
    nonisolated var mosaicSpan: WorkboardMosaicSpan {
        switch self {
        case .small: return .small
        case .standard: return .standard
        case .large: return .large
        }
    }
}

// MARK: - Metrics

/// Grid tuning. Every stored value is sanitised at init so a caller cannot feed
/// a non-finite or inverted range into the engine.
nonisolated struct WorkboardMosaicMetrics: Sendable, Hashable {
    /// Column counts stay even so a 2-unit standard card always packs flush.
    static let absoluteMinimumColumns = 2

    let spacing: CGFloat
    /// Below this a unit is unreadable, so the grid drops to fewer columns.
    let minimumUnitWidth: CGFloat
    /// The width a unit should reach before another column pair is added.
    let comfortableUnitWidth: CGFloat
    /// Caps unit growth on wide displays so tiles never balloon.
    let maximumUnitWidth: CGFloat
    /// Unit height as a multiple of unit width.
    let unitAspectRatio: CGFloat
    /// The column count a compact width settles on: four units, two cards.
    let preferredMinimumColumns: Int
    let maximumColumns: Int
    /// Stands in for a proposal that carries no usable width.
    let fallbackWidth: CGFloat

    init(
        spacing: CGFloat = 12,
        minimumUnitWidth: CGFloat = 64,
        comfortableUnitWidth: CGFloat = 88,
        maximumUnitWidth: CGFloat = 144,
        unitAspectRatio: CGFloat = 1,
        preferredMinimumColumns: Int = 4,
        maximumColumns: Int = 12,
        fallbackWidth: CGFloat = 360
    ) {
        self.spacing = spacing.isFinite ? max(0, spacing) : 0
        let resolvedMinimum = Self.sanitised(minimumUnitWidth, fallback: 64)
        let resolvedMaximum = max(resolvedMinimum, Self.sanitised(maximumUnitWidth, fallback: 144))
        self.minimumUnitWidth = resolvedMinimum
        self.maximumUnitWidth = resolvedMaximum
        self.comfortableUnitWidth = min(
            max(Self.sanitised(comfortableUnitWidth, fallback: 88), resolvedMinimum),
            resolvedMaximum
        )
        self.unitAspectRatio = unitAspectRatio.isFinite
            ? min(max(unitAspectRatio, 0.25), 4)
            : 1
        let resolvedPreferred = Self.evenColumns(preferredMinimumColumns)
        self.preferredMinimumColumns = resolvedPreferred
        self.maximumColumns = max(resolvedPreferred, Self.evenColumns(maximumColumns))
        self.fallbackWidth = fallbackWidth.isFinite ? max(1, fallbackWidth) : 360
    }

    static let standard = WorkboardMosaicMetrics()

    /// Larger text needs larger tiles, which means fewer columns at the same
    /// width. Scaling the unit thresholds is enough — the column search reacts.
    func scaled(by factor: CGFloat) -> WorkboardMosaicMetrics {
        let safeFactor = factor.isFinite ? min(max(factor, 0.5), 3) : 1
        return WorkboardMosaicMetrics(
            spacing: spacing,
            minimumUnitWidth: minimumUnitWidth * safeFactor,
            comfortableUnitWidth: comfortableUnitWidth * safeFactor,
            maximumUnitWidth: maximumUnitWidth * safeFactor,
            unitAspectRatio: unitAspectRatio,
            preferredMinimumColumns: preferredMinimumColumns,
            maximumColumns: maximumColumns,
            fallbackWidth: fallbackWidth
        )
    }

    static func scaled(for dynamicTypeSize: DynamicTypeSize) -> WorkboardMosaicMetrics {
        standard.scaled(by: unitScale(for: dynamicTypeSize))
    }

    static func unitScale(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        switch dynamicTypeSize {
        case .xSmall, .small, .medium, .large: return 1
        case .xLarge: return 1.08
        case .xxLarge: return 1.16
        case .xxxLarge: return 1.24
        case .accessibility1: return 1.4
        case .accessibility2: return 1.55
        case .accessibility3: return 1.7
        case .accessibility4: return 1.85
        case .accessibility5: return 2
        @unknown default: return 1
        }
    }

    private static func sanitised(_ value: CGFloat, fallback: CGFloat) -> CGFloat {
        value.isFinite ? max(8, value) : fallback
    }

    private static func evenColumns(_ value: Int) -> Int {
        let floored = max(absoluteMinimumColumns, value)
        return floored - (floored % 2)
    }
}

// MARK: - Engine

/// Pure placement. No view types, no environment, no state: the same inputs
/// always produce the same frames, which is what makes the layout cacheable.
nonisolated struct WorkboardMosaicEngine: Sendable {
    nonisolated struct Item: Sendable, Hashable {
        let id: UUID
        let span: WorkboardMosaicSpan

        init(id: UUID, span: WorkboardMosaicSpan) {
            self.id = id
            self.span = span
        }

        init(id: UUID, size: WorkMaterialCardSize) {
            self.init(id: id, span: size.mosaicSpan)
        }
    }

    nonisolated struct Placement: Sendable, Hashable {
        /// Absent when the board was laid out from bare spans, which is how the
        /// SwiftUI `Layout` drives the engine (subviews carry no material id).
        let id: UUID?
        let index: Int
        let span: WorkboardMosaicSpan
        let column: Int
        let row: Int
        /// Left-to-right coordinates with the grid origin at (0, 0).
        let frame: CGRect
    }

    nonisolated struct Result: Sendable, Hashable {
        let placements: [Placement]
        /// Width is the full grid width even when the last band is short, so the
        /// board reserves a stable drop surface.
        let contentSize: CGSize
        let columns: Int
        let unitSize: CGSize

        static let empty = Result(
            placements: [],
            contentSize: .zero,
            columns: WorkboardMosaicMetrics.absoluteMinimumColumns,
            unitSize: .zero
        )

        func frame(for id: UUID) -> CGRect? {
            placements.first { $0.id == id }?.frame
        }

        func placement(for id: UUID) -> Placement? {
            placements.first { $0.id == id }
        }

        /// Index a card dropped at `point` should take, resolved through the
        /// grid rather than by nearest tile: the row band that contains the
        /// point picks the line, and the first tile in that band whose
        /// horizontal midpoint is past the point picks the slot. A band's empty
        /// trailing units therefore append after its last card, which a
        /// distance search cannot express — an empty cell has no tile to be
        /// near, so its whole region would resolve to whichever neighbour
        /// happened to be closest. `point` is in the engine's left-to-right
        /// grid space; callers holding view coordinates go through
        /// `WorkboardMosaicLayout.insertionIndex(at:in:containerWidth:layoutDirection:)`.
        func insertionIndex(at point: CGPoint) -> Int {
            guard !placements.isEmpty else { return 0 }
            guard point.x.isFinite, point.y.isFinite else { return placements.count }

            var bandStart = 0
            while bandStart < placements.count {
                let bandTop = placements[bandStart].frame.minY
                var bandEnd = bandStart
                var bandBottom = placements[bandStart].frame.maxY
                while bandEnd + 1 < placements.count,
                      placements[bandEnd + 1].frame.minY == bandTop {
                    bandEnd += 1
                    bandBottom = max(bandBottom, placements[bandEnd].frame.maxY)
                }
                // A point in the gutter under a band belongs to the band below
                // it, which is the one the card would visually land in.
                if point.y <= bandBottom {
                    for index in bandStart...bandEnd where point.x < placements[index].frame.midX {
                        return placements[index].index
                    }
                    return placements[bandEnd].index + 1
                }
                bandStart = bandEnd + 1
            }
            return placements.count
        }
    }

    let metrics: WorkboardMosaicMetrics

    init(metrics: WorkboardMosaicMetrics = .standard) {
        self.metrics = metrics
    }

    func place(_ items: [Item], availableWidth: CGFloat) -> Result {
        place(entries: items.map { (id: Optional($0.id), span: $0.span) }, availableWidth: availableWidth)
    }

    func place(sizes: [(id: UUID, size: WorkMaterialCardSize)], availableWidth: CGFloat) -> Result {
        place(entries: sizes.map { (id: Optional($0.id), span: $0.size.mosaicSpan) }, availableWidth: availableWidth)
    }

    func place(spans: [WorkboardMosaicSpan], availableWidth: CGFloat) -> Result {
        place(entries: spans.map { (id: nil, span: $0) }, availableWidth: availableWidth)
    }

    /// Column pairs are added while a unit still clears the comfortable width;
    /// below that the grid holds at four units until even legibility fails.
    func columnCount(forWidth width: CGFloat) -> Int {
        let resolved = resolvedWidth(width)
        var candidate = metrics.maximumColumns
        while candidate > metrics.preferredMinimumColumns {
            if unitWidth(columns: candidate, width: resolved) >= metrics.comfortableUnitWidth {
                return candidate
            }
            candidate -= 2
        }
        candidate = metrics.preferredMinimumColumns
        while candidate > WorkboardMosaicMetrics.absoluteMinimumColumns {
            if unitWidth(columns: candidate, width: resolved) >= metrics.minimumUnitWidth {
                return candidate
            }
            candidate -= 2
        }
        return WorkboardMosaicMetrics.absoluteMinimumColumns
    }

    /// Never returns zero: a degenerate width still yields a positive, finite
    /// unit so every frame stays drawable.
    func unitWidth(columns: Int, width: CGFloat) -> CGFloat {
        let safeColumns = max(1, columns)
        let resolved = resolvedWidth(width)
        let gutters = CGFloat(safeColumns - 1) * metrics.spacing
        let raw = (resolved - gutters) / CGFloat(safeColumns)
        guard raw.isFinite else { return metrics.minimumUnitWidth }
        return min(max(raw, 1), metrics.maximumUnitWidth)
    }

    private func resolvedWidth(_ width: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0 else { return metrics.fallbackWidth }
        return min(width, 100_000)
    }

    private func place(
        entries: [(id: UUID?, span: WorkboardMosaicSpan)],
        availableWidth: CGFloat
    ) -> Result {
        let boardWidth = resolvedWidth(availableWidth)
        let columns = columnCount(forWidth: boardWidth)
        let gridUnitWidth = unitWidth(columns: columns, width: boardWidth)
        let gridUnitHeight = max(1, gridUnitWidth * metrics.unitAspectRatio)
        let spacing = metrics.spacing
        let unitSize = CGSize(width: gridUnitWidth, height: gridUnitHeight)
        let contentWidth = CGFloat(columns) * gridUnitWidth + CGFloat(columns - 1) * spacing

        guard !entries.isEmpty else {
            return Result(
                placements: [],
                contentSize: CGSize(width: contentWidth, height: 0),
                columns: columns,
                unitSize: unitSize
            )
        }

        var placements: [Placement] = []
        placements.reserveCapacity(entries.count)
        var column = 0
        var bandRow = 0
        var bandHeight = 0

        for (index, entry) in entries.enumerated() {
            let span = WorkboardMosaicSpan(
                columns: min(entry.span.columns, columns),
                rows: entry.span.rows
            )
            if column > 0, column + span.columns > columns {
                bandRow += bandHeight
                column = 0
                bandHeight = 0
            }
            let frame = CGRect(
                x: CGFloat(column) * (gridUnitWidth + spacing),
                y: CGFloat(bandRow) * (gridUnitHeight + spacing),
                width: CGFloat(span.columns) * gridUnitWidth + CGFloat(span.columns - 1) * spacing,
                height: CGFloat(span.rows) * gridUnitHeight + CGFloat(span.rows - 1) * spacing
            )
            placements.append(
                Placement(
                    id: entry.id,
                    index: index,
                    span: span,
                    column: column,
                    row: bandRow,
                    frame: frame
                )
            )
            column += span.columns
            bandHeight = max(bandHeight, span.rows)
            if column >= columns {
                bandRow += bandHeight
                column = 0
                bandHeight = 0
            }
        }

        let totalRows = bandRow + bandHeight
        let contentHeight = totalRows > 0
            ? CGFloat(totalRows) * gridUnitHeight + CGFloat(totalRows - 1) * spacing
            : 0

        return Result(
            placements: placements,
            contentSize: CGSize(width: contentWidth, height: contentHeight),
            columns: columns,
            unitSize: unitSize
        )
    }
}

// MARK: - Layout value

nonisolated struct WorkboardMosaicCardSizeKey: LayoutValueKey {
    static let defaultValue: WorkMaterialCardSize = .standard
}

extension View {
    func workboardMosaicCardSize(_ size: WorkMaterialCardSize) -> some View {
        layoutValue(key: WorkboardMosaicCardSizeKey.self, value: size)
    }
}

// MARK: - Layout

/// Right-to-left: the engine stays left-to-right and this shell mirrors x at
/// placement time, so `layoutDirection` must be fed from the environment by the
/// view that installs the layout. Leaving it at `.leftToRight` disables the
/// mirror entirely, which is the correct setting if the surrounding container
/// already presents flipped coordinates — mirroring twice is as wrong as not
/// mirroring at all. Drop-index reads must go through
/// `insertionIndex(at:in:containerWidth:layoutDirection:)` so they mirror the
/// same way the frames did.
nonisolated struct WorkboardMosaicLayout: Layout {
    var metrics: WorkboardMosaicMetrics = .standard
    var layoutDirection: LayoutDirection = .leftToRight

    nonisolated struct Cache {
        nonisolated struct Key: Hashable {
            let spans: [WorkboardMosaicSpan]
            let width: CGFloat
            let metrics: WorkboardMosaicMetrics
        }

        var key: Key?
        var result: WorkboardMosaicEngine.Result
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(key: nil, result: .empty)
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.key = nil
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = Self.resolvedWidth(from: proposal, metrics: metrics)
        let result = memoisedResult(width: width, subviews: subviews, cache: &cache)
        let reportedWidth: CGFloat
        if let proposed = proposed(from: proposal) {
            reportedWidth = proposed
        } else {
            // A proposal carrying no width is a probe for the layout's own
            // requirement, so answer with the narrowest grid that still draws
            // rather than with the fallback width the height was estimated at.
            reportedWidth = min(result.contentSize.width, Self.minimumContentWidth(metrics: metrics))
        }
        return CGSize(width: max(0, reportedWidth), height: max(0, result.contentSize.height))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        let width = bounds.width.isFinite && bounds.width > 0
            ? bounds.width
            : Self.resolvedWidth(from: proposal, metrics: metrics)
        let result = memoisedResult(width: width, subviews: subviews, cache: &cache)
        let inset = Self.horizontalInset(
            containerWidth: bounds.width,
            contentWidth: result.contentSize.width
        )
        for placement in result.placements where placement.index < subviews.count {
            let frame = Self.presentedFrame(
                placement.frame,
                contentWidth: result.contentSize.width,
                layoutDirection: layoutDirection
            )
            subviews[placement.index].place(
                at: CGPoint(x: bounds.minX + inset + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    // MARK: Proposal and coordinate helpers

    /// A proposal carrying no usable width — unspecified, infinite, zero,
    /// non-finite, or height-only — falls back to a compact board width rather
    /// than propagating garbage into the grid arithmetic.
    static func resolvedWidth(from proposal: ProposedViewSize, metrics: WorkboardMosaicMetrics) -> CGFloat {
        guard let width = proposal.width, width.isFinite, width > 0 else {
            return metrics.fallbackWidth
        }
        return width
    }

    /// The narrowest board the engine still lays out: the absolute minimum
    /// column count at the minimum legible unit, gutters included.
    static func minimumContentWidth(metrics: WorkboardMosaicMetrics) -> CGFloat {
        let columns = CGFloat(WorkboardMosaicMetrics.absoluteMinimumColumns)
        return columns * metrics.minimumUnitWidth + (columns - 1) * metrics.spacing
    }

    private func proposed(from proposal: ProposedViewSize) -> CGFloat? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return width
    }

    static func horizontalInset(containerWidth: CGFloat, contentWidth: CGFloat) -> CGFloat {
        guard containerWidth.isFinite, contentWidth.isFinite else { return 0 }
        return max(0, (containerWidth - contentWidth) / 2)
    }

    static func presentedFrame(
        _ frame: CGRect,
        contentWidth: CGFloat,
        layoutDirection: LayoutDirection
    ) -> CGRect {
        guard layoutDirection == .rightToLeft, contentWidth.isFinite else { return frame }
        return CGRect(
            x: contentWidth - frame.maxX,
            y: frame.minY,
            width: frame.width,
            height: frame.height
        )
    }

    /// Drop geometry: `point` is in the coordinate space of the view that owns
    /// the layout, so the centring inset and any right-to-left mirror are undone
    /// before the engine reads reading order.
    static func insertionIndex(
        at point: CGPoint,
        in result: WorkboardMosaicEngine.Result,
        containerWidth: CGFloat,
        layoutDirection: LayoutDirection
    ) -> Int {
        let inset = horizontalInset(
            containerWidth: containerWidth,
            contentWidth: result.contentSize.width
        )
        var local = CGPoint(x: point.x - inset, y: point.y)
        if layoutDirection == .rightToLeft, result.contentSize.width.isFinite, local.x.isFinite {
            local.x = result.contentSize.width - local.x
        }
        return result.insertionIndex(at: local)
    }

    private func memoisedResult(
        width: CGFloat,
        subviews: Subviews,
        cache: inout Cache
    ) -> WorkboardMosaicEngine.Result {
        let spans = subviews.map { $0[WorkboardMosaicCardSizeKey.self].mosaicSpan }
        let key = Cache.Key(spans: spans, width: width, metrics: metrics)
        if let cached = cache.key, cached == key {
            return cache.result
        }
        let placed = WorkboardMosaicEngine(metrics: metrics).place(spans: spans, availableWidth: width)
        cache.key = key
        cache.result = placed
        return placed
    }
}
