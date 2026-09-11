// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkCaptureInbox.swift
//
// App-Group transport for inert Workboard captures. Share extensions publish a
// complete directory with one atomic rename; the app claims a directory with a
// second rename, imports it into the Workboard, then acknowledges deletion. The
// API deliberately has no dispatch operation and the envelope has no gateway
// fields, so capture ingress cannot accidentally become an agent send path.
// Claim tokens protect against stale acknowledgements within one process. Across
// processes — the app and a headless intent process drain the same queue — the
// claiming rename carries ownership itself: its destination name is unique to one
// acquisition, so no other process can name, requeue, or roll back that path, and
// every later operation on a claim verifies that name's generation. A lease file
// written inside it names the owner and carries the heartbeat that keeps a long
// import alive. `reconcile()` returns to the pending queue only claims no live
// acquisition covers, and sweeps only abandoned temp data.
//
// Acknowledgement is never self-issued: only the drainer, after the imported
// material is durably readable, may delete a claim.

import CryptoKit
import Foundation
import UniformTypeIdentifiers
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

/// One file a caller hands to `WorkCaptureInbox.publishFileCapture`.
///
/// The bytes stay on disk: the publisher copies the file into staging instead of
/// reading it, so a multi-file capture is bounded by the queue's byte limits and
/// not by the footprint of the process publishing it — which for a Shortcut is a
/// headless process the system kills without warning. `byteCount` is what the
/// caller believes the file weighs; it buys an early refusal, and the queue
/// still measures the bytes it actually stages.
struct WorkCaptureFileInput: Sendable {
    let url: URL
    let displayName: String?
    let mimeType: String?
    let typeIdentifier: String?
    let byteCount: Int64
}

actor WorkCaptureInbox {
    static let shared = WorkCaptureInbox()

    nonisolated static let directoryName = "WorkCaptureInbox"
    nonisolated static let manifestFilename = "manifest.json"
    /// Ownership marker written inside a claimed directory. The name is reserved
    /// against payload leaves so a published envelope can never declare it.
    nonisolated static let leaseFilename = "claim-lease.json"
    /// Separates the three fields a claimed directory's name carries. A UUID
    /// string never contains it, so the name parses unambiguously even when the
    /// claim instant is negative.
    nonisolated static let claimNameSeparator: Character = "_"
    /// A claim this old is treated as abandoned. Chosen far above a realistic
    /// drain (a bounded envelope persists in seconds) so a live drainer is never
    /// robbed, and low enough that a capture stranded by a crash returns within
    /// one recovery window instead of hiding for an hour. A drain that genuinely
    /// needs longer refreshes its lease rather than widening this horizon.
    nonisolated static let staleClaimHorizon: TimeInterval = 5 * 60
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
        /// Identifies the one acquisition that took this capture. It is spelled
        /// into the claimed directory's name, so it is the value every later
        /// operation checks before touching those bytes.
        let generation: UUID
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

    /// The on-disk ownership marker. `owner` identifies one inbox instance and
    /// `generation` the one acquisition it names, so a relaunched process never
    /// recognizes its predecessor's lease as its own and falls back to the
    /// horizon, which is the only cross-process liveness signal a plain file can
    /// carry. `refreshedAt` is what a heartbeat extends.
    struct ClaimLease: Codable, Equatable, Sendable {
        let owner: UUID
        let generation: UUID
        let refreshedAt: Date
    }

    /// The identity a claimed directory's NAME carries. The claiming rename is
    /// the only atomic step of an acquisition, so its destination has to answer
    /// both ownership questions on its own: which capture this is, and which
    /// acquisition took it. `claimedAt` is the one freshness clock that is atomic
    /// with that rename — a rename leaves the directory's own timestamps alone,
    /// so they still date the publication — which is what lets an acquisition
    /// whose lease has not landed yet read as live rather than as abandoned.
    private struct ClaimDirectory {
        let envelopeID: UUID
        /// Nil for a bare-id directory. No acquisition in this build can create
        /// one, so such a directory is stranded by definition.
        let generation: UUID?
        let claimedAt: Date?
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
        /// Directories left in processing because a live acquisition still covers
        /// them — a lease inside the stale horizon, or a claiming rename whose
        /// lease has not landed yet. Distinguishes "another process is draining
        /// it" from "nothing was stranded", which are otherwise both a zero
        /// release count.
        let respectedLeaseCount: Int

        init(
            releasedClaimCount: Int,
            removedTemporaryCount: Int,
            collisionCount: Int,
            encounteredFilesystemFailure: Bool = false,
            respectedLeaseCount: Int = 0
        ) {
            self.releasedClaimCount = releasedClaimCount
            self.removedTemporaryCount = removedTemporaryCount
            self.collisionCount = collisionCount
            self.encounteredFilesystemFailure = encounteredFilesystemFailure
            self.respectedLeaseCount = respectedLeaseCount
        }
    }

    private nonisolated static let log = Logger(
        subsystem: Constants.identityNamespace,
        category: "WorkCaptureInbox"
    )

    private let baseURL: URL
    private let fileManager: FileManager
    /// Identifies this instance in every lease it writes. Minted per instance so
    /// two inboxes over one directory — the app and a headless intent process —
    /// can tell each other's claims apart.
    nonisolated let ownerID = UUID()
    /// Keyed by claim generation, not by envelope id: a capture requeued and
    /// retaken by another process is a different acquisition, and this map must
    /// not let one instance's bookkeeping speak for the other's.
    private var activeClaims: [UUID: UUID] = [:]
    private var didScaffold = false
    /// Mints the generation spelled into each claimed directory's name. Only an
    /// isolated-directory inbox can substitute it, and only so that the claiming
    /// rename's destination-exists branch is reachable at all: production mints
    /// a fresh UUID per attempt, which can never name a path that already
    /// exists, so that branch is otherwise dead to every test.
    private let makeGeneration: @Sendable () -> UUID

    private var temporaryURL: URL { baseURL.appendingPathComponent("tmp", isDirectory: true) }
    private var processingURL: URL { baseURL.appendingPathComponent("processing", isDirectory: true) }

    private init() {
        self.baseURL = Self.defaultBaseURL()
        self.fileManager = .default
        self.makeGeneration = { UUID() }
    }

    init(
        baseURL: URL,
        fileManager: FileManager = .default,
        makeGeneration: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.baseURL = baseURL
        self.fileManager = fileManager
        self.makeGeneration = makeGeneration
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
        var staged: [StagedEntry] = []
        if let imageData {
            staged.append(StagedEntry(
                entry: WorkCaptureEnvelope.Entry(
                    // App captures currently have at most one image. Reusing the
                    // caller-owned capture id makes its material stable even after
                    // the first envelope was drained and acknowledged before an
                    // intent process died; replay then repairs instead of adding a
                    // second screenshot with a fresh UUID.
                    id: captureID,
                    kind: .image,
                    sequence: 0,
                    relativePath: "payload-000.\(WorkCaptureEnvelope.safePathExtension((imageFilename as NSString).pathExtension))",
                    displayName: imageFilename,
                    mimeType: imageMIMEType,
                    typeIdentifier: imageTypeIdentifier,
                    byteCount: Int64(imageData.count)
                ),
                payload: .inline(imageData)
            ))
        }
        return try publishCapture(
            id: captureID,
            createdAt: createdAt,
            note: note,
            source: .app,
            staged: staged
        )
    }

    /// Publishes the files a Shortcut handed over as ONE capture: the note and
    /// every file become cards together or not at all.
    ///
    /// Identity is derived rather than minted — the entry at `sequence` is
    /// UUIDv5 over `(captureID, sequence)` — so a Shortcut killed after the
    /// publication and rerun repairs the same cards instead of laying a second
    /// copy of the same files on the desk. That is also why `captureID` belongs
    /// to the caller: it is the only thing that survives the process.
    ///
    /// A set that cannot become one capture is refused whole. Truncating it
    /// would tell a person who chose forty files that twenty-four of them are
    /// what they captured, and they would have no way of knowing which.
    @discardableResult
    func publishFileCapture(
        note: String?,
        files: [WorkCaptureFileInput],
        captureID: UUID = UUID(),
        createdAt: Date = Date()
    ) throws -> UUID {
        guard files.count <= WorkCaptureEnvelope.maximumEntryCount else {
            throw WorkCaptureEnvelope.PublicationValidationFailure.tooManyEntries
        }
        // The declared sizes are refused first because they cost no I/O: a
        // caller that already knows the set is too big is told so before the
        // queue opens a directory. The staged bytes are measured again below,
        // so a wrong declaration cannot smuggle anything past these limits.
        var declaredBytes: Int64 = 0
        for file in files {
            guard file.byteCount <= WorkCaptureEnvelope.maximumFileBytes else {
                throw WorkCaptureEnvelope.PublicationValidationFailure.invalidFileEntry
            }
            declaredBytes += max(0, file.byteCount)
            guard declaredBytes <= WorkCaptureEnvelope.maximumEnvelopeBytes else {
                throw InboxError.invalidEnvelope(captureID, .envelopeTooLarge)
            }
        }

        var staged: [StagedEntry] = []
        for (sequence, file) in files.enumerated() {
            let displayName = WorkCaptureEnvelope.safeDisplayName(file.displayName)
                ?? WorkCaptureEnvelope.safeDisplayName(file.url.lastPathComponent)
            // The staged leaf is generated. Only an extension is taken from the
            // source's name, and only through the generator that reduces
            // anything unusable to `dat`, so no foreign name reaches the disk.
            let namedExtension = displayName.map { ($0 as NSString).pathExtension } ?? ""
            let pathExtension = WorkCaptureEnvelope.safePathExtension(
                namedExtension.isEmpty ? file.url.pathExtension : namedExtension
            )
            // A picture is declared a picture HERE, where the caller's metadata
            // is still in hand, rather than being re-derived downstream: the
            // drainer already mints a thumbnail and a gallery page for an
            // `.image` entry, and a photo that arrives as a generic file is a
            // row the person has to open one at a time to recognise. The mime
            // type is asked first because it is what a share sheet and a
            // Shortcut both reliably carry; the type identifier answers for the
            // files that carry only that. Everything else stays `.file`.
            let mimeType = WorkCaptureEnvelope.safeOpaqueMetadata(file.mimeType)
            let typeIdentifier = WorkCaptureEnvelope.safeOpaqueMetadata(file.typeIdentifier)
            let isImage = mimeType?.lowercased().hasPrefix("image/") == true
                || typeIdentifier.flatMap { UTType($0)?.conforms(to: .image) } == true
            staged.append(StagedEntry(
                entry: WorkCaptureEnvelope.Entry(
                    id: Self.fileEntryID(forCapture: captureID, sequence: sequence),
                    kind: isImage ? .image : .file,
                    sequence: sequence,
                    relativePath: "payload-\(Self.paddedSequence(sequence)).\(pathExtension)",
                    displayName: displayName,
                    mimeType: mimeType,
                    typeIdentifier: typeIdentifier,
                    byteCount: file.byteCount
                ),
                payload: .copiedFile(from: file.url)
            ))
        }

        return try publishCapture(
            id: captureID,
            createdAt: createdAt,
            note: note ?? "",
            source: .shortcut,
            staged: staged
        )
    }

    /// The permanent identity of the file captured at `sequence`.
    ///
    /// The same shape as `WorkVoiceScreenshotCoordinator.materialID(forCapture:)`
    /// — UUIDv5 over a fixed namespace — in a namespace of its OWN, so a file
    /// entry can never name the card another derivation already owns. The
    /// position is part of the name because a capture carries many files and
    /// each needs an identity a rerun reproduces.
    nonisolated static func fileEntryID(forCapture captureID: UUID, sequence: Int) -> UUID {
        var hasher = Insecure.SHA1()
        withUnsafeBytes(of: fileEntryNamespace.uuid) { hasher.update(bufferPointer: $0) }
        withUnsafeBytes(of: captureID.uuid) { hasher.update(bufferPointer: $0) }
        // Fixed width and byte order: the name has to be the same on every
        // device and every build, so the platform's Int is never hashed.
        var position = UInt32(truncatingIfNeeded: sequence).bigEndian
        withUnsafeBytes(of: &position) { hasher.update(bufferPointer: $0) }
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

    /// Derivation namespace for file entries, a literal in the same spirit as
    /// the desk's own fixed id. Its only requirement is that no other
    /// derivation uses it, which is what keeps a captured file from ever naming
    /// a voice capture's recording, screenshot or fallback note.
    private nonisolated static let fileEntryNamespace = UUID(
        uuidString: "F11E0000-0000-4000-A000-000000000001"
    )!

    func pendingCount() throws -> Int {
        try ensureScaffold()
        return try pendingEnvelopeIDs().count
    }

    /// Claims the oldest published capture. The atomic move IS the acquisition of
    /// ownership: its destination is named for this attempt's generation and the
    /// instant it happens, so exactly one caller can create that path, no other
    /// process can requeue or roll back a claim it did not take, and a rename
    /// whose lease has not landed yet still reads as live rather than abandoned.
    /// The lease follows immediately and before validation, naming the owner for
    /// acknowledgement and carrying the heartbeat. Malformed envelopes are
    /// securely removed and reported without ever entering Workboard persistence.
    func claimNext(now: Date = Date()) throws -> Claim? {
        try ensureScaffold()
        for id in try pendingEnvelopeIDs() {
            let published = baseURL.appendingPathComponent(id.uuidString, isDirectory: true)
            let generation = makeGeneration()
            let claimed = processingURL.appendingPathComponent(
                Self.claimDirectoryName(envelopeID: id, claimedAt: now, generation: generation),
                isDirectory: true
            )
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
                // An unleasable claim is refused outright: an acknowledgement has
                // to be able to prove ownership, and the acquisition window that
                // covers a markerless claim expires with the same horizon.
                try writeLease(in: claimed, generation: generation, now: now)
            } catch {
                try preserveClaimedDirectory(id: id, at: claimed, generation: generation)
                throw InboxError.filesystemFailure
            }

            do {
                let envelope = try validateEnvelope(in: claimed, expectedID: id)
                let token = UUID()
                activeClaims[generation] = token
                postLocalChange()
                return Claim(
                    token: token,
                    generation: generation,
                    envelope: envelope,
                    directoryURL: claimed
                )
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
                    try preserveClaimedDirectory(id: id, at: claimed, generation: generation)
                    throw error
                }
            } catch {
                // An unclassified validator failure is not proof of malformed
                // private data. Preserve it and fail closed for this pass.
                try preserveClaimedDirectory(id: id, at: claimed, generation: generation)
                throw InboxError.filesystemFailure
            }
        }
        return nil
    }

    // MARK: - Acknowledgement seam

    /// THE acknowledgement point: the queue's only deletion of imported bytes,
    /// and the inbox never reaches it on its own. The drainer calls this once the
    /// capture is durably readable from the store — every material row, and the
    /// blob of every material whose bytes it carries. Anything acknowledged
    /// before that is unrecoverable, while anything acknowledged twice is merely
    /// replayed: the importer persists `envelope.id` first, so a death between
    /// import and acknowledgement presents the same id again and never creates a
    /// second draft.
    func acknowledge(_ claim: Claim) throws {
        try requireActive(claim)
        try requireLeaseOwnership(claim)
        do {
            try fileManager.removeItem(at: claim.directoryURL)
        } catch {
            guard Self.isMissingFileError(error) else {
                throw InboxError.filesystemFailure
            }
        }
        activeClaims.removeValue(forKey: claim.generation)
        postLocalChange()
    }

    /// Returns a capture to the pending queue when persistence could not accept
    /// it. Nothing is dispatched and no bytes are lost. A UUID collision is kept
    /// in processing for explicit reconciliation rather than overwriting either
    /// directory.
    ///
    /// A release that cannot land ends this instance's interest in the claim all
    /// the same: the import that held it is over either way, so the local token
    /// goes and only the on-disk rules decide who recovers the directory.
    func release(_ claim: Claim) throws {
        try requireActive(claim)
        try requireLeaseOwnership(claim)
        let destination = baseURL.appendingPathComponent(claim.id.uuidString, isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path) else {
            abandonLocalClaim(claim)
            throw InboxError.filesystemFailure
        }
        removeLease(in: claim.directoryURL)
        do {
            try fileManager.moveItem(at: claim.directoryURL, to: destination)
            activeClaims.removeValue(forKey: claim.generation)
            postLocalChange()
        } catch {
            abandonLocalClaim(claim)
            throw InboxError.filesystemFailure
        }
    }

    /// Drop this instance's bookkeeping for a claim it can no longer finish,
    /// leaving the claimed directory exactly where it stands.
    ///
    /// `reconcile` skips every directory `activeClaims` still names, because a
    /// live import must never have its bytes requeued underneath it. A token
    /// held past the end of that import inverts the protection: no reconciliation
    /// in this process can ever see the directory again, so a transient fault at
    /// the moment of release strands the capture until the process dies, however
    /// many times the app retries in the foreground. Nothing is deleted and
    /// nothing is moved here — the lease, or the stale horizon over a directory
    /// whose lease has already gone, is what decides who picks it up.
    private func abandonLocalClaim(_ claim: Claim) {
        activeClaims.removeValue(forKey: claim.generation)
    }

    /// Extends ownership of a claim whose durable import legitimately outlives
    /// the stale horizon. Callers that finish inside the horizon never need it.
    func refreshLease(_ claim: Claim, now: Date = Date()) throws {
        try requireActive(claim)
        try requireLeaseOwnership(claim)
        try writeLease(in: claim.directoryURL, generation: claim.generation, now: now)
    }

    /// Repairs crash-stranded claims and abandoned extension writes. Claims this
    /// actor holds are never touched, and neither are claims another process's
    /// lease still covers — the queue is drained by the app and by headless
    /// intent processes, so process-local bookkeeping alone cannot decide who
    /// owns a directory. Call once during app launch, then claim until nil. The
    /// 1-hour temp horizon is generous relative to an extension copy while
    /// bounding private bytes left by a killed extension.
    func reconcile(now: Date = Date()) -> ReconciliationReport {
        var released = 0
        var removedTemporary = 0
        var collisions = 0
        var respectedLeases = 0
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

        let strandedChildren: [URL]
        do {
            strandedChildren = try directoryChildren(of: processingURL)
        } catch {
            strandedChildren = []
            encounteredFilesystemFailure = true
        }
        for source in strandedChildren {
            guard let claimed = Self.claimDirectory(named: source.lastPathComponent) else { continue }
            if let generation = claimed.generation, activeClaims[generation] != nil { continue }
            let destination = baseURL.appendingPathComponent(
                claimed.envelopeID.uuidString,
                isDirectory: true
            )
            guard isAbandonedClaim(claimed, at: source, now: now) else {
                respectedLeases += 1
                continue
            }
            if fileManager.fileExists(atPath: destination.path) {
                collisions += 1
                continue
            }
            // The marker belongs to processing. Carrying it back would leave an
            // undeclared file in a directory whose containment is exact.
            removeLease(in: source)
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
            encounteredFilesystemFailure: encounteredFilesystemFailure,
            respectedLeaseCount: respectedLeases
        )
    }

    // MARK: - Cross-process claim ownership

    /// The on-disk name of one acquisition. It is not private because it IS the
    /// ownership boundary: reconciliation reads it back, and a test that stages
    /// an acquisition has to spell exactly what the claiming rename creates.
    nonisolated static func claimDirectoryName(
        envelopeID: UUID,
        claimedAt: Date,
        generation: UUID
    ) -> String {
        let separator = claimNameSeparator
        return "\(envelopeID.uuidString)\(separator)\(epochSeconds(claimedAt))\(separator)\(generation.uuidString)"
    }

    private nonisolated static func claimDirectory(named name: String) -> ClaimDirectory? {
        if let envelopeID = UUID(uuidString: name) {
            return ClaimDirectory(envelopeID: envelopeID, generation: nil, claimedAt: nil)
        }
        let fields = name.split(separator: claimNameSeparator, omittingEmptySubsequences: false)
        guard fields.count == 3,
              let envelopeID = UUID(uuidString: String(fields[0])),
              let seconds = Int64(fields[1]),
              let generation = UUID(uuidString: String(fields[2])) else { return nil }
        return ClaimDirectory(
            envelopeID: envelopeID,
            generation: generation,
            claimedAt: Date(timeIntervalSince1970: TimeInterval(seconds))
        )
    }

    /// Clamped and finite-checked so no date a caller can supply traps the
    /// conversion; a nonsense instant only ages the claim from a boundary.
    private nonisolated static func epochSeconds(_ date: Date) -> Int64 {
        let raw = date.timeIntervalSince1970.rounded(.down)
        guard raw.isFinite else { return 0 }
        return Int64(min(max(raw, -8_000_000_000_000), 8_000_000_000_000))
    }

    /// Whether any acquisition currently holds `id` in processing. The claim
    /// path carries a generation, so identity has to be read out of the name
    /// rather than spelled as one expected path.
    private func isClaimed(_ id: UUID) -> Bool {
        guard let children = try? directoryChildren(of: processingURL) else { return false }
        return children.contains { child in
            Self.claimDirectory(named: child.lastPathComponent)?.envelopeID == id
        }
    }

    /// A claimed directory is abandoned when no live acquisition covers it: its
    /// name predates generation-scoped claims, its lease names this instance
    /// (which is not holding that generation, or the caller would have skipped
    /// it), or both the instant its name carries and its lease predate the stale
    /// horizon. The name's instant is what protects a rename whose lease has not
    /// landed yet, and it is the only clock atomic with that rename. A claim
    /// dated in the future is respected until the clock catches up — skew must
    /// never let two processes drain one capture at once.
    private func isAbandonedClaim(_ claimed: ClaimDirectory, at directory: URL, now: Date) -> Bool {
        guard let generation = claimed.generation, let claimedAt = claimed.claimedAt else {
            return true
        }
        switch leaseState(in: directory, fallbackDate: claimedAt) {
        case .absent:
            return now.timeIntervalSince(claimedAt) >= Self.staleClaimHorizon
        case .held(let owner, let leasedGeneration, let refreshedAt):
            // The path is unique to one acquisition, so a lease naming this
            // instance on a generation it no longer holds is its own dead claim.
            if owner == ownerID, leasedGeneration == generation { return true }
            return now.timeIntervalSince(max(claimedAt, refreshedAt)) >= Self.staleClaimHorizon
        }
    }

    /// Fails a claim whose directory another process has taken over. Without it
    /// an acknowledgement could delete, and a release could requeue, bytes that
    /// a live drainer in another process is reading.
    private func requireLeaseOwnership(_ claim: Claim) throws {
        switch leaseState(in: claim.directoryURL, fallbackDate: Date()) {
        case .absent:
            // The marker is written before a claim is handed out and the path is
            // unique to this acquisition, so a missing marker — whether the
            // directory is gone or merely stripped — means the claim was taken.
            activeClaims.removeValue(forKey: claim.generation)
            throw InboxError.staleClaim
        case .held(let owner, let generation, _):
            // An unreadable marker is corruption, not evidence of a takeover: a
            // process that steals the claim writes a readable lease of its own.
            guard let owner else { return }
            guard owner != ownerID || generation != claim.generation else { return }
            activeClaims.removeValue(forKey: claim.generation)
            throw InboxError.staleClaim
        }
    }

    /// Whether `directory` is safe for this acquisition's own rollback to move.
    /// A readable lease naming anyone else means the path was taken over, and
    /// rolling it back would requeue bytes another drainer is reading.
    private func isOwnedForRollback(_ directory: URL, generation: UUID) -> Bool {
        switch leaseState(in: directory, fallbackDate: Date()) {
        case .absent:
            // The lease may simply not have landed yet: rollback is reached from
            // the failure of the write itself.
            return true
        case .held(let owner, let leasedGeneration, _):
            guard let owner else { return true }
            return owner == ownerID && leasedGeneration == generation
        }
    }

    private enum LeaseState {
        case absent
        case held(owner: UUID?, generation: UUID?, refreshedAt: Date)
    }

    private func leaseURL(in directory: URL) -> URL {
        directory.appendingPathComponent(Self.leaseFilename, isDirectory: false)
    }

    private func writeLease(in directory: URL, generation: UUID, now: Date) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let lease = ClaimLease(owner: ownerID, generation: generation, refreshedAt: now)
        guard let data = try? encoder.encode(lease) else {
            throw InboxError.filesystemFailure
        }
        do {
            // Another process must be able to read this marker whenever it is
            // awake, and it holds no user content — so the payload's complete
            // protection would only turn a locked device into a false takeover.
            try data.write(
                to: leaseURL(in: directory),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        } catch {
            throw InboxError.filesystemFailure
        }
    }

    private func leaseState(in directory: URL, fallbackDate: Date) -> LeaseState {
        let url = leaseURL(in: directory)
        guard fileManager.fileExists(atPath: url.path) else { return .absent }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let data = fileManager.contents(atPath: url.path),
              let lease = try? decoder.decode(ClaimLease.self, from: data) else {
            // Unreadable bytes still prove someone claimed the directory. Age it
            // by the file instead so the horizon can still expire it.
            let modifiedAt = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            return .held(owner: nil, generation: nil, refreshedAt: modifiedAt ?? fallbackDate)
        }
        return .held(
            owner: lease.owner,
            generation: lease.generation,
            refreshedAt: lease.refreshedAt
        )
    }

    /// Best effort: a surviving marker is tolerated by claim validation and
    /// overwritten by the next claim, so failing here must not fail the caller.
    private func removeLease(in directory: URL) {
        try? fileManager.removeItem(at: leaseURL(in: directory))
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

        // The lease is this actor's own file, written before validation and never
        // declarable as a payload leaf. Any bytes a publisher smuggled under that
        // name were overwritten by the claim, so tolerating it here admits none.
        let allowedNames = relativePaths.union([Self.manifestFilename, Self.leaseFilename])
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
              value != leaseFilename,
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

    // MARK: - Publication transaction

    /// How one staged entry's bytes reach the staging directory.
    private enum StagedPayload {
        case inline(Data)
        /// Copied, never read into memory: the source may be a quarter-gigabyte
        /// file a Shortcut pointed at.
        case copiedFile(from: URL)
    }

    /// One entry and the bytes, if any, that must be in staging before the
    /// manifest can honestly describe it. The entry's own `byteCount` is what
    /// the caller believes; the published manifest carries what was staged.
    private struct StagedEntry {
        let entry: WorkCaptureEnvelope.Entry
        let payload: StagedPayload?
    }

    /// The one staging → validate → atomic-rename transaction behind every
    /// in-process publication, and the same one both share extensions publish
    /// through. An in-app or Shortcut capture therefore cannot be left half
    /// written by a shape this queue has never exercised.
    ///
    /// Caller-owned identity makes recovery idempotent. If the publisher was
    /// killed after its atomic move but before it cleared whatever guard armed
    /// it, a later retry observes the same capture rather than publishing a
    /// second project. An already-imported capture may no longer have either
    /// directory; replaying the same id is still safe because
    /// `WorkCaptureDrainer` persists envelope ids before acknowledge.
    private func publishCapture(
        id: UUID,
        createdAt: Date,
        note: String,
        source: WorkCaptureEnvelope.Source,
        staged: [StagedEntry]
    ) throws -> UUID {
        try ensureScaffold()
        let publisher = WorkCaptureDirectoryPublisher(
            inboxURL: baseURL,
            fileSystem: WorkCaptureFileManagerFileSystem(fileManager: fileManager)
        )
        // The capture id is caller-owned and replayable, so the staging name
        // carries a discriminator: two attempts at one capture must never share
        // a private directory.
        let stagingName = "\(id.uuidString)-\(UUID().uuidString)"
        let published = publisher.publishedURL(for: id)

        if fileManager.fileExists(atPath: published.path) || isClaimed(id) {
            return id
        }

        // Every byte limit is checked against the sources before one byte is
        // copied: a set that cannot become a capture must not first be
        // duplicated onto a disk the person may already be short of.
        try refuseOversizedSources(staged, id: id)

        var stagedDirectory: URL?
        var didPublish = false
        defer {
            // `commit` clears up after its own refusals; this covers the window
            // between opening the staging directory and reaching it.
            if !didPublish, let stagedDirectory { publisher.discard(stagedDirectory) }
        }
        do {
            let staging = try publisher.beginStaging(named: stagingName)
            stagedDirectory = staging
            let entries = try stagePayloads(staged, into: staging, publisher: publisher)
            let envelope = WorkCaptureEnvelope(
                id: id,
                createdAt: createdAt,
                note: note,
                source: source,
                entries: entries
            )
            try publisher.commit(envelope, staging: staging)
            didPublish = true
            postLocalChange()
            return id
        } catch let failure as WorkCaptureEnvelope.PublicationValidationFailure {
            // A refused envelope is the caller's contract violation, not a
            // transient fault, and must not be reported as one.
            throw failure
        } catch {
            // Another process may have won the same deterministic publication
            // between the existence check and atomic move. Its complete
            // directory is the durable result; the losing temp is discarded.
            if fileManager.fileExists(atPath: published.path) || isClaimed(id) {
                return id
            }
            throw InboxError.filesystemFailure
        }
    }

    /// Refuses a set no capture may carry, measured on the sources rather than
    /// trusted from the caller. `maximumEntryCount` belongs to the calling API,
    /// which refuses it before building anything at all.
    private func refuseOversizedSources(_ staged: [StagedEntry], id: UUID) throws {
        var totalBytes: Int64 = 0
        for item in staged {
            let byteCount: Int64
            switch item.payload {
            case .none:
                continue
            case .inline(let data):
                byteCount = Int64(data.count)
            case .copiedFile(let source):
                byteCount = try sourceByteCount(at: source)
            }
            guard byteCount <= WorkCaptureEnvelope.maximumFileBytes else {
                throw WorkCaptureEnvelope.PublicationValidationFailure.invalidFileEntry
            }
            totalBytes += byteCount
            guard totalBytes <= WorkCaptureEnvelope.maximumEnvelopeBytes else {
                throw InboxError.invalidEnvelope(id, .envelopeTooLarge)
            }
        }
    }

    /// Copies or writes every payload into `staging` and returns the entries the
    /// manifest will carry, each stamped with the size of the file that is
    /// actually there.
    ///
    /// The manifest has to describe the staged bytes exactly: the claim
    /// validator destroys a capture whose entry disagrees with its payload, so a
    /// file that changed under the copy fails here — where the person can retry
    /// — rather than silently at import.
    private func stagePayloads(
        _ staged: [StagedEntry],
        into staging: URL,
        publisher: WorkCaptureDirectoryPublisher
    ) throws -> [WorkCaptureEnvelope.Entry] {
        var entries: [WorkCaptureEnvelope.Entry] = []
        var totalBytes: Int64 = 0
        for item in staged {
            guard let payload = item.payload, let relativePath = item.entry.relativePath else {
                entries.append(item.entry)
                continue
            }
            let destination = staging.appendingPathComponent(relativePath, isDirectory: false)
            switch payload {
            case .inline(let data):
                try publisher.fileSystem.writeProtected(data, to: destination)
            case .copiedFile(let source):
                try copyPayload(from: source, to: destination)
            }
            let byteCount = try stagedByteCount(at: destination)
            guard byteCount <= WorkCaptureEnvelope.maximumFileBytes else {
                throw WorkCaptureEnvelope.PublicationValidationFailure.invalidFileEntry
            }
            totalBytes += byteCount
            guard totalBytes <= WorkCaptureEnvelope.maximumEnvelopeBytes else {
                throw WorkCaptureEnvelope.PublicationValidationFailure.invalidFileEntry
            }
            entries.append(WorkCaptureEnvelope.Entry(
                id: item.entry.id,
                kind: item.entry.kind,
                sequence: item.entry.sequence,
                relativePath: relativePath,
                text: item.entry.text,
                displayName: item.entry.displayName,
                mimeType: item.entry.mimeType,
                typeIdentifier: item.entry.typeIdentifier,
                byteCount: byteCount
            ))
        }
        return entries
    }

    /// Copies a caller's file into staging under this queue's own protection.
    /// A copy inherits the source's protection class, which for a file another
    /// app handed over is whatever that app chose — and the queue holds a copy
    /// of private content from here until the app has imported it.
    private func copyPayload(from source: URL, to destination: URL) throws {
        try withSecurityScope(source) {
            try fileManager.copyItem(at: source, to: destination)
        }
        #if os(iOS)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: destination.path
        )
        #endif
    }

    /// The size of a file a caller offered. A file that is not there — or is
    /// not a regular file — is a contract violation and not a transient fault:
    /// publishing the rest would silently drop something the person chose.
    private func sourceByteCount(at url: URL) throws -> Int64 {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try withSecurityScope(url) {
                try fileManager.attributesOfItem(atPath: url.path)
            }
        } catch {
            if Self.isMissingFileError(error) {
                throw WorkCaptureEnvelope.PublicationValidationFailure.invalidFileEntry
            }
            throw InboxError.filesystemFailure
        }
        guard (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = attributes[.size] as? NSNumber else {
            throw WorkCaptureEnvelope.PublicationValidationFailure.invalidFileEntry
        }
        return size.int64Value
    }

    private func stagedByteCount(at url: URL) throws -> Int64 {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = attributes[.size] as? NSNumber else {
            throw InboxError.filesystemFailure
        }
        return size.int64Value
    }

    /// Reads a caller's file under its security scope. A Shortcut hands over a
    /// URL the app may only touch while the scope is held, and a local file that
    /// needs no scope answers false and is read exactly the same way.
    private func withSecurityScope<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    /// Three digits of sequence, so a capture's payload leaves sort the way its
    /// entries do. Bounded by `maximumEntryCount`, so the width always holds.
    private nonisolated static func paddedSequence(_ sequence: Int) -> String {
        let digits = String(sequence)
        guard digits.count < 3 else { return digits }
        return String(repeating: "0", count: 3 - digits.count) + digits
    }

    // MARK: - Filesystem helpers

    private func requireActive(_ claim: Claim) throws {
        guard activeClaims[claim.generation] == claim.token,
              claim.directoryURL.deletingLastPathComponent().standardizedFileURL == processingURL.standardizedFileURL,
              Self.claimDirectory(named: claim.directoryURL.lastPathComponent)?.generation == claim.generation else {
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
    /// this narrow rollback instead of the public `release` API. It moves only a
    /// directory this acquisition still owns: `claimed` is generation-scoped, so
    /// no other process can occupy it, and a foreign lease inside it is refused
    /// rather than requeued.
    private func preserveClaimedDirectory(id: UUID, at claimed: URL, generation: UUID) throws {
        let destination = baseURL.appendingPathComponent(id.uuidString, isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path),
              isOwnedForRollback(claimed, generation: generation) else {
            throw InboxError.filesystemFailure
        }
        removeLease(in: claimed)
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
