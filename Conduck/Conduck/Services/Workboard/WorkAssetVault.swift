// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkAssetVault.swift
//
// Device-local storage for Workboard file bytes. The private CloudKit database
// syncs the brief and material metadata, while the database stores only an
// opaque local leaf key for each payload. Another device never sees a fake
// attachment and dispatch stays blocked until the user explicitly reattaches it.

#if !os(watchOS)
import Foundation

actor WorkAssetVault {
    static let shared = WorkAssetVault()

    struct StoredFile: Sendable, Equatable {
        let key: String
        let byteCount: Int64
    }

    /// Workboard file bytes are intentionally device-local. A zero ceiling keeps
    /// even modest screenshots/documents out of the shared Conversations model,
    /// which is also mirrored by Watch for chat continuity. Brief metadata still
    /// syncs; another device presents an honest reattach state. This is a device-
    /// budget and privacy boundary, not a claimed CloudKit limit.
    nonisolated static let mirroredPayloadCeilingBytes: Int64 = 0

    enum VaultError: Error, Equatable {
        case unsafeKey
        case missing
        case writeFailed
    }

    private let baseURL: URL
    private let fileManager: FileManager
    /// Keys written by this process whose database mutation has not committed
    /// yet. Reconciliation can run while `ConversationStore` is suspended on a
    /// vault write; protecting that small publication gap prevents a just-picked
    /// file from being mistaken for a crash orphan before its `WorkMaterial`
    /// row exists. Process death clears the set, which is exactly when the next
    /// launch should judge the database authoritative again.
    private var stagedKeys: Set<String> = []

    private init() {
        self.baseURL = Self.productionBaseURL
        self.fileManager = .default
    }

    init(baseURL: URL, fileManager: FileManager = .default) {
        self.baseURL = baseURL
        self.fileManager = fileManager
    }

    nonisolated static var productionBaseURL: URL {
        let root: URL
        if let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Constants.appGroupID
        ) {
            root = group.appendingPathComponent("Application Support", isDirectory: true)
        } else if let applicationSupport = try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
        ) {
            root = applicationSupport
        } else {
            // Silently degrading a durable private vault to tmp would turn a
            // force-quit or OS cleanup into user-visible data loss. No durable
            // container is a provisioning failure, so fail before accepting data.
            preconditionFailure("WorkAssetVault requires durable Application Support storage")
        }
        return root.appendingPathComponent("WorkboardAssets", isDirectory: true)
    }

    /// Store bytes under a generated opaque leaf. The caller persists the
    /// returned key; source/display filenames never become filesystem paths.
    func store(_ data: Data, id: UUID = UUID(), suggestedExtension: String? = nil) throws -> String {
        try scaffold()
        let key = Self.makeKey(id: id, suggestedExtension: suggestedExtension)
        let destination = try resolvedURL(for: key)
        do {
            #if os(iOS)
            try data.write(
                to: destination,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            #else
            try data.write(to: destination, options: [.atomic])
            #endif
            stagedKeys.insert(key)
            return key
        } catch {
            throw VaultError.writeFailed
        }
    }

    /// Stream/copy a picked file into the vault without loading an arbitrarily
    /// large payload into memory. The security scope is bracketed here.
    func storeFile(
        at sourceURL: URL,
        id: UUID = UUID(),
        suggestedExtension: String? = nil
    ) throws -> String {
        try scaffold()
        let key = Self.makeKey(
            id: id,
            suggestedExtension: suggestedExtension ?? sourceURL.pathExtension
        )
        let destination = try resolvedURL(for: key)
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
            #if os(iOS)
            try? fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path
            )
            #endif
            stagedKeys.insert(key)
            return key
        } catch {
            try? fileManager.removeItem(at: destination)
            throw VaultError.writeFailed
        }
    }

    /// Chunked, cancellable variant used by the Workboard file picker. Progress
    /// reports copied bytes rather than pretending a potentially multi-hundred-
    /// megabyte synchronous copy is an instant material mutation.
    func storeFileStreaming(
        at sourceURL: URL,
        id: UUID = UUID(),
        suggestedExtension: String? = nil,
        expectedByteCount: Int64,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> StoredFile {
        try scaffold()
        let key = Self.makeKey(
            id: id,
            suggestedExtension: suggestedExtension ?? sourceURL.pathExtension
        )
        let destination = try resolvedURL(for: key)
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

        do {
            guard fileManager.createFile(atPath: destination.path, contents: nil) else {
                throw VaultError.writeFailed
            }
            let input = try FileHandle(forReadingFrom: sourceURL)
            let output = try FileHandle(forWritingTo: destination)
            defer {
                try? input.close()
                try? output.close()
            }

            var copied: Int64 = 0
            while true {
                try Task.checkCancellation()
                guard let chunk = try input.read(upToCount: 1_024 * 1_024), !chunk.isEmpty else {
                    break
                }
                try output.write(contentsOf: chunk)
                copied += Int64(chunk.count)
                if expectedByteCount > 0 {
                    onProgress(min(1, Double(copied) / Double(expectedByteCount)))
                }
            }
            guard expectedByteCount < 0 || copied == expectedByteCount else {
                throw VaultError.writeFailed
            }
            try output.synchronize()
            #if os(iOS)
            try? fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path
            )
            #endif
            onProgress(1)
            stagedKeys.insert(key)
            return StoredFile(key: key, byteCount: copied)
        } catch is CancellationError {
            try? fileManager.removeItem(at: destination)
            throw CancellationError()
        } catch {
            try? fileManager.removeItem(at: destination)
            throw VaultError.writeFailed
        }
    }

    func data(for key: String) throws -> Data {
        let url = try resolvedURL(for: key)
        guard fileManager.fileExists(atPath: url.path) else { throw VaultError.missing }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    /// A stable local URL for app-internal snapshotting. Never hand this URL to
    /// an external opener, share sheet, or document editor; copy it first.
    func url(for key: String) throws -> URL {
        let url = try resolvedURL(for: key)
        guard fileManager.fileExists(atPath: url.path) else { throw VaultError.missing }
        return url
    }

    /// Copy a vault object to a stable per-dispatch temporary URL. Vault
    /// replacement/removal is serialized by this actor, so either this returns
    /// the exact old bytes or fails before any network work can start.
    func snapshotFile(for key: String, id: UUID = UUID()) throws -> URL {
        let source = try resolvedURL(for: key)
        guard fileManager.fileExists(atPath: source.path) else { throw VaultError.missing }
        let ext = WorkCaptureEnvelope.safePathExtension(source.pathExtension)
        let destination = fileManager.temporaryDirectory.appendingPathComponent(
            "conduck-workboard-dispatch-\(id.uuidString).\(ext)"
        )
        do {
            try fileManager.copyItem(at: source, to: destination)
            #if os(iOS)
            try? fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path
            )
            #endif
            return destination
        } catch {
            try? fileManager.removeItem(at: destination)
            throw VaultError.writeFailed
        }
    }

    func contains(_ key: String) -> Bool {
        guard let url = try? resolvedURL(for: key) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    func remove(_ key: String) throws {
        let url = try resolvedURL(for: key)
        stagedKeys.remove(key)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    /// Release the short in-process publication guard after the matching
    /// `WorkMaterial.localVaultKey` save has committed. A later reconciliation
    /// will still retain the file from the authoritative database key set.
    func markReferenced(_ key: String) {
        stagedKeys.remove(key)
    }

    /// Reclaim only valid vault leaves not named by the authoritative database.
    /// Invalid/foreign directory entries are left untouched and reported.
    func reclaimUnreferenced(keeping keys: Set<String>) -> Int {
        guard (try? scaffold()) != nil,
              let children = try? fileManager.contentsOfDirectory(
                at: baseURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else { return 0 }
        var removed = 0
        let protectedKeys = keys.union(stagedKeys)
        for child in children {
            let key = child.lastPathComponent
            guard Self.isSafeKey(key), !protectedKeys.contains(key) else { continue }
            let values = try? child.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            if (try? fileManager.removeItem(at: child)) != nil { removed += 1 }
        }
        return removed
    }

    nonisolated static func shouldMirror(byteCount: Int64) -> Bool {
        // Zero is a valid empty file, while negative values mean the source did
        // not report a size. Neither is evidence that it is safe to materialize
        // the URL in memory; both must take the streaming local-vault lane.
        byteCount > 0 && byteCount <= mirroredPayloadCeilingBytes
    }

    nonisolated static func makeKey(id: UUID, suggestedExtension: String?) -> String {
        let ext = WorkCaptureEnvelope.safePathExtension(suggestedExtension)
        return id.uuidString.lowercased() + "." + ext
    }

    nonisolated static func isSafeKey(_ key: String) -> Bool {
        guard key == (key as NSString).lastPathComponent,
              !key.contains("/"), !key.contains("\\"),
              let dot = key.lastIndex(of: "."),
              UUID(uuidString: String(key[..<dot])) != nil else { return false }
        return WorkCaptureEnvelope.safePathExtension(String(key[key.index(after: dot)...]))
            == String(key[key.index(after: dot)...]).lowercased()
    }

    private func scaffold() throws {
        do {
            try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
            #if os(iOS)
            try? fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: baseURL.path
            )
            #endif
        } catch {
            throw VaultError.writeFailed
        }
    }

    private func resolvedURL(for key: String) throws -> URL {
        guard Self.isSafeKey(key) else { throw VaultError.unsafeKey }
        return baseURL.appendingPathComponent(key, isDirectory: false)
    }
}
#endif
