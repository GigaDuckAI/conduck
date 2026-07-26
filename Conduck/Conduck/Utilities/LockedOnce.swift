// Conduck
// LockedOnce.swift
//
// The app's ONE once-primitive: a lock-backed single-fire latch for the
// "several callbacks race to resume one `CheckedContinuation`" shape, where a
// second `resume` is a hard `fatalError` in every build configuration.
//
// Its own file because three call sites across two files claim it, and every
// one of them is a `withCheckedContinuation` bridge whose handlers land on
// DIFFERENT queues:
//   - `WCSessionWatchHealthTransport.query(timeout:)` — WCSession's
//     `replyHandler` / `errorHandler` / the local deadline `Task`.
//   - `DiagnosticsRunner.probeNetworkPath()` — repeat `NWPathMonitor`
//     `pathUpdateHandler` deliveries.
//   - `CheckNetworkIntent.checkNetworkConnectivity()` — same `NWPathMonitor`
//     shape, claimed BEFORE `cancel()` (which stops FUTURE deliveries but
//     cannot un-enqueue a handler block already dispatched).
// A bare `Bool` flag would be the trap each of them copies instead.
//
// Pure `os` + Foundation. NOT a Watch-target member (no watchOS call site).

import Foundation
import os        // OSAllocatedUnfairLock — the latch's backing store

/// Thread-safe single-fire latch. Internal (not private to any one file) so all
/// three continuation bridges share one implementation, and so the concurrency
/// test can hammer `claim()` directly.
final class LockedOnce: @unchecked Sendable {
    private let fired = OSAllocatedUnfairLock(initialState: false)
    /// True exactly once, for exactly one caller.
    func claim() -> Bool {
        fired.withLock { alreadyFired in
            if alreadyFired { return false }
            alreadyFired = true
            return true
        }
    }
}
