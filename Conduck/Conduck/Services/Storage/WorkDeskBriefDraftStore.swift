// SPDX-License-Identifier: Apache-2.0

// Device-local request recovery, deliberately outside the synced project and
// conversation stores. Only task text, a gateway reference, selection identity
// and disclosure preference persist: no credentials, packet, files or replies.
// Atomic per-project writes compare each window's last loaded revision. Stale
// windows preserve their text and resolve conflicts explicitly. Only actual
// project deletion/reset clears all sessions; sync absence deletes nothing.

#if !os(watchOS)
import Foundation

struct WorkDeskBriefDraftRecord: Codable, Equatable {
    var version = 1
    /// A fresh revision distinguishes a recreated request with identical text.
    var revision: UUID?
    /// Written before dispatch; a failed retirement never restores as unsent.
    var pendingConversationID: UUID?
    var task: String
    var gatewayRef: String?
    var excludedIDs: Set<UUID>
    var selectedMaterialIDs: Set<UUID>?
    var selectedCompanionIDs: [UUID: UUID]
    var additionalMaterialIDs: Set<UUID>
    var knownProjectResultIDs: Set<UUID>
    var materialsExpanded: Bool?
}

@MainActor protocol WorkDeskBriefDraftStorage {
    func read(projectID: UUID) throws -> Data?
    func write(_ data: Data, projectID: UUID) throws
    func remove(projectID: UUID) throws
    func eraseAll() throws
}

@MainActor final class WorkDeskBriefDraftStore {
    enum Failure: Error { case invalidated, unsupportedVersion }

    struct Conflict: Error, Equatable {
        let current: WorkDeskBriefDraftRecord?
        fileprivate let currentData: Data?
        var canReplace: Bool { current?.pendingConversationID == nil }
    }

    static let shared: WorkDeskBriefDraftStore = {
        #if CONDUCK_TESTING
        return WorkDeskBriefDraftStore(storage: InMemoryWorkDeskBriefDraftStorage())
        #else
        precondition(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
                     "Tests must use Debug-Testing and an isolated draft store")
        return WorkDeskBriefDraftStore(storage: WorkDeskBriefDraftFileStorage.live())
        #endif
    }()

    final class Session {
        let projectID: UUID
        private(set) var isInvalidated = false
        var onInvalidated: (() -> Void)?
        fileprivate var baselineData: Data?
        fileprivate var baselineRecord: WorkDeskBriefDraftRecord?
        fileprivate var unreadableData: Data?
        fileprivate var isRetired = false
        init(projectID: UUID) { self.projectID = projectID }
        fileprivate func invalidate() {
            isInvalidated = true
            onInvalidated?()
        }
    }

    private final class WeakSession {
        weak var value: Session?
        init(_ value: Session) { self.value = value }
    }

    private let storage: any WorkDeskBriefDraftStorage
    private var sessions: [WeakSession] = []
    private var deletedProjectIDs: Set<UUID> = []

    init(storage: any WorkDeskBriefDraftStorage) { self.storage = storage }

    func session(projectID: UUID) -> Session {
        let session = Session(projectID: projectID)
        sessions.removeAll { $0.value == nil }
        sessions.append(WeakSession(session))
        if deletedProjectIDs.contains(projectID) { session.invalidate() }
        return session
    }

    func load(_ session: Session, resolving conflict: Conflict? = nil) throws -> WorkDeskBriefDraftRecord? {
        guard !session.isInvalidated else { throw Failure.invalidated }
        let data = try storage.read(projectID: session.projectID)
        let current: Conflict
        do { current = try snapshot(data: data) }
        catch {
            // Only an explicit discard may target bytes that failed decoding.
            // Failed reload must not advance the baseline of a writable editor.
            session.unreadableData = data
            throw error
        }
        if let conflict, current.currentData != conflict.currentData { throw current }
        session.baselineData = data
        session.baselineRecord = current.current
        session.unreadableData = nil
        session.isRetired = false
        return current.current
    }

    func save(_ record: WorkDeskBriefDraftRecord, session: Session) throws {
        guard !session.isInvalidated else { throw Failure.invalidated }
        // A stale window being hidden must not write its unchanged old request.
        // Comparing values also avoids a filesystem write on every Close.
        let current = try snapshot(projectID: session.projectID)
        guard !session.isRetired, current.currentData == session.baselineData else { throw current }
        if record == session.baselineRecord { return }
        try write(record, session: session)
    }

    /// Explicit replacement is tied to the version the person actually saw.
    /// Another edit during the decision refreshes the conflict instead of
    /// overwriting unseen text. An in-flight request cannot be replaced.
    func replace(_ record: WorkDeskBriefDraftRecord, session: Session, conflict: Conflict) throws {
        guard !session.isInvalidated else { throw Failure.invalidated }
        let current = try snapshot(projectID: session.projectID)
        guard current.currentData == conflict.currentData, current.canReplace else { throw current }
        try write(record, session: session)
    }

    /// Request retirement never clears another window's independent text. That
    /// window discovers the changed revision when it next saves and can choose
    /// whether to keep its own request or load the current saved one.
    func clear(_ session: Session, preservingNewerRequest: Bool = false) throws {
        guard !session.isInvalidated, !session.isRetired else { return }
        let currentData = try storage.read(projectID: session.projectID)
        guard currentData == session.baselineData || (session.unreadableData != nil && currentData == session.unreadableData) else {
            if preservingNewerRequest {
                session.isRetired = true
                return
            }
            throw try snapshot(data: currentData)
        }
        try storage.remove(projectID: session.projectID)
        session.isRetired = true
    }

    private func snapshot(projectID: UUID) throws -> Conflict {
        try snapshot(data: storage.read(projectID: projectID))
    }

    private func snapshot(data: Data?) throws -> Conflict {
        guard let data else {
            return Conflict(current: nil, currentData: nil)
        }
        var record = try JSONDecoder().decode(WorkDeskBriefDraftRecord.self, from: data)
        guard record.version == 1 else { throw Failure.unsupportedVersion }
        record.revision = nil
        return Conflict(current: record, currentData: data)
    }

    private func write(_ record: WorkDeskBriefDraftRecord, session: Session) throws {
        var stored = record
        stored.revision = UUID()
        let data = try JSONEncoder().encode(stored)
        try storage.write(data, projectID: session.projectID)
        session.baselineData = data
        session.baselineRecord = record
        session.isRetired = false
    }

    /// Tombstones are durable deletion evidence. Retry this on later snapshots
    /// if storage refuses cleanup; every existing session is blocked immediately.
    func deleteProjects(_ ids: Set<UUID>) throws {
        deletedProjectIDs.formUnion(ids)
        invalidate(projectIDs: ids)
        for id in ids { try storage.remove(projectID: id) }
    }

    /// For an explicit app-data reset, separate from Delete all conversations,
    /// which intentionally preserves the entire Work desk.
    func eraseAll() throws {
        try storage.eraseAll()
        for session in sessions.compactMap(\.value) { session.invalidate() }
        sessions.removeAll()
    }

    private func invalidate(projectIDs: Set<UUID>) {
        for session in sessions.compactMap(\.value) where projectIDs.contains(session.projectID) {
            session.invalidate()
        }
    }
}

@MainActor final class InMemoryWorkDeskBriefDraftStorage: WorkDeskBriefDraftStorage {
    var records: [UUID: Data] = [:]
    func read(projectID: UUID) throws -> Data? { records[projectID] }
    func write(_ data: Data, projectID: UUID) throws { records[projectID] = data }
    func remove(projectID: UUID) throws { records.removeValue(forKey: projectID) }
    func eraseAll() throws { records.removeAll() }
}

/// Explicit-directory adapter also exercises disk recovery in isolated tests.
/// Live directory lookup lives in LiveStorage.swift, behind the test boundary.
@MainActor final class WorkDeskBriefDraftFileStorage: WorkDeskBriefDraftStorage {
    let directory: URL
    init(directory: URL) { self.directory = directory }

    func read(projectID: UUID) throws -> Data? {
        do { return try Data(contentsOf: location(projectID)) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        }
    }

    func write(_ data: Data, projectID: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var localDirectory = directory
        var attributes = URLResourceValues()
        attributes.isExcludedFromBackup = true
        try localDirectory.setResourceValues(attributes)
        #if os(iOS)
        try data.write(to: location(projectID), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: location(projectID), options: .atomic)
        #endif
    }

    func remove(projectID: UUID) throws { try removeIfPresent(location(projectID)) }
    func eraseAll() throws { try removeIfPresent(directory) }

    private func location(_ projectID: UUID) -> URL {
        directory.appendingPathComponent(projectID.uuidString).appendingPathExtension("json")
    }

    private func removeIfPresent(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError { }
    }
}
#endif
