// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkAssetVault.swift
//
// Device-local storage for the ONE lane of Work payloads that does not sync:
// `WorkMaterialStoragePolicy`'s `.localVault`, which is every payload above
// `Constants.workboardSyncCeilingBytes` and every one whose size cannot be
// measured. Bytes within the ceiling take the other lane — a `WorkMaterialBlob`
// row in the payload store, mirrored to the person's private CloudKit database,
// so they reach their other devices. A payload is written to exactly one lane;
// this vault never holds a second copy of a synced one.
//
// A vaulted material's Core Data row carries an opaque local leaf key and no
// bytes, so another device shows the card and reads it `unavailableOnThisDevice`
// until the person reattaches the file there — never a payload it cannot open.
// The ceiling is what keeps that boundary affordable: the Conversations model is
// mirrored to the Watch as well, so an unbounded payload would be a device-budget
// cost everywhere, which is the reason for the split rather than any claimed
// CloudKit record limit.
//
// Leaf keys are generated and opaque: a source or display filename never becomes
// a filesystem path.
//
// The vault lives in the App Group, so the app, the share extensions and the
// headless intent process all write it. A leaf therefore exists for a moment
// before ANY process can see the row that names it, and the database alone
// cannot tell that publication gap from a crash orphan. Reclamation closes the
// gap from both sides: a staging marker beside the leaf states the claim across
// processes, and no leaf younger than `stagingHorizon` is reclaimed even
// without one.

#if !os(watchOS)
import Foundation

actor WorkAssetVault {
    static let shared = WorkAssetVault()

    struct StoredFile: Sendable, Equatable {
        let key: String
        let byteCount: Int64
    }

    enum VaultError: Error, Equatable {
        case unsafeKey
        case missing
        case writeFailed
    }

    /// The on-disk staging claim written beside a leaf while its `WorkMaterial`
    /// row is being written. `owner` names one vault instance, so a marker this
    /// instance wrote for a key it is no longer staging is known residue and
    /// expires at once instead of waiting out the horizon.
    struct StagingClaim: Codable, Equatable, Sendable {
        let owner: UUID
        let stagedAt: Date
    }

    /// Suffix of the staging marker for a leaf. A marker name is deliberately
    /// NOT a valid vault key, so reclamation reads markers as claims and never
    /// as payload data, and no reader can reach one through `data(for:)`.
    nonisolated static let stagingMarkerSuffix = ".staging"

    /// A leaf younger than this — or covered by a marker no older than this — is
    /// never reclaimed. The cost is asymmetric: keeping a crash orphan for one
    /// more board load wastes bounded disk, while deleting a leaf another
    /// process staged seconds ago destroys a payload the person just captured.
    /// Chosen far above a real publication (one copy plus one Core Data save,
    /// seconds even at the 256 MB share cap) and low enough that residue does
    /// not outlive a session.
    nonisolated static let stagingHorizon: TimeInterval = 15 * 60

    private let baseURL: URL
    private let fileManager: FileManager
    /// Per-instance identity, minted in the stored-property initializer so both
    /// `init`s carry one. A relaunched process must not read its predecessor's
    /// marker as its own: the horizon is the only cross-process liveness signal
    /// a plain file can carry.
    nonisolated let instanceID = UUID()
    /// Keys written by this process whose database mutation has not committed
    /// yet. Reconciliation can run while `ConversationStore` is suspended on a
    /// vault write; protecting that small publication gap prevents a just-picked
    /// file from being mistaken for a crash orphan before its `WorkMaterial`
    /// row exists. Process death clears the set, which is why the marker and the
    /// horizon — not this set — are what protect a leaf staged elsewhere.
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
        beginStaging(key)
        do {
            #if os(iOS)
            try data.write(
                to: destination,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            #else
            try data.write(to: destination, options: [.atomic])
            #endif
            return key
        } catch {
            endStaging(key)
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
        beginStaging(key)
        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
            #if os(iOS)
            try? fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path
            )
            #endif
            return key
        } catch {
            try? fileManager.removeItem(at: destination)
            endStaging(key)
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
        beginStaging(key)

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
            return StoredFile(key: key, byteCount: copied)
        } catch is CancellationError {
            try? fileManager.removeItem(at: destination)
            endStaging(key)
            throw CancellationError()
        } catch {
            try? fileManager.removeItem(at: destination)
            endStaging(key)
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

    /// Resolve many leaves in a single hop. A board refresh needs a URL for every
    /// image material at once; asking key by key would queue that wave behind
    /// every other vault write for the whole pass. Missing and unsafe keys are
    /// simply absent from the result.
    func urls(for keys: [String]) -> [String: URL] {
        var resolved: [String: URL] = [:]
        resolved.reserveCapacity(keys.count)
        for key in keys where resolved[key] == nil {
            guard let url = try? resolvedURL(for: key),
                  fileManager.fileExists(atPath: url.path) else { continue }
            resolved[key] = url
        }
        return resolved
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

    /// Duplicate one vault object under a fresh opaque key at the filesystem
    /// level. Copying a card must never route a several-hundred-megabyte payload
    /// through `Data`, and each card owning its own leaf is what lets deleting
    /// one card reclaim its bytes without touching the other's.
    func copy(key: String, id: UUID = UUID()) throws -> StoredFile {
        let source = try resolvedURL(for: key)
        guard fileManager.fileExists(atPath: source.path) else { throw VaultError.missing }
        try scaffold()
        let destinationKey = Self.makeKey(id: id, suggestedExtension: source.pathExtension)
        let destination = try resolvedURL(for: destinationKey)
        beginStaging(destinationKey)
        do {
            try fileManager.copyItem(at: source, to: destination)
            #if os(iOS)
            try? fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path
            )
            #endif
            let byteCount = fileByteCount(at: destination) ?? 0
            return StoredFile(key: destinationKey, byteCount: byteCount)
        } catch {
            try? fileManager.removeItem(at: destination)
            endStaging(destinationKey)
            throw VaultError.writeFailed
        }
    }

    func contains(_ key: String) -> Bool {
        guard let url = try? resolvedURL(for: key) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    func remove(_ key: String) throws {
        let url = try resolvedURL(for: key)
        endStaging(key)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    /// Release the publication guard — the in-process staged key and the
    /// cross-process marker both — after the matching `WorkMaterial.localVaultKey`
    /// save has committed. A later reconciliation retains the file from the
    /// authoritative database key set instead.
    func markReferenced(_ key: String) {
        endStaging(key)
    }

    /// Prove a published leaf before its publication may be reported durable,
    /// then release the guard. A caller that has just saved a row naming `key`
    /// must not acknowledge the capture — or delete the source bytes it came
    /// from — when the leaf is missing or the wrong length, because the row
    /// would then promise a payload the vault cannot serve. A mismatch KEEPS the
    /// guard, so the failed publication cannot be followed by a reclamation pass
    /// deleting what is left of it.
    @discardableResult
    func confirmPublication(of key: String, expectedByteCount: Int64? = nil) -> Bool {
        guard let url = try? resolvedURL(for: key) else { return false }
        guard let byteCount = fileByteCount(at: url) else {
            // Nothing on disk left to protect; the caller learns the publication
            // is not durable from the returned false.
            endStaging(key)
            return false
        }
        if let expectedByteCount, expectedByteCount >= 0, byteCount != expectedByteCount {
            return false
        }
        endStaging(key)
        return true
    }

    /// Reclaim only valid vault leaves that neither the authoritative database
    /// nor a live staging claim names. Invalid/foreign directory entries are left
    /// untouched. `now` is injectable so a test can age past the horizon without
    /// sleeping; production always judges against the wall clock.
    func reclaimUnreferenced(keeping keys: Set<String>, now: Date = Date()) -> Int {
        guard (try? scaffold()) != nil,
              let children = try? fileManager.contentsOfDirectory(
                at: baseURL,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .creationDateKey, .contentModificationDateKey
                ],
                options: [.skipsHiddenFiles]
              ) else { return 0 }

        var leaves: [String: URL] = [:]
        var markers: [String: URL] = [:]
        for child in children {
            let name = child.lastPathComponent
            let values = try? child.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            // A safe key is payload first: `staging` is a legal path extension,
            // so classifying by suffix ahead of key shape would let a leaf named
            // `<uuid>.staging` be mistaken for a claim on nothing.
            if Self.isSafeKey(name) {
                leaves[name] = child
            } else if let staged = Self.stagedKey(forMarkerNamed: name) {
                markers[staged] = child
            }
        }

        var removed = 0
        let protectedKeys = keys.union(stagedKeys)
        for (key, url) in leaves where !protectedKeys.contains(key) {
            if let marker = markers[key],
               !isAbandonedStagingClaim(at: marker, now: now) { continue }
            guard isPastStagingHorizon(url, now: now) else { continue }
            guard (try? fileManager.removeItem(at: url)) != nil else { continue }
            removed += 1
            if let marker = markers.removeValue(forKey: key) {
                try? fileManager.removeItem(at: marker)
            }
        }
        // A marker whose leaf is absent names nothing yet — an atomic write
        // publishes its file only at the end — so it is swept solely once
        // abandoned, never merely because the payload has not appeared.
        for (key, marker) in markers {
            guard leaves[key] == nil, !protectedKeys.contains(key) else { continue }
            guard isAbandonedStagingClaim(at: marker, now: now) else { continue }
            try? fileManager.removeItem(at: marker)
        }
        return removed
    }

    nonisolated static func makeKey(id: UUID, suggestedExtension: String?) -> String {
        let ext = WorkCaptureEnvelope.safePathExtension(suggestedExtension)
        return id.uuidString.lowercased() + "." + ext
    }

    /// The leaf a marker name claims, or nil when the name is not a marker for a
    /// key this vault could have written.
    nonisolated static func stagedKey(forMarkerNamed name: String) -> String? {
        guard name.hasSuffix(stagingMarkerSuffix) else { return nil }
        let key = String(name.dropLast(stagingMarkerSuffix.count))
        return isSafeKey(key) ? key : nil
    }

    nonisolated static func isSafeKey(_ key: String) -> Bool {
        guard key == (key as NSString).lastPathComponent,
              !key.contains("/"), !key.contains("\\"),
              let dot = key.lastIndex(of: "."),
              UUID(uuidString: String(key[..<dot])) != nil else { return false }
        return WorkCaptureEnvelope.safePathExtension(String(key[key.index(after: dot)...]))
            == String(key[key.index(after: dot)...]).lowercased()
    }

    // MARK: - Publication guard

    /// Open the publication gap for `key`: the marker goes down BEFORE the bytes
    /// so another process can never observe a leaf that no claim covers.
    private func beginStaging(_ key: String) {
        stagedKeys.insert(key)
        writeStagingMarker(for: key)
    }

    private func endStaging(_ key: String) {
        stagedKeys.remove(key)
        removeStagingMarker(for: key)
    }

    private func stagingMarkerURL(for key: String) -> URL? {
        guard Self.isSafeKey(key) else { return nil }
        return baseURL.appendingPathComponent(key + Self.stagingMarkerSuffix, isDirectory: false)
    }

    /// Best effort by design: `stagingHorizon` still covers the publication gap
    /// without a marker, so a marker that cannot be written must never fail a
    /// capture the person just made.
    private func writeStagingMarker(for key: String) {
        guard let url = stagingMarkerURL(for: key) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(
            StagingClaim(owner: instanceID, stagedAt: Date())
        ) else { return }
        #if os(iOS)
        // Any awake process must be able to read this marker to see that the
        // leaf is claimed, and it carries no user content — the payloads'
        // stronger protection would only turn a locked device into a false
        // orphan and license deleting live bytes.
        try? data.write(
            to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        #else
        try? data.write(to: url, options: [.atomic])
        #endif
    }

    private func removeStagingMarker(for key: String) {
        guard let url = stagingMarkerURL(for: key) else { return }
        try? fileManager.removeItem(at: url)
    }

    /// A claim is abandoned when this instance wrote it for a key it is no
    /// longer staging (the publication it covered has ended, and marker removal
    /// merely failed) or when it predates the horizon. A claim dated in the
    /// future is respected until the clock catches up: skew must never license
    /// deleting a payload mid-publication.
    private func isAbandonedStagingClaim(at url: URL, now: Date) -> Bool {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let claim = fileManager.contents(atPath: url.path).flatMap {
            try? decoder.decode(StagingClaim.self, from: $0)
        }
        if let claim, claim.owner == instanceID { return true }
        var stagedAt = claim?.stagedAt
        if stagedAt == nil {
            // Unreadable bytes still prove someone claimed the leaf; age the
            // claim by its file so the horizon can expire it anyway.
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            stagedAt = attributes?[.modificationDate] as? Date
        }
        guard let stagedAt else { return false }
        return now.timeIntervalSince(stagedAt) >= Self.stagingHorizon
    }

    /// Whether a leaf is old enough to be judged by the database alone. A file
    /// still being streamed keeps advancing its modification date, so the newest
    /// of the two timestamps is what a long copy is measured by. A leaf whose age
    /// cannot be read is never reclaimed: the vault refuses to delete what it
    /// cannot reason about.
    private func isPastStagingHorizon(_ url: URL, now: Date) -> Bool {
        let values = try? url.resourceValues(
            forKeys: [.creationDateKey, .contentModificationDateKey]
        )
        let stamps = [values?.creationDate, values?.contentModificationDate].compactMap { $0 }
        guard let newest = stamps.max() else { return false }
        return now.timeIntervalSince(newest) >= Self.stagingHorizon
    }

    private func fileByteCount(at url: URL) -> Int64? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.int64Value
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
