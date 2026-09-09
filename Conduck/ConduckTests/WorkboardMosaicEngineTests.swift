// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardMosaicEngineTests.swift
//
// The mosaic engine is the board's only source of geometry, so these tests lock
// the invariants the UI relies on: tiles never overlap, every frame stays inside
// the reported content box, reading order survives any mix of card sizes, the
// column search behaves from a narrow phone to a wide Mac, degenerate widths and
// proposals stay finite, and drop indices read in visual order under both
// layout directions.
//
// TWO ENGINES, ONE FILE. The board ships ONE footprint, so the default engine
// grants every card the same tile — the "One footprint" section holds that, and
// holds it TOTALLY, because the fixed-slot drag is only true if no path can
// still draw a wide card. The mixed-span path stays compiled and stays tested
// here behind an explicit `footprint: .mixed`, because uniformity is a product
// bet that has to be reversible on evidence rather than a deletion. A test that
// feeds a mix of sizes therefore says `.mixed`; a test whose spans are all
// standard is left on the default engine on purpose, since that is the engine
// the app actually runs.

import SwiftUI
import XCTest
@testable import Conduck

final class WorkboardMosaicEngineTests: XCTestCase {
    private let widthMatrix: [CGFloat] = [320, 360, 390, 428, 512, 600, 744, 834, 920, 1024, 1280, 1600]

    // MARK: - Spans

    func testCardSizeMapsToUnitSpans() {
        XCTAssertEqual(WorkMaterialCardSize.small.mosaicSpan, WorkboardMosaicSpan(columns: 1, rows: 1))
        XCTAssertEqual(WorkMaterialCardSize.standard.mosaicSpan, WorkboardMosaicSpan(columns: 2, rows: 2))
        XCTAssertEqual(WorkMaterialCardSize.large.mosaicSpan, WorkboardMosaicSpan(columns: 4, rows: 2))
    }

    func testSpanNeverCollapsesBelowOneUnit() {
        let span = WorkboardMosaicSpan(columns: 0, rows: -3)
        XCTAssertEqual(span.columns, 1)
        XCTAssertEqual(span.rows, 1)
    }

    // MARK: - Geometry invariants

    func testNoOverlapAndInBoundsAcrossWidthMatrix() {
        let engine = WorkboardMosaicEngine(footprint: .mixed)
        for width in widthMatrix {
            for seed in UInt64(1)...UInt64(12) {
                let spans = pseudoRandomSpans(count: 17, seed: seed)
                let result = engine.place(spans: spans, availableWidth: width)
                assertNoOverlap(result, context: "width \(width) seed \(seed)")
                assertInBounds(result, context: "width \(width) seed \(seed)")
                assertReadingOrder(result, context: "width \(width) seed \(seed)")
            }
        }
    }

    func testEveryPlacementKeepsInputOrder() {
        let engine = WorkboardMosaicEngine(footprint: .mixed)
        let spans = pseudoRandomSpans(count: 23, seed: 99)
        let result = engine.place(spans: spans, availableWidth: 744)

        XCTAssertEqual(result.placements.map(\.index), Array(0..<spans.count))
        XCTAssertEqual(result.placements.map(\.span.columns), spans.map { min($0.columns, result.columns) })
    }

    func testPermutingSizesNeverReordersPlacements() {
        let engine = WorkboardMosaicEngine(footprint: .mixed)
        let sizes: [WorkMaterialCardSize] = [.small, .standard, .large, .small, .standard]
        for permutation in permutations(sizes) {
            for width in [CGFloat(360), 600, 920, 1280] {
                let items = permutation.map { WorkboardMosaicEngine.Item(id: UUID(), size: $0) }
                let result = engine.place(items, availableWidth: width)

                XCTAssertEqual(result.placements.map(\.id), items.map { Optional($0.id) })
                XCTAssertEqual(result.placements.map(\.index), Array(0..<items.count))
                assertReadingOrder(result, context: "permutation at width \(width)")
                assertNoOverlap(result, context: "permutation at width \(width)")
            }
        }
    }

    func testFramesAreDeterministic() {
        let engine = WorkboardMosaicEngine(footprint: .mixed)
        let spans = pseudoRandomSpans(count: 9, seed: 7)
        XCTAssertEqual(
            engine.place(spans: spans, availableWidth: 834),
            engine.place(spans: spans, availableWidth: 834)
        )
    }

    func testIdentifiedFrameLookup() {
        let engine = WorkboardMosaicEngine()
        let first = UUID()
        let second = UUID()
        let result = engine.place(
            sizes: [(id: first, size: .standard), (id: second, size: .standard)],
            availableWidth: 360
        )

        XCTAssertEqual(result.frame(for: first), result.placements[0].frame)
        XCTAssertEqual(result.frame(for: second), result.placements[1].frame)
        XCTAssertNil(result.frame(for: UUID()))
        XCTAssertEqual(result.placement(for: second)?.index, 1)
    }

    // MARK: - Column search

    func testCompactWidthSettlesOnFourUnitColumns() {
        let engine = WorkboardMosaicEngine()
        for width in [CGFloat(320), 360, 390, 428] {
            XCTAssertEqual(engine.columnCount(forWidth: width), 4, "width \(width)")
        }
    }

    func testWiderSurfacesGainColumnsAndStayReadable() {
        let engine = WorkboardMosaicEngine()
        let metrics = WorkboardMosaicMetrics.standard
        var previous = 0
        for width in widthMatrix {
            let columns = engine.columnCount(forWidth: width)
            XCTAssertGreaterThanOrEqual(columns, previous, "columns regressed at width \(width)")
            XCTAssertEqual(columns % 2, 0, "columns must stay even at width \(width)")
            XCTAssertLessThanOrEqual(columns, metrics.maximumColumns)
            let unit = engine.unitWidth(columns: columns, width: width)
            XCTAssertGreaterThanOrEqual(unit, metrics.minimumUnitWidth, "unit too narrow at width \(width)")
            XCTAssertLessThanOrEqual(unit, metrics.maximumUnitWidth, "unit too wide at width \(width)")
            previous = columns
        }
        XCTAssertGreaterThan(engine.columnCount(forWidth: 1280), engine.columnCount(forWidth: 360))
    }

    func testVeryNarrowWidthDropsBelowTheCompactFloorRatherThanShrinkTiles() {
        let engine = WorkboardMosaicEngine(footprint: .mixed)
        XCTAssertEqual(engine.columnCount(forWidth: 200), WorkboardMosaicMetrics.absoluteMinimumColumns)

        let result = engine.place(spans: [.large, .standard, .small], availableWidth: 200)
        XCTAssertEqual(result.columns, 2)
        // The large span clamps to the grid instead of overflowing it.
        XCTAssertEqual(result.placements[0].span.columns, 2)
        assertInBounds(result, context: "narrow clamp")
        assertNoOverlap(result, context: "narrow clamp")
    }

    func testUnitClampsOnVeryWideSurfaces() {
        let engine = WorkboardMosaicEngine()
        let result = engine.place(spans: [.standard, .standard], availableWidth: 6000)
        XCTAssertEqual(result.columns, WorkboardMosaicMetrics.standard.maximumColumns)
        XCTAssertEqual(result.unitSize.width, WorkboardMosaicMetrics.standard.maximumUnitWidth, accuracy: 0.001)
        XCTAssertLessThan(result.contentSize.width, 6000)
    }

    // MARK: - Degenerate input

    func testDegenerateWidthsStayFiniteAndPositive() {
        let engine = WorkboardMosaicEngine(footprint: .mixed)
        for width in [CGFloat(0), -400, .nan, .infinity, -.infinity, 1, 0.0001] {
            let result = engine.place(spans: [.standard, .small, .large], availableWidth: width)
            XCTAssertTrue(result.unitSize.width.isFinite, "width \(width)")
            XCTAssertGreaterThan(result.unitSize.width, 0, "width \(width)")
            XCTAssertGreaterThan(result.unitSize.height, 0, "width \(width)")
            XCTAssertTrue(result.contentSize.width.isFinite, "width \(width)")
            XCTAssertTrue(result.contentSize.height.isFinite, "width \(width)")
            XCTAssertGreaterThanOrEqual(result.columns, WorkboardMosaicMetrics.absoluteMinimumColumns)
            assertNoOverlap(result, context: "width \(width)")
            assertInBounds(result, context: "width \(width)")
        }
    }

    func testDegenerateMetricsAreSanitised() {
        let metrics = WorkboardMosaicMetrics(
            spacing: .nan,
            minimumUnitWidth: 400,
            comfortableUnitWidth: -10,
            maximumUnitWidth: 20,
            unitAspectRatio: .infinity,
            preferredMinimumColumns: -6,
            maximumColumns: 1,
            fallbackWidth: .nan
        )
        XCTAssertEqual(metrics.spacing, 0)
        XCTAssertGreaterThanOrEqual(metrics.maximumUnitWidth, metrics.minimumUnitWidth)
        XCTAssertGreaterThanOrEqual(metrics.comfortableUnitWidth, metrics.minimumUnitWidth)
        XCTAssertLessThanOrEqual(metrics.comfortableUnitWidth, metrics.maximumUnitWidth)
        XCTAssertEqual(metrics.unitAspectRatio, 1)
        XCTAssertEqual(metrics.preferredMinimumColumns, WorkboardMosaicMetrics.absoluteMinimumColumns)
        XCTAssertGreaterThanOrEqual(metrics.maximumColumns, metrics.preferredMinimumColumns)
        XCTAssertEqual(metrics.fallbackWidth, 360)

        let result = WorkboardMosaicEngine(metrics: metrics, footprint: .mixed)
            .place(spans: [.large, .small], availableWidth: 500)
        assertNoOverlap(result, context: "sanitised metrics")
        assertInBounds(result, context: "sanitised metrics")
    }

    func testEmptyBoardHasNoHeightAndAppendsAtZero() {
        let engine = WorkboardMosaicEngine()
        let result = engine.place(spans: [], availableWidth: 600)
        XCTAssertTrue(result.placements.isEmpty)
        XCTAssertEqual(result.contentSize.height, 0)
        XCTAssertGreaterThan(result.contentSize.width, 0)
        XCTAssertEqual(result.insertionIndex(at: CGPoint(x: 120, y: 40)), 0)
    }

    func testProposalChurnResolvesToAUsableWidth() {
        let metrics = WorkboardMosaicMetrics.standard
        let proposals: [ProposedViewSize] = [
            .unspecified,
            .zero,
            .infinity,
            ProposedViewSize(width: nil, height: 400),
            ProposedViewSize(width: .nan, height: 400),
            ProposedViewSize(width: -120, height: nil),
            ProposedViewSize(width: 0, height: 0)
        ]
        for proposal in proposals {
            let width = WorkboardMosaicLayout.resolvedWidth(from: proposal, metrics: metrics)
            XCTAssertEqual(width, metrics.fallbackWidth)
        }
        XCTAssertEqual(
            WorkboardMosaicLayout.resolvedWidth(from: ProposedViewSize(width: 512, height: nil), metrics: metrics),
            512
        )
    }

    /// A width-less proposal is a probe for the layout's own requirement, and
    /// the engine lays out happily at two columns — so the minimum it reports
    /// must be the two-column grid, not the fallback width its height estimate
    /// is derived from.
    func testReportedMinimumWidthIsTheTwoColumnGridNotTheFallback() {
        let metrics = WorkboardMosaicMetrics.standard
        let minimum = WorkboardMosaicLayout.minimumContentWidth(metrics: metrics)
        let twoColumns = WorkboardMosaicEngine(metrics: metrics)
            .place(spans: [.standard], availableWidth: 200)

        XCTAssertLessThanOrEqual(minimum, twoColumns.contentSize.width)
        XCTAssertLessThan(minimum, metrics.fallbackWidth)
        XCTAssertGreaterThan(minimum, 0)
    }

    // MARK: - Dynamic Type

    func testLargerDynamicTypeTradesColumnsForTileSize() {
        let width: CGFloat = 920
        let standard = WorkboardMosaicEngine(metrics: .scaled(for: .large))
        let accessible = WorkboardMosaicEngine(metrics: .scaled(for: .accessibility5))

        let standardColumns = standard.columnCount(forWidth: width)
        let accessibleColumns = accessible.columnCount(forWidth: width)
        XCTAssertLessThan(accessibleColumns, standardColumns)
        XCTAssertGreaterThan(
            accessible.unitWidth(columns: accessibleColumns, width: width),
            standard.unitWidth(columns: standardColumns, width: width)
        )
        XCTAssertEqual(WorkboardMosaicMetrics.unitScale(for: .medium), 1)
    }

    func testDynamicTypeStillHoldsGeometryInvariants() {
        for dynamicTypeSize in DynamicTypeSize.allCases {
            let engine = WorkboardMosaicEngine(metrics: .scaled(for: dynamicTypeSize), footprint: .mixed)
            for width in [CGFloat(320), 600, 1280] {
                let result = engine.place(spans: pseudoRandomSpans(count: 11, seed: 3), availableWidth: width)
                assertNoOverlap(result, context: "\(dynamicTypeSize) at \(width)")
                assertInBounds(result, context: "\(dynamicTypeSize) at \(width)")
                assertReadingOrder(result, context: "\(dynamicTypeSize) at \(width)")
            }
        }
    }

    // MARK: - Insertion index

    func testInsertionIndexFollowsReadingOrder() {
        let engine = WorkboardMosaicEngine()
        let result = engine.place(spans: Array(repeating: .standard, count: 6), availableWidth: 360)
        XCTAssertEqual(result.columns, 4)

        let first = result.placements[0].frame
        XCTAssertEqual(result.insertionIndex(at: CGPoint(x: first.minX + 4, y: first.midY)), 0)
        XCTAssertEqual(result.insertionIndex(at: CGPoint(x: first.maxX - 4, y: first.midY)), 1)

        let last = result.placements[5].frame
        XCTAssertEqual(result.insertionIndex(at: CGPoint(x: last.maxX - 4, y: last.maxY + 200)), 6)
        XCTAssertEqual(result.insertionIndex(at: CGPoint(x: -400, y: -400)), 0)

        let third = result.placements[2].frame
        XCTAssertEqual(result.insertionIndex(at: CGPoint(x: third.minX + 2, y: third.midY)), 2)
        XCTAssertEqual(result.insertionIndex(at: CGPoint(x: third.maxX - 2, y: third.midY)), 3)
    }

    /// The board's most common drop: releasing a card into the empty space
    /// after the last one. Those units hold no tile, so a nearest-tile search
    /// resolves them to whichever neighbour happens to be closest and the card
    /// lands mid-board; the band walk appends across the whole region.
    func testDroppingIntoTheTrailingEmptyRegionAppends() {
        let engine = WorkboardMosaicEngine()
        let result = engine.place(spans: Array(repeating: .standard, count: 3), availableWidth: 330)
        XCTAssertEqual(result.columns, 4)

        let lastBand = result.placements[2].frame
        let emptyMinX = lastBand.maxX + WorkboardMosaicMetrics.standard.spacing
        for x in stride(from: emptyMinX + 1, through: result.contentSize.width, by: 9) {
            for y in stride(from: lastBand.minY, through: lastBand.maxY, by: 11) {
                XCTAssertEqual(
                    result.insertionIndex(at: CGPoint(x: x, y: y)),
                    3,
                    "the empty trailing slot must append, not insert (\(x), \(y))"
                )
            }
        }
    }

    func testInsertionIndexIsMonotonicInBothAxes() {
        let engine = WorkboardMosaicEngine(footprint: .mixed)
        let spans = pseudoRandomSpans(count: 11, seed: 7)
        let result = engine.place(spans: spans, availableWidth: 512)

        for y in stride(from: CGFloat(2), through: result.contentSize.height, by: 13) {
            var previous = 0
            for x in stride(from: CGFloat(2), through: result.contentSize.width, by: 17) {
                let index = result.insertionIndex(at: CGPoint(x: x, y: y))
                XCTAssertGreaterThanOrEqual(index, previous, "reading order reversed at (\(x), \(y))")
                previous = index
            }
        }

        for x in stride(from: CGFloat(2), through: result.contentSize.width, by: 17) {
            var previous = 0
            for y in stride(from: CGFloat(2), through: result.contentSize.height, by: 13) {
                let index = result.insertionIndex(at: CGPoint(x: x, y: y))
                XCTAssertGreaterThanOrEqual(index, previous, "reading order reversed at (\(x), \(y))")
                previous = index
            }
        }
    }

    func testInsertionIndexIsAlwaysAValidInsertionPoint() {
        let engine = WorkboardMosaicEngine(footprint: .mixed)
        let spans = pseudoRandomSpans(count: 13, seed: 42)
        let result = engine.place(spans: spans, availableWidth: 744)
        for x in stride(from: CGFloat(-50), through: result.contentSize.width + 50, by: 37) {
            for y in stride(from: CGFloat(-50), through: result.contentSize.height + 50, by: 41) {
                let index = result.insertionIndex(at: CGPoint(x: x, y: y))
                XCTAssertGreaterThanOrEqual(index, 0)
                XCTAssertLessThanOrEqual(index, spans.count)
            }
        }
        XCTAssertEqual(result.insertionIndex(at: CGPoint(x: CGFloat.nan, y: 10)), spans.count)
        XCTAssertEqual(result.insertionIndex(at: CGPoint(x: 10, y: CGFloat.infinity)), spans.count)
    }

    // MARK: - Layout shell

    func testCentringInsetOnlyAppliesToLeftoverWidth() {
        XCTAssertEqual(
            WorkboardMosaicLayout.horizontalInset(containerWidth: 1000, contentWidth: 600),
            200
        )
        XCTAssertEqual(
            WorkboardMosaicLayout.horizontalInset(containerWidth: 400, contentWidth: 600),
            0
        )
        XCTAssertEqual(
            WorkboardMosaicLayout.horizontalInset(containerWidth: .nan, contentWidth: 600),
            0
        )
    }

    func testRightToLeftMirrorsXAndPreservesSize() {
        let engine = WorkboardMosaicEngine()
        let result = engine.place(spans: Array(repeating: .standard, count: 4), availableWidth: 360)
        let contentWidth = result.contentSize.width

        for placement in result.placements {
            let mirrored = WorkboardMosaicLayout.presentedFrame(
                placement.frame,
                contentWidth: contentWidth,
                layoutDirection: .rightToLeft
            )
            XCTAssertEqual(mirrored.width, placement.frame.width, accuracy: 0.001)
            XCTAssertEqual(mirrored.height, placement.frame.height, accuracy: 0.001)
            XCTAssertEqual(mirrored.minY, placement.frame.minY, accuracy: 0.001)
            XCTAssertEqual(mirrored.minX, contentWidth - placement.frame.maxX, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(mirrored.minX, -0.001)
            XCTAssertLessThanOrEqual(mirrored.maxX, contentWidth + 0.001)
        }

        // Leading-to-trailing order survives the mirror: the first card sits on
        // the right in a right-to-left board.
        let firstMirrored = WorkboardMosaicLayout.presentedFrame(
            result.placements[0].frame,
            contentWidth: contentWidth,
            layoutDirection: .rightToLeft
        )
        let secondMirrored = WorkboardMosaicLayout.presentedFrame(
            result.placements[1].frame,
            contentWidth: contentWidth,
            layoutDirection: .rightToLeft
        )
        XCTAssertGreaterThan(firstMirrored.minX, secondMirrored.minX)

        let unchanged = WorkboardMosaicLayout.presentedFrame(
            result.placements[0].frame,
            contentWidth: contentWidth,
            layoutDirection: .leftToRight
        )
        XCTAssertEqual(unchanged, result.placements[0].frame)
    }

    func testInsertionIndexMirrorsForRightToLeft() {
        let engine = WorkboardMosaicEngine()
        let result = engine.place(spans: Array(repeating: .standard, count: 4), availableWidth: 360)
        let containerWidth = result.contentSize.width

        let nearRightEdge = CGPoint(x: containerWidth - 4, y: 10)
        XCTAssertEqual(
            WorkboardMosaicLayout.insertionIndex(
                at: nearRightEdge,
                in: result,
                containerWidth: containerWidth,
                layoutDirection: .rightToLeft
            ),
            0
        )
        XCTAssertEqual(
            WorkboardMosaicLayout.insertionIndex(
                at: nearRightEdge,
                in: result,
                containerWidth: containerWidth,
                layoutDirection: .leftToRight
            ),
            2
        )
    }

    func testInsertionIndexUndoesCentringInset() {
        let engine = WorkboardMosaicEngine()
        let result = engine.place(spans: Array(repeating: .standard, count: 2), availableWidth: 360)
        let containerWidth = result.contentSize.width + 200
        let inset: CGFloat = 100

        let point = CGPoint(x: inset + result.placements[0].frame.minX + 4, y: 10)
        XCTAssertEqual(
            WorkboardMosaicLayout.insertionIndex(
                at: point,
                in: result,
                containerWidth: containerWidth,
                layoutDirection: .leftToRight
            ),
            0
        )
    }

    // MARK: - One footprint

    /// TOTAL enforcement, stated as a test: whatever a row stores, the DEFAULT
    /// engine grants the same tile. This is what the fixed-slot drag rests on —
    /// one reachable wide card and every slot rectangle below is a lie — so it
    /// is checked over every size, every entry point into the engine and a
    /// width matrix rather than at one convenient width.
    func testTheDefaultEngineGrantsOneFootprintWhateverARowStores() {
        let engine = WorkboardMosaicEngine()
        let standardSpan = WorkboardFootprint.uniformSpan
        for width in widthMatrix {
            let bySpan = engine.place(spans: [.small, .large, .standard, .large], availableWidth: width)
            let sizes: [WorkMaterialCardSize] = [.small, .large, .standard, .large]
            let bySize = engine.place(
                sizes: sizes.map { (id: UUID(), size: $0) },
                availableWidth: width
            )
            let byItem = engine.place(
                sizes.map { WorkboardMosaicEngine.Item(id: UUID(), size: $0) },
                availableWidth: width
            )
            for result in [bySpan, bySize, byItem] {
                let granted = min(standardSpan.columns, result.columns)
                XCTAssertEqual(
                    result.placements.map(\.span.columns),
                    Array(repeating: granted, count: sizes.count),
                    "a stored size reached the grid at width \(width)"
                )
                XCTAssertEqual(
                    Set(result.placements.map(\.frame.width)).count, 1,
                    "tiles differ in width at \(width)"
                )
                XCTAssertEqual(
                    Set(result.placements.map(\.frame.height)).count, 1,
                    "tiles differ in height at \(width)"
                )
            }
            // Same board, same frames, whichever size the rows happen to hold.
            let allStandard = engine.place(
                spans: Array(repeating: WorkboardMosaicSpan.standard, count: sizes.count),
                availableWidth: width
            )
            XCTAssertEqual(bySpan, allStandard, "the mixed board is not the uniform board at \(width)")
        }
    }

    /// The switch is a switch. Asking for the mixed path still gets it, which
    /// is what keeps the decision reversible rather than merely commented.
    func testTheMixedPathStaysReachableBehindTheFootprintSwitch() {
        let mixed = WorkboardMosaicEngine(footprint: .mixed)
            .place(spans: [.small, .large], availableWidth: 920)
        XCTAssertEqual(mixed.placements[0].span, .small)
        XCTAssertEqual(mixed.placements[1].span, .large)
        XCTAssertEqual(WorkboardFootprint.rendered(.large), .standard)
        XCTAssertEqual(WorkboardFootprint.rendered(.small), .standard)
        XCTAssertEqual(WorkboardFootprint.rendered(.standard), .standard)
    }

    /// THE SWITCH IS NOT THE WHOLE REVERSAL, and this is what says so out loud.
    ///
    /// `WorkboardFootprint.isUniform` returns the ENGINE to mixed spans. It does
    /// not return the card FACES: `WorkboardSourceCard` and
    /// `WorkboardAudioCardView` each hold a `layoutSize` that answers
    /// `.standard` outright, which is exactly right while one footprint is
    /// enforced and exactly wrong the moment it is not — standard content, and a
    /// standard companion band, drawn into a one-unit tile. Nor does the switch
    /// move the canvas's drop resolution off the slot functions and back onto
    /// `WorkboardMosaicLayout.insertionIndex(at:in:containerWidth:layoutDirection:)`,
    /// which is the only reader that understands a mixed board's gaps.
    ///
    /// So the coupling is asserted rather than left in a comment: while the
    /// board is uniform the hardcoded face is correct and is pinned as such,
    /// and the day somebody flips the switch this test fails and names the files
    /// that have to follow it. A silent half-reversal is the failure mode a
    /// switch invites; a red test is not.
    func testFlippingTheFootprintSwitchAloneWouldNotReturnTheCardFaces() throws {
        let faces = [
            "Conduck/Views/Workboard/WorkboardCaptureCanvas.swift",
            "Conduck/Views/Workboard/WorkboardAudioCardView.swift",
        ]
        let hardcoded = "private var layoutSize: WorkMaterialCardSize { .standard }"
        let remedy = "route it through WorkboardFootprint.rendered(material.cardSize),"
            + " restore its compact/wide drawing, and resolve drops through"
            + " WorkboardMosaicLayout.insertionIndex(at:in:containerWidth:layoutDirection:)"
            + " instead of the slot functions"
        for path in faces {
            let source = try RefusalLaneSource.source(at: path)
            if WorkboardFootprint.isUniform {
                XCTAssertTrue(
                    source.contains(hardcoded),
                    "\(path) draws the granted tile while one footprint is enforced"
                )
            } else {
                XCTAssertFalse(
                    source.contains(hardcoded),
                    "\(path) still hardcodes its footprint on a mixed board — \(remedy)"
                )
            }
        }
    }

    /// Six cards per row on the board's own column, two on a phone. The memo's
    /// whole width argument is this number; anything else and the Mac window is
    /// still mostly margin.
    func testTheBoardsColumnHoldsSixCardsPerRowAndAPhoneHoldsTwo() {
        let engine = WorkboardMosaicEngine()
        // `WorkboardDetailView` pads before it caps, so the grid is the cap
        // minus the two 16pt insets.
        let grid = WorkboardMetrics.contentMaxWidth - 2 * WorkboardMetrics.standardSpacing
        XCTAssertEqual(engine.cardsPerRow(forWidth: grid), 6)
        XCTAssertEqual(engine.cardsPerRow(forWidth: 360 - 2 * WorkboardMetrics.standardSpacing), 2)
        for width in widthMatrix {
            XCTAssertGreaterThanOrEqual(engine.cardsPerRow(forWidth: width), 2, "width \(width)")
            XCTAssertEqual(engine.columnCount(forWidth: width) % 2, 0, "width \(width)")
        }
    }

    // MARK: - Slots

    /// Slots are a pure function of (count, width): they answer for the uniform
    /// grid whatever the cards store, and they do not move while one card is
    /// lifted out of them. That is the property the drag is built on.
    func testSlotFramesAreTheUniformGridAndIgnoreWhatCardsStore() {
        let engine = WorkboardMosaicEngine()
        for width in widthMatrix {
            let slots = engine.slotFrames(count: 7, width: width)
            XCTAssertEqual(slots.count, 7)
            XCTAssertEqual(
                slots, engine.place(spans: Array(repeating: .standard, count: 7), availableWidth: width)
                    .placements.map(\.frame)
            )
            XCTAssertEqual(Set(slots.map(\.width)).count, 1, "width \(width)")
            let perRow = engine.cardsPerRow(forWidth: width)
            if slots.count > perRow {
                XCTAssertEqual(slots[0].minY, slots[perRow - 1].minY, accuracy: 0.001)
                XCTAssertGreaterThan(slots[perRow].minY, slots[0].minY, "row did not wrap at \(width)")
            }
        }
        XCTAssertTrue(engine.slotFrames(count: 0, width: 920).isEmpty)
    }

    /// The presented form a placeholder is drawn from: mirrored for
    /// right-to-left and shifted by the same centring inset the layout applies,
    /// so a caller never re-derives either and cannot mirror twice.
    func testPresentedSlotFramesCarryTheMirrorAndTheCentringInset() {
        let engine = WorkboardMosaicEngine()
        // Wide enough that the unit clamps and the grid stops filling the
        // container, which is the only case a centring inset exists in.
        let width: CGFloat = 2400
        let result = engine.uniformResult(count: 5, width: width)
        let inset = WorkboardMosaicLayout.horizontalInset(
            containerWidth: width, contentWidth: result.contentSize.width
        )
        XCTAssertGreaterThan(inset, 0, "the fixture needs leftover width for the inset to matter")

        let leftToRight = engine.presentedSlotFrames(count: 5, width: width, layoutDirection: .leftToRight)
        XCTAssertEqual(leftToRight[0].minX, inset + result.placements[0].frame.minX, accuracy: 0.001)

        let rightToLeft = engine.presentedSlotFrames(count: 5, width: width, layoutDirection: .rightToLeft)
        for (index, frame) in rightToLeft.enumerated() {
            XCTAssertEqual(frame.width, leftToRight[index].width, accuracy: 0.001)
            XCTAssertEqual(frame.minY, leftToRight[index].minY, accuracy: 0.001)
        }
        XCTAssertGreaterThan(
            rightToLeft[0].minX, rightToLeft[1].minX,
            "the first card sits on the right in a right-to-left board"
        )
    }

    /// The boundary rule, checked as a boundary: a pointer holds its slot right
    /// up to a tile's horizontal midpoint and takes the next one past it. The
    /// lines are the same in both layout directions once the mirror is undone.
    func testInsertionSlotResolvesOnTileMidpointsInBothDirections() {
        let engine = WorkboardMosaicEngine()
        let width: CGFloat = 920
        let frames = engine.presentedSlotFrames(count: 6, width: width, layoutDirection: .leftToRight)

        for (index, frame) in frames.enumerated() {
            XCTAssertEqual(
                engine.insertionSlot(
                    at: CGPoint(x: frame.midX - 1, y: frame.midY),
                    count: 6, width: width, layoutDirection: .leftToRight
                ),
                index,
                "slot \(index) released its gap before the midpoint"
            )
            XCTAssertEqual(
                engine.insertionSlot(
                    at: CGPoint(x: frame.midX + 1, y: frame.midY),
                    count: 6, width: width, layoutDirection: .leftToRight
                ),
                index + 1,
                "slot \(index) held its gap past the midpoint"
            )
        }

        let mirrored = engine.presentedSlotFrames(count: 6, width: width, layoutDirection: .rightToLeft)
        XCTAssertEqual(
            engine.insertionSlot(
                at: CGPoint(x: mirrored[0].midX + 1, y: mirrored[0].midY),
                count: 6, width: width, layoutDirection: .rightToLeft
            ),
            0,
            "right-to-left reads the other way and still names the first gap"
        )
        // Below every band, and on an empty board.
        XCTAssertEqual(
            engine.insertionSlot(
                at: CGPoint(x: 10, y: 100_000), count: 6, width: width, layoutDirection: .leftToRight
            ),
            6
        )
        XCTAssertEqual(
            engine.insertionSlot(
                at: CGPoint(x: 10, y: 10), count: 0, width: width, layoutDirection: .leftToRight
            ),
            0
        )
    }

    /// A slot is always a valid gap, at every width, for any pointer.
    func testInsertionSlotIsAlwaysAValidGap() {
        let engine = WorkboardMosaicEngine()
        for width in widthMatrix {
            let result = engine.uniformResult(count: 9, width: width)
            for x in stride(from: CGFloat(-60), through: width + 60, by: 29) {
                for y in stride(from: CGFloat(-60), through: result.contentSize.height + 60, by: 31) {
                    for direction in [LayoutDirection.leftToRight, .rightToLeft] {
                        let slot = engine.insertionSlot(
                            at: CGPoint(x: x, y: y), count: 9, width: width, layoutDirection: direction
                        )
                        XCTAssertGreaterThanOrEqual(slot, 0)
                        XCTAssertLessThanOrEqual(slot, 9)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func assertNoOverlap(
        _ result: WorkboardMosaicEngine.Result,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let frames = result.placements.map(\.frame)
        for outer in frames.indices {
            for inner in frames.indices where inner > outer {
                let intersection = frames[outer].insetBy(dx: 0.01, dy: 0.01)
                    .intersection(frames[inner].insetBy(dx: 0.01, dy: 0.01))
                XCTAssertTrue(
                    intersection.isNull || intersection.isEmpty,
                    "\(context): tiles \(outer) and \(inner) overlap",
                    file: file,
                    line: line
                )
            }
        }
    }

    private func assertInBounds(
        _ result: WorkboardMosaicEngine.Result,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for placement in result.placements {
            let frame = placement.frame
            XCTAssertTrue(frame.minX.isFinite && frame.minY.isFinite, "\(context): non-finite origin", file: file, line: line)
            XCTAssertGreaterThan(frame.width, 0, "\(context): empty tile width", file: file, line: line)
            XCTAssertGreaterThan(frame.height, 0, "\(context): empty tile height", file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minX, -0.001, "\(context): tile left of grid", file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minY, -0.001, "\(context): tile above grid", file: file, line: line)
            XCTAssertLessThanOrEqual(
                frame.maxX,
                result.contentSize.width + 0.001,
                "\(context): tile right of grid",
                file: file,
                line: line
            )
            XCTAssertLessThanOrEqual(
                frame.maxY,
                result.contentSize.height + 0.001,
                "\(context): tile below grid",
                file: file,
                line: line
            )
        }
    }

    /// A later card may sit beside or below an earlier one, never above it.
    private func assertReadingOrder(
        _ result: WorkboardMosaicEngine.Result,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var previous: CGRect?
        for placement in result.placements {
            defer { previous = placement.frame }
            guard let earlier = previous else { continue }
            XCTAssertGreaterThanOrEqual(
                placement.frame.minY,
                earlier.minY - 0.001,
                "\(context): tile \(placement.index) rose above its predecessor",
                file: file,
                line: line
            )
            if abs(placement.frame.minY - earlier.minY) < 0.001 {
                XCTAssertGreaterThan(
                    placement.frame.minX,
                    earlier.minX,
                    "\(context): tile \(placement.index) moved left within its row",
                    file: file,
                    line: line
                )
            }
        }
    }

    private func pseudoRandomSpans(count: Int, seed: UInt64) -> [WorkboardMosaicSpan] {
        var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let palette: [WorkboardMosaicSpan] = [.small, .standard, .large]
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return palette[Int((state >> 33) % UInt64(palette.count))]
        }
    }

    private func permutations<T>(_ elements: [T]) -> [[T]] {
        guard elements.count > 1 else { return [elements] }
        var output: [[T]] = []
        for index in elements.indices {
            var rest = elements
            let element = rest.remove(at: index)
            for tail in permutations(rest) {
                output.append([element] + tail)
            }
        }
        return output
    }
}
