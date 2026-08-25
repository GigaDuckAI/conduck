// SPDX-License-Identifier: Apache-2.0
//
// The share figure the ranked usage rows carry, pinned at its edges. The
// rounding rules are the honesty rules: a tiny-but-real share must never
// print as "0 %", a dominant-but-not-total one must never print as "100 %",
// and exactly-100 % is reserved for a count that IS the whole. Expected
// values are built through the same formatter the implementation uses, so
// these tests hold under any locale the simulator runs in.

import XCTest
@testable import Conduck

final class UsageShareFormatTests: XCTestCase {

    private func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    func testShareIsThePlainRoundedPercentInTheMiddle() {
        XCTAssertEqual(UsageDetailFormat.shareText(100, of: 200), percent(0.5))
        XCTAssertEqual(UsageDetailFormat.shareText(43, of: 100), percent(0.43))
    }

    func testTheWholeReadsAsExactlyOneHundredOnlyWhenItIsTheWhole() {
        XCTAssertEqual(UsageDetailFormat.shareText(7, of: 7), percent(1))
        XCTAssertEqual(
            UsageDetailFormat.shareText(199, of: 200), ">" + percent(0.99),
            "199 of 200 rounds to 100 but is not the whole")
    }

    func testATinyShareNeverPrintsAsZero() {
        XCTAssertEqual(UsageDetailFormat.shareText(1, of: 300), "<" + percent(0.01))
        XCTAssertEqual(
            UsageDetailFormat.shareText(1, of: 100), percent(0.01),
            "a real 1 % is not a trace")
    }

    func testNoShareExistsOverAnEmptyDenominatorOrForNothing() {
        XCTAssertNil(UsageDetailFormat.shareText(0, of: 0))
        XCTAssertNil(UsageDetailFormat.shareText(3, of: 0))
        XCTAssertNil(UsageDetailFormat.shareText(0, of: 12))
    }

    /// The missing-mass footers say their numbers in words — both of them,
    /// because a lone count with no denominator is the shape of caption this
    /// whole surface exists to avoid.
    func testMissingMassFootersNameBothNumbers() {
        XCTAssertEqual(
            UsageDetailFormat.unattributedDeviceFooter(3, of: 120),
            "Device was not recorded on 3 of 120 attempts.")
        XCTAssertEqual(
            UsageDetailFormat.unattributedGatewayFooter(1, of: 9),
            "Gateway was not recorded on 1 of 9 attempts.")
    }

    /// The ranked caption leads with the sample: a trailing share on the row
    /// is unreadable without the absolute count somewhere beside it.
    func testRankedRowCaptionLeadsWithTheAttemptCount() {
        let summary = GatewayUsageAggregator.summarize(
            attempts: [
                GatewayAttemptRecord(
                    id: UUID(),
                    conversationID: UUID(),
                    userMessageID: UUID(),
                    gatewayRef: "openclaw",
                    startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    completedAt: nil,
                    outcome: .succeeded,
                    appErrorCode: nil,
                    origin: .unknown,
                    inputMode: .unknown,
                    requestedModel: nil,
                    finishReason: nil,
                    reportedInputTokens: nil,
                    reportedOutputTokens: nil,
                    reportedTotalTokens: nil,
                    reportedCachedInputTokens: nil,
                    reportedCacheWriteInputTokens: nil,
                    reportedReasoningOutputTokens: nil,
                    originDeviceClass: nil,
                    currentTurnInlineImageCount: nil,
                    priorTurnInlineImageCount: nil,
                    currentTurnInlineTextFileCount: nil,
                    priorTurnInlineTextFileCount: nil,
                    fallbackSourceDevice: nil
                ),
            ],
            liveAttemptIDs: [],
            now: Date(timeIntervalSince1970: 1_700_000_100),
            activityRange: nil,
            calendar: Calendar(identifier: .gregorian),
            grace: 300
        )

        let caption = UsageDetailFormat.rankedRowCaption(summary.byGateway[0])
        XCTAssertTrue(
            caption.hasPrefix("1 attempt · "),
            "caption should open with the sample, got: \(caption)")
    }
}
