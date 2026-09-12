// SPDX-License-Identifier: Apache-2.0

// Content-sync presentation boundaries: unavailable bytes must not promise an
// automatic arrival while OFF, deletion still discloses the account-wide usage
// cutoff, and a failed runtime transition never presents as healthy local mode.

import XCTest
@testable import Conduck

@MainActor
final class ContentSyncPresentationTests: XCTestCase {
    func testMissingCardWhileOffExplainsLocalAbsenceWithoutPromisingArrival() throws {
        let label = try XCTUnwrap(WorkboardCardFacePolicy.availabilityLabel(
            for: .syncPending, contentSyncEnabled: false
        ))
        let summary = String(localized: label)
        XCTAssertTrue(summary.contains("content sync is off"))
        XCTAssertFalse(summary.contains("Waiting"))
        XCTAssertEqual(
            WorkboardCardFacePolicy.availabilityGlyphName(for: .syncPending, contentSyncEnabled: false),
            "icloud.slash"
        )

        // The projection's derived availability line must never become a
        // user-authored caption when the board refreshes after toggling OFF.
        XCTAssertEqual(
            WorkboardCardFacePolicy.caption(from: "My notes • " + summary, byteCount: nil),
            "My notes"
        )
        for sharing in [false, true] {
            let explanation = String(localized: ContentSyncPresentationPolicy.missingFileExplanation(
                enabled: false, sharing: sharing
            ))
            XCTAssertTrue(explanation.contains("Settings → General"))
            XCTAssertFalse(explanation.contains("still arriving"))
            XCTAssertFalse(explanation.contains("once it lands"))
        }
    }

    func testLocalDeleteAllDisclosesDelayedConversationDeletesAndImmediateUsageScope() {
        let message = String(localized: ContentSyncPresentationPolicy.deleteAllConversations(enabled: false))
        XCTAssertTrue(message.contains("from this device"))
        XCTAssertTrue(message.contains("deletions can sync while turning off is still in progress"))
        XCTAssertTrue(message.contains("turn content sync back on"))
        XCTAssertTrue(message.contains("Usage history is cleared across all your devices"))
        XCTAssertTrue(message.contains("Work desk stays untouched"))
    }

    func testReenableConfirmationIncludesOtherDevicesAndOfflineDeletions() {
        let message = String(localized: ContentSyncPresentationPolicy.confirmation(enabling: true))
        XCTAssertTrue(message.contains("any of your devices"))
        XCTAssertTrue(message.contains("current iCloud account"))
        XCTAssertTrue(message.contains("edits and deletions"))
    }

    func testDiagnosticsDistinguishesEffectiveOffFromApplyingAndFailed() {
        let off = DiagnosticsRunner.contentSyncRowState(state: .off, message: nil)
        XCTAssertFalse(off.status.needsAttention)
        XCTAssertTrue(off.detail.contains("off on this device"))
        XCTAssertEqual(DiagnosticsRunner.contentSyncRowState(state: .applying, message: nil).status, .running)
        let failure = DiagnosticsRunner.contentSyncRowState(state: .failed, message: nil)
        XCTAssertTrue(failure.status.needsAttention)
        XCTAssertFalse(failure.detail.contains("off on this device"))
    }

    func testPolicyContentionKeepsLastGoodCopyAndRecoveryRefreshesIt() throws {
        let base = SettingsDependencies.inMemory()
        let gate = PolicyGate()
        let dependencies = SettingsDependencies(defaults: base.defaults, ubiquitous: base.ubiquitous,
            secrets: base.secrets, cloudAvailability: base.cloudAvailability, changes: base.changes,
            contentSyncPolicyLock: gate)
        let preferences = ContentSyncPreferenceStore(dependencies: dependencies)
        let notifications = NotificationCenter()
        let snapshot = ContentSyncPresentationSnapshot(preferences: preferences, notifications: notifications)
        XCTAssertTrue(snapshot.isEnabled)

        gate.setReadable(false)
        notifications.post(name: .contentSyncPreferenceDidChange, object: nil)
        XCTAssertTrue(snapshot.isEnabled, "Unreadable policy must not be cached as an explicit OFF.")

        let off = ContentSyncPreference(enabled: false, revision: 100, identifier: UUID())
        base.ubiquitous.set(try JSONEncoder().encode(off), forKey: ContentSyncPreferenceStore.storageKey)
        gate.setReadable(true)
        notifications.post(name: .contentSyncStateDidChange, object: nil)
        XCTAssertFalse(snapshot.isEnabled, "Recovery must refresh even without another preference event.")
    }

    func testNonParticipatingStoreDoesNotReportAnEndlessTransition() async {
        let store = ConversationStore(inMemory: true)
        let state = await store.currentContentSyncState()
        XCTAssertEqual(state.phase, .off)
        XCTAssertFalse(state.desiredEnabled)
        await store._removeIsolatedVaultDirectoryForTesting()
    }

    private nonisolated final class PolicyGate: ContentSyncPolicyLock, @unchecked Sendable {
        private let mutex = NSLock()
        private var readable = true
        func setReadable(_ value: Bool) { mutex.withLock { readable = value } }
        func lock() -> Bool { mutex.withLock { readable } }
        func unlock() {}
    }
}
