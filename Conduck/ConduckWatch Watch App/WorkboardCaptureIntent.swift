// SPDX-License-Identifier: Apache-2.0

// ConduckWatch Watch App
// WorkboardCaptureIntent.swift
//
// A text-only Siri and Shortcuts lane onto the single Work desk. This is
// deliberately separate from `RecordNoteIntent`: it appends one inert note card
// and has no gateway, conversation, message, or dispatch codepath. The shared
// ConversationStore keeps the capture in the same private CloudKit-backed model
// the other devices read.
//
// The wrist writes the desk with raw Core Data because
// `ConversationStore+Workboard.swift` is not a member of this target, so
// `upsertDeskMaterial` — the app's one authoritative desk write — cannot be
// called here. The logic below mirrors that op's contract for the one shape the
// wrist produces (a note, no payload): resolve-or-create the desk row, then
// insert-or-return the material by id, all inside ONE managed-object context so
// a capture can never leave a desk without its card. Entity and column names,
// and the `kind`/`storageMode` raw values, are restated here for the same
// reason; `WorkboardRecords.swift` is canonical for them.

import AppIntents
import CoreData
import Foundation

/// One note card's worth of prepared text: the wrist's shape of the same
/// thought the iOS `CaptureWorkboardIntent` hands `WorkMaterialDraft`, so the
/// field names are the material's, not a heading's.
nonisolated struct WatchWorkboardCapture: Equatable, Sendable {
    let title: String
    let textContent: String
}

nonisolated enum WatchWorkboardCaptureText {
    /// Mirrors `WorkCaptureEnvelope.maximumNoteCharacters`, the bound every
    /// other capture ingress enforces — named identically so the source guard
    /// comparing the two spellings has something to compare. The Watch target
    /// does not compile the envelope, so the value is restated here; a Shortcut
    /// can pipe a whole document into this parameter, and an unbounded note is
    /// both unexportable to CloudKit and a cost on every board load.
    static let maximumNoteCharacters = 16_000

    static func prepare(_ rawValue: String) throws -> WatchWorkboardCapture {
        let normalized = rawValue
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw WatchWorkboardCaptureError.emptyThought }
        // Refuse rather than truncate: a silently shortened note looks like a
        // successful capture and loses the part the person cared about.
        guard normalized.count <= maximumNoteCharacters else {
            throw WatchWorkboardCaptureError.thoughtTooLong
        }

        let title = normalized
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            .map { String($0.prefix(72)) }
            ?? String(localized: "workboard.item.untitled", defaultValue: "Untitled note")
        return WatchWorkboardCapture(title: title, textContent: normalized)
    }
}

nonisolated enum WatchWorkboardCaptureError: LocalizedError {
    case emptyThought
    case thoughtTooLong

    var errorDescription: String? {
        switch self {
        case .emptyThought:
            return String(
                localized: "intent.workboardCapture.error.empty",
                defaultValue: "Say or type what you want to prepare first."
            )
        case .thoughtTooLong:
            return String(
                localized: "intent.workboardCapture.error.tooLong",
                defaultValue: "That’s too long to add to Work. Shorten it, then try again."
            )
        }
    }
}

extension ConversationStore {
    /// Append one note card to the Work desk from the wrist.
    ///
    /// DESK IDENTITY comes from `Constants.workboardDeskItemID`, the same
    /// compile-time id every other surface names — `Constants.swift` is a
    /// member of this target, so the wrist reads the canonical value rather
    /// than a copy of it. The desk row is created lazily by the first capture,
    /// holds no editable heading (title and objective stay nil columns) and is
    /// never deleted.
    ///
    /// NO DEDUP. CloudKit forbids a Core Data uniqueness constraint, so two
    /// devices capturing at once can each insert a physical desk row under that
    /// one id. Both writes must stand: the board projects one logical desk and
    /// unions the materials of every physical row, so a duplicate row is
    /// invisible rather than lossy. Deleting the loser would export a deletion
    /// of valid data to every other device.
    ///
    /// IDEMPOTENCY is on `id`: a replayed capture finds its own material and
    /// gets its title back instead of adding a second card.
    ///
    /// RANK is decided here rather than by the caller. The wrist cannot see the
    /// board, so the append position is read inside the same transaction that
    /// writes it.
    func upsertDeskMaterial(
        _ capture: WatchWorkboardCapture,
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) async throws -> String {
        try await ensureLoaded()
        let context = newWriteContext()
        let deskID = Constants.workboardDeskItemID
        let title = try await context.perform { [context] in
            let deskRequest = NSFetchRequest<NSManagedObject>(entityName: "WorkItem")
            deskRequest.predicate = NSPredicate(format: "id == %@", deskID as CVarArg)
            deskRequest.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
            deskRequest.fetchLimit = 1

            var createdDesk = false
            let desk: NSManagedObject
            if let existing = try context.fetch(deskRequest).first {
                desk = existing
            } else {
                desk = NSEntityDescription.insertNewObject(forEntityName: "WorkItem", into: context)
                desk.setValue(deskID, forKey: "id")
                desk.setValue(createdAt, forKey: "createdAt")
                desk.setValue(createdAt, forKey: "updatedAt")
                createdDesk = true
            }

            let materialRequest = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
            materialRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            materialRequest.sortDescriptors = [
                NSSortDescriptor(key: "updatedAt", ascending: false)
            ]
            materialRequest.fetchLimit = 1
            if let existing = try context.fetch(materialRequest).first {
                // The card is already on the desk. The desk row may still be
                // the one this call just created — CloudKit can import a
                // material before its owner — so a re-ensured desk is saved
                // even though the material is untouched.
                if createdDesk { try context.save() }
                return existing.value(forKey: "title") as? String ?? capture.title
            }

            let rankRequest = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
            rankRequest.predicate = NSPredicate(format: "workItemID == %@", deskID as CVarArg)
            rankRequest.sortDescriptors = [NSSortDescriptor(key: "sequence", ascending: false)]
            rankRequest.fetchLimit = 1
            let highestRank = try context.fetch(rankRequest).first
                .flatMap { ($0.value(forKey: "sequence") as? NSNumber)?.intValue }

            let row = NSEntityDescription.insertNewObject(
                forEntityName: "WorkMaterial",
                into: context
            )
            row.setValue(id, forKey: "id")
            row.setValue(deskID, forKey: "workItemID")
            row.setValue("note", forKey: "kind")
            row.setValue(capture.title, forKey: "title")
            row.setValue("", forKey: "caption")
            row.setValue(capture.textContent, forKey: "textContent")
            row.setValue(NSNumber(value: 0), forKey: "byteSize")
            row.setValue(NSNumber(value: Int32(clamping: (highestRank ?? -1) + 1)), forKey: "sequence")
            row.setValue("metadataOnly", forKey: "storageMode")
            // `cardSize` stays nil: standard is the absent value, and the wrist
            // never sizes a card.
            row.setValue("watch", forKey: "sourceDevice")
            row.setValue(createdAt, forKey: "createdAt")
            row.setValue(createdAt, forKey: "updatedAt")
            desk.setValue(createdAt, forKey: "updatedAt")
            try context.save()
            return capture.title
        }
        await postDidChange()
        return title
    }
}

struct CaptureWorkboardIntent: AppIntent {
    static var title: LocalizedStringResource = LocalizedStringResource(
        "intent.workboardCapture.title",
        defaultValue: "Add to Work"
    )

    static var description = IntentDescription(
        LocalizedStringResource(
            "intent.workboardCapture.description",
            defaultValue: "Save a thought to your private Work desk without sending it to an AI."
        )
    )

    static var supportedModes: IntentModes = [.background]

    @Parameter(
        title: LocalizedStringResource(
            "intent.workboardCapture.thought",
            defaultValue: "What needs doing?"
        )
    )
    var thought: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$thought) to Work")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let capture = try WatchWorkboardCaptureText.prepare(thought)
        // Each run of the Shortcut is its own capture, so the material id is
        // minted per invocation rather than derived from the text: two runs
        // carrying the same words are two cards the person asked for.
        let title = try await ConversationStore.shared.upsertDeskMaterial(capture)
        let confirmation = String(
            localized: "intent.workboardCapture.confirmation",
            defaultValue: "Added to Work. Nothing was sent."
        )
        return .result(value: title, dialog: IntentDialog(stringLiteral: confirmation))
    }
}
