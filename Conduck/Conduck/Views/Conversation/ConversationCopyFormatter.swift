// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationCopyFormatter.swift
//
// Renders a whole conversation into one plain-text block for the toolbar
// "Copy conversation" action. Role-labeled turns, agent Markdown kept
// verbatim (this is a paste-elsewhere export, not a TTS strip), attachments
// as one-line placeholders — never bytes, never `extractedText`, never
// `storedKey` (the key is an opaque server path; leaking it into a paste
// would violate the never-reveal rule).
//
// Pure Foundation — unit-testable without SwiftUI (MessageRowFormatters
// precedent). "Copy" not "Transcript": transcript means STT output
// throughout this codebase.

import Foundation

enum ConversationCopyFormatter {
    /// Build the clipboard text for a conversation. `agentName` labels agent
    /// turns (the bound backend's display name); blank falls back to the
    /// existing "Personal AI" catalog string so the label matches the
    /// nav-title fallback.
    static func build(messages: [MessageRecord], agentName: String) -> String {
        let trimmedName = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedAgentName = trimmedName.isEmpty
            ? String(localized: "Personal AI")  // xcstrings: chat-ui
            : trimmedName

        var blocks: [String] = []
        for message in messages {
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // A turn with neither text nor attachments has nothing to paste.
            if text.isEmpty && message.attachments.isEmpty { continue }

            var lines: [String] = []
            if message.role == "user" {
                lines.append(String(localized: "thread.copyAll.userLabel",
                                    defaultValue: "You:"))  // xcstrings: chat-ui
            } else {
                lines.append(String(localized: "thread.copyAll.agentLabel",
                                    defaultValue: "\(resolvedAgentName):"))  // xcstrings: chat-ui
            }
            if !text.isEmpty {
                lines.append(text)
            }
            // `MessageRecord.attachments` is pre-sorted by `sequence`.
            for attachment in message.attachments {
                lines.append(placeholder(for: attachment))
            }
            if message.status == "failed" {
                lines.append(String(localized: "thread.copyAll.notSent",
                                    defaultValue: "[Not sent]"))  // xcstrings: chat-ui
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    /// One-line stand-in for an attachment. Text matches the Watch's
    /// established bracket convention ("[Image attached]" / "[File attached]");
    /// named files carry the user-visible filename only.
    private static func placeholder(for attachment: AttachmentRecord) -> String {
        if attachment.isImage {
            return String(localized: "thread.copyAll.imageAttached",
                          defaultValue: "[Image attached]")  // xcstrings: chat-ui
        }
        if let filename = attachment.filename?.trimmingCharacters(in: .whitespacesAndNewlines),
           !filename.isEmpty {
            return String(localized: "thread.copyAll.fileAttachedNamed",
                          defaultValue: "[File attached: \(filename)]")  // xcstrings: chat-ui
        }
        return String(localized: "thread.copyAll.fileAttached",
                      defaultValue: "[File attached]")  // xcstrings: chat-ui
    }
}
