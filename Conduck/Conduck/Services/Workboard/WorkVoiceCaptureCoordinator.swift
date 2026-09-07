// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkVoiceCaptureCoordinator.swift
//
// The two phases of a Work voice note, and the only place either one is
// written. A recording becomes a desk card the moment its compressed bytes
// exist — BEFORE speech recognition is attempted — and the transcript is
// written onto that same card if and when it arrives.
//
// The order is the whole point. Transcription is the step that fails: an
// unreadable key, an offline device, a model that is not installed, a person
// who abandons a hung request. Publishing the recording first means every one
// of those costs the words and never the recording, so what is left on the desk
// is a playable card a later retry can still fill in.
//
// Both phases name the card by the capture's own id, which is also the id the
// pending-retry record carries. That is what lets the retry surface repair THIS
// card after the app has been closed and reopened, instead of publishing the
// recovered words beside a recording that is already waiting for them.
//
// A failure and an absence are different answers here. The store refusing a
// write is transient and leaves a card that still wants its words, so it
// throws; only a capture that owns no recording of its own reports it, and only
// then may the words be published some other way — under
// `fallbackNoteID(forCapture:)`, never under the capture id, because the desk
// write is idempotent BY id and would answer a note published there with the
// card that is already sitting on it.
//
// `recover(_:transcript:attachedTo:store:queue:)` is the third and last entry
// point, and the one every retry surface uses. A capture recovered hours later, in another
// process, cannot see what this one saw, so the decision it has to make —
// attach, republish then attach, or publish the words beside a card that is
// gone — is made from the retry record's own `publicationState` rather than
// from an absence, which is a fact with two opposite causes. Duplicating that
// three-way decision at each surface is what let one of them republish a card a
// person had deleted while another quietly dropped the words.
//
// A capture id can also be REFUSED rather than answered: the desk write throws
// `invalidMaterialOwner` when that id already names a card of another kind. A
// refusal never clears on its own, so retrying it verbatim fails identically
// for ever and the queue entry can never leave the queue. The recording is
// therefore put back once more under
// `WorkMaterialCollisionEscape.materialID(forCapture:)`, and the words follow
// it there — which is also why a recovery looks for the recording under BOTH
// ids before it decides there is none. A refusal of the escape id too is
// terminal: the words go beside it as a note, and no third id is ever derived.

#if !os(watchOS)

import CoreData
import CryptoKit
import Foundation

/// Both spellings resolve to one type: consumers were specified against the
/// unqualified name, and the coordinator owns it.
typealias WorkVoiceAttachOutcome = WorkVoiceCaptureCoordinator.WorkVoiceAttachOutcome

/// Same rule for the recovery answer.
typealias WorkVoiceRecoveryOutcome = WorkVoiceCaptureCoordinator.WorkVoiceRecoveryOutcome

/// A cancellation the Core Data write queue can read.
///
/// `Task.isCancelled` is the wrong instrument inside a `context.perform`
/// closure: it answers about the task the queue is running the closure on, not
/// the capture's, so it reads `false` however hard the person pressed Cancel
/// transcription. This box is set from a cancellation handler on whatever
/// thread delivers it and read at the mutation boundary, which is the only
/// place a promise about the WORDS can still be kept.
///
/// `@unchecked Sendable` with a lock rather than an actor, because the reader is
/// a synchronous closure on a queue it may not leave.
final class WorkVoiceWriteAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

enum WorkVoiceCaptureCoordinator {

    #if CONDUCK_TESTING
    /// Stands between the store's first-use load and the queued transcript
    /// write — the one gap a press can land in that no `Task.isCancelled` on
    /// the far side would ever see.
    @MainActor static var transcriptWritePauseForTesting: (@Sendable @MainActor () async -> Void)?
    #endif

    /// What became of a transcript handed to a capture id.
    ///
    /// The distinction is the whole reason this is not a `Bool`: a write that
    /// FAILED throws, and a card that is genuinely not there answers here. Only
    /// the two answers below `attached` say the words have nowhere to land, and
    /// only they permit a caller to publish them some other way; a thrown error
    /// means the words are still owed to a card that exists, so the caller must
    /// keep its pending retry rather than complete the capture.
    enum WorkVoiceAttachOutcome: Sendable, Equatable {
        /// The recording carries the words — or already did, in which case
        /// nothing was written.
        case attached
        /// No row anywhere carries this id: a phase-1 publication the desk
        /// refused, or a card a person deleted while STT was in flight.
        case recordingMissing
        /// The id names a card that is not a recording — a legacy per-capture
        /// material re-homed onto the desk, or a row a merge produced. Spoken
        /// words must never be written onto it.
        case notAudio
    }

    /// What became of a capture recovered from `PendingRetryStore`.
    ///
    /// The caller's whole duty hangs on it: every case but `retryKept` is
    /// TERMINAL — the words are on the desk and the durable record may be
    /// released — while `retryKept` and a THROW both mean the record must stay
    /// armed. `isTerminal` is the question to ask; matching on the individual
    /// cases to decide it is how one surface starts clearing a retry the others
    /// keep.
    enum WorkVoiceRecoveryOutcome: Sendable, Equatable {
        /// Why the capture was left for another attempt, with nothing written.
        enum RetryKept: Sendable, Equatable {
            /// The record is not a Work capture. Its transcript belongs to the
            /// lane that armed it, and the desk must not be written at all.
            case notAWorkCapture
            /// There are no words yet. Recognition still owes this capture its
            /// transcript, and a publication of silence beside the recording
            /// would be worse than none. The RECORDING is secured before this
            /// answer is given: a record saying the desk never took it has its
            /// bytes put back as a playable card first — under the capture's
            /// own id, or its escape when that id names a card of another kind
            /// — so what is still owed is only the words. The one state where
            /// nothing could be secured is a capture whose id AND whose escape
            /// are both taken; its bytes stay in the entry, which is where the
            /// only copy of them was already, and the non-terminal answer is
            /// what every surface renders as a retry error.
            case noTranscript
        }

        /// The words joined the recording that was already standing.
        case attached
        /// Phase one was KNOWN to have failed, so the recording was published
        /// from the parked bytes and the words joined it. One card, exactly as
        /// the capture would have produced first time — under the capture's own
        /// id, or under its collision escape when that id was already a card of
        /// another kind.
        case republishedAndAttached
        /// The capture owns no recording — deleted while recognition was in
        /// flight, or an id that names somebody else's card, or an identity
        /// refused under both the capture id and its escape — so the words
        /// landed beside it under `fallbackNoteID(forCapture:)`.
        case fallbackNotePublished
        /// Nothing was written and the durable record must stay armed.
        case retryKept(RetryKept)

        /// Whether the capture is finished, and its durable record may be
        /// released.
        var isTerminal: Bool {
            switch self {
            case .attached, .republishedAndAttached, .fallbackNotePublished:
                return true
            case .retryKept:
                return false
            }
        }
    }

    /// PHASE 1 — the recording becomes a card, before anything is transcribed.
    ///
    /// The bytes are COPIED into whichever lane `WorkMaterialStoragePolicy`
    /// picks inside the desk write, exactly as every other capture is: a
    /// compressed voice note is far below the sync ceiling, so it normally
    /// rides the person's private CloudKit as a blob. The caller keeps sole
    /// ownership of whatever temporary file it wrote for the transcription hop
    /// — nothing here reads, retains, moves or deletes it.
    ///
    /// Idempotent through the desk write: replaying one capture id returns the
    /// card that is already there instead of adding a second one.
    ///
    /// A throw means the recording is not on the desk. There is no answer for
    /// that but to keep the bytes and try again — a capture whose card never
    /// landed is not a capture that succeeded with words only.
    ///
    /// `sourceDevice` names the surface the words were SPOKEN at, which is not
    /// always the process doing the writing: a wrist recording is relayed to
    /// the phone and published there, so `SourceDevice.current` would call it
    /// an iPhone note. Every surface that captures somewhere else passes its
    /// own value; the default keeps the in-app and intent lanes, which do run
    /// where the person spoke, spelling it exactly once.
    ///
    /// `attachedTo` is the PICTURE this recording belongs to, when one press
    /// produced both. It is supplied by the CALLER and never derived here, and
    /// that is the whole reason it is a parameter: `captureID` is not always
    /// the capture's own id — the escape republication below passes
    /// `WorkMaterialCollisionEscape.materialID(forCapture:)` through it — so a
    /// derivation taken from this parameter would name a picture that does not
    /// exist. Every caller derives it from the ORIGINAL capture id.
    ///
    /// A promise about IDENTITY, not existence: it is set whenever the capture
    /// carried a picture at this moment, even if that picture's own
    /// publication failed, so a retry that lands the picture later needs no
    /// repair. Nil for every lane that captures no picture — the wrist relay,
    /// CarPlay, a plain voice note.
    @discardableResult
    static func publishRecording(
        captureID: UUID,
        audio: Data,
        fileExtension: String,
        mimeType: String,
        createdAt: Date = Date(),
        sourceDevice: String = SourceDevice.current,
        attachedTo: UUID? = nil,
        store: ConversationStore = .shared
    ) async throws -> WorkMaterialRecord {
        try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                id: captureID,
                kind: .audio,
                title: untranscribedTitle,
                filename: "\(recordingFilenameStem).\(fileExtension)",
                mimeType: mimeType,
                payload: audio,
                byteSize: Int64(audio.count),
                sourceDevice: sourceDevice,
                attachedToMaterialID: attachedTo,
                createdAt: createdAt
            )
        )
    }

    /// PHASE 2 — the words join the recording they came from.
    ///
    /// THROWS only when the store itself refused the write. That is a transient
    /// failure over a card that exists, so the caller must keep the capture
    /// pending — its bytes and its words — and offer a retry; treating it as
    /// "there is no card" would strand a playable recording that is still
    /// waiting for its transcript while the same words go somewhere else.
    ///
    /// `.recordingMissing` and `.notAudio` are the two answers that say the
    /// words have nowhere to land here, and they are the only ones that permit
    /// a fallback publication — under `fallbackNoteID(forCapture:)`, never
    /// under the capture id itself.
    ///
    /// Idempotent: a second delivery of the same words writes nothing, bumps
    /// nothing and notifies nobody, so a retried attachment cannot advance the
    /// desk's revision under an unrelated board mutation.
    @discardableResult
    static func attachTranscript(
        _ transcript: String,
        toRecording captureID: UUID,
        store: ConversationStore = .shared
    ) async throws -> WorkVoiceAttachOutcome {
        // An empty transcript asks for nothing, so the store classifies the id
        // and writes nothing. It must still answer truthfully about the card:
        // reporting `.recordingMissing` for a recording that is standing fine
        // would invite a fallback publication of silence beside it.
        let words = WorkboardWorkspaceCaptureLogic.normalizedThought(transcript)
        return try await store.applyWorkVoiceTranscript(
            materialID: captureID,
            transcript: words,
            title: title(forTranscript: words)
        )
    }

    /// RECOVERY — the whole of what a retry surface does to the desk, and the
    /// only place the attach-or-fallback decision is made.
    ///
    /// Every surface that can recover a parked Work capture (the in-app retry
    /// card, the menu-bar retry, the Shortcuts lane) calls this and nothing
    /// else. They cannot see what the capture saw, and the question they face
    /// has two opposite right answers behind one observation: an id that names
    /// no card is either a publication the desk refused — the bytes in hand are
    /// the only copy and belong back on the desk — or a card a person deleted
    /// while recognition was in flight, which must stay deleted. The retry
    /// record's `publicationState` is the only thing that tells them apart, and
    /// a nil one (a record written before it was recorded) is UNKNOWN, so it
    /// takes the conservative branch: attach, and publish the words beside a
    /// missing card rather than resurrecting it.
    ///
    /// The RECORDING is dealt with before the transcript is even read. A record
    /// that says the desk never took it holds the only copy of it, and that is
    /// true whether or not recognition has produced any words — so those bytes
    /// go back on the desk first, and the words join whatever is standing there
    /// afterwards.
    ///
    /// THROWS whatever the store threw, unchanged. That is a write that failed
    /// over a capture that still exists, so the caller must keep its durable
    /// record and surface a retry; nothing here clears anything, and clearing
    /// on a terminal outcome is the caller's own act (`isTerminal`).
    ///
    /// The one refusal that is NOT rethrown is a colliding identity. A desk
    /// write that answers `invalidMaterialOwner` says this id belongs to a card
    /// of another kind, and that never becomes untrue — so rethrowing it leaves
    /// a queue entry every retry fails on identically, for ever. The recording
    /// goes back under `WorkMaterialCollisionEscape.materialID(forCapture:)`
    /// instead, ONCE, and a refusal of that id too is terminal: the words land
    /// beside it as a note, and no third id is ever derived.
    ///
    /// It takes the CLAIM rather than a bare record because the two facts it
    /// learns — that the recording is on the desk again, and which id carries
    /// it — belong in the durable entry the caller is still holding. A verdict
    /// that lives only in this call's local state is one a crash erases, and
    /// `.phaseOneFailed` left standing over a recording that IS on the desk is
    /// what lets a later retry resurrect a card the person deleted.
    ///
    /// Idempotent in all four branches — the republication, the escape, the
    /// attachment and the fallback note are each keyed by a derived-or-given id
    /// the desk write answers rather than duplicates — so a capture recovered
    /// twice, or on two devices, still has exactly the cards it had after the
    /// first.
    ///
    /// `attachedTo` names the picture this capture's recording belongs to, for
    /// the one branch that WRITES a recording: the republication. The durable
    /// record is the authority — `PendingRetryMetadata.workAttachedToMaterialID`
    /// is written when the capture is parked and survives the loss of the
    /// picture's bytes — so a caller that states nothing gets the record's own
    /// link rather than none, and a caller that states one is restating it.
    /// Nothing else here takes it: the attachment writes words onto a card that
    /// already carries its link, and the FALLBACK NOTE never carries one at all
    /// — it is not a recording, and folding a note is a decision this iteration
    /// did not take.
    @discardableResult
    static func recover(
        _ claim: PendingRetryClaim,
        transcript: String?,
        attachedTo: UUID? = nil,
        store: ConversationStore = .shared,
        queue: PendingRetryStore = .shared
    ) async throws -> WorkVoiceRecoveryOutcome {
        let pending = claim.entry.metadata
        guard pending.resolvedDestination == .work else {
            return .retryKept(.notAWorkCapture)
        }

        let captureID = pending.id
        let escapeID = WorkMaterialCollisionEscape.materialID(forCapture: captureID)
        let attachedPictureID = attachedTo ?? pending.workAttachedToMaterialID

        // The one state that licenses a republication: the desk is KNOWN never
        // to have held this recording, so there is nothing to resurrect and the
        // parked bytes are the only copy of it. Empty bytes name no recording
        // at all, and the words fall through to the note-shaped answer below.
        //
        // It happens BEFORE the transcript is examined, and that order is the
        // point: a capture that has no words yet is exactly the capture whose
        // recording exists nowhere but in these bytes, and refusing to look at
        // it until recognition succeeds is how a recording waits on a
        // transcription that may never arrive.
        var republication = Republication.notAttempted
        if pending.publicationState == .phaseOneFailed, !claim.entry.audioData.isEmpty {
            republication = try await republishRecording(
                claim.entry.audioData,
                under: captureID,
                escapingTo: escapeID,
                createdAt: pending.createdAt,
                attachedTo: attachedPictureID,
                store: store
            )
            // The desk holds the recording again, so record that the moment it
            // is true rather than on the way out. A recovery that answers
            // `.noTranscript` returns with the entry still armed, and an entry
            // that still says `.phaseOneFailed` is exempt from expiry for ever
            // and licenses a later retry to republish a card the person may
            // have deleted in between.
            if case .landed = republication {
                _ = await queue.recordPublicationState(
                    claim, transcript: nil, publicationState: .published
                )
            }
        }

        // The caller's words win; the entry's are the fallback. A surface that
        // has nothing to say is not a reason to leave words the provider was
        // already paid for sitting in the entry this call is holding.
        let words = WorkboardWorkspaceCaptureLogic.normalizedThought(
            transcript ?? pending.transcript ?? ""
        )
        guard !words.isEmpty else { return .retryKept(.noTranscript) }

        for materialID in republication.recordingIDs(captureID: captureID, escapeID: escapeID) {
            switch try await attachTranscript(words, toRecording: materialID, store: store) {
            case .attached:
                return republication.isLanded ? .republishedAndAttached : .attached
            case .recordingMissing, .notAudio:
                continue
            }
        }

        try await publishFallbackNote(
            words,
            forCapture: captureID,
            createdAt: pending.createdAt,
            store: store
        )
        return .fallbackNotePublished
    }

    /// What became of a recovery's attempt to put the recording back.
    private enum Republication {
        /// The verdict did not license one: the desk is believed to hold this
        /// recording already, or the entry parked no bytes.
        case notAttempted
        /// The recording is on the desk under this id — the capture's own, or
        /// its escape.
        case landed(UUID)
        /// Both ids name cards of another kind. Nothing can carry the
        /// recording, and no third id exists.
        case refusedTwice

        var isLanded: Bool {
            if case .landed = self { return true }
            return false
        }

        /// The ids the transcript must be offered to, in order.
        ///
        /// A republication names exactly where the recording is. Without one,
        /// the recording may be standing under either id — the capture's own,
        /// or an escape a PREVIOUS recovery took — and trying only the first
        /// would write the words into a note beside a recording that was there
        /// to carry them. A double refusal leaves nothing to try.
        func recordingIDs(captureID: UUID, escapeID: UUID) -> [UUID] {
            switch self {
            case .notAttempted: return [captureID, escapeID]
            case .landed(let id): return [id]
            case .refusedTwice: return []
            }
        }
    }

    /// Put the parked bytes back on the desk, escaping a colliding id once.
    ///
    /// The container is read off the bytes rather than assumed from the parked
    /// file's name: both capture lanes preserve COMPRESSED bytes and the
    /// compressor answers WAV whenever AAC encoding fails.
    ///
    /// Only `invalidMaterialOwner` is caught. Every other failure is transient
    /// over a capture that still exists and must reach the caller as a throw,
    /// so the entry stays armed and the bytes stay the only copy of themselves.
    ///
    /// BOTH attempts carry the SAME `attachedTo`. What escapes here is the
    /// RECORDING's id; the picture's is derived from the capture id and is not
    /// affected by a collision on the audio side, so a recording that lands
    /// under its escape names exactly the picture it would have named under its
    /// own id. Deriving the link from `escapeID` — or from the `captureID`
    /// parameter of the inner call — would name a card nothing ever publishes.
    private static func republishRecording(
        _ audio: Data,
        under captureID: UUID,
        escapingTo escapeID: UUID,
        createdAt: Date,
        attachedTo: UUID?,
        store: ConversationStore
    ) async throws -> Republication {
        let container = SourceAudioContainer.sniff(audio)
        do {
            _ = try await publishRecording(
                captureID: captureID,
                audio: audio,
                fileExtension: container.fileExtension,
                mimeType: container.mimeType,
                createdAt: createdAt,
                attachedTo: attachedTo,
                store: store
            )
            return .landed(captureID)
        } catch WorkboardStoreError.invalidMaterialOwner {
            do {
                _ = try await publishRecording(
                    captureID: escapeID,
                    audio: audio,
                    fileExtension: container.fileExtension,
                    mimeType: container.mimeType,
                    createdAt: createdAt,
                    attachedTo: attachedTo,
                    store: store
                )
                return .landed(escapeID)
            } catch WorkboardStoreError.invalidMaterialOwner {
                return .refusedTwice
            }
        }
    }

    /// The words as their own card, for a capture whose recording is not there
    /// to carry them.
    ///
    /// It names itself from its first line, the way the recording would have
    /// once it had words — a person who sees this card is looking at what they
    /// said, and a capture-lane label would name a mechanism they never used.
    /// Written straight to the desk rather than queued: the durable copy of
    /// these words is the retry record the caller is still holding, so a
    /// refused write must reach that caller as a throw and not be absorbed by a
    /// second queue it would then have to be told to stop trusting.
    ///
    /// It carries NO `attachedToMaterialID`, deliberately. The link is written
    /// on recordings alone: a note folded into a picture's card would lose the
    /// full-text route that is the only way to read it, and this iteration
    /// leaves text and pictures as two cards. A note that names a picture would
    /// also be a second kind of child the board fold has to reason about.
    private static func publishFallbackNote(
        _ words: String,
        forCapture captureID: UUID,
        createdAt: Date,
        store: ConversationStore
    ) async throws {
        _ = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                id: fallbackNoteID(forCapture: captureID),
                kind: .note,
                title: title(forTranscript: words),
                textContent: words,
                storageMode: .metadataOnly,
                sourceDevice: SourceDevice.current,
                createdAt: createdAt
            )
        )
    }

    /// The material id a fallback publication must use when a capture owns no
    /// recording card of its own.
    ///
    /// It cannot be the capture id: the desk write is idempotent BY id, so a
    /// note published at the capture id of an existing card (a card the capture
    /// id names that is not a recording, or a recording whose kind check
    /// refused the words) answers with that card unchanged — no duplicate, but
    /// no words either. Derived rather than random so a replayed retry lands on the one
    /// note it already published instead of adding another, on every device:
    /// UUIDv5 over a fixed namespace, so the answer is a pure function of the
    /// capture id.
    static func fallbackNoteID(forCapture id: UUID) -> UUID {
        var hasher = Insecure.SHA1()
        withUnsafeBytes(of: fallbackNoteNamespace.uuid) { hasher.update(bufferPointer: $0) }
        withUnsafeBytes(of: id.uuid) { hasher.update(bufferPointer: $0) }
        var bytes = Array(hasher.finalize().prefix(16))
        // RFC 4122 §4.3: name-based, SHA-1 (version 5) and the standard variant.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Compile-time namespace for `fallbackNoteID(forCapture:)`. A literal, in
    /// the same spirit as the desk's own fixed id: two devices replaying one
    /// capture must derive the same note id or the replay duplicates it.
    private static let fallbackNoteNamespace =
        UUID(uuidString: "DE5C0F00-0000-4000-A000-000000000001")!

    /// The card's name before there are any words to name it with, and again
    /// whenever a transcript turns out to carry no first line. Same shape as
    /// `WorkboardWorkspaceCaptureLogic.noteTitle(for:)` — first non-empty line,
    /// clipped — with the recording's own default instead of a thought's.
    static func title(forTranscript transcript: String) -> String {
        let leadLine = WorkboardWorkspaceCaptureLogic.title(for: transcript)
        return leadLine.isEmpty ? untranscribedTitle : leadLine
    }

    /// Placeholder title carried by a card whose words have not arrived — a
    /// failed transcription, or the moments before a successful one.
    static var untranscribedTitle: String {
        String(
            localized: "workboard.voice.recording.untitled",
            defaultValue: "Voice note"
        )
    }

    /// Names the payload for the card's file line. The capture's own temporary
    /// filename is a machine identity that means nothing to a person.
    private static let recordingFilenameStem = "voice-note"
}

private extension ConversationStore {
    /// Write a transcript onto the recording card it came from, in one save.
    ///
    /// This is a content edit, not a repair: the bytes are already durable and
    /// are not touched, and the material's storage lane is not re-decided. The
    /// desk's own `updatedAt` advances with the card's because the words are
    /// board content — the same reason `reorderWorkMaterials` advances it and
    /// `setWorkMaterialCardSize` deliberately does not.
    ///
    /// EVERY physical row of the material is written. CloudKit can materialize
    /// one logical card as several rows, and whichever row wins the canonical
    /// read must carry the transcript rather than a stale empty one.
    ///
    /// It classifies anything that is not a recording standing on the desk
    /// rather than throwing: the caller's fallback is to publish the words some
    /// other way, which a thrown error would read as a reason to abandon them.
    /// A throw here means only that the write itself failed.
    ///
    /// A delivery that asks for values every row already holds writes nothing,
    /// bumps nothing and posts nothing. The words arrive more than once by
    /// design — a retry surface re-attaches after an interrupted app launch —
    /// and a rewrite would spend a CloudKit round trip on identical bytes and
    /// advance the desk's revision under whatever board mutation is in flight.
    ///
    /// The `textContent` column is written unconditionally. Whether a card may
    /// SHOW text it stores is decided in one place, on the read path, by the
    /// same rule that governs every other material; restating it here is how a
    /// writer and a reader start disagreeing.
    func applyWorkVoiceTranscript(
        materialID: UUID,
        transcript: String,
        title: String
    ) async throws -> WorkVoiceAttachOutcome {
        // The authorization the WRITE itself can read. `Task.isCancelled` inside
        // a `context.perform` closure answers about the queue's own task rather
        // than this one, so it reads `false` however hard the person pressed —
        // a check that looks right and is not. This box is set from the
        // cancellation handler, on whatever thread delivers it, and read at the
        // mutation boundary below.
        let authorization = WorkVoiceWriteAuthorization()
        return try await withTaskCancellationHandler {
            try await applyWorkVoiceTranscript(
                materialID: materialID,
                transcript: transcript,
                title: title,
                authorization: authorization
            )
        } onCancel: {
            authorization.cancel()
        }
    }

    private func applyWorkVoiceTranscript(
        materialID: UUID,
        transcript: String,
        title: String,
        authorization: WorkVoiceWriteAuthorization
    ) async throws -> WorkVoiceAttachOutcome {
        try await ensureLoaded()
        // THE WRITE BOUNDARY, and the last place the cancel can still mean
        // something. "Cancel transcription" is a promise about the WORDS, and
        // the recorder's own check is upstream of `ensureLoaded()` — which opens
        // a store on first use and can suspend for as long as that takes. A
        // press landing in there used to be answered only AFTER the words were
        // on the card, by a check that changed the sentence and not the desk.
        //
        // Cooperative, and it throws rather than reporting an outcome: nothing
        // was attempted, so there is no attachment verdict to report, and the
        // recorder maps a cancelled capture to `.idle` with no banner and no
        // retry save — the same answer its provider hop already gives.
        try Task.checkCancellation()
        #if CONDUCK_TESTING
        // Exactly the gap this authorization exists for: the store is open, the
        // check above has passed, and the write has not been queued yet. The
        // production path has no statement here at all.
        if let pause = await WorkVoiceCaptureCoordinator.transcriptWritePauseForTesting {
            await pause()
        }
        #endif
        let context = newWriteContext()
        let written = try await context.perform { [context] () -> (WorkVoiceAttachOutcome, Bool) in
            let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
            request.predicate = NSPredicate(format: "id == %@", materialID as CVarArg)
            let rows = try context.fetch(request)
            guard !rows.isEmpty else { return (.recordingMissing, false) }
            // Fails closed on every row: a merge that produced one row of a
            // different kind means this id no longer names one recording, and
            // guessing which row is the real one is how a screenshot acquires
            // somebody's spoken words.
            guard rows.allSatisfy({ row in
                WorkMaterialKind(stored: row.value(forKey: "kind") as? String) == .audio
                    && row.value(forKey: "workItemID") as? UUID == Constants.workboardDeskItemID
            }) else { return (.notAudio, false) }

            // Nothing was asked for, or every physical row already answers it.
            guard !transcript.isEmpty, rows.contains(where: { row in
                row.value(forKey: "textContent") as? String != transcript
                    || row.value(forKey: "title") as? String != title
            }) else { return (.attached, false) }

            // THE MUTATION BOUNDARY. The check above was taken before this
            // closure was queued and before the fetches inside it ran, and
            // "Cancel transcription" is a promise about the WORDS: a press that
            // landed in that gap has to be answered here, where the words would
            // otherwise be written. It throws, because nothing was attempted —
            // there is no attachment verdict to report, and the recorder maps a
            // cancellation to `.idle` with no banner and no retry save.
            guard !authorization.isCancelled else { throw CancellationError() }

            let now = Date()
            for row in rows {
                row.setValue(transcript, forKey: "textContent")
                row.setValue(title, forKey: "title")
                row.setValue(now, forKey: "updatedAt")
            }
            let desk = NSFetchRequest<NSManagedObject>(entityName: "WorkItem")
            desk.predicate = NSPredicate(
                format: "id == %@", Constants.workboardDeskItemID as CVarArg
            )
            for row in try context.fetch(desk) {
                row.setValue(now, forKey: "updatedAt")
            }
            try context.save()
            return (.attached, true)
        }
        // Only a save is worth a notification: a board that redraws for a write
        // that did not happen is how a no-op becomes visible churn.
        if written.1 { await postDidChange() }
        return written.0
    }
}

#endif
