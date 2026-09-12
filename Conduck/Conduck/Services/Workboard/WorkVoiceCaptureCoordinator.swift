// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkVoiceCaptureCoordinator.swift
//
// A Work voice note reaches the desk as WORDS, and this is the only place they
// are written. The recording is never a desk card: it is compressed, parked in
// the device-local retry queue, transcribed, and deleted once the words card
// exists. Nothing appears on the desk until the words arrive.
//
// The order is the whole point. Transcription is the step that fails — an
// unreadable key, an offline device, a model that is not installed, a person
// who abandons a hung request — and the answer to every one of those is the
// parked bytes and a Try Again, not a permanently syncing copy of somebody's
// voice sitting on the board for ever.
//
// `publishTranscript(...)` is the single seam every lane and every retry
// surface writes through. The card it publishes is named by the capture's own
// id, which is also the id the pending-retry record carries, so a replay hours
// later in another process lands on the card it already wrote instead of adding
// a second one.
//
// LOOK BEFORE INSERTING. One capture's words can occupy any of three ids — the
// capture's own, `WorkMaterialCollisionEscape.materialID(forCapture:)` and
// `fallbackNoteID(forCapture:)` — because a card of ANOTHER kind standing at an
// id makes the desk write refuse it, and a refusal never clears on its own. So
// a publication searches all three for a publication that already completed
// before it inserts anything: a `.transcript` at any of them is this capture,
// finished; a legacy `.audio` there is a recording an earlier build put on the
// desk and the words join it; a `.note` at the last-resort id is an earlier
// build's fallback. Inserting at the first FREE id instead publishes a second
// copy the moment somebody deletes the card that caused the original escape.
//
// Only when none of the three answers is a card inserted, at the first of them
// free of a foreign card. `invalidMaterialOwner` moves to the next; every other
// failure is transient over a capture that still exists and reaches the caller
// as a throw, so the parked bytes stay the only copy and the retry survives.
//
// CANCELLATION IS READ INSIDE THE WRITE. "Cancel transcription" is a promise
// about the WORDS, and the gap between a caller's own check and the queued Core
// Data mutation is long enough to hold a press — `ensureLoaded()` opens a store
// on first use. `WorkVoiceWriteAuthorization` is the box the mutation boundary
// itself reads, threaded into the insert (`upsertDeskMaterial(authorization:)`)
// and into the attach alike.
//
// `recover(_:transcript:attachedTo:store:queue:)` is what every retry surface
// calls, and it is thin by design: a record that is not a Work capture is not
// this lane's to write, a capture with no words yet keeps its retry with the
// desk untouched and its bytes parked, and anything else is `publishTranscript`
// followed by the `.published` stamp that says the words are durable somewhere
// other than this entry.
//
// Project placement shares the new card's transaction. A retry answers a
// standing card without touching its placement: later user filing always wins.
// A deleted destination explicitly falls back to All materials and returns that
// recoverable outcome to the surface; a failed fallback keeps the parked clip.
// No capture-to-assignment crash window exists for a successfully filed card.
//
// NOTHING HERE PUBLISHES A RECORDING, and there is no function that could. The
// only desk draft this file builds is `.transcript`; the one `.audio` card it
// can still touch is one an earlier build left standing, and all it does there
// is write the words onto it. `WorkVoicePublicationProhibitionTests` holds that
// rule across every lane, so a surface that wants a playable card has to go
// through the desk's own attachment door like any other file.

#if !os(watchOS)

import CoreData
import CryptoKit
import Foundation

/// The seam's answer, unqualified: consumers are specified against the
/// unqualified name, and the coordinator owns it.
typealias WorkVoiceTranscriptOutcome = WorkVoiceCaptureCoordinator.WorkVoiceTranscriptOutcome

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

    /// The import lane and every voice recovery surface use the same honest
    /// location notice. It reports success without inviting another capture.
    static var savedInAllMaterialsMessage: String {
        String(localized: LocalizedStringResource(
            "workdesk.capture.project.atomic.failed.message",
            defaultValue: "Some items couldn’t be added to the project. They’re safe on Home. Open Home to organise them."
        ))
    }

    #if CONDUCK_TESTING
    /// Stands between the store's first-use load and the queued transcript
    /// write — the one gap a press can land in that no `Task.isCancelled` on
    /// the far side would ever see.
    @MainActor static var transcriptWritePauseForTesting: (@Sendable @MainActor () async -> Void)?
    /// Models a peer publication after project refusal and before the fallback
    /// rescans candidates. No store mutation lock is held at this boundary.
    @MainActor static var projectFallbackPauseForTesting: (@Sendable @MainActor () async throws -> Void)?
    #endif

    /// What became of words offered to a LEGACY recording — the one desk write
    /// this file makes that is not an insert, reached only when a card an
    /// earlier build published is still standing at a capture's id.
    ///
    /// FILE-PRIVATE, and it stays that way: no lane and no surface answers this
    /// question. `publishTranscript` reads it, decides whether the search moves
    /// on, and answers `WorkVoiceTranscriptOutcome` — the only shape a caller
    /// sees. A caller that could see this one would have to know which of three
    /// ids it was asking about, which is exactly the reasoning the seam exists
    /// to hold in one place.
    ///
    /// The distinction is the whole reason this is not a `Bool`: a write that
    /// FAILED throws, and a card that is genuinely not there answers here.
    fileprivate enum WorkVoiceAttachOutcome: Sendable, Equatable {
        /// The recording carries the words — or already did, in which case
        /// nothing was written.
        case attached
        /// No row carries this id any more: the card was deleted between the
        /// search that found it and this write.
        case recordingMissing
        /// The id names a card that is not a recording — re-kinded, or a row a
        /// merge produced. Spoken words must never be written onto it.
        case notAudio
    }

    /// Where a capture's words ended up, and which card carries them.
    ///
    /// All cases mean the same thing to a caller — the words are on the desk
    /// and the parked recording may go — and they differ only in what the
    /// person sees: a card that is the words alone, which is what every capture
    /// produces now, or a legacy recording an earlier build published that took
    /// the words onto itself. The id is carried because the lanes need it: it
    /// is what a capture reports as its material and what a screenshot fold
    /// names.
    enum WorkVoiceTranscriptOutcome: Sendable, Equatable {
        /// A words-only card carries them, under this id.
        case wordsPublished(materialID: UUID)
        /// The project disappeared before insertion. Words are safe and the
        /// caller must explain their location rather than invite a duplicate.
        case wordsPublishedInAllMaterials(materialID: UUID)
        /// A recording published by an earlier build was standing at this id
        /// and took the words onto itself.
        case attachedToRecording(materialID: UUID)

        var savedInAllMaterials: Bool {
            if case .wordsPublishedInAllMaterials = self { return true }
            return false
        }

        /// The card the words are on, whichever shape it took.
        var materialID: UUID {
            switch self {
            case .wordsPublished(let id), .wordsPublishedInAllMaterials(let id), .attachedToRecording(let id):
                return id
            }
        }
    }

    /// Why a publication was refused before anything was written.
    enum WorkVoiceTranscriptRefusal: Error, Sendable, Equatable {
        /// There are no words. A wordless card is exactly the state the desk is
        /// meant never to show, so nothing is written and nothing is answered —
        /// every lane checks its transcript before it reaches this seam, and a
        /// silent empty card would be the one way that check could be skipped
        /// without anybody noticing.
        case noWords
    }

    /// What became of a capture recovered from `PendingRetryStore`.
    ///
    /// The caller's whole duty hangs on it: every case but `retryKept` is
    /// TERMINAL — the words are on the desk and the durable record may be
    /// released, which is what deletes the parked recording — while `retryKept`
    /// and a THROW both mean the record must stay armed. `isTerminal` is the
    /// question to ask; matching on the individual cases to decide it is how one
    /// surface starts clearing a retry the others keep.
    enum WorkVoiceRecoveryOutcome: Sendable, Equatable {
        /// Why the capture was left for another attempt, with nothing written.
        enum RetryKept: Sendable, Equatable {
            /// The record is not a Work capture. Its transcript belongs to the
            /// lane that armed it, and the desk must not be written at all.
            case notAWorkCapture
            /// There are no words yet. Recognition still owes this capture its
            /// transcript, and the recording it came from is parked in the entry
            /// this call is holding — which is where the only copy of it lives
            /// until the words land. Nothing reaches the desk, the bytes stay
            /// exactly where they are, and the non-terminal answer is what every
            /// surface renders as a Try Again.
            case noTranscript
        }

        /// A words-only card carries the recovered transcript.
        case wordsPublished
        case wordsPublishedInAllMaterials
        /// A recording an earlier build had published was standing, and the
        /// words joined it there.
        case attached
        /// Nothing was written and the durable record must stay armed.
        case retryKept(RetryKept)

        var savedInAllMaterials: Bool { self == .wordsPublishedInAllMaterials }

        /// Whether the capture is finished, and its durable record may be
        /// released.
        var isTerminal: Bool {
            switch self {
            case .wordsPublished, .wordsPublishedInAllMaterials, .attached:
                return true
            case .retryKept:
                return false
            }
        }
    }

    /// THE SEAM. The words of one capture become a card on the desk, exactly
    /// once, however many times this is called and from however many processes.
    ///
    /// The card is `WorkMaterialKind.transcript`: `.metadataOnly`, no payload,
    /// `textContent` the normalized words, `title` their first line. It carries
    /// the `sourceDevice` the words were SPOKEN at — not always the process
    /// doing the writing, since a wrist recording is relayed to the phone and
    /// published there — and `attachedTo`, the picture that same press produced,
    /// which is what folds the two into one card on the board.
    ///
    /// IT LOOKS BEFORE IT INSERTS, across all three ids this capture's words may
    /// already occupy. A `.transcript` at any of them is this publication,
    /// already done. A legacy `.audio` there is a recording an earlier build put
    /// on the desk, and the words are written onto it rather than published
    /// beside it. A `.note` at the LAST-RESORT id — and only there — is an
    /// earlier build's fallback note, which is these same words under a
    /// different kind. Searching only the capture id and inserting at the first
    /// free one publishes a second copy the moment the card that caused an
    /// earlier escape is deleted.
    ///
    /// THE INSERT then takes the first id free of a FOREIGN card, in the same
    /// order. `invalidMaterialOwner` says this id names a card of another kind,
    /// which never becomes untrue, so it moves on; every other failure is
    /// transient over a capture that still exists and is rethrown, which is what
    /// keeps the caller's retry armed over the only copy of the recording. A
    /// refusal at all three is rethrown too: there is no fourth id, and a chain
    /// of derived ids has no end.
    ///
    /// `authorization` is read at the Core Data mutation boundary itself, inside
    /// both the insert and the attach. A caller that checked cancellation before
    /// calling has checked it before a suspension that can outlast the press.
    ///
    /// - Throws: `WorkVoiceTranscriptRefusal.noWords` when the transcript
    ///   normalizes to nothing; whatever the store threw otherwise.
    @discardableResult
    static func publishTranscript(
        _ transcript: String,
        forCapture captureID: UUID,
        createdAt: Date,
        sourceDevice: String? = nil,
        attachedTo: UUID? = nil,
        authorization: WorkVoiceWriteAuthorization? = nil,
        projectID: UUID? = nil,
        store: ConversationStore = .shared
    ) async throws -> WorkVoiceTranscriptOutcome {
        let words = WorkboardWorkspaceCaptureLogic.normalizedThought(transcript)
        guard !words.isEmpty else { throw WorkVoiceTranscriptRefusal.noWords }

        let candidates = candidateIDs(forCapture: captureID)
        let lastResortID = candidates[candidates.count - 1]

        for candidate in candidates {
            guard let standing = try await store.fetchWorkMaterial(id: candidate) else { continue }
            switch standing.kind {
            case .transcript:
                // This capture's own card. Answered rather than rewritten: the
                // words are already there, and a second write would spend a
                // CloudKit round trip advancing the desk's revision under
                // whatever board mutation is in flight.
                return try await standingWordsOutcome(
                    materialID: candidate, projectID: projectID, store: store
                )
            case .audio:
                // A recording an earlier build published. The words belong ON
                // it — publishing them beside it leaves a person with a card
                // they can play and a card they can read, for one thing they
                // said once.
                switch try await attachWords(
                    words, to: candidate, authorization: authorization, store: store
                ) {
                case .attached:
                    return .attachedToRecording(materialID: candidate)
                case .recordingMissing, .notAudio:
                    // Deleted, or re-kinded, between the read above and the
                    // write. Whatever stands there now is not this capture's
                    // recording, so the search continues.
                    continue
                }
            case .note where candidate == lastResortID:
                // An earlier build's fallback note: these words, under the kind
                // that build had for them. It is recognised only at the
                // last-resort id, because a `.note` at the capture id or its
                // escape is somebody else's card and has to be escaped, not
                // adopted.
                return try await standingWordsOutcome(
                    materialID: candidate, projectID: projectID, store: store
                )
            default:
                continue
            }
        }

        var refusal: (any Error)?
        for candidate in candidates {
            do {
                let record = try await store.upsertDeskMaterial(
                    WorkMaterialDraft(
                        id: candidate,
                        kind: .transcript,
                        title: title(forTranscript: words),
                        textContent: words,
                        storageMode: .metadataOnly,
                        // The surface the words were SPOKEN at. Every lane that
                        // captures somewhere else states its own; the default
                        // keeps the in-app and intent lanes, which do run where
                        // the person spoke, spelling it exactly once.
                        sourceDevice: sourceDevice ?? SourceDevice.current,
                        // Derived by the CALLER from the ORIGINAL capture id and
                        // carried unchanged onto every candidate. What escapes
                        // here is the WORDS' id; the picture's is derived from
                        // the capture id and no collision on this side moves it,
                        // so a card that lands under its escape names exactly the
                        // picture it would have named under its own id.
                        attachedToMaterialID: attachedTo,
                        createdAt: createdAt
                    ),
                    authorization: authorization,
                    projectID: projectID
                )
                return .wordsPublished(materialID: record.id)
            } catch let error as WorkDeskStoreError where error == .projectNotFound || error == .projectArchived || error == .projectSelectionRequired {
                // The transaction inserted nothing. Preserve the spoken words
                // with the same deterministic capture id, just as imports keep
                // a deleted destination's capture in All materials. A failure
                // here still throws, leaving the durable retry untouched.
                #if CONDUCK_TESTING
                if let pause = await projectFallbackPauseForTesting { try await pause() }
                #endif
                let outcome = try await publishTranscript(
                    words, forCapture: captureID, createdAt: createdAt,
                    sourceDevice: sourceDevice, attachedTo: attachedTo,
                    authorization: authorization, store: store
                )
                switch outcome {
                case .attachedToRecording, .wordsPublishedInAllMaterials:
                    return outcome
                case .wordsPublished:
                    return .wordsPublishedInAllMaterials(materialID: outcome.materialID)
                }
            } catch WorkboardStoreError.invalidMaterialOwner {
                refusal = WorkboardStoreError.invalidMaterialOwner
                continue
            }
        }
        throw refusal ?? WorkboardStoreError.invalidMaterialOwner
    }

    /// A process can die after the fallback card commits and before its
    /// location notice is presented. The durable destination plus current
    /// placement evidence reconstruct that notice without writing anything.
    /// A filed card whose project was later deleted retains its placement row;
    /// it was never refused and must not report a fallback on replay.
    private static func standingWordsOutcome(
        materialID: UUID, projectID: UUID?, store: ConversationStore
    ) async throws -> WorkVoiceTranscriptOutcome {
        if let projectID,
           try await store.isUnfiledWorkCaptureFallback(materialID: materialID, projectID: projectID) {
            return .wordsPublishedInAllMaterials(materialID: materialID)
        }
        return .wordsPublished(materialID: materialID)
    }

    /// The ids one capture's words may occupy, in the order they are searched
    /// and then tried.
    ///
    /// All three are pure functions of the capture id, so two devices replaying
    /// one capture derive the same list and land on the same card. The last is
    /// the end of the line: a chain of derived ids has no end, and every link is
    /// one more card the person never asked for.
    private static func candidateIDs(forCapture captureID: UUID) -> [UUID] {
        [
            captureID,
            WorkMaterialCollisionEscape.materialID(forCapture: captureID),
            fallbackNoteID(forCapture: captureID)
        ]
    }

    /// Write the words onto a legacy recording, honouring a caller's
    /// cancellation box at the mutation boundary when there is one.
    ///
    /// Without one the store makes its own from the ambient task, which is what
    /// every caller that has not thought about cancellation should get.
    private static func attachWords(
        _ words: String,
        to materialID: UUID,
        authorization: WorkVoiceWriteAuthorization?,
        store: ConversationStore
    ) async throws -> WorkVoiceAttachOutcome {
        guard let authorization else {
            return try await store.applyWorkVoiceTranscript(
                materialID: materialID,
                transcript: words,
                title: title(forTranscript: words)
            )
        }
        return try await withTaskCancellationHandler {
            try await store.applyWorkVoiceTranscript(
                materialID: materialID,
                transcript: words,
                title: title(forTranscript: words),
                authorization: authorization
            )
        } onCancel: {
            authorization.cancel()
        }
    }

    /// RECOVERY — the whole of what a retry surface does to the desk.
    ///
    /// Every surface that can recover a parked Work capture (the in-app retry
    /// card, the menu-bar retry, the Shortcuts lane, the wrist relay) calls this
    /// and nothing else. There is one decision left in it and it is not about
    /// the desk: whether this record is even a Work capture, and whether any
    /// words exist yet. Everything after that is `publishTranscript`, which is
    /// idempotent by id and needs no help from a caller that cannot see what the
    /// capture saw.
    ///
    /// A capture with NO WORDS keeps its retry and touches nothing. The parked
    /// bytes are the only copy of the recording, the desk stays empty, and the
    /// non-terminal answer is what every surface renders as a Try Again. This is
    /// the ordinary state of a device whose speech key is missing: the recording
    /// waits, and nothing half-finished appears on the board.
    ///
    /// THROWS whatever the store threw, unchanged. That is a write that failed
    /// over a capture that still exists, so the caller must keep its durable
    /// record and surface a retry; nothing here clears anything, and clearing on
    /// a terminal outcome is the caller's own act (`isTerminal`).
    ///
    /// It takes the CLAIM rather than a bare record because the fact it learns —
    /// that the words are on the desk — belongs in the durable entry the caller
    /// is still holding. A verdict that lives only in this call's local state is
    /// one a crash erases, and an entry still saying `.phaseOneFailed` over a
    /// capture whose words ARE written is exempt from expiry for ever. The words
    /// are stamped with it, so a retry after a crash between this line and the
    /// caller's clear pays for no second transcription.
    ///
    /// `attachedTo` names the picture this capture produced, when one press
    /// produced both. The durable record is the authority —
    /// `PendingRetryMetadata.workAttachedToMaterialID` is written when the
    /// capture is parked and survives the loss of the picture's bytes — so a
    /// caller that states nothing gets the record's own link rather than none,
    /// and a caller that states one is restating it.
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

        // The caller's words win; the entry's are the fallback. A surface that
        // has nothing to say is not a reason to leave words the provider was
        // already paid for sitting in the entry this call is holding.
        let words = WorkboardWorkspaceCaptureLogic.normalizedThought(
            transcript ?? pending.transcript ?? ""
        )
        guard !words.isEmpty else { return .retryKept(.noTranscript) }

        let published = try await publishTranscript(
            words,
            forCapture: pending.id,
            createdAt: pending.createdAt,
            sourceDevice: pending.sourceDevice,
            attachedTo: attachedTo ?? pending.workAttachedToMaterialID,
            projectID: pending.workProjectID,
            store: store
        )
        // Recorded the moment it is true rather than on the way out, and with
        // the WORDS: the desk holds them, so the entry is no longer the only
        // copy of anything, and a crash before the caller's clear leaves a
        // record whose replay writes nothing twice and buys nothing twice.
        _ = await queue.recordPublicationState(
            claim, transcript: words, publicationState: .published
        )
        switch published {
        case .wordsPublished: return .wordsPublished
        case .wordsPublishedInAllMaterials: return .wordsPublishedInAllMaterials
        case .attachedToRecording: return .attached
        }
    }

    /// The LAST-RESORT id: where a capture's words land when both the capture id
    /// and its collision escape name cards of another kind.
    ///
    /// Derived rather than random so a replayed publication lands on the one
    /// card it already wrote instead of adding another, on every device: UUIDv5
    /// over a fixed namespace, so the answer is a pure function of the capture
    /// id. It is also where an earlier build's fallback NOTE was written, which
    /// is why a `.note` standing here — and only here — is read as this
    /// capture's words rather than as somebody else's card.
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

    /// The words card's name: the first line of what was said. Same shape as
    /// `WorkboardWorkspaceCaptureLogic.noteTitle(for:)` — first non-empty line,
    /// clipped — with a spoken capture's own default instead of a thought's.
    static func title(forTranscript transcript: String) -> String {
        let leadLine = WorkboardWorkspaceCaptureLogic.title(for: transcript)
        return leadLine.isEmpty ? untranscribedTitle : leadLine
    }

    /// The name a spoken capture falls back to when its words carry no first
    /// line to take one from — punctuation alone, or a provider that answered
    /// with a line break. A card with no words at all is never published, so
    /// this is a fallback and not a placeholder.
    static var untranscribedTitle: String {
        String(
            localized: "workboard.voice.recording.untitled",
            defaultValue: "Voice note"
        )
    }

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
    ) async throws -> WorkVoiceCaptureCoordinator.WorkVoiceAttachOutcome {
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

    /// The same write with the cancellation box supplied by the CALLER, for a
    /// lane that owns one already — the seam threads one box through the insert
    /// and the attach alike, so a press lands on whichever of the two a
    /// publication turns out to take.
    fileprivate func applyWorkVoiceTranscript(
        materialID: UUID,
        transcript: String,
        title: String,
        authorization: WorkVoiceWriteAuthorization
    ) async throws -> WorkVoiceCaptureCoordinator.WorkVoiceAttachOutcome {
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
        let contextLease = try await newWriteContextLease()
        defer { contextLease.finish() }
        let context = contextLease.context
        let written = try await context.perform { [context] () -> (WorkVoiceCaptureCoordinator.WorkVoiceAttachOutcome, Bool) in
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
