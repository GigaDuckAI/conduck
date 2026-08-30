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

enum WorkboardItemState: String, CaseIterable, Codable, Hashable, Sendable {
    case draft
    case waiting
    case review
    case done

    var title: LocalizedStringResource {
        switch self {
        case .draft:
            return LocalizedStringResource("workboard.state.draft", defaultValue: "Draft")
        case .waiting:
            return LocalizedStringResource("workboard.state.waiting", defaultValue: "Waiting")
        case .review:
            return LocalizedStringResource("workboard.state.review", defaultValue: "Review")
        case .done:
            return LocalizedStringResource("workboard.state.done", defaultValue: "Done")
        }
    }

    var systemImage: String {
        switch self {
        case .draft: return "square.and.pencil"
        case .waiting: return "hourglass"
        case .review: return "sparkle.magnifyingglass"
        case .done: return "checkmark.circle.fill"
        }
    }

    /// Human-attention order, independent from persistence ordering.
    nonisolated var attentionRank: Int {
        switch self {
        case .review: return 0
        case .waiting: return 1
        case .draft: return 2
        case .done: return 3
        }
    }
}

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
    var state: WorkboardItemState
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

    init(
        id: UUID = UUID(),
        title: String = "",
        objective: String = "",
        context: String = "",
        desiredResult: String = "",
        constraints: String = "",
        reviewBy: Date? = nil,
        state: WorkboardItemState = .draft,
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

enum WorkboardGatewayAvailability: Hashable, Sendable {
    case ready
    case configured(String)
    case limited(String)
    case unavailable(String)

    var isUsable: Bool {
        if case .unavailable = self { return false }
        return true
    }
}

struct WorkboardGatewayChoice: Identifiable, Hashable, Sendable {
    var id: String { ref.rawString }
    var ref: RemoteAgentRef
    var name: String
    var detail: String
    var capabilities: Set<WorkboardGatewayCapability>
    var availability: WorkboardGatewayAvailability
    var isRecommended: Bool

    init(
        ref: RemoteAgentRef,
        name: String,
        detail: String,
        capabilities: Set<WorkboardGatewayCapability> = [.text],
        availability: WorkboardGatewayAvailability = .ready,
        isRecommended: Bool = false
    ) {
        self.ref = ref
        self.name = name
        self.detail = detail
        self.capabilities = capabilities.union([.text])
        self.availability = availability
        self.isRecommended = isRecommended
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
            .filter { needle.isEmpty || searchCorpus(for: $0).localizedStandardContains(needle) }
            .sorted(by: attentionSort)
    }

    nonisolated static func items(
        in state: WorkboardItemState,
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
            .filter { needle.isEmpty || searchCorpus(for: $0).localizedStandardContains(needle) }
            .sorted(by: projectStripSort)
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

    nonisolated static func searchCorpus(for item: WorkboardItemSnapshot) -> String {
        let materials = item.materials.flatMap { [$0.name, $0.detail ?? "", $0.textContent ?? ""] }
        let runs = item.runs.flatMap {
            [$0.gatewayName, $0.resultMarkdown ?? "", $0.failureMessage ?? "", $0.sentPrompt]
        }
        return ([item.title, item.objective, item.context, item.desiredResult, item.constraints] + materials + runs)
            .joined(separator: "\n")
    }

    nonisolated static func briefing(from items: [WorkboardItemSnapshot], now: Date = Date()) -> WorkboardBriefingSnapshot {
        let needsYou = Self.items(in: .review, from: items)
        let waiting = Self.items(in: .waiting, from: items)
        let allDrafts = Self.items(in: .draft, from: items)
        // A visible briefing should surface a manageable set, while its spoken
        // counts remain complete and come from the canonical deterministic builder.
        let drafts = Array(allDrafts.prefix(3))
        let failureCount = needsYou.filter { $0.latestRun?.state == .failed }.count
        let canonicalBriefing = WorkboardBriefingBuilder.build(
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
            spokenText: canonicalBriefing.spokenText
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
                    sequence: material.sequence
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
        var setState: @MainActor (UUID, WorkboardItemState) async throws -> WorkboardItemSnapshot
        var acknowledgeRun: @MainActor (UUID, UUID, String) async throws -> WorkboardItemSnapshot
        var dispatch: @MainActor (WorkboardDispatchRequest) async throws -> WorkboardDispatchReceipt
        var openConversation: @MainActor (UUID) -> Void
        var openMaterial: @MainActor (WorkboardMaterialSnapshot) -> Void
        var openGatewaySettings: @MainActor () -> Void
        var scheduleReviewReminder: @MainActor (
            UUID,
            Date
        ) async -> WorkboardReviewReminderScheduleResult
        var cancelReviewReminder: @MainActor (UUID) async -> Void
        var captureVoice: (@MainActor () async throws -> String)?
        var shapeDraft: (@MainActor (WorkboardEditDraft) async throws -> WorkboardEditDraft)?
        var readBriefingAloud: (@MainActor (String) async -> Void)?
        var stopBriefingAloud: (@MainActor () -> Void)?

        init(
            loadItems: @escaping @MainActor () async throws -> [WorkboardItemSnapshot],
            loadGateways: @escaping @MainActor () async throws -> ([WorkboardGatewayChoice], [CustomGateway]),
            saveDraft: @escaping @MainActor (WorkboardEditDraft) async throws -> WorkboardItemSnapshot,
            saveDraftAsCopy: @escaping @MainActor (WorkboardEditDraft) async throws -> WorkboardItemSnapshot,
            importMaterial: @escaping @MainActor (
                UUID,
                Int64,
                WorkboardMaterialImport,
                @escaping @Sendable (Double) -> Void
            ) async throws -> WorkboardItemSnapshot,
            removeMaterial: @escaping @MainActor (UUID, Int64, UUID) async throws -> WorkboardItemSnapshot,
            replaceMaterial: @escaping @MainActor (
                UUID,
                Int64,
                UUID,
                WorkboardMaterialImport,
                @escaping @Sendable (Double) -> Void
            ) async throws -> WorkboardItemSnapshot,
            deleteItem: @escaping @MainActor (UUID) async throws -> Void,
            duplicateItem: @escaping @MainActor (UUID) async throws -> WorkboardItemSnapshot,
            setState: @escaping @MainActor (UUID, WorkboardItemState) async throws -> WorkboardItemSnapshot,
            acknowledgeRun: @escaping @MainActor (UUID, UUID, String) async throws -> WorkboardItemSnapshot,
            dispatch: @escaping @MainActor (WorkboardDispatchRequest) async throws -> WorkboardDispatchReceipt,
            openConversation: @escaping @MainActor (UUID) -> Void,
            openMaterial: @escaping @MainActor (WorkboardMaterialSnapshot) -> Void,
            openGatewaySettings: @escaping @MainActor () -> Void,
            scheduleReviewReminder: @escaping @MainActor (
                UUID,
                Date
            ) async -> WorkboardReviewReminderScheduleResult = { itemID, date in
                await WorkboardReviewReminderScheduler.shared.scheduleFromUserAction(
                    itemID: itemID,
                    at: date
                )
            },
            cancelReviewReminder: @escaping @MainActor (UUID) async -> Void = { itemID in
                await WorkboardReviewReminderScheduler.shared.cancel(itemID: itemID)
            },
            captureVoice: (@MainActor () async throws -> String)? = nil,
            shapeDraft: (@MainActor (WorkboardEditDraft) async throws -> WorkboardEditDraft)? = nil,
            readBriefingAloud: (@MainActor (String) async -> Void)? = nil,
            stopBriefingAloud: (@MainActor () -> Void)? = nil,
            reorderItems: @escaping @MainActor (
                WorkItemBoardReorder
            ) async throws -> [WorkboardItemSnapshot] = { _ in [] }
        ) {
            self.loadItems = loadItems
            self.loadGateways = loadGateways
            self.saveDraft = saveDraft
            self.saveDraftAsCopy = saveDraftAsCopy
            self.importMaterial = importMaterial
            self.removeMaterial = removeMaterial
            self.replaceMaterial = replaceMaterial
            self.deleteItem = deleteItem
            self.duplicateItem = duplicateItem
            self.reorderItems = reorderItems
            self.setState = setState
            self.acknowledgeRun = acknowledgeRun
            self.dispatch = dispatch
            self.openConversation = openConversation
            self.openMaterial = openMaterial
            self.openGatewaySettings = openGatewaySettings
            self.scheduleReviewReminder = scheduleReviewReminder
            self.cancelReviewReminder = cancelReviewReminder
            self.captureVoice = captureVoice
            self.shapeDraft = shapeDraft
            self.readBriefingAloud = readBriefingAloud
            self.stopBriefingAloud = stopBriefingAloud
        }
    }

    private let dependencies: Dependencies

    var items: [WorkboardItemSnapshot] = []
    var gateways: [WorkboardGatewayChoice] = []
    var customGateways: [CustomGateway] = []
    var isLoading = false
    var loadError: String?
    var searchText = ""
    var filter: WorkboardFilter = .open
    var prefersColumns = true
    var isReorderingBoard = false
    var selectedItemID: UUID?
    /// A canvas identity that has not written a Core Data row yet. New Work is
    /// therefore instant, but abandoning an untouched canvas never leaves an
    /// "Untitled" ghost behind. The first thought or material persists it.
    var provisionalWorkspaceID: UUID?

    var editorPresented = false
    var editingDraft = WorkboardEditDraft()
    var editorIsSaving = false
    var materialImportProgress: Double?
    var workspaceImportState: WorkboardWorkspaceImportState?
    /// One visible capture mutation at a time. The queue is global because a
    /// single view model owns all optimistic WorkItem revisions and a person can
    /// switch projects while an async picker/save is still finishing.
    var workspaceMutationItemID: UUID?
    /// Session-local composer drafts keyed by project. Keeping these above the
    /// detail view means switching projects or collapsing the split view never
    /// discards half-written work.
    var workspaceComposerDrafts: [UUID: String] = [:]
    var editorSavedAt: Date?
    var editorSuggestion: WorkboardEditDraft?
    var editorConflict: WorkboardEditorConflict?
    var isShapingDraft = false
    var isCapturingVoice = false
    var voiceCaptureTarget: WorkboardVoiceTarget?
    var isUpdatingReviewReminder = false

    var preflightItemID: UUID?
    var selectedGatewayID: String?
    var excludedMaterialIDs: Set<UUID> = []
    var isDispatching = false

    var briefing: WorkboardBriefingSnapshot?
    var isReadingBriefing = false
    var notice: WorkboardNotice?
    var workspaceStatus: WorkboardTransientStatus?
    var confirmation: WorkboardConfirmation?

    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var lastSavedFingerprint = ""
    @ObservationIgnored private var editorWasPersisted = false
    @ObservationIgnored private var loadRequestedWhileLoading = false
    @ObservationIgnored private var workspaceMutationWaiters: [WorkspaceMutationWaiter] = []

    private struct WorkspaceMutationWaiter {
        let itemID: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    var visibleItems: [WorkboardItemSnapshot] {
        WorkboardPresentationLogic.visibleItems(items, filter: filter, searchText: searchText)
    }

    var projectStripItems: [WorkboardItemSnapshot] {
        WorkboardPresentationLogic.projectStripItems(items, filter: filter, searchText: searchText)
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
    /// Voice is a complete first-party capture surface. The optional dependency
    /// remains available to deterministic previews/tests, but production uses
    /// the interactive recorder sheet so the person explicitly starts/stops.
    var canCaptureVoice: Bool { true }
    var canReadBriefing: Bool { dependencies.readBriefingAloud != nil }

    func isImportingIntoWorkspace(_ itemID: UUID) -> Bool {
        // Every capture mutation is serialized because each success advances an
        // optimistic owner revision. Disable capture everywhere, not only on the
        // project that owns the current progress indicator.
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
        }
        provisionalWorkspaceID = nil
    }

    /// Creates the lightest possible project and opens its capture canvas. The
    /// structured editor remains an optional refinement step, never the price of
    /// jotting down a first thought or dropping a first file.
    @discardableResult
    func createWorkspace(id: UUID = UUID()) async -> WorkboardItemSnapshot? {
        if let existing = item(withID: id) {
            selectedItemID = id
            return existing
        }
        do {
            let saved = try await dependencies.saveDraft(WorkboardEditDraft(id: id))
            upsert(saved)
            provisionalWorkspaceID = nil
            selectedItemID = saved.id
            return saved
        } catch {
            presentWorkspaceCaptureFailure(error)
            return nil
        }
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

    func showNewEditor() {
        autosaveTask?.cancel()
        editingDraft = WorkboardEditDraft()
        lastSavedFingerprint = editingDraft.contentFingerprint
        editorWasPersisted = false
        editorSavedAt = nil
        editorSuggestion = nil
        editorPresented = true
    }

    func showEditor(for item: WorkboardItemSnapshot) {
        autosaveTask?.cancel()
        editingDraft = WorkboardEditDraft(item: item)
        lastSavedFingerprint = editingDraft.contentFingerprint
        editorWasPersisted = true
        editorSavedAt = item.modifiedAt
        editorSuggestion = nil
        editorPresented = true
    }

    func noteEditorChanged() {
        guard editorPresented, editingDraft.contentFingerprint != lastSavedFingerprint else { return }
        autosaveTask?.cancel()
        guard editingDraft.isMeaningful || editorWasPersisted else { return }
        autosaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            _ = await self?.saveEditorNow(showFailure: true)
        }
    }

    func setReviewReminderEnabled(_ enabled: Bool) async {
        guard !isUpdatingReviewReminder else { return }
        if enabled {
            guard editingDraft.isMeaningful || editorWasPersisted else {
                notice = WorkboardNotice(
                    kind: .information,
                    title: LocalizedStringResource(
                        "workboard.reminder.needsBrief.title",
                        defaultValue: "Add the brief first"
                    ),
                    message: String(localized: LocalizedStringResource(
                        "workboard.reminder.needsBrief.message",
                        defaultValue: "Write what you want to review, then turn on the reminder."
                    ))
                )
                return
            }
            let proposed = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
            await persistAndScheduleReviewReminder(proposed, revertingTo: nil)
        } else {
            let previous = editingDraft.reviewBy
            guard previous != nil else { return }
            isUpdatingReviewReminder = true
            editingDraft.reviewBy = nil
            guard await saveEditorNow(showFailure: true) else {
                editingDraft.reviewBy = previous
                isUpdatingReviewReminder = false
                return
            }
            await dependencies.cancelReviewReminder(editingDraft.id)
            isUpdatingReviewReminder = false
        }
    }

    func setReviewReminderDate(_ date: Date) async {
        guard !isUpdatingReviewReminder,
              let previous = editingDraft.reviewBy,
              date != previous else { return }
        await persistAndScheduleReviewReminder(date, revertingTo: previous)
    }

    private func persistAndScheduleReviewReminder(
        _ date: Date,
        revertingTo previous: Date?
    ) async {
        isUpdatingReviewReminder = true
        editingDraft.reviewBy = date
        guard await saveEditorNow(showFailure: true) else {
            editingDraft.reviewBy = previous
            isUpdatingReviewReminder = false
            return
        }
        let result = await dependencies.scheduleReviewReminder(editingDraft.id, date)
        guard result == .scheduled else {
            editingDraft.reviewBy = previous
            _ = await saveEditorNow(showFailure: true)
            if previous == nil {
                await dependencies.cancelReviewReminder(editingDraft.id)
            }
            let denied = result == .notAuthorized
            notice = WorkboardNotice(
                kind: .information,
                title: denied
                    ? LocalizedStringResource(
                        "workboard.reminder.permission.title",
                        defaultValue: "Reminders are off"
                    )
                    : LocalizedStringResource(
                        "workboard.reminder.failed.title",
                        defaultValue: "Reminder not scheduled"
                    ),
                message: String(localized: denied
                    ? LocalizedStringResource(
                        "workboard.reminder.permission.message",
                        defaultValue: "Allow notifications for Conduck in System Settings, then try again. The brief was saved without a reminder."
                    )
                    : LocalizedStringResource(
                        "workboard.reminder.failed.message",
                        defaultValue: "The system could not add that reminder. The brief was saved without changing its reminder."
                    ))
            )
            isUpdatingReviewReminder = false
            return
        }
        isUpdatingReviewReminder = false
    }

    @discardableResult
    func saveEditorNow(showFailure: Bool) async -> Bool {
        autosaveTask?.cancel()
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
                editorSavedAt = Date()
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

    @discardableResult
    func closeEditor() async -> Bool {
        guard await saveEditorNow(showFailure: false) else { return false }
        editorPresented = false
        return true
    }

    /// Explicit escape hatch after a save failure. It abandons only the
    /// in-memory edits; any prior autosave remains durable and untouched.
    func discardUnsavedEditorChanges() {
        autosaveTask?.cancel()
        notice = nil
        editorConflict = nil
        editorSuggestion = nil
        editorPresented = false
    }

    func reviewEditorAndSend() async {
        guard editingDraft.isReadyToSend else { return }
        guard await saveEditorNow(showFailure: true) else { return }
        let itemID = editingDraft.id
        editorPresented = false
        await Task.yield()
        await showPreflight(itemID: itemID)
    }

    func importMaterial(
        _ materialImport: WorkboardMaterialImport,
        into itemID: UUID
    ) async {
        // Pickers and PhotosUI can finish after their editor has disappeared.
        // Bind every mutation to the brief that launched it; never consult a
        // later editor's ID after an actor suspension.
        guard editingDraft.id == itemID else { return }
        guard await flushEditorBeforeMaterialMutation() else { return }
        guard !Task.isCancelled, editingDraft.id == itemID else { return }
        materialImportProgress = 0
        defer {
            if editingDraft.id == itemID { materialImportProgress = nil }
        }
        do {
            let refreshed = try await dependencies.importMaterial(
                itemID,
                editingDraft.baseRevision,
                materialImport
            ) { progress in
                Task { @MainActor [self] in
                    guard self.editingDraft.id == itemID else { return }
                    self.materialImportProgress = min(1, max(0, progress))
                }
            }
            // The bytes are durable even if cancellation arrived while the
            // repository call was completing. Refresh the card, but only adopt
            // it into the editor when that editor still owns the same brief.
            upsert(refreshed)
            guard editingDraft.id == itemID else { return }
            refreshEditorAfterMaterialMutation(refreshed)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, editingDraft.id == itemID else { return }
            notice = WorkboardNotice(
                kind: .error,
                title: LocalizedStringResource("workboard.material.import.failed.title", defaultValue: "Couldn’t add material"),
                message: error.localizedDescription
            )
        }
    }

    /// Appends one chat-like thought without turning capture into execution.
    /// The first thought becomes the objective so a fresh workspace is useful;
    /// later thoughts remain independent note materials in the chronological
    /// source shelf. Either path is durable before this method returns.
    @discardableResult
    func addWorkspaceThought(_ rawValue: String, to itemID: UUID) async -> Bool {
        let thought = WorkboardWorkspaceCaptureLogic.normalizedThought(rawValue)
        guard !thought.isEmpty else { return false }

        await acquireWorkspaceMutation(for: itemID)
        defer { releaseWorkspaceMutation(for: itemID) }
        return await addWorkspaceThoughtUnlocked(thought, to: itemID)
    }

    private func addWorkspaceThoughtUnlocked(_ thought: String, to itemID: UUID) async -> Bool {
        guard let item = item(withID: itemID) else {
            var draft = WorkboardEditDraft(id: itemID)
            draft.objective = thought
            draft.title = WorkboardWorkspaceCaptureLogic.title(for: thought)
            do {
                let saved = try await dependencies.saveDraft(draft)
                upsert(saved)
                provisionalWorkspaceID = nil
                selectedItemID = saved.id
                return true
            } catch {
                presentWorkspaceCaptureFailure(error)
                return false
            }
        }

        if item.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var draft = WorkboardEditDraft(item: item)
            draft.objective = thought
            if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.title = WorkboardWorkspaceCaptureLogic.title(for: thought)
            }
            do {
                let saved = try await dependencies.saveDraft(draft)
                upsert(saved)
                return true
            } catch {
                presentWorkspaceCaptureFailure(error)
                return false
            }
        }

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
    /// a half-written thought.
    @discardableResult
    func reviewWorkspaceAndSend(itemID: UUID) async -> Bool {
        guard await flushWorkspaceComposer(itemID: itemID) else { return false }
        guard selectedItemID == itemID,
              item(withID: itemID)?.isReadyToSend == true else { return false }
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

    func removeMaterial(
        _ material: WorkboardMaterialSnapshot,
        from itemID: UUID
    ) async {
        guard editingDraft.id == itemID else { return }
        guard await flushEditorBeforeMaterialMutation() else { return }
        guard !Task.isCancelled, editingDraft.id == itemID else { return }
        do {
            let refreshed = try await dependencies.removeMaterial(
                itemID,
                editingDraft.baseRevision,
                material.id
            )
            upsert(refreshed)
            guard editingDraft.id == itemID else { return }
            refreshEditorAfterMaterialMutation(refreshed)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, editingDraft.id == itemID else { return }
            notice = WorkboardNotice(
                kind: .error,
                title: LocalizedStringResource("workboard.material.remove.failed.title", defaultValue: "Couldn’t remove material"),
                message: error.localizedDescription
            )
        }
    }

    func reattachMaterial(
        _ material: WorkboardMaterialSnapshot,
        with replacement: WorkboardMaterialImport,
        in itemID: UUID
    ) async {
        guard editingDraft.id == itemID else { return }
        guard await flushEditorBeforeMaterialMutation() else { return }
        guard !Task.isCancelled, editingDraft.id == itemID else { return }
        materialImportProgress = 0
        defer {
            if editingDraft.id == itemID { materialImportProgress = nil }
        }
        do {
            let refreshed = try await dependencies.replaceMaterial(
                itemID,
                editingDraft.baseRevision,
                material.id,
                replacement
            ) { progress in
                Task { @MainActor [self] in
                    guard self.editingDraft.id == itemID else { return }
                    self.materialImportProgress = min(1, max(0, progress))
                }
            }
            upsert(refreshed)
            guard editingDraft.id == itemID else { return }
            refreshEditorAfterMaterialMutation(refreshed)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, editingDraft.id == itemID else { return }
            if let repositoryError = error as? WorkboardLiveRepositoryError,
               repositoryError == .staleDraft || repositoryError == .itemNotFound {
                editorConflict = WorkboardEditorConflict(message: error.localizedDescription)
                return
            }
            notice = WorkboardNotice(
                kind: .error,
                title: LocalizedStringResource(
                    "workboard.material.reattach.failed.title",
                    defaultValue: "Couldn’t reattach material"
                ),
                message: error.localizedDescription
            )
        }
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

    func captureVoice(into target: WorkboardVoiceTarget) async {
        guard let captureVoice = dependencies.captureVoice, !isCapturingVoice else { return }
        isCapturingVoice = true
        do {
            let transcript = try await captureVoice().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else {
                isCapturingVoice = false
                return
            }
            switch target {
            case .objective:
                editingDraft.objective = appending(transcript, to: editingDraft.objective)
            case .context:
                editingDraft.context = appending(transcript, to: editingDraft.context)
            }
            noteEditorChanged()
        } catch {
            notice = WorkboardNotice(
                kind: .error,
                title: LocalizedStringResource("workboard.voice.failed.title", defaultValue: "Voice capture stopped"),
                message: error.localizedDescription
            )
        }
        isCapturingVoice = false
    }

    func presentVoiceCapture(for target: WorkboardVoiceTarget) {
        guard !isCapturingVoice else { return }
        voiceCaptureTarget = target
    }

    func applyVoiceTranscript(_ rawTranscript: String, to target: WorkboardVoiceTarget) {
        let transcript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return }
        switch target {
        case .objective:
            editingDraft.objective = appending(transcript, to: editingDraft.objective)
        case .context:
            editingDraft.context = appending(transcript, to: editingDraft.context)
        }
        voiceCaptureTarget = nil
        noteEditorChanged()
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
        noteEditorChanged()
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
        guard gateway.availability.isUsable else { return }
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
              let gateway = selectedGateway,
              gateway.availability.isUsable else { return }
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

    func canMoveItem(_ itemID: UUID, direction: WorkboardMoveDirection) -> Bool {
        WorkboardBoardOrdering.request(
            moving: itemID,
            direction: direction,
            in: items,
            visibleItemIDs: Set(projectStripItems.map(\.id))
        ) != nil
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

    private func applyBoardPositions(_ positions: [WorkItemBoardPosition]) {
        let byID = Dictionary(uniqueKeysWithValues: positions.map { ($0.id, $0) })
        for index in items.indices {
            guard let position = byID[items[index].id] else { continue }
            items[index].boardOrder = position.boardOrder
        }
    }

    func transition(_ item: WorkboardItemSnapshot, to state: WorkboardItemState) async {
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

    private func upsert(_ item: WorkboardItemSnapshot) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
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
        editorSavedAt = item.modifiedAt
    }

    private func flushEditorBeforeMaterialMutation() async -> Bool {
        autosaveTask?.cancel()
        while editorIsSaving {
            guard !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await saveEditorNow(showFailure: true)
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
                editorSavedAt = latest.modifiedAt
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

    private func appending(_ addition: String, to existing: String) -> String {
        let clean = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? addition : "\(clean)\n\n\(addition)"
    }
}
