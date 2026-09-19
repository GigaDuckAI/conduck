// SPDX-License-Identifier: Apache-2.0

import CloudKit
import XCTest
@testable import Conduck

/// Exercises the health reducer used by live and replayed CloudKit events.
/// No CloudKit container or account is needed: chronology, store identity and
/// nested error shapes are the inputs that decide whether a warning is truthful.
@MainActor
final class CloudSyncMonitorTests: XCTestCase {

    // MARK: - Actionable states (the user can fix → surface)

    func testNoAccountIsActionable() {
        XCTAssertEqual(CloudSyncMonitor.actionableReason(for: .noAccount), .noAccount)
    }

    func testRestrictedIsActionable() {
        XCTAssertEqual(CloudSyncMonitor.actionableReason(for: .restricted), .restricted)
    }

    // MARK: - Silent states (healthy or transient → never alarm)

    func testAvailableIsSilent() {
        XCTAssertNil(CloudSyncMonitor.actionableReason(for: .available))
    }

    func testCouldNotDetermineIsSilent() {
        // Transient — the system retries; surfacing it would be a false alarm.
        XCTAssertNil(CloudSyncMonitor.actionableReason(for: .couldNotDetermine))
    }

    func testTemporarilyUnavailableIsSilent() {
        // Transient — the system retries; surfacing it would be a false alarm.
        XCTAssertNil(CloudSyncMonitor.actionableReason(for: .temporarilyUnavailable))
    }

    // MARK: - Reason copy is non-empty for every actionable reason

    func testEveryReasonHasBannerAndSettingsCopy() {
        for reason in [CloudSyncMonitor.Reason.noAccount, .restricted, .quotaExceeded] {
            XCTAssertFalse(
                String(localized: reason.bannerMessage).isEmpty,
                "Missing banner copy for \(reason)"
            )
            XCTAssertFalse(
                String(localized: reason.settingsMessage).isEmpty,
                "Missing settings copy for \(reason)"
            )
        }
    }

    func testAvailableAccountDoesNotClearStorageFailure() {
        var health = CloudSyncHealth()
        health.ingest(event(at: 1, quota: true))

        health.applyAccountStatus(.available, at: date(2))
        XCTAssertEqual(health.reason, .quotaExceeded)
        health.applyAccountStatus(.temporarilyUnavailable, at: date(3))
        XCTAssertEqual(health.reason, .quotaExceeded)
        health.applyAccountStatus(.available, at: date(4))
        XCTAssertEqual(health.reason, .quotaExceeded)
        XCTAssertNil(health.ignoreEventsBefore, "Temporary account changes must not discard retained quota evidence")
    }

    func testOnlyNewerSuccessfulExportClearsAffectedStore() {
        var health = CloudSyncHealth()
        health.ingest(event(at: 2, quota: true))
        for kind in [SyncEventSummary.Kind.setup, .importEvent] {
            health.ingest(event(at: 3, kind: kind, succeeded: true))
            XCTAssertEqual(health.reason, .quotaExceeded)
        }
        health.ingest(event(at: 3, store: "blobs", succeeded: true))
        XCTAssertEqual(health.reason, .quotaExceeded)
        health.ingest(event(at: 1, succeeded: true))
        XCTAssertEqual(health.reason, .quotaExceeded)
        health.ingest(event(at: 4)) // An unrelated failure is not recovery.
        XCTAssertEqual(health.reason, .quotaExceeded)
        health.ingest(event(at: 5, succeeded: true))
        XCTAssertNil(health.reason)
    }

    func testEachAffectedStoreMustRecover() {
        var health = CloudSyncHealth()
        health.ingest(event(at: 1, quota: true))
        health.ingest(event(at: 2, store: "blobs", quota: true))
        health.ingest(event(at: 3, succeeded: true))
        XCTAssertEqual(health.reason, .quotaExceeded)
        health.ingest(event(at: 4, store: "blobs", succeeded: true))
        XCTAssertNil(health.reason)
    }

    func testOutOfOrderReplayCannotResurrectRecoveredQuotaFailure() {
        var health = CloudSyncHealth()
        health.ingest(event(at: 3, succeeded: true))
        health.ingest(event(at: 1, quota: true))
        health.ingest(event(at: 2, quota: true))
        XCTAssertNil(health.reason)

        health.ingest(event(at: 4, quota: true))
        XCTAssertEqual(health.reason, .quotaExceeded)
        health.ingest(event(at: 3, succeeded: true))
        XCTAssertEqual(health.reason, .quotaExceeded)
    }

    func testEqualTimestampSuccessCannotClaimRecovery() {
        for failureFirst in [true, false] {
            var health = CloudSyncHealth()
            let failure = event(at: 2, quota: true)
            let success = event(at: 2, succeeded: true)
            for event in failureFirst ? [failure, success] : [success, failure] {
                health.ingest(event)
            }
            XCTAssertEqual(health.reason, .quotaExceeded)
        }
    }

    func testCatchUpRestoresUnresolvedFailureDespiteLaterImports() {
        var health = CloudSyncHealth()
        health.ingest(event(at: 1, quota: true))
        for second in 2...100 {
            health.ingest(event(at: TimeInterval(second), kind: .importEvent, succeeded: true))
        }
        health.applyAccountStatus(.available, at: date(101))
        XCTAssertEqual(health.reason, .quotaExceeded)
    }

    func testConfirmedSignOutAndRestoredCutoffRejectOldAndInFlightEvents() {
        var health = CloudSyncHealth()
        health.ingest(event(at: 1, quota: true))
        health.applyAccountStatus(.noAccount, at: date(3))
        health.applyAccountStatus(.available, at: date(3.5))
        XCTAssertNil(health.reason)

        // The same cutoff is persisted locally by the monitor. Recreating the
        // reducer must not let later catch-up resurrect the previous account.
        var relaunched = CloudSyncHealth(ignoreEventsBefore: health.ignoreEventsBefore)
        relaunched.ingest(event(at: 1, quota: true))
        relaunched.ingest(SyncEventSummary(
            kind: .exportEvent, succeeded: false, started: date(2), ended: date(4),
            storeID: "core", error: quotaError
        ))
        XCTAssertNil(relaunched.reason)
        relaunched.ingest(event(at: 5, quota: true))
        XCTAssertEqual(relaunched.reason, .quotaExceeded)
    }

    func testSignOutResetsQuotaButRestrictedAccountPreservesIt() {
        var health = CloudSyncHealth()
        health.ingest(event(at: 1, quota: true))
        health.applyAccountStatus(.restricted, at: date(2))
        XCTAssertEqual(health.reason, .restricted)
        health.applyAccountStatus(.available, at: date(3))
        XCTAssertEqual(health.reason, .quotaExceeded)

        health.applyAccountStatus(.noAccount, at: date(4))
        health.ingest(event(at: 5, quota: true))
        XCTAssertEqual(health.reason, .noAccount)
        health.applyAccountStatus(.available, at: date(6))
        health.ingest(event(at: 1, quota: true))
        XCTAssertNil(health.reason)
    }

    func testUnfinishedOrUnattributedEventsCannotChangeHealth() {
        var health = CloudSyncHealth()
        health.ingest(SyncEventSummary(
            kind: .exportEvent, succeeded: false, started: date(1), ended: nil,
            storeID: "core", error: quotaError
        ))
        health.ingest(SyncEventSummary(
            kind: .exportEvent, succeeded: false, started: date(1), ended: date(2),
            storeID: nil, error: quotaError
        ))
        XCTAssertNil(health.reason)
    }

    func testQuotaClassificationTraversesUnderlyingAndPartialFailures() {
        let partial = NSError(domain: CKErrorDomain, code: CKError.Code.partialFailure.rawValue, userInfo: [
            CKPartialErrorsByItemIDKey: ["opaque-item": quotaError]
        ])
        let wrapper = NSError(domain: NSCocoaErrorDomain, code: 134400, userInfo: [
            NSUnderlyingErrorKey: partial
        ])
        let summary = SyncEventSummary(
            kind: .exportEvent, succeeded: false, started: date(1), ended: date(2),
            storeID: "core", error: wrapper
        )
        XCTAssertTrue(summary.isQuotaExceeded)
        XCTAssertEqual(summary.redactedLine, "export FAIL err=NSCocoaErrorDomain#134400")
        XCTAssertFalse(summary.redactedLine.contains("opaque-item"))

        let multiple = NSError(domain: NSCocoaErrorDomain, code: 134400, userInfo: [
            NSMultipleUnderlyingErrorsKey: [wrapper]
        ])
        XCTAssertTrue(SyncEventSummary(
            kind: .exportEvent, succeeded: false, started: date(1), ended: date(2),
            storeID: "core", error: multiple
        ).isQuotaExceeded)
    }

    func testQuotaClassificationRejectsUnrelatedErrorWithSameNumericCode() {
        let other = NSError(domain: "OtherDomain", code: CKError.Code.quotaExceeded.rawValue)
        XCTAssertFalse(SyncEventSummary(
            kind: .exportEvent, succeeded: false, started: date(1), ended: date(2),
            storeID: "core", error: other
        ).isQuotaExceeded)
    }

    func testLocalOnlyStoreReportsUnavailableHistoryRatherThanEmptySuccess() async {
        let store = ConversationStore(inMemory: true)
        let summaries = await store.recentSyncEventSummaries()
        XCTAssertNil(summaries)
        await store._removeIsolatedVaultDirectoryForTesting()
    }

    private var quotaError: NSError {
        NSError(domain: CKErrorDomain, code: CKError.Code.quotaExceeded.rawValue)
    }

    private func date(_ second: TimeInterval) -> Date {
        Date(timeIntervalSince1970: second)
    }

    private func event(
        at second: TimeInterval,
        store: String = "core",
        kind: SyncEventSummary.Kind = .exportEvent,
        succeeded: Bool = false,
        quota: Bool = false
    ) -> SyncEventSummary {
        SyncEventSummary(
            kind: kind, succeeded: succeeded, started: date(second - 0.5), ended: date(second),
            storeID: store, error: quota ? quotaError : nil
        )
    }
}
