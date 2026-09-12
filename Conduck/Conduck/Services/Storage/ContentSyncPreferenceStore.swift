// SPDX-License-Identifier: Apache-2.0

// One account preference, independently delivered by KVS and the paired phone.
// A versioned value orders both transports so an old queued ON cannot overwrite
// a newer OFF. Absence is not a deletion: preserve the last known choice, and
// synthesize ON only when no valid value has ever arrived. Never publish that
// synthesized default. KVS is eventually delivered, not a first-launch barrier.
//
// This synchronous store is available before ANY content database is opened,
// including in headless intents and on Watch. Every transaction refreshes the
// App Group policy file under a distinct cross-process lock. Defaults are a
// migration source and best-effort cache, never a persistence admission gate.
// No content, credentials or account identifiers enter this preference or its
// notifications.

import Foundation

nonisolated struct ContentSyncPreference: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    let enabled: Bool
    let revision: Int64
    let identifier: UUID

    var isValid: Bool { schemaVersion == 1 && revision >= 0 && revision < Int64.max }

    /// Clock-derived revision advances past every value this device has seen.
    /// Concurrent revisions converge deterministically; OFF wins an exact tie.
    func isNewer(than other: Self) -> Bool {
        if revision != other.revision { return revision > other.revision }
        if enabled != other.enabled { return !enabled }
        return identifier.uuidString > other.identifier.uuidString
    }

    static func decode(_ data: Data?) -> Self? {
        guard let data, let value = try? JSONDecoder().decode(Self.self, from: data),
              value.isValid else { return nil }
        return value
    }
}

extension Notification.Name {
    nonisolated static let contentSyncPreferenceDidChange = Notification.Name("contentSyncPreferenceDidChange")
}

nonisolated final class ContentSyncPreferenceStore: @unchecked Sendable {
    static let shared = ContentSyncPreferenceStore()
    static let storageKey = "contentSync.preference.v1"
    static let watchMessageKey = "contentSyncPreference"
    private static let pendingPublicationKey = "contentSync.pendingPublication.v1"

    enum Failure: Error { case storageUnavailable, revisionExhausted, invalidSnapshot }

    private struct Snapshot: Codable, Equatable {
        var schemaVersion = 1
        var current: ContentSyncPreference?
        var pending: ContentSyncPreference?

        var isValid: Bool {
            schemaVersion == 1 && (current?.isValid ?? true) && (pending?.isValid ?? true)
                && (pending == nil || pending == current)
        }
    }

    // Multiple SettingsManager instances may share one dependency bundle. This
    // lock also serializes them in tests, where no filesystem lock is installed.
    private static let processLock = NSRecursiveLock()
    private let defaults: any DefaultsStore
    private let ubiquitous: any UbiquitousStore
    private let policyLock: (any ContentSyncPolicyLock)?

    init(dependencies: SettingsDependencies = .processDefault) {
        defaults = dependencies.defaults
        ubiquitous = dependencies.ubiquitous
        policyLock = dependencies.contentSyncPolicyLock
        dependencies.changes.observe { [weak self] change in
            guard change.reason.deliversRemoteValues,
                  change.changedKeys.contains(Self.storageKey) else { return }
            _ = self?.currentPreference()
        }
    }

    /// Failure to read policy cannot grant permission to start a mirror.
    var isEnabled: Bool {
        (try? read().enabled) ?? false
    }

    /// Lifecycle code distinguishes an unreadable policy from a deliberate OFF.
    /// The conservative Bool above is only suitable for admitting a transfer.
    func readEnabled() throws -> Bool {
        try read().enabled
    }

    func currentPreference() -> ContentSyncPreference? {
        try? read().value
    }

    /// Persist the explicit local choice before announcing it. Writes to KVS
    /// are not gated by the iCloud Drive identity token: that token does not
    /// describe KVS availability, and KVS can retain writes until sign-in.
    @discardableResult
    func setEnabled(_ enabled: Bool) throws -> ContentSyncPreference {
        let value = try transaction {
            let current = try reconcileLocked().snapshot.current
            let milliseconds = Date().timeIntervalSince1970 * 1_000
            let clock = Int64(max(0, min(milliseconds, Double(Int64.max / 2))))
            let revision = max(clock, (current?.revision ?? 0) + 1)
            let next = ContentSyncPreference(enabled: enabled, revision: revision, identifier: UUID())
            guard next.isValid else { throw Failure.revisionExhausted }
            let data = try JSONEncoder().encode(next)
            try saveSnapshotLocked(Snapshot(current: next, pending: next))
            ubiquitous.set(data, forKey: Self.storageKey)
            return next
        }
        announceChange()
        return value
    }

    /// Used by the Watch courier. Never re-publish inbound values to KVS and
    /// never let an old queue delivery replace a newer durable preference.
    @discardableResult
    func adopt(_ incoming: ContentSyncPreference) -> Bool {
        guard incoming.isValid else { return false }
        do {
            var didChange = false
            let changed = try transaction {
                let result = try reconcileLocked()
                didChange = result.changed
                let current = result.snapshot.current
                guard current == nil || incoming.isNewer(than: current!) else { return false }
                try saveSnapshotLocked(Snapshot(current: incoming, pending: nil))
                didChange = true
                return true
            }
            if didChange { announceChange() }
            return changed
        } catch { return false }
    }

    private func read() throws -> (value: ContentSyncPreference?, enabled: Bool) {
        let result = try transaction { try reconcileLocked() }
        if result.changed { announceChange() }
        return (result.snapshot.current, result.snapshot.current?.enabled ?? true)
    }

    private func reconcileLocked() throws -> (snapshot: Snapshot, changed: Bool) {
        let original = try loadSnapshotLocked()
        var snapshot = original
        let local = snapshot.current
        let remote = ContentSyncPreference.decode(ubiquitous.data(forKey: Self.storageKey))
        if let remote, local == nil || remote.isNewer(than: local!) {
            snapshot.current = remote
        }
        if let pending = snapshot.pending, let winner = snapshot.current,
           winner.isNewer(than: pending) {
            snapshot.pending = nil
        }
        if snapshot != original { try saveSnapshotLocked(snapshot) }

        // Publish only AFTER the current value and retry intent are committed.
        // An initial KVS download can replace a locally queued write; the file
        // retains that explicit choice across process death until it arrives.
        if let pending = snapshot.pending, pending == snapshot.current, pending != remote {
            ubiquitous.set(try JSONEncoder().encode(pending), forKey: Self.storageKey)
        }
        return (snapshot, original.current != snapshot.current)
    }

    private func loadSnapshotLocked() throws -> Snapshot {
        if let persistence = policyLock as? any ContentSyncPolicyPersistence,
           let data = try persistence.readSnapshot() {
            guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
                  snapshot.isValid else { throw Failure.invalidSnapshot }
            return snapshot
        }
        // One-time migration, or the isolated in-memory test dependency. A
        // preferences flush is not a validity test for values already readable.
        defaults.synchronize()
        let current = ContentSyncPreference.decode(defaults.data(forKey: Self.storageKey))
        let pending = ContentSyncPreference.decode(defaults.data(forKey: Self.pendingPublicationKey))
        let snapshot = Snapshot(current: current, pending: pending == current ? pending : nil)
        if current != nil, policyLock is any ContentSyncPolicyPersistence {
            try saveSnapshotLocked(snapshot)
        }
        return snapshot
    }

    private func saveSnapshotLocked(_ snapshot: Snapshot) throws {
        guard snapshot.isValid else { throw Failure.invalidSnapshot }
        if let persistence = policyLock as? any ContentSyncPolicyPersistence {
            try persistence.writeSnapshot(JSONEncoder().encode(snapshot))
        }
        // Existing settings readers can retain this cache, but its asynchronous
        // flush result cannot invalidate an already committed policy file.
        defaults.set(try snapshot.current.map { try JSONEncoder().encode($0) }, forKey: Self.storageKey)
        defaults.set(try snapshot.pending.map { try JSONEncoder().encode($0) }, forKey: Self.pendingPublicationKey)
        defaults.synchronize()
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        if let policyLock {
            guard policyLock.lock() else { throw Failure.storageUnavailable }
        }
        defer { policyLock?.unlock() }
        return try body()
    }

    private func announceChange() {
        // Deliver after all locks are released: observers are allowed to read
        // the preference immediately or initiate a database transition.
        NotificationCenter.default.post(name: .contentSyncPreferenceDidChange, object: self)
    }
}
