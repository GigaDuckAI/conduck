// SPDX-License-Identifier: Apache-2.0

// Conduck
// CaptureWorkboardIntent.swift
//
// A headless, text-first capture lane for Siri, the Action Button, and custom
// Shortcuts. It appends one inert note card to the single Work desk and has
// intentionally no gateway, conversation, or dispatch dependency. Capturing can
// never equal Send.
//
// Every identifier here is frozen: the intent type name, its title/description/
// parameter keys and the `parameterSummary` phrasing are what an installed
// Shortcut is bound to, so changing any of them silently breaks a Shortcut the
// person already built. The desk it writes to is resolved by
// `ConversationStore.upsertDeskMaterial`, which owns desk identity, rank and
// crash repair for every capture surface.

#if !os(watchOS)
import AppIntents
import Foundation

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
        let normalized = thought
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw CaptureWorkboardIntentError.emptyThought }
        // A Shortcut can pipe a whole document into this parameter. Refuse
        // rather than truncate: a silently shortened note looks like a
        // successful capture and loses the part the person cared about.
        guard normalized.count <= WorkCaptureEnvelope.maximumNoteCharacters else {
            throw CaptureWorkboardIntentError.thoughtTooLong
        }

        let title = normalized
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            .map { String($0.prefix(72)) }
            ?? String(localized: "workboard.item.untitled", defaultValue: "Untitled note")

        // Each run of the Shortcut is its own capture, so the material id is
        // minted here rather than derived from the text: two runs carrying the
        // same words are two cards the person asked for, not a replay. The id
        // is still what the desk op keys idempotency on, so a retry of THIS
        // invocation cannot double-post.
        //
        // Rank is deliberately not stated. A headless lane cannot see the board,
        // and `upsertDeskMaterial` decides the append position inside its own
        // write transaction.
        let record = try await ConversationStore.shared.upsertDeskMaterial(
            WorkMaterialDraft(
                kind: .note,
                title: title,
                textContent: normalized,
                storageMode: .metadataOnly,
                sourceDevice: SourceDevice.current
            )
        )
        let confirmation = String(
            localized: "intent.workboardCapture.confirmation",
            defaultValue: "Added to Work. Nothing was sent."
        )
        return .result(
            value: record.title,
            dialog: IntentDialog(stringLiteral: confirmation)
        )
    }
}

private enum CaptureWorkboardIntentError: LocalizedError {
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
#endif
