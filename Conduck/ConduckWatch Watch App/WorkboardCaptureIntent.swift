// SPDX-License-Identifier: Apache-2.0

// ConduckWatch Watch App
// WorkboardCaptureIntent.swift
//
// A text-only Siri and Shortcuts lane into the private Workboard. This is
// deliberately separate from `RecordNoteIntent`: it inserts one inert WorkItem
// and has no gateway, conversation, message, or dispatch codepath. The shared
// ConversationStore keeps the capture in the same private CloudKit-backed model
// the other devices read.

import AppIntents
import CoreData
import Foundation

nonisolated struct WatchWorkboardCapture: Equatable, Sendable {
    let title: String
    let objective: String
}

nonisolated enum WatchWorkboardCaptureText {
    /// Mirrors `WorkCaptureEnvelope.maximumNoteCharacters`, the bound every
    /// other capture ingress enforces. The Watch target does not compile the
    /// envelope, so the value is restated here; a Shortcut can pipe a whole
    /// document into this parameter, and an unbounded objective is both
    /// unexportable to CloudKit and a cost on every board load.
    static let maximumObjectiveCharacters = 16_000

    static func prepare(_ rawValue: String) throws -> WatchWorkboardCapture {
        let normalized = rawValue
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw WatchWorkboardCaptureError.emptyThought }
        // Refuse rather than truncate: a silently shortened brief looks like a
        // successful capture and loses the part the person cared about.
        guard normalized.count <= maximumObjectiveCharacters else {
            throw WatchWorkboardCaptureError.thoughtTooLong
        }

        let title = normalized
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            .map { String($0.prefix(72)) }
            ?? String(localized: "workboard.item.untitled", defaultValue: "Untitled brief")
        return WatchWorkboardCapture(title: title, objective: normalized)
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
    /// The wrist intentionally owns only this narrow Workboard write. Keeping
    /// the insertion here avoids pulling the editor, asset vault, or dispatch
    /// implementation into the Watch target while preserving the same store.
    func createInertWatchWorkboardCapture(
        _ capture: WatchWorkboardCapture,
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) async throws -> String {
        try await ensureLoaded()
        let context = newWriteContext()
        let title = try await context.perform { [context] in
            let request = NSFetchRequest<NSManagedObject>(entityName: "WorkItem")
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            request.fetchLimit = 1
            if let existing = try context.fetch(request).first {
                return existing.value(forKey: "title") as? String ?? capture.title
            }

            let row = NSEntityDescription.insertNewObject(forEntityName: "WorkItem", into: context)
            row.setValue(id, forKey: "id")
            row.setValue(capture.title, forKey: "title")
            row.setValue(capture.objective, forKey: "objective")
            row.setValue(false, forKey: "isPinned")
            row.setValue(createdAt, forKey: "createdAt")
            row.setValue(createdAt, forKey: "updatedAt")
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
            defaultValue: "Save a thought as a private Workboard draft without sending it to an AI."
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
        let title = try await ConversationStore.shared.createInertWatchWorkboardCapture(capture)
        let confirmation = String(
            localized: "intent.workboardCapture.confirmation",
            defaultValue: "Added to Workboard. Nothing was sent."
        )
        return .result(value: title, dialog: IntentDialog(stringLiteral: confirmation))
    }
}
