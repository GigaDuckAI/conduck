// SPDX-License-Identifier: Apache-2.0

// The foreground host owns when an active day is recorded. These tests use
// isolated defaults to verify day counting and the permanent request budget.

import XCTest
@testable import Conduck

@MainActor
final class AppReviewUsageTests: XCTestCase {
    private let key = "appReview.usage.v1"
    private let start = Date(timeIntervalSince1970: 1_800_057_600) // UTC midnight.
    private func date(_ day: Double) -> Date { start.addingTimeInterval(day * 86_400) }

    private func recordThreeDays(_ usage: AppReviewUsage) {
        for day in [0.0, 1, 2] { usage.recordActiveDay(now: date(day)) }
    }

    private func storedState(_ defaults: InMemoryDefaultsStore) throws -> [String: Any] {
        let data = try XCTUnwrap(defaults.data(forKey: key))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testThirdDistinctDayQualifiesWithoutOtherUsageRequirements() {
        let usage = AppReviewUsage(dependencies: .inMemory())
        XCTAssertFalse(usage.isEligible)
        XCTAssertFalse(usage.claimRequest())
        usage.recordActiveDay(now: date(0))
        XCTAssertFalse(usage.isEligible)
        usage.recordActiveDay(now: date(1))
        XCTAssertFalse(usage.isEligible)
        usage.recordActiveDay(now: date(2))
        XCTAssertTrue(usage.isEligible)
        XCTAssertTrue(usage.claimRequest())
    }

    func testRepeatedForegroundEventsOnSameDayCountOnlyOnce() throws {
        let defaults = InMemoryDefaultsStore()
        let usage = AppReviewUsage(dependencies: .inMemory(defaults: defaults))
        for hour in 0..<24 { usage.recordActiveDay(now: date(0).addingTimeInterval(Double(hour * 3_600))) }
        XCTAssertFalse(usage.isEligible)
        XCTAssertEqual(try storedState(defaults)["activeDayCount"] as? Int, 1)
        usage.recordActiveDay(now: date(1))
        XCTAssertFalse(usage.isEligible)
        usage.recordActiveDay(now: date(2))
        XCTAssertTrue(usage.isEligible)
    }

    func testLongGapsCountObservedDaysRatherThanElapsedDays() {
        let usage = AppReviewUsage(dependencies: .inMemory())
        usage.recordActiveDay(now: date(0))
        usage.recordActiveDay(now: date(100))
        XCTAssertFalse(usage.isEligible)
        usage.recordActiveDay(now: date(1_000))
        XCTAssertTrue(usage.isEligible)
    }

    func testClockRollbackDoesNotAdvanceTheCounter() throws {
        let defaults = InMemoryDefaultsStore()
        let usage = AppReviewUsage(dependencies: .inMemory(defaults: defaults))
        usage.recordActiveDay(now: date(10))
        usage.recordActiveDay(now: date(11))
        for day in [0.0, 1, 10, 11] { usage.recordActiveDay(now: date(day)) }
        XCTAssertFalse(usage.isEligible)
        XCTAssertEqual(try storedState(defaults)["activeDayCount"] as? Int, 2)
        usage.recordActiveDay(now: date(12))
        XCTAssertTrue(usage.isEligible)
    }

    func testCounterStaysCappedWhenPresentationIsDeferred() throws {
        let defaults = InMemoryDefaultsStore()
        let usage = AppReviewUsage(dependencies: .inMemory(defaults: defaults))
        for day in 0..<100 { usage.recordActiveDay(now: date(Double(day))) }
        XCTAssertTrue(usage.isEligible)
        XCTAssertEqual(try storedState(defaults)["activeDayCount"] as? Int, 3)
    }

    func testRelaunchPreservesDayCountWithoutCountingSameDayAgain() {
        let dependencies = SettingsDependencies.inMemory()
        let first = AppReviewUsage(dependencies: dependencies)
        first.recordActiveDay(now: date(0))
        first.recordActiveDay(now: date(1))
        let relaunched = AppReviewUsage(dependencies: dependencies)
        relaunched.recordActiveDay(now: date(1))
        XCTAssertFalse(relaunched.isEligible)
        relaunched.recordActiveDay(now: date(2))
        XCTAssertTrue(relaunched.isEligible)
    }

    func testClaimPersistsBeforeReturningAndCannotRepeatAcrossInstances() throws {
        let defaults = InMemoryDefaultsStore()
        let dependencies = SettingsDependencies.inMemory(defaults: defaults)
        let usage = AppReviewUsage(dependencies: dependencies)
        let otherWindow = AppReviewUsage(dependencies: dependencies)
        recordThreeDays(usage)
        XCTAssertTrue(otherWindow.isEligible)
        XCTAssertTrue(usage.claimRequest())
        XCTAssertEqual(try storedState(defaults)["hasRequested"] as? Bool, true)
        XCTAssertFalse(usage.claimRequest())
        XCTAssertFalse(otherWindow.claimRequest())
        let relaunched = AppReviewUsage(dependencies: dependencies)
        for day in 100..<110 { relaunched.recordActiveDay(now: date(Double(day))) }
        XCTAssertFalse(relaunched.isEligible)
        XCTAssertFalse(relaunched.claimRequest())
    }

    func testManualReviewHandoffSuppressesBeforeAnyUsageAndAfterEligibility() {
        for alreadyEligible in [false, true] {
            let dependencies = SettingsDependencies.inMemory()
            let usage = AppReviewUsage(dependencies: dependencies)
            if alreadyEligible { recordThreeDays(usage) }
            usage.suppressRequests()
            usage.suppressRequests()
            let relaunched = AppReviewUsage(dependencies: dependencies)
            recordThreeDays(relaunched)
            XCTAssertFalse(relaunched.isEligible)
            XCTAssertFalse(relaunched.claimRequest())
        }
    }

    func testInvalidDatesNeverCreateAnActiveDay() {
        let defaults = InMemoryDefaultsStore()
        let usage = AppReviewUsage(dependencies: .inMemory(defaults: defaults))
        for seconds in [Double.nan, Double.infinity, -1] {
            usage.recordActiveDay(now: Date(timeIntervalSince1970: seconds))
        }
        XCTAssertNil(defaults.object(forKey: key))
        XCTAssertFalse(usage.isEligible)
    }

    func testMalformedStateFailsClosedAndCannotBeResetByMoreActiveDays() {
        let invalid: [Any] = [
            "wrong storage type", Data("not JSON".utf8),
            Data(#"{"activeDayCount":3,"hasRequested":false}"#.utf8),
            Data(#"{"lastActiveDay":12,"activeDayCount":4,"hasRequested":false}"#.utf8),
            Data(#"{"lastActiveDay":-1,"activeDayCount":3,"hasRequested":false}"#.utf8),
            Data(#"{"lastActiveDay":12,"activeDayCount":0,"hasRequested":false}"#.utf8),
            Data(#"{"lastActiveDay":12,"activeDayCount":3}"#.utf8)
        ]
        for raw in invalid {
            let defaults = InMemoryDefaultsStore(seed: [key: raw])
            let usage = AppReviewUsage(dependencies: .inMemory(defaults: defaults))
            recordThreeDays(usage)
            XCTAssertFalse(usage.isEligible)
            XCTAssertFalse(usage.claimRequest())
        }
    }

    func testStateNeverWritesToCloud() {
        let cloud = InMemoryUbiquitousStore()
        let usage = AppReviewUsage(dependencies: .inMemory(ubiquitous: cloud, cloudAvailable: true))
        recordThreeDays(usage)
        XCTAssertTrue(usage.claimRequest())
        usage.suppressRequests()
        XCTAssertTrue(cloud.dictionaryRepresentation().isEmpty)
        XCTAssertEqual(cloud.synchronizeCallCount, 0)
    }

    func testClearingUsageHistoryCannotRearmAClaimOrManualHandoff() async {
        for manual in [false, true] {
            let dependencies = SettingsDependencies.inMemory()
            let usage = AppReviewUsage(dependencies: dependencies)
            recordThreeDays(usage)
            if manual { usage.suppressRequests() } else { XCTAssertTrue(usage.claimRequest()) }
            let settings = SettingsManager(dependencies: dependencies)
            await settings.advanceGatewayUsageClearedThrough(date(20))
            let relaunched = AppReviewUsage(dependencies: dependencies)
            XCTAssertFalse(relaunched.isEligible)
            XCTAssertFalse(relaunched.claimRequest())
        }
    }
}
