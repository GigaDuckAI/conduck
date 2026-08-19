// SPDX-License-Identifier: Apache-2.0

// Conduck
// NetworkPathObserver.swift
//
// One process-lifetime `NWPathMonitor` whose only authority is CHOOSING A WORD.
//
// THE NARRATOR CONSTRAINT — read this before wiring anything new to it. This
// observer may change what a row SAYS and nothing else. It never gates a
// dispatch, never cancels a task, never enqueues, never writes to the store,
// and is never consulted before `task.resume()`. That is what makes it safe by
// construction rather than by evidence: Apple documents no guarantee behind
// `NWPath.Status.satisfied` (a captive portal reads `.satisfied`; the nearest
// normative statement, the deprecated `SCNetworkReachability`, only ever
// promised that a packet CAN leave the device), so any design that let this
// signal authorize an action would be resting a correctness claim on an
// undocumented one. Here it rests on nothing: the worst a wrong reading can do
// is put a slightly different sentence on a screen.
//
// `.unsatisfied` IS THE ONLY STATUS ACTED ON. `.satisfied` and
// `.requiresConnection` authorize nothing, anywhere. The two consumers are:
//   1. `LiveTurnPhaseResolver` — picking "Waiting for a connection…" over
//      "Sending…" for a turn already in flight, and only while the turn has
//      NOT yet been stamped as dispatched.
//   2. `ConverseCancelVerdict` — ADDING the offline cause to an already-proven
//      failure a user-initiated Stop produced. The proof there comes from the
//      byte counters alone. This reading can only ever ADD, never select: a
//      `.satisfied` answer leaves the verdict on the client-side cause that
//      names nothing but the stop itself, so a wrong reading yields a
//      differently-worded failure on a turn already proven undelivered, never
//      a failure that should not have been and never a remedy pointed at a
//      machine that was not involved.
//
// NOT A PREFLIGHT. Apple's guidance against pre-flighting reachability targets
// the pattern of asking "is the network up?" and then declining to make a
// request. Nothing here declines anything.
//
// DELIBERATELY LAZY. `shared` is constructed on first read, which in practice
// comes from the conversation thread's derived phase. Nothing in app startup
// touches it, so the monitor costs nothing on a launch that never renders a
// live turn. CONSEQUENCE, stated rather than hidden: before the first read —
// and in the window before the monitor's first callback lands —
// `pathIsUnsatisfiedNow()` reports `false`. "We do not know" must never render
// as "offline", so unknown always falls to the safe side: the row says
// "Sending…" and a Stop names only the stop itself. The headless Shortcut
// lane never constructs it and needs nothing from it (it has no UI and no
// Stop); every surface that can show a phase or offer a Stop has read the
// observable property first, which is what constructs it.
//
// TWO READERS, ONE TRUTH. SwiftUI reads the `@Observable` property on the main
// actor. `BackgroundRemoteAgent`'s serial delegate queue reads
// `pathIsUnsatisfiedNow()`, a lock-guarded snapshot written from the path
// handler BEFORE it hops to the main actor. The delegate must never touch the
// `@Observable` property — Observation's storage is main-actor state.
//
// watchOS: NOT A MEMBER OF THE WATCH TARGET, deliberately and permanently.
// With a paired iPhone nearby the wrist's path reads `.satisfied` through the
// companion proxy even when the phone itself has no route out, so `.unsatisfied`
// there is both rare and misleading. The wrist keeps `WatchNetworkFailureCopy`,
// which reasons about the companion link instead.
//
// macOS: compiles and runs, and can never change a word — the macOS converse
// lane stamps dispatch at turn start, and the resolver short-circuits on that.
// No `#if` is needed anywhere; do not add one.

import Foundation
import Network

@Observable @MainActor
final class NetworkPathObserver {

    static let shared = NetworkPathObserver()

    /// SwiftUI-observable mirror of the snapshot. `false` until the monitor's
    /// first callback lands — see the header on why unknown reads as "not
    /// unsatisfied".
    private(set) var isPathUnsatisfied: Bool = false

    /// The nonisolated read for `BackgroundRemoteAgent`'s delegate queue.
    /// Returns `false` when the observer has never been constructed, which is
    /// the same safe side as "not yet known".
    nonisolated static func pathIsUnsatisfiedNow() -> Bool { snapshot.current }

    // MARK: - Snapshot

    /// Lock-guarded mirror, written from the monitor's queue and read from any
    /// thread. A separate box rather than a bare `nonisolated(unsafe) var`: the
    /// change-detection and the read have to share one critical section, or two
    /// rapid transitions can interleave into a stale mirror.
    private final class Snapshot: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        #if CONDUCK_TESTING
        /// Test-only forced reading. Held under the SAME lock as `value` so a
        /// forced answer and a live monitor callback can never interleave into
        /// a half-applied state.
        private var forced: Bool?
        #endif

        var current: Bool {
            lock.lock()
            defer { lock.unlock() }
            #if CONDUCK_TESTING
            if let forced { return forced }
            #endif
            return value
        }

        /// Store `newValue`; returns whether it actually differed. CHANGE-ONLY
        /// by contract — the path handler fires repeatedly with the same status
        /// and every downstream write is more expensive than this compare.
        @discardableResult
        func set(_ newValue: Bool) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard value != newValue else { return false }
            value = newValue
            return true
        }

        #if CONDUCK_TESTING
        /// Install or clear the forced reading; returns what `current` now
        /// reports, so the caller can bring the observable mirror to the same
        /// answer inside one critical section's worth of truth.
        func force(_ newValue: Bool?) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            forced = newValue
            return forced ?? value
        }
        #endif
    }

    nonisolated private static let snapshot = Snapshot()

    // MARK: - Monitor

    /// Started in `init`, never cancelled and never restarted. A monitor that
    /// could be stopped would need every caller to agree on who owns the
    /// lifetime, and a stopped monitor reports a frozen status that reads
    /// exactly like a live one.
    @ObservationIgnored private let monitor = NWPathMonitor()

    private init() {
        let queue = DispatchQueue(label: Constants.identityNamespace + ".networkpath")
        monitor.pathUpdateHandler = { [weak self] path in
            let unsatisfied = (path.status == .unsatisfied)
            // Snapshot first, main actor second: the delegate queue's reader
            // must never observe an older value than the UI does.
            guard Self.snapshot.set(unsatisfied) else { return }
            Task { @MainActor in
                guard let self else { return }
                // Re-read the snapshot rather than trusting the captured value.
                // Two transitions in quick succession spawn two hops with no
                // ordering guarantee between them; both then converge on the
                // one settled truth instead of fighting over it.
                let latest = Self.pathIsUnsatisfiedNow()
                guard self.isPathUnsatisfied != latest else { return }
                self.isPathUnsatisfied = latest
            }
        }
        monitor.start(queue: queue)
    }

    // MARK: - Testing

    #if CONDUCK_TESTING
    /// TEST SEAM — force what every reader believes about the path, in memory,
    /// for the duration of one test. `nil` hands the answer back to the monitor.
    ///
    /// WHY IT HAS TO EXIST. The only producer of this value is a real
    /// `NWPathMonitor` reading the host's actual radios, and `isPathUnsatisfied`
    /// is `private(set)`. So the ENTIRE `.waitingForNetwork` half of the live-turn
    /// state machine — the airplane-mode case this whole design was built for —
    /// is unreachable from a suite through the composed types: a test could only
    /// ever observe whatever the build machine's network happened to be doing,
    /// which is both wrong and non-deterministic. Without a seam the phase could
    /// be asserted at the pure-resolver level and nowhere else, leaving the wiring
    /// between the registry, this observer, the view model and the row copy
    /// untested — which is exactly the seam the original defect lived in.
    ///
    /// SAFE AGAINST THE LIVE MONITOR by construction, not by timing. A forced
    /// reading wins inside `Snapshot`'s critical section, and the monitor's
    /// main-actor hop RE-READS `pathIsUnsatisfiedNow()` rather than trusting its
    /// captured status — so a real path change landing mid-test updates the
    /// hidden `value` and cannot move either the snapshot or the observable
    /// mirror while a force is installed.
    ///
    /// Compiled only under `CONDUCK_TESTING` (the `Debug-Testing` configuration),
    /// so no shipping build carries a way to lie to this observer.
    static func _setPathUnsatisfiedForTesting(_ value: Bool?) {
        let settled = snapshot.force(value)
        if shared.isPathUnsatisfied != settled { shared.isPathUnsatisfied = settled }
    }
    #endif
}
