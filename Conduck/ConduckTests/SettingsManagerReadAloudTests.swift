// SPDX-License-Identifier: Apache-2.0

// Conduck
// SettingsManagerReadAloudTests.swift
//
// Coverage for the three per-surface read-aloud preference accessors:
// the iOS notification-open toggle (device-local), the macOS quick-lane
// toggle (device-local), and the Watch toggle (iPhone-hosted, KVS-couriered
// — only the App-Group leg is assertable here; the KVS write is a live
// `NSUbiquitousKeyValueStore` side effect with no injectable seam).
//
// Test isolation: drives the live `SettingsManager.shared` actor (a `static
// let` singleton — can't construct a fresh instance per test), so every test
// wipes the three keys in the same App Groups UserDefaults the actor uses,
// in setUp + tearDown (the `SessionContinuationPolicyTests` pattern). Pure
// UserDefaults round-trips; no Keychain → no signed-build skip-guards.

import XCTest
@testable import Conduck

final class SettingsManagerReadAloudTests: XCTestCase {

    /// App Groups UserDefaults — same suite the actor uses internally.
    private let defaults = TestStores.defaults

    override func setUp() async throws {
        try await super.setUp()
        wipeReadAloudKeys()
    }

    override func tearDown() async throws {
        wipeReadAloudKeys()
        try await super.tearDown()
    }

    private func wipeReadAloudKeys() {
        defaults.removeObject(forKey: Constants.speakReplyOnNotificationOpenKey)
        defaults.removeObject(forKey: Constants.speakQuickLaneRepliesKey)
        defaults.removeObject(forKey: Constants.watchReadRepliesAloudKey)
    }

    // MARK: - Defaults (never-written keys must read OFF)

    func testAllThreeDefaultToFalseWhenUnset() async {
        let settings = SettingsManager.shared
        let notificationOpen = await settings.getSpeakReplyOnNotificationOpen()
        let quickLane = await settings.getSpeakQuickLaneReplies()
        let watch = await settings.getWatchReadRepliesAloud()
        XCTAssertFalse(notificationOpen,
                       "Unset notification-open toggle must read OFF — surprise audio is the worst failure.")
        XCTAssertFalse(quickLane, "Unset quick-lane toggle must read OFF.")
        XCTAssertFalse(watch, "Unset Watch toggle must read OFF.")
    }

    func testStaticTapReadDefaultsToFalseWhenUnset() {
        XCTAssertFalse(SettingsManager.speakReplyOnNotificationOpenAtTap(),
                       "The synchronous notification-tap read must default OFF like the actor read.")
    }

    // MARK: - Round-trips

    func testSpeakReplyOnNotificationOpenRoundTrip() async {
        let settings = SettingsManager.shared
        await settings.setSpeakReplyOnNotificationOpen(true)
        let on = await settings.getSpeakReplyOnNotificationOpen()
        XCTAssertTrue(on)
        await settings.setSpeakReplyOnNotificationOpen(false)
        let off = await settings.getSpeakReplyOnNotificationOpen()
        XCTAssertFalse(off, "An explicit false must persist (not read as 'unset → default').")
    }

    func testSpeakQuickLaneRepliesRoundTrip() async {
        let settings = SettingsManager.shared
        await settings.setSpeakQuickLaneReplies(true)
        let on = await settings.getSpeakQuickLaneReplies()
        XCTAssertTrue(on)
        await settings.setSpeakQuickLaneReplies(false)
        let off = await settings.getSpeakQuickLaneReplies()
        XCTAssertFalse(off)
    }

    func testWatchReadRepliesAloudRoundTripAppGroupLeg() async {
        let settings = SettingsManager.shared
        await settings.setWatchReadRepliesAloud(true)
        let on = await settings.getWatchReadRepliesAloud()
        XCTAssertTrue(on)
        XCTAssertEqual(defaults.object(forKey: Constants.watchReadRepliesAloudKey) as? Bool, true,
                       "The setter's App-Group leg is the durable local read — must be written.")
        await settings.setWatchReadRepliesAloud(false)
        let off = await settings.getWatchReadRepliesAloud()
        XCTAssertFalse(off)
    }

    // MARK: - Static tap-read matches the actor read

    func testStaticTapReadMatchesActorRead() async {
        let settings = SettingsManager.shared
        await settings.setSpeakReplyOnNotificationOpen(true)
        let actorValue = await settings.getSpeakReplyOnNotificationOpen()
        XCTAssertEqual(SettingsManager.speakReplyOnNotificationOpenAtTap(), actorValue,
                       "The nonisolated tap-path read and the actor read share one key + suite — they must agree.")
    }

    // MARK: - Device-local scope (the two local toggles never share a key)

    func testTogglesAreIndependent() async {
        let settings = SettingsManager.shared
        await settings.setSpeakQuickLaneReplies(true)
        let notificationOpen = await settings.getSpeakReplyOnNotificationOpen()
        let watch = await settings.getWatchReadRepliesAloud()
        XCTAssertFalse(notificationOpen, "Setting the macOS toggle must not flip the iOS toggle.")
        XCTAssertFalse(watch, "Setting the macOS toggle must not flip the Watch toggle.")
    }
}
