// SPDX-License-Identifier: Apache-2.0

// Conduck
// FileLaneWitnessBreakerTests.swift
//
// Locks `BackgroundFileTransfer.FileLaneWitnessBreaker` — the process-local
// state that bounds what a dead file server costs the user.
//
// WHAT IS ACTUALLY AT STAKE. The pre-dispatch absence witness sits on the
// dispatch critical path and every send waits for it, a pure-text turn that was
// never going to involve a file included. Against a lane that is simply gone
// that is the full witness deadline added to every message the user sends,
// forever. In this product the commonest cause is mundane — file-server URLs are
// frequently quick tunnels whose hostname rotates on restart — so "the
// configured lane is unreachable" is the expected state, not an exotic one.
//
// THE TWO THINGS IT MUST NEVER DO, both of which have their own cases below: it
// must never switch the lane off (the lane's settings screen is the only place
// the user can repair it), and it must never suppress the FACT that a turn went
// out folder-less — only the request that would have re-established it.
//
// Deterministic + headless: the clock is injected, so nothing here sleeps and
// nothing depends on wall time.

import XCTest
@testable import Conduck

final class FileLaneWitnessBreakerTests: XCTestCase {

    private typealias Breaker = BackgroundFileTransfer.FileLaneWitnessBreaker

    private let lane = "lane-under-test"
    private let start = ContinuousClock.now

    override func setUp() {
        super.setUp()
        Breaker.shared.resetAll()
    }

    override func tearDown() {
        Breaker.shared.resetAll()
        super.tearDown()
    }

    /// An untouched lane is probed. Nothing is assumed about a server nobody has
    /// asked yet.
    func testAnUnknownLaneIsProbed() {
        XCTAssertEqual(Breaker.shared.decide(lane: lane, now: start), .probe)
        XCTAssertNil(Breaker.shared.faultedSince(lane: lane))
    }

    /// A host that produced no HTTP response at all will not produce one next
    /// turn either, so the cooldown opens on the FIRST observation. Three
    /// samples would spend roughly a dozen seconds of the user's time
    /// re-learning something already known.
    func testAnUnreachableLaneOpensTheCooldownImmediately() {
        Breaker.shared.recordFailure(lane: lane, severity: .unreachable, now: start)

        XCTAssertEqual(Breaker.shared.decide(lane: lane, now: start), .cooldown)
    }

    /// A server that ANSWERED, unhelpfully, keeps its benefit of the doubt: a
    /// `5xx` or a one-in-a-billion name collision is transient often enough that
    /// one sample is not a diagnosis.
    func testALaneThatAnsweredIsProbedTwiceMoreBeforeTheCooldownOpens() {
        Breaker.shared.recordFailure(lane: lane, severity: .answered, now: start)
        XCTAssertEqual(Breaker.shared.decide(lane: lane, now: start), .probe)

        Breaker.shared.recordFailure(lane: lane, severity: .answered, now: start)
        XCTAssertEqual(Breaker.shared.decide(lane: lane, now: start), .probe)

        Breaker.shared.recordFailure(lane: lane, severity: .answered, now: start)
        XCTAssertEqual(Breaker.shared.decide(lane: lane, now: start), .cooldown)
    }

    /// The threshold follows the LATEST evidence. A streak that starts with two
    /// unhelpful answers and then goes dark must not sit through a third probe
    /// on the strength of samples that are no longer the best information.
    func testAStreakThatTurnsUnreachableOpensAtOnce() {
        Breaker.shared.recordFailure(lane: lane, severity: .answered, now: start)
        Breaker.shared.recordFailure(lane: lane, severity: .unreachable, now: start)

        XCTAssertEqual(Breaker.shared.decide(lane: lane, now: start), .cooldown)
    }

    /// …and it opens on the FIRST RUNG when it does. The ladder counts how many
    /// cooldowns this streak has actually climbed, never the streak length
    /// measured against the threshold the newest failure stamped — those differ
    /// exactly when the severity changes mid-streak, and the difference is rungs
    /// the user waits through that nobody meant them to. Two unhelpful answers
    /// (threshold 3, no cooldown yet) then a dark host (threshold 1) used to
    /// enter its first pause already two rungs up: half an hour where five
    /// minutes was meant, on a lane that may have been repaired seconds ago.
    func testTheFirstCooldownAfterASeverityChangeLandsOnTheFirstRung() {
        Breaker.shared.recordFailure(lane: lane, severity: .answered, now: start)
        Breaker.shared.recordFailure(lane: lane, severity: .answered, now: start)
        Breaker.shared.recordFailure(lane: lane, severity: .unreachable, now: start)

        let firstRung = Breaker.backoff(pastThreshold: 1)
        XCTAssertEqual(
            Breaker.shared.decide(lane: lane, now: start.advanced(by: .seconds(firstRung - 1))),
            .cooldown)
        XCTAssertEqual(
            Breaker.shared.decide(lane: lane, now: start.advanced(by: .seconds(firstRung))),
            .probe,
            "the FIRST pause of a streak is the first rung, whatever re-stamped the threshold")
    }

    /// And the rung count then advances one at a time from there, so the ladder
    /// still widens — the fix must not flatten it into a permanent five minutes.
    func testTheLadderStillWidensAfterASeverityChange() {
        Breaker.shared.recordFailure(lane: lane, severity: .answered, now: start)
        Breaker.shared.recordFailure(lane: lane, severity: .answered, now: start)
        Breaker.shared.recordFailure(lane: lane, severity: .unreachable, now: start)

        let firstRung = Breaker.backoff(pastThreshold: 1)
        let reprobedAt = start.advanced(by: .seconds(firstRung))
        Breaker.shared.recordFailure(lane: lane, severity: .unreachable, now: reprobedAt)

        let secondRung = Breaker.backoff(pastThreshold: 2)
        XCTAssertGreaterThan(secondRung, firstRung)
        XCTAssertEqual(
            Breaker.shared.decide(
                lane: lane, now: reprobedAt.advanced(by: .seconds(secondRung - 1))),
            .cooldown)
        XCTAssertEqual(
            Breaker.shared.decide(lane: lane, now: reprobedAt.advanced(by: .seconds(secondRung))),
            .probe)
    }

    /// A success wipes the rung count with everything else, so a lane that
    /// recovers and later fails again starts its next ladder from the bottom.
    func testTheRungCountResetsWithTheStreak() {
        Breaker.shared.recordFailure(lane: lane, severity: .unreachable, now: start)
        Breaker.shared.recordFailure(lane: lane, severity: .unreachable, now: start)
        Breaker.shared.recordWitnessed(lane: lane)

        Breaker.shared.recordFailure(lane: lane, severity: .unreachable, now: start)

        let firstRung = Breaker.backoff(pastThreshold: 1)
        XCTAssertEqual(
            Breaker.shared.decide(lane: lane, now: start.advanced(by: .seconds(firstRung))),
            .probe,
            "a repaired-then-failing lane must not inherit the old streak's rungs")
    }

    /// The cooldown widens, and it is HALF-OPEN: when a window expires exactly
    /// one probe goes through. A lane that latched shut until an explicit user
    /// action would be a silent trap, because most real repairs (a restarted
    /// server, a fixed proxy, a DNS record) leave the app's configuration
    /// untouched and are therefore invisible to it.
    func testTheCooldownWidensAndReopensForOneProbe() {
        Breaker.shared.recordFailure(lane: lane, severity: .unreachable, now: start)

        let firstRung = Breaker.backoff(pastThreshold: 1)
        XCTAssertEqual(
            Breaker.shared.decide(lane: lane, now: start.advanced(by: .seconds(firstRung - 1))),
            .cooldown)
        XCTAssertEqual(
            Breaker.shared.decide(lane: lane, now: start.advanced(by: .seconds(firstRung))),
            .probe,
            "the window expiring must let exactly one attempt through")

        // That attempt failed too: the ladder moves on a rung, and the longer
        // window is measured from the NEW failure.
        let reprobedAt = start.advanced(by: .seconds(firstRung))
        Breaker.shared.recordFailure(lane: lane, severity: .unreachable, now: reprobedAt)
        let secondRung = Breaker.backoff(pastThreshold: 2)
        XCTAssertGreaterThan(secondRung, firstRung, "the cadence must widen, not repeat")
        XCTAssertEqual(
            Breaker.shared.decide(lane: lane, now: reprobedAt.advanced(by: .seconds(firstRung))),
            .cooldown)
    }

    /// The ladder is bounded: a lane that is genuinely walled settles at one
    /// probe an hour rather than climbing forever into a state nothing can
    /// recover from without the user noticing.
    func testTheLadderIsBounded() {
        let ceiling = Breaker.backoff(pastThreshold: 99)
        XCTAssertEqual(ceiling, Breaker.backoff(pastThreshold: 4))
        XCTAssertEqual(ceiling, 60 * 60)
    }

    /// One witnessed absence clears everything — the streak, the cooldown, and
    /// the start instant the thread's rows are scoped against. Recovery needs no
    /// user action.
    func testASuccessResetsEverything() {
        Breaker.shared.recordFailure(lane: lane, severity: .unreachable, now: start)
        XCTAssertNotNil(Breaker.shared.faultedSince(lane: lane))

        Breaker.shared.recordWitnessed(lane: lane)

        XCTAssertEqual(Breaker.shared.decide(lane: lane, now: start), .probe)
        XCTAssertNil(Breaker.shared.faultedSince(lane: lane))
    }

    /// A server that does not implement `PROPFIND` is a CAPABILITY, not a
    /// failure: it never expires, it never counts toward a streak, and — the
    /// point — it produces no fault for the thread to talk about. A per-turn
    /// complaint about a permanent property of the user's own server is noise.
    func testAnIncapableLaneIsSilentAndNeverDecays() {
        Breaker.shared.recordCannotReturn(lane: lane)

        XCTAssertEqual(Breaker.shared.decide(lane: lane, now: start), .cannotReturn)
        XCTAssertEqual(
            Breaker.shared.decide(lane: lane, now: start.advanced(by: .seconds(86_400))),
            .cannotReturn,
            "waiting cannot make a server implement a method")
        XCTAssertNil(Breaker.shared.faultedSince(lane: lane),
                     "a limitation must never derive a fault row")
    }

    /// The app narrows on proof and must widen on proof too: a server that has
    /// since been reconfigured to speak `PROPFIND` gets its capability back from
    /// the first witnessed absence, with no reinstall and no reset button.
    func testAnIncapableLaneRecoversOnProof() {
        Breaker.shared.recordCannotReturn(lane: lane)
        Breaker.shared.recordWitnessed(lane: lane)

        XCTAssertEqual(Breaker.shared.decide(lane: lane, now: start), .probe)
    }

    /// An explicit user action ("my server is worth another look right now")
    /// drops the whole entry.
    func testResetForgetsTheLane() {
        Breaker.shared.recordFailure(lane: lane, severity: .unreachable, now: start)
        Breaker.shared.reset(lane: lane)

        XCTAssertEqual(Breaker.shared.decide(lane: lane, now: start), .probe)
        XCTAssertNil(Breaker.shared.faultedSince(lane: lane))
    }

    /// The streak start is stamped ONCE, at the first failure, and does not
    /// creep forward with later ones — otherwise the causality gate would walk
    /// past the very turns it was meant to cover, and the rows would vanish one
    /// by one as the lane kept failing.
    func testTheStreakStartIsStampedOnceAndDoesNotCreep() {
        let first = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)
        Breaker.shared.recordFailure(lane: lane, severity: .answered, now: start, wallClock: first)
        Breaker.shared.recordFailure(lane: lane, severity: .answered, now: start, wallClock: later)

        XCTAssertEqual(Breaker.shared.faultedSince(lane: lane), first)
    }

    /// Lanes are independent: one server going dark says nothing about another.
    func testLanesAreTrackedIndependently() {
        Breaker.shared.recordFailure(lane: lane, severity: .unreachable, now: start)

        XCTAssertEqual(Breaker.shared.decide(lane: "some-other-lane", now: start), .probe)
    }
}
