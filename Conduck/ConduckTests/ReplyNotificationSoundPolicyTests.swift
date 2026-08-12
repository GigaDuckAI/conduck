// SPDX-License-Identifier: Apache-2.0

// Conduck
// ReplyNotificationSoundPolicyTests.swift
//
// One chime per BURST, not one per reply.
//
// The case that matters is the one a process-local timestamp cannot survive: on
// iOS the background URLSession event relaunches the process once per landing
// turn, so three agents answering within seconds run `consumeChime` in three
// different processes. These tests drive that shape by constructing a FRESH
// policy read against the SAME defaults, which is exactly what a relaunch does.
//
// Every case uses its own `InMemoryDefaultsStore` — nothing touches the
// process-wide App Group.

import XCTest
@testable import Conduck

@MainActor
final class ReplyNotificationSoundPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let window = ReplyNotificationSoundPolicy.burstWindow

    // MARK: - Pure predicate

    func testFirstReplyChimes() {
        XCTAssertTrue(ReplyNotificationSoundPolicy.shouldChime(now: now, lastChimeAt: nil))
    }

    func testASecondReplyInsideTheWindowIsSilent() {
        XCTAssertFalse(
            ReplyNotificationSoundPolicy.shouldChime(
                now: now.addingTimeInterval(window - 1),
                lastChimeAt: now
            )
        )
    }

    func testTheWindowBoundaryChimes() {
        XCTAssertTrue(
            ReplyNotificationSoundPolicy.shouldChime(
                now: now.addingTimeInterval(window),
                lastChimeAt: now
            )
        )
    }

    func testAStampInTheFutureCountsAsExpired() {
        // The device clock moved backwards between the write and this read.
        // Silence for however far it jumped is the worse failure.
        XCTAssertTrue(
            ReplyNotificationSoundPolicy.shouldChime(
                now: now,
                lastChimeAt: now.addingTimeInterval(3_600)
            )
        )
    }

    // MARK: - Consuming the window

    func testABurstOfThreeRepliesChimesOnce() {
        let defaults = InMemoryDefaultsStore()
        XCTAssertTrue(ReplyNotificationSoundPolicy.consumeChime(now: now, defaults: defaults))
        XCTAssertFalse(
            ReplyNotificationSoundPolicy.consumeChime(now: now.addingTimeInterval(2), defaults: defaults)
        )
        XCTAssertFalse(
            ReplyNotificationSoundPolicy.consumeChime(now: now.addingTimeInterval(9), defaults: defaults)
        )
    }

    func testTheWindowSurvivesAProcessRelaunch() {
        // The whole reason this lives in App-Group defaults rather than a
        // static: the second reply runs in a process the background URLSession
        // event started, with no memory of the first.
        let defaults = InMemoryDefaultsStore()
        XCTAssertTrue(ReplyNotificationSoundPolicy.consumeChime(now: now, defaults: defaults))

        let relaunchedDefaults = InMemoryDefaultsStore(seed: defaults.dictionaryRepresentation())
        XCTAssertFalse(
            ReplyNotificationSoundPolicy.consumeChime(
                now: now.addingTimeInterval(5),
                defaults: relaunchedDefaults
            )
        )
    }

    func testASilentReplyDoesNotExtendTheWindow() {
        // The window measures time since the last AUDIBLE chime. If a silenced
        // reply re-stamped it, a steady trickle of replies would never chime
        // again.
        let defaults = InMemoryDefaultsStore()
        XCTAssertTrue(ReplyNotificationSoundPolicy.consumeChime(now: now, defaults: defaults))
        XCTAssertFalse(
            ReplyNotificationSoundPolicy.consumeChime(now: now.addingTimeInterval(window - 1), defaults: defaults)
        )
        XCTAssertTrue(
            ReplyNotificationSoundPolicy.consumeChime(now: now.addingTimeInterval(window), defaults: defaults)
        )
    }

    func testTwoUnrelatedRepliesBothChime() {
        let defaults = InMemoryDefaultsStore()
        XCTAssertTrue(ReplyNotificationSoundPolicy.consumeChime(now: now, defaults: defaults))
        XCTAssertTrue(
            ReplyNotificationSoundPolicy.consumeChime(now: now.addingTimeInterval(600), defaults: defaults)
        )
    }

    func testStorageUsesTheAppGroupKeyAndNothingElse() {
        let defaults = InMemoryDefaultsStore()
        XCTAssertTrue(ReplyNotificationSoundPolicy.consumeChime(now: now, defaults: defaults))
        XCTAssertEqual(
            defaults.double(forKey: Constants.lastReplyChimeAtKey),
            now.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(defaults.dictionaryRepresentation().count, 1)
    }

    // MARK: - Only an AUDIBLE reply may spend the window

    /// The whole point of the audibility gate. `willPresent` strips `.sound`
    /// from every foreground banner, so a reply that lands while the app is
    /// frontmost makes no sound — and if it consumed the window anyway, the
    /// reply that lands ten seconds later, after the user locked the phone,
    /// would arrive silent too. "One chime per burst" would become zero.
    func testAForegroundReplyDoesNotSpendTheWindow() {
        let defaults = InMemoryDefaultsStore()
        XCTAssertFalse(
            ReplyNotificationSoundPolicy.consumeChimeIfAudible(
                appIsFrontmost: true, now: now, defaults: defaults
            ),
            "A frontmost app cannot chime — the delegate strips the sound."
        )
        XCTAssertEqual(
            defaults.dictionaryRepresentation().count, 0,
            "Nothing was heard, so nothing may be stamped."
        )
        XCTAssertTrue(
            ReplyNotificationSoundPolicy.consumeChimeIfAudible(
                appIsFrontmost: false, now: now.addingTimeInterval(10), defaults: defaults
            ),
            "The next reply, delivered with the app backgrounded, still chimes."
        )
    }

    func testABackgroundReplyStillSpendsTheWindowExactlyOnce() {
        let defaults = InMemoryDefaultsStore()
        XCTAssertTrue(
            ReplyNotificationSoundPolicy.consumeChimeIfAudible(
                appIsFrontmost: false, now: now, defaults: defaults
            )
        )
        XCTAssertFalse(
            ReplyNotificationSoundPolicy.consumeChimeIfAudible(
                appIsFrontmost: false, now: now.addingTimeInterval(1), defaults: defaults
            )
        )
    }

    func testResetClearsTheWindow() {
        let defaults = InMemoryDefaultsStore()
        XCTAssertTrue(ReplyNotificationSoundPolicy.consumeChime(now: now, defaults: defaults))
        ReplyNotificationSoundPolicy._resetForTesting(defaults: defaults)
        XCTAssertTrue(
            ReplyNotificationSoundPolicy.consumeChime(now: now.addingTimeInterval(1), defaults: defaults)
        )
    }
}
