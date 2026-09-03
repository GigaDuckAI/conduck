// SPDX-License-Identifier: Apache-2.0

// Conduck
// PendingRetryLeaseRenewal.swift
//
// Keeps ONE retry reservation alive for exactly as long as a surface is working
// on the recording it holds.
//
// Why it has to exist: a retry surface is granted its reservation for ten
// minutes, and a single custom STT request is allowed 300 seconds and is
// attempted three times — so one transcription can outlast the hold that is
// protecting it. The store can extend a hold (`PendingRetryStore.renew`) and
// exempts a held capture from the expiry sweep, but nothing was asking it to,
// which left the longest transcriptions — the ones on the worst connections,
// which is where parked recordings come from — the likeliest to lose the
// recording underneath them.
//
// SCOPED rather than started and stopped by hand: the renewal lives exactly as
// long as the `operation` call, so a throw, an early return or a cancelled task
// stops it with nothing for the caller to remember. A surface that had to call
// `stop()` on every exit is the same duty the release of the reservation itself
// was got wrong on once already.
//
// Stopping the renewal is NOT releasing the reservation: the holder still owns
// the capture afterwards, until it releases it, clears it, or the horizon
// lapses. This type only decides how long "still working" keeps the horizon
// ahead of the clock.

import Foundation

enum PendingRetryLeaseRenewal {

    /// How often a live holder extends its reservation.
    ///
    /// Far inside the ten minutes a retry surface is granted, so a single
    /// missed tick — a suspended app, a busy main actor — never costs the hold,
    /// and the extension is cheap: one metadata write under the cross-process
    /// lock, no recording read.
    ///
    /// `nonisolated` because it is the default argument below, which is
    /// evaluated outside any actor.
    nonisolated static let interval: TimeInterval = 120

    /// Run `operation` while renewing `claim` every `interval` seconds.
    ///
    /// The renewal starts before the work and stops the instant the work
    /// returns, throws, or is cancelled. A renewal the store REFUSES ends the
    /// loop rather than retrying: false means the reservation lapsed and
    /// somebody else took the capture, and the ownership check every surface
    /// makes before it acts on the result is what turns that into a
    /// user-visible refusal. A loop that kept asking would only take the
    /// cross-process lock on behalf of a holder that no longer holds anything.
    static func whileRenewing<T>(
        _ claim: PendingRetryClaim,
        in store: PendingRetryStore = .shared,
        every interval: TimeInterval = PendingRetryLeaseRenewal.interval,
        operation: () async throws -> T
    ) async rethrows -> T {
        // Detached on purpose: the callers are main-actor surfaces, and a
        // renewal inherited onto the main actor would queue behind the very UI
        // work the long transcription is keeping busy.
        let renewal = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(max(0, interval) * 1_000_000_000)
                    )
                } catch {
                    return
                }
                guard await store.renew(claim) else { return }
            }
        }
        defer { renewal.cancel() }
        return try await operation()
    }
}
