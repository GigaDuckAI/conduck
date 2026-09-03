// SPDX-License-Identifier: Apache-2.0

// Conduck
// PendingRetryStore.swift
//
// Every capture whose words are still owed, held as a QUEUE keyed by capture
// id. One entry per capture — its own recording, its own optional screenshot,
// its own durable record — and no entry is ever displaced by another. That is
// the whole shape: a second capture arming while a first is unfinished is the
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
// ON-DISK SHAPE (App Groups container, shared with Watch + Widget targets):
//
//   pending_retry_entry_<id>.json        the SIDECAR: the whole record for one
//                                        capture, plus the lease over it
//   pending_retry_audio_<dest>_<id>.m4a  the recording (`.complete` protection)
//   pending_retry_work_image_<id>.bin    optional Work screenshot bytes
//   pending_retry_tomb_<id>.tombstone    "this capture is being deleted"
//   pending_retry_audio_<id>.m4a         transitional dev-build path, READ only
//   pending_retry_audio.m4a              pre-id-scoped Chat path; its bytes are
//                                        COPIED under an id on first launch and
//                                        it is never read or deleted after that
//   pending_retry.lock                   the cross-process advisory flock
//   UserDefaults["pending_retry_queue"]  the INDEX: JSON `[PendingRetryMetadata]`
//   UserDefaults["pending_retry_metadata"] the single-slot pointer an older
//                                        release wrote, folded in and retired
//   UserDefaults["pending_retry_shape"]  which of the two layouts above wrote
//                                        this container
//
// WHY THE SIDECAR AND THE TOMBSTONE EXIST. The index and the payload cannot be
// committed atomically — one is a defaults domain and the other is a file — so
// a process that dies between them leaves a recording the index does not name.
// With only those two, an interrupted ARM and an interrupted CLEAR leave the
// identical residue and no reader can tell them apart: guess "arm" and a
// finished capture comes back from the dead; guess "clear" and the only copy of
// what somebody said is deleted. So each state names itself.
//
//   ARM   — sidecar, then bytes, then index row. A recording whose sidecar is
//           beside it and whose index row is missing is an arm that did not
//           commit, and the sidecar carries the WHOLE record, so nothing about
//           the capture is lost with the row.
//   CLEAR — tombstone, then index row, then payloads, then the tombstone last.
//           Anything under a tombstone is a deletion to be finished, never a
//           capture to be adopted.
//
// EXPIRY is a budget for a TRANSCRIPTION, not for a recording. Ten minutes is
// the right window for words that can be bought from a provider again, so it
// governs Chat retries and Work captures whose recording is already a card on
// the desk. It does not govern a Work capture whose recording the desk never
// took — `.phaseOneFailed`, and the UNKNOWN verdict an older record carries:
// those bytes are the only copy of what somebody said, and they leave only when
// publication succeeds or the person discards them.
//
// THE CLAIM API is how a surface takes one capture. Two retry surfaces can be
// on screen at once (the menu bar and the desk's voice sheet), and a queue read
// that hands both of them the same newest entry has them transcribe and finish
// it twice. `claimNext` reserves exactly one capture for ten minutes, reads
// exactly ONE recording however many are queued — several maximum-size
// recordings materialised at once is how an iOS process dies before it can
// offer any of them — and every later operation carries the token that
// reservation minted.

import Foundation
import Darwin

nonisolated enum PendingRetryDestination: String, Codable, CaseIterable, Sendable {
    case chat
    case work
}

/// Which retry surface is asking for work. A capture's DESTINATION is the
/// surface that can finish it — a Work recording belongs on the desk and a Chat
/// recording in a conversation, and neither can complete the other's — so the
/// two names are one type rather than two that have to be kept in step.
typealias PendingRetrySurface = PendingRetryDestination

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

/// A reservation over ONE queued capture, held for `claimLeaseDuration`.
///
/// The token identifies the HOLDER and the instant identifies how long the
/// reservation is respected. Expiry only makes a reservation stealable — it
/// does not retire the token, so a slow holder that nobody overtook can still
/// finish the capture it took.
nonisolated struct PendingRetryLease: Codable, Sendable {
    let token: UUID
    let expiresAt: Date

    func isLive(at now: Date) -> Bool { expiresAt > now }
}

/// The durable record of ONE capture, written beside its bytes.
///
/// It exists so that an arm interrupted before the index row commits is still
/// fully described: the id and the destination are recoverable from the
/// filename, but the words already recognised, the publication verdict, the
/// language and the attempt count are not, and every one of them changes what a
/// recovery does. Reconstructing an entry without them is how a refused Work
/// publication came back as a capture with no verdict, which no recovery can
/// handle correctly.
nonisolated struct PendingRetrySidecar: Codable, Sendable {
    let metadata: PendingRetryMetadata
    let lease: PendingRetryLease?

    init(metadata: PendingRetryMetadata, lease: PendingRetryLease? = nil) {
        self.metadata = metadata
        self.lease = lease
    }
}

/// One queued capture, reserved for the caller that will finish it.
///
/// Every operation that ends or restates a capture takes the claim rather than
/// a bare id, so a surface can only act on a capture it actually holds.
nonisolated struct PendingRetryClaim: Sendable {
    let entry: PendingRetryEntry
    let token: UUID

    var id: UUID { entry.metadata.id }

    init(entry: PendingRetryEntry, token: UUID) {
        self.entry = entry
        self.token = token
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

/// The App-Group filenames one capture's payloads take, in one place.
///
/// Every rule in this file that writes, reads, adopts or reclaims a file goes
/// through here, so a name can never be spelled one way by the writer and
/// another by the sweep — which is how the fixed-name legacy recording came to
/// be deleted by an entry that did not own it.
nonisolated enum PendingRetryFiles {
    static let sidecarPrefix = "pending_retry_entry_"
    static let tombstonePrefix = "pending_retry_tomb_"
    static let audioPrefix = "pending_retry_audio_"
    static let workImagePrefix = "pending_retry_work_image_"

    /// The pre-id-scoped Chat recording. Deliberately NOT covered by
    /// `audioPrefix` (it carries no trailing underscore), so no sweep or scan
    /// keyed on that prefix can ever reach it.
    static let legacyAudioName = "pending_retry_audio.m4a"
    static let lockName = "pending_retry.lock"

    static let sidecarSuffix = ".json"
    static let tombstoneSuffix = ".tombstone"
    static let audioSuffix = ".m4a"

    static func sidecar(_ id: UUID) -> String {
        "\(sidecarPrefix)\(id.uuidString)\(sidecarSuffix)"
    }

    static func tombstone(_ id: UUID) -> String {
        "\(tombstonePrefix)\(id.uuidString)\(tombstoneSuffix)"
    }

    static func audio(_ id: UUID, _ destination: PendingRetryDestination) -> String {
        "\(audioPrefix)\(destination.rawValue)_\(id.uuidString)\(audioSuffix)"
    }

    /// The id-scoped name a development build wrote before the destination
    /// became part of the filename. Read and reclaimed, never written.
    static func transitionalAudio(_ id: UUID) -> String {
        "\(audioPrefix)\(id.uuidString)\(audioSuffix)"
    }

    static func workImage(_ id: UUID) -> String {
        "\(workImagePrefix)\(id.uuidString).bin"
    }

    static func sidecarID(_ name: String) -> UUID? {
        identifier(in: name, prefix: sidecarPrefix, suffix: sidecarSuffix)
    }

    static func tombstoneID(_ name: String) -> UUID? {
        identifier(in: name, prefix: tombstonePrefix, suffix: tombstoneSuffix)
    }

    static func workImageID(_ name: String) -> UUID? {
        identifier(in: name, prefix: workImagePrefix, suffix: ".bin")
    }

    /// The capture an audio filename names, and the destination it declares.
    /// A nil destination is the transitional name, which declares none.
    static func audioID(_ name: String) -> (id: UUID, destination: PendingRetryDestination?)? {
        for destination in PendingRetryDestination.allCases {
            if let id = identifier(
                in: name,
                prefix: "\(audioPrefix)\(destination.rawValue)_",
                suffix: audioSuffix
            ) {
                return (id, destination)
            }
        }
        guard let id = identifier(in: name, prefix: audioPrefix, suffix: audioSuffix) else {
            return nil
        }
        return (id, nil)
    }

    /// True for every file this store owns. The lock and the legacy fixed-name
    /// recording are deliberately excluded: neither belongs to a capture.
    static func isRetryFile(_ name: String) -> Bool {
        sidecarID(name) != nil
            || tombstoneID(name) != nil
            || workImageID(name) != nil
            || audioID(name) != nil
    }

    private static func identifier(in name: String, prefix: String, suffix: String) -> UUID? {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix),
              name.count > prefix.count + suffix.count else { return nil }
        return UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(suffix.count)))
    }
}

/// The App-Group `UserDefaults` keys this store owns. Local to the retry queue
/// and not promoted to `Constants` because no other subsystem reads them; named
/// here rather than inside the actor so the INDEX and the files beside it are
/// described in one place.
nonisolated enum PendingRetryDefaultsKeys {
    /// The index: JSON `[PendingRetryMetadata]`, newest first.
    static let queue = "pending_retry_queue"
    /// The single slot an older release wrote. Read on every reconciliation and
    /// retired only once the queue carrying it is committed.
    static let legacySlot = "pending_retry_metadata"
    /// Which on-disk layout wrote this container.
    static let shape = "pending_retry_shape"
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

    /// How long one `claimNext` reserves a capture. Long enough that a slow
    /// provider round trip on a bad connection never loses the reservation
    /// mid-transcription, and short enough that a process killed while holding
    /// one gives the capture back within a single recovery window rather than
    /// stranding it until the next launch. A holder that finishes early gives
    /// it back with `release`.
    static let claimLeaseDuration: TimeInterval = 600

    /// Which on-disk layout wrote this container. Anything below the current
    /// value means the sidecars and tombstones below are not there yet, so a
    /// recording with neither is an arm the older layout could not describe
    /// rather than residue a clear left behind.
    private static let currentShape = 2

    private let containerOverride: URL?
    private let defaultsOverride: (any DefaultsStore)?

    private init() {
        containerOverride = nil
        defaultsOverride = nil
    }

    #if CONDUCK_TESTING
    // Test seams. Both exist because the durable half of this store — the write
    // orders that make an interrupted arm and an interrupted clear
    // distinguishable, the adoption scan, the lease — is unreachable otherwise:
    // the production instance writes the process-global App-Group container
    // every other capture test in this bundle shares, so a test that drove it
    // would be asserting against, and corrupting, its neighbours' state.
    // Compiled only under CONDUCK_TESTING and reachable from nowhere else.

    /// This store over an isolated directory and an isolated defaults domain.
    init(containerURL: URL, defaults: any DefaultsStore) {
        self.containerOverride = containerURL
        self.defaultsOverride = defaults
        try? FileManager.default.createDirectory(
            at: containerURL,
            withIntermediateDirectories: true
        )
    }

    /// Counts every attempt to read a parked RECORDING's bytes. `claimNext`
    /// must make exactly one per call however many captures are queued; nothing
    /// but a count can prove that, and the difference between one read and all
    /// of them is whether an iOS process survives a queue of maximum-size
    /// recordings.
    private(set) var audioReadsForTesting = 0

    func resetAudioReadsForTesting() { audioReadsForTesting = 0 }
    #endif

    // MARK: - Storage Locations

    private var containerURL: URL? {
        if let containerOverride { return containerOverride }
        return FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Constants.appGroupID)
    }

    /// App Groups UserDefaults handle (shared with Widget / Watch — though
    /// only the main iOS app currently writes to this key).
    private var defaults: any DefaultsStore {
        defaultsOverride ?? SettingsDependencies.processDefault.defaults
    }

    // MARK: - Arming

    /// Queue a capture's audio + metadata for a later retry, or restate one
    /// already queued.
    ///
    /// It removes NOTHING. Every other capture's audio, screenshot and metadata
    /// are left exactly as they are, because the only thing a store can know
    /// about somebody else's recording is that it cannot make another one.
    ///
    /// Write order is the ARM order stated at the top of this file — sidecar,
    /// bytes, index row — and it is the whole reason a process that dies here
    /// leaves a state the next read can name.
    ///
    /// - Throws: file-system errors writing to App Groups container.
    func save(
        audioData: Data,
        metadata: PendingRetryMetadata,
        workImageData: Data? = nil
    ) async throws {
        guard let container = containerURL else { throw AppError.settingsLoadFailed }
        let defaults = defaults
        try withExclusiveLock(in: container) {
            // Read the queue BEFORE anything of this capture's lands, so its
            // own files are never briefly residue the same read would judge.
            let existing = queueLocked(from: defaults, in: container)

            // A tombstone over this id would have the next read delete what is
            // about to be written. Only a clear interrupted mid-way leaves one,
            // and re-arming the same capture is a legitimate answer to that.
            remove(container.appendingPathComponent(PendingRetryFiles.tombstone(metadata.id)))

            // The sidecar carries the whole record, so an arm that dies before
            // the index row commits loses nothing about the capture. A live
            // reservation is carried through: a re-arm is a new failure on a
            // capture somebody may still be holding, not a reason to take it
            // away from them.
            let lease = readSidecar(for: metadata.id, in: container)?.lease
            try writeSidecar(
                PendingRetrySidecar(metadata: metadata, lease: lease),
                in: container
            )

            // `.complete` file protection: the file is unreadable while the
            // device is locked. A failure propagates so the guard never claims
            // an unavailable recording was saved.
            let audioURL = container.appendingPathComponent(
                PendingRetryFiles.audio(metadata.id, metadata.resolvedDestination)
            )
            try audioData.write(to: audioURL, options: [.atomic, .completeFileProtection])

            if metadata.resolvedDestination == .work,
               let workImageData,
               !workImageData.isEmpty {
                try? workImageData.write(
                    to: container.appendingPathComponent(
                        PendingRetryFiles.workImage(metadata.id)
                    ),
                    options: [.atomic, .completeFileProtection]
                )
            }

            // The index row is the LAST thing committed. The process lock makes
            // the whole sequence indivisible across the main app and concurrent
            // App Intent hosts.
            try persist(PendingRetryQueue.upserting(metadata, into: existing), to: defaults)
        }
    }

    // MARK: - The claim API

    /// Reserve the next capture a surface can finish, with its bytes.
    ///
    /// Newest first, because the capture a person just made is the one they are
    /// waiting on. The scan itself reads only records; exactly ONE recording is
    /// read, and only the reserved one's — the whole queue materialised at once
    /// is several maximum-size recordings in an iOS process that has to survive
    /// long enough to offer them.
    ///
    /// A capture somebody else is already holding is skipped while their lease
    /// is live. A capture whose recording is GONE is finished here rather than
    /// offered: a retry that cannot load its recording is a button that fails
    /// every time it is pressed. A recording that is present but unreadable —
    /// `.completeFileProtection` before first unlock — is skipped and kept.
    func claimNext(surface: PendingRetrySurface? = nil) async -> PendingRetryClaim? {
        guard let container = containerURL else { return nil }
        let defaults = defaults
        return try? withExclusiveLock(in: container) { () -> PendingRetryClaim? in
            let now = Date()
            let entries = liveQueueLocked(from: defaults, in: container)
            var chosen: PendingRetryMetadata?
            var chosenURL: URL?
            var doomed: [PendingRetryMetadata] = []

            for metadata in entries {
                guard let url = readableAudioURL(for: metadata, in: container) else {
                    doomed.append(metadata)
                    continue
                }
                guard chosen == nil else { continue }
                if let surface, metadata.resolvedDestination != surface { continue }
                if let lease = readSidecar(for: metadata.id, in: container)?.lease,
                   lease.isLive(at: now) { continue }
                chosen = metadata
                chosenURL = url
            }

            if !doomed.isEmpty {
                _ = finishLocked(doomed, from: entries, defaults: defaults, in: container)
            }

            guard let chosen, let chosenURL, let audioData = readAudio(at: chosenURL) else {
                return nil
            }
            let lease = PendingRetryLease(
                token: UUID(),
                expiresAt: now.addingTimeInterval(Self.claimLeaseDuration)
            )
            // A reservation that cannot be written is not a reservation. Better
            // to offer nothing this tap than to hand two surfaces the same
            // capture believing one of them holds it.
            guard (try? writeSidecar(
                PendingRetrySidecar(metadata: chosen, lease: lease),
                in: container
            )) != nil else { return nil }

            return PendingRetryClaim(
                entry: PendingRetryEntry(
                    audioData: audioData,
                    metadata: chosen,
                    workImageData: workImageData(for: chosen, in: container)
                ),
                token: lease.token
            )
        }
    }

    /// How many captures are waiting, records only — no recording is read.
    ///
    /// It counts every live capture including one another surface is holding: a
    /// reservation says who is finishing a recording, not whether it is still
    /// waiting. This is what a retry surface asks after finishing one, and what
    /// Diagnostics reports.
    func pendingCount() async -> Int {
        guard let container = containerURL else { return 0 }
        let defaults = defaults
        return (try? withExclusiveLock(in: container) {
            liveQueueLocked(from: defaults, in: container).count
        }) ?? 0
    }

    /// Give a capture back without finishing it. The entry and its recording
    /// stay exactly as they are; only the reservation goes, so the next tap —
    /// on this surface or another — can take it.
    func release(_ claim: PendingRetryClaim) async {
        guard let container = containerURL else { return }
        _ = try? withExclusiveLock(in: container) {
            guard let sidecar = readSidecar(for: claim.id, in: container),
                  sidecar.lease?.token == claim.token else { return }
            try? writeSidecar(
                PendingRetrySidecar(metadata: sidecar.metadata, lease: nil),
                in: container
            )
        }
    }

    /// Finish exactly the capture this claim holds, and nothing else.
    ///
    /// Write order is the CLEAR order stated at the top of this file: the
    /// tombstone first, so a process that dies part-way leaves a deletion the
    /// next read finishes rather than a recording it resurrects.
    ///
    /// False when the claim no longer holds the capture — somebody overtook an
    /// expired reservation, or the capture is already finished — and then
    /// nothing is written at all.
    @discardableResult
    func clear(_ claim: PendingRetryClaim) async -> Bool {
        guard let container = containerURL else { return false }
        let defaults = defaults
        return (try? withExclusiveLock(in: container) { () -> Bool in
            let entries = queueLocked(from: defaults, in: container)
            guard holdsLease(claim, in: container) else { return false }
            guard let removed = entries.first(where: { $0.id == claim.id }) else { return false }
            return !finishLocked([removed], from: entries, defaults: defaults, in: container).isEmpty
        }) ?? false
    }

    /// Record what this holder OBSERVED about the capture it is finishing —
    /// whether the recording reached the desk, and the words if recognition
    /// already produced them. Metadata only: no recording is re-written and no
    /// other capture is read back or re-committed.
    @discardableResult
    func recordPublicationState(
        _ claim: PendingRetryClaim,
        transcript: String? = nil,
        publicationState: PendingRetryPublicationState
    ) async -> Bool {
        guard let container = containerURL else { return false }
        let defaults = defaults
        return (try? withExclusiveLock(in: container) { () -> Bool in
            let entries = queueLocked(from: defaults, in: container)
            guard let lease = liveLease(for: claim, in: container) else { return false }
            return restateLocked(
                id: claim.id, in: entries, defaults: defaults, container: container, lease: lease
            ) { $0.recording(transcript: transcript, publicationState: publicationState) }
        }) ?? false
    }

    /// Count one more attempt against the capture this holder is finishing, and
    /// record the error that ended it. Diagnostics only — it changes nothing
    /// the retry logic branches on.
    @discardableResult
    func updateAttempt(_ claim: PendingRetryClaim, lastErrorCode: Int?) async -> Bool {
        guard let container = containerURL else { return false }
        let defaults = defaults
        return (try? withExclusiveLock(in: container) { () -> Bool in
            let entries = queueLocked(from: defaults, in: container)
            guard let lease = liveLease(for: claim, in: container) else { return false }
            return restateLocked(
                id: claim.id, in: entries, defaults: defaults, container: container, lease: lease
            ) { $0.recordingAttempt(lastErrorCode: lastErrorCode) }
        }) ?? false
    }

    // MARK: - Public API

    /// Every capture still waiting, newest first, with its bytes.
    ///
    /// Superseded by the claim API. No PRODUCTION caller remains; what keeps
    /// it is the tests that measure the difference — `claimNext` reads one
    /// recording where this reads all of them, and deleting this deletes the
    /// control that proves it. It reads EVERY queued recording into memory and
    /// reserves none of them, which is both halves of what `claimNext` exists
    /// to fix.
    func load() async -> [PendingRetryEntry] {
        guard let container = containerURL else { return [] }
        let defaults = defaults
        return (try? withExclusiveLock(in: container) { () -> [PendingRetryEntry] in
            let entries = liveQueueLocked(from: defaults, in: container)
            var loaded: [PendingRetryEntry] = []
            var doomed: [PendingRetryMetadata] = []
            for metadata in entries {
                guard let url = readableAudioURL(for: metadata, in: container) else {
                    doomed.append(metadata)
                    continue
                }
                // Present but unreadable is a locked device, not a lost
                // recording: skip it and leave it queued.
                guard let audioData = readAudio(at: url) else { continue }
                loaded.append(
                    PendingRetryEntry(
                        audioData: audioData,
                        metadata: metadata,
                        workImageData: workImageData(for: metadata, in: container)
                    )
                )
            }
            if !doomed.isEmpty {
                _ = finishLocked(doomed, from: entries, defaults: defaults, in: container)
            }
            return loaded
        }) ?? []
    }

    /// Cheap pre-check for UI (avoids loading audio just to test for presence
    /// of a retry). Mirrors `load()`'s expiry behavior.
    func hasPending() async -> Bool {
        guard let container = containerURL else { return false }
        let defaults = defaults
        return (try? withExclusiveLock(in: container) {
            !liveQueueLocked(from: defaults, in: container).isEmpty
        }) ?? false
    }

    /// The `AppError.errorCode` that armed the NEWEST pending retry, if any —
    /// a metadata-only read (no audio load) for the home-screen retry card's
    /// Troubleshoot affordance. Newest because that is the capture the card
    /// offers first. Mirrors `hasPending()`'s expiry behavior so the card and
    /// its Troubleshoot button never disagree; nil when nothing is pending or
    /// the original failure carried no code.
    func pendingErrorCode() async -> Int? {
        guard let container = containerURL else { return nil }
        let defaults = defaults
        return try? withExclusiveLock(in: container) {
            liveQueueLocked(from: defaults, in: container).first?.lastErrorCode
        }
    }

    /// Metadata-only Diagnostics snapshot of the newest pending capture —
    /// `createdAt`, the arming `lastErrorCode`, and whether the audio file
    /// still EXISTS (metadata can orphan if the file is deleted out from under
    /// us; the row must not promise a retry that would immediately fail). No
    /// audio load. Mirrors `hasPending()`'s expiry purge; nil = nothing
    /// pending.
    func diagnosticSnapshot() async -> (createdAt: Date, lastErrorCode: Int?, audioFileExists: Bool)? {
        guard let container = containerURL else { return nil }
        let defaults = defaults
        return try? withExclusiveLock(in: container) {
            guard let metadata = liveQueueLocked(from: defaults, in: container).first else {
                return nil
            }
            return (
                metadata.createdAt,
                metadata.lastErrorCode,
                readableAudioURL(for: metadata, in: container) != nil
            )
        }
    }

    /// Purge every capture the clock may retire, and reclaim the files no
    /// queued capture names any more. Called from `ConduckApp` on launch
    /// (privacy: don't leave stale audio sitting in App Groups storage
    /// indefinitely). A recording whose desk card never landed is exempt — see
    /// `PendingRetryMetadata.isExemptFromExpiry`.
    func cleanupExpired() async {
        guard let container = containerURL else { return }
        let defaults = defaults
        _ = try? withExclusiveLock(in: container) {
            removeRetryFiles(
                retaining: liveQueueLocked(from: defaults, in: container),
                in: container
            )
        }
    }

    /// Clear exactly the capture the caller completed, and nothing else. Every
    /// other queued capture — including one armed by another process while this
    /// caller was suspended — is untouched.
    ///
    /// Superseded by `clear(_ claim:)`; delete when no caller remains. It takes
    /// no reservation, so it cannot tell whether the capture it is finishing is
    /// the one this caller was working on.
    @discardableResult
    func clear(ifCurrentID id: UUID) async -> Bool {
        guard let container = containerURL else { return false }
        let defaults = defaults
        return (try? withExclusiveLock(in: container) { () -> Bool in
            let entries = queueLocked(from: defaults, in: container)
            guard let removed = entries.first(where: { $0.id == id }) else { return false }
            return !finishLocked([removed], from: entries, defaults: defaults, in: container).isEmpty
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
    ///
    /// Superseded by `recordPublicationState(_ claim:transcript:publicationState:)`;
    /// delete when no caller remains.
    @discardableResult
    func recordPublicationState(
        id: UUID,
        transcript: String? = nil,
        publicationState: PendingRetryPublicationState?
    ) async -> Bool {
        guard let container = containerURL else { return false }
        let defaults = defaults
        return (try? withExclusiveLock(in: container) { () -> Bool in
            let entries = queueLocked(from: defaults, in: container)
            return restateLocked(
                id: id,
                in: entries,
                defaults: defaults,
                container: container,
                lease: readSidecar(for: id, in: container)?.lease
            ) { $0.recording(transcript: transcript, publicationState: publicationState) }
        }) ?? false
    }

    /// Discard every pending capture (Settings → "Clear pending recording").
    /// Deletes the audio files, the screenshots, the records and the queue
    /// itself — including the pre-id-scoped recording, which this is the only
    /// operation allowed to delete.
    func clear() async {
        guard let container = containerURL else { return }
        let defaults = defaults
        _ = try? withExclusiveLock(in: container) {
            defaults.removeObject(forKey: PendingRetryDefaultsKeys.queue)
            defaults.removeObject(forKey: PendingRetryDefaultsKeys.legacySlot)
            _ = defaults.synchronize()
            removeRetryFiles(retaining: [], in: container)
            remove(container.appendingPathComponent(PendingRetryFiles.legacyAudioName))
        }
    }

    // MARK: - Locked helpers (every one of these runs under `withExclusiveLock`)

    /// The queue as it stands on disk: decoded, reconciled against the files
    /// beside it, and committed when either changed.
    ///
    /// The reconciliation is the whole crash story, in the order the states
    /// have to be resolved.
    private func queueLocked(
        from defaults: any DefaultsStore,
        in container: URL
    ) -> [PendingRetryMetadata] {
        // Refresh the App-Group domain after acquiring the cross-process lock;
        // another intent host may have committed since this process's
        // UserDefaults cache was last read.
        _ = defaults.synchronize()

        let queueData = defaults.data(forKey: PendingRetryDefaultsKeys.queue)
        let pointerData = defaults.data(forKey: PendingRetryDefaultsKeys.legacySlot)
        let decoded = PendingRetryQueue.decoding(queue: queueData, legacy: pointerData)
        var entries = decoded.entries
        var files = inventory(in: container)
        let firstReconcile = defaults.integer(forKey: PendingRetryDefaultsKeys.shape) < Self.currentShape
        var changed = false
        var foldedLegacySlot = decoded.migratedLegacy
        var retireLegacyPointer = decoded.migratedLegacy
        var retireLegacyRecording = false

        // 1 — Finish every interrupted clear. A tombstone is a deletion this
        // store already committed to; nothing under one is ever adopted.
        for id in files.tombstones.sorted(by: { $0.uuidString < $1.uuidString }) {
            if let index = entries.firstIndex(where: { $0.id == id }) {
                entries.remove(at: index)
                changed = true
            }
            removeFiles(forID: id, in: container)
            remove(container.appendingPathComponent(PendingRetryFiles.tombstone(id)))
            files.forget(id)
        }

        // 2 — Give the folded single slot its OWN bytes. The fixed name carries
        // no id, so while a queued capture's payload lives under it any other
        // Chat capture's completion deletes this recording. It is COPIED under
        // the slot's id before the entry is trusted, and the original goes only
        // after the queue naming the copy commits.
        if let slot = pointerData.flatMap({
            try? JSONDecoder().decode(PendingRetryMetadata.self, from: $0)
        }), !queuedIDs(in: queueData).contains(slot.id) {
            if files.audio[slot.id] != nil {
                // Already id-scoped: an earlier fold copied them and died
                // before retiring the original.
                retireLegacyRecording = files.hasLegacyRecording
            } else if copyLegacyRecording(
                to: slot.id,
                destination: slot.resolvedDestination,
                files: &files,
                in: container
            ) {
                retireLegacyRecording = true
            } else {
                // Its only recording could not be put under an id. Leave BOTH
                // the pointer and the file exactly as they are for the next
                // read; a queued capture with no bytes would be finished by the
                // next claim, and finishing it is what deletes the file.
                entries.removeAll { $0.id == slot.id }
                foldedLegacySlot = false
                retireLegacyPointer = false
            }
        }

        // 3 — The pre-id-scoped recording, once. An entry folded in by an
        // earlier build points at the fixed name and has no bytes of its own;
        // the oldest such Chat capture is the one that recording belongs to.
        if firstReconcile, files.hasLegacyRecording, !retireLegacyRecording {
            let orphaned = entries
                .filter { $0.resolvedDestination == .chat && files.audio[$0.id] == nil }
                .sorted { $0.createdAt < $1.createdAt }
            if let owner = orphaned.first,
               copyLegacyRecording(to: owner.id, destination: .chat, files: &files, in: container) {
                retireLegacyRecording = true
                changed = true
            }
        }

        // 4 — Adopt every arm that did not commit. The sidecar carries the
        // WHOLE record, so a refused Work publication comes back with its
        // verdict and its words rather than as a capture with neither.
        for id in files.sidecars.sorted(by: { $0.uuidString < $1.uuidString })
        where !entries.contains(where: { $0.id == id }) {
            guard let file = files.audio[id] else {
                // An arm whose bytes never landed. There is no recording to
                // protect and no retry that could succeed.
                remove(container.appendingPathComponent(PendingRetryFiles.sidecar(id)))
                continue
            }
            if let sidecar = readSidecar(for: id, in: container) {
                entries.append(sidecar.metadata)
            } else if let salvaged = adoptedMetadata(forID: id, file: file) {
                // An unreadable record is not a reason to delete a recording.
                entries.append(salvaged)
            } else {
                continue
            }
            changed = true
        }

        // 5 — A recording with neither a record nor an index row. Under the
        // current layout that is residue a clear did not finish deleting;
        // under the previous one it is an arm that could not describe itself,
        // and those are adopted once.
        let unattachedAudio = files.audio.filter { id, _ in
            !files.sidecars.contains(id) && !entries.contains(where: { $0.id == id })
        }
        for (id, file) in unattachedAudio.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard firstReconcile, let adopted = adoptedMetadata(forID: id, file: file) else {
                removeFiles(forID: id, in: container)
                continue
            }
            guard (try? writeSidecar(
                PendingRetrySidecar(metadata: adopted),
                in: container
            )) != nil else { continue }
            files.sidecars.insert(id)
            entries.append(adopted)
            changed = true
        }

        // 6 — Give every index row a record. This is what upgrades a container
        // the previous layout wrote, and what repairs one somebody deleted.
        let unrecorded = entries.filter { !files.sidecars.contains($0.id) }
        for metadata in unrecorded {
            guard (try? writeSidecar(
                PendingRetrySidecar(metadata: metadata),
                in: container
            )) != nil else { continue }
            files.sidecars.insert(metadata.id)
        }

        entries = PendingRetryQueue.ordered(entries)

        var committed = true
        if changed || foldedLegacySlot || retireLegacyPointer {
            do {
                try persist(entries, to: defaults)
                if retireLegacyPointer {
                    // Only once the queue carrying it is committed. The pointer
                    // is the sole description of that recording until then.
                    defaults.removeObject(forKey: PendingRetryDefaultsKeys.legacySlot)
                    _ = defaults.synchronize()
                }
                if retireLegacyRecording {
                    remove(container.appendingPathComponent(PendingRetryFiles.legacyAudioName))
                }
            } catch {
                // Nothing on disk was lost: the next read decodes the same
                // inputs, finds the same files and folds them in again.
                committed = false
            }
        }
        if firstReconcile, committed {
            defaults.set(Self.currentShape, forKey: PendingRetryDefaultsKeys.shape)
            _ = defaults.synchronize()
        }
        return entries
    }

    /// The queue with the clock applied — expired captures finished and their
    /// files reclaimed.
    private func liveQueueLocked(
        from defaults: any DefaultsStore,
        in container: URL
    ) -> [PendingRetryMetadata] {
        let entries = queueLocked(from: defaults, in: container)
        let split = PendingRetryQueue.partitioningExpired(entries, at: Date())
        guard !split.expired.isEmpty else { return entries }
        let finished = finishLocked(
            split.expired, from: entries, defaults: defaults, in: container
        )
        return entries.filter { !finished.contains($0.id) }
    }

    /// End these captures, in the CLEAR order. Returns the ids actually
    /// removed.
    ///
    /// The tombstone is written first and is REQUIRED: without it the residue
    /// of an interrupted deletion is indistinguishable from an arm, and the
    /// next read brings the capture back. A capture that cannot be tombstoned
    /// therefore stays queued rather than being deleted unsafely.
    @discardableResult
    private func finishLocked(
        _ doomed: [PendingRetryMetadata],
        from entries: [PendingRetryMetadata],
        defaults: any DefaultsStore,
        in container: URL
    ) -> Set<UUID> {
        var tombstoned: Set<UUID> = []
        for metadata in doomed where writeTombstone(metadata.id, in: container) {
            tombstoned.insert(metadata.id)
        }
        guard !tombstoned.isEmpty else { return [] }

        // The index row goes before the payloads, so a death in between leaves
        // the tombstone in charge and the next read finishes the deletion.
        try? persist(entries.filter { !tombstoned.contains($0.id) }, to: defaults)
        for id in tombstoned {
            removeFiles(forID: id, in: container)
            remove(container.appendingPathComponent(PendingRetryFiles.tombstone(id)))
        }
        return tombstoned
    }

    /// Restate ONE record, in the sidecar first and the index second, so the
    /// durable copy is never behind the one a crash would lose.
    private func restateLocked(
        id: UUID,
        in entries: [PendingRetryMetadata],
        defaults: any DefaultsStore,
        container: URL,
        lease: PendingRetryLease?,
        _ transform: (PendingRetryMetadata) -> PendingRetryMetadata
    ) -> Bool {
        guard let updated = PendingRetryQueue.updating(id: id, in: entries, transform),
              let restated = updated.first(where: { $0.id == id }) else { return false }
        guard (try? writeSidecar(
            PendingRetrySidecar(metadata: restated, lease: lease),
            in: container
        )) != nil else { return false }
        do {
            try persist(updated, to: defaults)
        } catch {
            return false
        }
        return true
    }

    private func persist(
        _ entries: [PendingRetryMetadata],
        to defaults: any DefaultsStore
    ) throws {
        defaults.set(try JSONEncoder().encode(entries), forKey: PendingRetryDefaultsKeys.queue)
        _ = defaults.synchronize()
    }

    // MARK: - Leases

    /// The reservation this claim still holds, or nil when somebody overtook it.
    ///
    /// An EXPIRED lease whose token still matches is honoured: expiry makes a
    /// reservation stealable, and a holder nobody overtook has not lost the
    /// capture it took — only the right to keep others off it.
    private func liveLease(
        for claim: PendingRetryClaim,
        in container: URL
    ) -> PendingRetryLease? {
        guard let lease = readSidecar(for: claim.id, in: container)?.lease,
              lease.token == claim.token else { return nil }
        return lease
    }

    private func holdsLease(_ claim: PendingRetryClaim, in container: URL) -> Bool {
        liveLease(for: claim, in: container) != nil
    }

    // MARK: - Files

    /// Everything this store owns in the container, read in one pass.
    private struct Inventory {
        struct AudioFile {
            let url: URL
            /// Nil for the transitional name, which declares no destination.
            let destination: PendingRetryDestination?
        }

        var sidecars: Set<UUID> = []
        var tombstones: Set<UUID> = []
        var audio: [UUID: AudioFile] = [:]
        var hasLegacyRecording = false

        mutating func forget(_ id: UUID) {
            sidecars.remove(id)
            tombstones.remove(id)
            audio[id] = nil
        }
    }

    private func inventory(in container: URL) -> Inventory {
        var found = Inventory()
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: container,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return found }

        for url in children {
            let name = url.lastPathComponent
            if name == PendingRetryFiles.legacyAudioName {
                found.hasLegacyRecording = true
            } else if let id = PendingRetryFiles.sidecarID(name) {
                found.sidecars.insert(id)
            } else if let id = PendingRetryFiles.tombstoneID(name) {
                found.tombstones.insert(id)
            } else if let audio = PendingRetryFiles.audioID(name) {
                // The destination-scoped name wins over the transitional one:
                // it is the only layout anything writes today.
                if audio.destination != nil || found.audio[audio.id] == nil {
                    found.audio[audio.id] = Inventory.AudioFile(
                        url: url,
                        destination: audio.destination
                    )
                }
            }
        }
        return found
    }

    /// The captures the INDEX itself named, before the single-slot pointer was
    /// folded in. It is what tells a pointer that has already been folded from
    /// one that is being folded now.
    private func queuedIDs(in queueData: Data?) -> Set<UUID> {
        Set(
            (queueData.flatMap {
                try? JSONDecoder().decode([PendingRetryMetadata].self, from: $0)
            } ?? []).map(\.id)
        )
    }

    /// Put the pre-id-scoped recording under one capture's own id. COPY, never
    /// move: the original stays until the queue naming the copy is committed,
    /// so a death in between costs nothing.
    private func copyLegacyRecording(
        to id: UUID,
        destination: PendingRetryDestination,
        files: inout Inventory,
        in container: URL
    ) -> Bool {
        let source = container.appendingPathComponent(PendingRetryFiles.legacyAudioName)
        let target = container.appendingPathComponent(PendingRetryFiles.audio(id, destination))
        // COPY, never move: the original stays until the entry naming the copy
        // is committed, so a death in between costs nothing.
        guard (try? FileManager.default.copyItem(at: source, to: target)) != nil else {
            return false
        }
        files.audio[id] = Inventory.AudioFile(url: target, destination: destination)
        return true
    }

    /// The record a recording can be reconstructed from when nothing else
    /// describes it: its id and destination from the name, and its age from the
    /// file. Everything a recovery branches on is missing, which is exactly why
    /// the sidecar exists.
    private func adoptedMetadata(
        forID id: UUID,
        file: Inventory.AudioFile
    ) -> PendingRetryMetadata? {
        let values = try? file.url.resourceValues(
            forKeys: [.contentModificationDateKey, .isRegularFileKey]
        )
        guard values?.isRegularFile == true else { return nil }
        return PendingRetryMetadata(
            id: id,
            createdAt: values?.contentModificationDate ?? .distantPast,
            audioFileURL: file.url,
            preferredLanguage: nil,
            attemptCount: 1,
            lastErrorCode: nil,
            destination: file.destination
        )
    }

    /// Where this capture's bytes actually are, across the two id-scoped
    /// layouts; nil when nothing this capture OWNS is left.
    ///
    /// The pre-id-scoped fixed name is deliberately absent. It carries no id,
    /// so every Chat capture would resolve to it — and the completion of any
    /// one of them would then delete a recording belonging to another. Its
    /// bytes are copied under an id by the reconciliation instead.
    private func readableAudioURL(
        for metadata: PendingRetryMetadata,
        in container: URL
    ) -> URL? {
        let scoped = container.appendingPathComponent(
            PendingRetryFiles.audio(metadata.id, metadata.resolvedDestination)
        )
        if FileManager.default.fileExists(atPath: scoped.path) { return scoped }
        let transitional = container.appendingPathComponent(
            PendingRetryFiles.transitionalAudio(metadata.id)
        )
        if FileManager.default.fileExists(atPath: transitional.path) { return transitional }
        return nil
    }

    private func readAudio(at url: URL) -> Data? {
        #if CONDUCK_TESTING
        audioReadsForTesting += 1
        #endif
        return try? Data(contentsOf: url)
    }

    private func workImageData(
        for metadata: PendingRetryMetadata,
        in container: URL
    ) -> Data? {
        guard metadata.resolvedDestination == .work else { return nil }
        return try? Data(
            contentsOf: container.appendingPathComponent(
                PendingRetryFiles.workImage(metadata.id)
            )
        )
    }

    private func sidecarURL(for id: UUID, in container: URL) -> URL {
        container.appendingPathComponent(PendingRetryFiles.sidecar(id))
    }

    private func readSidecar(for id: UUID, in container: URL) -> PendingRetrySidecar? {
        guard let data = try? Data(contentsOf: sidecarURL(for: id, in: container)) else {
            return nil
        }
        return try? JSONDecoder().decode(PendingRetrySidecar.self, from: data)
    }

    /// The record is protected only to first unlock, deliberately: it holds
    /// nothing the index in App-Group `UserDefaults` does not already hold at
    /// exactly that level, and a headless capture arming before the device has
    /// ever been unlocked has to be able to read what is already parked.
    private func writeSidecar(_ sidecar: PendingRetrySidecar, in container: URL) throws {
        try JSONEncoder().encode(sidecar).write(
            to: sidecarURL(for: sidecar.metadata.id, in: container),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    /// Declare a deletion. Its CONTENT is never read — the file's existence is
    /// the whole signal — so it carries the id only to be legible to a person
    /// looking at the container.
    private func writeTombstone(_ id: UUID, in container: URL) -> Bool {
        (try? Data(id.uuidString.utf8).write(
            to: container.appendingPathComponent(PendingRetryFiles.tombstone(id)),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )) != nil
    }

    /// Delete every payload of ONE capture. Reached only under a tombstone, or
    /// for residue no entry and no record names.
    private func removeFiles(forID id: UUID, in container: URL) {
        for destination in PendingRetryDestination.allCases {
            remove(container.appendingPathComponent(PendingRetryFiles.audio(id, destination)))
        }
        remove(container.appendingPathComponent(PendingRetryFiles.transitionalAudio(id)))
        remove(container.appendingPathComponent(PendingRetryFiles.workImage(id)))
        remove(container.appendingPathComponent(PendingRetryFiles.sidecar(id)))
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// `actor` serialization ends at the process boundary. App Intents and the
    /// foreground app can both touch the App-Group queue, so a tiny advisory
    /// file lock wraps every metadata/payload transaction as one cross-process
    /// unit.
    private func withExclusiveLock<T>(
        in container: URL,
        _ operation: () throws -> T
    ) throws -> T {
        let lockFileURL = container.appendingPathComponent(PendingRetryFiles.lockName)
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
    /// discard), never on the arming path: a file whose index row has not
    /// committed yet is a recording waiting to be adopted, not residue.
    ///
    /// The pre-id-scoped recording is out of its reach by construction — its
    /// name carries no id and no `pending_retry_audio_` prefix — because a
    /// sweep that could reach it would delete a recording no entry can name.
    private func removeRetryFiles(
        retaining entries: [PendingRetryMetadata],
        in container: URL
    ) {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: container,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        var retained: Set<String> = []
        for metadata in entries {
            for destination in PendingRetryDestination.allCases {
                retained.insert(PendingRetryFiles.audio(metadata.id, destination))
            }
            retained.insert(PendingRetryFiles.transitionalAudio(metadata.id))
            retained.insert(PendingRetryFiles.workImage(metadata.id))
            retained.insert(PendingRetryFiles.sidecar(metadata.id))
        }

        for child in children {
            let name = child.lastPathComponent
            guard PendingRetryFiles.isRetryFile(name), !retained.contains(name) else { continue }
            remove(child)
        }
    }
}
