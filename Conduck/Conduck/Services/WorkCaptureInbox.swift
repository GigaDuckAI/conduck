// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkCaptureInbox.swift
//
// App-Group transport for inert Workboard captures. Share extensions publish a
// complete directory with one atomic rename; the app claims a directory with a
// second rename, imports it into the Workboard, then acknowledges deletion. The
// API deliberately has no dispatch operation and the envelope has no gateway
// fields, so capture ingress cannot accidentally become an agent send path.
// Claim tokens protect against stale acknowledgements; `reconcile()` returns
// crash-stranded claims to the pending queue and sweeps only abandoned temp data.

import Foundation
import os

/// Bridges the share extensions' best-effort Darwin notification into the
/// process-local notification already consumed by `PersonalWorkbenchView`.
/// The durable App Group queue remains authoritative: Darwin notifications can
/// coalesce or disappear while the app is suspended, and every board load also
/// drains the queue. This bridge only removes the avoidable delay while the app
/// is already alive and visible.
final class WorkCaptureChangeObserver {
    init() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            workCaptureDarwinChangeCallback,
            WorkCaptureInbox.darwinNotificationName as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(WorkCaptureInbox.darwinNotificationName as CFString),
            nil
        )
    }
}

private func workCaptureDarwinChangeCallback(
    _ center: CFNotificationCenter?,
    _ observer: UnsafeMutableRawPointer?,
    _ name: CFNotificationName?,
    _ object: UnsafeRawPointer?,
    _ userInfo: CFDictionary?
) {
    // `CFNotificationCenter` does not promise a main-thread callback. SwiftUI's
    // observer ultimately mutates a @MainActor model, so hop before publishing.
    DispatchQueue.main.async {
        NotificationCenter.default.post(
            name: WorkCaptureInbox.didChangeNotification,
            object: nil
        )
    }
}

actor WorkCaptureInbox {
    static let shared = WorkCaptureInbox()

    nonisolated static let directoryName = "WorkCaptureInbox"
    nonisolated static let manifestFilename = "manifest.json"
    nonisolated static let didChangeNotification = Notification.Name(
        Constants.identityNamespace + ".work-capture-inbox.changed"
    )
    /// Best-effort cross-process hint posted by the share extensions. The disk
    /// queue remains authoritative because Darwin notifications are coalesced
    /// and can be lost while an app is suspended.
    nonisolated static let darwinNotificationName =
        Constants.identityNamespace + ".work-capture-inbox.changed"

    struct Claim: Sendable {
        let token: UUID
        let envelope: WorkCaptureEnvelope
        let directoryURL: URL

        var id: UUID { envelope.id }

        /// Returns the already-validated local payload URL for a file-backed
        /// entry. Inline text and URL entries intentionally return nil.
        func payloadURL(for entry: WorkCaptureEnvelope.Entry) -> URL? {
            guard entry.kind == .image || entry.kind == .file || entry.kind == .webPage,
                  let relativePath = entry.relativePath else { return nil }
            return directoryURL.appendingPathComponent(relativePath, isDirectory: false)
        }
    }

    enum InboxError: Error, Equatable, Sendable {
        case invalidEnvelope(UUID?, ValidationFailure)
        case staleClaim
        case filesystemFailure

        enum ValidationFailure: String, Sendable {
            case manifestMissing
            case manifestTooLarge
            case manifestUnreadable
            case unsupportedVersion
            case identityMismatch
            case emptyCapture
            case tooManyEntries
            case noteTooLong
            case duplicateEntry
            case invalidSequence
            case unsafeMetadata
            case invalidInlineContent
            case invalidURL
            case unsafeRelativePath
            case missingPayload
            case unexpectedPayload
            case payloadSizeMismatch
            case payloadTooLarge
            case envelopeTooLarge
        }
    }

    struct ReconciliationReport: Sendable, Equatable {
        let releasedClaimCount: Int
        let removedTemporaryCount: Int
        let collisionCount: Int
        /// Reconciliation is best-effort so a single stranded directory cannot
        /// block later claims. This flag makes a scaffold/enumeration/move failure
        /// explicit to callers instead of silently treating it as an empty queue.
        let encounteredFilesystemFailure: Bool

        init(
            releasedClaimCount: Int,
            removedTemporaryCount: Int,
            collisionCount: Int,
            encounteredFilesystemFailure: Bool = false
        ) {
            self.releasedClaimCount = releasedClaimCount
            self.removedTemporaryCount = removedTemporaryCount
            self.collisionCount = collisionCount
            self.encounteredFilesystemFailure = encounteredFilesystemFailure
        }
    }

    private nonisolated static let log = Logger(
        subsystem: Constants.identityNamespace,
        category: "WorkCaptureInbox"
    )

    private let baseURL: URL
    private let fileManager: FileManager
    private var activeClaims: [UUID: UUID] = [:]
    private var didScaffold = false

    private var temporaryURL: URL { baseURL.appendingPathComponent("tmp", isDirectory: true) }
    private var processingURL: URL { baseURL.appendingPathComponent("processing", isDirectory: true) }

    private init() {
        self.baseURL = Self.defaultBaseURL()
        self.fileManager = .default
    }

    init(baseURL: URL, fileManager: FileManager = .default) {
        self.baseURL = baseURL
        self.fileManager = fileManager
    }

    nonisolated static var productionBaseURL: URL { defaultBaseURL() }

    /// The durable queue lives in App-Group Application Support. A local
    /// Application Support fallback keeps source/simulator builds functional
    /// when the community App Group is not provisioned.
    private nonisolated static func defaultBaseURL() -> URL {
        let support: URL
        if let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Constants.appGroupID
        ) {
            support = groupURL.appendingPathComponent("Application Support", isDirectory: true)
        } else if let applicationSupport = try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
        ) {
            support = applicationSupport
        } else {
            // An inert capture is still user data. Falling back to tmp would
            // make an OS cleanup look like a successful save followed by loss.
            preconditionFailure("WorkCaptureInbox requires durable Application Support storage")
        }
        return support.appendingPathComponent(directoryName, isDirectory: true)
    }

    // MARK: - Consumer API

    /// Atomically publishes an in-app quick capture through the same durable,
    /// inert queue as the Share Extension. The note and optional screenshot
    /// become visible together or not at all; a process death can never leave a
    /// Work item without the screenshot the person saw beside it.
    @discardableResult
    func publishAppCapture(
        note: String,
        screenshotPNG: Data?,
        captureID: UUID = UUID(),
        createdAt: Date = Date()
    ) throws -> UUID {
        try publishAppCapture(
            note: note,
            imageData: screenshotPNG,
            imageFilename: "screenshot.png",
            imageMIMEType: "image/png",
            imageTypeIdentifier: "public.png",
            captureID: captureID,
            createdAt: createdAt
        )
    }

    /// Format-honest sibling used by GigaAction after ImageProcessor has
    /// stripped metadata and normalized a supplied screenshot to JPEG.
    @discardableResult
    func publishAppCapture(
        note: String,
        imageData: Data?,
        imageFilename: String,
        imageMIMEType: String,
        imageTypeIdentifier: String,
        captureID: UUID = UUID(),
        createdAt: Date = Date()
    ) throws -> UUID {
        try ensureScaffold()
        let id = captureID
        let temporary = temporaryURL.appendingPathComponent(
            "\(id.uuidString)-\(UUID().uuidString)",
            isDirectory: true
        )
        let published = baseURL.appendingPathComponent(id.uuidString, isDirectory: true)
        let processing = processingURL.appendingPathComponent(id.uuidString, isDirectory: true)

        // Caller-owned identity makes GigaAction recovery idempotent. If the
        // intent was killed after its atomic move but before it cleared the
        // audio retry guard, a later retry observes the same capture rather
        // than publishing a second project. An already-imported capture may no
        // longer have either directory; replaying the same id is still safe
        // because WorkCaptureDrainer persists envelope ids before acknowledge.
        if fileManager.fileExists(atPath: published.path)
            || fileManager.fileExists(atPath: processing.path) {
            return id
        }
        var entries: [WorkCaptureEnvelope.Entry] = []

        if let imageData {
            guard Int64(imageData.count) <= WorkCaptureEnvelope.maximumFileBytes else {
                throw WorkCaptureEnvelope.PublicationValidationFailure.invalidFileEntry
            }
            entries.append(WorkCaptureEnvelope.Entry(
                // App captures currently have at most one image. Reusing the
                // caller-owned capture id makes its material stable even after
                // the first envelope was drained and acknowledged before an
                // intent process died; replay then repairs instead of adding a
                // second screenshot with a fresh UUID.
                id: id,
                kind: .image,
                sequence: 0,
                relativePath: "payload-000.\(WorkCaptureEnvelope.safePathExtension((imageFilename as NSString).pathExtension))",
                displayName: imageFilename,
                mimeType: imageMIMEType,
                typeIdentifier: imageTypeIdentifier,
                byteCount: Int64(imageData.count)
            ))
        }

        let envelope = WorkCaptureEnvelope(
            id: id,
            createdAt: createdAt,
            note: note,
            source: .app,
            entries: entries
        )
        try envelope.validateForPublication()
        let manifest = try envelope.encoded()
        guard manifest.count <= WorkCaptureEnvelope.maximumManifestBytes else {
            throw InboxError.filesystemFailure
        }

        var didPublish = false
        defer {
            if !didPublish { try? fileManager.removeItem(at: temporary) }
        }
        do {
            try fileManager.createDirectory(at: temporary, withIntermediateDirectories: false)
            if let imageData, let relativePath = entries.first?.relativePath {
                try imageData.write(
                    to: temporary.appendingPathComponent(relativePath),
                    options: [.atomic, .completeFileProtection]
                )
            }
            try manifest.write(
                to: temporary.appendingPathComponent(Self.manifestFilename),
                options: [.atomic, .completeFileProtection]
            )
            try fileManager.moveItem(at: temporary, to: published)
            didPublish = true
            postLocalChange()
            return id
        } catch {
            // Another process may have won the same deterministic publication
            // between the existence check and atomic move. Its complete
            // directory is the durable result; the losing temp is discarded.
            if fileManager.fileExists(atPath: published.path)
                || fileManager.fileExists(atPath: processing.path) {
                return id
            }
            throw InboxError.filesystemFailure
        }
    }

    func pendingCount() throws -> Int {
        try ensureScaffold()
        return try pendingEnvelopeIDs().count
    }

    /// Claims the oldest published capture. An atomic move is the cross-process
    /// ownership boundary; a second caller either claims another capture or sees
    /// no work. Malformed envelopes are securely removed and reported without
    /// ever entering Workboard persistence.
    func claimNext() throws -> Claim? {
        try ensureScaffold()
        for id in try pendingEnvelopeIDs() {
            let published = baseURL.appendingPathComponent(id.uuidString, isDirectory: true)
            let claimed = processingURL.appendingPathComponent(id.uuidString, isDirectory: true)
            do {
                try fileManager.moveItem(at: published, to: claimed)
            } catch {
                // A vanished source or occupied processing destination is an
                // ordinary claim race. Protection, quota, and other I/O errors
                // must not masquerade as an empty queue.
                if Self.isMissingFileError(error) || Self.isDestinationExistsError(error) {
                    continue
                }
                throw InboxError.filesystemFailure
            }

            do {
                let envelope = try validateEnvelope(in: claimed, expectedID: id)
                let token = UUID()
                activeClaims[id] = token
                postLocalChange()
                return Claim(token: token, envelope: envelope, directoryURL: claimed)
            } catch let error as InboxError {
                switch error {
                case .invalidEnvelope(_, let reason):
                    // Only a deterministic wire/containment violation is
                    // destructive. The reason is logged before the bytes go: it
                    // is the only forensic record of what a person shared and
                    // never received, and the capture id ties it to the queue.
                    Self.log.error(
                        "Discarding malformed Work capture \(id.uuidString, privacy: .public): \(reason.rawValue, privacy: .public)"
                    )
                    // If removal itself fails, leave the directory in processing
                    // for reconciliation and surface the I/O fault.
                    do {
                        try fileManager.removeItem(at: claimed)
                    } catch {
                        throw InboxError.filesystemFailure
                    }
                    postLocalChange()
                    throw error
                case .filesystemFailure, .staleClaim:
                    try preserveClaimedDirectory(id: id, at: claimed)
                    throw error
                }
            } catch {
                // An unclassified validator failure is not proof of malformed
                // private data. Preserve it and fail closed for this pass.
                try preserveClaimedDirectory(id: id, at: claimed)
                throw InboxError.filesystemFailure
            }
        }
        return nil
    }

    /// Deletes a successfully imported capture. Idempotency belongs to the
    /// Workboard importer: it should persist `envelope.id` before acknowledging,
    /// so a process death between those operations merely presents the same id
    /// again and never creates a second draft.
    func acknowledge(_ claim: Claim) throws {
        try requireActive(claim)
        do {
            try fileManager.removeItem(at: claim.directoryURL)
        } catch {
            guard Self.isMissingFileError(error) else {
                throw InboxError.filesystemFailure
            }
        }
        activeClaims.removeValue(forKey: claim.id)
        postLocalChange()
    }

    /// Returns a capture to the pending queue when persistence could not accept
    /// it. Nothing is dispatched and no bytes are lost. A UUID collision is kept
    /// in processing for explicit reconciliation rather than overwriting either
    /// directory.
    func release(_ claim: Claim) throws {
        try requireActive(claim)
        let destination = baseURL.appendingPathComponent(claim.id.uuidString, isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw InboxError.filesystemFailure
        }
        do {
            try fileManager.moveItem(at: claim.directoryURL, to: destination)
            activeClaims.removeValue(forKey: claim.id)
            postLocalChange()
        } catch {
            throw InboxError.filesystemFailure
        }
    }

    /// Repairs crash-stranded claims and abandoned extension writes. Active
    /// claims owned by this actor are never touched. Call once during app launch,
    /// then claim until nil. The 1-hour temp horizon is generous relative to an
    /// extension copy while bounding private bytes left by a killed extension.
    func reconcile(now: Date = Date()) -> ReconciliationReport {
        var released = 0
        var removedTemporary = 0
        var collisions = 0
        var encounteredFilesystemFailure = false

        do {
            try ensureScaffold()
        } catch {
            return ReconciliationReport(
                releasedClaimCount: 0,
                removedTemporaryCount: 0,
                collisionCount: 0,
                encounteredFilesystemFailure: true
            )
        }

        let strandedIDs: [UUID]
        do {
            strandedIDs = try childEnvelopeIDs(of: processingURL)
        } catch {
            strandedIDs = []
            encounteredFilesystemFailure = true
        }
        for id in strandedIDs where activeClaims[id] == nil {
            let source = processingURL.appendingPathComponent(id.uuidString, isDirectory: true)
            let destination = baseURL.appendingPathComponent(id.uuidString, isDirectory: true)
            if fileManager.fileExists(atPath: destination.path) {
                collisions += 1
                continue
            }
            do {
                try fileManager.moveItem(at: source, to: destination)
                released += 1
            } catch {
                encounteredFilesystemFailure = true
            }
        }

        let cutoff = now.addingTimeInterval(-60 * 60)
        let temporaryChildren: [URL]
        do {
            temporaryChildren = try directoryChildren(of: temporaryURL)
        } catch {
            temporaryChildren = []
            encounteredFilesystemFailure = true
        }
        for child in temporaryChildren {
            let modifiedAt: Date
            do {
                modifiedAt = try child.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate ?? now
            } catch {
                encounteredFilesystemFailure = true
                continue
            }
            guard modifiedAt < cutoff else { continue }
            do {
                try fileManager.removeItem(at: child)
                removedTemporary += 1
            } catch {
                encounteredFilesystemFailure = true
            }
        }

        if released > 0 || removedTemporary > 0 {
            postLocalChange()
        }
        return ReconciliationReport(
            releasedClaimCount: released,
            removedTemporaryCount: removedTemporary,
            collisionCount: collisions,
            encounteredFilesystemFailure: encounteredFilesystemFailure
        )
    }

    // MARK: - Validation

    private func validateEnvelope(in directory: URL, expectedID: UUID) throws -> WorkCaptureEnvelope {
        let manifestURL = directory.appendingPathComponent(Self.manifestFilename, isDirectory: false)
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: manifestURL.path)
        } catch {
            if Self.isMissingFileError(error) {
                throw InboxError.invalidEnvelope(expectedID, .manifestMissing)
            }
            throw InboxError.filesystemFailure
        }
        guard (attributes[.type] as? FileAttributeType) == .typeRegular,
              let manifestSize = attributes[.size] as? NSNumber else {
            throw InboxError.invalidEnvelope(expectedID, .manifestMissing)
        }
        guard manifestSize.int64Value <= Int64(WorkCaptureEnvelope.maximumManifestBytes) else {
            throw InboxError.invalidEnvelope(expectedID, .manifestTooLarge)
        }
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw InboxError.filesystemFailure
        }
        let envelope: WorkCaptureEnvelope
        do {
            envelope = try WorkCaptureEnvelope.decode(data)
        } catch {
            throw InboxError.invalidEnvelope(expectedID, .manifestUnreadable)
        }
        guard envelope.version == WorkCaptureEnvelope.currentVersion else {
            throw InboxError.invalidEnvelope(expectedID, .unsupportedVersion)
        }
        guard envelope.id == expectedID else {
            throw InboxError.invalidEnvelope(expectedID, .identityMismatch)
        }
        guard envelope.note.count <= WorkCaptureEnvelope.maximumNoteCharacters else {
            throw InboxError.invalidEnvelope(expectedID, .noteTooLong)
        }
        guard envelope.entries.count <= WorkCaptureEnvelope.maximumEntryCount else {
            throw InboxError.invalidEnvelope(expectedID, .tooManyEntries)
        }
        guard !envelope.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !envelope.entries.isEmpty else {
            throw InboxError.invalidEnvelope(expectedID, .emptyCapture)
        }

        var entryIDs = Set<UUID>()
        var sequences = Set<Int>()
        var relativePaths = Set<String>()
        var totalBytes: Int64 = 0

        for entry in envelope.entries {
            guard entryIDs.insert(entry.id).inserted, sequences.insert(entry.sequence).inserted else {
                throw InboxError.invalidEnvelope(expectedID, .duplicateEntry)
            }
            guard entry.sequence >= 0 else {
                throw InboxError.invalidEnvelope(expectedID, .invalidSequence)
            }
            guard WorkCaptureEnvelope.safeDisplayName(entry.displayName) == entry.displayName,
                  Self.isSafeOpaqueMetadata(entry.displayName),
                  Self.isSafeOpaqueMetadata(entry.mimeType),
                  Self.isSafeOpaqueMetadata(entry.typeIdentifier) else {
                throw InboxError.invalidEnvelope(expectedID, .unsafeMetadata)
            }

            switch entry.kind {
            case .text:
                guard entry.relativePath == nil,
                      let text = entry.text,
                      !text.isEmpty,
                      text.count <= WorkCaptureEnvelope.maximumTextCharacters else {
                    throw InboxError.invalidEnvelope(expectedID, .invalidInlineContent)
                }
            case .url:
                guard entry.relativePath == nil,
                      let value = entry.text,
                      WorkCaptureEnvelope.isAcceptedWebURL(value) else {
                    throw InboxError.invalidEnvelope(expectedID, .invalidURL)
                }
            case .image, .file, .webPage:
                guard entry.text == nil,
                      let relativePath = entry.relativePath,
                      Self.isSafeLeaf(relativePath),
                      relativePaths.insert(relativePath).inserted else {
                    throw InboxError.invalidEnvelope(expectedID, .unsafeRelativePath)
                }
                let payloadURL = directory.appendingPathComponent(relativePath, isDirectory: false)
                let payloadAttributes: [FileAttributeKey: Any]
                do {
                    payloadAttributes = try fileManager.attributesOfItem(atPath: payloadURL.path)
                } catch {
                    if Self.isMissingFileError(error) {
                        throw InboxError.invalidEnvelope(expectedID, .missingPayload)
                    }
                    throw InboxError.filesystemFailure
                }
                guard (payloadAttributes[.type] as? FileAttributeType) == .typeRegular,
                      let sizeNumber = payloadAttributes[.size] as? NSNumber else {
                    throw InboxError.invalidEnvelope(expectedID, .missingPayload)
                }
                let size = sizeNumber.int64Value
                guard entry.byteCount == nil || entry.byteCount == size else {
                    throw InboxError.invalidEnvelope(expectedID, .payloadSizeMismatch)
                }
                guard size <= WorkCaptureEnvelope.maximumFileBytes else {
                    throw InboxError.invalidEnvelope(expectedID, .payloadTooLarge)
                }
                totalBytes += size
                guard totalBytes <= WorkCaptureEnvelope.maximumEnvelopeBytes else {
                    throw InboxError.invalidEnvelope(expectedID, .envelopeTooLarge)
                }
            }
        }

        let allowedNames = relativePaths.union([Self.manifestFilename])
        let actualNames = Set(try directoryChildren(of: directory).map(\.lastPathComponent))
        guard actualNames == allowedNames else {
            throw InboxError.invalidEnvelope(expectedID, .unexpectedPayload)
        }
        return envelope
    }

    private nonisolated static func isSafeLeaf(_ value: String) -> Bool {
        guard !value.isEmpty,
              value != ".",
              value != "..",
              value != manifestFilename,
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

    private nonisolated static func isMissingFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain else { return false }
        return nsError.code == NSFileNoSuchFileError
            || nsError.code == NSFileReadNoSuchFileError
    }

    private nonisolated static func isDestinationExistsError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && nsError.code == NSFileWriteFileExistsError
    }

    // MARK: - Filesystem helpers

    private func requireActive(_ claim: Claim) throws {
        guard activeClaims[claim.id] == claim.token,
              claim.directoryURL.deletingLastPathComponent().standardizedFileURL == processingURL.standardizedFileURL else {
            throw InboxError.staleClaim
        }
    }

    private func ensureScaffold() throws {
        guard !didScaffold else { return }
        do {
            for url in [baseURL, temporaryURL, processingURL] {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            }
        } catch {
            throw InboxError.filesystemFailure
        }
        didScaffold = true
    }

    private func pendingEnvelopeIDs() throws -> [UUID] {
        var datedIDs: [(id: UUID, modifiedAt: Date)] = []
        for id in try childEnvelopeIDs(of: baseURL) {
            let url = baseURL.appendingPathComponent(id.uuidString, isDirectory: true)
            do {
                let attributes = try fileManager.attributesOfItem(atPath: url.path)
                datedIDs.append((
                    id: id,
                    modifiedAt: attributes[.modificationDate] as? Date ?? .distantPast
                ))
            } catch {
                // Another claimant may win after enumeration. All other access
                // failures are transient faults callers must be able to retry.
                if Self.isMissingFileError(error) { continue }
                throw InboxError.filesystemFailure
            }
        }
        return datedIDs.sorted { lhs, rhs in
            if lhs.modifiedAt == rhs.modifiedAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.modifiedAt < rhs.modifiedAt
        }.map(\.id)
    }

    private func childEnvelopeIDs(of parent: URL) throws -> [UUID] {
        try directoryChildren(of: parent).compactMap { UUID(uuidString: $0.lastPathComponent) }
    }

    private func directoryChildren(of parent: URL) throws -> [URL] {
        do {
            return try fileManager.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: []
            )
        } catch {
            throw InboxError.filesystemFailure
        }
    }

    /// Validation has not minted an active token yet, so transient failures use
    /// this narrow rollback instead of the public `release` API.
    private func preserveClaimedDirectory(id: UUID, at claimed: URL) throws {
        let destination = baseURL.appendingPathComponent(id.uuidString, isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw InboxError.filesystemFailure
        }
        do {
            try fileManager.moveItem(at: claimed, to: destination)
            postLocalChange()
        } catch {
            throw InboxError.filesystemFailure
        }
    }

    private nonisolated func postLocalChange() {
        // Inbox work runs on this actor's executor, but the notification is
        // consumed by SwiftUI and refreshes a @MainActor model. Match the
        // Darwin bridge above and publish the process-local hint on main.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }
}
