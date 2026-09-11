// SPDX-License-Identifier: Apache-2.0

// Conduck
// SavedRecordingRecoveryAvailabilityTests.swift
//
// Ordinary queue recovery yields to a live capture or an unsent transcript,
// including when reserving a recording temporarily reduces the waiting count.

import XCTest
@testable import Conduck

@MainActor
final class SavedRecordingRecoveryAvailabilityTests: XCTestCase {
    func testActiveWorkBlocksRecoveryEvenWhenRecordingIsTemporarilyReserved() {
        for count in [0, 1, 3] {
            XCTAssertEqual(SavedRecordingRecoveryAvailability.resolve(isBusy: true, waitingCount: count), .busy)
        }
    }

    func testSettledSurfaceOffersRecoveryOnlyForWaitingRecordings() {
        XCTAssertEqual(SavedRecordingRecoveryAvailability.resolve(isBusy: false, waitingCount: 0), .empty)
        XCTAssertEqual(SavedRecordingRecoveryAvailability.resolve(isBusy: false, waitingCount: 1), .ready)
        XCTAssertEqual(SavedRecordingRecoveryAvailability.resolve(isBusy: false, waitingCount: 3), .ready)
    }

    func testUnsentRequestMustBeResolvedBeforeAnotherRecordingCanReplaceIt() {
        XCTAssertEqual(SavedRecordingRecoveryAvailability.resolve(
            isBusy: false, waitingCount: 2, hasUnsentRequest: true
        ), .busy)
        XCTAssertEqual(SavedRecordingRecoveryAvailability.resolve(
            isBusy: false, waitingCount: 2, hasUnsentRequest: false
        ), .ready)
    }
}
