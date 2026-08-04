// SPDX-License-Identifier: Apache-2.0

// Conduck
// FileLaneScanBreakerTests.swift
//
// Locks the process-local circuit breaker that bounds the retroactive output
// scan against a file lane which can never answer "not found" — an SPA
// `try_files` fallback, a catch-all 403, an SSO portal that 200s everything.
// Without it every existence probe is non-definitive, no turn ever closes, and
// the per-turn hold map re-releases the same pending turns forever.
//
// What is covered here is the DECISION half: when a stalled pass may keep
// scanning, when it must stop, how fast a bad lane is re-asked, and what
// reopens it. The request half (`laneAnswersNotFound`) is one call into the
// production probe path and belongs to the founder's on-device QA.
//
// Deterministic + headless: no network, no Core Data, no Keychain. Time is
// injected, so nothing here sleeps.

import XCTest
@testable import Conduck

final class FileLaneScanBreakerTests: XCTestCase {

    private let breaker = FileLaneScanBreaker.shared
    private let base = ContinuousClock.Instant.now

    /// The singleton outlives an XCTest case, so every test starts from empty.
    override func setUp() {
        super.setUp()
        breaker.resetAllForTesting()
    }

    override func tearDown() {
        breaker.resetAllForTesting()
        super.tearDown()
    }

    private func lane(_ name: String = #function) -> String { "lane-\(name)" }

    private func measureTicket(_ lane: String, at now: ContinuousClock.Instant) -> FileLaneScanBreaker.Ticket {
        guard case let .measure(ticket) = breaker.evaluate(lane: lane, now: now) else {
            XCTFail("expected the breaker to ask for a measurement")
            return .init(lane: lane, generation: 0)
        }
        return ticket
    }

    // MARK: - The trip

    /// A lane with no history is measured, never assumed bad: the first stall in
    /// a process must not silence a server nothing has asked about yet.
    func testUnknownLaneIsMeasuredRatherThanSuppressed() {
        let lane = lane()
        XCTAssertNil(breaker.suppressionInterval(lane: lane, now: base))
        guard case .measure = breaker.evaluate(lane: lane, now: base) else {
            return XCTFail("a lane with no verdict must be measured")
        }
    }

    /// One measured fault ends the fan-out immediately — the pass has proof the
    /// LANE cannot answer, so probing its remaining turns is knowingly useless.
    func testOneMeasuredFaultSuppressesTheFanOutAtOnce() {
        let lane = lane()
        let ticket = measureTicket(lane, at: base)
        XCTAssertEqual(breaker.record(.faulted, ticket: ticket, now: base), 5 * 60)
        XCTAssertEqual(breaker.suppressionInterval(lane: lane, now: base), 5 * 60)
    }

    /// The bounded count: consecutive faults widen the cadence a walled lane is
    /// re-asked on, and it stops widening at an hour rather than latching shut,
    /// so a server repaired invisibly (a restart, a removed `try_files`, a fixed
    /// proxy) still recovers on its own.
    func testConsecutiveFaultsWidenTheCadenceToACeiling() {
        let lane = lane()
        var now = base
        let expected: [TimeInterval] = [5 * 60, 15 * 60, 30 * 60, 60 * 60, 60 * 60]
        for (index, interval) in expected.enumerated() {
            let ticket = measureTicket(lane, at: now)
            XCTAssertEqual(
                breaker.record(.faulted, ticket: ticket, now: now),
                interval,
                "fault \(index + 1) should back off to \(interval)s"
            )
            // Step past the backoff so the next evaluate is allowed to measure.
            now = now.advanced(by: .seconds(interval + 1))
        }
    }

    /// A faulted lane costs NOTHING inside its backoff window: no fan-out and no
    /// health request. This is the drain the breaker exists to remove.
    func testFaultedLaneIsFreeInsideItsBackoffWindow() {
        let lane = lane()
        let ticket = measureTicket(lane, at: base)
        breaker.record(.faulted, ticket: ticket, now: base)

        XCTAssertEqual(
            breaker.suppressionInterval(lane: lane, now: base.advanced(by: .seconds(299))),
            5 * 60
        )
        XCTAssertNil(
            breaker.suppressionInterval(lane: lane, now: base.advanced(by: .seconds(301))),
            "once the backoff elapses the lane is measurable again"
        )
    }

    // MARK: - Key-local ambiguity must not trip it

    /// The property that makes the breaker safe: one unreadable filename cannot
    /// silence a lane. An `.ambiguous` candidate stalls its turn, but the lane
    /// still answers a key that cannot exist, so the health verdict is healthy
    /// and the pass keeps scanning the rest of the window.
    func testHealthyVerdictKeepsAStalledPassScanning() {
        let lane = lane()
        let ticket = measureTicket(lane, at: base)
        XCTAssertNil(breaker.record(.healthy, ticket: ticket, now: base))
        XCTAssertNil(breaker.suppressionInterval(lane: lane, now: base))
        XCTAssertEqual(breaker.evaluate(lane: lane, now: base), .proceed)
    }

    /// A single healthy answer clears an accumulated fault ladder outright — the
    /// lane demonstrably works now, and making the user serve out a backoff
    /// earned by a server that has since recovered would be the wrong kind of
    /// memory.
    func testHealthyVerdictClearsTheFaultLadder() {
        let lane = lane()
        var now = base
        for _ in 0..<3 {
            let ticket = measureTicket(lane, at: now)
            let backoff = breaker.record(.faulted, ticket: ticket, now: now) ?? 0
            now = now.advanced(by: .seconds(backoff + 1))
        }
        let recovery = measureTicket(lane, at: now)
        breaker.record(.healthy, ticket: recovery, now: now)

        // Back to square one: the NEXT fault costs the shortest interval, not
        // the ceiling the lane had climbed to.
        let after = now.advanced(by: .seconds(120))
        let ticket = measureTicket(lane, at: after)
        XCTAssertEqual(breaker.record(.faulted, ticket: ticket, now: after), 5 * 60)
    }

    /// Evidence the scan produced anyway — a closed turn, or a confirmed file —
    /// is proof the lane answers definitively, and it costs no request at all.
    func testFreeEvidenceCountsAsHealth() {
        let lane = lane()
        let ticket = measureTicket(lane, at: base)
        breaker.record(.faulted, ticket: ticket, now: base)
        XCTAssertNotNil(breaker.suppressionInterval(lane: lane, now: base))

        breaker.noteHealthyEvidence(lane: lane, now: base)
        XCTAssertNil(breaker.suppressionInterval(lane: lane, now: base))
    }

    /// A healthy verdict is reusable only briefly. Its job is to collapse a
    /// reload storm into one measurement, not to keep fanning out at a lane that
    /// went down a minute ago.
    func testHealthyVerdictExpires() {
        let lane = lane()
        let ticket = measureTicket(lane, at: base)
        breaker.record(.healthy, ticket: ticket, now: base)

        XCTAssertEqual(breaker.evaluate(lane: lane, now: base.advanced(by: .seconds(30))), .proceed)
        guard case .measure = breaker.evaluate(lane: lane, now: base.advanced(by: .seconds(61))) else {
            return XCTFail("a stale healthy verdict must be re-measured, not reused")
        }
    }

    // MARK: - Reopening

    /// Lane identity is the key, so any edit to the URL, the credential or the
    /// device-local certificate pin lands on a clean entry. This is what makes
    /// "I just fixed my settings" instant with no reset path at all.
    func testIdentityChangeIsACleanLane() {
        let before = "durable-a\u{1}signature-a"
        let afterPinFix = "durable-a\u{1}signature-b"
        let ticket = measureTicket(before, at: base)
        breaker.record(.faulted, ticket: ticket, now: base)

        XCTAssertNotNil(breaker.suppressionInterval(lane: before, now: base))
        XCTAssertNil(
            breaker.suppressionInterval(lane: afterPinFix, now: base),
            "a pin-only repair changes identitySignature, so it is a different lane"
        )
    }

    /// The explicit user action. A "Check again" tap clears the backoff outright
    /// rather than serving out an interval the user has just contradicted.
    func testExplicitResetReopensTheLane() {
        let lane = lane()
        var now = base
        for _ in 0..<3 {
            let ticket = measureTicket(lane, at: now)
            let backoff = breaker.record(.faulted, ticket: ticket, now: now) ?? 0
            now = now.advanced(by: .seconds(backoff + 1))
        }
        let ticket = measureTicket(lane, at: now)
        breaker.record(.faulted, ticket: ticket, now: now)
        XCTAssertNotNil(breaker.suppressionInterval(lane: lane, now: now))

        breaker.reset(lane: lane)
        XCTAssertNil(breaker.suppressionInterval(lane: lane, now: now))
        guard case .measure = breaker.evaluate(lane: lane, now: now) else {
            return XCTFail("a reset lane is measured again immediately")
        }
    }

    /// A reset invalidates a measurement already in flight against the state it
    /// replaced. Without the generation check, an answer about the OLD lane
    /// could land on the clean one and re-suppress a lane the user just asked
    /// us to re-examine.
    func testVerdictFromASupersededGenerationIsDropped() {
        let lane = lane()
        let ticket = measureTicket(lane, at: base)
        breaker.reset(lane: lane)

        XCTAssertNil(breaker.record(.faulted, ticket: ticket, now: base))
        XCTAssertNil(breaker.suppressionInterval(lane: lane, now: base))
    }

    // MARK: - Single flight

    /// Several mounted threads on one lane must not each fire their own health
    /// request, and — the part that actually matters — must not each count an
    /// observation. One sample tripping the ladder three times would turn a
    /// single blip into the hourly cadence.
    func testConcurrentPassesShareOneMeasurement() {
        let lane = lane()
        let first = measureTicket(lane, at: base)

        XCTAssertEqual(
            breaker.evaluate(lane: lane, now: base),
            .suppress(retryAfter: 5 * 60),
            "a second view model waits rather than opening its own request"
        )

        breaker.record(.faulted, ticket: first, now: base)
        let after = base.advanced(by: .seconds(301))
        let second = measureTicket(lane, at: after)
        XCTAssertEqual(
            breaker.record(.faulted, ticket: second, now: after),
            15 * 60,
            "the ladder advanced once per completed measurement, not once per caller"
        )
    }

    /// A measurement that produced no verdict — the lane identity moved under
    /// it — releases its reservation without counting as a fault. The lane was
    /// not the thing that failed.
    func testAbandonedMeasurementIsNotAFault() {
        let lane = lane()
        let ticket = measureTicket(lane, at: base)
        breaker.abandon(ticket)

        XCTAssertNil(breaker.suppressionInterval(lane: lane, now: base))
        let next = measureTicket(lane, at: base)
        XCTAssertEqual(
            breaker.record(.faulted, ticket: next, now: base),
            5 * 60,
            "the abandoned attempt left no fault behind"
        )
    }
}
