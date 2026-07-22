// Conduck
// PendingRetryStore.swift
//
// The `PendingRetryMetadata` shape is locked and deliberately omits
// mode/context/targetLanguage/emojiStyle/polishEnabled/vocabularyJSON
// fields — Conduck V1 has none of those concepts.
//
// Storage layout (App Groups, shared with Watch + Widget targets):
//   <appGroupID>/pending_retry_audio.m4a   (raw AAC bytes; file protection `.complete`)
//   UserDefaults[metadataKey]              (JSON-encoded `PendingRetryMetadata`)
//
// 10-minute TTL enforced by `PendingRetryMetadata.isExpired`. Expired entries
// are purged lazily on read + eagerly on launch via `cleanupExpired()`.

import Foundation

/// Metadata describing a pending retry audio file. Locked Codable shape —
/// explicitly does NOT carry mode, emoji, polish, vocabulary, or context
/// fields (Conduck V1 has no such concepts).
struct PendingRetryMetadata: Codable, Sendable {
    /// Stable identifier for this pending retry. Useful for logging /
    /// diagnostics; not a primary key in any storage layer.
    let id: UUID

    /// Wall-clock time the retry was queued. TTL check uses this against
    /// `Date()` at read time.
    let createdAt: Date

    /// Path to the audio file in App Groups container. Caller responsible
    /// for verifying the file still exists before retrying.
    let audioFileURL: URL

    /// Preferred STT language hint at the time of original failure (so the
    /// retry uses the same language even if the user has since changed it).
    let preferredLanguage: String?

    /// Number of times the retry has been attempted (including the original
    /// failing call that triggered the save). Incremented by callers; the
    /// store is shape-only here.
    let attemptCount: Int

    /// The `AppError.errorCode` that caused this pending retry. Diagnostic
    /// only — used to filter / classify pending retries in UI; never to
    /// branch the retry logic itself.
    let lastErrorCode: Int?

    /// 10-minute TTL — anything older is considered stale and should be
    /// purged by `cleanupExpired()`.
    var isExpired: Bool {
        Date().timeIntervalSince(createdAt) > 600
    }
}

/// Persists a single pending audio retry across app launches, so a network
/// failure during in-app transcription leaves the user with a retry button
/// rather than a lost recording. Singleton actor — concurrent callers
/// serialize on the actor.
actor PendingRetryStore {
    static let shared = PendingRetryStore()

    private init() { }

    // MARK: - Storage Locations

    /// Key under which metadata is stored in App Groups UserDefaults.
    /// Local to this store; not promoted to `Constants` because no other
    /// subsystem references it (single producer + single consumer).
    private static let metadataKey = "pending_retry_metadata"

    /// URL of the audio file inside the App Groups container.
    /// Nil only if the App Group is mis-provisioned (entitlement missing).
    private var audioFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Constants.appGroupID)?
            .appendingPathComponent("pending_retry_audio.m4a")
    }

    /// App Groups UserDefaults handle (shared with Widget / Watch — though
    /// only the main iOS app currently writes to this key).
    private var defaults: UserDefaults? {
        UserDefaults(suiteName: Constants.appGroupID)
    }

    // MARK: - Public API

    /// Save audio bytes + metadata for a later retry. Overwrites any prior
    /// pending retry (V1 supports a single slot — multi-pending queue is
    /// out of scope).
    /// - Throws: file-system errors writing to App Groups container.
    func save(audioData: Data, metadata: PendingRetryMetadata) async throws {
        guard let url = audioFileURL, let defaults = defaults else {
            throw AppError.settingsLoadFailed
        }

        // `.complete` file protection: file is unreadable while device locked.
        // Tighter than `.completeUntilFirstUserAuthentication` because
        // pending retries are user-initiated foreground actions; the user is
        // already past first unlock by the time we save.
        try audioData.write(to: url, options: [.atomic, .completeFileProtection])

        let encoded = try JSONEncoder().encode(metadata)
        defaults.set(encoded, forKey: Self.metadataKey)
    }

    /// Load the currently-pending audio + metadata, if any. Returns nil if
    /// no retry is pending, the metadata is expired, or the audio/metadata
    /// are out of sync.
    func load() async -> (audioData: Data, metadata: PendingRetryMetadata)? {
        guard let url = audioFileURL, let defaults = defaults else { return nil }

        guard let metadataData = defaults.data(forKey: Self.metadataKey),
              let metadata = try? JSONDecoder().decode(PendingRetryMetadata.self, from: metadataData) else {
            return nil
        }

        if metadata.isExpired {
            await clear()
            return nil
        }

        guard let audioData = try? Data(contentsOf: url) else {
            // Metadata orphaned (file deleted out from under us) — purge.
            await clear()
            return nil
        }

        return (audioData, metadata)
    }

    /// Cheap pre-check for UI (avoids loading the full audio just to test
    /// for presence of a retry). Mirrors `load()`'s expiry behavior.
    func hasPending() async -> Bool {
        guard let defaults = defaults,
              let metadataData = defaults.data(forKey: Self.metadataKey),
              let metadata = try? JSONDecoder().decode(PendingRetryMetadata.self, from: metadataData) else {
            return false
        }

        if metadata.isExpired {
            await clear()
            return false
        }

        return true
    }

    /// The `AppError.errorCode` that armed the current pending retry, if any —
    /// a metadata-only read (no audio load) for the home-screen retry card's
    /// Troubleshoot affordance. Mirrors `hasPending()`'s expiry behavior so the
    /// card and its Troubleshoot button never disagree; nil when nothing is
    /// pending, the entry is expired, or the original failure carried no code.
    func pendingErrorCode() async -> Int? {
        guard let defaults = defaults,
              let metadataData = defaults.data(forKey: Self.metadataKey),
              let metadata = try? JSONDecoder().decode(PendingRetryMetadata.self, from: metadataData) else {
            return nil
        }

        if metadata.isExpired {
            await clear()
            return nil
        }

        return metadata.lastErrorCode
    }

    /// Metadata-only Diagnostics snapshot — `createdAt` (remaining-TTL copy),
    /// the arming `lastErrorCode`, and whether the audio file still EXISTS
    /// (metadata can orphan if the file is deleted out from under us; the row
    /// must not promise a retry that would immediately fail). No audio load.
    /// Mirrors `hasPending()`'s lazy-expiry purge; nil = nothing pending.
    func diagnosticSnapshot() async -> (createdAt: Date, lastErrorCode: Int?, audioFileExists: Bool)? {
        guard let defaults = defaults,
              let metadataData = defaults.data(forKey: Self.metadataKey),
              let metadata = try? JSONDecoder().decode(PendingRetryMetadata.self, from: metadataData) else {
            return nil
        }
        if metadata.isExpired {
            await clear()
            return nil
        }
        let exists = audioFileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        return (metadata.createdAt, metadata.lastErrorCode, exists)
    }

    /// Purge any pending retry whose metadata's `isExpired` is true. Called
    /// from `ConduckApp` on launch (privacy: don't leave stale audio
    /// sitting in App Groups storage indefinitely).
    func cleanupExpired() async {
        guard let defaults = defaults,
              let metadataData = defaults.data(forKey: Self.metadataKey),
              let metadata = try? JSONDecoder().decode(PendingRetryMetadata.self, from: metadataData) else {
            return
        }
        if metadata.isExpired {
            await clear()
        }
    }

    /// Explicitly clear the pending retry (e.g., after a successful retry,
    /// or on Settings → "Clear pending recording"). Deletes both the audio
    /// file and the metadata entry.
    func clear() async {
        if let url = audioFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        defaults?.removeObject(forKey: Self.metadataKey)
    }
}
