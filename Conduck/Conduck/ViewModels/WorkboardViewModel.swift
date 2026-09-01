// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardViewModel.swift
//
// Presentation boundary for the private desk. Work is ONE desk at a
// compile-time id, so this model holds a single board and loads nothing else:
// a project row written by a build that predates the desk stays in the store
// and never reaches a screen. The UI deliberately depends on immutable
// snapshots and injected async operations instead of Core Data objects, so the
// persistence layer can evolve its schema without leaking managed-object
// lifetimes into SwiftUI. Nothing here leaves the device: every operation this
// model can perform writes to the person's own private store.

import Foundation
import SwiftUI

// MARK: - Presentation snapshots

enum WorkboardMaterialKind: String, CaseIterable, Codable, Hashable, Sendable {
    case image
    case file
    case link
    case note

    var title: LocalizedStringResource {
        switch self {
        case .image:
            return LocalizedStringResource("workboard.material.image", defaultValue: "Image")
        case .file:
            return LocalizedStringResource("workboard.material.file", defaultValue: "File")
        case .link:
            return LocalizedStringResource("workboard.material.link", defaultValue: "Link")
        case .note:
            return LocalizedStringResource("workboard.material.note", defaultValue: "Note")
        }
    }

    var systemImage: String {
        switch self {
        case .image: return "photo"
        case .file: return "doc"
        case .link: return "link"
        case .note: return "note.text"
        }
    }

}

/// Device-relative payload truth. Local-only files intentionally remain visible
/// on other devices as provenance, but they cannot be opened there until their
/// bytes are reattached. `syncPending` is the other unreadable state and is a
/// different thing to ask of the person: the bytes ride private CloudKit and
/// have not landed here yet, so the card waits rather than asking to be
/// repaired. Both are unreadable, so both fail closed — `isAvailable` names
/// the readable cases so a state added later cannot fail open by omission.
enum WorkboardMaterialAvailability: String, Codable, Hashable, Sendable {
    case available
    case localOnly
    case syncPending
    case unavailableOnThisDevice

    var isAvailable: Bool { self == .available || self == .localOnly }
}

struct WorkboardMaterialSnapshot: Identifiable, Hashable, Sendable {
    let id: UUID
    var kind: WorkboardMaterialKind
    var name: String
    var detail: String?
    var textContent: String?
    var urlString: String?
    var mimeType: String?
    var thumbnailData: Data?
    var byteCount: Int64?
    var availability: WorkboardMaterialAvailability
    var sequence: Int
    /// Presentation-only board footprint. It is deliberately absent from
    /// `WorkboardEditDraft.contentFingerprint` and from every prompt packet:
    /// resizing a card must never advance the owner revision, trip the
    /// card's own content revision.
    var cardSize: WorkMaterialCardSize
    var createdAt: Date
    var revision: Int64

    init(
        id: UUID = UUID(),
        kind: WorkboardMaterialKind,
        name: String,
        detail: String? = nil,
        textContent: String? = nil,
        urlString: String? = nil,
        mimeType: String? = nil,
        thumbnailData: Data? = nil,
        byteCount: Int64? = nil,
        availability: WorkboardMaterialAvailability = .available,
        sequence: Int = 0,
        cardSize: WorkMaterialCardSize = .standard,
        createdAt: Date = Date(),
        revision: Int64 = 0
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.detail = detail
        self.textContent = textContent
        self.urlString = urlString
        self.mimeType = mimeType
        self.thumbnailData = thumbnailData
        self.byteCount = byteCount
        self.availability = availability
        self.sequence = sequence
        self.cardSize = cardSize
        self.createdAt = createdAt
        self.revision = revision
    }
}

/// The desk as the board reads it: the material it holds, in the order the
/// person arranged it, plus the revision every capture compares and swaps
/// against. The desk carries no brief — its row's title and objective stay
/// unwritten — so the two String fields project that emptiness for the tests
/// that hold the invariant; no surface displays either one.
struct WorkboardItemSnapshot: Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    var objective: String
    var materials: [WorkboardMaterialSnapshot]
    var revision: Int64

    init(
        id: UUID = UUID(),
        title: String = "",
        objective: String = "",
        materials: [WorkboardMaterialSnapshot] = [],
        revision: Int64 = 0
    ) {
        self.id = id
        self.title = title
        self.objective = objective
        self.materials = materials
        self.revision = revision
    }

}

struct WorkboardMaterialImport: Hashable, Sendable {
    let id: UUID
    var kind: WorkboardMaterialKind
    var name: String
    var detail: String?
    var textContent: String?
    var urlString: String?
    var mimeType: String?
    var data: Data?
    var fileURL: URL?
    var byteCount: Int64?

    init(
        id: UUID = UUID(),
        kind: WorkboardMaterialKind,
        name: String,
        detail: String? = nil,
        textContent: String? = nil,
        urlString: String? = nil,
        mimeType: String? = nil,
        data: Data? = nil,
        fileURL: URL? = nil,
        byteCount: Int64? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.detail = detail
        self.textContent = textContent
        self.urlString = urlString
        self.mimeType = mimeType
        self.data = data
        self.fileURL = fileURL
        self.byteCount = byteCount
    }
}

enum WorkboardVoiceTarget: String, Identifiable, Hashable, Sendable {
    case context

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .context:
            return LocalizedStringResource(
                "workboard.voice.context",
                defaultValue: "Add context and thoughts"
            )
        }
    }
}

struct WorkboardNotice: Identifiable, Equatable {
    enum Kind { case error, information }

    let id = UUID()
    let kind: Kind
    let title: LocalizedStringResource
    let message: String
}

struct WorkboardTransientStatus: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

struct WorkboardWorkspaceImportState: Equatable {
    let itemID: UUID
    var completedCount: Int
    let totalCount: Int
    var failedCount: Int

    var progress: Double {
        guard totalCount > 0 else { return 0 }
        return min(1, max(0, Double(completedCount) / Double(totalCount)))
    }
}

struct WorkboardWorkspaceImportReport: Equatable, Sendable {
    let addedCount: Int
    let failedCount: Int

    var hasFailures: Bool { failedCount > 0 }
}

nonisolated enum WorkboardReorderPlacement: Hashable, Sendable {
    case before
    case after
}

nonisolated enum WorkboardMoveDirection: Hashable, Sendable {
    case earlier
    case later
}

/// Pure planning for card drag, drop-slot insertion and the equivalent
/// accessibility actions inside one project's board. The result is always a
/// COMPLETE ordering of that project's materials, because the store rewrites
/// dense sequence ranks from the whole list under one owner-revision CAS.
enum WorkboardMaterialOrdering {
    /// `index` is a slot in the CURRENT order, `0...count` — exactly what the
    /// mosaic engine's `insertionIndex(at:)` returns. Nil when the move is a
    /// no-op or the material does not belong to `materials`.
    nonisolated static func order(
        moving materialID: UUID,
        toInsertionIndex index: Int,
        in materials: [WorkboardMaterialSnapshot]
    ) -> [UUID]? {
        var orderedIDs = materials.map(\.id)
        guard let sourceIndex = orderedIDs.firstIndex(of: materialID) else { return nil }
        let slot = min(max(index, 0), orderedIDs.count)
        // A slot is a gap between cards, so removing the dragged card first
        // shifts every later gap down by one.
        let destination = slot > sourceIndex ? slot - 1 : slot
        orderedIDs.remove(at: sourceIndex)
        orderedIDs.insert(materialID, at: min(destination, orderedIDs.count))
        return orderedIDs == materials.map(\.id) ? nil : orderedIDs
    }

    nonisolated static func order(
        moving materialID: UUID,
        relativeTo targetMaterialID: UUID,
        placement: WorkboardReorderPlacement,
        in materials: [WorkboardMaterialSnapshot]
    ) -> [UUID]? {
        guard materialID != targetMaterialID else { return nil }
        let orderedIDs = materials.map(\.id)
        guard orderedIDs.contains(materialID),
              let targetIndex = orderedIDs.firstIndex(of: targetMaterialID) else { return nil }
        return order(
            moving: materialID,
            toInsertionIndex: placement == .before ? targetIndex : targetIndex + 1,
            in: materials
        )
    }

    nonisolated static func order(
        moving materialID: UUID,
        direction: WorkboardMoveDirection,
        in materials: [WorkboardMaterialSnapshot]
    ) -> [UUID]? {
        let orderedIDs = materials.map(\.id)
        guard let index = orderedIDs.firstIndex(of: materialID) else { return nil }
        switch direction {
        case .earlier:
            guard index > 0 else { return nil }
            return order(moving: materialID, toInsertionIndex: index - 1, in: materials)
        case .later:
            guard index < orderedIDs.count - 1 else { return nil }
            return order(moving: materialID, toInsertionIndex: index + 2, in: materials)
        }
    }
}

enum WorkboardWorkspaceCaptureLogic {
    nonisolated static func normalizedThought(_ rawValue: String) -> String {
        rawValue
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func title(for thought: String) -> String {
        normalizedThought(thought)
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            .map { String($0.prefix(72)) }
            ?? ""
    }

    nonisolated static func noteTitle(for thought: String) -> String {
        let title = title(for: thought)
        return title.isEmpty
            ? String(localized: LocalizedStringResource(
                "workboard.workspace.thought.defaultTitle",
                defaultValue: "Thought"
            ))
            : title
    }
}

// MARK: - View model

@Observable
@MainActor
final class WorkboardViewModel {
    /// No operation names an owner: Work is one desk at a compile-time id, so
    /// the adapter behind these closures addresses it and this model never
    /// carries a board identity it could get wrong.
    struct Dependencies {
        /// The desk, or nil while no capture has created its row yet.
        var loadDesk: @MainActor () async throws -> WorkboardItemSnapshot?
        /// `(expectedDeskRevision, material, onProgress) -> refreshed desk`.
        /// The token is nil exactly when this model holds no desk to guard —
        /// the first capture creates the row, and a token for a row that does
        /// not exist could not be honestly compared.
        var importMaterial: @MainActor (
            Int64?,
            WorkboardMaterialImport,
            @escaping @Sendable (Double) -> Void
        ) async throws -> WorkboardItemSnapshot
        var removeMaterial: @MainActor (Int64, UUID) async throws -> WorkboardItemSnapshot
        var replaceMaterial: @MainActor (
            Int64,
            UUID,
            WorkboardMaterialImport,
            @escaping @Sendable (Double) -> Void
        ) async throws -> WorkboardItemSnapshot
        var openConversation: @MainActor (UUID) -> Void
        var openMaterial: @MainActor (WorkboardMaterialSnapshot) -> Void
        var openGatewaySettings: @MainActor () -> Void
        /// `(orderedMaterialIDs, expectedDeskRevision) -> refreshed desk`.
        /// Rewriting sequence is board content, so it advances the desk
        /// revision and is refused when the drag was built on an order the
        /// person never saw.
        var reorderMaterials: (@MainActor ([UUID], Int64) async throws -> WorkboardItemSnapshot)?
        /// `(materialID, size)`. Revision-neutral by contract: it must not
        /// stamp `updatedAt` on the material or on the desk.
        var setMaterialCardSize: (@MainActor (UUID, WorkMaterialCardSize) async throws -> Void)?
    }

    private let dependencies: Dependencies

    /// The one desk. Nil means no capture has created its row yet, which is
    /// what the empty-desk canvas draws; a legacy project row on a device that
    /// predates the desk is never loaded, so it can never appear here.
    private(set) var desk: WorkboardItemSnapshot?
    var isLoading = false
    var loadError: String?
    var workspaceImportState: WorkboardWorkspaceImportState?
    /// Session-local composer drafts keyed by the board they belong to. Keeping
    /// them above the detail view means collapsing or reopening the column
    /// never discards half-written work.
    var workspaceComposerDrafts: [UUID: String] = [:]
    /// Boards whose composer holds text that would survive normalization. The
    /// detail view reads this instead of the draft dictionary, so a keystroke
    /// invalidates only what depends on emptiness, not the whole board.
    private(set) var nonEmptyComposerDrafts: Set<UUID> = []

    var notice: WorkboardNotice?
    var workspaceStatus: WorkboardTransientStatus?

    /// True while a capture mutation holds the serialized lane.
    private(set) var isMutatingDesk = false

    @ObservationIgnored private var loadRequestedWhileLoading = false
    @ObservationIgnored private var deskMutationWaiters: [CheckedContinuation<Void, Never>] = []

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// Every capture mutation is serialized because each success advances the
    /// desk's optimistic revision, so capture is disabled while any of them is
    /// in flight rather than only on the card showing progress.
    var isCapturingIntoAnyWorkspace: Bool {
        isMutatingDesk || workspaceImportState != nil
    }

    func workspaceComposerDraft(for itemID: UUID) -> String {
        workspaceComposerDrafts[itemID] ?? ""
    }

    func setWorkspaceComposerDraft(_ value: String, for itemID: UUID) {
        if value.isEmpty {
            workspaceComposerDrafts.removeValue(forKey: itemID)
        } else {
            workspaceComposerDrafts[itemID] = value
        }
        if WorkboardWorkspaceCaptureLogic.normalizedThought(value).isEmpty {
            nonEmptyComposerDrafts.remove(itemID)
        } else {
            nonEmptyComposerDrafts.insert(itemID)
        }
    }

    func hasComposerDraft(for itemID: UUID) -> Bool {
        nonEmptyComposerDrafts.contains(itemID)
    }

    func load() async {
        if isLoading {
            // A capture/CloudKit notification may arrive after the current
            // fetch took its snapshot. Remember that edge and always perform a
            // trailing read instead of silently leaving the board stale.
            loadRequestedWhileLoading = true
            return
        }
        isLoading = true
        repeat {
            loadRequestedWhileLoading = false
            loadError = nil
            do {
                desk = try await dependencies.loadDesk()
            } catch is CancellationError {
                // A trailing request belongs to a different caller/event and
                // still deserves one fresh attempt below.
                if !loadRequestedWhileLoading { break }
            } catch {
                loadError = error.localizedDescription
            }
        } while loadRequestedWhileLoading
        isLoading = false
    }

    /// Resolves a board id against the only board there is. Anything but the
    /// desk answers nil rather than a second board, so a surface that still
    /// carries an id cannot address a row this model does not load.
    func item(withID id: UUID) -> WorkboardItemSnapshot? {
        guard let desk, desk.id == id else { return nil }
        return desk
    }

    /// Appends one chat-like thought without turning capture into execution.
    /// Every thought is a note card, so what the person typed stays a
    /// rearrangeable card. The thought is durable before this method returns.
    @discardableResult
    func addWorkspaceThought(_ rawValue: String, to itemID: UUID) async -> Bool {
        let thought = WorkboardWorkspaceCaptureLogic.normalizedThought(rawValue)
        guard !thought.isEmpty else { return false }

        await acquireWorkspaceMutation()
        defer { releaseWorkspaceMutation() }
        return await addWorkspaceThoughtUnlocked(thought, to: itemID)
    }

    private func addWorkspaceThoughtUnlocked(_ thought: String, to itemID: UUID) async -> Bool {
        // One route for every thought, on the empty desk as much as on a desk
        // already full of cards. A first thought lands atomically: the store's
        // desk write publishes the desk row and the note in a single
        // transaction after any bytes are staged.
        let material = WorkboardMaterialImport(
            kind: .note,
            name: WorkboardWorkspaceCaptureLogic.noteTitle(for: thought),
            textContent: thought
        )
        let report = await importWorkspaceMaterialsUnlocked(
            [material],
            to: itemID,
            announcesResult: false
        )
        return report.addedCount == 1
    }

    /// Persists exactly what the pinned composer shows before anything else can
    /// hide it.
    @discardableResult
    func flushWorkspaceComposer(itemID: UUID) async -> Bool {
        let pending = WorkboardWorkspaceCaptureLogic.normalizedThought(
            workspaceComposerDraft(for: itemID)
        )
        guard !pending.isEmpty else { return true }
        guard await addWorkspaceThought(pending, to: itemID) else { return false }
        setWorkspaceComposerDraft("", for: itemID)
        return true
    }

    /// Imports a drop/picker batch serially. Every successful mutation advances
    /// the desk's optimistic revision before the next item starts, preventing
    /// concurrent providers from racing each other into stale-draft failures.
    /// Partial success is never replayed as a whole batch, so a later retry
    /// cannot duplicate material the user already watched land.
    @discardableResult
    func importWorkspaceMaterials(
        _ imports: [WorkboardMaterialImport],
        to itemID: UUID,
        additionalFailureCount: Int = 0,
        announcesResult: Bool = true
    ) async -> WorkboardWorkspaceImportReport {
        await acquireWorkspaceMutation()
        defer { releaseWorkspaceMutation() }
        return await importWorkspaceMaterialsUnlocked(
            imports,
            to: itemID,
            additionalFailureCount: additionalFailureCount,
            announcesResult: announcesResult
        )
    }

    private func importWorkspaceMaterialsUnlocked(
        _ imports: [WorkboardMaterialImport],
        to itemID: UUID,
        additionalFailureCount: Int = 0,
        announcesResult: Bool = true
    ) async -> WorkboardWorkspaceImportReport {
        let priorFailures = max(0, additionalFailureCount)
        // Capture lands on the desk and nowhere else. A surface aiming at any
        // other board is refused rather than redirected: silently rewriting the
        // target would hide the caller's bug behind a card that appeared anyway.
        guard itemID == Constants.workboardDeskItemID,
              !imports.isEmpty || priorFailures > 0,
              workspaceImportState == nil else {
            return WorkboardWorkspaceImportReport(
                addedCount: 0,
                failedCount: imports.count + priorFailures
            )
        }

        if imports.isEmpty {
            let report = WorkboardWorkspaceImportReport(addedCount: 0, failedCount: priorFailures)
            if announcesResult { presentWorkspaceImportReport(report) }
            return report
        }

        // The desk stays unwritten until its first material is actually stored:
        // an absent revision token means "create the row with this card", and
        // the store publishes both in one transaction after any bytes are
        // staged, so a cancelled or unreadable drop leaves no ghost desk.
        var current = desk

        workspaceImportState = WorkboardWorkspaceImportState(
            itemID: itemID,
            completedCount: priorFailures,
            totalCount: imports.count + priorFailures,
            failedCount: priorFailures
        )
        var added = 0
        var failed = priorFailures
        var firstFailure: Error?

        for (index, materialImport) in imports.enumerated() {
            guard !Task.isCancelled else {
                failed += imports.count - index
                break
            }
            do {
                let refreshed = try await dependencies.importMaterial(
                    current?.revision,
                    materialImport
                ) { itemProgress in
                    Task { @MainActor [self] in
                        guard var state = self.workspaceImportState,
                              state.itemID == itemID else { return }
                        let bounded = min(1, max(0, itemProgress))
                        state.completedCount = min(
                            state.totalCount,
                            priorFailures + index + (bounded >= 1 ? 1 : 0)
                        )
                        self.workspaceImportState = state
                    }
                }
                current = refreshed
                adopt(refreshed)
                added += 1
            } catch {
                failed += 1
                if firstFailure == nil { firstFailure = error }
            }
            if var state = workspaceImportState, state.itemID == itemID {
                state.completedCount = priorFailures + index + 1
                state.failedCount = failed
                workspaceImportState = state
            }
        }

        workspaceImportState = nil
        let report = WorkboardWorkspaceImportReport(addedCount: added, failedCount: failed)
        if announcesResult {
            presentWorkspaceImportReport(report)
        } else if report.hasFailures {
            presentWorkspaceCaptureFailure(
                firstFailure ?? WorkboardLiveRepositoryError.missingPayload
            )
        }
        return report
    }

    func presentWorkspaceImportReport(_ report: WorkboardWorkspaceImportReport) {
        guard report.addedCount > 0 || report.failedCount > 0 else { return }
        if report.failedCount == 0 {
            let message: String
            if report.addedCount == 1 {
                message = String(localized: LocalizedStringResource(
                    "workboard.workspace.import.complete.message.one",
                    defaultValue: "One item was added. Nothing was sent."
                ))
            } else {
                message = String.localizedStringWithFormat(
                    String(localized: LocalizedStringResource(
                        "workboard.workspace.import.complete.message",
                        defaultValue: "%lld items were added. Nothing was sent."
                    )),
                    Int64(report.addedCount)
                )
            }
            workspaceStatus = WorkboardTransientStatus(message: message)
            AccessibilityAnnouncer.announce(message)
        } else {
            notice = WorkboardNotice(
                kind: .information,
                title: LocalizedStringResource(
                    "workboard.workspace.import.partial.title",
                    defaultValue: "Some items need another try"
                ),
                message: String.localizedStringWithFormat(
                    String(localized: LocalizedStringResource(
                        "workboard.workspace.import.partial.message",
                        defaultValue: "%1$lld added, %2$lld failed. Added items were kept and nothing was sent."
                    )),
                    Int64(report.addedCount),
                    Int64(report.failedCount)
                )
            )
        }
    }

    private func presentWorkspaceCaptureFailure(_ error: Error) {
        notice = WorkboardNotice(
            kind: .error,
            title: LocalizedStringResource(
                "workboard.workspace.capture.failed.title",
                defaultValue: "Couldn’t add to Work"
            ),
            message: error.localizedDescription
        )
    }

    /// Reattaches a device-local source directly from the spatial workspace.
    /// It resolves the desk's latest revision immediately before mutation, so
    /// a picker left open across a sync cannot write against a stale revision.
    func reattachWorkspaceMaterial(
        _ material: WorkboardMaterialSnapshot,
        in itemID: UUID,
        with replacement: WorkboardMaterialImport
    ) async {
        await acquireWorkspaceMutation()
        defer { releaseWorkspaceMutation() }
        guard let current = item(withID: itemID),
              current.materials.contains(where: { $0.id == material.id }) else {
            presentWorkspaceCaptureFailure(WorkboardLiveRepositoryError.itemNotFound)
            return
        }
        workspaceImportState = WorkboardWorkspaceImportState(
            itemID: itemID,
            completedCount: 0,
            totalCount: 1,
            failedCount: 0
        )
        defer { workspaceImportState = nil }
        do {
            let refreshed = try await dependencies.replaceMaterial(
                current.revision,
                material.id,
                replacement
            ) { progress in
                Task { @MainActor [self] in
                    guard var state = self.workspaceImportState,
                          state.itemID == itemID else { return }
                    state.completedCount = progress >= 1 ? 1 : 0
                    self.workspaceImportState = state
                }
            }
            adopt(refreshed)
            presentWorkspaceImportReport(WorkboardWorkspaceImportReport(addedCount: 1, failedCount: 0))
        } catch {
            presentWorkspaceCaptureFailure(error)
        }
    }

    /// One capture mutation at a time. The lane is a plain queue because every
    /// capture advances the same desk revision, so two of them in flight would
    /// race each other into stale-revision refusals.
    private func acquireWorkspaceMutation() async {
        if !isMutatingDesk {
            isMutatingDesk = true
            return
        }
        await withCheckedContinuation { continuation in
            deskMutationWaiters.append(continuation)
        }
    }

    private func releaseWorkspaceMutation() {
        guard !deskMutationWaiters.isEmpty else {
            isMutatingDesk = false
            return
        }
        deskMutationWaiters.removeFirst().resume()
    }

    /// Drops a card into a slot the mosaic engine reported, `0...count` in the
    /// order the person is looking at.
    @discardableResult
    func reorderMaterial(
        _ materialID: UUID,
        toInsertionIndex index: Int,
        in itemID: UUID
    ) async -> Bool {
        await performMaterialReorder(in: itemID) { materials in
            WorkboardMaterialOrdering.order(
                moving: materialID,
                toInsertionIndex: index,
                in: materials
            )
        }
    }

    /// Card-relative form for menus and pointer drops that resolve to a
    /// neighbour rather than a slot.
    @discardableResult
    func reorderMaterial(
        _ materialID: UUID,
        relativeTo targetMaterialID: UUID,
        placement: WorkboardReorderPlacement = .before,
        in itemID: UUID
    ) async -> Bool {
        await performMaterialReorder(in: itemID) { materials in
            WorkboardMaterialOrdering.order(
                moving: materialID,
                relativeTo: targetMaterialID,
                placement: placement,
                in: materials
            )
        }
    }

    /// Keyboard/Switch Control/VoiceOver equivalent to dragging a card.
    @discardableResult
    func moveMaterial(
        _ materialID: UUID,
        direction: WorkboardMoveDirection,
        in itemID: UUID
    ) async -> Bool {
        await performMaterialReorder(in: itemID) { materials in
            WorkboardMaterialOrdering.order(
                moving: materialID,
                direction: direction,
                in: materials
            )
        }
    }

    /// Board footprint only. It deliberately skips the capture lane and the
    /// desk revision: a resize is presentation, so it must never advance the
    /// content revision that capture writes CAS against.
    @discardableResult
    func setMaterialCardSize(
        _ size: WorkMaterialCardSize,
        materialID: UUID,
        in itemID: UUID
    ) async -> Bool {
        guard let setCardSize = dependencies.setMaterialCardSize,
              item(withID: itemID) != nil,
              let materialIndex = desk?.materials
                  .firstIndex(where: { $0.id == materialID }) else { return false }
        let previous = desk?.materials[materialIndex].cardSize ?? .standard
        guard previous != size else { return true }
        desk?.materials[materialIndex].cardSize = size
        do {
            try await setCardSize(materialID, size)
            return true
        } catch {
            if let materialIndex = desk?.materials
                .firstIndex(where: { $0.id == materialID }) {
                desk?.materials[materialIndex].cardSize = previous
            }
            notice = WorkboardNotice(
                kind: .error,
                title: LocalizedStringResource(
                    "workboard.action.failed.title",
                    defaultValue: "Couldn’t update the board"
                ),
                message: error.localizedDescription
            )
            return false
        }
    }

    /// Board-scoped removal. It takes the capture lane and CASes on the desk's
    /// own revision, so a removal racing an import is serialized rather than
    /// refused as stale. Removing the last card leaves the desk standing.
    @discardableResult
    func removeMaterialFromBoard(_ materialID: UUID, in itemID: UUID) async -> Bool {
        await acquireWorkspaceMutation()
        defer { releaseWorkspaceMutation() }
        guard let current = item(withID: itemID),
              current.materials.contains(where: { $0.id == materialID }) else { return false }
        do {
            let refreshed = try await dependencies.removeMaterial(
                current.revision,
                materialID
            )
            adopt(refreshed)
            return true
        } catch is CancellationError {
            return false
        } catch {
            notice = WorkboardNotice(
                kind: .error,
                title: LocalizedStringResource(
                    "workboard.material.remove.failed.title",
                    defaultValue: "Couldn’t remove material"
                ),
                message: error.localizedDescription
            )
            return false
        }
    }

    /// Reorder shares the capture lane with thoughts and drops: it rewrites
    /// canonical card order under the desk's optimistic revision, so a drag
    /// racing an import would otherwise be refused as stale.
    private func performMaterialReorder(
        in itemID: UUID,
        plan: ([WorkboardMaterialSnapshot]) -> [UUID]?
    ) async -> Bool {
        guard let reorderMaterials = dependencies.reorderMaterials else { return false }
        await acquireWorkspaceMutation()
        defer { releaseWorkspaceMutation() }
        guard let current = item(withID: itemID),
              let orderedIDs = plan(current.materials) else { return false }

        let previousMaterials = current.materials
        applyMaterialOrder(orderedIDs)
        do {
            let refreshed = try await reorderMaterials(orderedIDs, current.revision)
            adopt(refreshed)
            return true
        } catch {
            // The drag is optimistic for direct-manipulation responsiveness. On
            // conflict, prefer the latest private-store order; if that read also
            // fails, restore only the order captured before this drag.
            do {
                desk = try await dependencies.loadDesk()
            } catch {
                applyMaterials(previousMaterials)
            }
            notice = WorkboardNotice(
                kind: .error,
                title: LocalizedStringResource(
                    "workboard.action.failed.title",
                    defaultValue: "Couldn’t update the board"
                ),
                message: error.localizedDescription
            )
            return false
        }
    }

    /// Mirrors the store's dense rank rewrite so the optimistic board and the
    /// persisted sequence agree before the round trip completes.
    private func applyMaterialOrder(_ orderedIDs: [UUID]) {
        guard let current = desk else { return }
        let byID = Dictionary(
            current.materials.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var reordered = orderedIDs.compactMap { byID[$0] }
        guard reordered.count == current.materials.count else { return }
        for position in reordered.indices {
            reordered[position].sequence = position
        }
        desk?.materials = reordered
    }

    private func applyMaterials(_ materials: [WorkboardMaterialSnapshot]) {
        desk?.materials = materials
    }

    func openMaterial(_ material: WorkboardMaterialSnapshot) {
        dependencies.openMaterial(material)
    }

    func openGatewaySettings() {
        dependencies.openGatewaySettings()
    }

    /// Adopts a desk returned by one operation without letting it undo a newer
    /// read. An operation's result is built from the value the store held when
    /// it started and can land after a corrective `load()`; dropping it when
    /// the board already holds a strictly newer revision keeps the late result
    /// from resurrecting a stale card. Equal revisions still adopt the incoming
    /// value — both describe the same `updatedAt`, and the operation's own
    /// result carries facts the store cannot report yet.
    private func adopt(_ snapshot: WorkboardItemSnapshot) {
        guard let current = desk else {
            desk = snapshot
            return
        }
        guard current.revision <= snapshot.revision else { return }
        desk = snapshot
    }
}
