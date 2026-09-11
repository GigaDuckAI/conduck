// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardViewModel.swift
//
// Presentation boundary for the private desk. Work is ONE desk at a
// compile-time id, so this model holds a single board and loads nothing else:
// a project row written by a build that predates the desk stays in the store
// and never reaches a screen. Because there is only one board, no operation
// here takes a board id — the desk is the subject of every one of them.
// The UI deliberately depends on immutable snapshots and injected async
// operations instead of Core Data objects, so the persistence layer can evolve
// its schema without leaking managed-object lifetimes into SwiftUI.
//
// The boundary, stated precisely: every operation writes to the person's own
// private stores, and those stores carry the desk's metadata — and the payload
// bytes eligible for it — through the person's private iCloud to their other
// devices. Capture placement shares each new material's transaction; retries
// never reassign a standing card, so later user filing wins. A missing project
// retries that item unfiled and names the recoverable location explicitly. If
// even that write fails, the composer keeps its input and voice keeps its clip.
// Nothing here is sent to an AI or to a Conduck-operated server: this
// model has no transport of any kind, and there is no server of ours anywhere.

import Foundation
import SwiftUI

// MARK: - Presentation snapshots

enum WorkboardMaterialKind: String, CaseIterable, Codable, Hashable, Sendable {
    case image
    case file
    case link
    case note
    // A recording is its own card shape, not a file that happens to be audible:
    // the board draws it with a transport, so a card that cannot play must be
    // impossible to reach through this kind.
    case audio
    // Spoken words with no recording behind them. It is a separate shape from
    // `.note` because the board owes the person the fact that these words were
    // SPOKEN — a typed note and a dictated one are read differently — and a
    // separate shape from `.audio` because there is nothing to play: routing it
    // through `.audio` would draw a transport over bytes that do not exist.
    case transcript

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
        case .audio:
            return LocalizedStringResource("workboard.material.audio", defaultValue: "Voice note")
        case .transcript:
            return LocalizedStringResource(
                "workboard.material.transcript",
                defaultValue: "Spoken note"
            )
        }
    }

    var systemImage: String {
        switch self {
        case .image: return "photo"
        case .file: return "doc"
        case .link: return "link"
        case .note: return "note.text"
        // `waveform` is reserved for the kinds that carry a transport, so the
        // glyph never promises playback the card cannot offer.
        case .audio: return "waveform"
        case .transcript: return "text.quote"
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

/// The recording drawn INSIDE the picture it names, carrying everything its own
/// card would have carried.
///
/// WHY A SEPARATE TYPE AND NOT A NESTED SNAPSHOT. A card that could hold a card
/// is a recursive value type, which has no size; and the fold refuses chains, so
/// a companion never has a companion of its own. This mirrors every field of
/// `WorkboardMaterialSnapshot` instead, and `material` gives the child back as
/// the card the board would have drawn standalone — which is what the routes
/// that act on ONE material are handed. Nothing here is projected a second
/// time: the fold builds this FROM the child's own snapshot, so the folded
/// recording and a standalone one are named, sized and gated identically.
///
/// `revision`, `mimeType` and `availability` are carried rather than trimmed
/// because Share and Open both re-read the store by id and then compare against
/// what the card claimed: a companion missing them could be shared under a
/// revision that no longer exists.
struct WorkboardCompanionSnapshot: Identifiable, Hashable, Sendable {
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
    var cardSize: WorkMaterialCardSize
    /// The picture this recording named. Kept after it resolves because it is
    /// the only thing on the card that says why this recording is here.
    var attachedToMaterialID: UUID?
    var createdAt: Date
    var revision: Int64

    init(_ material: WorkboardMaterialSnapshot) {
        self.id = material.id
        self.kind = material.kind
        self.name = material.name
        self.detail = material.detail
        self.textContent = material.textContent
        self.urlString = material.urlString
        self.mimeType = material.mimeType
        self.thumbnailData = material.thumbnailData
        self.byteCount = material.byteCount
        self.availability = material.availability
        self.sequence = material.sequence
        self.cardSize = material.cardSize
        self.attachedToMaterialID = material.attachedToMaterialID
        self.createdAt = material.createdAt
        self.revision = material.revision
    }

    /// The footprint this recording actually draws into. See
    /// `WorkboardMaterialSnapshot.renderedCardSize`.
    var renderedCardSize: WorkMaterialCardSize { WorkboardFootprint.rendered(cardSize) }

    /// The companion as its own card — the value Open, Share and Reattach take.
    /// It carries no companion of its own, which is the fold's no-chain rule
    /// stated in the type.
    var material: WorkboardMaterialSnapshot {
        WorkboardMaterialSnapshot(
            id: id,
            kind: kind,
            name: name,
            detail: detail,
            textContent: textContent,
            urlString: urlString,
            mimeType: mimeType,
            thumbnailData: thumbnailData,
            byteCount: byteCount,
            availability: availability,
            sequence: sequence,
            cardSize: cardSize,
            attachedToMaterialID: attachedToMaterialID,
            createdAt: createdAt,
            revision: revision
        )
    }
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
    /// The picture this card names, exactly as the store holds it — RAW, and
    /// resolved by nobody but `WorkboardCompanionFold`. A recording whose
    /// picture never landed keeps naming it and draws as its own card, which is
    /// correct rather than a defect.
    var attachedToMaterialID: UUID?
    var createdAt: Date
    var revision: Int64
    /// The recording folded into this picture, when one named it. Derived by
    /// the board build and by nothing else: it is absent from every capture
    /// draft and from the store, so it can never be written back.
    var companion: WorkboardCompanionSnapshot?

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
        attachedToMaterialID: UUID? = nil,
        createdAt: Date = Date(),
        revision: Int64 = 0,
        companion: WorkboardCompanionSnapshot? = nil
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
        self.attachedToMaterialID = attachedToMaterialID
        self.createdAt = createdAt
        self.revision = revision
        self.companion = companion
    }

    /// The footprint this card actually draws into.
    ///
    /// `cardSize` is what the ROW stores; this is what the BOARD grants, and
    /// the board grants one tile. Every face, every accessibility description
    /// and every geometry read asks here rather than reading `cardSize` or
    /// hardcoding `.standard` — a hardcoded answer is the same decision written
    /// in a place `WorkboardFootprint` cannot reach, so flipping the switch
    /// back would restore the grid without restoring the drawing.
    var renderedCardSize: WorkMaterialCardSize { WorkboardFootprint.rendered(cardSize) }
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
    /// Supplied only by a capture with visible context, before suspension. The
    /// live adapter carries it into the canonical material write transaction.
    var projectID: UUID? = nil

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

    /// The sheet's navigation title. It names the act the sheet performs —
    /// recording — because the recording itself becomes the card and the
    /// transcript is written onto it afterwards; a title promising only text
    /// would misdescribe what the user is about to keep.
    var title: LocalizedStringResource {
        switch self {
        case .context:
            return LocalizedStringResource(
                "workboard.voice.context",
                defaultValue: "Record a voice note"
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

/// A note the desk says once and takes back. Two kinds, because the board has
/// two things worth saying briefly and only one of them is good news: a capture
/// landed, or a move could not be kept.
///
/// A refused drag is deliberately NOT a `WorkboardNotice`. That channel is an
/// alert, and an alert answers a gesture the person has already completed with
/// a modal they have to dismiss before they can try again — for something the
/// board can simply show them by standing in the order the desk actually holds.
struct WorkboardTransientStatus: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Something the person asked for happened.
        case confirmation
        /// The desk moved underneath a gesture and kept its own order.
        case conflict
    }

    let id = UUID()
    let message: String
    var kind: Kind = .confirmation
}

/// Progress of the one import batch the desk can be running. There is a single
/// board, so the state names no owner: it exists while a batch is in flight and
/// is nil otherwise.
struct WorkboardImportState: Equatable {
    var completedCount: Int
    let totalCount: Int
    var failedCount: Int

    var progress: Double {
        guard totalCount > 0 else { return 0 }
        return min(1, max(0, Double(completedCount) / Double(totalCount)))
    }
}

struct WorkboardImportReport: Equatable, Sendable {
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
/// accessibility actions on the desk. The result is always a COMPLETE ordering
/// of the desk's materials, because the store rewrites dense sequence ranks
/// from the whole list under one owner-revision CAS.
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

/// Where one material id actually LIVES on a folded board, and how a complete
/// stored order is rebuilt from the cards the person can see.
///
/// A recording drawn inside its picture is NOT one of `materials` — it is that
/// card's `companion` — so the two things that address materials BY ID have to
/// account for it or folding silently breaks them:
///
/// - a route that resolves one id (open, share, reattach, a tap taken before the
///   board reloaded) finds nothing and falls back to a stale snapshot;
/// - a reorder omits the hidden recording, and the store refuses the whole
///   permutation because every logical id must appear exactly once.
///
/// Both answers live here so they cannot drift apart.
enum WorkboardDeskMember {
    /// The card, or the recording inside a card, that `id` names — or nil when
    /// the board carries neither.
    ///
    /// A companion comes back as `companion.material`: the child as its own
    /// card. That is what keeps every route SINGLE-material — each one
    /// validates and acts on exactly the member it was handed, and none of them
    /// has to learn that a card can contain another.
    /// Main-actor isolated, unlike its sibling below, only because
    /// `WorkboardCompanionSnapshot.material` is: it is a computed member of a
    /// board type. Nothing here needs an actor.
    static func find(
        _ id: UUID,
        among cards: [WorkboardMaterialSnapshot]
    ) -> WorkboardMaterialSnapshot? {
        if let card = cards.first(where: { $0.id == id }) { return card }
        for card in cards where card.companion?.id == id {
            return card.companion?.material
        }
        return nil
    }

    /// A displayed order (card ids, as dragged) expanded into the STORED order:
    /// each folded card becomes `[picture, recording]`, adjacent.
    ///
    /// `reorderWorkMaterials` rewrites dense ranks from a permutation that must
    /// contain every logical id exactly once, and adjacency is what makes the
    /// pair survive the rewrite as a pair. Expanding here — and never inserting
    /// a companion into the rendered array — is the whole of the displayed /
    /// persisted split: mosaic geometry, drag payloads and accessibility
    /// position counts stay displayed-only, and only the store request is
    /// complete.
    nonisolated static func expandedOrder(
        _ displayedIDs: [UUID],
        among cards: [WorkboardMaterialSnapshot]
    ) -> [UUID] {
        var companionByCard: [UUID: UUID] = [:]
        for card in cards {
            if let companion = card.companion { companionByCard[card.id] = companion.id }
        }
        guard !companionByCard.isEmpty else { return displayedIDs }
        var expanded: [UUID] = []
        expanded.reserveCapacity(displayedIDs.count + companionByCard.count)
        for id in displayedIDs {
            expanded.append(id)
            if let companionID = companionByCard[id] { expanded.append(companionID) }
        }
        return expanded
    }

    /// The board a drag was planned on, in the STORED order and with the
    /// companion links the desk held — the value a reorder rebases against.
    ///
    /// NOT `expandedOrder`. That is displayed order made complete, and the two
    /// differ exactly when a fold is involved: a recording published before its
    /// picture holds the lower rank, so a desk storing
    /// `recording, other, picture` draws `other, picture` and expands to
    /// `other, picture, recording`. Rebasing against that would report a
    /// rearrangement on a desk nothing had rearranged, and every drag on a
    /// folded board would be refused.
    ///
    /// The ranks come from the snapshots, so this must be read BEFORE the
    /// optimistic order is applied — `applyMaterialOrder` overwrites both a
    /// card's rank and its companion's with the dense ones the store is about
    /// to write.
    ///
    /// The sort is the same `(sequence, createdAt, id)` tuple the live
    /// repository's projection uses; a second comparator here would drift from
    /// it silently.
    nonisolated static func canonicalBaseline(
        among cards: [WorkboardMaterialSnapshot]
    ) -> WorkboardReorderBaseline {
        var keyed: [(id: UUID, sequence: Int, createdAt: Date)] = []
        var attachments: [UUID: UUID] = [:]
        keyed.reserveCapacity(cards.count)
        for card in cards {
            keyed.append((id: card.id, sequence: card.sequence, createdAt: card.createdAt))
            if let named = card.attachedToMaterialID { attachments[card.id] = named }
            guard let companion = card.companion else { continue }
            keyed.append((
                id: companion.id,
                sequence: companion.sequence,
                createdAt: companion.createdAt
            ))
            if let named = companion.attachedToMaterialID { attachments[companion.id] = named }
        }
        let order = keyed
            .sorted { ($0.sequence, $0.createdAt, $0.id.uuidString) < ($1.sequence, $1.createdAt, $1.id.uuidString) }
            .map(\.id)
        return WorkboardReorderBaseline(orderedIDs: order, attachments: attachments)
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
    /// Kept beside the capture draft so macOS hiding Work cannot discard an
    /// unfinished project editor or allow a second handoff owner on return.
    @ObservationIgnored private var cachedDeskWorkspace: WorkDeskWorkspaceState?
    var deskWorkspace: WorkDeskWorkspaceState {
        if let cachedDeskWorkspace { return cachedDeskWorkspace }
        let workspace = WorkDeskWorkspaceState()
        cachedDeskWorkspace = workspace
        return workspace
    }

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
        /// `(expectedDeskRevision, pictureID, recordingID) -> refreshed desk`.
        /// The ONE mutation behind a folded card's single Delete: two materials
        /// removed under one compare-and-swap. Two `removeMaterial` calls could
        /// not stand in for it — the first advances the very revision the second
        /// is holding, so the recording would outlive the picture it was drawn
        /// inside.
        ///
        /// `recordingID` is the companion the person was LOOKING at. Nothing
        /// below re-picks it; the store validates that exact pair and refuses a
        /// fold a sync has since undone.
        ///
        /// Defaulted to a refusal rather than declared optional: a board that
        /// never folds does not have to state it, while a board that folds and
        /// forgets to wire it fails where the person can see it instead of
        /// silently leaving half a card standing.
        var removeMaterialGroup: @MainActor (Int64, UUID, UUID) async throws -> WorkboardItemSnapshot = {
            _, _, _ in throw WorkboardLiveRepositoryError.itemNotFound
        }
        var replaceMaterial: @MainActor (
            Int64,
            UUID,
            WorkboardMaterialImport,
            @escaping @Sendable (Double) -> Void
        ) async throws -> WorkboardItemSnapshot
        var openMaterial: @MainActor (WorkboardMaterialSnapshot) -> Void
        /// Hand one card to the system's share UI. Defaulted to a no-op so a
        /// test board that never shares does not have to state one, and kept
        /// SEPARATE from `openMaterial` because the two verbs resolve a card
        /// differently: opening presents inside the app, sharing copies bytes
        /// out of it.
        var shareMaterial: @MainActor (WorkboardMaterialSnapshot) -> Void = { _ in }
        /// `(proposedMaterialIDs, baseline) -> refreshed desk`.
        ///
        /// Rewriting sequence is board content, so it advances the desk
        /// revision — but a drag is guarded by REBASE rather than by that
        /// revision. `baseline` is the canonical order and companion links the
        /// move was planned on, and the desk accepts the proposal when its own
        /// order is still that baseline with new ids appended, keeping both the
        /// move and whatever arrived while it was saving. A desk that moved any
        /// other way refuses, and the refusal is a note rather than an alert.
        ///
        /// No revision token: the revision has necessarily moved in exactly the
        /// case the rebase exists to accept, so carrying one would only give a
        /// caller a way to refuse a move the desk can keep.
        var reorderMaterials: (
            @MainActor ([UUID], WorkboardReorderBaseline) async throws -> WorkboardItemSnapshot
        )?
    }

    private let dependencies: Dependencies

    /// The one desk. Nil means no capture has created its row yet, which is
    /// what the empty-desk canvas draws; a legacy project row on a device that
    /// predates the desk is never loaded, so it can never appear here.
    private(set) var desk: WorkboardItemSnapshot?
    var isLoading = false
    var loadError: String?
    var importState: WorkboardImportState?
    /// Each destination owns its session-local draft above the detail view.
    /// Resolve directly from scope rather than an onChange callback: a submit
    /// in the same turn as navigation must never see the departing draft.
    var composerScope: WorkDeskScope { deskWorkspace.composerScope }
    var composerDraft: String { composerDraft(for: composerScope) }
    /// Whether the draft holds text that would survive normalization. It is
    /// stored on the scope's session rather than derived from `composerDraft`: a surface
    /// that only needs emptiness reads this and is invalidated when emptiness
    /// flips, not on every keystroke.
    var hasComposerDraft: Bool { deskWorkspace.composerSession(for: composerScope).hasDraft }

    var notice: WorkboardNotice?
    var workspaceStatus: WorkboardTransientStatus?

    /// True while a capture mutation holds the serialized lane.
    private(set) var isMutatingDesk = false

    /// How the desk draws its cards. It lives HERE rather than on the board
    /// view because a control that drives it can be declared above the canvas —
    /// in a toolbar that has no access to the board's own `@State`.
    ///
    /// Only the explicit setter persists. Resolving another scope, search or
    /// an accessibility fallback never writes back a preference. Session mode
    /// is observable, so both pickers and the board retain one effective value.
    var layoutMode: WorkboardLayoutMode {
        get { deskWorkspace.layoutSession(for: composerScope).mode }
        set {
            let scope = composerScope
            deskWorkspace.layoutSession(for: scope).mode = newValue
            newValue.save(for: scope)
        }
    }

    @ObservationIgnored private var loadRequestedWhileLoading = false
    @ObservationIgnored private var deskMutationWaiters: [CheckedContinuation<Void, Never>] = []

    init(dependencies: Dependencies, deskWorkspace: WorkDeskWorkspaceState? = nil) {
        self.dependencies = dependencies
        self.cachedDeskWorkspace = deskWorkspace
    }

    /// Every capture mutation is serialized because each success advances the
    /// desk's optimistic revision, so capture is disabled while any of them is
    /// in flight rather than only on the card showing progress.
    var isCapturingIntoDesk: Bool {
        isMutatingDesk || importState != nil
    }

    func setComposerDraft(_ value: String) {
        setComposerDraft(value, for: composerScope)
    }

    func composerDraft(for scope: WorkDeskScope) -> String {
        deskWorkspace.composerSession(for: scope).text
    }

    func setComposerDraft(_ value: String, for scope: WorkDeskScope) {
        deskWorkspace.composerSession(for: scope).setText(value)
    }

    /// Words returned for editing must be visible before the caller focuses
    /// the composer. Restore their launch project if it still exists; after
    /// deletion keep the words in All materials instead of an unreachable draft.
    func receiveComposerTranscript(_ transcript: String, in launchScope: WorkDeskScope) {
        let target: WorkDeskScope
        if case .project(let id) = launchScope,
           deskWorkspace.organization.project(id: id) == nil || WorkboardLayoutMode.isDeleted(launchScope) {
            target = .all
        } else {
            target = launchScope
        }
        if composerScope != target { deskWorkspace.selectScope(target) }
        let existing = composerDraft(for: target).trimmingCharacters(in: .whitespacesAndNewlines)
        setComposerDraft(existing.isEmpty ? transcript : "\(existing)\n\n\(transcript)", for: target)
    }

    /// A delayed save clears only the captured text in its original scope.
    /// Equal text elsewhere is a different draft; later edits stay intact.
    func clearComposerDraft(_ capturedText: String, in scope: WorkDeskScope) {
        guard composerDraft(for: scope) == capturedText else { return }
        setComposerDraft("", for: scope)
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

    /// Appends one chat-like thought without turning capture into execution.
    /// Every thought is a note card, so what the person typed stays a
    /// rearrangeable card. The thought is durable before this method returns.
    @discardableResult
    func addThought(_ rawValue: String, projectID: UUID? = nil) async -> Bool {
        let thought = WorkboardWorkspaceCaptureLogic.normalizedThought(rawValue)
        guard !thought.isEmpty else { return false }

        await acquireDeskMutation()
        defer { releaseDeskMutation() }
        return await addThoughtUnlocked(thought, projectID: projectID)
    }

    private func addThoughtUnlocked(_ thought: String, projectID: UUID?) async -> Bool {
        // One route for every thought, on the empty desk as much as on a desk
        // already full of cards. A first thought lands atomically: the store's
        // desk write publishes the desk row and the note in a single
        // transaction after any bytes are staged.
        let material = WorkboardMaterialImport(
            kind: .note,
            name: WorkboardWorkspaceCaptureLogic.noteTitle(for: thought),
            textContent: thought
        )
        let report = await importMaterialsUnlocked(
            [material],
            projectID: projectID,
            announcesResult: false
        )
        return report.addedCount == 1
    }

    /// Imports a drop/picker batch serially. Every successful mutation advances
    /// the desk's optimistic revision before the next item starts, preventing
    /// concurrent providers from racing each other into stale-draft failures.
    /// Partial success is never replayed as a whole batch, so a later retry
    /// cannot duplicate material the user already watched land.
    @discardableResult
    func importMaterials(
        _ imports: [WorkboardMaterialImport],
        projectID: UUID? = nil,
        additionalFailureCount: Int = 0,
        announcesResult: Bool = true
    ) async -> WorkboardImportReport {
        await acquireDeskMutation()
        defer { releaseDeskMutation() }
        return await importMaterialsUnlocked(
            imports,
            projectID: projectID,
            additionalFailureCount: additionalFailureCount,
            announcesResult: announcesResult
        )
    }

    private func importMaterialsUnlocked(
        _ imports: [WorkboardMaterialImport],
        projectID: UUID? = nil,
        additionalFailureCount: Int = 0,
        announcesResult: Bool = true
    ) async -> WorkboardImportReport {
        let priorFailures = max(0, additionalFailureCount)
        guard !imports.isEmpty || priorFailures > 0,
              importState == nil else {
            return WorkboardImportReport(
                addedCount: 0,
                failedCount: imports.count + priorFailures
            )
        }

        if imports.isEmpty {
            let report = WorkboardImportReport(addedCount: 0, failedCount: priorFailures)
            if announcesResult { presentImportReport(report) }
            return report
        }

        // The desk stays unwritten until its first material is actually stored:
        // an absent revision token means "create the row with this card", and
        // the store publishes both in one transaction after any bytes are
        // staged, so a cancelled or unreadable drop leaves no ghost desk.
        var current = desk

        importState = WorkboardImportState(
            completedCount: priorFailures,
            totalCount: imports.count + priorFailures,
            failedCount: priorFailures
        )
        var added = 0
        var savedOutsideProject = false
        var remainingProjectID = projectID
        var failed = priorFailures
        var firstFailure: Error?

        for (index, materialImport) in imports.enumerated() {
            guard !Task.isCancelled else {
                failed += imports.count - index
                break
            }
            do {
                var contextualImport = materialImport
                contextualImport.projectID = remainingProjectID
                let progress: @Sendable (Double) -> Void = { itemProgress in
                    Task { @MainActor [self] in
                        guard var state = self.importState else { return }
                        let bounded = min(1, max(0, itemProgress))
                        state.completedCount = min(
                            state.totalCount,
                            priorFailures + index + (bounded >= 1 ? 1 : 0)
                        )
                        self.importState = state
                    }
                }
                let refreshed: WorkboardItemSnapshot
                do {
                    refreshed = try await dependencies.importMaterial(
                        current?.revision, contextualImport, progress
                    )
                } catch WorkDeskStoreError.projectNotFound {
                    // The atomic write inserted nothing. A missing project is
                    // recoverable without losing input: save this same capture
                    // unfiled and keep the remaining batch unfiled too. The
                    // refusal may have already staged a large payload, so do
                    // not repeat that expensive probe for every later item.
                    remainingProjectID = nil
                    contextualImport.projectID = nil
                    refreshed = try await dependencies.importMaterial(
                        current?.revision, contextualImport, progress
                    )
                }
                if projectID != nil, remainingProjectID == nil { savedOutsideProject = true }
                current = refreshed
                adopt(refreshed)
                added += 1
            } catch {
                failed += 1
                if firstFailure == nil { firstFailure = error }
            }
            if var state = importState {
                state.completedCount = priorFailures + index + 1
                state.failedCount = failed
                importState = state
            }
        }

        importState = nil
        let report = WorkboardImportReport(addedCount: added, failedCount: failed)
        if announcesResult {
            presentImportReport(report)
        } else if report.hasFailures {
            presentCaptureFailure(
                firstFailure ?? WorkboardLiveRepositoryError.missingPayload
            )
        }
        if projectID != nil, added > 0 {
            // Read the transaction's placements into the visible workspace;
            // this never writes organization or overrides a later user move.
            await deskWorkspace.organization.reload()
        }
        if savedOutsideProject { presentCaptureSavedInAllMaterials(report: report) }
        return report
    }

    /// Shared with the microphone: success in a different location must be
    /// explicit, and must not be presented as a failure inviting duplication.
    func presentCaptureSavedInAllMaterials(
        report: WorkboardImportReport = WorkboardImportReport(addedCount: 1, failedCount: 0)
    ) {
        workspaceStatus = nil
        notice = WorkboardNotice(
            kind: .information,
            title: LocalizedStringResource(
                "workdesk.capture.project.failed.title", defaultValue: "Saved in All materials"
            ),
            message: report.hasFailures
                ? String.localizedStringWithFormat(
                    String(localized: LocalizedStringResource(
                        "workdesk.capture.project.atomic.partial.message",
                        defaultValue: "%1$lld added; %2$lld couldn’t be added. Some saved items couldn’t be placed in the project. Open All materials to organise them."
                    )), Int64(report.addedCount), Int64(report.failedCount)
                )
                : WorkVoiceCaptureCoordinator.savedInAllMaterialsMessage
        )
    }

    func presentImportReport(_ report: WorkboardImportReport) {
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

    private func presentCaptureFailure(_ error: Error) {
        notice = WorkboardNotice(
            kind: .error,
            title: LocalizedStringResource(
                "workboard.workspace.capture.failed.title",
                defaultValue: "Couldn’t add to Work"
            ),
            message: error.localizedDescription
        )
    }

    /// Reattaches a device-local source directly from the board. It resolves the
    /// desk's latest revision immediately before mutation, so a picker left open
    /// across a sync cannot write against a stale revision.
    ///
    /// The membership check reaches COMPANIONS as well as cards: a recording
    /// drawn inside its picture is not one of `materials`, and repairing its
    /// bytes is the one route a folded recording would otherwise lose. The
    /// replacement still names the recording's own id, so the store replaces
    /// that material and nothing else.
    func reattachMaterial(
        _ material: WorkboardMaterialSnapshot,
        with replacement: WorkboardMaterialImport
    ) async {
        await acquireDeskMutation()
        defer { releaseDeskMutation() }
        guard let current = desk,
              WorkboardDeskMember.find(material.id, among: current.materials) != nil else {
            presentCaptureFailure(WorkboardLiveRepositoryError.itemNotFound)
            return
        }
        importState = WorkboardImportState(
            completedCount: 0,
            totalCount: 1,
            failedCount: 0
        )
        defer { importState = nil }
        do {
            let refreshed = try await dependencies.replaceMaterial(
                current.revision,
                material.id,
                replacement
            ) { progress in
                Task { @MainActor [self] in
                    guard var state = self.importState else { return }
                    state.completedCount = progress >= 1 ? 1 : 0
                    self.importState = state
                }
            }
            adopt(refreshed)
            presentImportReport(WorkboardImportReport(addedCount: 1, failedCount: 0))
        } catch {
            presentCaptureFailure(error)
        }
    }

    /// One capture mutation at a time. The lane is a plain queue because every
    /// capture advances the same desk revision, so two of them in flight would
    /// race each other into stale-revision refusals.
    private func acquireDeskMutation() async {
        if !isMutatingDesk {
            isMutatingDesk = true
            return
        }
        await withCheckedContinuation { continuation in
            deskMutationWaiters.append(continuation)
        }
    }

    private func releaseDeskMutation() {
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
        toInsertionIndex index: Int
    ) async -> Bool {
        await performMaterialReorder { materials in
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
        placement: WorkboardReorderPlacement = .before
    ) async -> Bool {
        await performMaterialReorder { materials in
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
        direction: WorkboardMoveDirection
    ) async -> Bool {
        await performMaterialReorder { materials in
            WorkboardMaterialOrdering.order(
                moving: materialID,
                direction: direction,
                in: materials
            )
        }
    }

    /// Board-scoped removal. It takes the capture lane and CASes on the desk's
    /// own revision, so a removal racing an import is serialized rather than
    /// refused as stale. Removing the last card leaves the desk standing.
    @discardableResult
    func removeMaterialFromBoard(_ materialID: UUID) async -> Bool {
        await acquireDeskMutation()
        defer { releaseDeskMutation() }
        guard let current = desk,
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

    /// Removes a folded card — the picture and the recording drawn inside it —
    /// as ONE card, because that is what the person is deleting.
    ///
    /// `childID` is the companion the board DREW, handed down from the card the
    /// menu belonged to. Nothing here re-picks it: re-resolving the fold at
    /// confirmation time could delete a different recording from the one the
    /// person saw. The store validates the exact pair and refuses when a sync
    /// has undone the fold, which surfaces as the same notice any other refused
    /// removal does.
    ///
    /// Like `removeMaterialFromBoard` this is not optimistic — the card leaves
    /// the board when the store says both members are gone, so a refusal has
    /// nothing to roll back.
    @discardableResult
    func removeGroupFromBoard(parentID: UUID, childID: UUID) async -> Bool {
        await acquireDeskMutation()
        defer { releaseDeskMutation() }
        guard let current = desk,
              current.materials.contains(where: { $0.id == parentID }) else { return false }
        do {
            let refreshed = try await dependencies.removeMaterialGroup(
                current.revision,
                parentID,
                childID
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

    /// Reorder shares the capture lane with thoughts and drops, so a drag
    /// racing a local import is serialized rather than raced.
    ///
    /// The plan is made from the cards the person DRAGGED — displayed order —
    /// and expanded into the stored order immediately before the store call.
    /// The store requires every logical material id exactly once, so a folded
    /// recording that never entered the request would refuse an otherwise
    /// ordinary drag; and planning over the stored order instead would let the
    /// hidden recording occupy a slot the person cannot see.
    ///
    /// The desk is guarded by REBASE, not by a revision. The baseline is read
    /// after the lane is acquired and BEFORE the optimistic order is applied —
    /// `applyMaterialOrder` overwrites the very ranks the baseline is built
    /// from — and it is canonical rather than displayed, because a fold makes
    /// those two orders differ.
    ///
    /// Three outcomes, deliberately distinct. A cancellation is silent: nothing
    /// asked and nothing failed. A desk that moved in a way the drag cannot be
    /// replayed onto is a transient NOTE beside the board, which then simply
    /// shows the order the desk holds. Anything else — a store that could not
    /// write at all — keeps the alert, because that is a failure the person may
    /// need to act on.
    private func performMaterialReorder(
        plan: ([WorkboardMaterialSnapshot]) -> [UUID]?
    ) async -> Bool {
        guard let reorderMaterials = dependencies.reorderMaterials else { return false }
        await acquireDeskMutation()
        defer { releaseDeskMutation() }
        guard let current = desk,
              let orderedIDs = plan(current.materials) else { return false }

        let previousMaterials = current.materials
        let baseline = WorkboardDeskMember.canonicalBaseline(among: previousMaterials)
        let persistedIDs = WorkboardDeskMember.expandedOrder(
            orderedIDs,
            among: previousMaterials
        )
        applyMaterialOrder(orderedIDs)
        do {
            let refreshed = try await reorderMaterials(persistedIDs, baseline)
            adopt(refreshed)
            return true
        } catch {
            // Roll back only our own optimistic order, preserving newer sync
            // arrivals and presentation edits. Do this before the corrective
            // read so a missing or older snapshot cannot leave the failed
            // move on screen. A sync can also arrive while that read awaits.
            if desk?.revision == current.revision {
                restoreMaterialOrder(previousMaterials)
            }
            if let refreshed = try? await dependencies.loadDesk() {
                adopt(refreshed)
            }
            reportRefusedReorder(error)
            return false
        }
    }

    /// Says what a refused drag was, in the register the refusal deserves.
    private func reportRefusedReorder(_ error: any Error) {
        if error is CancellationError { return }
        if Self.isReorderConflict(error) {
            let message = String(localized: LocalizedStringResource(
                "workboard.reorder.conflict",
                defaultValue: "The desk changed while this move was saving, so the board kept its own order."
            ))
            workspaceStatus = WorkboardTransientStatus(message: message, kind: .conflict)
            AccessibilityAnnouncer.announce(message)
            return
        }
        notice = WorkboardNotice(
            kind: .error,
            title: LocalizedStringResource(
                "workboard.action.failed.title",
                defaultValue: "Couldn’t update the board"
            ),
            message: error.localizedDescription
        )
    }

    /// The one refusal that means "the desk moved", named at both layers it can
    /// arrive from: the store's own refusal, and the adapter's translation of
    /// it. Matched by case rather than by message so a reworded error cannot
    /// quietly turn a note back into an alert.
    private nonisolated static func isReorderConflict(_ error: any Error) -> Bool {
        if let repositoryError = error as? WorkboardLiveRepositoryError {
            return repositoryError == .staleDraft
        }
        if let storeError = error as? WorkboardStoreError {
            return storeError == .staleRevision
        }
        return false
    }

    /// Mirrors the store's dense rank rewrite so the optimistic board and the
    /// persisted sequence agree before the round trip completes.
    ///
    /// `orderedIDs` is DISPLAYED order and the array it writes stays displayed:
    /// a companion is never inserted as a card. The ranks are the EXPANDED
    /// ones, though — a folded card takes its own rank and hands the next one
    /// to the recording inside it — because that is exactly what the store
    /// writes for the same permutation, and an optimistic board that disagreed
    /// would flip cards around under the person when the real order arrived.
    private func applyMaterialOrder(_ orderedIDs: [UUID]) {
        guard let current = desk else { return }
        let byID = Dictionary(
            current.materials.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var reordered = orderedIDs.compactMap { byID[$0] }
        guard reordered.count == current.materials.count else { return }
        var rank = 0
        for position in reordered.indices {
            reordered[position].sequence = rank
            rank += 1
            if reordered[position].companion != nil {
                reordered[position].companion?.sequence = rank
                rank += 1
            }
        }
        desk?.materials = reordered
    }

    /// Puts a refused drag's board back the way it found it — the order AND the
    /// ranks it was planned on.
    ///
    /// `applyMaterialOrder` recomputes dense ranks because that is what the
    /// store is about to write. A rollback writes nothing, so the ranks to put
    /// back are the SAVED ones: a recording published before its picture is
    /// ranked before it, and reindexing the displayed cards would leave the
    /// board claiming ranks no row on disk holds.
    ///
    /// The cards themselves are the CURRENT ones, matched by id, so a resize
    /// that landed while the drag was in flight survives the rollback; only the
    /// two rank fields come from the saved copy.
    private func restoreMaterialOrder(_ saved: [WorkboardMaterialSnapshot]) {
        guard let current = desk else { return }
        let byID = Dictionary(
            current.materials.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let restored: [WorkboardMaterialSnapshot] = saved.compactMap { previous in
            guard var card = byID[previous.id] else { return nil }
            card.sequence = previous.sequence
            if let companion = previous.companion, card.companion?.id == companion.id {
                card.companion?.sequence = companion.sequence
            }
            return card
        }
        guard restored.count == current.materials.count else { return }
        desk?.materials = restored
    }

    func openMaterial(_ material: WorkboardMaterialSnapshot) {
        dependencies.openMaterial(material)
    }

    func shareMaterial(_ material: WorkboardMaterialSnapshot) {
        dependencies.shareMaterial(material)
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
