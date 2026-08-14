// SPDX-License-Identifier: Apache-2.0

// Conduck
// ReadStateStore.swift
//
// Device-local record of what the user has already LOOKED AT in each
// conversation — the source of the conversation list's "there is something here
// you haven't seen" states. It keeps TWO markers per conversation, because the
// list asks two different questions:
//
//   • `markViewed`      — when was this thread last on screen? Drives the amber
//                         unseen-reply disc and the bold row.
//   • `markFailureSeen` — when was this thread last on screen WHILE IT WAS
//                         SHOWING A FAILURE? Drives whether the red mark has
//                         been retired.
//
// THE SECOND IS NOT DERIVABLE FROM THE FIRST, and collapsing them is the bug
// this shape exists to prevent. The read marker is re-stamped on every new tail
// in an open thread — including the user's own message, the instant it is sent.
// A failed turn's stamp is its `createdAt`, and failing bumps neither that nor
// the conversation's `lastActivityAt`. So by the time a send fails, the read
// marker is ALREADY newer than the turn it would have to acknowledge: reusing
// it would suppress the failure mark for everything sent from the composer,
// which is nearly every failure. The failure marker is therefore written only
// where a failure is actually on screen.
//
// DEVICE-LOCAL BY DESIGN, and it must stay that way: App-Group `UserDefaults`
// ONLY, never `NSUbiquitousKeyValueStore`, never a Core Data column. The
// CloudKit production schema is additive-only and permanent, and "I read this on
// my phone" is not a fact the iPad should inherit — these markers answer "is
// there something here I haven't looked at ON THIS SCREEN".
//
// NOT ON watchOS. The Watch app has its own container, so a wrist marker could
// only ever record wrist-viewing; the wrist shows delivery state only.
//
// MULTI-PROCESS SHAPE. The main app, the share extension, an App Intent and a
// background relaunch all run against the same App Group. Only the main app
// writes markers today (stated here so a future writer is a deliberate
// decision), and the per-conversation key layout means even a second writer
// could not lose an UNRELATED marker — there is no read-modify-write of a shared
// blob to lose it in.

import Foundation

@Observable @MainActor
final class ReadStateStore {

    // MARK: - Singleton

    static let shared = ReadStateStore()

    /// Bounded cache, applied to EACH marker set independently. Beyond this the
    /// oldest markers are dropped. There is NO list-fetch-driven pruning:
    /// absence from one fetch is not a deletion signal — an offline launch reads
    /// a partial local mirror before the CloudKit import lands, and pruning
    /// there would relight recently-read threads.
    static let maxMarkers = 2_000

    /// Realistic device-clock skew the marker clamp absorbs. Deliberately
    /// small: it exists for minutes of drift, not for a broken clock.
    static let clockSkewGrace: TimeInterval = 3_600

    // MARK: - State

    private let defaults: any DefaultsStore

    /// Markers CACHED in observable stored properties. `@Observable` reports
    /// changes to STORED properties only, so a getter reading `DefaultsStore`
    /// directly would register no SwiftUI dependency (the row would never
    /// repaint when a thread is marked viewed) and would also decode the whole
    /// defaults domain once per row per body evaluation.
    private var markers: [UUID: Date]

    /// The failure-acknowledgement set. Separate storage for the reason in the
    /// file header — same shape, different write trigger.
    private var failureMarkers: [UUID: Date]

    /// This device's first sight of the feature. Nil until stamped; everything
    /// older counts as viewed. Applies to the READ marker only — see
    /// `lastFailureSeen` for why acknowledgement gets no such optimism.
    private var epoch: Date?

    // MARK: - Init

    init(defaults: any DefaultsStore = SettingsDependencies.processDefault.defaults) {
        self.defaults = defaults

        // ONE prefix sweep at construction, not a per-read decode. Both sets are
        // filled from the same pass so a launch costs one decode, not two.
        var loadedRead: [UUID: Date] = [:]
        var loadedFailure: [UUID: Date] = [:]
        var orphanKeys: [String] = []
        let readPrefix = Constants.conversationReadStatePrefix
        let failurePrefix = Constants.conversationFailureSeenPrefix

        for (key, value) in defaults.dictionaryRepresentation() {
            let prefix: String
            if key.hasPrefix(readPrefix) {
                // The epoch shares the read prefix and is not a marker.
                if key == Constants.conversationReadStateEpochKey { continue }
                prefix = readPrefix
            } else if key.hasPrefix(failurePrefix) {
                prefix = failurePrefix
            } else {
                continue
            }

            // An orphan is a key under one of these prefixes that cannot be a
            // marker at all — an unparsable id or a non-numeric value. That is
            // garbage this store wrote or a future format it does not
            // understand; either way keeping it only grows the sweep. A marker
            // whose conversation no longer exists is NOT an orphan (see
            // `markDeleted` and the header's no-fetch-driven-pruning rule).
            let suffix = String(key.dropFirst(prefix.count))
            guard let id = UUID(uuidString: suffix),
                  let seconds = (value as? NSNumber)?.doubleValue else {
                orphanKeys.append(key)
                continue
            }
            if prefix == readPrefix {
                loadedRead[id] = Date(timeIntervalSince1970: seconds)
            } else {
                loadedFailure[id] = Date(timeIntervalSince1970: seconds)
            }
        }
        self.markers = loadedRead
        self.failureMarkers = loadedFailure

        let storedEpoch = defaults.double(forKey: Constants.conversationReadStateEpochKey)
        self.epoch = storedEpoch > 0 ? Date(timeIntervalSince1970: storedEpoch) : nil

        for key in orphanKeys { defaults.removeObject(forKey: key) }
        enforceCap(on: &markers, prefix: readPrefix)
        enforceCap(on: &failureMarkers, prefix: failurePrefix)
    }

    // MARK: - Epoch

    /// Stamp this device's first sight of the feature. Called ONCE from
    /// deterministic app startup, never from a SwiftUI `body` — creating state
    /// during rendering is both a SwiftUI error and a race with the CloudKit
    /// import (a reply that imported at 10:00 would be classified read because
    /// the first row happened to render at 10:01). Idempotent.
    func stampEpochIfNeeded(now: Date = Date()) {
        guard epoch == nil else { return }
        epoch = now
        defaults.set(now.timeIntervalSince1970, forKey: Constants.conversationReadStateEpochKey)
    }

    // MARK: - Read

    /// Epoch-resolved "last looked at" for one conversation.
    ///
    /// `nil` ONLY before the epoch is stamped, in which case every conversation
    /// is treated as viewed — the safe direction: a fresh install with imported
    /// history shows zero dots. Once stamped, a conversation with no marker of
    /// its own resolves to the epoch, so imported history stays dark while
    /// anything that arrives afterwards is genuinely new.
    func lastViewed(_ conversationID: UUID) -> Date? {
        resolved(markers[conversationID])
    }

    /// "Last looked at while a failure was showing" — the RAW marker, with NO
    /// epoch fallback. Nil means nothing has acknowledged this conversation's
    /// failure, so it keeps its mark.
    ///
    /// DELIBERATELY ASYMMETRIC WITH `lastViewed`, which does fall back to the
    /// epoch. Two reasons, and both point the same way:
    ///
    /// 1. An epoch fallback here would be UNCLEARABLE. `clearFailureSeen` exists
    ///    so a retried turn can go red again, but a retry does not advance the
    ///    turn's `createdAt` — so a turn older than the epoch would resolve as
    ///    acknowledged the instant its marker was removed, and the clear would
    ///    be a no-op. The same trap swallows a pre-epoch `sending` turn that the
    ///    launch sweep later flips to `failed`: a first-ever failure, silently
    ///    born acknowledged.
    /// 2. The two signals fail in opposite directions. An unacknowledged failure
    ///    over-reports — the user sees a mark for something they already read,
    ///    and one click clears it. An acknowledged one goes SILENT, which is the
    ///    failure mode this whole feature must not have. The unseen-reply disc
    ///    can afford the epoch's optimism because a missed reply is still sitting
    ///    there to be found; a mark that never appears is a message the user
    ///    never learns did not send.
    ///
    /// The cost is one visible mark per already-failed conversation on the first
    /// launch after this ships, each cleared by opening it. That is the feature
    /// working, not a wall of noise: only a conversation whose TAIL is still a
    /// failed turn qualifies, and asking again has always retired those.
    func lastFailureSeen(_ conversationID: UUID) -> Date? {
        failureMarkers[conversationID]
    }

    private func resolved(_ marker: Date?) -> Date? {
        guard let epoch else { return nil }
        guard let marker else { return epoch }
        return max(marker, epoch)
    }

    /// Every stored marker — tests + diagnostics.
    func storedMarkers() -> [UUID: Date] { markers }

    /// Every stored failure-acknowledgement marker — tests + diagnostics.
    func storedFailureMarkers() -> [UUID: Date] { failureMarkers }

    // MARK: - Write

    /// Record that the user has looked at this conversation.
    ///
    /// CLAMPED AND MONOTONIC — see `clamped(existing:reference:now:)`.
    func markViewed(_ conversationID: UUID, lastActivityAt: Date?, now: Date = Date()) {
        write(
            conversationID,
            into: &markers,
            prefix: Constants.conversationReadStatePrefix,
            reference: lastActivityAt,
            now: now
        )
    }

    /// Record that the user has looked at this conversation WHILE it was showing
    /// a failure — the acknowledgement that retires the list's red mark.
    ///
    /// `failedAt` is the failed turn's own stamp, and it plays exactly the role
    /// `lastActivityAt` plays for `markViewed`: a turn mirrored from a device
    /// whose clock runs ahead would otherwise stay "newer than the marker" and
    /// keep its row red while the user is looking straight at the error.
    func markFailureSeen(_ conversationID: UUID, failedAt: Date?, now: Date = Date()) {
        write(
            conversationID,
            into: &failureMarkers,
            prefix: Constants.conversationFailureSeenPrefix,
            reference: failedAt,
            now: now
        )
    }

    /// Spend this conversation's failure acknowledgement, so the NEXT failure
    /// earns a fresh mark.
    ///
    /// Called when a failed turn is re-armed by Retry, and it is what keeps the
    /// acknowledgement honest. Retry writes ONLY the status column — the turn
    /// keeps its original `createdAt`, and a status flip bumps neither that nor
    /// the conversation's `lastActivityAt`. So the stamp the resolver compares
    /// against never advances across a retry: without this, one acknowledgement
    /// would silence that turn's mark for every re-failure it ever has, and
    /// `markFailureSeen` is monotone so nothing else could undo it.
    ///
    /// A plain removal, not a backdated stamp: the marker must fall back to the
    /// epoch exactly as an untouched conversation's does.
    func clearFailureSeen(_ conversationID: UUID) {
        guard failureMarkers.removeValue(forKey: conversationID) != nil else { return }
        defaults.removeObject(
            forKey: Constants.conversationFailureSeenPrefix + conversationID.uuidString
        )
    }

    /// Drop both markers for a conversation the user actually deleted. This is
    /// the ONLY deletion path — absence from a fetch is not one.
    func markDeleted(_ conversationID: UUID) {
        if markers.removeValue(forKey: conversationID) != nil {
            defaults.removeObject(
                forKey: Constants.conversationReadStatePrefix + conversationID.uuidString
            )
        }
        if failureMarkers.removeValue(forKey: conversationID) != nil {
            defaults.removeObject(
                forKey: Constants.conversationFailureSeenPrefix + conversationID.uuidString
            )
        }
    }

    // MARK: - Shared mechanics

    /// The ONE write path both marker sets take, so a fix to the clamp or the
    /// cap cannot land on one set and miss the other.
    ///
    /// Mutates `set` IN PLACE through the `inout` binding rather than staging a
    /// local copy. `@Observable` yields the stored property directly for an
    /// `inout` argument and brackets the whole call in a single mutation event,
    /// so a staged copy would buy no observation benefit and would force a
    /// copy-on-write duplication of up to `maxMarkers` entries — on a path that
    /// runs for every new tail in an open thread.
    private func write(
        _ conversationID: UUID,
        into set: inout [UUID: Date],
        prefix: String,
        reference: Date?,
        now: Date
    ) {
        let existing = set[conversationID]
        let marker = Self.clamped(existing: existing, reference: reference, now: now)
        guard marker != existing else { return }

        set[conversationID] = marker
        defaults.set(marker.timeIntervalSince1970, forKey: prefix + conversationID.uuidString)
        enforceCap(on: &set, prefix: prefix)
    }

    /// CLAMPED AND MONOTONIC:
    ///     newMarker = max(existing, now, min(reference, now + grace))
    ///
    /// - `max(existing, …)` — a local clock that moves backwards can never
    ///   resurrect already-acknowledged state.
    /// - `min(reference, now + grace)` — a row mirrored from a device whose
    ///   clock is a month fast cannot poison this marker into the future and
    ///   suppress a month of genuinely new activity. The residual failure on
    ///   such a device is a stuck marker, not silence.
    private static func clamped(existing: Date?, reference: Date?, now: Date) -> Date {
        var candidate = now
        if let reference {
            candidate = max(candidate, min(reference, now.addingTimeInterval(clockSkewGrace)))
        }
        return max(existing ?? .distantPast, candidate)
    }

    /// Keep a marker set bounded, dropping the OLDEST first — the least likely
    /// to still matter, since an old marker's conversation is far down a list
    /// sorted by activity.
    private func enforceCap(on set: inout [UUID: Date], prefix: String) {
        guard set.count > Self.maxMarkers else { return }
        let doomed = set
            .sorted { $0.value < $1.value }
            .prefix(set.count - Self.maxMarkers)
        for (id, _) in doomed {
            set.removeValue(forKey: id)
            defaults.removeObject(forKey: prefix + id.uuidString)
        }
    }

    // MARK: - Testing

    /// Test-only reset hook. Clears both caches AND the backing keys so test
    /// order cannot leak state through the shared instance.
    static func _resetForTesting() {
        let store = shared
        store.markers.removeAll()
        store.failureMarkers.removeAll()
        store.epoch = nil
        for key in store.defaults.dictionaryRepresentation().keys
        where key.hasPrefix(Constants.conversationReadStatePrefix)
            || key.hasPrefix(Constants.conversationFailureSeenPrefix) {
            store.defaults.removeObject(forKey: key)
        }
        store.defaults.removeObject(forKey: Constants.conversationReadStateEpochKey)
    }
}
