// SPDX-License-Identifier: Apache-2.0

// Conduck
// PendingRetryStore.swift
//
// The retry record deliberately carries only the information needed to recover
// the exact capture. The optional destination is additive: records written by
// older releases decode as Chat, while Work captures can never fall through to
// a gateway retry lane.
//
// Storage layout (App Groups, shared with Watch + Widget targets):
//   pending_retry_audio_<destination>_<id>.m4a (raw AAC bytes; `.complete`)
//   pending_retry_work_image_<id>.bin      (optional Work screenshot bytes)
//   UserDefaults[metadataKey]              (JSON-encoded `PendingRetryMetadata`)
//
// 10-minute TTL enforced by `PendingRetryMetadata.isExpired`. Expired entries
// are purged lazily on read + eagerly on launch via `cleanupExpired()`.

import Foundation
import Darwin

enum PendingRetryDestination: String, Codable, CaseIterable, Sendable {
    case chat
    case work
}

/// Metadata describing a pending retry audio file. Destination is optional on
/// the wire for backwards compatibility; nil means Chat for every record made
/// before Work existed.
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

    /// Where a recovered transcript must land. Optional so previously encoded
    /// six-field records remain decodable without a migration.
    let destination: PendingRetryDestination?

    var resolvedDestination: PendingRetryDestination { destination ?? .chat }

    init(
        id: UUID,
        createdAt: Date,
        audioFileURL: URL,
        preferredLanguage: String?,
        attemptCount: Int,
        lastErrorCode: Int?,
        destination: PendingRetryDestination? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.audioFileURL = audioFileURL
        self.preferredLanguage = preferredLanguage
        self.attemptCount = attemptCount
        self.lastErrorCode = lastErrorCode
        self.destination = destination
    }

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

    private var lockFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Constants.appGroupID)?
            .appendingPathComponent("pending_retry.lock")
    }

    /// Legacy fixed path retained only so a pending Chat retry written by an
    /// older build survives the upgrade into id-scoped storage.
    private var legacyAudioFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Constants.appGroupID)?
            .appendingPathComponent("pending_retry_audio.m4a")
    }

    private func audioFileURL(
        for id: UUID,
        destination: PendingRetryDestination
    ) -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Constants.appGroupID)?
            .appendingPathComponent(
                "pending_retry_audio_\(destination.rawValue)_\(id.uuidString).m4a"
            )
    }

    /// Transitional id-scoped path used by development builds before the
    /// destination became part of the recoverable filename.
    private func preDestinationAudioFileURL(for id: UUID) -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Constants.appGroupID)?
            .appendingPathComponent("pending_retry_audio_\(id.uuidString).m4a")
    }

    private func workImageURL(for id: UUID) -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Constants.appGroupID)?
            .appendingPathComponent("pending_retry_work_image_\(id.uuidString).bin")
    }

    /// App Groups UserDefaults handle (shared with Widget / Watch — though
    /// only the main iOS app currently writes to this key).
    private var defaults: any DefaultsStore {
        SettingsDependencies.processDefault.defaults
    }

    // MARK: - Public API

    /// Save audio bytes + metadata for a later retry. Overwrites any prior
    /// pending retry (V1 supports a single slot — multi-pending queue is
    /// out of scope).
    /// - Throws: file-system errors writing to App Groups container.
    func save(
        audioData: Data,
        metadata: PendingRetryMetadata,
        workImageData: Data? = nil
    ) async throws {
        guard let url = audioFileURL(
            for: metadata.id,
            destination: metadata.resolvedDestination
        ) else {
            throw AppError.settingsLoadFailed
        }
        let defaults = defaults
        try withExclusiveLock {
            // `.complete` file protection: the file is unreadable while the
            // device is locked. A failure propagates so the guard never claims
            // an unavailable recording was saved.
            try audioData.write(to: url, options: [.atomic, .completeFileProtection])

            // Audio and Work screenshot are tied to the retry identity, not
            // shared fixed filenames. Metadata is committed LAST as the pointer.
            // The process lock makes that transaction indivisible across the
            // main app and concurrent App Intent hosts.
            if metadata.resolvedDestination == .work,
               let workImageData,
               !workImageData.isEmpty,
               let imageURL = workImageURL(for: metadata.id) {
                try? workImageData.write(
                    to: imageURL,
                    options: [.atomic, .completeFileProtection]
                )
            }
            let encoded = try JSONEncoder().encode(metadata)
            defaults.set(encoded, forKey: Self.metadataKey)
            _ = defaults.synchronize()
            removeRetryFiles(except: metadata.id)
        }
    }

    /// Load the currently-pending audio + metadata, if any. Returns nil if
    /// no retry is pending, the metadata is expired, or the audio/metadata
    /// are out of sync.
    func load() async -> (
        audioData: Data,
        metadata: PendingRetryMetadata,
        workImageData: Data?
    )? {
        let defaults = defaults
        return try? withExclusiveLock {
            guard let metadata = decodedMetadata(from: defaults) else { return nil }
            guard !metadata.isExpired else {
                clearLocked(metadata: metadata, defaults: defaults)
                return nil
            }

            guard let scopedURL = audioFileURL(
                for: metadata.id,
                destination: metadata.resolvedDestination
            ) else { return nil }
            let selectedURL: URL
            if FileManager.default.fileExists(atPath: scopedURL.path) {
                selectedURL = scopedURL
            } else if let transitionalURL = preDestinationAudioFileURL(for: metadata.id),
                      FileManager.default.fileExists(atPath: transitionalURL.path) {
                selectedURL = transitionalURL
            } else if let legacyAudioFileURL,
                      FileManager.default.fileExists(atPath: legacyAudioFileURL.path),
                      metadata.resolvedDestination == .chat {
                selectedURL = legacyAudioFileURL
            } else {
                clearLocked(metadata: metadata, defaults: defaults)
                return nil
            }

            guard let audioData = try? Data(contentsOf: selectedURL) else {
                clearLocked(metadata: metadata, defaults: defaults)
                return nil
            }
            let imageData: Data?
            if metadata.resolvedDestination == .work,
               let imageURL = workImageURL(for: metadata.id) {
                imageData = try? Data(contentsOf: imageURL)
            } else {
                imageData = nil
            }
            return (audioData, metadata, imageData)
        }
    }

    /// Cheap pre-check for UI (avoids loading the full audio just to test
    /// for presence of a retry). Mirrors `load()`'s expiry behavior.
    func hasPending() async -> Bool {
        let defaults = defaults
        return (try? withExclusiveLock {
            guard let metadata = decodedMetadata(from: defaults) else { return false }
            if metadata.isExpired {
                clearLocked(metadata: metadata, defaults: defaults)
                return false
            }
            return true
        }) ?? false
    }

    /// The `AppError.errorCode` that armed the current pending retry, if any —
    /// a metadata-only read (no audio load) for the home-screen retry card's
    /// Troubleshoot affordance. Mirrors `hasPending()`'s expiry behavior so the
    /// card and its Troubleshoot button never disagree; nil when nothing is
    /// pending, the entry is expired, or the original failure carried no code.
    func pendingErrorCode() async -> Int? {
        let defaults = defaults
        return try? withExclusiveLock {
            guard let metadata = decodedMetadata(from: defaults) else { return nil }
            if metadata.isExpired {
                clearLocked(metadata: metadata, defaults: defaults)
                return nil
            }
            return metadata.lastErrorCode
        }
    }

    /// Metadata-only Diagnostics snapshot — `createdAt` (remaining-TTL copy),
    /// the arming `lastErrorCode`, and whether the audio file still EXISTS
    /// (metadata can orphan if the file is deleted out from under us; the row
    /// must not promise a retry that would immediately fail). No audio load.
    /// Mirrors `hasPending()`'s lazy-expiry purge; nil = nothing pending.
    func diagnosticSnapshot() async -> (createdAt: Date, lastErrorCode: Int?, audioFileExists: Bool)? {
        let defaults = defaults
        return try? withExclusiveLock {
            guard let metadata = decodedMetadata(from: defaults) else { return nil }
            if metadata.isExpired {
                clearLocked(metadata: metadata, defaults: defaults)
                return nil
            }
            let scopedExists = audioFileURL(
                for: metadata.id,
                destination: metadata.resolvedDestination
            )
                .map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            let transitionalExists = preDestinationAudioFileURL(for: metadata.id)
                .map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            let legacyExists = metadata.resolvedDestination == .chat
                && (legacyAudioFileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
            return (
                metadata.createdAt,
                metadata.lastErrorCode,
                scopedExists || transitionalExists || legacyExists
            )
        }
    }

    /// Purge any pending retry whose metadata's `isExpired` is true. Called
    /// from `ConduckApp` on launch (privacy: don't leave stale audio
    /// sitting in App Groups storage indefinitely).
    func cleanupExpired() async {
        let defaults = defaults
        _ = try? withExclusiveLock {
            guard let metadata = decodedMetadata(from: defaults), metadata.isExpired else { return }
            clearLocked(metadata: metadata, defaults: defaults)
        }
    }

    /// Clears only the capture the caller actually completed. A newer capture
    /// that won the single retry slot while this caller was suspended is left
    /// untouched.
    @discardableResult
    func clear(ifCurrentID id: UUID) async -> Bool {
        let defaults = defaults
        return (try? withExclusiveLock {
            guard let metadata = decodedMetadata(from: defaults), metadata.id == id else {
                return false
            }
            clearLocked(metadata: metadata, defaults: defaults)
            return true
        }) ?? false
    }

    /// Updates diagnostics for a retry only while it still owns the slot. This
    /// never re-writes audio and can therefore never resurrect an older capture
    /// over a newer Chat/Work arm.
    @discardableResult
    func updateAttemptIfCurrent(id: UUID, lastErrorCode: Int?) async -> Bool {
        let defaults = defaults
        return (try? withExclusiveLock {
            guard let current = decodedMetadata(from: defaults), current.id == id else {
                return false
            }
            let updated = PendingRetryMetadata(
                id: current.id,
                createdAt: current.createdAt,
                audioFileURL: current.audioFileURL,
                preferredLanguage: current.preferredLanguage,
                attemptCount: current.attemptCount + 1,
                lastErrorCode: lastErrorCode,
                destination: current.destination
            )
            defaults.set(try JSONEncoder().encode(updated), forKey: Self.metadataKey)
            _ = defaults.synchronize()
            return true
        }) ?? false
    }

    /// Explicitly clear the pending retry (e.g., after a successful retry,
    /// or on Settings → "Clear pending recording"). Deletes both the audio
    /// file and the metadata entry.
    func clear() async {
        let defaults = defaults
        _ = try? withExclusiveLock {
            defaults.removeObject(forKey: Self.metadataKey)
            _ = defaults.synchronize()
            removeRetryFiles(except: nil)
        }
    }

    private func decodedMetadata(from defaults: any DefaultsStore) -> PendingRetryMetadata? {
        // Refresh the App-Group domain after acquiring the cross-process lock;
        // another intent host may have committed the slot since this process's
        // UserDefaults cache was last read.
        _ = defaults.synchronize()
        if let data = defaults.data(forKey: Self.metadataKey),
           let metadata = try? JSONDecoder().decode(PendingRetryMetadata.self, from: data) {
            return metadata
        }
        return recoverNewestOrphan(from: defaults)
    }

    /// A process can die after the protected id-scoped audio reaches disk but
    /// before UserDefaults commits its pointer. Destination is encoded in the
    /// filename specifically so this state is recoverable without guessing or
    /// deleting private words. The newest complete audio becomes the single
    /// slot; older candidates remain untouched until a later successful save or
    /// explicit clear, so recovery itself is non-destructive.
    private func recoverNewestOrphan(
        from defaults: any DefaultsStore
    ) -> PendingRetryMetadata? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Constants.appGroupID
        ), let children = try? FileManager.default.contentsOfDirectory(
            at: container,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let candidates: [(URL, UUID, PendingRetryDestination, Date)] = children.compactMap { url in
            let name = url.lastPathComponent
            guard name.hasSuffix(".m4a"),
                  let destination = PendingRetryDestination.allCases.first(where: {
                      name.hasPrefix("pending_retry_audio_\($0.rawValue)_")
                  }) else { return nil }
            let prefix = "pending_retry_audio_\(destination.rawValue)_"
            let rawID = String(name.dropFirst(prefix.count).dropLast(4))
            guard let id = UUID(uuidString: rawID),
                  let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]
                  ), values.isRegularFile == true else { return nil }
            return (url, id, destination, values.contentModificationDate ?? .distantPast)
        }
        guard let newest = candidates.max(by: { $0.3 < $1.3 }) else { return nil }

        let metadata = PendingRetryMetadata(
            id: newest.1,
            createdAt: newest.3,
            audioFileURL: newest.0,
            preferredLanguage: nil,
            attemptCount: 1,
            lastErrorCode: nil,
            destination: newest.2
        )
        guard let encoded = try? JSONEncoder().encode(metadata) else { return nil }
        defaults.set(encoded, forKey: Self.metadataKey)
        _ = defaults.synchronize()
        return metadata
    }

    private func clearLocked(
        metadata: PendingRetryMetadata,
        defaults: any DefaultsStore
    ) {
        guard decodedMetadata(from: defaults)?.id == metadata.id else { return }
        defaults.removeObject(forKey: Self.metadataKey)
        _ = defaults.synchronize()
        if let audioURL = audioFileURL(
            for: metadata.id,
            destination: metadata.resolvedDestination
        ) {
            try? FileManager.default.removeItem(at: audioURL)
        }
        if let transitionalURL = preDestinationAudioFileURL(for: metadata.id) {
            try? FileManager.default.removeItem(at: transitionalURL)
        }
        if let imageURL = workImageURL(for: metadata.id) {
            try? FileManager.default.removeItem(at: imageURL)
        }
        if metadata.resolvedDestination == .chat, let legacyAudioFileURL {
            try? FileManager.default.removeItem(at: legacyAudioFileURL)
        }
    }

    /// `actor` serialization ends at the process boundary. App Intents and the
    /// foreground app can both touch the App-Group slot, so a tiny advisory file
    /// lock wraps every metadata/payload transaction as one cross-process unit.
    private func withExclusiveLock<T>(_ operation: () throws -> T) throws -> T {
        guard let lockFileURL else { throw AppError.settingsLoadFailed }
        let descriptor = Darwin.open(
            lockFileURL.path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw AppError.settingsLoadFailed }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw AppError.settingsLoadFailed
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func removeRetryFiles(except retainedID: UUID?) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Constants.appGroupID
        ), let children = try? FileManager.default.contentsOfDirectory(
            at: container,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        let retainedAudioNames: Set<String> = retainedID.map { id in
            Set(PendingRetryDestination.allCases.map {
                "pending_retry_audio_\($0.rawValue)_\(id.uuidString).m4a"
            })
        } ?? []
        let retainedImageName = retainedID.map { "pending_retry_work_image_\($0.uuidString).bin" }
        for child in children {
            let name = child.lastPathComponent
            let isRetryFile = name == "pending_retry_audio.m4a"
                || name.hasPrefix("pending_retry_audio_")
                || name.hasPrefix("pending_retry_work_image_")
            guard isRetryFile,
                  !retainedAudioNames.contains(name),
                  name != retainedImageName else { continue }
            try? FileManager.default.removeItem(at: child)
        }
    }
}
