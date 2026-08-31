// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardViewModel.swift
//
// Presentation boundary for the private Agent Workboard. The UI deliberately
// depends on immutable snapshots and injected async operations instead of Core
// Data objects: the persistence layer can evolve its schema without leaking
// managed-object lifetimes into SwiftUI, while dispatch remains one explicit,
// auditable operation. Drafts autosave locally; only `dispatch` can create work
// outside the board, and it receives the exact prompt + selected material IDs
// the preflight screen showed the person.

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

/// Device-relative payload truth carried all the way into preflight. Local-only
/// files intentionally remain visible on other devices, but they can never look
/// checked or reach dispatch until their bytes are reattached there.
enum WorkboardMaterialAvailability: String, Codable, Hashable, Sendable {
    case available
    case localOnly
    case unavailableOnThisDevice

    var isAvailable: Bool { self != .unavailableOnThisDevice }
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
    /// "changed after send" banner, or invalidate a preflight.
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

enum WorkboardRunState: String, Codable, Hashable, Sendable {
    case sending
    case waiting
    case replied
    case failed
    case cancelled

    var title: LocalizedStringResource {
        switch self {
        case .sending:
            return LocalizedStringResource("workboard.run.sending", defaultValue: "Sending")
        case .waiting:
            return LocalizedStringResource("workboard.run.waiting", defaultValue: "Waiting for AI")
        case .replied:
            return LocalizedStringResource("workboard.run.replied", defaultValue: "Reply received")
        case .failed:
            return LocalizedStringResource("workboard.run.failed", defaultValue: "Needs attention")
        case .cancelled:
            return LocalizedStringResource("workboard.run.cancelled", defaultValue: "Cancelled")
        }
    }

    var systemImage: String {
        switch self {
        case .sending: return "arrow.up.circle"
        case .waiting: return "hourglass"
        case .replied: return "checkmark.bubble.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        }
    }
}

struct WorkboardRunSnapshot: Identifiable, Hashable, Sendable {
    let id: UUID
    var state: WorkboardRunState
    var gatewayRef: RemoteAgentRef
    var gatewayName: String
    var conversationID: UUID?
    var sentPrompt: String
    var includedMaterialNames: [String]
    var resultMarkdown: String?
    var resultAttachments: [AttachmentRecord]
    var failureMessage: String?
    var needsReview: Bool
    var canAcknowledgeReview: Bool
    var reviewResultKey: String?
    var startedAt: Date
    var finishedAt: Date?

    init(
        id: UUID = UUID(),
        state: WorkboardRunState,
        gatewayRef: RemoteAgentRef,
        gatewayName: String,
        conversationID: UUID? = nil,
        sentPrompt: String,
        includedMaterialNames: [String] = [],
        resultMarkdown: String? = nil,
        resultAttachments: [AttachmentRecord] = [],
        failureMessage: String? = nil,
        needsReview: Bool = false,
        canAcknowledgeReview: Bool = true,
        reviewResultKey: String? = nil,
        startedAt: Date = Date(),
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.state = state
        self.gatewayRef = gatewayRef
        self.gatewayName = gatewayName
        self.conversationID = conversationID
        self.sentPrompt = sentPrompt
        self.includedMaterialNames = includedMaterialNames
        self.resultMarkdown = resultMarkdown
        self.resultAttachments = resultAttachments
        self.failureMessage = failureMessage
        self.needsReview = needsReview
        self.canAcknowledgeReview = canAcknowledgeReview
        self.reviewResultKey = reviewResultKey
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

struct WorkboardItemSnapshot: Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    var objective: String
    var context: String
    var desiredResult: String
    var constraints: String
    var reviewBy: Date?
    var state: WorkItemState
    var materials: [WorkboardMaterialSnapshot]
    var runs: [WorkboardRunSnapshot]
    var isPinned: Bool
    var createdAt: Date
    var modifiedAt: Date
    /// Stable, presentation-only position within the pinned or unpinned
    /// project-strip cohort. Nil means the project has not been manually placed.
    var boardOrder: Int64?
    var revision: Int64
    var lastSentRevision: Int64?
    var wasCapturedExternally: Bool
    /// Haystack for the sidebar search field, joined once here rather than per
    /// filter pass: every keystroke re-derives the visible board, and the joined
    /// text includes each run's full prompt and reply. Stored verbatim — the
    /// matcher folds case, diacritics and width on BOTH operands, so a stored
    /// lowercase copy would buy nothing and cost a second allocation of the
    /// board's entire text.
    let searchCorpus: String

    init(
        id: UUID = UUID(),
        title: String = "",
        objective: String = "",
        context: String = "",
        desiredResult: String = "",
        constraints: String = "",
        reviewBy: Date? = nil,
        state: WorkItemState = .draft,
        materials: [WorkboardMaterialSnapshot] = [],
        runs: [WorkboardRunSnapshot] = [],
        isPinned: Bool = false,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        boardOrder: Int64? = nil,
        revision: Int64 = 0,
        lastSentRevision: Int64? = nil,
        wasCapturedExternally: Bool = false
    ) {
        self.id = id
        self.title = title
        self.objective = objective
        self.context = context
        self.desiredResult = desiredResult
        self.constraints = constraints
        self.reviewBy = reviewBy
        self.state = state
        self.materials = materials
        self.runs = runs
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.boardOrder = boardOrder
        self.revision = revision
        self.lastSentRevision = lastSentRevision
        self.wasCapturedExternally = wasCapturedExternally
        let materialText = materials.flatMap { [$0.name, $0.detail ?? "", $0.textContent ?? ""] }
        let runText = runs.flatMap {
            [$0.gatewayName, $0.resultMarkdown ?? "", $0.failureMessage ?? "", $0.sentPrompt]
        }
        self.searchCorpus = ([title, objective, context, desiredResult, constraints]
            + materialText
            + runText)
            .joined(separator: "\n")
    }

    var displayTitle: String {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanTitle.isEmpty { return cleanTitle }
        let firstLine = objective
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !firstLine.isEmpty { return String(firstLine.prefix(72)) }
        return String(localized: LocalizedStringResource(
            "workboard.item.untitled",
            defaultValue: "Untitled brief"
        ))
    }

    nonisolated var latestRun: WorkboardRunSnapshot? {
        runs.max { $0.startedAt < $1.startedAt }
    }

    nonisolated var hasChangesSinceLastSend: Bool {
        guard let lastSentRevision else { return false }
        return revision > lastSentRevision
    }

    nonisolated var isReadyToSend: Bool {
        !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct WorkboardEditDraft: Hashable, Sendable {
    var id: UUID
    var title: String
    var objective: String
    var context: String
    var desiredResult: String
    var constraints: String
    var reviewBy: Date?
    var materials: [WorkboardMaterialSnapshot]
    var isPinned: Bool
    var baseRevision: Int64

    init(item: WorkboardItemSnapshot) {
        id = item.id
        title = item.title
        objective = item.objective
        context = item.context
        desiredResult = item.desiredResult
        constraints = item.constraints
        reviewBy = item.reviewBy
        materials = item.materials
        isPinned = item.isPinned
        baseRevision = item.revision
    }

    init(id: UUID = UUID()) {
        self.id = id
        title = ""
        objective = ""
        context = ""
        desiredResult = ""
        constraints = ""
        reviewBy = nil
        materials = []
        isPinned = false
        baseRevision = 0
    }

    var isMeaningful: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !desiredResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !constraints.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !materials.isEmpty
            // A set review-by date is deliberate input: without this, a
            // date-only new draft blocks swipe-dismiss yet saves nothing.
            || reviewBy != nil
    }

    var isReadyToSend: Bool {
        !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Excludes the persistence revision so a successful save can update the
    /// optimistic concurrency token without making the editor look dirty again.
    var contentFingerprint: String {
        let materialFingerprint = materials.map { material in
            "\(material.id.uuidString)|\(material.name)|\(material.detail ?? "")|\(material.sequence)"
        }.joined(separator: "\n")
        return [
            title,
            objective,
            context,
            desiredResult,
            constraints,
            reviewBy?.timeIntervalSinceReferenceDate.description ?? "",
            isPinned.description,
            materialFingerprint
        ].joined(separator: "\u{1F}")
    }
}

enum WorkboardGatewayCapability: String, Hashable, Sendable {
    case text
    case images
    case files
}

struct WorkboardGatewayChoice: Identifiable, Hashable, Sendable {
    var id: String { ref.rawString }
    var ref: RemoteAgentRef
    var name: String
    var detail: String
    var capabilities: Set<WorkboardGatewayCapability>
    /// A gateway reaches the roster only once it is configured on this device,
    /// so this is a plain status line, never a reachability verdict: the send
    /// itself is the only thing that proves the endpoint answers.
    var configurationStatus: String

    init(
        ref: RemoteAgentRef,
        name: String,
        detail: String,
        capabilities: Set<WorkboardGatewayCapability> = [.text],
        configurationStatus: String = ""
    ) {
        self.ref = ref
        self.name = name
        self.detail = detail
        self.capabilities = capabilities.union([.text])
        self.configurationStatus = configurationStatus
    }

    func supports(_ material: WorkboardMaterialSnapshot) -> Bool {
        guard material.availability.isAvailable else { return false }
        switch material.kind {
        case .image:
            return capabilities.contains(.images)
        case .file:
            // UTF-8 text/code can ride inline through every configured gateway.
            // Work files intentionally do not sync extracted content, so use
            // bounded metadata to keep the dispatch-time probe reachable; the
            // coordinator still verifies the actual bytes before transport.
            let hasInlineText = !(material.textContent ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            return hasInlineText || canAttemptInlineTextProbe(material)
                ? capabilities.contains(.text)
                : capabilities.contains(.files)
        case .link, .note:
            return capabilities.contains(.text)
        }
    }

    private func canAttemptInlineTextProbe(_ material: WorkboardMaterialSnapshot) -> Bool {
        guard let byteCount = material.byteCount,
              byteCount >= 0,
              byteCount <= Int64(Constants.textProbeMaxBytes) else { return false }

        let mime = material.mimeType?.lowercased() ?? ""
        if mime.hasPrefix("video/") || mime.hasPrefix("audio/")
            || mime.hasPrefix("image/") || mime == "application/pdf"
            || mime.contains("zip") || mime.contains("archive") {
            return false
        }

        let ext = (material.name as NSString).pathExtension.lowercased()
        let obviouslyBinary = Set([
            "7z", "a", "avi", "bin", "dmg", "doc", "docx", "gz", "heic",
            "jpeg", "jpg", "m4a", "m4v", "mov", "mp3", "mp4", "odt", "pdf",
            "png", "rar", "tar", "wav", "webp", "xls", "xlsx", "zip",
        ])
        return !obviouslyBinary.contains(ext)
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

struct WorkboardDispatchRequest: Hashable, Sendable {
    let id: UUID
    let itemID: UUID
    let expectedRevision: Int64
    let gatewayRef: RemoteAgentRef
    let prompt: String
    let includedMaterialIDs: [UUID]
    let includedMaterialVersions: [WorkboardMaterialVersion]
    let createdAt: Date

    init(
        id: UUID = UUID(),
        itemID: UUID,
        expectedRevision: Int64,
        gatewayRef: RemoteAgentRef,
        prompt: String,
        includedMaterialIDs: [UUID],
        includedMaterialVersions: [WorkboardMaterialVersion] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.itemID = itemID
        self.expectedRevision = expectedRevision
        self.gatewayRef = gatewayRef
        self.prompt = prompt
        self.includedMaterialIDs = includedMaterialIDs
        self.includedMaterialVersions = includedMaterialVersions
        self.createdAt = createdAt
    }
}

struct WorkboardDispatchReceipt: Hashable, Sendable {
    let item: WorkboardItemSnapshot
    let conversationID: UUID
    let runID: UUID
}

enum WorkboardFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    case open
    case needsYou
    case waiting
    case drafts
    case changed
    case done
    case all

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .open:
            return LocalizedStringResource("workboard.filter.open", defaultValue: "Open work")
        case .needsYou:
            return LocalizedStringResource("workboard.filter.needsYou", defaultValue: "Needs you")
        case .waiting:
            return LocalizedStringResource("workboard.filter.waiting", defaultValue: "Waiting on AI")
        case .drafts:
            return LocalizedStringResource("workboard.filter.drafts", defaultValue: "Drafts")
        case .changed:
            return LocalizedStringResource("workboard.filter.changed", defaultValue: "Changed after send")
        case .done:
            return LocalizedStringResource("workboard.filter.done", defaultValue: "Done")
        case .all:
            return LocalizedStringResource("workboard.filter.all", defaultValue: "Everything")
        }
    }

    nonisolated func includes(_ item: WorkboardItemSnapshot) -> Bool {
        switch self {
        case .open: return item.state != .done
        case .needsYou: return item.state == .review
        case .waiting: return item.state == .waiting
        case .drafts: return item.state == .draft
        case .changed: return item.hasChangesSinceLastSend
        case .done: return item.state == .done
        case .all: return true
        }
    }
}

struct WorkboardBriefingSnapshot: Identifiable, Hashable, Sendable {
    let id = UUID()
    let generatedAt: Date
    let needsYou: [WorkboardItemSnapshot]
    let waiting: [WorkboardItemSnapshot]
    let drafts: [WorkboardItemSnapshot]
    let spokenText: String

    var isEmpty: Bool { needsYou.isEmpty && waiting.isEmpty && drafts.isEmpty }
}

enum WorkboardVoiceTarget: String, Identifiable, Hashable, Sendable {
    case objective
    case context

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .objective:
            return LocalizedStringResource(
                "workboard.voice.objective",
                defaultValue: "Describe the work"
            )
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

struct WorkboardEditorConflict: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

struct WorkboardConfirmation: Identifiable, Equatable {
    enum Kind { case duplicate, delete }

    let id = UUID()
    let kind: Kind
    let itemID: UUID
    let itemTitle: String
}

/// A rename in flight. It carries the project's own id rather than a list index,
/// so a sync landing between the right-click and the alert's Rename button can
/// never retarget the write.
struct WorkboardRenameRequest: Identifiable, Equatable {
    let id: UUID
    let originalTitle: String
}

// MARK: - Pure presentation logic

enum WorkboardPresentationLogic {
    nonisolated static func visibleItems(
        _ items: [WorkboardItemSnapshot],
        filter: WorkboardFilter,
        searchText: String
    ) -> [WorkboardItemSnapshot] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return items
            .filter(filter.includes)
            .filter { matches($0, needle: needle) }
            .sorted(by: attentionSort)
    }

    /// Answers the emptiness question without materializing or sorting the board.
    /// The overview asks it on every pass purely to choose between the canvas and
    /// the empty state, and the corpus scan is the expensive half.
    nonisolated static func hasVisibleItems(
        _ items: [WorkboardItemSnapshot],
        filter: WorkboardFilter,
        searchText: String
    ) -> Bool {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.contains { filter.includes($0) && matches($0, needle: needle) }
    }

    nonisolated static func items(
        in state: WorkItemState,
        from items: [WorkboardItemSnapshot]
    ) -> [WorkboardItemSnapshot] {
        items.filter { $0.state == state }.sorted(by: attentionSort)
    }

    /// The sketch's central project strip is manually ordered across lifecycle
    /// states. Pinning remains a separate leading cohort; state badges move with
    /// their cards but drag never writes or implies a lifecycle transition.
    nonisolated static func projectStripItems(
        _ items: [WorkboardItemSnapshot],
        filter: WorkboardFilter,
        searchText: String
    ) -> [WorkboardItemSnapshot] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return items
            .filter(filter.includes)
            .filter { matches($0, needle: needle) }
            .sorted(by: projectStripSort)
    }

    /// `searchCorpus` is joined once, at snapshot time, so a keystroke never
    /// re-derives it. `localizedStandardContains` folds case, diacritics and
    /// width on both sides in the reader's own locale, so the haystack is stored
    /// exactly as written.
    nonisolated static func matches(_ item: WorkboardItemSnapshot, needle: String) -> Bool {
        needle.isEmpty || item.searchCorpus.localizedStandardContains(needle)
    }

    nonisolated static func projectStripSort(
        _ lhs: WorkboardItemSnapshot,
        _ rhs: WorkboardItemSnapshot
    ) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        switch (lhs.boardOrder, rhs.boardOrder) {
        case let (.some(left), .some(right)) where left != right:
            return left < right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            break
        }
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    nonisolated static func attentionSort(_ lhs: WorkboardItemSnapshot, _ rhs: WorkboardItemSnapshot) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        if lhs.state.attentionRank != rhs.state.attentionRank {
            return lhs.state.attentionRank < rhs.state.attentionRank
        }
        if lhs.state == .waiting, lhs.modifiedAt != rhs.modifiedAt {
            // Oldest waits surface first; every other lane is newest first.
            return lhs.modifiedAt < rhs.modifiedAt
        }
        if lhs.reviewBy != rhs.reviewBy {
            switch (lhs.reviewBy, rhs.reviewBy) {
            case (.some(let left), .some(let right)): return left < right
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): break
            }
        }
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    nonisolated static func briefing(from items: [WorkboardItemSnapshot], now: Date = Date()) -> WorkboardBriefingSnapshot {
        let needsYou = Self.items(in: .review, from: items)
        let waiting = Self.items(in: .waiting, from: items)
        let allDrafts = Self.items(in: .draft, from: items)
        // A visible briefing should surface a manageable set, while its spoken
        // counts remain complete and come from the canonical deterministic builder.
        let drafts = Array(allDrafts.prefix(3))
        let failureCount = needsYou.filter { $0.latestRun?.state == .failed }.count
        let spokenText = WorkboardBriefingBuilder.build(
            from: WorkboardBriefingFacts(
                repliesToReview: max(0, needsYou.count - failureCount),
                failuresToReview: failureCount,
                waiting: waiting.count,
                drafts: allDrafts.count
            )
        )
        return WorkboardBriefingSnapshot(
            generatedAt: now,
            needsYou: needsYou,
            waiting: waiting,
            drafts: drafts,
            spokenText: spokenText
        )
    }
}

nonisolated enum WorkboardReorderPlacement: Hashable, Sendable {
    case before
    case after
}

nonisolated enum WorkboardMoveDirection: Hashable, Sendable {
    case earlier
    case later
}

/// Pure planning for card drag and equivalent accessibility actions. Plans
/// normalize the entire pin cohort, which avoids fractional-rank drift and gives
/// the store one complete optimistic compare-and-swap request.
enum WorkboardBoardOrdering {
    nonisolated static func request(
        moving movingItemID: UUID,
        relativeTo targetItemID: UUID,
        placement: WorkboardReorderPlacement,
        in items: [WorkboardItemSnapshot]
    ) -> WorkItemBoardReorder? {
        guard movingItemID != targetItemID,
              let moving = items.first(where: { $0.id == movingItemID }),
              let target = items.first(where: { $0.id == targetItemID }),
              moving.isPinned == target.isPinned else { return nil }

        let cohort = items
            .filter { $0.isPinned == moving.isPinned }
            .sorted(by: WorkboardPresentationLogic.projectStripSort)
        var orderedIDs = cohort.map(\.id)
        guard let sourceIndex = orderedIDs.firstIndex(of: movingItemID) else { return nil }
        orderedIDs.remove(at: sourceIndex)
        guard let targetIndex = orderedIDs.firstIndex(of: targetItemID) else { return nil }
        let insertionIndex = placement == .before ? targetIndex : targetIndex + 1
        orderedIDs.insert(movingItemID, at: insertionIndex)
        guard orderedIDs != cohort.map(\.id) else { return nil }

        return WorkItemBoardReorder(
            movingItemID: movingItemID,
            expectedPinned: moving.isPinned,
            expectedPositions: cohort.map {
                WorkItemBoardPosition(id: $0.id, boardOrder: $0.boardOrder)
            },
            orderedItemIDs: orderedIDs
        )
    }

    nonisolated static func request(
        moving movingItemID: UUID,
        direction: WorkboardMoveDirection,
        in items: [WorkboardItemSnapshot],
        visibleItemIDs: Set<UUID>? = nil
    ) -> WorkItemBoardReorder? {
        guard let moving = items.first(where: { $0.id == movingItemID }) else { return nil }
        let cohort = items
            .filter { $0.isPinned == moving.isPinned }
            .filter { visibleItemIDs?.contains($0.id) ?? true }
            .sorted(by: WorkboardPresentationLogic.projectStripSort)
        guard let index = cohort.firstIndex(where: { $0.id == movingItemID }) else { return nil }
        let targetIndex: Int
        switch direction {
        case .earlier:
            guard index > cohort.startIndex else { return nil }
            targetIndex = cohort.index(before: index)
        case .later:
            guard index < cohort.index(before: cohort.endIndex) else { return nil }
            targetIndex = cohort.index(after: index)
        }
        return request(
            moving: movingItemID,
            relativeTo: cohort[targetIndex].id,
            placement: direction == .earlier ? .before : .after,
            in: items
        )
    }
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

/// Which brief field the editor should adopt focus in when it opens. The board
/// asks for this instead of silently refusing an unsendable brief.
nonisolated enum WorkboardEditorFocusTarget: Hashable, Sendable {
    case objective
}

/// Builds the transcript Apple's on-device model shapes into a brief. Shaping
/// reads the collected thoughts, not only the authored fields, so a board full
/// of notes produces a real brief. Neither `WorkBriefPromptBuilder` nor
/// `WorkBriefAssistant` bounds its input, while one stored note may run to
/// `WorkCaptureEnvelope.maximumNoteCharacters` and the system model's context
/// window is far smaller — so the bounds live here. Truncation is silent
/// because the result is an editable suggestion, never a send. Presentation
/// kind `.note` covers voice transcripts: the store's `.transcript` rows map
/// onto it, and Workboard retains no audio.
nonisolated enum WorkBriefShapingSource {
    static let maximumNoteCount = 12
    static let maximumNoteCharacters = 800
    static let maximumTranscriptCharacters = 6_000

    static func transcript(for draft: WorkboardEditDraft) -> String {
        let authored = [
            draft.title,
            draft.objective,
            draft.context,
            draft.desiredResult,
            draft.constraints
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

        let notes = draft.materials
            .filter { $0.kind == .note }
            .compactMap { material -> String? in
                let text = (material.textContent ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : truncated(text, to: maximumNoteCharacters)
            }
            .prefix(maximumNoteCount)

        var sections = authored
        if !notes.isEmpty {
            sections.append("Collected thoughts:\n" + notes.map { "- \($0)" }.joined(separator: "\n"))
        }
        return truncated(sections.joined(separator: "\n\n"), to: maximumTranscriptCharacters)
    }

    private static func truncated(_ value: String, to limit: Int) -> String {
        guard value.count > limit, limit > 1 else { return value }
        return String(value.prefix(limit - 1)) + "…"
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

enum WorkboardPromptComposer {
    /// Thin presentation adapter over the ONE canonical serializer. Preview and
    /// dispatch both consume this exact output; this layer only maps UI snapshots
    /// into the persistence-neutral packet shape.
    nonisolated static func compose(item: WorkboardItemSnapshot, includedMaterialIDs: Set<UUID>) -> String {
        let materials = item.materials
            .filter { includedMaterialIDs.contains($0.id) }
            .map { material in
                WorkBriefMaterialPacket(
                    id: material.id,
                    kind: material.packetKind,
                    label: material.name,
                    text: material.textContent,
                    url: material.urlString,
                    mimeType: material.mimeType,
                    byteSize: material.byteCount,
                    sequence: material.sequence,
                    createdAt: material.createdAt
                )
            }
        return WorkBriefPromptBuilder.build(
            workItemID: item.id,
            title: item.title,
            objective: item.objective,
            context: item.context,
            constraints: item.constraints,
            desiredResult: item.desiredResult,
            reviewBy: item.reviewBy,
            materials: materials
        ).canonicalPrompt
    }
}

private extension WorkboardMaterialSnapshot {
    nonisolated var packetKind: WorkBriefMaterialPacket.Kind {
        switch kind {
        case .image: return .image
        case .file: return .file
        case .link: return .link
        case .note: return .note
        }
    }
}

// MARK: - View model

@Observable
@MainActor
final class WorkboardViewModel {
    struct Dependencies {
        var loadItems: @MainActor () async throws -> [WorkboardItemSnapshot]
        var loadGateways: @MainActor () async throws -> ([WorkboardGatewayChoice], [CustomGateway])
        var saveDraft: @MainActor (WorkboardEditDraft) async throws -> WorkboardItemSnapshot
        var saveDraftAsCopy: @MainActor (WorkboardEditDraft) async throws -> WorkboardItemSnapshot
        var importMaterial: @MainActor (
            UUID,
            Int64,
            WorkboardMaterialImport,
            @escaping @Sendable (Double) -> Void
        ) async throws -> WorkboardItemSnapshot
        var removeMaterial: @MainActor (UUID, Int64, UUID) async throws -> WorkboardItemSnapshot
        var replaceMaterial: @MainActor (
            UUID,
            Int64,
            UUID,
            WorkboardMaterialImport,
            @escaping @Sendable (Double) -> Void
        ) async throws -> WorkboardItemSnapshot
        var deleteItem: @MainActor (UUID) async throws -> Void
        var duplicateItem: @MainActor (UUID) async throws -> WorkboardItemSnapshot
        var reorderItems: @MainActor (WorkItemBoardReorder) async throws -> [WorkboardItemSnapshot]
        var setState: @MainActor (UUID, WorkItemState) async throws -> WorkboardItemSnapshot
        var acknowledgeRun: @MainActor (UUID, UUID, String) async throws -> WorkboardItemSnapshot
        var dispatch: @MainActor (WorkboardDispatchRequest) async throws -> WorkboardDispatchReceipt
        var openConversation: @MainActor (UUID) -> Void
        var openMaterial: @MainActor (WorkboardMaterialSnapshot) -> Void
        var openGatewaySettings: @MainActor () -> Void
        var shapeDraft: (@MainActor (WorkboardEditDraft) async throws -> WorkboardEditDraft)?
        var readBriefingAloud: (@MainActor (String) async -> Void)?
        var stopBriefingAloud: (@MainActor () -> Void)?
        /// `(itemID, orderedMaterialIDs, expectedOwnerRevision) -> refreshed item`.
        /// Rewriting sequence is canonical prompt order, so it advances the
        /// owner revision and is refused when the drag was built on an order the
        /// person never saw.
        var reorderMaterials: (@MainActor (UUID, [UUID], Int64) async throws -> WorkboardItemSnapshot)?
        /// `(itemID, materialID, size)`. Revision-neutral by contract: it must
        /// not stamp `updatedAt` on the material or its owner.
        var setMaterialCardSize: (@MainActor (UUID, UUID, WorkMaterialCardSize) async throws -> Void)?
        /// `(itemID, expectedPinned, isPinned) -> refreshed item`. Revision-neutral
        /// by the same contract, and it compares against the pin the person saw
        /// rather than a revision, so pinning never reads as a brief edit.
        var setPinned: (@MainActor (UUID, Bool, Bool) async throws -> WorkboardItemSnapshot)?
    }

    private let dependencies: Dependencies

    var items: [WorkboardItemSnapshot] = []
    var gateways: [WorkboardGatewayChoice] = []
    var customGateways: [CustomGateway] = []
    var isLoading = false
    var loadError: String?
    /// What the search field shows. Write it through `updateSearchText` so the
    /// board keeps filtering off `appliedSearchText` instead of re-deriving every
    /// projection over the full corpus on each keystroke.
    private(set) var searchText = ""
    /// The needle the board actually filters on, trailing `searchText` by
    /// `searchDebounce` while the person is still typing.
    private(set) var appliedSearchText = ""
    var filter: WorkboardFilter = .open
    var isReorderingBoard = false
    var selectedItemID: UUID?
    /// A canvas identity that has not written a Core Data row yet. New Work is
    /// therefore instant, but abandoning an untouched canvas never leaves an
    /// "Untitled" ghost behind. The first thought or material persists it.
    var provisionalWorkspaceID: UUID?

    var editorPresented = false
    var editingDraft = WorkboardEditDraft()
    var editorIsSaving = false
    var workspaceImportState: WorkboardWorkspaceImportState?
    /// One visible capture mutation at a time. The queue is global because a
    /// single view model owns all optimistic WorkItem revisions and a person can
    /// switch projects while an async picker/save is still finishing.
    var workspaceMutationItemID: UUID?
    /// Session-local composer drafts keyed by project. Keeping these above the
    /// detail view means switching projects or collapsing the split view never
    /// discards half-written work.
    var workspaceComposerDrafts: [UUID: String] = [:]
    /// Projects whose composer holds text that would survive normalization.
    /// The detail view's send affordance reads this instead of the draft
    /// dictionary, so a keystroke cannot invalidate the result card and the
    /// whole run timeline beside it.
    private(set) var nonEmptyComposerDrafts: Set<UUID> = []
    /// Set when the brief is opened because something needed a field the person
    /// has not written yet. The editor consumes it once and clears it.
    var editorFocusRequest: WorkboardEditorFocusTarget?
    var editorSuggestion: WorkboardEditDraft?
    var editorConflict: WorkboardEditorConflict?
    var isShapingDraft = false

    var preflightItemID: UUID?
    var selectedGatewayID: String?
    var excludedMaterialIDs: Set<UUID> = []
    var isDispatching = false

    var briefing: WorkboardBriefingSnapshot?
    var isReadingBriefing = false
    var notice: WorkboardNotice?
    var workspaceStatus: WorkboardTransientStatus?
    var confirmation: WorkboardConfirmation?
    var renameRequest: WorkboardRenameRequest?
    /// What the rename alert's field holds. It lives here rather than in the
    /// sidebar row so an unmounted row — a filter change, a sync, the split view
    /// collapsing — cannot take a half-typed name down with it.
    var renameDraftTitle = ""

    @ObservationIgnored private var lastSavedFingerprint = ""
    @ObservationIgnored private var editorWasPersisted = false
    @ObservationIgnored private var loadRequestedWhileLoading = false
    @ObservationIgnored private var workspaceMutationWaiters: [WorkspaceMutationWaiter] = []
    @ObservationIgnored private var searchDebounceTask: Task<Void, Never>?

    /// Long enough to swallow a burst of typing, short enough that the board
    /// still feels like it is filtering as you type.
    private static let searchDebounce = Duration.milliseconds(150)

    private struct WorkspaceMutationWaiter {
        let itemID: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    var visibleItems: [WorkboardItemSnapshot] {
        WorkboardPresentationLogic.visibleItems(items, filter: filter, searchText: appliedSearchText)
    }

    var projectStripItems: [WorkboardItemSnapshot] {
        WorkboardPresentationLogic.projectStripItems(items, filter: filter, searchText: appliedSearchText)
    }

    var hasVisibleItems: Bool {
        WorkboardPresentationLogic.hasVisibleItems(items, filter: filter, searchText: appliedSearchText)
    }

    /// The one write path for the search field. Clearing applies immediately —
    /// the person is on their way somewhere else, not still narrowing.
    func updateSearchText(_ value: String) {
        guard value != searchText else { return }
        searchText = value
        searchDebounceTask?.cancel()
        guard !value.isEmpty else {
            appliedSearchText = ""
            return
        }
        searchDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.searchDebounce)
            guard !Task.isCancelled, let self else { return }
            self.appliedSearchText = self.searchText
        }
    }

    var selectedItem: WorkboardItemSnapshot? {
        guard let selectedItemID else { return nil }
        return items.first { $0.id == selectedItemID }
    }

    var preflightItem: WorkboardItemSnapshot? {
        guard let preflightItemID else { return nil }
        return items.first { $0.id == preflightItemID }
    }

    var selectedGateway: WorkboardGatewayChoice? {
        gateways.first { $0.id == selectedGatewayID }
    }

    var editorHasUnsavedChanges: Bool {
        editingDraft.contentFingerprint != lastSavedFingerprint
    }

    var canShapeDraft: Bool { dependencies.shapeDraft != nil }
    var canReadBriefing: Bool { dependencies.readBriefingAloud != nil }

    /// Every capture mutation is serialized because each success advances an
    /// optimistic owner revision, so capture is disabled board-wide rather than
    /// only on the project that owns the current progress indicator.
    var isCapturingIntoAnyWorkspace: Bool {
        workspaceMutationItemID != nil || workspaceImportState != nil
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

    /// Opens the quick capture canvas without persisting anything. This is the
    /// single New Work route used by the sidebar, recent strip and briefing.
    @discardableResult
    func beginWorkspace(id: UUID = UUID()) -> UUID {
        provisionalWorkspaceID = id
        selectedItemID = nil
        return id
    }

    func cancelProvisionalWorkspace() {
        if let provisionalWorkspaceID {
            workspaceComposerDrafts.removeValue(forKey: provisionalWorkspaceID)
            nonEmptyComposerDrafts.remove(provisionalWorkspaceID)
        }
        provisionalWorkspaceID = nil
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
                async let loadedItems = dependencies.loadItems()
                async let gatewayRoster = dependencies.loadGateways()
                let (newItems, roster) = try await (loadedItems, gatewayRoster)
                items = newItems
                gateways = roster.0
                customGateways = roster.1
                if let selectedItemID, !items.contains(where: { $0.id == selectedItemID }) {
                    self.selectedItemID = nil
                }
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

    func item(withID id: UUID) -> WorkboardItemSnapshot? {
        items.first { $0.id == id }
    }

    func showEditor(
        for item: WorkboardItemSnapshot,
        focusing target: WorkboardEditorFocusTarget? = nil
    ) {
        editingDraft = WorkboardEditDraft(item: item)
        lastSavedFingerprint = editingDraft.contentFingerprint
        editorWasPersisted = true
        editorSuggestion = nil
        editorFocusRequest = target
        editorPresented = true
    }

    /// One-shot read. The editor takes the request as it appears and clears it,
    /// so reopening the brief later does not re-steal focus.
    func consumeEditorFocusRequest() -> WorkboardEditorFocusTarget? {
        defer { editorFocusRequest = nil }
        return editorFocusRequest
    }

    @discardableResult
    func saveEditorNow(showFailure: Bool) async -> Bool {
        guard !editorIsSaving else { return false }
        guard editingDraft.isMeaningful || editorWasPersisted else {
            lastSavedFingerprint = editingDraft.contentFingerprint
            return true
        }
        while editingDraft.contentFingerprint != lastSavedFingerprint {
            // Freeze the exact submitted value. The editor stays responsive
            // while storage is suspended, so a later keystroke must never be
            // mistaken for part of this save's success.
            let submittedDraft = editingDraft
            let submittedFingerprint = submittedDraft.contentFingerprint
            editorIsSaving = true
            do {
                let saved = try await dependencies.saveDraft(submittedDraft)
                upsert(saved)
                // Advance the optimistic token for the next pass without
                // replacing newer text. Material projections are replaced only
                // when that part of the draft did not change in flight.
                editingDraft.baseRevision = saved.revision
                if editingDraft.materials == submittedDraft.materials {
                    editingDraft.materials = saved.materials
                }
                lastSavedFingerprint = submittedFingerprint
                editorWasPersisted = true
                editorIsSaving = false
            } catch {
                editorIsSaving = false
                if let repositoryError = error as? WorkboardLiveRepositoryError,
                   repositoryError == .staleDraft || repositoryError == .itemNotFound {
                    editorConflict = WorkboardEditorConflict(message: error.localizedDescription)
                    return false
                }
                if showFailure {
                    notice = WorkboardNotice(
                        kind: .error,
                        title: LocalizedStringResource("workboard.save.failed.title", defaultValue: "Draft not saved"),
                        message: error.localizedDescription
                    )
                }
                return false
            }
        }
        return true
    }

    func reviewEditorAndSend() async {
        guard editingDraft.isReadyToSend else {
            editorFocusRequest = .objective
            return
        }
        guard await saveEditorNow(showFailure: true) else { return }
        let itemID = editingDraft.id
        editorPresented = false
        await Task.yield()
        await showPreflight(itemID: itemID)
    }

    /// Appends one chat-like thought without turning capture into execution.
    /// Every thought is a note card — the composer never writes the brief, so
    /// what the person typed stays a rearrangeable card and the objective stays
    /// theirs to author. The thought is durable before this method returns.
    @discardableResult
    func addWorkspaceThought(_ rawValue: String, to itemID: UUID) async -> Bool {
        let thought = WorkboardWorkspaceCaptureLogic.normalizedThought(rawValue)
        guard !thought.isEmpty else { return false }

        await acquireWorkspaceMutation(for: itemID)
        defer { releaseWorkspaceMutation(for: itemID) }
        return await addWorkspaceThoughtUnlocked(thought, to: itemID)
    }

    private func addWorkspaceThoughtUnlocked(_ thought: String, to itemID: UUID) async -> Bool {
        // One route for every thought, on a provisional canvas as much as on an
        // established project. A first thought on a canvas that owns no row yet
        // still lands atomically: the import path publishes owner and first
        // material in a single store transaction and derives the project title
        // from the note's own first line, leaving the objective empty for the
        // person to write.
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

    /// Saves the exact visible composer text before opening preflight. This is
    /// the one path used by both the canvas and toolbar, so ⌘-Return cannot skip
    /// a half-written thought. Collected thoughts do not describe the work, so a
    /// brief without an objective opens the editor on that field instead of
    /// refusing without explanation.
    @discardableResult
    func reviewWorkspaceAndSend(itemID: UUID) async -> Bool {
        guard await flushWorkspaceComposer(itemID: itemID) else { return false }
        guard selectedItemID == itemID, let item = item(withID: itemID) else { return false }
        guard item.isReadyToSend else {
            showEditor(for: item, focusing: .objective)
            return false
        }
        await showPreflight(itemID: itemID)
        return preflightItemID == itemID
    }

    /// Persists exactly what the pinned composer shows before any lifecycle
    /// action can hide or dispatch it.
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

    func completeWorkspace(itemID: UUID) async {
        guard await flushWorkspaceComposer(itemID: itemID),
              let current = item(withID: itemID) else { return }
        await transition(current, to: .done)
    }

    /// Imports a drop/picker batch serially. Every successful mutation advances
    /// the owner's optimistic revision before the next item starts, preventing
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
        await acquireWorkspaceMutation(for: itemID)
        defer { releaseWorkspaceMutation(for: itemID) }
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
        guard (!imports.isEmpty || priorFailures > 0),
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

        // A provisional workspace stays memory-only until its first material is
        // actually stored. Revision zero publishes the owner and its first
        // material in one store transaction after any bytes are staged, so a
        // cancelled or unreadable drop cannot leave a ghost card behind.
        var current = item(withID: itemID)

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
                    itemID,
                    current?.revision ?? 0,
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
                upsert(refreshed)
                if selectedItemID != refreshed.id {
                    provisionalWorkspaceID = nil
                    selectedItemID = refreshed.id
                }
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
    /// It resolves the owner's latest revision immediately before mutation, so
    /// opening a picker never leaves a stale editor draft as hidden authority.
    func reattachWorkspaceMaterial(
        _ material: WorkboardMaterialSnapshot,
        in itemID: UUID,
        with replacement: WorkboardMaterialImport
    ) async {
        await acquireWorkspaceMutation(for: itemID)
        defer { releaseWorkspaceMutation(for: itemID) }
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
                itemID,
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
            upsert(refreshed)
            presentWorkspaceImportReport(WorkboardWorkspaceImportReport(addedCount: 1, failedCount: 0))
        } catch {
            presentWorkspaceCaptureFailure(error)
        }
    }

    private func acquireWorkspaceMutation(for itemID: UUID) async {
        if workspaceMutationItemID == nil {
            workspaceMutationItemID = itemID
            return
        }
        await withCheckedContinuation { continuation in
            workspaceMutationWaiters.append(WorkspaceMutationWaiter(
                itemID: itemID,
                continuation: continuation
            ))
        }
    }

    private func releaseWorkspaceMutation(for itemID: UUID) {
        guard workspaceMutationItemID == itemID else { return }
        guard !workspaceMutationWaiters.isEmpty else {
            workspaceMutationItemID = nil
            return
        }
        let next = workspaceMutationWaiters.removeFirst()
        workspaceMutationItemID = next.itemID
        next.continuation.resume()
    }

    func shapeEditorDraft() async {
        guard let shapeDraft = dependencies.shapeDraft, !isShapingDraft else { return }
        isShapingDraft = true
        do {
            editorSuggestion = try await shapeDraft(editingDraft)
        } catch {
            notice = WorkboardNotice(
                kind: .error,
                title: LocalizedStringResource("workboard.shape.failed.title", defaultValue: "Couldn’t shape this brief"),
                message: error.localizedDescription
            )
        }
        isShapingDraft = false
    }

    func applyEditorSuggestion() {
        guard let suggestion = editorSuggestion else { return }
        // Materials, revision and identity remain the original draft's; the
        // assistant is allowed to shape words, never mutate persistence identity.
        editingDraft.title = suggestion.title
        editingDraft.objective = suggestion.objective
        editingDraft.context = suggestion.context
        editingDraft.desiredResult = suggestion.desiredResult
        editingDraft.constraints = suggestion.constraints
        editorSuggestion = nil
    }

    func showPreflight(itemID: UUID) async {
        if gateways.isEmpty {
            do {
                let roster = try await dependencies.loadGateways()
                gateways = roster.0
                customGateways = roster.1
            } catch {
                notice = WorkboardNotice(
                    kind: .error,
                    title: LocalizedStringResource("workboard.gateway.load.failed.title", defaultValue: "Gateways unavailable"),
                    message: error.localizedDescription
                )
                return
            }
        }
        guard selectedItemID == itemID,
              items.contains(where: { $0.id == itemID }) else { return }
        preflightItemID = itemID
        // Deliberately no auto-selection. Even one configured destination is a
        // choice the person confirms at the irreversible boundary.
        selectedGatewayID = nil
        excludedMaterialIDs = []
    }

    func selectGateway(_ gateway: WorkboardGatewayChoice) {
        selectedGatewayID = gateway.id
    }

    func isMaterialSupported(_ material: WorkboardMaterialSnapshot) -> Bool {
        selectedGateway?.supports(material) ?? true
    }

    func isMaterialIncluded(_ material: WorkboardMaterialSnapshot) -> Bool {
        isMaterialSupported(material) && !excludedMaterialIDs.contains(material.id)
    }

    func setMaterial(_ material: WorkboardMaterialSnapshot, included: Bool) {
        guard isMaterialSupported(material) else { return }
        if included {
            excludedMaterialIDs.remove(material.id)
        } else {
            excludedMaterialIDs.insert(material.id)
        }
    }

    var includedPreflightMaterialIDs: Set<UUID> {
        guard let item = preflightItem else { return [] }
        return Set(item.materials.filter(isMaterialIncluded).map(\.id))
    }

    var preflightPrompt: String {
        guard let item = preflightItem else { return "" }
        return WorkboardPromptComposer.compose(
            item: item,
            includedMaterialIDs: includedPreflightMaterialIDs
        )
    }

    func dispatchPreflight() async {
        guard !isDispatching,
              let item = preflightItem,
              let gateway = selectedGateway else { return }
        isDispatching = true
        let request = WorkboardDispatchRequest(
            itemID: item.id,
            expectedRevision: item.revision,
            gatewayRef: gateway.ref,
            prompt: preflightPrompt,
            includedMaterialIDs: item.materials
                .filter(isMaterialIncluded)
                .map(\.id),
            includedMaterialVersions: item.materials
                .filter(isMaterialIncluded)
                .map { WorkboardMaterialVersion(id: $0.id, revision: $0.revision) }
                .sorted { $0.id.uuidString < $1.id.uuidString }
        )
        do {
            let receipt = try await dependencies.dispatch(request)
            upsert(receipt.item)
            selectedItemID = receipt.item.id
            preflightItemID = nil
            selectedGatewayID = nil
            excludedMaterialIDs = []
        } catch {
            notice = WorkboardNotice(
                kind: .error,
                title: LocalizedStringResource("workboard.dispatch.failed.title", defaultValue: "Nothing was sent"),
                message: error.localizedDescription
            )
        }
        isDispatching = false
    }

    func requestDelete(_ item: WorkboardItemSnapshot) {
        confirmation = WorkboardConfirmation(kind: .delete, itemID: item.id, itemTitle: item.displayTitle)
    }

    func requestDuplicate(_ item: WorkboardItemSnapshot) {
        confirmation = WorkboardConfirmation(kind: .duplicate, itemID: item.id, itemTitle: item.displayTitle)
    }

    /// Seeds the field with the STORED title, never `displayTitle`: a project
    /// named only by its first thought must open the field empty rather than
    /// invite the person to accept a name they never chose.
    func requestRename(_ item: WorkboardItemSnapshot) {
        renameDraftTitle = item.title
        renameRequest = WorkboardRenameRequest(id: item.id, originalTitle: item.title)
    }

    /// A name is brief content, so it is written through `saveDraft` — the same
    /// store write the brief itself uses, so the two can never persist a project
    /// differently. It takes the capture lane and CASes on the project's own
    /// revision exactly as a thought or a drop does, so renaming while an import
    /// is in flight is serialized rather than refused as stale. Every way this
    /// can fail says so: the alert is already gone by then, so a silent refusal
    /// would leave the old name on screen with nothing to explain it.
    @discardableResult
    func commitRename() async -> Bool {
        guard let request = renameRequest else { return false }
        let title = renameDraftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        renameRequest = nil
        renameDraftTitle = ""
        guard title != request.originalTitle else { return false }
        await acquireWorkspaceMutation(for: request.id)
        defer { releaseWorkspaceMutation(for: request.id) }
        guard let current = item(withID: request.id) else {
            notice = WorkboardNotice(
                kind: .error,
                title: LocalizedStringResource(
                    "workboard.action.failed.title",
                    defaultValue: "Couldn’t update the board"
                ),
                message: String(localized: LocalizedStringResource(
                    "workboard.item.missing.message",
                    defaultValue: "It may have been deleted on another device."
                ))
            )
            return false
        }
        var draft = WorkboardEditDraft(item: current)
        draft.title = title
        do {
            upsert(try await dependencies.saveDraft(draft))
            return true
        } catch is CancellationError {
            return false
        } catch {
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

    /// Board footprint only, like a card resize: pin goes through its own
    /// revision-neutral store path instead of the brief write, so a one-swipe
    /// gesture can never make a sent brief look changed, invalidate an approved
    /// preflight, or re-sort the lane by modification time. It still takes the
    /// capture lane, because an import landing on the same project republishes
    /// the whole snapshot. A row that has already left the board refuses in
    /// silence — a swipe on something that just vanished must not shout.
    @discardableResult
    func setPinned(_ isPinned: Bool, for itemID: UUID) async -> Bool {
        guard let setPinned = dependencies.setPinned else { return false }
        await acquireWorkspaceMutation(for: itemID)
        defer { releaseWorkspaceMutation(for: itemID) }
        guard let current = item(withID: itemID) else { return false }
        guard current.isPinned != isPinned else { return true }
        do {
            upsert(try await setPinned(itemID, current.isPinned, isPinned))
            return true
        } catch is CancellationError {
            return false
        } catch {
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

    func performConfirmation() async {
        guard let confirmation else { return }
        self.confirmation = nil
        do {
            switch confirmation.kind {
            case .delete:
                try await dependencies.deleteItem(confirmation.itemID)
                items.removeAll { $0.id == confirmation.itemID }
                if selectedItemID == confirmation.itemID { selectedItemID = nil }
            case .duplicate:
                let copy = try await dependencies.duplicateItem(confirmation.itemID)
                upsert(copy)
                selectedItemID = copy.id
            }
        } catch {
            notice = WorkboardNotice(
                kind: .error,
                title: LocalizedStringResource("workboard.action.failed.title", defaultValue: "Couldn’t update the board"),
                message: error.localizedDescription
            )
        }
    }

    /// Reorder a card in the sketch's global project strip. The planner admits
    /// cross-lifecycle moves but never cross-pin moves, so dragging a Needs You
    /// card changes only where it is presented—not what its linked Chat proves.
    @discardableResult
    func reorderItem(
        _ itemID: UUID,
        relativeTo targetItemID: UUID,
        placement: WorkboardReorderPlacement = .before
    ) async -> Bool {
        guard let request = WorkboardBoardOrdering.request(
            moving: itemID,
            relativeTo: targetItemID,
            placement: placement,
            in: items
        ) else { return false }
        return await performBoardReorder(request)
    }

    /// Keyboard/Switch Control/VoiceOver equivalent to direct manipulation.
    @discardableResult
    func moveItem(_ itemID: UUID, direction: WorkboardMoveDirection) async -> Bool {
        guard let request = WorkboardBoardOrdering.request(
            moving: itemID,
            direction: direction,
            in: items,
            visibleItemIDs: Set(projectStripItems.map(\.id))
        ) else { return false }
        return await performBoardReorder(request)
    }

    private func performBoardReorder(_ request: WorkItemBoardReorder) async -> Bool {
        guard !isReorderingBoard else { return false }
        isReorderingBoard = true
        let desiredPositions = request.desiredPositions
        applyBoardPositions(desiredPositions)

        do {
            let refreshed = try await dependencies.reorderItems(request)
            for item in refreshed { upsert(item) }
            isReorderingBoard = false
            return true
        } catch {
            // The drag is optimistic for direct-manipulation responsiveness. On
            // conflict, prefer the latest private-store order; if that read also
            // fails, restore only the rank fields captured before this drag.
            if let latest = try? await dependencies.loadItems() {
                items = latest
            } else {
                applyBoardPositions(request.expectedPositions)
            }
            notice = WorkboardNotice(
                kind: .error,
                title: LocalizedStringResource(
                    "workboard.action.failed.title",
                    defaultValue: "Couldn’t update the board"
                ),
                message: error.localizedDescription
            )
            isReorderingBoard = false
            return false
        }
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
    /// owner revision: a resize is presentation, so it must never make a sent
    /// brief look changed or invalidate an open preflight.
    @discardableResult
    func setMaterialCardSize(
        _ size: WorkMaterialCardSize,
        materialID: UUID,
        in itemID: UUID
    ) async -> Bool {
        guard let setCardSize = dependencies.setMaterialCardSize,
              let itemIndex = items.firstIndex(where: { $0.id == itemID }),
              let materialIndex = items[itemIndex].materials
                  .firstIndex(where: { $0.id == materialID }) else { return false }
        let previous = items[itemIndex].materials[materialIndex].cardSize
        guard previous != size else { return true }
        items[itemIndex].materials[materialIndex].cardSize = size
        do {
            try await setCardSize(itemID, materialID, size)
            return true
        } catch {
            if let index = items.firstIndex(where: { $0.id == itemID }),
               let materialIndex = items[index].materials
                   .firstIndex(where: { $0.id == materialID }) {
                items[index].materials[materialIndex].cardSize = previous
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

    /// Board-scoped removal. `removeMaterial(_:from:)` is the editor's form —
    /// it is keyed to `editingDraft` and flushes it first, so calling it from a
    /// board whose brief is closed would be a silent no-op. This one takes the
    /// capture lane and CASes on the item's own revision instead, and only
    /// touches the editor when that same item happens to be open.
    @discardableResult
    func removeMaterialFromBoard(_ materialID: UUID, in itemID: UUID) async -> Bool {
        await acquireWorkspaceMutation(for: itemID)
        defer { releaseWorkspaceMutation(for: itemID) }
        guard let current = item(withID: itemID),
              current.materials.contains(where: { $0.id == materialID }) else { return false }
        do {
            let refreshed = try await dependencies.removeMaterial(
                itemID,
                current.revision,
                materialID
            )
            upsert(refreshed)
            if editingDraft.id == itemID {
                refreshEditorAfterMaterialMutation(refreshed)
            }
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
    /// canonical prompt order under the owner's optimistic revision, so a drag
    /// racing an import would otherwise be refused as stale.
    private func performMaterialReorder(
        in itemID: UUID,
        plan: ([WorkboardMaterialSnapshot]) -> [UUID]?
    ) async -> Bool {
        guard let reorderMaterials = dependencies.reorderMaterials else { return false }
        await acquireWorkspaceMutation(for: itemID)
        defer { releaseWorkspaceMutation(for: itemID) }
        guard let current = item(withID: itemID),
              let orderedIDs = plan(current.materials) else { return false }

        let previousMaterials = current.materials
        applyMaterialOrder(orderedIDs, in: itemID)
        do {
            let refreshed = try await reorderMaterials(itemID, orderedIDs, current.revision)
            upsert(refreshed)
            if editingDraft.id == itemID {
                refreshEditorAfterMaterialMutation(refreshed)
            }
            return true
        } catch {
            // The drag is optimistic for direct-manipulation responsiveness. On
            // conflict, prefer the latest private-store order; if that read also
            // fails, restore only the order captured before this drag.
            if let latest = try? await dependencies.loadItems() {
                items = latest
            } else {
                applyMaterials(previousMaterials, in: itemID)
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
    private func applyMaterialOrder(_ orderedIDs: [UUID], in itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        let byID = Dictionary(
            items[index].materials.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var reordered = orderedIDs.compactMap { byID[$0] }
        guard reordered.count == items[index].materials.count else { return }
        for position in reordered.indices {
            reordered[position].sequence = position
        }
        items[index].materials = reordered
    }

    private func applyMaterials(_ materials: [WorkboardMaterialSnapshot], in itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].materials = materials
    }

    private func applyBoardPositions(_ positions: [WorkItemBoardPosition]) {
        let byID = Dictionary(uniqueKeysWithValues: positions.map { ($0.id, $0) })
        for index in items.indices {
            guard let position = byID[items[index].id] else { continue }
            items[index].boardOrder = position.boardOrder
        }
    }

    func transition(_ item: WorkboardItemSnapshot, to state: WorkItemState) async {
        do {
            upsert(try await dependencies.setState(item.id, state))
        } catch {
            notice = WorkboardNotice(
                kind: .error,
                title: LocalizedStringResource("workboard.action.failed.title", defaultValue: "Couldn’t update the board"),
                message: error.localizedDescription
            )
        }
    }

    func acknowledge(_ run: WorkboardRunSnapshot, in item: WorkboardItemSnapshot) async {
        guard run.needsReview,
              run.canAcknowledgeReview,
              let resultKey = run.reviewResultKey else { return }
        do {
            let refreshed = try await dependencies.acknowledgeRun(item.id, run.id, resultKey)
            upsert(refreshed)
        } catch {
            notice = WorkboardNotice(
                kind: .error,
                title: LocalizedStringResource(
                    "workboard.review.acknowledge.failed.title",
                    defaultValue: "Couldn’t mark this result reviewed"
                ),
                message: error.localizedDescription
            )
        }
    }

    func openConversation(for item: WorkboardItemSnapshot) {
        guard let conversationID = item.latestRun?.conversationID else { return }
        dependencies.openConversation(conversationID)
    }

    func openMaterial(_ material: WorkboardMaterialSnapshot) {
        dependencies.openMaterial(material)
    }

    func openGatewaySettings() {
        dependencies.openGatewaySettings()
    }

    func presentBriefing() {
        briefing = WorkboardPresentationLogic.briefing(from: items)
    }

    func openFromBriefing(_ item: WorkboardItemSnapshot) {
        briefing = nil
        selectedItemID = item.id
    }

    func toggleBriefingSpeech() async {
        if isReadingBriefing {
            dependencies.stopBriefingAloud?()
            isReadingBriefing = false
            return
        }
        guard let briefing else { return }
        guard let read = dependencies.readBriefingAloud else { return }
        isReadingBriefing = true
        await read(briefing.spokenText)
        isReadingBriefing = false
    }

    /// Adopts a snapshot returned by one operation without letting it undo a
    /// newer read. A dispatch receipt is built from the value the store held at
    /// prepare time and can land after a corrective `load()`; dropping it when
    /// the board already holds a strictly newer revision keeps the late receipt
    /// from resurrecting the stale card. Equal revisions still adopt the
    /// incoming value — both describe the same `updatedAt`, and the operation's
    /// own result carries facts the store cannot report yet.
    private func upsert(_ item: WorkboardItemSnapshot) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else {
            items.append(item)
            return
        }
        guard items[index].revision <= item.revision else { return }
        items[index] = item
    }

    /// Material persistence advances the owner's optimistic revision before the
    /// next debounced field save. Refresh both the editor token and the visible
    /// card atomically so the subsequent autosave cannot reject its own edit as
    /// stale. Material mutation itself is already durable, so it becomes the new
    /// saved fingerprint rather than manufacturing a redundant reorder save.
    private func refreshEditorAfterMaterialMutation(_ item: WorkboardItemSnapshot) {
        upsert(item)
        // The mutation is an optimistic CAS against the whole card. Adopt the
        // returned canonical fields as well as its materials/revision so a
        // newer CloudKit value fetched at the boundary can never be silently
        // overwritten by stale editor fields on the next keystroke.
        editingDraft = WorkboardEditDraft(item: item)
        lastSavedFingerprint = editingDraft.contentFingerprint
        editorWasPersisted = true
    }

    func resolveEditorConflictBySavingCopy() async {
        do {
            let copy = try await dependencies.saveDraftAsCopy(editingDraft)
            upsert(copy)
            editorConflict = nil
            editorPresented = false
            selectedItemID = copy.id
        } catch {
            notice = WorkboardNotice(
                kind: .error,
                title: LocalizedStringResource(
                    "workboard.conflict.copy.failed.title",
                    defaultValue: "Couldn’t save a copy"
                ),
                message: error.localizedDescription
            )
        }
    }

    func resolveEditorConflictByReloading() async {
        do {
            let refreshed = try await dependencies.loadItems()
            items = refreshed
            editorConflict = nil
            if let latest = refreshed.first(where: { $0.id == editingDraft.id }) {
                editingDraft = WorkboardEditDraft(item: latest)
                lastSavedFingerprint = editingDraft.contentFingerprint
                editorWasPersisted = true
            } else {
                editorPresented = false
                selectedItemID = nil
            }
        } catch {
            notice = WorkboardNotice(
                kind: .error,
                title: LocalizedStringResource(
                    "workboard.conflict.reload.failed.title",
                    defaultValue: "Couldn’t load the latest brief"
                ),
                message: error.localizedDescription
            )
        }
    }
}
