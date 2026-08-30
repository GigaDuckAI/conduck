// SPDX-License-Identifier: Apache-2.0

// Conduck
// CaptureWorkboardIntent.swift
//
// A headless, text-first capture lane for Siri, the Action Button, and custom
// Shortcuts. It creates an inert private Workboard draft and has intentionally no
// gateway, conversation, or dispatch dependency. Capturing can never equal Send.

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
        Summary("Add \(\.$thought) to Workboard")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let normalized = thought
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw CaptureWorkboardIntentError.emptyThought }

        let title = normalized
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            .map { String($0.prefix(72)) }
            ?? String(localized: "workboard.item.untitled", defaultValue: "Untitled brief")

        let record = try await ConversationStore.shared.createWorkItem(
            WorkItemDraft(content: WorkItemContent(title: title, objective: normalized))
        )
        let confirmation = String(
            localized: "intent.workboardCapture.confirmation",
            defaultValue: "Added to Workboard. Nothing was sent."
        )
        return .result(
            value: record.content.title,
            dialog: IntentDialog(stringLiteral: confirmation)
        )
    }
}

private enum CaptureWorkboardIntentError: LocalizedError {
    case emptyThought

    var errorDescription: String? {
        String(
            localized: "intent.workboardCapture.error.empty",
            defaultValue: "Say or type what you want to prepare first."
        )
    }
}
#endif
