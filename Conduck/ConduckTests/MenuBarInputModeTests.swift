// SPDX-License-Identifier: Apache-2.0

// Conduck
// MenuBarInputModeTests.swift
//
// Coverage for the macOS menu-bar input-mode preference: the pure-enum
// default + CaseIterable + Codable contract, and the `SettingsManager`
// round-trip — App Groups ONLY (device-local: the setter must NOT dual-write
// iCloud KVS, unlike `OnLaunchMode`) + notification fan-out + the static
// synchronous read (`menuBarInputModeAtLaunch`) agreeing with the actor read.
//
// Test isolation mirrors `OnLaunchModeTests`: the live `SettingsManager.shared`
// singleton's App Groups slot is wiped in setUp + tearDown. Pure-logic +
// UserDefaults round-trip — no Keychain, no signing.

import XCTest
@testable import Conduck

final class MenuBarInputModeTests: XCTestCase {

    private let defaults: UserDefaults = {
        UserDefaults(suiteName: Constants.appGroupID) ?? UserDefaults.standard
    }()

    override func setUp() async throws {
        try await super.setUp()
        defaults.removeObject(forKey: Constants.menuBarInputModeKey)
    }

    override func tearDown() async throws {
        defaults.removeObject(forKey: Constants.menuBarInputModeKey)
        try await super.tearDown()
    }

    // MARK: - Enum: default + CaseIterable + forward-compat fallback

    func testDefaultIsVoice() {
        XCTAssertEqual(MenuBarInputMode.default, .voice,
                       "Fresh installs must keep today's voice-first popover behavior.")
    }

    func testCaseIterableCoversBoth() {
        XCTAssertEqual(MenuBarInputMode.allCases, [.voice, .text])
    }

    func testRawValuesAreLocked() {
        // Raw strings are persisted — a rename would silently revert every
        // text-mode machine to voice.
        XCTAssertEqual(MenuBarInputMode.voice.rawValue, "voice")
        XCTAssertEqual(MenuBarInputMode.text.rawValue, "text")
    }

    func testUnknownRawValueDoesNotDecode() {
        XCTAssertNil(MenuBarInputMode(rawValue: "telepathy"),
                     "Unknown raw value must not decode — the getter then returns `.default`.")
    }

    func testCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for mode in MenuBarInputMode.allCases {
            let data = try encoder.encode(mode)
            let decoded = try decoder.decode(MenuBarInputMode.self, from: data)
            XCTAssertEqual(decoded, mode)
        }
    }

    // MARK: - SettingsManager round-trip (App Groups, device-local)

    func testGetterReturnsDefaultWhenUnset() async {
        let resolved = await SettingsManager.shared.getMenuBarInputMode()
        XCTAssertEqual(resolved, .default)
    }

    func testGetterReturnsDefaultForPoisonedRawValue() async {
        defaults.set("not-a-real-mode", forKey: Constants.menuBarInputModeKey)
        let resolved = await SettingsManager.shared.getMenuBarInputMode()
        XCTAssertEqual(resolved, .default,
                       "An unknown stored raw value must fall back to `.default` (forward-compat).")
    }

    func testRoundTripPersistsToAppGroups() async {
        await SettingsManager.shared.setMenuBarInputMode(.text)
        let resolved = await SettingsManager.shared.getMenuBarInputMode()
        XCTAssertEqual(resolved, .text)
        XCTAssertEqual(defaults.string(forKey: Constants.menuBarInputModeKey),
                       MenuBarInputMode.text.rawValue)
    }

    func testSetterDoesNotWriteICloudKVS() async {
        // DEVICE-LOCAL contract: the choice must never ride iCloud to another
        // machine (an office Mac and a laptop are legitimately different modes).
        NSUbiquitousKeyValueStore.default.removeObject(forKey: Constants.menuBarInputModeKey)
        await SettingsManager.shared.setMenuBarInputMode(.text)
        XCTAssertNil(NSUbiquitousKeyValueStore.default.string(forKey: Constants.menuBarInputModeKey),
                     "Setter must be App-Groups-only — no iCloud KVS write.")
    }

    func testSynchronousLaunchReadAgreesWithActorRead() async {
        XCTAssertEqual(SettingsManager.menuBarInputModeAtLaunch(), .default,
                       "Unset → default, matching the actor getter.")
        await SettingsManager.shared.setMenuBarInputMode(.text)
        let actorRead = await SettingsManager.shared.getMenuBarInputMode()
        XCTAssertEqual(SettingsManager.menuBarInputModeAtLaunch(), actorRead,
                       "The press-time sync read and the actor read must never disagree.")
    }

    func testSetModePostsNotification() async {
        let expectation = XCTNSNotificationExpectation(name: .settingsDidChangeRemotely)
        await SettingsManager.shared.setMenuBarInputMode(.text)
        await fulfillment(of: [expectation], timeout: 1.0)
    }
}
