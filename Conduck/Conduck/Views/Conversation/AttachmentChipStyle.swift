// Conduck
// AttachmentChipStyle.swift
//
// Shared color-coded file-chip styling, used by both the composer's
// `AttachmentPreviewStrip` (staged text files) and the thread bubble's
// text-file chip (`ConversationThreadView.MessageBubble`). Keeps the
// icon/tint/extension mapping in ONE place so a new file type is added once.
//
// Icon-by-extension:
//   .txt/.md      → doc.text
//   .csv          → tablecells
//   .json         → curlybraces
//   source code   → chevron.left.forwardslash.chevron.right
//   .rtf          → doc.richtext
// Pure Foundation + SwiftUI Color — no UIKit so it stays cross-platform.

import SwiftUI

enum AttachmentChipStyle {
    /// SF Symbol for a text/code file, keyed off its lowercased extension.
    static func symbol(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "txt", "text", "log": return "doc.text"
        case "md", "markdown": return "doc.text"
        case "csv", "tsv": return "tablecells"
        case "json": return "curlybraces"
        case "rtf": return "doc.richtext"
        case "swift", "js", "ts", "py", "rb", "go", "rs", "java", "kt",
             "c", "h", "cpp", "cc", "hpp", "m", "mm", "cs", "php", "sh",
             "html", "xml", "yaml", "yml", "toml", "sql", "css":
            return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }

    /// Accent tint for a text/code file, keyed off its lowercased extension.
    /// Colors are chosen for at-a-glance differentiation, not brand fidelity.
    static func tint(forExtension ext: String) -> Color {
        switch ext.lowercased() {
        case "csv", "tsv": return AppColors.success           // tabular = green
        case "json", "yaml", "yml", "toml": return AppColors.brandTeal
        case "md", "markdown", "txt", "text", "log", "rtf":
            return AppColors.brandAmber
        case "swift", "js", "ts", "py", "rb", "go", "rs", "java", "kt",
             "c", "h", "cpp", "cc", "hpp", "m", "mm", "cs", "php", "sh",
             "html", "xml", "sql", "css":
            return AppColors.sunsetOrange                       // source = orange
        default: return AppColors.textSecondary
        }
    }

    /// SF Symbol for a stored attachment by its `mimeType` (bubble chips load
    /// from `AttachmentRecord` which carries a mimeType, not always a clean
    /// extension — fall back via the filename when present).
    static func symbol(forMimeType mimeType: String, filename: String?) -> String {
        if let ext = filename.flatMap({ ($0 as NSString).pathExtension }), !ext.isEmpty {
            return symbol(forExtension: ext)
        }
        switch mimeType {
        case "text/csv": return "tablecells"
        case "application/json": return "curlybraces"
        case "text/markdown": return "doc.text"
        case "text/rtf", "application/rtf": return "doc.richtext"
        default: return "doc.text"
        }
    }

    static func tint(forMimeType mimeType: String, filename: String?) -> Color {
        if let ext = filename.flatMap({ ($0 as NSString).pathExtension }), !ext.isEmpty {
            return tint(forExtension: ext)
        }
        switch mimeType {
        case "text/csv": return AppColors.success
        case "application/json": return AppColors.brandTeal
        default: return AppColors.brandAmber
        }
    }

    /// Human-readable byte size (e.g. "12 KB") via `ByteCountFormatter`.
    static func formattedSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
