// Conduck — watchOS-only contract tests for `awaitValue` (TaskDeadline.swift),
// the first-finisher race between an already-running task and a deadline.
//
// Load-bearing for both WCSession round-trip waiters
// (`WatchSessionManager.pullSettingsFromPhone`,
// `WatchIdentityResolver.requestFromPhoneWithTimeout`): a caller must get its
// fallback AT the deadline TIME even while the shared task is parked on a
// continuation WCSession may not resume for many seconds — and the shared
// task must never be cancelled by a caller's expiry (its completion work,
// e.g. applying a pulled settings payload, still happens).

import XCTest
@testable import ConduckWatch_Watch_App

@MainActor
final class TaskDeadlineTests: XCTestCase {

    /// Holds a parked continuation so the test can resume it AFTER asserting —
    /// a checked continuation deallocated unresumed trips the runtime check.
    @MainActor
    private final class ContinuationBox {
        var continuation: CheckedContinuation<String, Never>?
    }

    func testReturnsFallbackAtDeadlineTimeWhileTaskIsParked() async {
        let box = ContinuationBox()
        let task = Task {
            await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
                box.continuation = c
            }
        }

        let started = Date()
        let value = await awaitValue(of: task, deadline: 0.15, onDeadline: "fallback")
        XCTAssertEqual(value, "fallback",
                       "A parked task must lose the race to the deadline leg.")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3.0,
                          "Must return at the deadline TIME — the parked continuation cannot hold the caller.")

        // Release the parked task and confirm the deadline never cancelled it:
        // the loser keeps running and its value still lands for a direct await.
        box.continuation?.resume(returning: "late")
        let final = await task.value
        XCTAssertEqual(final, "late",
                       "The shared task must keep running past the deadline (never cancelled by the race).")
    }

    func testTaskValueWinsBeforeDeadlineAndLateDeadlineYieldIsInert() async {
        let task = Task { true }
        let started = Date()
        let value = await awaitValue(of: task, deadline: 5, onDeadline: false)
        XCTAssertTrue(value,
                      "The task's value must win when it completes first — the deadline leg's later yield hits a finished stream (no-op).")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3.0,
                          "An early task win must not hold the caller anywhere near the deadline.")
    }

    func testDeadlineExpiryDoesNotCancelTheSharedTask() async {
        let task = Task { () -> Bool in
            try? await Task.sleep(for: .milliseconds(1500))
            // `try?` swallows a CancellationError, so a cancelled task would
            // fall through here immediately with isCancelled == true.
            return !Task.isCancelled
        }
        let raced = await awaitValue(of: task, deadline: 0.1, onDeadline: false)
        XCTAssertFalse(raced, "The deadline must win while the task is still sleeping.")

        let final = await task.value
        XCTAssertTrue(final,
                      "awaitValue must NOT cancel the shared task — its completion work still happens after the caller stopped waiting.")
    }
}
