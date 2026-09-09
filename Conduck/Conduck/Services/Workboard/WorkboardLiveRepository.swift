// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardLiveRepository.swift
//
// Live adapter between the desk's presentation model and Conduck's private
// local/CloudKit store. It maps immutable Sendable records into UI snapshots and
// owns every write the desk can perform. Work is ONE desk at
// `Constants.workboardDeskItemID`: this adapter names that row itself, reads
// nothing else, and creates nothing — the store's desk write is what brings the
// row into existence on the first capture. Nothing here reaches the network:
// the desk is a private surface, so this adapter has no transport of any kind.

#if !os(watchOS)

import Foundation

@MainActor
final class WorkboardLiveRepository {
    private let store: ConversationStore
    private let captureDrainer: WorkCaptureDrainer
    private let openMaterialHandler: @MainActor (WorkboardMaterialSnapshot) -> Void
    private let shareMaterialHandler: @MainActor (WorkboardMaterialSnapshot) -> Void
    private var localThumbnailCache: [UUID: CachedLocalThumbnail] = [:]

    private struct CachedLocalThumbnail {
        let revision: Int64
        let data: Data
    }

    /// Keeps the all-work load bounded even if someone uses Work as a large
    /// visual scrapbook. Older sources remain fully available and openable;
    /// they simply fall back to their type icon until they become recent again.
    private static let maximumLiveLocalThumbnails = 96

    /// Decode window for the preview wave. Each job is uninterruptible CPU work
    /// on the shared cooperative pool, so the width is a courtesy to every other
    /// awaiting continuation in the process, not a throughput knob.
    private static let maximumConcurrentThumbnailDecodes = 4

    /// Opening a card and sharing one are the ONLY routes out of the desk this
    /// adapter carries, and both end at the person's own device. The desk
    /// reaches no conversation and no gateway: it is an inert surface, so a
    /// handler for either would be a door with nothing behind it.
    init(
        store: ConversationStore = .shared,
        captureInbox: WorkCaptureInbox = .shared,
        openMaterial: @escaping @MainActor (WorkboardMaterialSnapshot) -> Void,
        shareMaterial: @escaping @MainActor (WorkboardMaterialSnapshot) -> Void = { _ in }
    ) {
        self.store = store
        self.captureDrainer = WorkCaptureDrainer(
            inbox: captureInbox,
            store: store,
            sourceDevice: SourceDevice.current
        )
        self.openMaterialHandler = openMaterial
        self.shareMaterialHandler = shareMaterial
    }

    func makeDependencies() -> WorkboardViewModel.Dependencies {
        WorkboardViewModel.Dependencies(
            loadDesk: { [self] in try await loadDesk() },
            importMaterial: { [self] expectedRevision, material, onProgress in
                try await importMaterial(
                    material,
                    expectedDeskRevision: expectedRevision,
                    onProgress: onProgress
                )
            },
            removeMaterial: { [self] revision, materialID in
                try await removeMaterial(materialID, expectedRevision: revision)
            },
            removeMaterialGroup: { [self] revision, parentID, childID in
                try await removeMaterialGroup(
                    parentID: parentID,
                    childID: childID,
                    expectedRevision: revision
                )
            },
            replaceMaterial: { [self] revision, materialID, material, onProgress in
                try await replaceMaterial(
                    materialID,
                    expectedRevision: revision,
                    with: material,
                    onProgress: onProgress
                )
            },
            openMaterial: { [self] material in openMaterialHandler(material) },
            shareMaterial: { [self] material in shareMaterialHandler(material) },
            reorderMaterials: { [self] orderedMaterialIDs, baseline in
                try await reorderMaterials(orderedMaterialIDs, baseline: baseline)
            }
        )
    }

    /// Public so the personal-workbench capture coordinator can own one durable,
    /// serialized drain independently of cancelable UI refresh tasks.
    @discardableResult
    func drainCaptures() async throws -> WorkCaptureDrainer.Report {
        try await captureDrainer.drainAvailableCaptures()
    }

    // MARK: - Load + mapping

    /// The desk, or nil while no capture has created its row. The fetch names
    /// the fixed id, so duplicate physical desk rows arrive already unioned by
    /// the store and a legacy project row is never read at all.
    private func loadDesk() async throws -> WorkboardItemSnapshot? {
        // Keep this a cancelable read. Capture ownership belongs exclusively to
        // `WorkCaptureRefreshCoordinator`; allowing a view load to claim queue
        // bytes would let its own claim/ack notification cancel the caller.
        guard let record = try await store.fetchWorkItem(
            id: Constants.workboardDeskItemID
        ) else { return nil }
        return await snapshot(for: record)
    }

    /// Builds transient previews from the device-local vault. The resulting
    /// bytes exist only in this repository's memory and the presentation
    /// snapshot: they are never written back to Core Data and therefore never
    /// enter CloudKit. ImageIO reads directly from the file URL off the main
    /// actor, keeping both UI responsiveness and the no-synced-file-content
    /// privacy invariant intact.
    private func localPresentationThumbnails(
        for record: WorkItemRecord
    ) async -> [UUID: Data] {
        let candidates = record.materials
            .filter {
                $0.kind == .image
                    && $0.thumbnailData == nil
                    && $0.availability == .availableLocally
            }
            .sorted {
                ($0.updatedAt, $0.id.uuidString) > ($1.updatedAt, $1.id.uuidString)
            }
        let boundedCandidates = Array(candidates.prefix(Self.maximumLiveLocalThumbnails))
        // Every projection carries the whole desk, so an entry the wave no
        // longer wants is genuinely gone rather than merely out of view.
        let candidateIDs = Set(boundedCandidates.map(\.id))
        localThumbnailCache = localThumbnailCache.filter { candidateIDs.contains($0.key) }

        var result: [UUID: Data] = [:]
        var pending: [(id: UUID, revision: Int64, key: String)] = []
        for material in boundedCandidates {
            let revision = Self.revision(for: material.updatedAt)
            if let cached = localThumbnailCache[material.id], cached.revision == revision {
                result[material.id] = cached.data
                continue
            }
            // The record already carries its vault key, so the URL comes from one
            // vault hop for the whole wave rather than a store round-trip each.
            guard let key = material.localVaultKey else {
                localThumbnailCache.removeValue(forKey: material.id)
                continue
            }
            pending.append((material.id, revision, key))
        }
        guard !pending.isEmpty else { return result }

        let urlsByKey = await store.workAssetVault.urls(for: pending.map(\.key))
        var jobs: [(id: UUID, revision: Int64, url: URL)] = []
        for entry in pending {
            guard let url = urlsByKey[entry.key] else {
                localThumbnailCache.removeValue(forKey: entry.id)
                continue
            }
            jobs.append((entry.id, entry.revision, url))
        }

        // ImageIO downsampling never suspends, so an unbounded fan-out would hold
        // every cooperative thread and stall unrelated continuations.
        let decodeWidth = Self.maximumConcurrentThumbnailDecodes
        let generated = await withTaskGroup(
            of: (UUID, Int64, Data?).self,
            returning: [(UUID, Int64, Data?)].self
        ) { group in
            var next = 0
            while next < jobs.count, next < decodeWidth {
                let job = jobs[next]
                group.addTask {
                    (job.id, job.revision, ImageProcessor.thumbnailOnly(fromFileAt: job.url))
                }
                next += 1
            }
            var values: [(UUID, Int64, Data?)] = []
            while let value = await group.next() {
                values.append(value)
                guard next < jobs.count else { continue }
                let job = jobs[next]
                group.addTask {
                    (job.id, job.revision, ImageProcessor.thumbnailOnly(fromFileAt: job.url))
                }
                next += 1
            }
            return values
        }
        for (id, revision, data) in generated {
            guard let data else {
                localThumbnailCache.removeValue(forKey: id)
                continue
            }
            localThumbnailCache[id] = CachedLocalThumbnail(revision: revision, data: data)
            result[id] = data
        }
        return result
    }

    private func snapshot(for record: WorkItemRecord) async -> WorkboardItemSnapshot {
        let localThumbnails = await localPresentationThumbnails(for: record)
        return Self.snapshot(for: record, localThumbnails: localThumbnails)
    }

    /// Shared bit-exact projection used by autosave and transport revalidation.
    static func revision(for date: Date) -> Int64 {
        WorkboardRevision.value(for: date)
    }

    /// The desk as CARDS. Every stored material is projected first and the fold
    /// runs over the projections, so a recording drawn inside its picture is the
    /// same value it would be standing alone — the board never has a second,
    /// thinner description of a companion.
    ///
    /// The result is DISPLAYED order, not the stored order: a folded recording
    /// is absent from `materials` while its picture is present. Anything that
    /// must address every stored id — a reorder above all — expands the pair
    /// through `WorkboardCompanionFold` rather than reading this array.
    private static func snapshot(
        for record: WorkItemRecord,
        localThumbnails: [UUID: Data] = [:]
    ) -> WorkboardItemSnapshot {
        let cards = record.materials
            .sorted { ($0.sequence, $0.createdAt, $0.id.uuidString) < ($1.sequence, $1.createdAt, $1.id.uuidString) }
            .map { materialSnapshot($0, transientThumbnail: localThumbnails[$0.id]) }
        return WorkboardItemSnapshot(
            id: record.id,
            title: record.content.title,
            objective: record.content.objective,
            materials: WorkboardCompanionFold.fold(cards).displayed,
            revision: revision(for: record.updatedAt)
        )
    }

    /// One card as the STORE holds it at this instant, projected through the
    /// SAME mapping the board uses.
    ///
    /// This is what a share consults, before preparing and again before
    /// presenting. It deliberately does not read the board: `WorkboardViewModel`
    /// refreshes behind a 180 ms debounce, so a card that was deleted or
    /// replaced moments ago still passes a board-level check — while the byte
    /// read resolves the id against the store and returns the NEW bytes. The
    /// pairing that produces is the failure worth preventing: a replacement
    /// leaving the device under the previous revision's name and type.
    ///
    /// Metadata only: no payload is read, so this stays cheap enough to run
    /// twice per share regardless of how large the card is.
    static func currentMaterialSnapshot(
        id: UUID,
        store: ConversationStore = .shared
    ) async throws -> WorkboardMaterialSnapshot? {
        guard let record = try await store.fetchWorkMaterial(id: id) else { return nil }
        return materialSnapshot(record)
    }

    /// The record→snapshot projection, for a test that already holds records.
    /// Named for what it is so nothing in the app reaches for it: the app asks
    /// `currentMaterialSnapshot`, which is the store read AND this projection.
    static func presentationSnapshotForTesting(
        _ record: WorkMaterialRecord
    ) -> WorkboardMaterialSnapshot {
        materialSnapshot(record)
    }

    private static func materialSnapshot(
        _ record: WorkMaterialRecord,
        transientThumbnail: Data? = nil
    ) -> WorkboardMaterialSnapshot {
        WorkboardMaterialSnapshot(
            id: record.id,
            kind: presentationKind(record),
            name: materialName(record),
            detail: materialDetail(record),
            textContent: record.textContent,
            urlString: record.urlString,
            mimeType: record.mimeType,
            thumbnailData: record.thumbnailData ?? transientThumbnail,
            byteCount: record.byteSize > 0 ? record.byteSize : nil,
            availability: presentationAvailability(record),
            sequence: record.sequence,
            cardSize: record.cardSize,
            // Carried RAW. Whether it names anything is the fold's question,
            // and a single card read outside a board build has no desk to
            // answer it against.
            attachedToMaterialID: record.attachedToMaterialID,
            createdAt: record.createdAt,
            revision: revision(for: record.updatedAt)
        )
    }

    /// Whether a card may be opened, played or sent, from what the store says
    /// is behind it. Every state that is not readable bytes on THIS device
    /// collapses to `.unavailableOnThisDevice`, so the surface fails closed by
    /// construction rather than by each caller remembering to. Internal so the
    /// tests can drive the real mapping instead of a copy of it.
    static func presentationAvailability(
        _ record: WorkMaterialRecord
    ) -> WorkboardMaterialAvailability {
        switch record.availability {
        case .synced:
            return .available
        case .availableLocally:
            return .localOnly
        case .unavailableOnThisDevice:
            // Bytes this device will never hold unless the person reattaches
            // them fail closed: the card is visible provenance, and nothing may
            // be sent from a payload this device cannot read.
            return .unavailableOnThisDevice
        case .syncedPending:
            // Also unreadable, and also fails closed — but the bytes are on
            // their way through private CloudKit, so the card must not offer to
            // replace them. Waiting and damage are two different things to
            // show a person.
            return .syncPending
        case .metadataOnly:
            // Notes and links intentionally have no binary payload. A binary
            // metadata row without bytes is visible provenance, not sendable.
            switch record.kind {
            case .note, .link, .transcript:
                return .available
            case .image, .file, .audio, .unknown:
                return .unavailableOnThisDevice
            }
        }
    }

    /// The ONE mapping from a stored material to the kind its card claims to be.
    /// A stored kind is broader than the shapes a card can draw, so the
    /// narrowing happens here and nowhere else: a second transcription of this
    /// switch would let two surfaces disagree about what one record IS, and the
    /// disagreement would only ever be visible as a card drawn with the wrong
    /// icon and the wrong noun. Internal so the tests can drive the real mapping
    /// instead of a copy of it.
    ///
    /// Every kind a card can draw maps 1:1; only `.unknown` is decided by what
    /// the record carries, because that is the one stored kind this build has no
    /// shape for.
    static func presentationKind(_ record: WorkMaterialRecord) -> WorkboardMaterialKind {
        switch record.kind {
        case .image: return .image
        case .file: return .file
        // An attached recording IS its card: narrowing it to a file would draw
        // an openable document where a transport belongs, and the audio card
        // would never be reached.
        case .audio: return .audio
        case .link: return .link
        case .note: return .note
        // Spoken words keep their own shape rather than passing as a typed
        // note: they read as a note but they are not one, and the board's noun
        // and glyph are the only place a person is told which they are looking
        // at.
        case .transcript: return .transcript
        case .unknown: return record.filename != nil || record.hasPayload ? .file : .note
        }
    }

    /// Title, then filename, then the link's host, then the kind's own noun.
    /// Each candidate is judged on its trimmed form but emitted verbatim: the
    /// card owns the final normalization.
    static func materialName(_ record: WorkMaterialRecord) -> String {
        let candidates = [record.title, record.filename ?? ""]
        if let value = candidates.first(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return value
        }
        if let value = record.urlString,
           let host = URLComponents(string: value)?.host,
           !host.isEmpty {
            return host
        }
        switch presentationKind(record) {
        case .image:
            return String(localized: "workboard.material.image", defaultValue: "Image")
        case .file:
            return String(localized: "workboard.material.file", defaultValue: "File")
        case .link:
            return String(localized: "workboard.material.link", defaultValue: "Link")
        case .note:
            return String(localized: "workboard.material.note", defaultValue: "Note")
        case .audio:
            return String(localized: "workboard.material.audio", defaultValue: "Voice note")
        case .transcript:
            return String(localized: "workboard.material.transcript", defaultValue: "Spoken note")
        }
    }

    /// The card's second line: the person's caption, then the one thing worth
    /// saying about where its bytes are, then a size when there is nothing
    /// else. Internal so the tests can drive the real copy instead of a copy of
    /// it.
    static func materialDetail(_ record: WorkMaterialRecord) -> String? {
        var parts: [String] = []
        let caption = record.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if !caption.isEmpty { parts.append(caption) }

        switch record.availability {
        case .availableLocally:
            parts.append(String(
                localized: "workboard.material.localOnly",
                defaultValue: "Available on this device"
            ))
        case .unavailableOnThisDevice:
            parts.append(String(
                localized: "workboard.material.unavailableHere",
                defaultValue: "Reattach on this device to open"
            ))
        case .syncedPending:
            parts.append(String(
                localized: "workboard.material.syncPending",
                defaultValue: "Waiting for iCloud…"
            ))
        case .metadataOnly, .synced:
            break
        }

        if parts.isEmpty, record.byteSize > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: record.byteSize, countStyle: .file))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    /// Capture. Every card the person adds in the app lands here, and this is
    /// the only place the app's own capture writes: the store's desk op decides
    /// desk identity, creates the row on the first capture, ranks the card
    /// inside its own transaction and returns an existing card unchanged when a
    /// capture is replayed.
    ///
    /// `expectedDeskRevision` is the board revision the person was looking at,
    /// and nil when there is no desk to guard yet. It reaches the store as the
    /// compare-and-swap token — the view model's serialized lane is the only
    /// caller in the app that has one, because every headless capture lane
    /// would only drop work by refusing.
    private func importMaterial(
        _ material: WorkboardMaterialImport,
        expectedDeskRevision: Int64?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> WorkboardItemSnapshot {
        // Validate and prepare the material before the store opens a write.
        // Most failures therefore happen before anything is durable.
        let payload: Data?
        let sourceFileURL: URL?
        let textContent: String?
        let urlString: String?
        switch material.kind {
        case .image, .file, .audio:
            // A recording arrives carrying bytes or a file URL exactly as a
            // file does; only the shape it draws as differs.
            if let url = material.fileURL {
                payload = nil
                sourceFileURL = url
            } else {
                guard let data = material.data, !data.isEmpty else {
                    throw WorkboardLiveRepositoryError.missingPayload
                }
                payload = data
                sourceFileURL = nil
            }
            textContent = nil
            urlString = nil
        case .link:
            guard let value = material.urlString,
                  WorkCaptureEnvelope.isAcceptedWebURL(value) else {
                throw WorkboardLiveRepositoryError.invalidLink
            }
            payload = nil
            sourceFileURL = nil
            textContent = nil
            urlString = value
        // Typed words and spoken words are prepared identically: both are text
        // and nothing else, and an empty one is not a card either way.
        case .note, .transcript:
            let text = material.textContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { throw WorkboardLiveRepositoryError.emptyNote }
            payload = nil
            sourceFileURL = nil
            textContent = text
            urlString = nil
        }

        let draft = WorkMaterialDraft(
                id: material.id,
                kind: storageKind(material.kind),
                title: material.name,
                caption: material.detail ?? "",
                textContent: textContent,
                urlString: urlString,
                // Every payload-bearing kind keeps the name its bytes arrived
                // under — the same three the payload arm above accepts. It is
                // what Share and Open hand back to the system, so a recording
                // stripped of it exports as an unnamed blob.
                filename: material.kind == .image
                    || material.kind == .file
                    || material.kind == .audio ? material.name : nil,
                mimeType: material.mimeType,
                payload: payload,
                byteSize: material.byteCount ?? payload.map { Int64($0.count) },
                // Rank is deliberately not supplied: the store appends inside
                // the same transaction that inserts the card, which a count
                // read out here would race.
                sourceDevice: SourceDevice.current
        )
        do {
            _ = try await store.upsertDeskMaterial(
                draft,
                sourceFileURL: sourceFileURL,
                sourceFileByteSize: material.byteCount,
                expectedOwnerRevision: expectedDeskRevision,
                onProgress: onProgress
            )
        } catch let committed as WorkMaterialCommittedUnavailableError {
            // The card COMMITTED; only its bytes could not be proved readable
            // afterwards, and it is on the desk reading unavailable. Reporting
            // that as a failed import is what makes the person drop the same
            // file again — and every drop mints a FRESH material id, so the
            // repeat publishes a SECOND card beside the unreadable one instead
            // of repairing it. The desk is returned with the committed card on
            // it; the card's own availability is what says the bytes have not
            // landed, and a reattach onto that card is the repair.
            guard let refreshed = try await store.fetchWorkItem(
                id: Constants.workboardDeskItemID
            ), refreshed.materials.contains(where: { $0.id == committed.record.id }) else {
                // The card the error carries is not on the desk after all, so
                // there is nothing for the caller to adopt: this really is a
                // failed import.
                throw committed
            }
            return await snapshot(for: refreshed)
        } catch {
            if case WorkboardStoreError.staleRevision = error {
                throw WorkboardLiveRepositoryError.staleDraft
            }
            throw error
        }
        guard let refreshed = try await store.fetchWorkItem(
            id: Constants.workboardDeskItemID
        ) else {
            throw WorkboardLiveRepositoryError.itemNotFound
        }
        return await snapshot(for: refreshed)
    }

    private func storageKind(_ kind: WorkboardMaterialKind) -> WorkMaterialKind {
        switch kind {
        case .image: return .image
        case .file: return .file
        case .link: return .link
        case .note: return .note
        case .audio: return .audio
        case .transcript: return .transcript
        }
    }

    /// Board drag. The store owns the single sequence rewrite, so this only
    /// carries the baseline the move was planned on and re-projects the desk.
    ///
    /// The baseline REPLACES the revision token a capture would carry: a drag
    /// that raced an arrival is exactly the case worth keeping, so the desk is
    /// asked whether the move can be replayed onto what it now holds rather
    /// than whether nothing happened. `staleDraft` is what a desk that moved
    /// some other way comes back as, and the board answers it with a note.
    private func reorderMaterials(
        _ orderedMaterialIDs: [UUID],
        baseline: WorkboardReorderBaseline
    ) async throws -> WorkboardItemSnapshot {
        do {
            let saved = try await store.reorderWorkMaterials(
                itemID: Constants.workboardDeskItemID,
                orderedMaterialIDs: orderedMaterialIDs,
                baseline: baseline
            )
            return await snapshot(for: saved)
        } catch WorkboardStoreError.staleRevision {
            throw WorkboardLiveRepositoryError.staleDraft
        } catch WorkboardStoreError.itemNotFound {
            throw WorkboardLiveRepositoryError.itemNotFound
        }
    }

    /// Removes one card. The desk row itself is never deleted — an empty desk
    /// is the surface before its first capture, not a missing one.
    private func removeMaterial(
        _ materialID: UUID,
        expectedRevision: Int64
    ) async throws -> WorkboardItemSnapshot {
        guard let item = try await store.fetchWorkItem(
            id: Constants.workboardDeskItemID
        ) else {
            throw WorkboardLiveRepositoryError.itemNotFound
        }
        guard Self.revision(for: item.updatedAt) == expectedRevision else {
            throw WorkboardLiveRepositoryError.staleDraft
        }
        guard item.materials.contains(where: { $0.id == materialID }) else {
            throw WorkboardStoreError.invalidMaterialOwner
        }
        do {
            try await store.deleteWorkMaterial(
                id: materialID,
                workItemID: Constants.workboardDeskItemID,
                expectedOwnerRevision: expectedRevision
            )
        } catch WorkboardStoreError.staleRevision {
            throw WorkboardLiveRepositoryError.staleDraft
        }
        guard let refreshed = try await store.fetchWorkItem(
            id: Constants.workboardDeskItemID
        ) else {
            throw WorkboardLiveRepositoryError.itemNotFound
        }
        return await snapshot(for: refreshed)
    }

    /// Removes a folded card — a screenshot and the recording that names it —
    /// in ONE store mutation.
    ///
    /// The same shape as `removeMaterial` above and deliberately not a loop
    /// over it: two single deletes cannot share one compare-and-swap, and the
    /// first would advance the desk revision the second is holding, leaving the
    /// recording standing alone. `ConversationStore.deleteWorkMaterialGroup`
    /// owns the whole decision — this only carries the token, states which desk,
    /// and re-projects.
    ///
    /// `childID` travels from the displayed card unchanged; nothing here or
    /// below re-picks a companion. The pair itself is validated in the store,
    /// so a card whose fold has been undone by a sync since the person opened
    /// the menu refuses with `WorkboardStoreError.invalidMaterialCompanion`
    /// rather than removing half of it.
    func removeMaterialGroup(
        parentID: UUID,
        childID: UUID,
        expectedRevision: Int64
    ) async throws -> WorkboardItemSnapshot {
        guard let item = try await store.fetchWorkItem(
            id: Constants.workboardDeskItemID
        ) else {
            throw WorkboardLiveRepositoryError.itemNotFound
        }
        guard Self.revision(for: item.updatedAt) == expectedRevision else {
            throw WorkboardLiveRepositoryError.staleDraft
        }
        // BOTH members, on this desk. The store proves they are a pair; this
        // proves the board is talking about cards that are actually here.
        guard item.materials.contains(where: { $0.id == parentID }),
              item.materials.contains(where: { $0.id == childID }) else {
            throw WorkboardStoreError.invalidMaterialOwner
        }
        do {
            try await store.deleteWorkMaterialGroup(
                parentID: parentID,
                childID: childID,
                workItemID: Constants.workboardDeskItemID,
                expectedOwnerRevision: expectedRevision
            )
        } catch WorkboardStoreError.staleRevision {
            throw WorkboardLiveRepositoryError.staleDraft
        }
        guard let refreshed = try await store.fetchWorkItem(
            id: Constants.workboardDeskItemID
        ) else {
            throw WorkboardLiveRepositoryError.itemNotFound
        }
        return await snapshot(for: refreshed)
    }

    private func replaceMaterial(
        _ materialID: UUID,
        expectedRevision: Int64,
        with replacement: WorkboardMaterialImport,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> WorkboardItemSnapshot {
        guard let item = try await store.fetchWorkItem(
            id: Constants.workboardDeskItemID
        ) else {
            throw WorkboardLiveRepositoryError.itemNotFound
        }
        guard Self.revision(for: item.updatedAt) == expectedRevision,
              item.materials.contains(where: { $0.id == materialID }) else {
            throw WorkboardLiveRepositoryError.staleDraft
        }
        guard let sourceURL = replacement.fileURL else {
            throw WorkboardLiveRepositoryError.missingPayload
        }
        let byteSize = replacement.byteCount ?? -1
        do {
            // Reattachment replaces the payload and its metadata, and nothing
            // else: no extract, no preview. The arriving bytes are new bytes,
            // so the storage policy picks their lane afresh — within the
            // ceiling they ride private CloudKit as a blob, above it they stay
            // in the device-local vault — but a derived text extract or
            // thumbnail would put READABLE file content on the material row
            // itself, which is a different claim from the payload the person
            // chose to attach.
            guard try await store.replaceWorkMaterialPayloadFile(
                id: materialID,
                from: sourceURL,
                byteSize: byteSize,
                filename: replacement.name,
                mimeType: replacement.mimeType,
                sourceDevice: SourceDevice.current,
                expectedOwnerRevision: expectedRevision,
                onProgress: onProgress
            ) != nil else {
                throw WorkboardLiveRepositoryError.itemNotFound
            }
        } catch WorkboardStoreError.staleRevision {
            throw WorkboardLiveRepositoryError.staleDraft
        }
        guard let refreshed = try await store.fetchWorkItem(
            id: Constants.workboardDeskItemID
        ) else {
            throw WorkboardLiveRepositoryError.itemNotFound
        }
        return await snapshot(for: refreshed)
    }
}

enum WorkboardLiveRepositoryError: LocalizedError, Equatable {
    case itemNotFound
    case staleDraft
    case missingPayload
    case invalidLink
    case emptyNote

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return String(
                localized: "workboard.error.itemMissing",
                defaultValue: "This card is no longer available."
            )
        case .staleDraft:
            return String(
                localized: "workboard.error.staleDraft",
                defaultValue: "This card changed on another device. Reopen it to keep the latest version."
            )
        case .missingPayload:
            return String(
                localized: "workboard.error.missingPayload",
                defaultValue: "That file could not be read. Choose it again."
            )
        case .invalidLink:
            return String(
                localized: "workboard.error.invalidLink",
                defaultValue: "Add a complete http or https link."
            )
        case .emptyNote:
            return String(
                localized: "workboard.error.emptyNote",
                defaultValue: "Write something before adding the note."
            )
        }
    }
}

// MARK: - Companion fold

/// The ONE rule by which a spoken capture stops being its own card and becomes
/// part of the picture it names.
///
/// One press of Capture to Work publishes two materials — a picture and the
/// VOICE material of that same press — and the voice material carries the id of
/// the picture (`WorkMaterialDraft.attachedToMaterialID`). This turns that link
/// into what the person sees: one card, the picture, with the voice inside it.
///
/// THE VOICE MATERIAL IS EITHER SHAPE. A press whose recording is kept publishes
/// an `.audio`; a press whose words are kept without it publishes a
/// `.transcript`. Both are the same half of the same press, so both fold — a
/// rule that folded only the recording would leave every words-only capture as
/// a second card beside the picture it was spoken over.
///
/// A PROMISE ABOUT IDENTITY, NOT ABOUT EXISTENCE. The link is written whenever
/// the press carried a picture, even when the picture's own publication failed,
/// so a recording whose picture is not on the desk resolves to nothing here and
/// draws as its own card. That is CORRECT, not a defect: a retry that lands the
/// picture later needs no repair, because the recording already names it and the
/// next board build folds them.
///
/// TWO CANDIDATES AND NO MORE, in this order: the id the recording names, then
/// the one escape a colliding publication may have taken
/// (`WorkMaterialCollisionEscape` — there is deliberately no second escape, so
/// there is no third candidate).
///
/// FIRST ELIGIBLE, NEVER FIRST EXISTING. A row of another kind standing at the
/// named id is precisely WHY the picture escaped, so a candidate that fails the
/// conditions is skipped rather than ending the search. Stopping at it would
/// leave every collision-escaped pair permanently unfoldable.
///
/// The conditions, and each one's reason:
/// - the parent is on THIS desk (the array is the desk),
/// - the parent is an `.image` — the fold draws a picture with a recording in
///   it, and nothing else,
/// - the parent names no picture of its own — a chain is not a fold,
/// - the child is the press's voice material, `.audio` or `.transcript` — a
///   TYPED `.note` keeps its own card, because a folded note would lose its
///   full-text route and nothing spoke it over the picture,
/// - the recording names something OTHER than itself — a self-naming link
///   resolves to nothing at all, the escape candidate included.
///
/// SEVERAL RECORDINGS NAMING ONE PICTURE: the one with the lowest `uuidString`
/// folds and every other draws standalone. The choice is deliberately
/// independent of the ARRANGEMENT — picking by rank would let a drag on an
/// unrelated card hand the picture a different recording. NOTHING IS EVER
/// DISCARDED: every material this is given comes back, either as a card or as
/// exactly one picture's companion.
///
/// This mirrors `ConversationStore`'s own `eligibleCompanionPictureID`, which is
/// what the group delete validates against; the two must agree, and both state
/// the same five conditions in the same order.
enum WorkboardCompanionFold {

    /// The board's cards, in displayed order; the recordings that stopped being
    /// cards; and which recording each picture drew.
    ///
    /// `displayed` is what the desk renders and what a mosaic, a drag payload
    /// and an accessibility position count are computed from.
    /// `hiddenChildIDs` and `childByParent` are what a caller that must address
    /// every STORED material — a reorder — expands the pair with, so the store
    /// still receives every logical id exactly once.
    typealias Folded = (
        displayed: [WorkboardMaterialSnapshot],
        hiddenChildIDs: Set<UUID>,
        childByParent: [UUID: UUID]
    )

    /// Fold one desk's cards. Pure: same input, same output, no store, no clock.
    static func fold(_ materials: [WorkboardMaterialSnapshot]) -> Folded {
        // The desk almost never holds a linked voice material, and this is the
        // whole board build's hot path: without this exit every load would
        // derive an escape id per card for nothing.
        guard materials.contains(where: {
            ($0.kind == .audio || $0.kind == .transcript) && $0.attachedToMaterialID != nil
        }) else {
            return (materials, [], [:])
        }

        // First occurrence wins. Duplicate physical rows arrive already unioned
        // by the store, so this only decides a case that should not exist —
        // deterministically rather than by whichever copy came last.
        var byID: [UUID: WorkboardMaterialSnapshot] = [:]
        for material in materials where byID[material.id] == nil {
            byID[material.id] = material
        }

        // Gather every claimant before choosing one: the winner is the lowest
        // child id, which is not knowable until the last claimant is seen.
        var claimants: [UUID: [UUID]] = [:]
        for child in materials {
            guard child.kind == .audio || child.kind == .transcript,
                  let link = child.attachedToMaterialID else { continue }
            guard let parentID = eligibleParentID(link: link, child: child.id, among: byID)
            else { continue }
            claimants[parentID, default: []].append(child.id)
        }

        var childByParent: [UUID: UUID] = [:]
        for (parentID, children) in claimants {
            guard let winner = children.min(by: { $0.uuidString < $1.uuidString }) else { continue }
            childByParent[parentID] = winner
        }
        let hiddenChildIDs = Set(childByParent.values)

        // Displayed order is the INPUT order minus the folded recordings, so a
        // pair sits at the picture's rank and a recording that did not fold
        // keeps its own — including when it was published before its picture.
        var displayed: [WorkboardMaterialSnapshot] = []
        displayed.reserveCapacity(materials.count - hiddenChildIDs.count)
        for material in materials {
            guard !hiddenChildIDs.contains(material.id) else { continue }
            guard let childID = childByParent[material.id], let child = byID[childID] else {
                displayed.append(material)
                continue
            }
            var parent = material
            parent.companion = WorkboardCompanionSnapshot(child)
            displayed.append(parent)
        }
        return (displayed, hiddenChildIDs, childByParent)
    }

    /// The picture one recording's link actually resolves to on this desk, or
    /// nil when it resolves to none. The two candidates and the five conditions
    /// are the type's own documentation above; this is the only place they run.
    static func eligibleParentID(
        link: UUID,
        child: UUID,
        among byID: [UUID: WorkboardMaterialSnapshot]
    ) -> UUID? {
        // A RECORDING THAT NAMES ITSELF RESOLVES TO NOTHING, and the search ends
        // here rather than merely skipping that candidate: the escape of the
        // child's OWN id is not the child, so a skip would let whatever picture
        // happens to sit at that derived id become a parent — folding, and then
        // authorising a group delete of, two cards that were never a pair. No
        // lane writes a self-link; the stored value is raw, so a corrupt or
        // synced row can carry one.
        guard link != child else { return nil }
        for candidate in [link, WorkMaterialCollisionEscape.materialID(forCapture: link)] {
            guard candidate != child else { continue }
            guard let parent = byID[candidate] else { continue }
            guard parent.kind == .image, parent.attachedToMaterialID == nil else { continue }
            return candidate
        }
        return nil
    }
}

#endif
