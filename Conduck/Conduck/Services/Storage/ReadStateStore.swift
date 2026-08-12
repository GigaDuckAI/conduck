// SPDX-License-Identifier: Apache-2.0

// Conduck
// ReadStateStore.swift
//
// Device-local record of when each conversation was last LOOKED AT — the source
// of the conversation list's "there is something here you haven't seen" state.
//
// DEVICE-LOCAL BY DESIGN, and it must stay that way: App-Group `UserDefaults`
// ONLY, never `NSUbiquitousKeyValueStore`, never a Core Data column. The
// CloudKit production schema is additive-only and permanent, and "I read this on
// my phone" is not a fact the iPad should inherit — the dot answers "is there
// something here I haven't looked at ON THIS SCREEN".
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

    /// Bounded cache. Beyond this the oldest markers are dropped. There is NO
    /// list-fetch-driven pruning: absence from one fetch is not a deletion
    /// signal — an offline launch reads a partial local mirror before the
    /// CloudKit import lands, and pruning there would relight recently-read
    /// threads.
    static let maxMarkers = 2_000

    /// Realistic device-clock skew the marker clamp absorbs. Deliberately
    /// small: it exists for minutes of drift, not for a broken clock.
    static let clockSkewGrace: TimeInterval = 3_600

    // MARK: - State

    private let defaults: any DefaultsStore

    /// Markers CACHED in an observable stored property. `@Observable` reports
    /// changes to STORED properties only, so a getter reading `DefaultsStore`
    /// directly would register no SwiftUI dependency (the row would never
    /// repaint when a thread is marked viewed) and would also decode the whole
    /// defaults domain once per row per body evaluation.
    private var markers: [UUID: Date]

    /// This device's first sight of the feature. Nil until stamped; everything
    /// older counts as viewed.
    private var epoch: Date?

    // MARK: - Init

    init(defaults: any DefaultsStore = SettingsDependencies.processDefault.defaults) {
        self.defaults = defaults

        // ONE prefix sweep at construction, not a per-read decode.
        var loaded: [UUID: Date] = [:]
        var orphanKeys: [String] = []
        let prefix = Constants.conversationReadStatePrefix
        for (key, value) in defaults.dictionaryRepresentation() {
            guard key.hasPrefix(prefix) else { continue }
            if key == Constants.conversationReadStateEpochKey { continue }
            let suffix = String(key.dropFirst(prefix.count))
            // An orphan is a key under this prefix that cannot be a marker at
            // all — an unparsable id or a non-numeric value. That is garbage
            // this store wrote or a future format it does not understand;
            // either way keeping it only grows the sweep. A marker whose
            // conversation no longer exists is NOT an orphan (see `markDeleted`
            // and the header's no-fetch-driven-pruning rule).
            guard let id = UUID(uuidString: suffix),
                  let seconds = (value as? NSNumber)?.doubleValue else {
                orphanKeys.append(key)
                continue
            }
            loaded[id] = Date(timeIntervalSince1970: seconds)
        }
        self.markers = loaded

        let storedEpoch = defaults.double(forKey: Constants.conversationReadStateEpochKey)
        self.epoch = storedEpoch > 0 ? Date(timeIntervalSince1970: storedEpoch) : nil

        for key in orphanKeys { defaults.removeObject(forKey: key) }
        enforceCap()
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
        guard let epoch else { return nil }
        guard let marker = markers[conversationID] else { return epoch }
        return max(marker, epoch)
    }

    /// Every stored marker — tests + diagnostics.
    func storedMarkers() -> [UUID: Date] { markers }

    // MARK: - Write

    /// Record that the user has looked at this conversation.
    ///
    /// CLAMPED AND MONOTONIC:
    ///     newMarker = max(existing, now, min(lastActivityAt, now + grace))
    ///
    /// - `max(existing, …)` — a local clock that moves backwards can never
    ///   resurrect already-read replies.
    /// - `min(lastActivityAt, now + grace)` — a row mirrored from a device whose
    ///   clock is a month fast cannot poison this marker into the future and
    ///   suppress a month of genuinely new replies. The residual failure on such
    ///   a device is a stuck dot, not silence.
    func markViewed(_ conversationID: UUID, lastActivityAt: Date?, now: Date = Date()) {
        var candidate = now
        if let lastActivityAt {
            candidate = max(candidate, min(lastActivityAt, now.addingTimeInterval(Self.clockSkewGrace)))
        }
        let existing = markers[conversationID]
        let marker = max(existing ?? .distantPast, candidate)
        guard marker != existing else { return }
        markers[conversationID] = marker
        defaults.set(marker.timeIntervalSince1970, forKey: Self.markerKey(conversationID))
        enforceCap()
    }

    /// Drop the marker for a conversation the user actually deleted. This is
    /// the ONLY deletion path — absence from a fetch is not one.
    func markDeleted(_ conversationID: UUID) {
        guard markers.removeValue(forKey: conversationID) != nil else { return }
        defaults.removeObject(forKey: Self.markerKey(conversationID))
    }

    // MARK: - Cap

    /// Keep the marker set bounded, dropping the OLDEST first — the least
    /// likely to still matter, since an old marker's conversation is far down a
    /// list sorted by activity.
    private func enforceCap() {
        guard markers.count > Self.maxMarkers else { return }
        let doomed = markers
            .sorted { $0.value < $1.value }
            .prefix(markers.count - Self.maxMarkers)
        for (id, _) in doomed {
            markers.removeValue(forKey: id)
            defaults.removeObject(forKey: Self.markerKey(id))
        }
    }

    private static func markerKey(_ conversationID: UUID) -> String {
        Constants.conversationReadStatePrefix + conversationID.uuidString
    }

    // MARK: - Testing

    /// Test-only reset hook. Clears the cache AND the backing keys so test
    /// order cannot leak state through the shared instance.
    static func _resetForTesting() {
        let store = shared
        store.markers.removeAll()
        store.epoch = nil
        for key in store.defaults.dictionaryRepresentation().keys
        where key.hasPrefix(Constants.conversationReadStatePrefix) {
            store.defaults.removeObject(forKey: key)
        }
        store.defaults.removeObject(forKey: Constants.conversationReadStateEpochKey)
    }
}
