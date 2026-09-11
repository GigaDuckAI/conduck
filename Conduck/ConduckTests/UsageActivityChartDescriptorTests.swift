// SPDX-License-Identifier: Apache-2.0

// Conduck
// UsageActivityChartDescriptorTests.swift
//
// Exercises the real accessibility descriptor's update lifecycle. SwiftUI
// retains the descriptor while a user changes measure or range, so replacing
// its series alone leaves VoiceOver describing new data with old units and
// bounds. These tests reuse one descriptor across those changes; a test that
// only constructed a fresh descriptor would miss the regression.

import Accessibility
import SwiftUI
import XCTest

@testable import Conduck

@MainActor
final class UsageActivityChartDescriptorTests: XCTestCase {
    private func bucket(
        day: Int = 0,
        attempts: Int = 4,
        turns: Int = 3,
        tokens: Int
    ) -> GatewayUsageActivityBucket {
        let calendar = Calendar.current
        let anchor = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_760_000_000))
        let start = calendar.date(byAdding: .day, value: day, to: anchor)!
        return GatewayUsageActivityBucket(
            periodStart: start,
            attempts: attempts,
            turns: turns,
            reportedTokens: tokens,
            tokenMeasuredAttempts: attempts
        )
    }

    private func representation(
        metric: UsageChartMetric,
        valueName: String,
        buckets: [GatewayUsageActivityBucket]
    ) -> UsageActivityChartDescriptor {
        UsageActivityChartDescriptor(
            title: "\(valueName) per day",
            seriesName: valueName,
            axisName: "Period",
            valueName: valueName,
            metric: metric,
            unit: .day,
            buckets: buckets,
            segments: []
        )
    }

    func testChangingMeasureUpdatesExistingAudioGraphUnitsAndBounds() throws {
        let buckets = [bucket(tokens: 12_000)]
        let descriptor = representation(metric: .turns, valueName: "Turns", buckets: buckets)
            .makeChartDescriptor()
        XCTAssertEqual(try XCTUnwrap(descriptor.yAxis).range, 0...3)

        representation(metric: .tokens, valueName: "Tokens", buckets: buckets)
            .updateChartDescriptor(descriptor)

        let tokenAxis = try XCTUnwrap(descriptor.yAxis)
        XCTAssertEqual(tokenAxis.title, "Tokens")
        XCTAssertEqual(tokenAxis.range, 0...12_000)
        XCTAssertEqual(descriptor.title, "Tokens per day")
        XCTAssertEqual(descriptor.series.first?.name, "Tokens")

        representation(metric: .devices, valueName: "Attempts", buckets: buckets)
            .updateChartDescriptor(descriptor)

        let attemptAxis = try XCTUnwrap(descriptor.yAxis)
        XCTAssertEqual(attemptAxis.title, "Attempts")
        XCTAssertEqual(attemptAxis.range, 0...4)
        XCTAssertEqual(descriptor.series.first?.name, "Attempts")
    }

    func testNarrowerRangeLowersExistingAudioGraphMaximum() throws {
        let descriptor = representation(
            metric: .tokens,
            valueName: "Tokens",
            buckets: [bucket(tokens: 20_000), bucket(day: 1, tokens: 450)]
        ).makeChartDescriptor()
        XCTAssertEqual(try XCTUnwrap(descriptor.yAxis).range, 0...20_000)

        representation(
            metric: .tokens,
            valueName: "Tokens",
            buckets: [bucket(day: 1, tokens: 450)]
        ).updateChartDescriptor(descriptor)

        let axis = try XCTUnwrap(descriptor.yAxis)
        XCTAssertEqual(axis.title, "Tokens")
        XCTAssertEqual(axis.range, 0...450)
        XCTAssertEqual(descriptor.series.first?.dataPoints.count, 1)
        XCTAssertEqual((descriptor.xAxis as? AXCategoricalDataAxisDescriptor)?.categoryOrder.count, 1)
    }

    func testZeroAndEmptyUpdatesKeepANondegenerateAudioGraphRange() throws {
        for buckets in [[bucket(tokens: 0)], []] {
            let descriptor = representation(
                metric: .tokens,
                valueName: "Tokens",
                buckets: [bucket(tokens: 20_000)]
            ).makeChartDescriptor()

            representation(metric: .tokens, valueName: "Tokens", buckets: buckets)
                .updateChartDescriptor(descriptor)

            let axis = try XCTUnwrap(descriptor.yAxis)
            XCTAssertEqual(axis.title, "Tokens")
            XCTAssertEqual(axis.range, 0...1)
            XCTAssertEqual(descriptor.series.first?.dataPoints.count, buckets.count)
        }
    }
}
