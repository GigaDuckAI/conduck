// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardUploadJournal.swift
//
// Crash recovery for the small window between a Work dispatch uploading bytes
// to the user's own file lane and atomically binding those keys to the new
// conversation. Each key is journaled before PUT. On a later launch Conduck
// keeps keys already referenced by the intended conversation, waits for any
// surviving background PUT, and deletes only unbound keys from the exact same
// durable lane. No credential, URL, prompt, or file bytes are stored. The
// operational server key necessarily contains the WebDAV-safe filename segment
// already shown to the destination gateway, so journal files use iOS data
// protection at rest and expire through reconciliation.

#if !os(watchOS)
import Foundation

nonisolated struct WorkboardPendingUpload: Codable, Sendable, Equatable, Identifiable {
    nonisolated static let currentVersion = 1

    struct Upload: Codable, Sendable, Equatable {
        let storedKey: String
        let sequence: Int
    }

    let version: Int
    let id: UUID
    let conversationID: UUID
    let gatewayRef: String
    let durableLaneID: String
    let createdAt: Date
    var uploads: [Upload]

    nonisolated init(
        version: Int = Self.currentVersion,
        id: UUID,
        conversationID: UUID,
        gatewayRef: String,
        durableLaneID: String,
        createdAt: Date = Date(),
        uploads: [Upload] = []
    ) {
        self.version = version
        self.id = id
        self.conversationID = conversationID
        self.gatewayRef = gatewayRef
        self.durableLaneID = durableLaneID
        self.createdAt = createdAt
        self.uploads = uploads
    }
}

actor WorkboardUploadJournal {
    static let shared = WorkboardUploadJournal()

    enum JournalError: Error, Equatable, Sendable {
        case invalidEntry
        case identityCollision
        case persistenceFailed
    }

    private let baseURL: URL
    private let fileManager: FileManager
    /// Dispatches in this process are skipped by a launch reconciliation that
    /// happens to overlap the user pressing Send.
    private var activeDispatchIDs: Set<UUID> = []

    private init() {
        self.baseURL = Self.defaultBaseURL()
        self.fileManager = .default
    }

    init(baseURL: URL, fileManager: FileManager = .default) {
        self.baseURL = baseURL
        self.fileManager = fileManager
    }

    func beginActivity(dispatchID: UUID) {
        activeDispatchIDs.insert(dispatchID)
    }

    func endActivity(dispatchID: UUID) {
        activeDispatchIDs.remove(dispatchID)
    }

    /// Persist ownership before network I/O. A failure is intentionally fatal
    /// to the dispatch: uploading without a recovery record would recreate the
    /// orphan window this journal exists to close.
    func register(
        dispatchID: UUID,
        conversationID: UUID,
        gatewayRef: String,
        durableLaneID: String,
        storedKey: String,
        sequence: Int
    ) throws {
        guard Self.isOwnedStoredKey(storedKey, conversationID: conversationID),
              sequence >= 0,
              !durableLaneID.isEmpty else {
            throw JournalError.invalidEntry
        }
        try scaffold()

        var entry: WorkboardPendingUpload
        let url = entryURL(for: dispatchID)
        if fileManager.fileExists(atPath: url.path) {
            entry = try readEntry(at: url)
            guard entry.id == dispatchID,
                  entry.conversationID == conversationID,
                  entry.gatewayRef == gatewayRef,
                  entry.durableLaneID == durableLaneID else {
                throw JournalError.identityCollision
            }
        } else {
            entry = WorkboardPendingUpload(
                id: dispatchID,
                conversationID: conversationID,
                gatewayRef: gatewayRef,
                durableLaneID: durableLaneID
            )
        }

        let upload = WorkboardPendingUpload.Upload(storedKey: storedKey, sequence: sequence)
        if !entry.uploads.contains(upload) {
            guard !entry.uploads.contains(where: {
                $0.sequence == sequence || $0.storedKey == storedKey
            }) else {
                throw JournalError.identityCollision
            }
            entry.uploads.append(upload)
            entry.uploads.sort {
                $0.sequence == $1.sequence
                    ? $0.storedKey < $1.storedKey
                    : $0.sequence < $1.sequence
            }
            try write(entry, to: url)
        }
    }

    /// Removes one key only after a definite 2xx/404 cleanup result. A network
    /// failure leaves it journaled for a later launch.
    func acknowledgeReclaimed(dispatchID: UUID, storedKey: String) {
        let url = entryURL(for: dispatchID)
        guard var entry = try? readEntry(at: url) else { return }
        entry.uploads.removeAll { $0.storedKey == storedKey }
        if entry.uploads.isEmpty {
            try? fileManager.removeItem(at: url)
        } else {
            try? write(entry, to: url)
        }
    }

    /// Core Data has atomically bound every uploaded key to the user turn. The
    /// journal is no longer authoritative and can be discarded.
    func finish(dispatchID: UUID) {
        activeDispatchIDs.remove(dispatchID)
        try? fileManager.removeItem(at: entryURL(for: dispatchID))
    }

    func pendingEntries() -> [WorkboardPendingUpload] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { try? readEntry(at: $0) }
            .sorted {
                $0.createdAt == $1.createdAt
                    ? $0.id.uuidString < $1.id.uuidString
                    : $0.createdAt < $1.createdAt
            }
    }

    /// Launch-time repair. It never guesses a destination: an unavailable,
    /// deleted, or repointed gateway keeps its tiny metadata record until the
    /// exact durable lane is available again.
    func reconcile(
        store: ConversationStore = .shared,
        settings: SettingsManager = .shared
    ) async {
        let entries = pendingEntries()
        for entry in entries {
            guard !activeDispatchIDs.contains(entry.id) else { continue }

            let referencedKeys: Set<String>
            do {
                referencedKeys = try await store.referencedStoredKeys(
                    Set(entry.uploads.map(\.storedKey))
                )
            } catch {
                // Store availability is the authority that separates live from
                // orphaned data. If it cannot answer, delete nothing.
                continue
            }

            for upload in entry.uploads where referencedKeys.contains(upload.storedKey) {
                acknowledgeReclaimed(dispatchID: entry.id, storedKey: upload.storedKey)
            }

            guard !activeDispatchIDs.contains(entry.id),
                  let ref = await MainActor.run(body: {
                      RemoteAgentRef(rawString: entry.gatewayRef)
                  }),
                  let snapshot = await settings.fileTransferSnapshot(for: ref),
                  snapshot.durableLaneID == entry.durableLaneID else {
                continue
            }

            let remaining = pendingEntries().first(where: { $0.id == entry.id })?.uploads ?? []
            for upload in remaining {
                guard !activeDispatchIDs.contains(entry.id) else { break }
                let live = await BackgroundFileTransfer.shared.hasLiveUploadTask(
                    shareEnvelopeID: entry.id,
                    sequence: upload.sequence
                )
                guard !live else { continue }
                let reclaimed = await BackgroundFileTransfer.shared.deleteFileForRecovery(
                    snapshot: snapshot,
                    storedKey: upload.storedKey
                )
                if reclaimed {
                    acknowledgeReclaimed(dispatchID: entry.id, storedKey: upload.storedKey)
                }
            }
        }
    }

    // MARK: - Persistence

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
            preconditionFailure("WorkboardUploadJournal requires durable Application Support storage")
        }
        return support.appendingPathComponent("WorkboardUploadJournal", isDirectory: true)
    }

    private func scaffold() throws {
        do {
            try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        } catch {
            throw JournalError.persistenceFailed
        }
    }

    private func entryURL(for id: UUID) -> URL {
        baseURL.appendingPathComponent(id.uuidString.lowercased() + ".json", isDirectory: false)
    }

    private func readEntry(at url: URL) throws -> WorkboardPendingUpload {
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let entry = try decoder.decode(WorkboardPendingUpload.self, from: data)
            guard entry.version == WorkboardPendingUpload.currentVersion,
                  url.deletingPathExtension().lastPathComponent == entry.id.uuidString.lowercased(),
                  Self.isValidGatewayRefString(entry.gatewayRef),
                  !entry.durableLaneID.isEmpty,
                  !entry.uploads.isEmpty,
                  Set(entry.uploads.map(\.sequence)).count == entry.uploads.count,
                  Set(entry.uploads.map(\.storedKey)).count == entry.uploads.count,
                  entry.uploads.allSatisfy({
                      $0.sequence >= 0
                          && Self.isOwnedStoredKey($0.storedKey, conversationID: entry.conversationID)
                  }) else {
                throw JournalError.invalidEntry
            }
            return entry
        } catch let error as JournalError {
            throw error
        } catch {
            throw JournalError.invalidEntry
        }
    }

    private func write(_ entry: WorkboardPendingUpload, to url: URL) throws {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            #if os(iOS)
            try encoder.encode(entry).write(
                to: url,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            #else
            try encoder.encode(entry).write(to: url, options: [.atomic])
            #endif
        } catch {
            throw JournalError.persistenceFailed
        }
    }

    /// DELETE is destructive even on a user-owned server, so a disk journal is
    /// not trusted merely because it lives in the App Group. Workboard keys have
    /// one narrow mint shape: `[conversation UUID/]8-lower-hex__safe-leaf`.
    nonisolated static func isOwnedStoredKey(_ key: String, conversationID: UUID) -> Bool {
        guard !key.isEmpty, key.utf8.count <= 520 else { return false }
        let components = key.split(separator: "/", omittingEmptySubsequences: false)
        let leaf: Substring
        switch components.count {
        case 1:
            leaf = components[0]
        case 2:
            guard components[0] == Substring(conversationID.uuidString) else { return false }
            leaf = components[1]
        default:
            return false
        }
        guard leaf.count > 10,
              leaf.index(leaf.startIndex, offsetBy: 8) < leaf.endIndex else { return false }
        let prefix = leaf.prefix(8)
        let separatorStart = leaf.index(leaf.startIndex, offsetBy: 8)
        let separatorEnd = leaf.index(separatorStart, offsetBy: 2, limitedBy: leaf.endIndex)
        let hexadecimal = Set("0123456789abcdef")
        guard let separatorEnd,
              leaf[separatorStart..<separatorEnd] == "__",
              prefix.allSatisfy(hexadecimal.contains) else {
            return false
        }
        let name = leaf[separatorEnd...]
        return !name.isEmpty
            && name.count <= FileServerClient.storedKeyComponentMaxCharacters - 10
            && name.allSatisfy { FileServerClient.storedKeySafeCharacters.contains($0) }
    }

    private nonisolated static func isValidGatewayRefString(_ raw: String) -> Bool {
        if raw == "openclaw" || raw == "hermes" { return true }
        guard raw.hasPrefix("custom_") else { return false }
        return UUID(uuidString: String(raw.dropFirst("custom_".count))) != nil
    }
}
#endif
