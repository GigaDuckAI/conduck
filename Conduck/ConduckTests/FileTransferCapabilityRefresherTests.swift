//
//  FileTransferCapabilityRefresherTests.swift
//  ConduckTests
//
//  Locks the PURE decision half of the silent, upgrade-only folder-capability
//  refresh — `FileTransferCapabilityRefresher.isProbeDue(...)`. The sweep body
//  (`refreshIfNeeded` / `sweep`) is singleton- and network-bound (SettingsManager
//  actor + a real cert-pinned probe session), guarded out of the test host, and
//  covered by the founder's on-device QA; the gating logic that decides WHETHER
//  a lane is re-probed is the part worth a regression lock.
//
//  Contract under test (UPGRADE-ONLY): a probe is due iff the lane is stuck flat
//  (`folderCapable == false`), was tested on THIS device (`testedLocally`), has
//  no DEFINITIVE outcome recorded at the current algorithm revision, and is out
//  of its per-lane backoff window.
//
//  Deterministic + headless: no network, no Core Data, no Keychain, no actor
//  hop — `isProbeDue` is pure. No real filenames / URLs / keys involved.
//

import XCTest
@testable import Conduck

final class FileTransferCapabilityRefresherTests: XCTestCase {

    // A fixed reference instant so backoff arithmetic is deterministic.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let backoff: TimeInterval = 24 * 60 * 60
    private let currentRevision = 1

    /// The baseline DUE case — every field set so a probe should fire. Each test
    /// flips exactly one input to assert its individual gate.
    private func due(
        folderCapable: Bool = false,
        testedLocally: Bool = true,
        recordedRevision: Int? = nil,
        lastAttempt: Date? = nil
    ) -> Bool {
        FileTransferCapabilityRefresher.isProbeDue(
            folderCapable: folderCapable,
            testedLocally: testedLocally,
            recordedRevision: recordedRevision,
            currentRevision: currentRevision,
            lastAttempt: lastAttempt,
            backoff: backoff,
            now: now
        )
    }

    /// Baseline: stuck-flat, locally tested, never probed, no prior attempt → due.
    func testBaselineStuckFlatLocallyTested_isDue() {
        XCTAssertTrue(due())
    }

    /// `folderCapable == true` is the ceiling — nothing to upgrade, never degrade.
    func testAlreadyFolderCapable_notDue() {
        XCTAssertFalse(due(folderCapable: true))
    }

    /// A synced-only peer that never tested here must not fire automated writes.
    func testNotTestedLocally_notDue() {
        XCTAssertFalse(due(testedLocally: false))
    }

    /// A DEFINITIVE outcome already recorded at the current revision parks the
    /// probe until the algorithm revision bumps.
    func testDefinitiveOutcomeAtCurrentRevision_notDue() {
        XCTAssertFalse(due(recordedRevision: currentRevision))
    }

    /// A recent attempt (1h ago, 24h backoff) is inside the window → not due.
    func testAttemptWithinBackoffWindow_notDue() {
        let oneHourAgo = now.addingTimeInterval(-60 * 60)
        XCTAssertFalse(due(lastAttempt: oneHourAgo))
    }

    /// An attempt older than the backoff (25h ago, 24h backoff) re-opens the
    /// window → due.
    func testAttemptOlderThanBackoff_isDue() {
        let twentyFiveHoursAgo = now.addingTimeInterval(-25 * 60 * 60)
        XCTAssertTrue(due(lastAttempt: twentyFiveHoursAgo))
    }

    /// A definitive outcome recorded at an OLD revision (0) is re-armed once the
    /// algorithm revision bumps to 1 — the whole point of the revision gate.
    func testDefinitiveOutcomeAtOldRevision_isDue() {
        XCTAssertTrue(due(recordedRevision: 0))
    }

    /// Exactly at the backoff boundary (>= backoff) the window is open → due
    /// (the guard rejects only `< backoff`).
    func testAttemptExactlyAtBackoffBoundary_isDue() {
        let exactlyBackoffAgo = now.addingTimeInterval(-backoff)
        XCTAssertTrue(due(lastAttempt: exactlyBackoffAgo))
    }
}
