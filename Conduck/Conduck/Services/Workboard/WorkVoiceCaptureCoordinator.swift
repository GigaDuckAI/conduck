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
// recovered words beside a recording that is already waiting for them. The two
// ids being the same value is deliberate a second time: the retry lane's
// fallback publication derives its note identity from that same id, so even a
// fallback finds the recording card and returns it unchanged rather than
// putting one utterance on the board twice.

#if !os(watchOS)

import CoreData
import Foundation

enum WorkVoiceCaptureCoordinator {

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
    /// Returns `false`, writing nothing, when this capture owns no recording
    /// card: an empty transcript, a card the person has since deleted, or a
    /// capture lane that never published one (the Shortcuts route, whose
    /// pending-retry id can name an imported screenshot instead). A `false`
    /// answer is what tells the retry surface to fall back to its ordinary
    /// note-shaped publication, so the words are never dropped on the floor.
    @discardableResult
    static func attachTranscript(
        _ transcript: String,
        toRecording captureID: UUID,
        store: ConversationStore = .shared
    ) async throws -> Bool {
        let words = WorkboardWorkspaceCaptureLogic.normalizedThought(transcript)
        guard !words.isEmpty else { return false }
        return try await store.applyWorkVoiceTranscript(
            materialID: captureID,
            transcript: words,
            title: title(forTranscript: words)
        )
    }

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
    /// filename carries a random UUID that means nothing to a person.
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
    /// It refuses anything that is not a recording standing on the desk, and
    /// returns false rather than throwing: the caller's fallback is to publish
    /// the words some other way, which a thrown error would read as a reason to
    /// abandon them.
    ///
    /// The `textContent` column is written unconditionally. Whether a card may
    /// SHOW text it stores is decided in one place, on the read path, by the
    /// same rule that governs every other material; restating it here is how a
    /// writer and a reader start disagreeing.
    func applyWorkVoiceTranscript(
        materialID: UUID,
        transcript: String,
        title: String
    ) async throws -> Bool {
        try await ensureLoaded()
        let context = newWriteContext()
        let changed = try await context.perform { [context] () -> Bool in
            let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
            request.predicate = NSPredicate(format: "id == %@", materialID as CVarArg)
            let rows = try context.fetch(request)
            guard !rows.isEmpty else { return false }
            // Fails closed on every row: a merge that produced one row of a
            // different kind means this id no longer names one recording, and
            // guessing which row is the real one is how a screenshot acquires
            // somebody's spoken words.
            guard rows.allSatisfy({ row in
                WorkMaterialKind(stored: row.value(forKey: "kind") as? String) == .audio
                    && row.value(forKey: "workItemID") as? UUID == Constants.workboardDeskItemID
            }) else { return false }

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
            return true
        }
        if changed { await postDidChange() }
        return changed
    }
}

#endif
