// SPDX-License-Identifier: Apache-2.0

// Conduck
// PendingRetryStore.swift
//
// Every capture whose words are still owed, held as a QUEUE keyed by capture
// id. One entry per capture — its own audio file, its own optional screenshot,
// its own metadata row — and no entry is ever displaced by another. That is the
// whole shape: a second capture arming while a first is unfinished is the
// ordinary case (the composer mic, a Shortcut, the menu bar and a headless
// intent host all reach this store, some of them from other processes), and a
// single overwriting slot answers it by deleting a recording that may exist
// nowhere else. Arming appends; completing removes exactly the entry that
// completed.
//
// The retry record deliberately carries only the information needed to recover
// the exact capture. Every field beyond the original six is OPTIONAL on the
// wire, and a record written by an older release decodes them as nil: the
// destination decodes as Chat, so a Work capture can never fall through to a
// gateway retry lane; the transcript decodes as "the words are still owed"; and
// the publication state decodes as "unknown", which a Work recovery must treat
// conservatively rather than as evidence either way. That is the only shape
// change a record may ever take — a required field would strand every recording
// already parked on a device mid-upgrade.
//
// Storage layout (App Groups, shared with Watch + Widget targets):
//   pending_retry_audio_<destination>_<id>.m4a (compressed bytes; `.complete`)
//   pending_retry_work_image_<id>.bin          (optional Work screenshot bytes)
//   UserDefaults["pending_retry_queue"]        (JSON `[PendingRetryMetadata]`)
//   UserDefaults["pending_retry_metadata"]     (the single-slot pointer an
//                                               older release wrote; READ and
//                                               folded into the queue on first
//                                               access, never deleted unread)
//
// EXPIRY is a budget for a TRANSCRIPTION, not for a recording. Ten minutes is
// the right window for words that can be bought from a provider again, so it
// governs Chat retries and Work captures whose recording is already a card on
// the desk. It does not govern a Work capture whose recording the desk never
// took — `.phaseOneFailed`, and the UNKNOWN verdict an older record carries:
// those bytes are the only copy of what somebody said, and they leave only when
// publication succeeds or the person discards them.

import Foundation
import Darwin

nonisolated enum PendingRetryDestination: String, Codable, CaseIterable, Sendable {
    case chat
    case work
}

/// What is known about a Work capture's PHASE ONE — the publication that puts
/// the recording on the desk as a playable card before speech recognition is
/// attempted — at the moment its retry was armed.
///
/// Optional on the wire: a record written before this existed decodes as nil,
/// and nil means UNKNOWN. A recovery must never read it as proof that phase one
/// landed, because the two states it cannot distinguish call for opposite acts —
/// republishing a recording the desk never held, and honouring a card a person
/// deleted while recognition was in flight.
nonisolated enum PendingRetryPublicationState: String, Codable, Sendable {
    /// The recording is a card on the desk under the capture id. An id that
    /// names no card later is therefore a deletion, and the words belong beside
    /// it rather than on a resurrected recording.
    case published
    /// The desk refused the recording. These bytes are the only copy of it, so
    /// a recovery republishes the card under the capture id before attaching.
    case phaseOneFailed
}

/// Metadata describing one queued capture. Destination is optional on the wire
/// for backwards compatibility; nil means Chat for every record made before
/// Work existed.
nonisolated struct PendingRetryMetadata: Codable, Sendable {
    /// Stable identifier for this capture. It is the queue's KEY: the audio
    /// file, the screenshot, the desk card a Work capture publishes and the
    /// record recovered hours later all name themselves with it.
    let id: UUID

    /// Wall-clock time the retry was queued. The expiry check uses this against
    /// `Date()` at read time, for the records expiry governs at all.
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

    /// The words this capture already produced, when recognition succeeded and
    /// only the write onto the card failed. Optional for the same reason
    /// `destination` is: records encoded before it existed decode as nil.
    ///
    /// Present means the provider has already been paid for these bytes, so a
    /// recovery attaches these words instead of buying the same answer twice.
    /// Nil means the words are still owed and the recovery must transcribe.
    let transcript: String?

    /// What is known about the recording's own publication, so a recovery can
    /// tell "the desk never held this" from "somebody deleted it". Optional and
    /// nil-means-unknown; see `PendingRetryPublicationState`.
    let publicationState: PendingRetryPublicationState?

    var resolvedDestination: PendingRetryDestination { destination ?? .chat }

    init(
        id: UUID,
        createdAt: Date,
        audioFileURL: URL,
        preferredLanguage: String?,
        attemptCount: Int,
        lastErrorCode: Int?,
        destination: PendingRetryDestination? = nil,
        transcript: String? = nil,
        publicationState: PendingRetryPublicationState? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.audioFileURL = audioFileURL
        self.preferredLanguage = preferredLanguage
        self.attemptCount = attemptCount
        self.lastErrorCode = lastErrorCode
        self.destination = destination
        self.transcript = transcript
        self.publicationState = publicationState
    }

    /// How long a capture may wait for a TRANSCRIPTION it can buy again.
    static let transcriptionRetryTTL: TimeInterval = 600

    /// True when the only thing this record protects is a transcription, so the
    /// TTL above may retire it.
    ///
    /// A Chat capture's words are the artifact and the provider can produce
    /// them again; a Work capture that reports `.published` has its recording
    /// on the desk already. Every other Work record — a publication the desk
    /// refused, and the UNKNOWN verdict an older record carries — holds bytes
    /// that exist nowhere else, and a clock is not a reason to delete them.
    var isExemptFromExpiry: Bool {
        resolvedDestination == .work && publicationState != .published
    }

    var isExpired: Bool { isExpired(at: Date()) }

    func isExpired(at now: Date) -> Bool {
        guard !isExemptFromExpiry else { return false }
        return now.timeIntervalSince(createdAt) > Self.transcriptionRetryTTL
    }

    /// The same record with one more attempt and a fresh diagnostic code. Every
    /// other field is carried forward verbatim: dropping the words or the
    /// publication verdict here would silently cost a later recovery a provider
    /// round trip, or leave it unable to tell a refused publication from a
    /// deleted card.
    func recordingAttempt(lastErrorCode: Int?) -> PendingRetryMetadata {
        PendingRetryMetadata(
            id: id,
            createdAt: createdAt,
            audioFileURL: audioFileURL,
            preferredLanguage: preferredLanguage,
            attemptCount: attemptCount + 1,
            lastErrorCode: lastErrorCode,
            destination: destination,
            transcript: transcript,
            publicationState: publicationState
        )
    }

    /// The same record carrying what a process OBSERVED about this capture. A
    /// nil argument means "keep what is already there", so a caller that knows
    /// only one of the two facts cannot erase the other.
    func recording(
        transcript newTranscript: String?,
        publicationState newState: PendingRetryPublicationState?
    ) -> PendingRetryMetadata {
        PendingRetryMetadata(
            id: id,
            createdAt: createdAt,
            audioFileURL: audioFileURL,
            preferredLanguage: preferredLanguage,
            attemptCount: attemptCount,
            lastErrorCode: lastErrorCode,
            destination: destination,
            transcript: newTranscript ?? transcript,
            publicationState: newState ?? publicationState
        )
    }
}

/// One queued capture as a retry surface receives it — metadata plus the bytes
/// that were parked with it.
nonisolated struct PendingRetryEntry: Sendable {
    let audioData: Data
    let metadata: PendingRetryMetadata
    let workImageData: Data?

    init(audioData: Data, metadata: PendingRetryMetadata, workImageData: Data?) {
        self.audioData = audioData
        self.metadata = metadata
        self.workImageData = workImageData
    }
}

/// What a Work recovery is handed, reduced to the two things it needs: which
/// capture this is, and the bytes it parked. It is a value rather than the
/// loaded entry so a recovery cannot be given a screenshot it has no business
/// publishing.
nonisolated struct PendingRetryRecord: Sendable {
    let metadata: PendingRetryMetadata
    let audio: Data

    init(metadata: PendingRetryMetadata, audio: Data) {
        self.metadata = metadata
        self.audio = audio
    }

    init(_ entry: PendingRetryEntry) {
        self.init(metadata: entry.metadata, audio: entry.audioData)
    }
}

/// Names the temporary file a retry surface writes recovered bytes to.
///
/// Both capture lanes preserve COMPRESSED bytes and `AudioCompressor` can
/// return WAV, so the container is read off the bytes rather than assumed: a
/// provider handed a `.m4a` name over RIFF is being told something untrue about
/// its own input, and the stricter ones refuse it.
enum PendingRetryAudioFile {
    /// File extension WITHOUT the leading dot, for the bytes as they actually
    /// are.
    static func `extension`(for bytes: Data) -> String {
        SourceAudioContainer.sniff(bytes).fileExtension
    }
}

/// The queue's own rules, as pure functions over the list of records.
///
/// They live apart from the actor because everything that can go wrong with a
/// queue of irreplaceable recordings goes wrong HERE — an upsert that replaces
/// the wrong entry, an expiry sweep that reaches a record holding the only copy
/// of a recording, a migration that reads the old pointer and drops it — and
/// none of that is reachable by a test that has to go through an App-Group file
/// and a process-global `UserDefaults` domain first.
nonisolated enum PendingRetryQueue {

    /// Newest first, which is the order a person is offered them in: the
    /// capture they just made is the one they are waiting on.
    static func ordered(_ entries: [PendingRetryMetadata]) -> [PendingRetryMetadata] {
        entries.sorted { $0.createdAt > $1.createdAt }
    }

    /// Add a capture, or replace the record of one already queued. Keyed by id
    /// and by nothing else: two captures are two entries, however close
    /// together they were armed.
    static func upserting(
        _ metadata: PendingRetryMetadata,
        into entries: [PendingRetryMetadata]
    ) -> [PendingRetryMetadata] {
        ordered(entries.filter { $0.id != metadata.id } + [metadata])
    }

    /// Remove exactly one capture. Everything else stays queued.
    static func removing(
        id: UUID,
        from entries: [PendingRetryMetadata]
    ) -> (kept: [PendingRetryMetadata], removed: PendingRetryMetadata?) {
        (entries.filter { $0.id != id }, entries.first { $0.id == id })
    }

    /// Split the queue into what survives the clock and what the clock may
    /// retire. `isExemptFromExpiry` is what keeps an irreplaceable recording on
    /// the left-hand side forever.
    static func partitioningExpired(
        _ entries: [PendingRetryMetadata],
        at now: Date
    ) -> (kept: [PendingRetryMetadata], expired: [PendingRetryMetadata]) {
        (entries.filter { !$0.isExpired(at: now) }, entries.filter { $0.isExpired(at: now) })
    }

    /// Restate ONE record in place. Nil when the capture is no longer queued,
    /// so a caller can tell "updated" from "this capture is finished or gone"
    /// without a second read.
    static func updating(
        id: UUID,
        in entries: [PendingRetryMetadata],
        _ transform: (PendingRetryMetadata) -> PendingRetryMetadata
    ) -> [PendingRetryMetadata]? {
        guard entries.contains(where: { $0.id == id }) else { return nil }
        return entries.map { $0.id == id ? transform($0) : $0 }
    }

    /// The queue as it stands on disk, with an older release's single-slot
    /// pointer folded in.
    ///
    /// The legacy record is READ, never assumed absent: a device that upgrades
    /// mid-capture has exactly one parked recording and it is described by that
    /// key alone. It is folded in only when the queue does not already name the
    /// same capture, so a migration that runs twice adds nothing.
    static func decoding(
        queue: Data?,
        legacy: Data?
    ) -> (entries: [PendingRetryMetadata], migratedLegacy: Bool) {
        let decoder = JSONDecoder()
        var entries = queue
            .flatMap { try? decoder.decode([PendingRetryMetadata].self, from: $0) } ?? []
        guard let legacy,
              let slot = try? decoder.decode(PendingRetryMetadata.self, from: legacy) else {
            return (ordered(entries), false)
        }
        if !entries.contains(where: { $0.id == slot.id }) {
            entries.append(slot)
        }
        return (ordered(entries), true)
    }
}

/// What a capture surface does to the queue, named as one seam. It exists so a
/// capture surface's OWN rules — which capture it arms and which it releases —
/// can be asserted without writing to the process-global App-Group file every
/// other capture test in the bundle shares.
nonisolated protocol PendingRetryQueueWriting: Sendable {
    func save(
        audioData: Data,
        metadata: PendingRetryMetadata,
        workImageData: Data?
    ) async throws

    @discardableResult
    func clear(ifCurrentID id: UUID) async -> Bool
}

/// Persists pending audio retries across app launches, so a network failure
/// during transcription leaves the user with a retry button rather than a lost
/// recording. Singleton actor — concurrent callers serialize on the actor, and
/// concurrent PROCESSES serialize on the advisory file lock every transaction
/// takes.
actor PendingRetryStore: PendingRetryQueueWriting {
    static let shared = PendingRetryStore()

    private init() { }

    // MARK: - Storage Locations

    /// Key under which the queue is stored in App Groups UserDefaults. Local to
    /// this store; not promoted to `Constants` because no other subsystem
    /// references it (single producer + single consumer).
    private static let queueKey = "pending_retry_queue"

    /// The single-slot pointer an older release wrote. Read on every load and
    /// folded into the queue; removed only once that fold is committed.
    private static let legacyMetadataKey = "pending_retry_metadata"

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

    /// Queue a capture's audio + metadata for a later retry, or restate one
    /// already queued.
    ///
    /// It removes NOTHING. Every other capture's audio, screenshot and metadata
    /// are left exactly as they are, because the only thing a store can know
    /// about somebody else's recording is that it cannot make another one.
    ///
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
            // Read the queue BEFORE the payload lands, so this capture's own
            // file is never briefly an orphan the read would adopt with none of
            // the metadata the caller is about to commit.
            let existing = queueLocked(from: defaults)

            // `.complete` file protection: the file is unreadable while the
            // device is locked. A failure propagates so the guard never claims
            // an unavailable recording was saved.
            try audioData.write(to: url, options: [.atomic, .completeFileProtection])

            // Audio and Work screenshot are tied to the capture identity, not
            // to shared fixed filenames. Metadata is committed LAST as the
            // pointer. The process lock makes that transaction indivisible
            // across the main app and concurrent App Intent hosts.
            if metadata.resolvedDestination == .work,
               let workImageData,
               !workImageData.isEmpty,
               let imageURL = workImageURL(for: metadata.id) {
                try? workImageData.write(
                    to: imageURL,
                    options: [.atomic, .completeFileProtection]
                )
            }
            try persist(PendingRetryQueue.upserting(metadata, into: existing), to: defaults)
        }
    }

    /// Every capture still waiting, newest first, with its bytes.
    ///
    /// A surface offers them in this order and finishes them ONE AT A TIME,
    /// clearing each by id as it completes. An entry whose audio can no longer
    /// be read is dropped here rather than offered: a retry that cannot load
    /// its recording is a button that fails every time it is pressed.
    func load() async -> [PendingRetryEntry] {
        let defaults = defaults
        return (try? withExclusiveLock { () -> [PendingRetryEntry] in
            let entries = liveQueueLocked(from: defaults)
            var loaded: [PendingRetryEntry] = []
            var survivors: [PendingRetryMetadata] = []
            for metadata in entries {
                guard let url = readableAudioURL(for: metadata),
                      let audioData = try? Data(contentsOf: url) else {
                    removeFiles(for: metadata)
                    continue
                }
                let imageData: Data?
                if metadata.resolvedDestination == .work,
                   let imageURL = workImageURL(for: metadata.id) {
                    imageData = try? Data(contentsOf: imageURL)
                } else {
                    imageData = nil
                }
                loaded.append(
                    PendingRetryEntry(
                        audioData: audioData,
                        metadata: metadata,
                        workImageData: imageData
                    )
                )
                survivors.append(metadata)
            }
            if survivors.count != entries.count {
                try? persist(survivors, to: defaults)
            }
            return loaded
        }) ?? []
    }

    /// Cheap pre-check for UI (avoids loading audio just to test for presence
    /// of a retry). Mirrors `load()`'s expiry behavior.
    func hasPending() async -> Bool {
        let defaults = defaults
        return (try? withExclusiveLock {
            !liveQueueLocked(from: defaults).isEmpty
        }) ?? false
    }

    /// The `AppError.errorCode` that armed the NEWEST pending retry, if any —
    /// a metadata-only read (no audio load) for the home-screen retry card's
    /// Troubleshoot affordance. Newest because that is the capture the card
    /// offers first. Mirrors `hasPending()`'s expiry behavior so the card and
    /// its Troubleshoot button never disagree; nil when nothing is pending or
    /// the original failure carried no code.
    func pendingErrorCode() async -> Int? {
        let defaults = defaults
        return try? withExclusiveLock {
            liveQueueLocked(from: defaults).first?.lastErrorCode
        }
    }

    /// Metadata-only Diagnostics snapshot of the newest pending capture —
    /// `createdAt`, the arming `lastErrorCode`, and whether the audio file
    /// still EXISTS (metadata can orphan if the file is deleted out from under
    /// us; the row must not promise a retry that would immediately fail). No
    /// audio load. Mirrors `hasPending()`'s expiry purge; nil = nothing
    /// pending.
    func diagnosticSnapshot() async -> (createdAt: Date, lastErrorCode: Int?, audioFileExists: Bool)? {
        let defaults = defaults
        return try? withExclusiveLock {
            guard let metadata = liveQueueLocked(from: defaults).first else { return nil }
            return (
                metadata.createdAt,
                metadata.lastErrorCode,
                readableAudioURL(for: metadata) != nil
            )
        }
    }

    /// Purge every capture the clock may retire, and reclaim the files no
    /// queued capture names any more. Called from `ConduckApp` on launch
    /// (privacy: don't leave stale audio sitting in App Groups storage
    /// indefinitely). A recording whose desk card never landed is exempt — see
    /// `PendingRetryMetadata.isExemptFromExpiry`.
    func cleanupExpired() async {
        let defaults = defaults
        _ = try? withExclusiveLock {
            removeRetryFiles(retaining: liveQueueLocked(from: defaults))
        }
    }

    /// Clear exactly the capture the caller completed, and nothing else. Every
    /// other queued capture — including one armed by another process while this
    /// caller was suspended — is untouched.
    @discardableResult
    func clear(ifCurrentID id: UUID) async -> Bool {
        let defaults = defaults
        return (try? withExclusiveLock {
            let split = PendingRetryQueue.removing(id: id, from: queueLocked(from: defaults))
            guard let removed = split.removed else { return false }
            try persist(split.kept, to: defaults)
            removeFiles(for: removed)
            return true
        }) ?? false
    }

    /// Update diagnostics for a capture only while it is still queued. Never
    /// re-writes audio and never touches another entry.
    @discardableResult
    func updateAttemptIfCurrent(id: UUID, lastErrorCode: Int?) async -> Bool {
        let defaults = defaults
        return (try? withExclusiveLock {
            guard let updated = PendingRetryQueue.updating(
                id: id,
                in: queueLocked(from: defaults),
                { $0.recordingAttempt(lastErrorCode: lastErrorCode) }
            ) else { return false }
            try persist(updated, to: defaults)
            return true
        }) ?? false
    }

    /// Record what a process OBSERVED about one capture — whether its recording
    /// reached the desk, and the words if recognition already produced them.
    ///
    /// The ownership check and the write happen inside ONE `withExclusiveLock`,
    /// so nothing can arm, complete or restate this capture between them. It is
    /// metadata-only: no audio is re-written, no file is touched, and no other
    /// entry is read back or re-committed. A capture that is no longer queued
    /// answers false and nothing is created — a verdict about a recording that
    /// has already been dealt with is not a reason to bring it back.
    ///
    /// A nil argument keeps whatever the record already carries.
    @discardableResult
    func recordPublicationState(
        id: UUID,
        transcript: String? = nil,
        publicationState: PendingRetryPublicationState?
    ) async -> Bool {
        let defaults = defaults
        return (try? withExclusiveLock {
            guard let updated = PendingRetryQueue.updating(
                id: id,
                in: queueLocked(from: defaults),
                { $0.recording(transcript: transcript, publicationState: publicationState) }
            ) else { return false }
            try persist(updated, to: defaults)
            return true
        }) ?? false
    }

    /// Discard every pending capture (Settings → "Clear pending recording").
    /// Deletes the audio files, the screenshots and the queue itself.
    func clear() async {
        let defaults = defaults
        _ = try? withExclusiveLock {
            defaults.removeObject(forKey: Self.queueKey)
            defaults.removeObject(forKey: Self.legacyMetadataKey)
            _ = defaults.synchronize()
            removeRetryFiles(retaining: [])
        }
    }

    // MARK: - Locked helpers (every one of these runs under `withExclusiveLock`)

    /// The queue as it stands on disk: decoded, with an older release's single
    /// slot folded in, and with any audio file no entry names adopted back.
    private func queueLocked(from defaults: any DefaultsStore) -> [PendingRetryMetadata] {
        // Refresh the App-Group domain after acquiring the cross-process lock;
        // another intent host may have committed since this process's
        // UserDefaults cache was last read.
        _ = defaults.synchronize()
        let decoded = PendingRetryQueue.decoding(
            queue: defaults.data(forKey: Self.queueKey),
            legacy: defaults.data(forKey: Self.legacyMetadataKey)
        )
        var entries = decoded.entries
        let adopted = adoptOrphans(into: &entries)
        guard decoded.migratedLegacy || adopted else { return entries }
        do {
            try persist(entries, to: defaults)
            if decoded.migratedLegacy {
                // Only once the queue carrying it is committed. The pointer is
                // the sole description of that recording until then.
                defaults.removeObject(forKey: Self.legacyMetadataKey)
                _ = defaults.synchronize()
            }
        } catch {
            // Nothing on disk was lost: the next read decodes the same inputs
            // and folds them in again.
        }
        return entries
    }

    /// The queue with the clock applied — expired captures dropped and their
    /// files reclaimed.
    private func liveQueueLocked(from defaults: any DefaultsStore) -> [PendingRetryMetadata] {
        let entries = queueLocked(from: defaults)
        let split = PendingRetryQueue.partitioningExpired(entries, at: Date())
        guard !split.expired.isEmpty else { return entries }
        try? persist(split.kept, to: defaults)
        for metadata in split.expired { removeFiles(for: metadata) }
        return split.kept
    }

    private func persist(
        _ entries: [PendingRetryMetadata],
        to defaults: any DefaultsStore
    ) throws {
        defaults.set(try JSONEncoder().encode(entries), forKey: Self.queueKey)
        _ = defaults.synchronize()
    }

    /// A process can die after the protected id-scoped audio reaches disk but
    /// before UserDefaults commits the queue that names it. Destination is
    /// encoded in the filename specifically so this state is recoverable
    /// without guessing or deleting private words: every such file the queue
    /// does not name is adopted back as its own entry, with the file's own
    /// modification time as its `createdAt`.
    ///
    /// Returns whether anything was adopted, so the caller commits only a queue
    /// that actually changed.
    private func adoptOrphans(into entries: inout [PendingRetryMetadata]) -> Bool {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Constants.appGroupID
        ), let children = try? FileManager.default.contentsOfDirectory(
            at: container,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }

        let known = Set(entries.map(\.id))
        var adopted: [PendingRetryMetadata] = []
        for url in children {
            let name = url.lastPathComponent
            guard name.hasSuffix(".m4a"),
                  let destination = PendingRetryDestination.allCases.first(where: {
                      name.hasPrefix("pending_retry_audio_\($0.rawValue)_")
                  }) else { continue }
            let prefix = "pending_retry_audio_\(destination.rawValue)_"
            let rawID = String(name.dropFirst(prefix.count).dropLast(4))
            guard let id = UUID(uuidString: rawID), !known.contains(id),
                  let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]
                  ), values.isRegularFile == true else { continue }
            adopted.append(
                PendingRetryMetadata(
                    id: id,
                    createdAt: values.contentModificationDate ?? .distantPast,
                    audioFileURL: url,
                    preferredLanguage: nil,
                    attemptCount: 1,
                    lastErrorCode: nil,
                    destination: destination
                )
            )
        }
        guard !adopted.isEmpty else { return false }
        entries = PendingRetryQueue.ordered(entries + adopted)
        return true
    }

    /// Where this capture's bytes actually are, across the two historical
    /// layouts; nil when nothing readable is left.
    private func readableAudioURL(for metadata: PendingRetryMetadata) -> URL? {
        if let scoped = audioFileURL(
            for: metadata.id,
            destination: metadata.resolvedDestination
        ), FileManager.default.fileExists(atPath: scoped.path) {
            return scoped
        }
        if let transitional = preDestinationAudioFileURL(for: metadata.id),
           FileManager.default.fileExists(atPath: transitional.path) {
            return transitional
        }
        if metadata.resolvedDestination == .chat,
           let legacyAudioFileURL,
           FileManager.default.fileExists(atPath: legacyAudioFileURL.path) {
            return legacyAudioFileURL
        }
        return nil
    }

    /// Delete the payloads of ONE capture. Never reached for a capture still in
    /// the queue.
    private func removeFiles(for metadata: PendingRetryMetadata) {
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
    /// foreground app can both touch the App-Group queue, so a tiny advisory
    /// file lock wraps every metadata/payload transaction as one cross-process
    /// unit.
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

    /// Reclaim every retry payload no queued capture names. Called only where
    /// the caller has just resolved the queue (launch cleanup, or an explicit
    /// discard), never on the arming path: a file whose metadata has not
    /// committed yet is a recording waiting to be adopted, not residue.
    private func removeRetryFiles(retaining entries: [PendingRetryMetadata]) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Constants.appGroupID
        ), let children = try? FileManager.default.contentsOfDirectory(
            at: container,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        var retainedNames: Set<String> = []
        for metadata in entries {
            for destination in PendingRetryDestination.allCases {
                retainedNames.insert(
                    "pending_retry_audio_\(destination.rawValue)_\(metadata.id.uuidString).m4a"
                )
            }
            retainedNames.insert("pending_retry_audio_\(metadata.id.uuidString).m4a")
            retainedNames.insert("pending_retry_work_image_\(metadata.id.uuidString).bin")
        }
        // The fixed-name file an older build wrote is the payload of whichever
        // Chat record is still queued, and its name carries no id to match on.
        if entries.contains(where: { $0.resolvedDestination == .chat }) {
            retainedNames.insert("pending_retry_audio.m4a")
        }

        for child in children {
            let name = child.lastPathComponent
            let isRetryFile = name == "pending_retry_audio.m4a"
                || name.hasPrefix("pending_retry_audio_")
                || name.hasPrefix("pending_retry_work_image_")
            guard isRetryFile, !retainedNames.contains(name) else { continue }
            try? FileManager.default.removeItem(at: child)
        }
    }
}
