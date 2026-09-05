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
            reorderMaterials: { [self] orderedMaterialIDs, expectedRevision in
                try await reorderMaterials(
                    orderedMaterialIDs,
                    expectedRevision: expectedRevision
                )
            },
            setMaterialCardSize: { [self] materialID, size in
                try await store.setWorkMaterialCardSize(
                    size,
                    materialID: materialID,
                    itemID: Constants.workboardDeskItemID
                )
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

    private static func snapshot(
        for record: WorkItemRecord,
        localThumbnails: [UUID: Data] = [:]
    ) -> WorkboardItemSnapshot {
        WorkboardItemSnapshot(
            id: record.id,
            title: record.content.title,
            objective: record.content.objective,
            materials: record.materials
                .sorted { ($0.sequence, $0.createdAt, $0.id.uuidString) < ($1.sequence, $1.createdAt, $1.id.uuidString) }
                .map { materialSnapshot($0, transientThumbnail: localThumbnails[$0.id]) },
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
    /// A stored kind is broader than the four shapes a card can draw, so the
    /// narrowing happens here and nowhere else: a second transcription of this
    /// switch would let two surfaces disagree about what one record IS, and the
    /// disagreement would only ever be visible as a card drawn with the wrong
    /// icon and the wrong noun. Internal so the tests can drive the real mapping
    /// instead of a copy of it.
    static func presentationKind(_ record: WorkMaterialRecord) -> WorkboardMaterialKind {
        switch record.kind {
        case .image: return .image
        case .file: return .file
        // A voice note travels as its recording, and the recording is the card:
        // narrowing it to a file would draw an openable document where a
        // transport belongs, and the audio card would never be reached.
        case .audio: return .audio
        case .link: return .link
        case .note, .transcript: return .note
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
        case .note:
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
                filename: material.kind == .image || material.kind == .file ? material.name : nil,
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
        }
    }

    /// Board drag. The store owns the single sequence rewrite, so this only
    /// carries the compare-and-swap token and re-projects the desk.
    private func reorderMaterials(
        _ orderedMaterialIDs: [UUID],
        expectedRevision: Int64
    ) async throws -> WorkboardItemSnapshot {
        do {
            let saved = try await store.reorderWorkMaterials(
                itemID: Constants.workboardDeskItemID,
                orderedMaterialIDs: orderedMaterialIDs,
                expectedOwnerRevision: expectedRevision
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

#endif
