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
// THE SIDECAR IS AUTHORITATIVE over its index row, and that follows from the
// orders above: every operation writes the sidecar first, so the two can only
// disagree when a process died between them, and the sidecar is the newer half.
// A reconciliation that reads a differing index row rewrites it from the
// sidecar. An UNREADABLE sidecar is evidence of nothing — the file is protected
// until first unlock, and a decode can fail on a truncated write — so its
// capture DEFERS: the recording is kept, nothing is persisted, and the next read
// tries again. Reconstructing a record from the filename instead loses the
// verdict, the words and the language, and that lossy row would then be the
// authority for ever.
//
// EXPIRY is a budget for a TRANSCRIPTION, not for a recording. Ten minutes is
// the right window for words that can be bought from a provider again, so it
// governs Chat retries and Work captures the desk already holds. It does not
// govern a Work capture the desk holds nothing for — `.phaseOneFailed`, which
// is the ordinary state of every fresh Work capture, and the UNKNOWN verdict an
// older record carries: those bytes are the only copy of what somebody said,
// and they leave only when the words land or the person discards them. A parked
// SCREENSHOT earns the same exemption for the same reason, and it is read off
// the file rather than off the record: the two artifacts publish separately, so
// an entry can hold a card on the desk and the only copy of a picture at the
// same time.
//
// THE RECORDING LEAVES WHEN THE WORDS LAND, and the entry does not always leave
// with it. A capture that still owes a screenshot keeps its entry — the parked
// picture may be the only copy of itself — so `retireRecording` deletes the
// audio alone and stamps `.published`. What is left, an entry with a picture and
// no recording, is OFFERED by the claim API with EMPTY bytes. It is not swept —
// the picture is not a sweep's to take — and it has nothing to transcribe, but
// it has a picture to publish, and an entry no surface can take is an entry no
// surface can finish: after a process death nothing would ever reap that
// picture again. Its words are parked on the record, so the surface that claims
// it publishes the picture, finds the words card already standing, and clears
// the entry without buying a second transcription.
//
// THE CLAIM API is how a surface takes one capture. Two retry surfaces can be
// on screen at once (the menu bar and the desk's voice sheet), and a queue read
// that hands both of them the same newest entry has them transcribe and finish
// it twice. `claimNext` reserves exactly one capture for ten minutes, reads
// exactly ONE recording however many are queued — several maximum-size
// recordings materialised at once is how an iOS process dies before it can
// offer any of them — and every later operation carries the token that
// reservation minted.
//
// `claimNext` SELECTS; `claim(id:duration:)` ADDRESSES. The two are different
// questions and only the retry surfaces ask the first one. A lane that armed a
// capture itself — the guard, the recorder, a Shortcut's intent process, the
// desk's voice sheet — holds the id it minted, and "the newest unreserved
// capture" is not that capture whenever anything armed after it. Its own
// duration is a parameter because the lanes' lifetimes differ by an order of
// magnitude: an intent process that is killed announces a retry at 90 seconds,
// so a ten-minute hold taken there would tell a person to tap a button the store
// refuses them for another eight.
//
// A RESERVATION IS RENEWED, not sized for the worst case. A custom provider
// request is allowed 300 seconds and is attempted three times, so a
// transcription can outlast any fixed horizon short enough to give a capture
// back promptly when its holder dies. `renew` extends the reservation by the
// duration it was granted with, `confirmOwnership` is what a holder asks before
// acting on a capture it has been transcribing for minutes, and a live
// reservation also exempts its capture from the expiry sweep — the clock retires
// captures nobody is finishing.

import Foundation
import Darwin

nonisolated enum PendingRetryDestination: String, Codable, CaseIterable, Sendable {
    case chat
    case work
}

/// Which retry surface is asking for work. A capture's DESTINATION is the
/// surface that can finish it — a Work capture's words belong on the desk and a
/// Chat recording's in a conversation, and neither can complete the other's — so the
/// two names are one type rather than two that have to be kept in step.
typealias PendingRetrySurface = PendingRetryDestination

/// Whether the DESK already holds what this capture produced.
///
/// It is the answer to one question and one only: are these parked bytes the
/// last copy of what somebody said? Every clock, every sweep and every discard
/// confirmation reads it for that, and nothing else.
///
/// Optional on the wire: a record written before this existed decodes as nil,
/// and nil means UNKNOWN, which is read as "assume the bytes are the only copy".
/// Case names and raw values are frozen — a device mid-upgrade has records on
/// disk written by the other build.
nonisolated enum PendingRetryPublicationState: String, Codable, Sendable {
    /// The desk holds this capture: its words card, or — for a capture an
    /// earlier build published — the recording itself. Either way what is on
    /// the board no longer depends on these bytes, so the clock may govern them
    /// and a discard costs nothing that is not already saved.
    case published
    /// The desk holds nothing for this capture. These bytes are the only copy of
    /// what was said, so no clock retires them and only the words landing, or
    /// the person's own discard, ends the entry.
    ///
    /// This is the ORDINARY state of every fresh Work capture, not a failure
    /// report: the recording is parked before speech recognition is attempted
    /// and nothing reaches the desk until the words arrive.
    case phaseOneFailed
}

/// Metadata describing one queued capture. Destination is optional on the wire
/// for backwards compatibility; nil means Chat for every record made before
/// Work existed.
/// Equatable so the reconciliation can tell an index row that AGREES with its
/// sidecar from one a crash left behind, and rewrite only the second.
nonisolated struct PendingRetryMetadata: Codable, Sendable, Equatable {
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

    /// The desk id of the PICTURE this capture's recording belongs to, when one
    /// press produced both — `WorkVoiceScreenshotCoordinator.materialID` of the
    /// capture id. Nil for every capture that carried no picture, and for every
    /// record written before this field existed.
    ///
    /// It is stored INDEPENDENTLY of `workImageData`. Those bytes are dropped
    /// from the record the moment the inbox has taken them, and the link has to
    /// outlive that: a recording republished a day later still belongs to the
    /// picture that press produced, whether or not this entry is still
    /// sheltering a copy of it. Nothing reconstructs the link from the
    /// remaining bytes — an entry with no bytes is exactly the entry whose
    /// picture already landed.
    ///
    /// It is NOT picture debt. The expiry clock, the exemption and the final
    /// sweep read the destination, the publication state, `createdAt` and the
    /// parked image FILE; a link is a fact about identity and buys this record
    /// no extra life.
    ///
    /// Named for its lane rather than `attachedToMaterialID`, which is the desk
    /// column's name, because this is a different field on a different type: it
    /// is what the desk column is written FROM, not a copy of it.
    let workAttachedToMaterialID: UUID?

    /// The surface the words were SPOKEN at, for the card a recovery publishes.
    ///
    /// It is not always the device doing the writing, which is the whole reason
    /// it is stored rather than derived: a wrist recording is relayed to the
    /// phone and published there, so `SourceDevice.current` at publication time
    /// would call it an iPhone note. CarPlay states "carplay", the relay
    /// "watch"; every lane that captures where it publishes states nothing.
    ///
    /// Optional on the wire for the reason every added field here is: a record
    /// written before it existed decodes as nil, and nil means the current
    /// device.
    let sourceDevice: String?

    /// Frozen when an in-app Work recording launches. Optional on disk so old
    /// captures and every external/headless capture remain unfiled. Re-arming
    /// the same capture preserves the original destination, including nil:
    /// retrying from another window must never borrow that window's project.
    let workProjectID: UUID?

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
        publicationState: PendingRetryPublicationState? = nil,
        workAttachedToMaterialID: UUID? = nil,
        sourceDevice: String? = nil,
        workProjectID: UUID? = nil
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
        self.workAttachedToMaterialID = workAttachedToMaterialID
        self.sourceDevice = sourceDevice
        self.workProjectID = workProjectID
    }

    /// How long a capture may wait for a TRANSCRIPTION it can buy again.
    static let transcriptionRetryTTL: TimeInterval = 600

    /// The same wait, measured for somebody who cannot answer it yet.
    ///
    /// A `.published` Work capture has its WORDS on the desk, so what is left in
    /// the entry is a leftover and the clock may govern it. But ten minutes is a
    /// budget for a person holding the device that failed, and the car is the
    /// surface where that is never true: a drive is hours, the phone may stay
    /// locked until the driver is home, and a sentence about finishing this on
    /// your iPhone is false the moment the entry is swept. A day covers the
    /// drive and the evening after it while keeping the queue bounded, which is
    /// the whole difference between a longer clock and no clock: nothing in
    /// these bytes is the only copy of anything the person said, and a queue
    /// that never retires them grows with no exit but the person's own discard.
    static let publishedWorkRetryTTL: TimeInterval = 86_400

    /// True when this record holds bytes that exist nowhere else, so no clock
    /// may retire it.
    ///
    /// A Chat capture's words are the artifact and the provider can produce
    /// them again; a Work capture that reports `.published` has its words card
    /// on the desk already, and whatever is still parked beside it is a
    /// leftover. Every other Work record — `.phaseOneFailed`, the ordinary
    /// state of a fresh capture, and the UNKNOWN verdict an older record
    /// carries — is the only copy, and a clock is not a reason to delete it.
    var isExemptFromExpiry: Bool {
        resolvedDestination == .work && publicationState != .published
    }

    /// How long THIS record may wait. Exempt records answer `nil`: they are not
    /// on a longer clock, they are on none.
    var retryTTL: TimeInterval? {
        if isExemptFromExpiry { return nil }
        if resolvedDestination == .work, publicationState == .published {
            return Self.publishedWorkRetryTTL
        }
        return Self.transcriptionRetryTTL
    }

    var isExpired: Bool { isExpired(at: Date()) }

    func isExpired(at now: Date) -> Bool {
        guard let ttl = retryTTL else { return false }
        return now.timeIntervalSince(createdAt) > ttl
    }

    /// The same record with one more attempt and a fresh diagnostic code. Every
    /// other field is carried forward verbatim: dropping the words or the
    /// publication verdict here would silently cost a later recovery a provider
    /// round trip, or leave it unable to tell a refused publication from a
    /// deleted card — and dropping the link would republish a recording as a
    /// card of its own beside the picture it came from.
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
            publicationState: publicationState,
            workAttachedToMaterialID: workAttachedToMaterialID,
            sourceDevice: sourceDevice,
            workProjectID: workProjectID
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
            publicationState: newState ?? publicationState,
            // Carried verbatim. This restatement is taken by a process that
            // observed a PUBLICATION, which learns nothing about the link or
            // about where the words were spoken and must not be able to erase
            // either.
            workAttachedToMaterialID: workAttachedToMaterialID,
            sourceDevice: sourceDevice,
            workProjectID: workProjectID
        )
    }

    /// The same record with whatever this one already knew about its own
    /// publication kept — the rule a RE-ARM of an id already queued obeys.
    ///
    /// Two things can never go backwards. Words already bought stay bought: a
    /// wrist that re-fires after a lost reply, or a stale in-app
    /// `preserveForRetry` from a recorder another surface has since taken over,
    /// would otherwise erase a transcript the provider was already paid for and
    /// the next retry would buy the same answer again. And a `.published`
    /// verdict never downgrades to `.phaseOneFailed`: the desk holds this
    /// capture, and a record saying otherwise is exempt from every clock for
    /// ever.
    ///
    /// The project destination also stays with the original launch, including
    /// nil for external captures. Everything else is the newcomer's, because
    /// the newcomer is the more recent observation of the same capture.
    func keepingPublication(of previous: PendingRetryMetadata) -> PendingRetryMetadata {
        let keptTranscript = transcript ?? previous.transcript
        let keptState: PendingRetryPublicationState? =
            previous.publicationState == .published ? .published : publicationState
        guard keptTranscript != transcript || keptState != publicationState
            || workProjectID != previous.workProjectID else { return self }
        return PendingRetryMetadata(
            id: id,
            createdAt: createdAt,
            audioFileURL: audioFileURL,
            preferredLanguage: preferredLanguage,
            attemptCount: attemptCount,
            lastErrorCode: lastErrorCode,
            destination: destination,
            transcript: keptTranscript,
            publicationState: keptState,
            workAttachedToMaterialID: workAttachedToMaterialID,
            sourceDevice: sourceDevice,
            workProjectID: previous.workProjectID
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

    /// How long this reservation was granted for, so a renewal extends it by
    /// the holder's OWN horizon rather than by a default that belongs to a
    /// different lane — a 90-second intent hold renewed for ten minutes is the
    /// hazard the parameter exists to avoid.
    ///
    /// Optional on the wire for the reason every added field here is: a
    /// reservation written before it existed decodes as nil, which reads as the
    /// standard horizon.
    let duration: TimeInterval?

    init(token: UUID, expiresAt: Date, duration: TimeInterval? = nil) {
        self.token = token
        self.expiresAt = expiresAt
        self.duration = duration
    }

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

/// A metadata-only account of the whole recovery queue. A saved capture is not
/// evidence of a failure: headless lanes save before starting and hold a lease
/// while they work. The counts distinguish those holds from recordings another
/// surface may recover, and a Work transcript that already exists needs saving,
/// not another speech-provider call.
///
/// No capture identity, path, transcript, or error text leaves this reduction.
/// Expiring counts include only available captures whose actual retention policy
/// has a deadline. A live lease, an unpublished Work recording, or a parked screenshot
/// protects the capture from the clock exactly as it does in the store's sweep.
nonisolated struct PendingRetryDiagnosticSnapshot: Sendable, Equatable {
    /// The file/lease facts read under the store lock, also the pure derivation
    /// seam used by tests. Audio bytes are never read to produce these facts.
    struct Capture: Sendable {
        let metadata: PendingRetryMetadata
        let audioFileExists: Bool
        let isActivelyLeased: Bool
        let leaseStateKnown: Bool
        let holdsWorkImage: Bool

        init(
            metadata: PendingRetryMetadata,
            audioFileExists: Bool = true,
            isActivelyLeased: Bool = false,
            leaseStateKnown: Bool = true,
            holdsWorkImage: Bool = false
        ) {
            self.metadata = metadata
            self.audioFileExists = audioFileExists
            self.isActivelyLeased = isActivelyLeased
            self.leaseStateKnown = leaseStateKnown
            self.holdsWorkImage = holdsWorkImage
        }
    }

    let totalCount: Int
    let availableCount: Int
    let processingCount: Int
    let missingAudioCount: Int
    let accessUnavailableCount: Int
    /// Available captures only. These sum to `availableCount`.
    let transcriptionCount: Int
    let finishSavingCount: Int
    /// Available captures with a deadline; other available captures have none.
    let expiringCount: Int

    /// Unindexed captures with unreadable sidecars have no metadata to reduce.
    /// Count their presence without inventing a destination, lease or deadline.
    init(captures: [Capture], now: Date, unreadableUnindexedCount: Int = 0) {
        var available = 0
        var processing = 0
        var missing = 0
        var unavailable = unreadableUnindexedCount
        var transcription = 0
        var saving = 0
        var expiring = 0

        for capture in captures {
            // An unreadable sidecar may hide a live reservation. The store
            // defers it; Diagnostics must not invent either an active holder or
            // a recording the user is free to take.
            guard capture.leaseStateKnown else {
                unavailable += 1
                continue
            }
            if capture.isActivelyLeased {
                processing += 1
                continue
            }
            // Mirror the actual expiry policy, including a screenshot whose
            // only remaining copy is protected independently of the recording.
            if capture.metadata.isExpired(at: now), !capture.holdsWorkImage {
                continue
            }
            guard capture.audioFileExists else {
                missing += 1
                continue
            }

            available += 1
            if capture.metadata.resolvedDestination == .work,
               let transcript = capture.metadata.transcript,
               !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                saving += 1
            } else {
                transcription += 1
            }
            if !capture.holdsWorkImage, capture.metadata.retryTTL != nil {
                expiring += 1
            }
        }

        totalCount = available + processing + missing + unavailable
        availableCount = available
        processingCount = processing
        missingAudioCount = missing
        accessUnavailableCount = unavailable
        transcriptionCount = transcription
        finishSavingCount = saving
        expiringCount = expiring
    }

    /// Anonymous counts only: copied support context, never a screen verdict.
    var reportFact: String {
        "queued(total \(totalCount), available \(availableCount), processing \(processingCount), transcription \(transcriptionCount), finish-saving \(finishSavingCount), missing-audio \(missingAudioCount), unreadable \(accessUnavailableCount), with-deadline \(expiringCount))"
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
    /// the left-hand side forever; `retryTTL` is what decides how long everybody
    /// else gets, which is a day for a published Work capture and ten minutes
    /// for a Chat one.
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

/// The durable write a capture surface makes when it parks a recording, named
/// as one seam. It exists so a capture surface's OWN rule — which capture it
/// arms — can be asserted without writing to the process-global App-Group file
/// every other capture test in the bundle shares.
///
/// It carries the arm and NOTHING that ends a capture: every operation that
/// finishes, restates or releases one is token-gated and lives on
/// `PendingRetryLaneReserving`, which refines this. A seam that let a surface
/// end a capture by id is what let two surfaces finish one recording.
nonisolated protocol PendingRetryQueueWriting: Sendable {
    func save(
        audioData: Data,
        metadata: PendingRetryMetadata,
        workImageData: Data?
    ) async throws
}

/// What a `save` that could not commit everything still left behind.
///
/// One shape, because one write can fail with the recording already durable:
/// the screenshot is the last byte written before the index row, and the
/// sidecar and the audio are committed above it. `reconcile` adopts that pair
/// on the next read regardless, so "the save threw" and "nothing is queued"
/// stopped being the same sentence — and every caller that read them as one
/// left a live entry it did not know it owned. The recording IS parked; the
/// picture is not, and the caller still has the only copy of it.
///
/// Deliberately NOT an `AppError`: it is a fact about this store's own write,
/// carried to the one caller that acts on it, not a verdict for a person.
nonisolated enum PendingRetrySaveOutcome: Error {
    case recordingParkedWithoutPicture(underlying: any Error)
}

/// Persists pending audio retries across app launches, so a network failure
/// during transcription leaves the user with a retry button rather than a lost
/// recording. Singleton actor — concurrent callers serialize on the actor, and
/// concurrent PROCESSES serialize on the advisory file lock every transaction
/// takes.
actor PendingRetryStore: PendingRetryQueueWriting {
    static let shared = PendingRetryStore()

    /// Posted after a capture is ARMED, so a surface rendering the queue's size
    /// learns about one it did not park itself.
    ///
    /// Every surface refreshes its own count after its own save, which is why
    /// this was not needed before: the lane that wrote the entry was the lane
    /// that displayed it. The composer's recorder broke that — it parks a Work
    /// capture the MENU BAR's retry row has to offer — and a count read before
    /// that save is a row that says nothing is waiting while a recording is.
    ///
    /// Posted on ARM and on RETIREMENT, which are the two things that change
    /// the number a surface renders. The sweep's own deletions are not
    /// announced: nobody asked about them, and the next read applies the clock
    /// again anyway.
    nonisolated static let queueDidChangeNotification = Notification.Name(
        "ai.gigaduck.pendingRetryQueueDidChange"
    )

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
    /// IT NEVER REGRESSES AN ENTRY IT IS RESTATING. Re-parking an id already
    /// queued keeps whatever that entry knew about its own publication — its
    /// words, and a `.published` verdict — because a re-arm is not always the
    /// newest thing that happened to the capture. A wrist re-fires when the
    /// phone's reply is lost, minutes after the phone finished; an in-app
    /// recorder's `preserveForRetry` can run after another surface took the
    /// capture over and published it. Either would otherwise erase a transcript
    /// the provider was already paid for, or downgrade a verdict that says the
    /// desk holds this capture — which is an entry exempt from every clock for
    /// ever. See `PendingRetryMetadata.keepingPublication(of:)`.
    ///
    /// Write order is the ARM order stated at the top of this file — sidecar,
    /// bytes, index row — and it is the whole reason a process that dies here
    /// leaves a state the next read can name.
    ///
    /// - Throws: file-system errors writing to App Groups container.
    func save(
        audioData: Data,
        metadata incoming: PendingRetryMetadata,
        workImageData: Data? = nil
    ) async throws {
        guard let container = containerURL else { throw AppError.settingsLoadFailed }
        let defaults = defaults
        // Carried out of the lock rather than thrown from inside it, so the
        // index row still commits and the announcement still goes out. See the
        // screenshot write below.
        var pictureFailure: (any Error)?
        try withExclusiveLock(in: container) {
            // Read the queue BEFORE anything of this capture's lands, so its
            // own files are never briefly residue the same read would judge.
            let existing = queueLocked(from: defaults, in: container)

            // The record this call actually writes. The queue is reconciled
            // against the sidecars above, so what it names for this id is the
            // capture as it durably stands, and an arm may not walk that
            // backwards. Everything below writes THIS — which is why the
            // caller's own argument is the only thing spelled `incoming`.
            let metadata = (existing.first { $0.id == incoming.id })
                .map(incoming.keepingPublication(of:)) ?? incoming

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

            // The picture's failure PROPAGATES, exactly as the recording's does
            // one line up and for the identical reason: this is the only copy
            // of a screenshot that reached no card, so a caller told the save
            // landed would stop treating memory as the last place it exists.
            // A swallowed write here armed an entry whose picture was never
            // written — the recovery it promises then finds nothing to
            // republish, and the quit that follows takes the bytes.
            //
            // It does NOT abandon the arm. The sidecar and the recording are
            // already committed above, and step 5 of `reconcile` adopts that
            // pair on the next read whether or not the index row lands — so a
            // throw taken HERE produced an entry that was real, claimable by any
            // surface, and unknown to the one that made it: it armed nothing,
            // released nothing on the next Record Again, and its ⌘Q guard read
            // the recording as memory-only. The row is committed and the picture's
            // failure travels back as its own outcome instead.
            if metadata.resolvedDestination == .work,
               let workImageData,
               !workImageData.isEmpty {
                do {
                    try workImageData.write(
                        to: container.appendingPathComponent(
                            PendingRetryFiles.workImage(metadata.id)
                        ),
                        options: [.atomic, .completeFileProtection]
                    )
                } catch {
                    pictureFailure = error
                }
            }

            // The index row is the LAST thing committed. The process lock makes
            // the whole sequence indivisible across the main app and concurrent
            // App Intent hosts.
            try persist(PendingRetryQueue.upserting(metadata, into: existing), to: defaults)
        }
        // Announced only once the write has COMMITTED, and outside the lock: a
        // surface that refreshed on a throw would count an entry that is not
        // there, and one that refreshed inside the lock would read the queue
        // through a lock this call still holds.
        NotificationCenter.default.post(name: Self.queueDidChangeNotification, object: nil)
        if let pictureFailure {
            throw PendingRetrySaveOutcome.recordingParkedWithoutPicture(underlying: pictureFailure)
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
    ///
    /// The one entry with no recording that IS offered is the one whose audio
    /// was retired the moment its words landed and whose screenshot is still
    /// parked. It comes with empty bytes and its parked words, which is exactly
    /// what its remaining debt needs: the picture is published, the words card
    /// is found already standing, and the entry is cleared. Left unoffered it
    /// was unfinishable — nothing else reaps a parked picture, and the expiry
    /// clock deliberately will not take one.
    func claimNext(surface: PendingRetrySurface? = nil) async -> PendingRetryClaim? {
        guard let container = containerURL else { return nil }
        let defaults = defaults
        let claim = try? withExclusiveLock(in: container) { () -> PendingRetryClaim? in
            let now = Date()
            let entries = liveQueueLocked(from: defaults, in: container)
            var chosen: PendingRetryMetadata?
            // Nil once something IS chosen means the chosen entry's recording
            // was retired with its words; `chosen` alone says whether anything
            // was picked at all.
            var chosenURL: URL?
            var doomed: [PendingRetryMetadata] = []

            for metadata in entries {
                let url = readableAudioURL(for: metadata, in: container)
                // A capture whose recording is gone is finished here — with ONE
                // exception: an entry whose recording was retired the moment its
                // words landed still shelters the only copy of a picture. It is
                // not this sweep's to take, and it is offered below with no
                // bytes, because publishing that picture is the only thing left
                // that can finish it.
                if url == nil, !holdsWorkImage(metadata.id, in: container) {
                    doomed.append(metadata)
                    continue
                }
                guard chosen == nil else { continue }
                if let surface, metadata.resolvedDestination != surface { continue }
                if isReserved(metadata.id, in: container, at: now) { continue }
                chosen = metadata
                chosenURL = url
            }

            if !doomed.isEmpty {
                _ = finishLocked(doomed, from: entries, defaults: defaults, in: container)
            }

            guard let chosen else { return nil }
            return reserveLocked(
                chosen,
                at: chosenURL,
                duration: Self.claimLeaseDuration,
                now: now,
                in: container
            )
        }
        announceQueueChange(claim != nil)
        return claim
    }

    /// Reserve the capture this caller already knows the id of.
    ///
    /// This is the ARM side's primitive. A lane that minted a capture — the
    /// guard, the recorder, a Shortcut's intent process, the desk's voice sheet
    /// — addresses that capture and no other, and `claimNext`'s answer ("the
    /// newest capture nobody has reserved") is a different capture the moment
    /// anything armed after it.
    ///
    /// Nil when the capture is not queued, when somebody else's reservation is
    /// still live over it, or when its recording cannot be read. A capture whose
    /// recording is GONE is finished here, exactly as `claimNext` finishes one —
    /// and the one whose recording was retired with its words while a screenshot
    /// stayed parked is handed over with empty bytes, exactly as `claimNext`
    /// hands it over, because publishing that picture is all it has left.
    ///
    /// `duration` is the caller's own horizon: a process that announces a retry
    /// at 90 seconds must not hold the capture for ten minutes, because the hold
    /// outlives the process and the person is told to tap a button the store
    /// then refuses.
    func claim(
        id: UUID,
        duration: TimeInterval = PendingRetryStore.claimLeaseDuration
    ) async -> PendingRetryClaim? {
        guard let container = containerURL else { return nil }
        let defaults = defaults
        let claim = try? withExclusiveLock(in: container) { () -> PendingRetryClaim? in
            let now = Date()
            let entries = liveQueueLocked(from: defaults, in: container)
            guard let metadata = entries.first(where: { $0.id == id }) else { return nil }
            guard !isReserved(id, in: container, at: now) else { return nil }
            let url = readableAudioURL(for: metadata, in: container)
            if url == nil, !holdsWorkImage(metadata.id, in: container) {
                // Its recording is gone and it shelters nothing else, so it is
                // finished here rather than offered — a retry that cannot load
                // its recording is a button that fails every time it is pressed.
                _ = finishLocked([metadata], from: entries, defaults: defaults, in: container)
                return nil
            }
            return reserveLocked(
                metadata, at: url, duration: duration, now: now, in: container
            )
        }
        announceQueueChange(claim != nil)
        return claim
    }

    /// The same reservation, with a refusal that says WHICH refusal it is.
    ///
    /// `claim(id:duration:)` answers nil for a capture nobody queued and for one
    /// somebody else is holding, and those demand opposite behavior: the first
    /// leaves the bytes in hand as the only copy, so the caller's own retry is
    /// the only thing that can finish it; the second must be refused, or two
    /// surfaces transcribe one recording and attach different words to one card.
    ///
    /// The distinction is not decorative. A `save` that wrote the sidecar and
    /// the audio and then THREW on the screenshot leaves an entry reconciliation
    /// adopts — real, claimable, and unknown to the local bookkeeping of the
    /// process that wrote it. Asked through `claim` alone, that process reads
    /// the refusal as "nothing was ever queued" and retries a recording another
    /// surface is already finishing.
    ///
    /// One pass under the same lock as `claim`, so the two answers cannot swap
    /// between a claim and a follow-up question.
    func reserve(
        id: UUID,
        duration: TimeInterval = PendingRetryStore.claimLeaseDuration
    ) async -> PendingRetryReservation {
        guard let container = containerURL else { return .absent }
        let defaults = defaults
        let outcome = try? withExclusiveLock(in: container) { () -> PendingRetryReservation in
            let now = Date()
            let entries = liveQueueLocked(from: defaults, in: container)
            guard let metadata = entries.first(where: { $0.id == id }) else { return .absent }
            guard !isReserved(id, in: container, at: now) else { return .heldElsewhere }
            let url = readableAudioURL(for: metadata, in: container)
            if url == nil, !holdsWorkImage(metadata.id, in: container) {
                // A capture whose recording is gone is FINISHED here, exactly as
                // `claimNext` finishes one — and an entry that no longer exists
                // is absent, which is the answer that lets the caller's own
                // bytes still be retried. The one entry kept and OFFERED instead
                // is the one whose recording was retired with its words and
                // whose picture is still parked here.
                _ = finishLocked([metadata], from: entries, defaults: defaults, in: container)
                return .absent
            }
            guard let claim = reserveLocked(
                metadata, at: url, duration: duration, now: now, in: container
            ) else { return .heldElsewhere }
            return .claimed(claim)
        }
        // A lock this process could not take says nothing about the entry, and
        // the safe reading of "somebody may be working on it" is the one that
        // refuses a second transcription.
        let resolved = outcome ?? .heldElsewhere
        if case .claimed = resolved { announceQueueChange(true) }
        return resolved
    }

    /// Extend the reservation this claim holds, by the duration it was granted
    /// with.
    ///
    /// A holder renews while it is still working: a custom provider request is
    /// allowed 300 seconds and is attempted three times, so a transcription can
    /// outlast a horizon short enough to give a capture back promptly when the
    /// process holding it dies. False when the reservation is no longer this
    /// holder's — somebody overtook it after it lapsed — and then nothing is
    /// written.
    @discardableResult
    func renew(_ claim: PendingRetryClaim) async -> Bool {
        guard let container = containerURL else { return false }
        return (try? withExclusiveLock(in: container) { () -> Bool in
            guard let sidecar = readSidecar(for: claim.id, in: container),
                  let lease = sidecar.lease, lease.token == claim.token else { return false }
            let horizon = lease.duration ?? Self.claimLeaseDuration
            // The sidecar's own metadata, never the index row's: the sidecar is
            // the authority, and a renewal must not quietly reinstate a record
            // an interrupted write left behind.
            return (try? writeSidecar(
                PendingRetrySidecar(
                    metadata: sidecar.metadata,
                    lease: PendingRetryLease(
                        token: lease.token,
                        expiresAt: Date().addingTimeInterval(horizon),
                        duration: lease.duration
                    )
                ),
                in: container
            )) != nil
        }) ?? false
    }

    /// Does this claim still hold its capture? Reads only — no reservation is
    /// taken, extended or dropped.
    ///
    /// It is the question a surface asks after minutes of transcription and
    /// before it acts: handing a transcript to a card, sending a message,
    /// cancelling the deferred notification, showing success. False means
    /// somebody else owns the capture now — an expired reservation was overtaken
    /// — or that the capture is already finished, and in either case this
    /// surface must do nothing further with it.
    func confirmOwnership(_ claim: PendingRetryClaim) async -> Bool {
        guard let container = containerURL else { return false }
        let defaults = defaults
        return (try? withExclusiveLock(in: container) { () -> Bool in
            // Deliberately the reconciled queue rather than the expiry-swept
            // one: a question about ownership may finish an interrupted
            // deletion, but it may not itself retire a capture on the clock.
            let entries = queueLocked(from: defaults, in: container)
            guard entries.contains(where: { $0.id == claim.id }) else { return false }
            return liveLease(for: claim, in: container) != nil
        }) ?? false
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

    /// How many captures are WAITING for somebody, records only.
    ///
    /// Same reading as `pendingCount()` minus the captures under a live
    /// reservation — the same skip `claimNext` makes when it picks one. That is
    /// the difference between a count and a queue depth: an ordinary capture
    /// holds its own reservation for the whole of its transcription, so a
    /// surface rendering `pendingCount()` flashes a "1 waiting" row through
    /// every successful recording somebody makes. Nothing is waiting for a
    /// person while its own lane is still working on it.
    ///
    /// It comes BACK when the lane dies without releasing: the reservation
    /// lapses and the capture counts again, which is exactly the state a retry
    /// card exists to show.
    func waitingCount() async -> Int {
        guard let container = containerURL else { return 0 }
        let defaults = defaults
        return (try? withExclusiveLock(in: container) { () -> Int in
            let now = Date()
            return liveQueueLocked(from: defaults, in: container)
                .filter { !isReserved($0.id, in: container, at: now) }
                .count
        }) ?? 0
    }

    /// The same question for a surface that only needs to know whether to draw
    /// the row at all.
    func hasWaiting() async -> Bool {
        await waitingCount() > 0
    }

    /// Give a capture back without finishing it. The entry and its recording
    /// stay exactly as they are; only the reservation goes, so the next tap —
    /// on this surface or another — can take it.
    func release(_ claim: PendingRetryClaim) async {
        guard let container = containerURL else { return }
        let handedBack = (try? withExclusiveLock(in: container) { () -> Bool in
            guard let sidecar = readSidecar(for: claim.id, in: container),
                  sidecar.lease?.token == claim.token else { return false }
            return (try? writeSidecar(
                PendingRetrySidecar(metadata: sidecar.metadata, lease: nil),
                in: container
            )) != nil
        }) ?? false
        // A hand-back is news: the capture is waiting again, and the row that
        // says how many are is not always this surface's.
        announceQueueChange(handedBack)
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
        let retired = (try? withExclusiveLock(in: container) { () -> Bool in
            let entries = queueLocked(from: defaults, in: container)
            guard holdsLease(claim, in: container) else { return false }
            guard let removed = entries.first(where: { $0.id == claim.id }) else { return false }
            return !finishLocked([removed], from: entries, defaults: defaults, in: container).isEmpty
        }) ?? false
        // A retirement is news for the same reason an arm is: the surface whose
        // row says how many captures are waiting is not always the one that
        // finished this one. A stale positive offers a Retry against an empty
        // queue, which answers "No saved recording to retry." Announced outside
        // the lock and only on a clear that actually happened.
        if retired {
            NotificationCenter.default.post(name: Self.queueDidChangeNotification, object: nil)
        }
        return retired
    }

    /// Retire just the parked SCREENSHOT of the capture this holder is
    /// finishing, now that a card owns the picture.
    ///
    /// Payload-only, and deliberately narrow: the entry, its recording, its
    /// verdict and its words are untouched, because the words may still be
    /// owed. What has to go is the image file, and it has to go THE MOMENT the
    /// picture publishes rather than at the next arm — a later `save` carrying
    /// `workImageData: nil` writes no file and deletes none, so a stale one
    /// survives every subsequent failure of that capture and goes on telling
    /// the expiry sweep this entry shelters the only copy of a picture.
    ///
    /// Under the lease like every other write here: a capture another surface
    /// took over is that surface's to finish, and its picture is not this
    /// one's to delete.
    @discardableResult
    func discardWorkImage(_ claim: PendingRetryClaim) async -> Bool {
        guard let container = containerURL else { return false }
        return (try? withExclusiveLock(in: container) { () -> Bool in
            guard holdsLease(claim, in: container) else { return false }
            remove(container.appendingPathComponent(PendingRetryFiles.workImage(claim.id)))
            return true
        }) ?? false
    }

    /// Retire just the RECORDING of the capture this holder is finishing, now
    /// that the desk holds its words.
    ///
    /// The entry itself stays. It is what a capture that still owes a SCREENSHOT
    /// needs: the words are written, so the recording is waste the moment they
    /// land, but the parked picture may still be the only copy of itself and the
    /// entry is the only thing sheltering it. Clearing the whole entry there
    /// takes the picture with it; leaving the recording instead means audio
    /// outlives the words it produced, on a container that is exempt from the
    /// clock for exactly as long as that picture is owed.
    ///
    /// The STAMP goes first and the file second, so a death in between leaves
    /// `.published` over a recording that is still on disk — true, and a second
    /// copy the day-long clock retires — rather than `.phaseOneFailed` over
    /// bytes that are already gone, which is a retry card offering a recording
    /// nothing can load.
    ///
    /// What is left reads as "the words are done": no recording file, a
    /// `.published` verdict, and whatever picture is still owed. Under the lease
    /// like every other write here — a capture another surface took over is that
    /// surface's to finish.
    @discardableResult
    func retireRecording(_ claim: PendingRetryClaim) async -> Bool {
        guard let container = containerURL else { return false }
        let defaults = defaults
        let retired = (try? withExclusiveLock(in: container) { () -> Bool in
            let entries = queueLocked(from: defaults, in: container)
            guard let lease = liveLease(for: claim, in: container) else { return false }
            guard entries.contains(where: { $0.id == claim.id }) else { return false }
            let stamped = restateLocked(
                id: claim.id,
                in: entries,
                defaults: defaults,
                container: container,
                lease: lease,
                { $0.recording(transcript: nil, publicationState: .published) }
            )
            guard stamped else { return false }
            // The recording alone. The sidecar, the index row and the parked
            // screenshot are all left exactly as they are.
            for destination in PendingRetryDestination.allCases {
                remove(container.appendingPathComponent(
                    PendingRetryFiles.audio(claim.id, destination)
                ))
            }
            remove(container.appendingPathComponent(
                PendingRetryFiles.transitionalAudio(claim.id)
            ))
            return true
        }) ?? false
        if retired {
            NotificationCenter.default.post(name: Self.queueDidChangeNotification, object: nil)
        }
        return retired
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
                let audioData: Data
                if let url = readableAudioURL(for: metadata, in: container) {
                    // Present but unreadable is a locked device, not a lost
                    // recording: skip it and leave it queued.
                    guard let bytes = readAudio(at: url) else { continue }
                    audioData = bytes
                } else if holdsWorkImage(metadata.id, in: container) {
                    // The same entry the claim API offers with no bytes: its
                    // recording went with its words and its picture is still
                    // parked, which is a debt a surface can still settle.
                    audioData = Data()
                } else {
                    doomed.append(metadata)
                    continue
                }
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
    ///
    /// DIAGNOSIS, never a verdict on the next attempt. It answers for ONE entry
    /// while the card it feeds speaks for the queue behind that entry, and it is
    /// a memory of a failure that already happened — indistinguishable, on a
    /// re-read, from one whose remedy the person has since carried out. A
    /// surface that gated its Retry on it withheld the button from every older
    /// capture and never handed it back.
    func pendingErrorCode() async -> Int? {
        guard let container = containerURL else { return nil }
        let defaults = defaults
        return try? withExclusiveLock(in: container) {
            liveQueueLocked(from: defaults, in: container).first?.lastErrorCode
        }
    }

    /// Snapshot of the whole queue, taken in one transaction. The current-format
    /// inspection reads metadata and file presence only, never claims a capture
    /// or loads its audio. It inherits the store's reconciliation and expiry
    /// maintenance: expired files can be deleted, and a legacy migration can
    /// copy or compare recording bytes before the metadata reduction runs.
    func diagnosticSnapshot() async -> PendingRetryDiagnosticSnapshot? {
        guard let container = containerURL else { return nil }
        let defaults = defaults
        return try? withExclusiveLock(in: container) { () -> PendingRetryDiagnosticSnapshot? in
            let entries = liveQueueLocked(from: defaults, in: container)
            let now = Date()
            let captures = entries.map { metadata in
                let sidecarExists = FileManager.default.fileExists(
                    atPath: sidecarURL(for: metadata.id, in: container).path
                )
                let sidecar = readSidecar(for: metadata.id, in: container)
                return PendingRetryDiagnosticSnapshot.Capture(
                    metadata: metadata,
                    audioFileExists: readableAudioURL(for: metadata, in: container) != nil,
                    isActivelyLeased: sidecar?.lease?.isLive(at: now) == true,
                    leaseStateKnown: !sidecarExists || sidecar != nil,
                    holdsWorkImage: holdsWorkImage(metadata.id, in: container)
                )
            }
            // An interrupted arm can leave a recording and sidecar before its
            // index commits. Reconciliation correctly defers an unreadable
            // sidecar instead of fabricating metadata; count that deferred
            // presence as unavailable rather than reporting an empty queue.
            let indexedIDs = Set(entries.map(\.id))
            let files = inventory(in: container)
            let unreadableUnindexedCount = files.sidecars.filter { id in
                !indexedIDs.contains(id) && files.audio[id] != nil
                    && readSidecar(for: id, in: container) == nil
            }.count
            let snapshot = PendingRetryDiagnosticSnapshot(
                captures: captures, now: now, unreadableUnindexedCount: unreadableUnindexedCount
            )
            return snapshot.totalCount > 0 ? snapshot : nil
        }
    }

    /// Purge every capture the clock may retire, and reclaim the files no
    /// queued capture names any more. Called from `ConduckApp` on launch
    /// (privacy: don't leave stale audio sitting in App Groups storage
    /// indefinitely). A recording whose desk card never landed is exempt — see
    /// `PendingRetryMetadata.isExemptFromExpiry` — and a published Work capture
    /// is held for a day rather than ten minutes, because the person whose
    /// words are owed may be driving; `PendingRetryMetadata.retryTTL` is the
    /// one place those two budgets are decided.
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

    /// Say that the queue a surface renders has changed, when it actually did.
    ///
    /// Announced OUTSIDE the lock, always: a listener refreshes its count by
    /// reading this store, and a notification posted from inside would have it
    /// wait on a lock this call still holds.
    private func announceQueueChange(_ changed: Bool) {
        guard changed else { return }
        NotificationCenter.default.post(name: Self.queueDidChangeNotification, object: nil)
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
        }) {
            let alreadyQueued = queuedIDs(in: queueData).contains(slot.id)
            if files.audio[slot.id] != nil {
                // Its bytes are already under its own id — either this fold
                // copied them and died before retiring the fixed name, or an
                // earlier read committed the entry and died before it. The
                // recognition is deliberately NOT conditioned on the entry
                // being absent from the index: the crash window that leaves an
                // already-queued capture beside an un-retired fixed name is
                // exactly the one that used to leak the file for ever, because
                // the next read skipped this step and retired the pointer, and
                // the pointer is the last thing that could name the file.
                retireLegacyRecording = files.hasLegacyRecording
            } else if !alreadyQueued {
                if copyLegacyRecording(
                    to: slot.id,
                    destination: slot.resolvedDestination,
                    files: &files,
                    in: container
                ) {
                    retireLegacyRecording = true
                } else {
                    // Its only recording could not be put under an id. Leave
                    // BOTH the pointer and the file exactly as they are for the
                    // next read; a queued capture with no bytes would be
                    // finished by the next claim, and finishing it is what
                    // deletes the file.
                    entries.removeAll { $0.id == slot.id }
                    foldedLegacySlot = false
                    retireLegacyPointer = false
                }
            }
            // Queued but owning no bytes is the entry an earlier build folded in
            // without moving them; step 3 is what gives it the recording.
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

        // 3b — The fixed name a build BEFORE this ordering left behind. That
        // build retired the pointer before deleting the file, so a death in
        // between removed the only thing that could name the recording. The one
        // safe reading of it is proof rather than inference: it goes only when a
        // queued capture's own recording is byte-for-byte this file, which is
        // proof the recording is preserved. An unreadable file compares unequal,
        // so a locked device leaves it alone.
        if firstReconcile, files.hasLegacyRecording, !retireLegacyRecording,
           legacyRecordingIsDuplicated(of: entries, files: files, in: container) {
            retireLegacyRecording = true
        }

        // 4 — The record is authoritative over its index row. They are never
        // committed together and the record is always written first, so a
        // disagreement is a process that died between the two writes and the
        // record is the newer half. An UNREADABLE record changes nothing: its
        // row is left exactly as it stands and the next read tries again.
        for (position, metadata) in entries.enumerated() {
            guard files.sidecars.contains(metadata.id),
                  let recorded = readSidecar(for: metadata.id, in: container)?.metadata,
                  recorded != metadata else { continue }
            entries[position] = recorded
            changed = true
        }

        // 5 — Adopt every arm that did not commit. The sidecar carries the
        // WHOLE record, so a refused Work publication comes back with its
        // verdict and its words rather than as a capture with neither.
        for id in files.sidecars.sorted(by: { $0.uuidString < $1.uuidString })
        where !entries.contains(where: { $0.id == id }) {
            guard files.audio[id] != nil else {
                // An arm whose bytes never landed. There is no recording to
                // protect and no retry that could succeed.
                remove(container.appendingPathComponent(PendingRetryFiles.sidecar(id)))
                continue
            }
            guard let sidecar = readSidecar(for: id, in: container) else {
                // Unreadable, so this capture DEFERS: the recording stays, the
                // record stays, and nothing is written. Rebuilding the entry
                // from the filename instead would lose the verdict, the words
                // and the language — and that lossy row would then be the
                // authority for ever, because a capture the index names is
                // never re-read from its record.
                continue
            }
            entries.append(sidecar.metadata)
            changed = true
        }

        // 6 — A recording with neither a record nor an index row. Under the
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

        // 7 — Give every index row a record. This is what upgrades a container
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
        if changed || foldedLegacySlot || retireLegacyPointer || retireLegacyRecording {
            do {
                try persist(entries, to: defaults)
                if retireLegacyRecording {
                    // BEFORE the pointer, deliberately. The pointer is the last
                    // thing that can name this recording, so a death between the
                    // two must leave the pointer standing over a file that is
                    // already gone — never a file with nothing left to name it.
                    remove(container.appendingPathComponent(PendingRetryFiles.legacyAudioName))
                }
                if retireLegacyPointer {
                    // Only once the queue carrying it is committed. The pointer
                    // is the sole description of that recording until then.
                    defaults.removeObject(forKey: PendingRetryDefaultsKeys.legacySlot)
                    _ = defaults.synchronize()
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
    ///
    /// A capture under a LIVE reservation is not idle, so the clock does not
    /// reach it: the TTL is a budget for a transcription nobody is performing,
    /// and a provider request may be allowed 300 seconds and attempted three
    /// times, which is longer than the budget itself. Deleting a recording out
    /// from under the surface transcribing it is the one thing the clock must
    /// never do. The reservation lapses when its holder stops renewing, and the
    /// next read applies the clock as normal.
    ///
    /// Nor does the clock reach a capture whose SCREENSHOT is still parked
    /// here. `publicationState` answers for the recording alone — `.published`
    /// says the desk holds it, which is what makes the entry a budget for a
    /// transcription — and a Work capture's picture is published separately, so
    /// the two verdicts can disagree. Until the picture is a card, this
    /// container holds the only copy of it, and a clock is no more a reason to
    /// delete that than it is to delete an unpublished recording.
    private func liveQueueLocked(
        from defaults: any DefaultsStore,
        in container: URL
    ) -> [PendingRetryMetadata] {
        let entries = queueLocked(from: defaults, in: container)
        let now = Date()
        let expired = PendingRetryQueue.partitioningExpired(entries, at: now).expired
            .filter { !isReserved($0.id, in: container, at: now) }
            .filter { !holdsWorkImage($0.id, in: container) }
        guard !expired.isEmpty else { return entries }
        let finished = finishLocked(
            expired, from: entries, defaults: defaults, in: container
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

    /// Might another surface still be holding this capture?
    ///
    /// An UNREADABLE record answers yes. Not knowing who holds a capture is not
    /// a licence to take it, and the two ways a record fails to read — protected
    /// until first unlock, or a decode that fails — are both states where a
    /// live reservation may be sitting in bytes this process cannot see.
    private func isReserved(_ id: UUID, in container: URL, at now: Date) -> Bool {
        let url = sidecarURL(for: id, in: container)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let sidecar = readSidecar(for: id, in: container) else { return true }
        guard let lease = sidecar.lease else { return false }
        return lease.isLive(at: now)
    }

    /// Is this capture's screenshot still parked here?
    ///
    /// The FILE is the question, not the record: the file is written when the
    /// picture is parked and retired by `discardWorkImage` the moment a card
    /// owns it, so its presence is exactly "no card holds this picture yet".
    /// The record cannot answer — its publication verdict describes the
    /// recording, and the two artifacts publish separately.
    private func holdsWorkImage(_ id: UUID, in container: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: container.appendingPathComponent(
                PendingRetryFiles.workImage(id)
            ).path
        )
    }

    /// Take the reservation and hand the capture over. The single place a claim
    /// is minted, so `claimNext` and `claim(id:)` cannot drift on what a
    /// reservation is or on what a claim carries.
    ///
    /// A reservation that cannot be WRITTEN is not a reservation: nothing is
    /// offered, because handing two surfaces the same capture while both believe
    /// they hold it is the defect the lease exists to remove.
    ///
    /// NO URL means the recording was retired the moment this capture's words
    /// landed, and the entry stands only for the screenshot still parked in it.
    /// The claim carries empty bytes, which is the honest shape: there is
    /// nothing to transcribe, the words are on the record already, and what the
    /// holder settles is the picture. A URL that is present but unreadable is
    /// the opposite case — a locked device — and it still offers nothing.
    private func reserveLocked(
        _ metadata: PendingRetryMetadata,
        at audioURL: URL?,
        duration: TimeInterval,
        now: Date,
        in container: URL
    ) -> PendingRetryClaim? {
        let audioData: Data
        if let audioURL {
            guard let bytes = readAudio(at: audioURL) else { return nil }
            audioData = bytes
        } else {
            audioData = Data()
        }
        let lease = PendingRetryLease(
            token: UUID(),
            expiresAt: now.addingTimeInterval(duration),
            duration: duration
        )
        guard (try? writeSidecar(
            PendingRetrySidecar(metadata: metadata, lease: lease),
            in: container
        )) != nil else { return nil }

        return PendingRetryClaim(
            entry: PendingRetryEntry(
                audioData: audioData,
                metadata: metadata,
                workImageData: workImageData(for: metadata, in: container)
            ),
            token: lease.token
        )
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

    /// Is the pre-id-scoped recording a copy of one a queued capture already
    /// owns?
    ///
    /// The fold COPIES rather than moves, so between the copy and the deletion
    /// both files hold the same bytes. If a process died in that window on a
    /// build that retired the pointer first, nothing names the fixed name any
    /// more — and the only honest way to reclaim it is proof that its content
    /// survives elsewhere. Bytes, not sizes or timestamps: an inference here
    /// deletes a recording that may exist nowhere else.
    ///
    /// A file that cannot be read compares unequal, so a locked device answers
    /// false and leaves it.
    private func legacyRecordingIsDuplicated(
        of entries: [PendingRetryMetadata],
        files: Inventory,
        in container: URL
    ) -> Bool {
        let legacy = container.appendingPathComponent(PendingRetryFiles.legacyAudioName)
        for metadata in entries {
            guard let file = files.audio[metadata.id] else { continue }
            if FileManager.default.contentsEqual(
                atPath: legacy.path, andPath: file.url.path
            ) { return true }
        }
        return false
    }

    /// The record a recording can be reconstructed from when nothing else
    /// describes it: its id and destination from the name, and its age from the
    /// file. Everything a recovery branches on is missing, which is why it is
    /// reached only where nothing else CAN describe the recording — a container
    /// the previous layout wrote, which had no records in it at all.
    ///
    /// `workAttachedToMaterialID` stays nil here for the same reason as
    /// `publicationState`: a filename says nothing about whether that press
    /// also took a picture, and a link INFERRED from the capture id would name
    /// a screenshot card that may never have existed. An unlinked recording
    /// renders as its own card, which is the truthful answer.
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
