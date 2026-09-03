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
// `recover(_:transcript:store:)` is the third and last entry point, and the one
// every retry surface uses. A capture recovered hours later, in another
// process, cannot see what this one saw, so the decision it has to make —
// attach, republish then attach, or publish the words beside a card that is
// gone — is made from the retry record's own `publicationState` rather than
// from an absence, which is a fact with two opposite causes. Duplicating that
// three-way decision at each surface is what let one of them republish a card a
// person had deleted while another quietly dropped the words.

#if !os(watchOS)

import CoreData
import CryptoKit
import Foundation

/// Both spellings resolve to one type: consumers were specified against the
/// unqualified name, and the coordinator owns it.
typealias WorkVoiceAttachOutcome = WorkVoiceCaptureCoordinator.WorkVoiceAttachOutcome

/// Same rule for the recovery answer.
typealias WorkVoiceRecoveryOutcome = WorkVoiceCaptureCoordinator.WorkVoiceRecoveryOutcome

enum WorkVoiceCaptureCoordinator {

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
            /// bytes put back as a playable card first, so what is still owed
            /// is only the words.
            case noTranscript
        }

        /// The words joined the recording that was already standing.
        case attached
        /// Phase one was KNOWN to have failed, so the recording was published
        /// under the capture id from the parked bytes and the words joined it.
        /// One card, exactly as the capture would have produced first time.
        case republishedAndAttached
        /// The capture owns no recording — deleted while recognition was in
        /// flight, or an id that names somebody else's card — so the words
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
    @discardableResult
    static func publishRecording(
        captureID: UUID,
        audio: Data,
        fileExtension: String,
        mimeType: String,
        createdAt: Date = Date(),
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
                sourceDevice: SourceDevice.current,
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
    /// Idempotent in all three branches — the republication, the attachment and
    /// the fallback note are each keyed by a derived-or-given id the desk write
    /// answers rather than duplicates — so a capture recovered twice, or on two
    /// devices, still has exactly the cards it had after the first.
    @discardableResult
    static func recover(
        _ pending: PendingRetryRecord,
        transcript: String,
        store: ConversationStore = .shared
    ) async throws -> WorkVoiceRecoveryOutcome {
        guard pending.metadata.resolvedDestination == .work else {
            return .retryKept(.notAWorkCapture)
        }

        let captureID = pending.metadata.id
        var republished = false
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
        if pending.metadata.publicationState == .phaseOneFailed, !pending.audio.isEmpty {
            let container = SourceAudioContainer.sniff(pending.audio)
            _ = try await publishRecording(
                captureID: captureID,
                audio: pending.audio,
                fileExtension: container.fileExtension,
                mimeType: container.mimeType,
                createdAt: pending.metadata.createdAt,
                store: store
            )
            republished = true
        }

        let words = WorkboardWorkspaceCaptureLogic.normalizedThought(transcript)
        guard !words.isEmpty else { return .retryKept(.noTranscript) }

        switch try await attachTranscript(words, toRecording: captureID, store: store) {
        case .attached:
            return republished ? .republishedAndAttached : .attached
        case .recordingMissing, .notAudio:
            try await publishFallbackNote(
                words,
                forCapture: captureID,
                createdAt: pending.metadata.createdAt,
                store: store
            )
            return .fallbackNotePublished
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
        try await ensureLoaded()
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
