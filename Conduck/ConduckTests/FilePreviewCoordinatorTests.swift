// SPDX-License-Identifier: Apache-2.0

//
//  FilePreviewCoordinatorTests.swift
//  ConduckTests
//
//  Locks the Quick Look presenter shared by the chat thread and the Work desk:
//    • the monotonic claim — latest tap wins, so a slower load that finishes
//      after a newer tap never steals the panel, and reclaims its own bytes
//      instead of leaking them.
//    • the per-platform lifetime rule, exercised in BOTH directions on one
//      platform via `FilePreviewReclaimPolicy`: `.onDismiss` (iOS) releases the
//      bytes when the preview closes, `.onAgeSweep` (macOS) leaves them alone
//      because "Open with" hands another app the live path.
//    • `cancelPendingPresentation` — invalidates the visible preview AND every
//      in-flight claim, so a hidden surface can never reopen Quick Look.
//
//  Pure logic: no Quick Look UI, no file system. `PreviewedFile.reclaim` is a
//  counting closure, which is exactly the seam the real lanes plug into.
//

import XCTest
@testable import Conduck

@MainActor
final class FilePreviewCoordinatorTests: XCTestCase {

    /// Counts reclaims per file — the observable half of the lifetime rule.
    private final class ReclaimLedger {
        private(set) var counts: [URL: Int] = [:]
        func count(for url: URL) -> Int { counts[url] ?? 0 }
        func record(_ url: URL) { counts[url, default: 0] += 1 }
    }

    private var ledger = ReclaimLedger()

    override func setUp() {
        super.setUp()
        ledger = ReclaimLedger()
    }

    private func makeFile(_ name: String) -> PreviewedFile {
        let url = URL(fileURLWithPath: "/tmp/conduck-preview-tests/\(name)")
        let ledger = ledger
        return PreviewedFile(url: url, reclaim: { ledger.record(url) })
    }

    // MARK: - Claim token

    func testAPresentCarryingASupersededClaimIsIgnoredAndReclaimsItsOwnFile() {
        let coordinator = FilePreviewCoordinator(reclaimPolicy: .onDismiss)
        let stale = coordinator.beginRequest()
        _ = coordinator.beginRequest()

        let file = makeFile("stale.txt")
        coordinator.present(file, token: stale)

        XCTAssertNil(coordinator.previewURL, "A superseded claim must never open the panel.")
        XCTAssertEqual(ledger.count(for: file.url), 1, "The unshown file must be reclaimed, not leaked.")
    }

    func testTheLatestTapWinsWhenLoadsFinishOutOfOrder() {
        let coordinator = FilePreviewCoordinator(reclaimPolicy: .onDismiss)
        let first = coordinator.beginRequest()
        let second = coordinator.beginRequest()

        let newer = makeFile("newer.txt")
        coordinator.present(newer, token: second)
        let older = makeFile("older.txt")
        coordinator.present(older, token: first)

        XCTAssertEqual(coordinator.previewURL, newer.url, "The later tap owns the panel.")
        XCTAssertEqual(ledger.count(for: older.url), 1)
        XCTAssertEqual(ledger.count(for: newer.url), 0, "The visible file stays alive.")
    }

    func testIsCurrentTracksOnlyTheNewestClaim() {
        let coordinator = FilePreviewCoordinator(reclaimPolicy: .onDismiss)
        let first = coordinator.beginRequest()
        XCTAssertTrue(coordinator.isCurrent(first))
        let second = coordinator.beginRequest()
        XCTAssertFalse(coordinator.isCurrent(first))
        XCTAssertTrue(coordinator.isCurrent(second))
    }

    // MARK: - Dismissal lifetime rule

    func testDismissalReclaimsTheFileUnderTheOnDismissPolicy() {
        let coordinator = FilePreviewCoordinator(reclaimPolicy: .onDismiss)
        let file = makeFile("ios.txt")
        coordinator.present(file, token: coordinator.beginRequest())

        coordinator.handleDismiss()

        XCTAssertEqual(ledger.count(for: file.url), 1)
    }

    func testDismissalLeavesTheFileUnderTheOnAgeSweepPolicy() {
        let coordinator = FilePreviewCoordinator(reclaimPolicy: .onAgeSweep)
        let file = makeFile("mac.txt")
        coordinator.present(file, token: coordinator.beginRequest())

        coordinator.handleDismiss()

        XCTAssertEqual(
            ledger.count(for: file.url), 0,
            "\"Open with\" holds the live path — deleting on dismissal would yank it.")
    }

    func testASecondDismissalNeverReclaimsTheSameFileTwice() {
        let coordinator = FilePreviewCoordinator(reclaimPolicy: .onDismiss)
        let file = makeFile("twice.txt")
        coordinator.present(file, token: coordinator.beginRequest())

        coordinator.handleDismiss()
        coordinator.handleDismiss()

        XCTAssertEqual(ledger.count(for: file.url), 1)
    }

    // MARK: - Replacing an on-screen preview

    func testReplacingAVisiblePreviewReclaimsTheOldFileUnderTheOnDismissPolicy() {
        let coordinator = FilePreviewCoordinator(reclaimPolicy: .onDismiss)
        let old = makeFile("old.txt")
        coordinator.present(old, token: coordinator.beginRequest())
        let new = makeFile("new.txt")
        coordinator.present(new, token: coordinator.beginRequest())

        XCTAssertEqual(coordinator.previewURL, new.url)
        XCTAssertEqual(ledger.count(for: old.url), 1)
        XCTAssertEqual(ledger.count(for: new.url), 0)
    }

    func testReplacingAVisiblePreviewLeavesTheOldFileUnderTheOnAgeSweepPolicy() {
        let coordinator = FilePreviewCoordinator(reclaimPolicy: .onAgeSweep)
        let old = makeFile("old.txt")
        coordinator.present(old, token: coordinator.beginRequest())
        let new = makeFile("new.txt")
        coordinator.present(new, token: coordinator.beginRequest())

        XCTAssertEqual(coordinator.previewURL, new.url)
        XCTAssertEqual(ledger.count(for: old.url), 0)
    }

    // MARK: - Cancellation

    func testCancellationClosesTheVisiblePreviewAndInvalidatesInFlightClaims() {
        let coordinator = FilePreviewCoordinator(reclaimPolicy: .onDismiss)
        let visible = makeFile("visible.txt")
        coordinator.present(visible, token: coordinator.beginRequest())
        let inFlight = coordinator.beginRequest()

        coordinator.cancelPendingPresentation()

        XCTAssertNil(coordinator.previewURL)
        XCTAssertEqual(ledger.count(for: visible.url), 1)
        XCTAssertFalse(coordinator.isCurrent(inFlight), "A hidden surface must not reopen Quick Look.")

        let late = makeFile("late.txt")
        coordinator.present(late, token: inFlight)
        XCTAssertNil(coordinator.previewURL)
        XCTAssertEqual(ledger.count(for: late.url), 1, "A cancelled load still reclaims its bytes.")
    }

    func testCancellationUnderTheOnAgeSweepPolicyLeavesTheVisibleFileAlone() {
        let coordinator = FilePreviewCoordinator(reclaimPolicy: .onAgeSweep)
        let visible = makeFile("visible.txt")
        coordinator.present(visible, token: coordinator.beginRequest())

        coordinator.cancelPendingPresentation()

        XCTAssertNil(coordinator.previewURL)
        XCTAssertEqual(ledger.count(for: visible.url), 0)
    }

    // MARK: - Platform default

    func testThePlatformDefaultMatchesThisPlatformsLifetimeRule() {
        #if os(macOS)
        XCTAssertEqual(FilePreviewReclaimPolicy.platformDefault, .onAgeSweep)
        #else
        XCTAssertEqual(FilePreviewReclaimPolicy.platformDefault, .onDismiss)
        #endif
    }
}
