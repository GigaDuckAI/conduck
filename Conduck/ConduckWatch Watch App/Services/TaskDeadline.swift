// SPDX-License-Identifier: Apache-2.0

// Conduck
// TaskDeadline.swift
//
// First-finisher race between an already-running task and a deadline.
// Shared by `WatchSessionManager.pullSettingsFromPhone` and
// `WatchIdentityResolver.requestFromPhoneWithTimeout` — both await a
// WCSession `sendMessage` round-trip whose reply window is system-
// controlled and can exceed the caller's budget.

import Foundation

/// Await `task.value`, but stop waiting after `seconds` and return
/// `fallback` instead. The task is NOT cancelled — it keeps running and its
/// completion work (e.g. applying a pulled settings payload) still happens;
/// only THIS caller stops waiting for it.
///
/// Why not `withTaskGroup`: a group awaits ALL children before returning,
/// even after `cancelAll()`, and a child suspended in `await task.value`
/// over a parked `withCheckedContinuation` cannot be interrupted by
/// cancellation — a group-based race therefore returns the right VALUE at
/// the deadline but not at the deadline TIME (it blocks until the
/// underlying continuation resumes, e.g. WCSession's own undocumented
/// reply timeout). Here the first `AsyncStream` yield wins and the loser's
/// later yield is a no-op, so the caller returns at the deadline.
func awaitValue<T: Sendable>(
    of task: Task<T, Never>,
    deadline seconds: TimeInterval,
    onDeadline fallback: T
) async -> T {
    let stream = AsyncStream<T> { continuation in
        Task {
            continuation.yield(await task.value)
            continuation.finish()
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            continuation.yield(fallback)
            continuation.finish()
        }
    }
    for await first in stream {
        return first
    }
    return fallback
}
