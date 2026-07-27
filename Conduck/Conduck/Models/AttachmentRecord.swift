// SPDX-License-Identifier: Apache-2.0

// Conduck
// AttachmentRecord.swift
//
// Sendable snapshot of a stored `Attachment`, decoupled from the
// `NSManagedObject` so it is safe to pass across the `ConversationStore`
// actor boundary and into `@MainActor` SwiftUI view models. Mirrors
// `MessageRecord` / `ConversationRecord`'s defensive `init(managedObject:)`
// posture (KVC + nil-coalescing) tolerating the all-optional Core Data model
// required by `NSPersistentCloudKitContainer`.
//
// CROSS-TARGET: this file is a Watch-target membership exception (see the
// pbxproj `63E4A001…` exception set, alongside `MessageRecord.swift`) so the
// Watch can render the `[Image attached]` / `[File attached]` placeholder.
// Pure Foundation — NO UIKit / ImageIO so it stays Watch-safe.
//
// MEMORY DISCIPLINE (load-bearing): the snapshot NEVER carries the full image
// bytes. It carries metadata + the small `thumbnailData` + (for text
// mimeTypes only) the decoded `extractedText`. Full image bytes are loaded
// on-demand via `ConversationStore.loadAttachmentData(for:)` for the
// full-screen viewer and for prior-turn data-URI assembly.

import Foundation
import CoreData

/// Snapshot of a single persisted attachment on a `Message` turn. `mimeType`
/// is dual-purpose: `image/jpeg` for images (full bytes live in the store's
/// `data`, NOT here); `text/*` / `application/json` for extracted text files
/// (the decoded UTF-8 text is surfaced via `extractedText`). Ordering within a
/// message is by `sequence` (the model relationship is unordered — CloudKit
/// rejects `NSOrderedSet`).
struct AttachmentRecord: Identifiable, Hashable, Sendable {
    let id: UUID
    /// `image/jpeg` for images; `text/*` / `application/json` for text files.
    let mimeType: String
    /// Original filename (text files — drives the bubble chip label, e.g.
    /// "report.csv"). Nil for images (camera/library have no meaningful name;
    /// the bubble renders a thumbnail, not a name).
    let filename: String?
    /// Small downsized preview (images only); nil for text files.
    let thumbnailData: Data?
    /// Decoded UTF-8 text — populated ONLY for text mimeTypes. Nil for images
    /// (their bytes are loaded on demand, never inlined into the snapshot).
    let extractedText: String?
    /// True when this attachment is a *server reference* (file transfer): the
    /// real bytes live on the user's own gateway file-server, NOT in Core Data.
    /// Drives the file-transfer chip + the "in your working directory" wire
    /// splice instead of the inline image-grid / text-fence rendering.
    let isServerReference: Bool
    /// Opaque server-issued handle for a server-stored blob (`<shortid>__<name>`).
    /// Used to address the file on the file-server (probe / download / wire ref).
    /// PRIVACY: never log / display this raw — it is an opaque path token.
    let storedKey: String?
    /// Discriminator for a synced server-reference PREVIEW: `"text"` (a bounded
    /// UTF-8 text snapshot lives in the store's `previewData`) or `nil` (no text
    /// preview; an image preview, if any, rides `thumbnailData`).
    ///
    /// The preview BYTES (`previewData`) are DELIBERATELY not carried on this
    /// snapshot — a file-rich Watch thread must not fault a 128 KiB blob per row.
    /// The viewer lazily fetches the single blob it needs via
    /// `ConversationStore.fetchPreviewText(messageID:attachmentID:)`.
    let previewKind: String?
    let width: Int
    let height: Int
    let byteSize: Int
    /// Render / wire order within the parent message (0-based).
    let sequence: Int
    let createdAt: Date

    /// True when `mimeType` is an image type — drives image-grid rendering.
    var isImage: Bool { mimeType.hasPrefix("image/") }

    /// True when `mimeType` is a text/code type whose decoded bytes are spliced
    /// inline on the wire. A server reference is NEITHER image NOR inline-text
    /// (its bytes never travel inline — they're handed to the agent's tools via
    /// the file-server), so it is excluded here.
    var isText: Bool { !isImage && !isServerReference }

    /// True when this attachment is a server-stored file (download on demand;
    /// referenced on the wire by `storedKey`, never inlined).
    var isServerFile: Bool { isServerReference }

    /// True when this server reference carries a synced, wrist-renderable TEXT
    /// preview (`previewKind == "text"` → its bytes are in the store's
    /// `previewData`). Server-reference-only: an inline text file is `isText`,
    /// not a preview.
    var hasTextPreview: Bool { isServerReference && previewKind == "text" }

    // MARK: - Text-preview eligibility

    /// Whether a server output file's `filename` names a TEXT-like type worth
    /// storing a bounded UTF-8 preview for. Case-insensitive extension allowlist,
    /// mirroring the TEXT subset of `FileTransferOutputDetector.outputAllowlist`
    /// (image / binary / pdf / audio / office-binary extensions excluded).
    ///
    /// EXTENSION-based, deliberately NOT MIME-based: agent output files routinely
    /// carry `application/*` MIME types (`application/json`, `application/x-yaml`,
    /// `application/x-sh`), so a naive `mimeType.hasPrefix("text/")` gate would
    /// silently drop exactly the machine-readable outputs a preview is most
    /// useful for. The extension is the reliable signal.
    static func isPreviewableTextFilename(_ filename: String) -> Bool {
        guard let dot = filename.lastIndex(of: "."), dot != filename.index(before: filename.endIndex) else {
            return false
        }
        let ext = filename[filename.index(after: dot)...].lowercased()
        return previewableTextExtensions.contains(ext)
    }

    /// TEXT-like subset of `FileTransferOutputDetector.outputAllowlist` — the
    /// source/data/markup types whose bytes decode as UTF-8 text. Excludes
    /// images (png/jpg/jpeg/gif/svg), archives (zip/tar/gz), office binaries
    /// (xlsx/xls/docx/doc/pptx), pdf, and columnar binary (parquet). `swift` is
    /// added on top of the mirrored set: it isn't in the detector's OUTPUT
    /// allowlist (agents rarely emit `.swift` as a deliverable) but it is
    /// unambiguously UTF-8 source and a natural preview target.
    private static let previewableTextExtensions: Set<String> = [
        "txt", "md", "json", "csv", "tsv", "xml", "yaml", "yml", "log", "html",
        "py", "js", "ts", "sh", "sql", "swift"
    ]

    // MARK: - Watch display classification

    /// UTF-8 byte ceiling above which a text attachment's decoded content is NOT
    /// laid out on the Watch. Laying out multi-hundred-KB `Text` on watchOS is a
    /// realistic UI freeze, so an oversized file shows a passive marker instead
    /// of a viewer. Composer-inlined files are ≤ ~32 KB, so 128 KB is generous
    /// headroom for anything that legitimately reaches the wrist inline.
    static let watchViewableTextByteCeiling = 128 * 1024

    /// How a single attachment renders in the Watch thread. Distinct cases so the
    /// bubble drives per-attachment rows AND the classification stays unit-
    /// testable independent of any view.
    enum WatchDisplayClass: Equatable {
        /// Server file reference — passive "[File attached]" (the wrist has no
        /// download capability by design).
        case serverPlaceholder
        /// Image with a (possibly not-yet-synced) thumbnail.
        case imageThumbnail
        /// Text/code file whose full content is synced and small enough to lay
        /// out — renders a tappable row into the Watch text viewer.
        case viewableText
        /// Text/code file whose content exceeds the layout ceiling — passive.
        case oversizedText
        /// A row whose content hasn't synced yet (nil `extractedText`) — passive.
        case filePlaceholder
    }

    /// Pure classifier for `WatchDisplayClass`. ORDER IS LOAD-BEARING: a server
    /// reference is checked FIRST because a server-reference image is BOTH
    /// `isImage` and `isServerFile` — classifying by `isImage` first renders it
    /// as an image fallback AND leaves a stray "[File attached]" marker (the
    /// latent double-placeholder bug). Images next; then text splits on the
    /// content ceiling; a partially-synced text row (nil `extractedText`) falls
    /// through to the passive placeholder.
    ///
    /// A server reference with a synced preview is now wrist-RENDERABLE: an image
    /// thumbnail (`thumbnailData`, checked first so a preview image beats a text
    /// preview) → `.imageThumbnail`; else a text preview (`hasTextPreview`) →
    /// `.viewableText`; else the passive `.serverPlaceholder`. The preview is a
    /// bounded SNAPSHOT stored on-device — the authoritative bytes stay on the
    /// user's own file-server (the wrist still has no download capability).
    static func watchDisplayClass(
        for attachment: AttachmentRecord,
        maxViewableUTF8Bytes: Int = Self.watchViewableTextByteCeiling
    ) -> WatchDisplayClass {
        if attachment.isServerFile {
            if attachment.thumbnailData != nil { return .imageThumbnail }
            if attachment.hasTextPreview { return .viewableText }
            return .serverPlaceholder
        }
        if attachment.isImage { return .imageThumbnail }
        // Non-image, non-server (`isText`) — split on content availability + size.
        guard let text = attachment.extractedText else { return .filePlaceholder }
        return text.utf8.count <= maxViewableUTF8Bytes ? .viewableText : .oversizedText
    }

    init(
        id: UUID,
        mimeType: String,
        filename: String? = nil,
        thumbnailData: Data?,
        extractedText: String?,
        width: Int,
        height: Int,
        byteSize: Int,
        sequence: Int,
        createdAt: Date,
        isServerReference: Bool = false,
        storedKey: String? = nil,
        previewKind: String? = nil
    ) {
        self.id = id
        self.mimeType = mimeType
        self.filename = filename
        self.thumbnailData = thumbnailData
        self.extractedText = extractedText
        self.isServerReference = isServerReference
        self.storedKey = storedKey
        self.previewKind = previewKind
        self.width = width
        self.height = height
        self.byteSize = byteSize
        self.sequence = sequence
        self.createdAt = createdAt
    }

    /// Defensive bridge from the all-optional Core Data entity. Every field
    /// nil-coalesces so a partially-synced CloudKit row never crashes —
    /// matches `MessageRecord`'s posture.
    ///
    /// For text mimeTypes the full `data` blob (the extracted text bytes, kept
    /// small by design — no image bytes) is decoded into `extractedText`. For
    /// image mimeTypes `data` is NEVER read here (load on demand); only the
    /// small `thumbnailData` crosses into the snapshot.
    init(managedObject: NSManagedObject) {
        let id = (managedObject.value(forKey: "id") as? UUID) ?? UUID()
        let mimeType = (managedObject.value(forKey: "mimeType") as? String) ?? "application/octet-stream"
        self.id = id
        self.mimeType = mimeType
        self.filename = managedObject.value(forKey: "filename") as? String
        self.thumbnailData = managedObject.value(forKey: "thumbnailData") as? Data
        self.width = (managedObject.value(forKey: "width") as? Int) ?? 0
        self.height = (managedObject.value(forKey: "height") as? Int) ?? 0
        self.byteSize = (managedObject.value(forKey: "byteSize") as? Int) ?? 0
        self.sequence = (managedObject.value(forKey: "sequence") as? Int) ?? 0
        self.createdAt = (managedObject.value(forKey: "createdAt") as? Date) ?? Date()

        // File-transfer fields (model v3+; absent on legacy rows → false / nil).
        let isServerReference = (managedObject.value(forKey: "isServerReference") as? Bool) ?? false
        self.isServerReference = isServerReference
        self.storedKey = managedObject.value(forKey: "storedKey") as? String
        // Preview discriminator only (model v6+; absent on legacy rows → nil).
        // The preview BYTES (`previewData`) are NEVER decoded here — a file-rich
        // Watch thread must not fault a 128 KiB blob per row; the viewer lazily
        // fetches the one blob it needs via `ConversationStore.fetchPreviewText`.
        self.previewKind = managedObject.value(forKey: "previewKind") as? String

        // Text-only: decode the stored UTF-8 bytes into `extractedText`. Images
        // never inline their bytes into the snapshot. Server references carry NO
        // local bytes (the file lives on the gateway file-server) — never decode
        // `data` for them.
        if mimeType.hasPrefix("image/") || isServerReference {
            self.extractedText = nil
        } else if let blob = managedObject.value(forKey: "data") as? Data {
            self.extractedText = String(data: blob, encoding: .utf8)
        } else {
            self.extractedText = nil
        }
    }
}
