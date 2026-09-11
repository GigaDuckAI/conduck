// SPDX-License-Identifier: Apache-2.0

// Conduck — iOS Share Extension
// WorkCaptureDirectoryPublisher.swift
//
// Verbatim cross-process mirror of the main app's WorkCaptureDirectoryPublisher.
// The extension is deliberately self-contained; keep the declarations
// byte-identical to the main-app and macOS-extension copies from `import
// Foundation` onward.

import Foundation

/// The filesystem a publication transaction needs. It is a seam rather than a
/// direct `FileManager` call so the transaction's failure paths — a staged
/// write that cannot land, a destination already taken — are reachable from a
/// test. Without one, the only available check is that a caller's source
/// mentions the right calls in the right order, which dead code satisfies and
/// an honest refactor breaks.
protocol WorkCaptureFileSystem: Sendable {
    nonisolated func createDirectory(at url: URL) throws
    nonisolated func writeProtected(_ data: Data, to url: URL) throws
    nonisolated func moveItem(at source: URL, to destination: URL) throws
    nonisolated func removeItem(at url: URL) throws
}

/// The production filesystem. Everything a capture stages is written with
/// complete protection: the queue holds a copy of private user content from the
/// moment an extension writes it until the app has imported it.
nonisolated struct WorkCaptureFileManagerFileSystem: WorkCaptureFileSystem, @unchecked Sendable {
    /// `FileManager`'s file operations are safe to call from several threads,
    /// and this wrapper adds no mutable state of its own.
    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func createDirectory(at url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func writeProtected(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try fileManager.moveItem(at: source, to: destination)
    }

    func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }
}

/// Stages a capture privately, then publishes it with ONE atomic rename. The
/// caller opens a staging directory, fills it with payload bytes, and hands the
/// finished envelope to `commit`, which validates it, writes `manifest.json`
/// and renames the whole directory into the queue.
///
/// The rename is the only externally visible mutation and it happens last, so a
/// process killed at any earlier point leaves nothing a drainer can read. Every
/// refusal inside `commit` removes the staged directory before it throws: those
/// bytes are a copy of the person's private content, and leaving them for a
/// later sweep widens the window in which a capture nobody received sits on
/// disk.
nonisolated struct WorkCaptureDirectoryPublisher {
    /// Refusals that belong to the transaction. Everything the envelope's own
    /// contract rejects surfaces as `WorkCaptureEnvelope.PublicationValidationFailure`.
    nonisolated enum Failure: Error, Equatable {
        /// The encoded manifest exceeds the wire bound. Separate from envelope
        /// validation because it is a property of the encoding rather than of
        /// any single value the person supplied.
        case manifestTooLarge
        /// Work is ONE desk, so no capture may name a destination. Refused here
        /// rather than trusted at each call site: a targeted envelope would
        /// reach a drainer that has no target to resolve it against.
        case envelopeNamesADestination
    }

    /// Restated rather than shared, because each extension compiles a mirror of
    /// this file and none of the rest of the queue's implementation.
    nonisolated static let manifestFilename = "manifest.json"
    /// Staging lives under the queue root so the publishing rename stays on one
    /// volume, which is what makes it atomic.
    nonisolated static let stagingDirectoryName = "tmp"

    let inboxURL: URL
    let fileSystem: WorkCaptureFileSystem

    init(
        inboxURL: URL,
        fileSystem: WorkCaptureFileSystem = WorkCaptureFileManagerFileSystem()
    ) {
        self.inboxURL = inboxURL
        self.fileSystem = fileSystem
    }

    /// `name` is the caller's, because uniqueness is the caller's concern: a
    /// share mints a fresh capture id per publication, while a caller-owned,
    /// replayable id needs a discriminator so two attempts at one capture
    /// cannot stage into the same directory.
    func stagingURL(named name: String) -> URL {
        inboxURL
            .appendingPathComponent(Self.stagingDirectoryName, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    func publishedURL(for id: UUID) -> URL {
        inboxURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    @discardableResult
    func beginStaging(named name: String) throws -> URL {
        let staging = stagingURL(named: name)
        try fileSystem.createDirectory(at: staging)
        return staging
    }

    /// Publishes `staging` as `envelope.id`. Throws without publishing — and
    /// without leaving the staged bytes behind — when the envelope is refused,
    /// the manifest cannot be written, or the destination is already taken.
    @discardableResult
    func commit(_ envelope: WorkCaptureEnvelope, staging: URL) throws -> URL {
        do {
            guard envelope.targetWorkItemID == nil else {
                throw Failure.envelopeNamesADestination
            }
            try envelope.validateForPublication()
            let manifest = try envelope.encoded()
            guard manifest.count <= WorkCaptureEnvelope.maximumManifestBytes else {
                throw Failure.manifestTooLarge
            }
            try fileSystem.writeProtected(
                manifest,
                to: staging.appendingPathComponent(Self.manifestFilename, isDirectory: false)
            )
            let published = publishedURL(for: envelope.id)
            try fileSystem.moveItem(at: staging, to: published)
            return published
        } catch {
            discard(staging)
            throw error
        }
    }

    /// Best effort: a staging directory that outlives its transaction is swept
    /// by reconciliation, so failing to remove it must never fail the caller.
    func discard(_ staging: URL) {
        try? fileSystem.removeItem(at: staging)
    }
}
