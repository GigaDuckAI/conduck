// SPDX-License-Identifier: Apache-2.0

// Tests the stat values actually consumed by the Usage overview. The token
// tile and chart must describe the same usable evidence even when gateways
// report different fields; missing evidence must not become a measured zero.

import XCTest
@testable import Conduck

@MainActor
final class UsageActivityStatTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func attempt(input: Int64? = nil, output: Int64? = nil, total: Int64? = nil) -> GatewayAttemptRecord {
        GatewayAttemptRecord(
            id: UUID(), conversationID: UUID(), userMessageID: UUID(), gatewayRef: "openclaw",
            startedAt: now.addingTimeInterval(-60), completedAt: now, outcome: .succeeded,
            reportedInputTokens: input, reportedOutputTokens: output, reportedTotalTokens: total)
    }

    func testDisplayedTokenTileUsesTheSameMixedEvidenceAsTheChart() throws {
        let summary = GatewayUsageAggregator.summarize(
            attempts: [attempt(total: 100), attempt(input: 100, output: 200)],
            liveAttemptIDs: [], now: now)
        let stat = try XCTUnwrap(UsageDashboardContent.activityStats(for: summary).first { $0.id == "tokens" })

        XCTAssertEqual(stat.value, Int64(400).formatted(.number.notation(.compactName)))
        XCTAssertEqual(summary.activity.buckets.reduce(0) { $0 + $1.reportedTokens }, 400)
        XCTAssertEqual(summary.tokens.reportedTotal.sum, 100, "Provider-specific detail retains its own evidence.")
        XCTAssertEqual(String(localized: stat.accessibility),
                       "400 tokens, using reported totals or input plus output")
    }

    func testTokenTileDistinguishesNoUsableTotalFromMeasuredZero() throws {
        for rows in [[attempt()], [attempt(input: 100)]] {
            let summary = GatewayUsageAggregator.summarize(attempts: rows, liveAttemptIDs: [], now: now)
            XCTAssertFalse(UsageDashboardContent.activityStats(for: summary).contains { $0.id == "tokens" })
        }
        let zero = GatewayUsageAggregator.summarize(
            attempts: [attempt(total: 0)], liveAttemptIDs: [], now: now)
        let stat = try XCTUnwrap(UsageDashboardContent.activityStats(for: zero).first { $0.id == "tokens" })
        XCTAssertEqual(stat.value, "0")
    }
}
