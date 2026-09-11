// SPDX-License-Identifier: Apache-2.0

// Conduck — macOS Share Extension
// WorkCaptureEnvelope.swift
//
// Verbatim cross-process mirror of the main app's WorkCaptureEnvelope. The
// extension is deliberately self-contained; keep everything from `import
// Foundation` onward identical to the main-app and iOS-extension copies.

import Foundation
import UniformTypeIdentifiers

/// One durable Workboard capture. The enclosing directory name is `id`, making
/// publication and import idempotent even when a wake is delivered more than
/// once. File bytes live beside `manifest.json`; text and web links remain small
/// inline entries.
struct WorkCaptureEnvelope: Codable, Sendable, Equatable {
    nonisolated static let currentVersion = 1
    nonisolated static let maximumEntryCount = 24
    nonisolated static let maximumNoteCharacters = 16_000
    nonisolated static let maximumTextCharacters = 100_000
    nonisolated static let maximumURLCharacters = 4_096
    nonisolated static let maximumDisplayNameCharacters = 120
    nonisolated static let maximumManifestBytes = 256 * 1_024
    nonisolated static let maximumFileBytes: Int64 = 256 * 1_024 * 1_024
    nonisolated static let maximumEnvelopeBytes: Int64 = 512 * 1_024 * 1_024

    let version: Int
    let id: UUID
    let createdAt: Date
    /// Optional words the user typed in Conduck's share sheet. Shared text is a
    /// material entry instead, so a later brief can distinguish source material
    /// from the user's instruction about it.
    let note: String
    let source: Source
    /// Optional local Work destination selected in the share sheet. The drainer
    /// revalidates that it still exists and is open; missing/Done targets fall
    /// back to a new inert item instead of dropping the capture.
    let targetWorkItemID: UUID?
    let entries: [Entry]

    enum Source: String, Codable, Sendable {
        case shareExtension
        case app
        case shortcut
    }

    /// Deterministic, capture-side validation. Constructors preserve exactly
    /// what the caller supplied so a limit violation can never masquerade as a
    /// successful, silently shortened capture. Share extensions validate this
    /// contract before their one atomic publication rename.
    enum PublicationValidationFailure: String, Error, Sendable, Equatable {
        case unsupportedVersion
        case emptyCapture
        case tooManyEntries
        case noteTooLong
        case duplicateEntry
        case invalidSequence
        case unsafeMetadata
        case invalidInlineContent
        case textTooLong
        case invalidURL
        case urlTooLong
        case invalidFileEntry

        nonisolated var isSizeViolation: Bool {
            switch self {
            case .tooManyEntries, .noteTooLong, .textTooLong, .urlTooLong:
                return true
            case .unsupportedVersion, .emptyCapture, .duplicateEntry,
                    .invalidSequence, .unsafeMetadata, .invalidInlineContent,
                    .invalidURL, .invalidFileEntry:
                return false
            }
        }
    }

    struct Entry: Codable, Sendable, Equatable, Identifiable {
        let id: UUID
        let kind: Kind
        let sequence: Int
        /// A leaf filename relative to the envelope directory. Present only for
        /// `.image`, `.file`, and `.webPage` entries.
        let relativePath: String?
        /// Inline payload for `.text` and `.url` entries.
        let text: String?
        /// User-facing source filename. It is metadata only and is never used as
        /// an on-disk path.
        let displayName: String?
        let mimeType: String?
        let typeIdentifier: String?
        let byteCount: Int64?

        enum Kind: String, Codable, Sendable {
            case text
            case url
            case image
            case file
            case webPage
        }

        nonisolated init(
            id: UUID = UUID(),
            kind: Kind,
            sequence: Int,
            relativePath: String? = nil,
            text: String? = nil,
            displayName: String? = nil,
            mimeType: String? = nil,
            typeIdentifier: String? = nil,
            byteCount: Int64? = nil
        ) {
            self.id = id
            self.kind = kind
            self.sequence = sequence
            self.relativePath = relativePath
            switch kind {
            case .text, .url:
                self.text = text
            case .image, .file, .webPage:
                self.text = nil
            }
            self.displayName = displayName
            self.mimeType = mimeType
            self.typeIdentifier = typeIdentifier
            self.byteCount = byteCount
        }
    }

    nonisolated init(
        version: Int = WorkCaptureEnvelope.currentVersion,
        id: UUID = UUID(),
        createdAt: Date = Date(),
        note: String = "",
        source: Source,
        targetWorkItemID: UUID? = nil,
        entries: [Entry]
    ) {
        self.version = version
        self.id = id
        self.createdAt = createdAt
        self.note = note
        self.source = source
        self.targetWorkItemID = targetWorkItemID
        self.entries = entries
    }

    /// Validates the complete inline envelope before a share extension writes
    /// `manifest.json` or publishes the directory. Payload byte limits are
    /// checked by the writer while it streams each file and by the inbox again
    /// after claim; this pass owns all limits that can otherwise be truncated by
    /// an in-memory initializer.
    nonisolated func validateForPublication() throws {
        guard version == Self.currentVersion else {
            throw PublicationValidationFailure.unsupportedVersion
        }
        guard note.count <= Self.maximumNoteCharacters else {
            throw PublicationValidationFailure.noteTooLong
        }
        guard entries.count <= Self.maximumEntryCount else {
            throw PublicationValidationFailure.tooManyEntries
        }
        guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !entries.isEmpty else {
            throw PublicationValidationFailure.emptyCapture
        }

        var entryIDs = Set<UUID>()
        var sequences = Set<Int>()
        for entry in entries {
            guard entryIDs.insert(entry.id).inserted,
                  sequences.insert(entry.sequence).inserted else {
                throw PublicationValidationFailure.duplicateEntry
            }
            guard entry.sequence >= 0 else {
                throw PublicationValidationFailure.invalidSequence
            }
            guard Self.safeDisplayName(entry.displayName) == entry.displayName,
                  Self.isSafeOpaqueMetadata(entry.displayName),
                  Self.isSafeOpaqueMetadata(entry.mimeType),
                  Self.isSafeOpaqueMetadata(entry.typeIdentifier) else {
                throw PublicationValidationFailure.unsafeMetadata
            }

            switch entry.kind {
            case .text:
                guard entry.relativePath == nil, let text = entry.text, !text.isEmpty else {
                    throw PublicationValidationFailure.invalidInlineContent
                }
                guard text.count <= Self.maximumTextCharacters else {
                    throw PublicationValidationFailure.textTooLong
                }
            case .url:
                guard entry.relativePath == nil, let value = entry.text, !value.isEmpty else {
                    throw PublicationValidationFailure.invalidInlineContent
                }
                guard value.count <= Self.maximumURLCharacters else {
                    throw PublicationValidationFailure.urlTooLong
                }
                guard Self.isAcceptedWebURL(value) else {
                    throw PublicationValidationFailure.invalidURL
                }
            case .image, .file, .webPage:
                guard entry.text == nil,
                      let relativePath = entry.relativePath,
                      Self.isSafeLeaf(relativePath),
                      let byteCount = entry.byteCount,
                      byteCount >= 0 else {
                    throw PublicationValidationFailure.invalidFileEntry
                }
            }
        }
    }

    // MARK: - Tolerant decode

    private enum CodingKeys: String, CodingKey {
        case version, id, createdAt, note, source, targetWorkItemID, entries
    }

    /// Missing fields default for staged app/extension upgrades. Values are read
    /// verbatim here and validated by `WorkCaptureInbox` before import; capture-
    /// time clamping must not turn a malformed or oversized disk manifest into a
    /// silently different Workboard draft.
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.id = try container.decode(UUID.self, forKey: .id)
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        self.source = try container.decodeIfPresent(Source.self, forKey: .source) ?? .shareExtension
        self.targetWorkItemID = try container.decodeIfPresent(UUID.self, forKey: .targetWorkItemID)
        self.entries = try container.decodeIfPresent([Entry].self, forKey: .entries) ?? []
    }

    // MARK: - Cross-process JSON contract

    private nonisolated static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    nonisolated func encoded() throws -> Data {
        try Self.makeEncoder().encode(self)
    }

    nonisolated static func decode(_ data: Data) throws -> WorkCaptureEnvelope {
        try makeDecoder().decode(WorkCaptureEnvelope.self, from: data)
    }

    // MARK: - Capture-time sanitation

    /// Turns source-controlled suggested names into bounded display metadata.
    /// Payloads always use generated relative paths, so no untrusted name reaches
    /// the filesystem. Path separators, control characters, and bidi overrides
    /// are removed to keep the Workboard honest about what it will later send.
    nonisolated static func safeDisplayName(_ raw: String?) -> String? {
        guard var value = raw, !value.isEmpty else { return nil }
        value = value.replacingOccurrences(of: "\\", with: "/")
        value = value.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        let forbiddenScalars: Set<UInt32> = [
            0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
            0x2066, 0x2067, 0x2068, 0x2069,
        ]
        value.unicodeScalars.removeAll { scalar in
            CharacterSet.controlCharacters.contains(scalar) || forbiddenScalars.contains(scalar.value)
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix(".") { value.removeFirst() }
        guard !value.isEmpty else { return nil }
        guard value.count > maximumDisplayNameCharacters else { return value }

        // Truncation can expose whitespace that the pre-truncation trim could not
        // see. Re-trimming keeps this function idempotent, which the publication
        // and claim validators both assert (`safeDisplayName(x) == x`).
        let ns = value as NSString
        let ext = ns.pathExtension
        if !ext.isEmpty, ext.count <= 12 {
            let suffix = "." + ext
            let stemBudget = maximumDisplayNameCharacters - suffix.count
            if stemBudget > 0 {
                let stem = String(ns.deletingPathExtension.prefix(stemBudget))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !stem.isEmpty { return stem + suffix }
            }
        }
        let truncated = String(value.prefix(maximumDisplayNameCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return truncated.isEmpty ? nil : truncated
    }

    /// Bounds source-controlled MIME types and UTIs at capture time. An
    /// unusable value is dropped rather than failing the whole publication:
    /// the annotation is descriptive metadata, and a capture the person already
    /// confirmed must never be lost to a foreign app's malformed type string.
    nonisolated static func safeOpaqueMetadata(_ raw: String?) -> String? {
        guard let raw, isSafeOpaqueMetadata(raw) else { return nil }
        return raw
    }

    /// A safe generated extension, not a filename. Only short ASCII letters and
    /// numbers survive; everything else becomes `dat`.
    nonisolated static func safePathExtension(_ raw: String?) -> String {
        guard let raw else { return "dat" }
        let lowered = raw.lowercased()
        guard (1...12).contains(lowered.count),
              lowered.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar))
              }) else { return "dat" }
        return lowered
    }

    nonisolated static func isAcceptedWebURL(_ value: String) -> Bool {
        guard value.count <= maximumURLCharacters,
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.isEmpty == false else { return false }
        return true
    }

    // MARK: - Payload shape

    /// Whether a payload is a recording. Every process that can be handed a file
    /// asks this one question the same way, and each compiles its own copy of
    /// this file, so the app and both share extensions cannot disagree about
    /// what a recording IS.
    ///
    /// Three annotations answer, in the order they can be trusted. The MIME type
    /// a source app supplied is checked first because it is the one annotation
    /// every share and Shortcut path fills in. The type identifier answers for
    /// the sources that declare a UTI instead. The filename's extension is the
    /// last resort, for a payload that arrived carrying neither — dropping a
    /// file onto the desk is the ordinary way that happens. Conformance rather
    /// than equality throughout, so a recording in any concrete audio type is
    /// recognised rather than only the handful worth spelling out.
    ///
    /// Video is deliberately NOT a recording even though it is audible: a film
    /// conforms to `public.movie` and never to `public.audio`, and treating one
    /// as audio would refuse it at doors that exist to keep microphone captures
    /// out.
    ///
    /// Pure and inert. It reads nothing, writes nothing, and carries no wire
    /// meaning: it only decides what its caller does next.
    nonisolated static func isAudioPayload(
        mimeType: String?,
        typeIdentifier: String?,
        filename: String?
    ) -> Bool {
        if let mimeType, mimeType.lowercased().hasPrefix("audio/") { return true }
        if let typeIdentifier,
           let declared = UTType(typeIdentifier),
           declared.conforms(to: .audio) {
            return true
        }
        guard let filename else { return false }
        let pathExtension = (filename as NSString).pathExtension
        guard !pathExtension.isEmpty,
              let inferred = UTType(filenameExtension: pathExtension) else { return false }
        return inferred.conforms(to: .audio)
    }

    private nonisolated static func isSafeLeaf(_ value: String) -> Bool {
        guard !value.isEmpty,
              value != ".",
              value != "..",
              value != "manifest.json",
              value.count <= 160,
              (value as NSString).lastPathComponent == value,
              !value.contains("/"),
              !value.contains("\\"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return false
        }
        return true
    }

    private nonisolated static func isSafeOpaqueMetadata(_ value: String?) -> Bool {
        guard let value else { return true }
        guard !value.isEmpty,
              value.count <= 160,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        let forbiddenScalars: Set<UInt32> = [
            0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
            0x2066, 0x2067, 0x2068, 0x2069,
        ]
        return !value.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar)
                || CharacterSet.illegalCharacters.contains(scalar)
                || forbiddenScalars.contains(scalar.value)
        }
    }
}
