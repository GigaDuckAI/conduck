// SPDX-License-Identifier: Apache-2.0

// Conduck
// AddFilesToWorkIntent.swift
//
// The files half of Work's Shortcuts surface: whatever a shortcut graph is
// holding — a document, a set of photos, a downloaded attachment — becomes
// cards on the single Work desk. Like every other Work ingress it is inert:
// there is no gateway, conversation or dispatch anywhere below this file, so
// adding to Work can never equal sending.
//
// ONE ENVELOPE, NOT ONE WRITE PER FILE. A headless intent process is killed
// without warning, so the capture is handed to `WorkCaptureInbox` as a single
// App-Group envelope and `WorkCaptureDrainer` lands it. That is what makes the
// set atomic — every file becomes a card together or none does — and what keeps
// the process's memory bounded: the publisher COPIES each file, so a 24-file
// capture never exists in RAM.
//
// THE CAPTURE ID IS DERIVED, NOT MINTED, which is the opposite of
// `CaptureWorkboardIntent`'s choice and for the opposite reason. A typed
// thought is a new thought every time it is typed; a set of files is the same
// set of files, and the run that matters is the one the system killed halfway
// through. Naming the capture after its INPUT means the rerun repairs the cards
// the first attempt published instead of laying a second copy of the same files
// on the desk — the entry ids under it are `WorkCaptureInbox.fileEntryID`,
// which is derived from that same name plus the position. The cost is that a
// person who deliberately runs the shortcut twice over an unchanged set gets
// one set of cards, which is the same answer the desk gives for every other
// replayed capture.
//
// The dialog is true at PUBLICATION time, not at import time. The drain below
// is best-effort — if the process dies before it, the envelope is still queued
// and the cards land at the next app launch — so the count spoken back is the
// number of files handed to the queue, never a count of rows in the store.

#if !os(watchOS)
import AppIntents
import CryptoKit
import Foundation
import UniformTypeIdentifiers

struct AddFilesToWorkIntent: AppIntent {
    static var title: LocalizedStringResource = LocalizedStringResource(
        "intent.workAddFiles.title",
        defaultValue: "Add Files to Work"
    )

    static var description = IntentDescription(
        LocalizedStringResource(
            "intent.workAddFiles.description",
            defaultValue: "Save files to your private Work desk without sending them to an AI."
        )
    )

    /// Headless by design. Nothing here needs a screen, and a shortcut that adds
    /// a file mid-automation must not steal the foreground to do it.
    static var supportedModes: IntentModes = [.background]

    /// `.item` rather than a narrower list: Work holds whatever a person keeps,
    /// and the desk decides how to show it from the type, so a filter here would
    /// only refuse files the desk can already carry.
    @Parameter(
        title: LocalizedStringResource(
            "intent.workAddFiles.files",
            defaultValue: "Files"
        ),
        supportedContentTypes: [.item],
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var files: [IntentFile]

    /// Optional, and never `requestValue`d — asking for it would foreground a
    /// lane whose whole point is that it does not.
    @Parameter(
        title: LocalizedStringResource(
            "intent.workAddFiles.note",
            defaultValue: "Note"
        ),
        inputConnectionBehavior: .never
    )
    var note: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$files) to Work") {
            \.$note
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        guard !files.isEmpty else { throw WorkFileCaptureRefusal.noFiles }

        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)

        // Bytes that arrive WITHOUT a URL are the only ones this process writes,
        // and it writes them under a leaf `TempScratchSweeper.ownedPrefixes`
        // claims: a jetsam between the write and the publication would otherwise
        // strand a copy of the person's file with no owner left to delete it.
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-workboard-intake-\(UUID().uuidString)", isDirectory: true)
        var stagedAnything = false
        defer {
            if stagedAnything { try? FileManager.default.removeItem(at: stagingRoot) }
        }

        var inputs: [WorkCaptureFileInput] = []
        for (position, file) in files.enumerated() {
            // A shortcut graph can hand over a file with no declared type at
            // all — "Get File" does it routinely — and the desk decides how to
            // SHOW a card from that type, so an undeclared photo would land as
            // a nameless generic row. The extension is the weakest honest
            // answer, so it is asked last and only when nothing was declared.
            let resolvedType = file.type
                ?? UTType(filenameExtension: (file.filename as NSString).pathExtension)
            let mimeType = resolvedType?.preferredMIMEType
            let typeIdentifier = resolvedType?.identifier
            if let url = file.fileURL {
                // Handed over as-is: the publisher holds the security scope and
                // copies, so nothing here reads a byte of a file that may weigh
                // a quarter of a gigabyte.
                inputs.append(WorkCaptureFileInput(
                    url: url,
                    displayName: file.filename,
                    mimeType: mimeType,
                    typeIdentifier: typeIdentifier,
                    byteCount: Self.byteCount(at: url)
                ))
                continue
            }
            let bytes = file.data
            if !stagedAnything {
                try? FileManager.default.createDirectory(
                    at: stagingRoot,
                    withIntermediateDirectories: true
                )
                stagedAnything = true
            }
            // A generated leaf. The display name travels in the envelope, where
            // it is sanitized; no name a shortcut supplies reaches this disk.
            let pathExtension = WorkCaptureEnvelope.safePathExtension(
                (file.filename as NSString).pathExtension
            )
            let staged = stagingRoot.appendingPathComponent(
                "file-\(position).\(pathExtension)",
                isDirectory: false
            )
            do {
                try bytes.write(to: staged, options: .atomic)
            } catch {
                throw WorkFileCaptureRefusal.unreadableFile(name: file.filename)
            }
            inputs.append(WorkCaptureFileInput(
                url: staged,
                displayName: file.filename,
                mimeType: mimeType,
                typeIdentifier: typeIdentifier,
                byteCount: Int64(bytes.count)
            ))
        }

        // Checked here as well as inside the queue, and not redundantly: the
        // queue refuses with one error per RULE, and a person who chose forty
        // files is owed the sentence that says which rule they met.
        if let refusal = Self.refusal(for: inputs) { throw refusal }

        do {
            _ = try await WorkCaptureInbox.shared.publishFileCapture(
                note: trimmedNote,
                files: inputs,
                captureID: Self.captureIdentity(note: trimmedNote, files: inputs)
            )
        } catch let failure as WorkCaptureEnvelope.PublicationValidationFailure {
            throw WorkFileCaptureRefusal(publicationFailure: failure, files: inputs)
        } catch WorkCaptureInbox.InboxError.invalidEnvelope(_, .envelopeTooLarge) {
            throw WorkFileCaptureRefusal.setTooLarge
        }

        // Best-effort, exactly as the voice lane drains: publication is the
        // durable boundary, so a transient persistence failure must not turn a
        // successful capture into a failed shortcut. The queued envelope is
        // drained again by the next board load.
        _ = try? await WorkCaptureDrainer(
            sourceDevice: SourceDevice.current
        ).drainAvailableCaptures()

        let confirmation = String(
            localized: "intent.workboardCapture.confirmation",
            defaultValue: "Added to Work. Nothing was sent."
        )
        return .result(
            value: inputs.count,
            dialog: IntentDialog(stringLiteral: confirmation)
        )
    }

    // MARK: - Refusals

    /// The whole-set refusal rules, as a pure function of what was handed over.
    ///
    /// Pure and static so the rules can be asserted without a filesystem, an
    /// App Group, or an intent process — the three things that make the queue's
    /// own copy of these limits awkward to exercise.
    static func refusal(for files: [WorkCaptureFileInput]) -> WorkFileCaptureRefusal? {
        guard !files.isEmpty else { return .noFiles }
        guard files.count <= WorkCaptureEnvelope.maximumEntryCount else {
            return .tooManyFiles(limit: WorkCaptureEnvelope.maximumEntryCount)
        }
        var total: Int64 = 0
        for file in files {
            guard file.byteCount <= WorkCaptureEnvelope.maximumFileBytes else {
                return .fileTooLarge(name: Self.name(of: file))
            }
            total += max(0, file.byteCount)
            guard total <= WorkCaptureEnvelope.maximumEnvelopeBytes else {
                return .setTooLarge
            }
        }
        return nil
    }

    private static func name(of file: WorkCaptureFileInput) -> String {
        let declared = file.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let declared, !declared.isEmpty { return declared }
        return file.url.lastPathComponent
    }

    // MARK: - Identity

    /// The permanent name of this capture: UUIDv5 over the note and, in the
    /// order they were handed over, each file's name and size.
    ///
    /// ORDER IS PART OF THE NAME, deliberately. The entry ids under this id are
    /// derived from the POSITION, so a set hashed order-insensitively would let
    /// a reordered rerun repair card 3 with the bytes of card 1. Hashing the
    /// order instead makes a reordered set a different capture, which is the
    /// honest answer.
    ///
    /// Names and sizes rather than bytes: a headless process must not read a
    /// quarter of a gigabyte to decide what to call something, and two runs
    /// carrying identically named files of identical size over the same note
    /// are the replay this derivation exists to catch.
    static func captureIdentity(note: String?, files: [WorkCaptureFileInput]) -> UUID {
        var hasher = Insecure.SHA1()
        withUnsafeBytes(of: captureIdentityNamespace.uuid) { hasher.update(bufferPointer: $0) }
        hasher.update(data: Data((note ?? "").utf8))
        for file in files {
            // A separator no name can contain, so "ab" + "c" and "a" + "bc"
            // cannot hash alike.
            hasher.update(data: Data([0x00]))
            hasher.update(data: Data(name(of: file).utf8))
            hasher.update(data: Data([0x00]))
            var size = UInt64(bitPattern: file.byteCount).bigEndian
            withUnsafeBytes(of: &size) { hasher.update(bufferPointer: $0) }
        }
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

    /// A namespace of its own, so a capture id can never collide with the entry
    /// ids derived under it or with a voice capture's recording.
    private static let captureIdentityNamespace = UUID(
        uuidString: "A11F0000-0000-4000-A000-000000000001"
    )!

    /// The size the source declares, measured under its security scope — a
    /// Shortcut's URL is unreadable outside one. An unreadable size is reported
    /// as zero rather than as a refusal: the queue measures the bytes it
    /// actually stages, so a stat that fails here costs the early refusal and
    /// nothing else.
    private static func byteCount(at url: URL) -> Int64 {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        return Int64(size ?? 0)
    }
}

/// Why a set of files did not become cards. Every case is a whole-set refusal:
/// publishing part of a set would tell a person who chose forty files that
/// twenty-four of them are what they captured, with no way of knowing which.
enum WorkFileCaptureRefusal: LocalizedError, Equatable {
    case noFiles
    case tooManyFiles(limit: Int)
    case fileTooLarge(name: String)
    case setTooLarge
    case unreadableFile(name: String)

    /// The queue's verdicts, restated as the sentence the person reads. The
    /// queue refuses per rule; this maps each rule onto the one thing they can
    /// do about it.
    init(publicationFailure: WorkCaptureEnvelope.PublicationValidationFailure, files: [WorkCaptureFileInput]) {
        switch publicationFailure {
        case .tooManyEntries:
            self = .tooManyFiles(limit: WorkCaptureEnvelope.maximumEntryCount)
        case .emptyCapture:
            self = .noFiles
        default:
            // `.invalidFileEntry` and every other envelope verdict reach here
            // only after the size rules above already passed, so what is left is
            // a source the queue could not read.
            self = .unreadableFile(name: files.first.map { file in
                file.displayName ?? file.url.lastPathComponent
            } ?? "")
        }
    }

    var errorDescription: String? {
        switch self {
        case .noFiles:
            return String(
                localized: "intent.workAddFiles.error.noFiles",
                defaultValue: "Choose at least one file to add to Work."
            )
        case .tooManyFiles:
            // The ceiling is deliberately not spoken. A number in the sentence
            // is a second place the limit lives, and a person told "more than
            // 24" still has to count what they selected.
            return String(
                localized: "intent.workAddFiles.error.tooManyFiles",
                defaultValue: "That’s too many files to add at once. Add them in smaller batches."
            )
        case .fileTooLarge(let name):
            return String(
                localized: "intent.workAddFiles.error.fileTooLarge",
                defaultValue: "“\(name)” is too big to keep in Work."
            )
        case .setTooLarge:
            return String(
                localized: "intent.workAddFiles.error.setTooLarge",
                defaultValue: "Those files are too big to add at once. Add them in smaller batches."
            )
        case .unreadableFile(let name):
            return String(
                localized: "intent.workAddFiles.error.unreadableFile",
                defaultValue: "“\(name)” couldn’t be read, so nothing was added to Work."
            )
        }
    }
}
#endif
