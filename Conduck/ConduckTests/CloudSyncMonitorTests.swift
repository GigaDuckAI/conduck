import CloudKit
import XCTest
@testable import Conduck

/// Locks the `CloudSyncMonitor` account-status classification — the single
/// behavior that decides whether the user sees the (rare) "iCloud unavailable"
/// surface. The rest of the monitor is CloudKit-stack-bound (inert on the
/// simulator/test seam), so the pure mapping is what's worth a regression net.
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
}

extension CloudSyncMonitor.Reason: Equatable {
    public static func == (lhs: CloudSyncMonitor.Reason, rhs: CloudSyncMonitor.Reason) -> Bool {
        switch (lhs, rhs) {
        case (.noAccount, .noAccount), (.restricted, .restricted), (.quotaExceeded, .quotaExceeded):
            return true
        default:
            return false
        }
    }
}
