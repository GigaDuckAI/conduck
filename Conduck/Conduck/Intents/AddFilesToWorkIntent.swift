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
// THE INPUT IS THE BYTES, not just the name and the size. Repair means one
// capture REPLACES another's payload, so anything the identity cannot tell
// apart is destroyed by the next capture it collides with: two files both
// called `memo.txt`, both five bytes, holding different words are one id under
// a name-and-size hash, and the second run overwrites the first person's card.
// The digest is therefore streamed in fixed chunks (`SHA256` over a
// `FileHandle`) rather than loaded — the memory a headless process must not
// spend is RAM, and reading a file in 256 KB pieces spends none of it — so the
// distinction costs one extra pass over bytes that are about to be copied
// anyway, and a genuine replay of the SAME bytes still lands on the same id and
// still repairs.
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
        // Refused HERE rather than at the queue, and before a byte is staged: a
        // shortcut can pipe a whole document into this parameter, and the
        // envelope's own verdict for it is a size violation the caller has to
        // translate — untranslated it reads as "that file could not be read",
        // which names the wrong thing and offers a remedy that cannot work.
        if let refusal = Self.refusal(forNote: trimmedNote) { throw refusal }

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

    /// The note's own whole-set refusal, split out because it is decided before
    /// anything is staged and asserted without a filesystem.
    ///
    /// The ceiling is the envelope's, single-sourced: `validateForPublication`
    /// refuses `.noteTooLong` above it and the queue preserves what the caller
    /// supplied rather than shortening it, so a note that is too long here is a
    /// note that is too long there.
    static func refusal(forNote note: String?) -> WorkFileCaptureRefusal? {
        guard let note, note.count > WorkCaptureEnvelope.maximumNoteCharacters else {
            return nil
        }
        return .noteTooLong
    }

    private static func name(of file: WorkCaptureFileInput) -> String {
        let declared = file.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let declared, !declared.isEmpty { return declared }
        return file.url.lastPathComponent
    }

    // MARK: - Identity

    /// The permanent name of this capture: UUIDv5 over the note and, in the
    /// order they were handed over, each file's name, size and CONTENT DIGEST.
    ///
    /// ORDER IS PART OF THE NAME, deliberately. The entry ids under this id are
    /// derived from the POSITION, so a set hashed order-insensitively would let
    /// a reordered rerun repair card 3 with the bytes of card 1. Hashing the
    /// order instead makes a reordered set a different capture, which is the
    /// honest answer.
    ///
    /// THE BYTES ARE PART OF THE NAME, and they have to be. The name and size
    /// alone are not an identity: two different `memo.txt`s of five bytes each
    /// derive the same id, and the second capture then REPAIRS the first — the
    /// queue republishes over the earlier cards and the bytes the person saved
    /// an hour ago are gone. A digest is the only thing that separates "the
    /// same set again" (repair, which is what makes a killed shortcut safe)
    /// from "a different set that happens to be named alike".
    ///
    /// Bounded memory, not bounded I/O: the digest is streamed in fixed chunks
    /// (`contentDigest(at:)`), so a 256 MB file costs a read and a constant
    /// amount of RAM. A headless intent process must never hold a file, but it
    /// may read one.
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
            // Fixed width, always: a digest that were sometimes absent would
            // put a variable-length field between two names.
            hasher.update(data: contentDigest(at: file.url))
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

    /// SHA-256 of a source's bytes, read in fixed chunks under its security
    /// scope — the one thing that tells two same-named, same-sized files apart.
    ///
    /// `FileHandle`, never `Data(contentsOf:)`: the ceiling is 256 MB a file
    /// and 512 MB a set, and this runs in a process the system kills without
    /// warning. Memory here is one chunk regardless of the file's size.
    ///
    /// A source that cannot be read digests as a fixed sentinel rather than as
    /// an empty file: SHA-256 never answers all-zero, so an unreadable file can
    /// neither collide with a real one nor make the field disappear. Such a set
    /// is refused by the queue moments later anyway — an unreadable source
    /// never becomes a card.
    private static func contentDigest(at url: URL) -> Data {
        let unreadable = Data(repeating: 0, count: 32)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return unreadable }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: digestChunkBytes)
            } catch {
                return unreadable
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }

    /// 256 KB — big enough that a large file is not a syscall storm, small
    /// enough that the ceiling on this process's memory is a rounding error.
    private static let digestChunkBytes = 256 * 1024
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
    case noteTooLong

    /// The queue's verdicts, restated as the sentence the person reads. The
    /// queue refuses per rule; this maps each rule onto the one thing they can
    /// do about it.
    init(publicationFailure: WorkCaptureEnvelope.PublicationValidationFailure, files: [WorkCaptureFileInput]) {
        switch publicationFailure {
        case .tooManyEntries:
            self = .tooManyFiles(limit: WorkCaptureEnvelope.maximumEntryCount)
        case .emptyCapture:
            self = .noFiles
        case .noteTooLong:
            // Named rather than defaulted: the files are fine, and telling a
            // person one of them could not be read sends them to re-pick a file
            // that was never the problem.
            self = .noteTooLong
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
        case .noteTooLong:
            // The note is named, because the files are not the problem and a
            // sentence that does not say which half to shorten is a sentence
            // the person cannot act on.
            return String(
                localized: "intent.workAddFiles.error.noteTooLong",
                defaultValue: "That note is too long to add to Work. Shorten it, then try again."
            )
        }
    }
}
#endif
