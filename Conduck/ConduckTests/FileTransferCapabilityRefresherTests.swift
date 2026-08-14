// SPDX-License-Identifier: Apache-2.0

//
//  FileTransferCapabilityRefresherTests.swift
//  ConduckTests
//
//  Locks the PURE decision halves of the silent, upgrade-only capability refresh
//  — `FileTransferCapabilityRefresher.isProbeDue(...)` (nested PUT) and
//  `isReturnProbeDue(...)` (`PROPFIND`). The sweep body (`refreshIfNeeded` /
//  `sweep`) is singleton- and network-bound (SettingsManager actor + a real
//  cert-pinned probe session), guarded out of the test host, and covered by the
//  founder's on-device QA; the gating logic that decides WHETHER a lane is
//  re-probed is the part worth a regression lock.
//
//  Folder contract (UPGRADE-ONLY): a probe is due iff the lane is stuck flat
//  (`folderCapable == false`), was tested on THIS device (`testedLocally`), has
//  no DEFINITIVE outcome recorded at the current algorithm revision, and is out
//  of its per-lane backoff window.
//
//  Return contract (UPGRADE-ONLY): a probe is due iff the lane is stuck
//  upload-only (`returnCapable == false`) and was tested on THIS device. NO
//  revision and NO time window, and both absences are load-bearing rather than
//  oversights — see the tests at the foot of this file.
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

    // MARK: - The RETURN re-probe (the self-heal for a repaired file server)
    //
    // `BackgroundFileTransfer.mintOutboxKey` gates on the stored `returnCapable`
    // verdict so the plain-`nginx` population stops paying a `PROPFIND` on the
    // critical path of every turn. A gate that only ever narrows would leave a
    // user who ENABLES `PROPFIND` on their server without file return until they
    // thought to re-run a Test Connection, which is the defect these lock.

    private func returnDue(returnCapable: Bool = false, testedLocally: Bool = true) -> Bool {
        FileTransferCapabilityRefresher.isReturnProbeDue(
            returnCapable: returnCapable, testedLocally: testedLocally)
    }

    /// Baseline: a lane the staged test stamped upload-only, on the device that
    /// stamped it → re-ask.
    func testUploadOnlyLaneTestedHere_isDue() {
        XCTAssertTrue(returnDue())
    }

    /// `returnCapable == true` is the ceiling. This refresh never narrows — only
    /// a structural refusal at the staged test, against a collection that
    /// certainly exists, may do that.
    func testAlreadyReturnCapable_notDue() {
        XCTAssertFalse(returnDue(returnCapable: true))
    }

    /// A device that received the verdict over iCloud has never seen the server.
    /// Same arming rule the folder probe uses, and for the stronger of its two
    /// reasons: no unexplained request at a host this device never met.
    func testReturnProbeNotTestedLocally_notDue() {
        XCTAssertFalse(returnDue(testedLocally: false))
    }

    /// NO REVISION GATE, and that is the difference from the folder probe rather
    /// than an omission. A stale folder verdict is a bug the app shipped, so it is
    /// re-asked once per algorithm revision; a stale return verdict is a change
    /// the USER makes to their own server on some unpredictable day, so parking it
    /// against anything the app versions would re-create the defect.
    ///
    /// Expressed as a shape assertion: the decision reads two bools and nothing
    /// else, so no repeated call can ever park it.
    func testReturnProbeIsNotParkedByRepetition() {
        for _ in 0..<10 {
            XCTAssertTrue(returnDue(), "The decision must stay due; only the caller's per-process claim bounds it.")
        }
    }

    /// NO TIME WINDOW either. The probe reads two statuses and writes nothing to
    /// the user's server, so once per launch is the whole bound it needs — a 24 h
    /// floor like the folder probe's would leave a user who just repaired their
    /// server waiting a day for the app to notice.
    func testReturnProbeHasNoBackoffParameterToSuppressIt() {
        // A pure two-input decision cannot carry a clock. If someone adds one,
        // this call site stops compiling and the reasoning above gets re-read.
        let decision: (Bool, Bool) -> Bool = FileTransferCapabilityRefresher.isReturnProbeDue
        XCTAssertTrue(decision(false, true))
        XCTAssertFalse(decision(true, true))
    }
}
