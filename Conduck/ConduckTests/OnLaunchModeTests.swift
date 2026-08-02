// SPDX-License-Identifier: Apache-2.0

// Conduck
// OnLaunchModeTests.swift
//
// Coverage for the cold-launch landing preference: the pure-enum default +
// CaseIterable + Codable contract, and the `SettingsManager` round-trip
// (App Groups + iCloud KVS dual-write + notification fan-out).
//
// Test isolation mirrors `SessionContinuationPolicyTests`: the live
// `SettingsManager.shared` singleton's App Groups slot is wiped in setUp +
// tearDown. Pure-logic + UserDefaults round-trip — no Keychain, no signing.

import XCTest
@testable import Conduck

final class OnLaunchModeTests: XCTestCase {

    private let defaults = TestStores.defaults

    override func setUp() async throws {
        try await super.setUp()
        defaults.removeObject(forKey: Constants.onLaunchModeKey)
    }

    override func tearDown() async throws {
        defaults.removeObject(forKey: Constants.onLaunchModeKey)
        try await super.tearDown()
    }

    // MARK: - Enum: default + CaseIterable + forward-compat fallback

    func testDefaultIsStartNew() {
        XCTAssertEqual(OnLaunchMode.default, .startNewConversation,
                       "Cold-launch default must be `.startNewConversation` (zero-friction landing).")
    }

    func testCaseIterableCoversBoth() {
        XCTAssertEqual(OnLaunchMode.allCases,
                       [.startNewConversation, .resumeLastConversation])
    }

    func testUnknownRawValueDoesNotDecode() {
        XCTAssertNil(OnLaunchMode(rawValue: "openWhateverWasOpen"),
                     "Unknown raw value must not decode — the getter then returns `.default`.")
    }

    func testCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for mode in OnLaunchMode.allCases {
            let data = try encoder.encode(mode)
            let decoded = try decoder.decode(OnLaunchMode.self, from: data)
            XCTAssertEqual(decoded, mode)
        }
    }

    // MARK: - SettingsManager round-trip (App Groups + KVS + notification)

    func testGetterReturnsDefaultWhenUnset() async {
        let resolved = await SettingsManager.shared.getOnLaunchMode()
        XCTAssertEqual(resolved, .default,
                       "Unset preference must resolve to `.default` (`.startNewConversation`).")
    }

    func testGetterReturnsDefaultForPoisonedRawValue() async {
        defaults.set("not-a-real-mode", forKey: Constants.onLaunchModeKey)
        let resolved = await SettingsManager.shared.getOnLaunchMode()
        XCTAssertEqual(resolved, .default,
                       "An unknown stored raw value must fall back to `.default` (forward-compat).")
    }

    func testRoundTripPersistsToAppGroups() async {
        await SettingsManager.shared.setOnLaunchMode(.resumeLastConversation)
        let resolved = await SettingsManager.shared.getOnLaunchMode()
        XCTAssertEqual(resolved, .resumeLastConversation,
                       "Preference must round-trip through App Groups.")
        XCTAssertEqual(defaults.string(forKey: Constants.onLaunchModeKey),
                       OnLaunchMode.resumeLastConversation.rawValue,
                       "Setter must dual-write the raw value into App Groups for the synchronous getter.")
    }

    func testRoundTripBothCases() async {
        await SettingsManager.shared.setOnLaunchMode(.resumeLastConversation)
        var resolved = await SettingsManager.shared.getOnLaunchMode()
        XCTAssertEqual(resolved, .resumeLastConversation)
        await SettingsManager.shared.setOnLaunchMode(.startNewConversation)
        resolved = await SettingsManager.shared.getOnLaunchMode()
        XCTAssertEqual(resolved, .startNewConversation)
    }

    func testSetModePostsNotification() async {
        let expectation = XCTNSNotificationExpectation(name: .settingsDidChangeRemotely)
        await SettingsManager.shared.setOnLaunchMode(.resumeLastConversation)
        await fulfillment(of: [expectation], timeout: 1.0)
    }
}
