// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardLiveRepository.swift
//
// Live adapter between the Workboard presentation model and Conduck's private
// local/CloudKit store. It maps immutable Sendable records into UI snapshots,
// exposes only gateways that are actually sendable on this device, and preserves
// explicit human state transitions. Transport is an injected callback receiving
// the exact preflight request and frozen gateway display name; this adapter never
// chooses a destination and contains no network-send implementation.

#if !os(watchOS)

import Foundation

@MainActor
final class WorkboardLiveRepository {
    typealias DispatchHandler = @MainActor (
        WorkboardDispatchRequest,
        String
    ) async throws -> WorkboardDispatchResult

    private let store: ConversationStore
    private let settings: SettingsManager
    private let captureDrainer: WorkCaptureDrainer
    private let dispatchHandler: DispatchHandler
    private let openConversationHandler: @MainActor (UUID) -> Void
    private let openMaterialHandler: @MainActor (WorkboardMaterialSnapshot) -> Void
    private let openGatewaySettingsHandler: @MainActor () -> Void
    private let captureVoiceHandler: (@MainActor () async throws -> String)?
    private let shapeDraftHandler: (@MainActor (WorkboardEditDraft) async throws -> WorkboardEditDraft)?
    private let readBriefingHandler: (@MainActor (String) async -> Void)?
    private let stopBriefingHandler: (@MainActor () -> Void)?
    private var localThumbnailCache: [UUID: CachedLocalThumbnail] = [:]

    private struct CachedLocalThumbnail {
        let revision: Int64
        let data: Data
    }

    /// Keeps the all-work load bounded even if someone uses Work as a large
    /// visual scrapbook. Older sources remain fully available and openable;
    /// they simply fall back to their type icon until they become recent again.
    private static let maximumLiveLocalThumbnails = 96

    init(
        store: ConversationStore = .shared,
        settings: SettingsManager = .shared,
        captureInbox: WorkCaptureInbox = .shared,
        dispatch: @escaping DispatchHandler,
        openConversation: @escaping @MainActor (UUID) -> Void,
        openMaterial: @escaping @MainActor (WorkboardMaterialSnapshot) -> Void,
        openGatewaySettings: @escaping @MainActor () -> Void,
        captureVoice: (@MainActor () async throws -> String)? = nil,
        shapeDraft: (@MainActor (WorkboardEditDraft) async throws -> WorkboardEditDraft)? = nil,
        readBriefingAloud: (@MainActor (String) async -> Void)? = nil,
        stopBriefingAloud: (@MainActor () -> Void)? = nil
    ) {
        self.store = store
        self.settings = settings
        self.captureDrainer = WorkCaptureDrainer(
            inbox: captureInbox,
            store: store,
            sourceDevice: SourceDevice.current
        )
        self.dispatchHandler = dispatch
        self.openConversationHandler = openConversation
        self.openMaterialHandler = openMaterial
        self.openGatewaySettingsHandler = openGatewaySettings
        self.captureVoiceHandler = captureVoice
        self.shapeDraftHandler = shapeDraft
        self.readBriefingHandler = readBriefingAloud
        self.stopBriefingHandler = stopBriefingAloud
    }

    func makeDependencies() -> WorkboardViewModel.Dependencies {
        WorkboardViewModel.Dependencies(
            loadItems: { [self] in try await loadItems() },
            loadGateways: { [self] in try await loadGateways() },
            saveDraft: { [self] draft in try await saveDraft(draft) },
            saveDraftAsCopy: { [self] draft in try await saveDraftAsCopy(draft) },
            importMaterial: { [self] itemID, revision, material, onProgress in
                try await importMaterial(
                    material,
                    to: itemID,
                    expectedRevision: revision,
                    onProgress: onProgress
                )
            },
            removeMaterial: { [self] itemID, revision, materialID in
                try await removeMaterial(
                    materialID,
                    from: itemID,
                    expectedRevision: revision
                )
            },
            replaceMaterial: { [self] itemID, revision, materialID, material, onProgress in
                try await replaceMaterial(
                    materialID,
                    in: itemID,
                    expectedRevision: revision,
                    with: material,
                    onProgress: onProgress
                )
            },
            deleteItem: { [self] itemID in
                try await store.deleteWorkItem(id: itemID)
                await WorkboardReviewReminderScheduler.shared.cancel(itemID: itemID)
            },
            duplicateItem: { [self] itemID in try await duplicateItem(id: itemID) },
            setState: { [self] itemID, state in try await setState(state, for: itemID) },
            acknowledgeRun: { [self] itemID, runID, resultKey in
                guard let item = try await store.acknowledgeWorkDispatchReview(
                    workItemID: itemID,
                    dispatchID: runID,
                    expectedResultKey: resultKey
                ) else {
                    throw WorkboardLiveRepositoryError.itemNotFound
                }
                return try await snapshot(for: item)
            },
            dispatch: { [self] request in try await dispatch(request) },
            openConversation: { [self] id in openConversationHandler(id) },
            openMaterial: { [self] material in openMaterialHandler(material) },
            openGatewaySettings: { [self] in openGatewaySettingsHandler() },
            captureVoice: captureVoiceHandler,
            shapeDraft: shapeDraftHandler,
            readBriefingAloud: readBriefingHandler,
            stopBriefingAloud: stopBriefingHandler,
            reorderItems: { [self] reorder in try await reorderItems(reorder) }
        )
    }

    /// Public so the personal-workbench capture coordinator can own one durable,
    /// serialized drain independently of cancelable UI refresh tasks.
    @discardableResult
    func drainCaptures() async throws -> WorkCaptureDrainer.Report {
        try await captureDrainer.drainAvailableCaptures()
    }

    // MARK: - Load + mapping

    private func loadItems() async throws -> [WorkboardItemSnapshot] {
        // Keep this a cancelable read. Capture ownership belongs exclusively to
        // `WorkCaptureRefreshCoordinator`; allowing a view load to claim queue
        // bytes would let its own claim/ack notification cancel the caller.
        _ = try await store.reconcileWorkAssetVault()
        let records = try await store.fetchWorkItems()
        return try await snapshots(for: records)
    }

    private func snapshots(for records: [WorkItemRecord]) async throws -> [WorkboardItemSnapshot] {
        await WorkboardReviewReminderScheduler.shared.reconcile(records)
        let conversationIDs = Set(records.flatMap { $0.dispatches.compactMap(\.conversationID) })
        var messagesByID: [UUID: MessageRecord] = [:]
        for conversationID in conversationIDs {
            for message in try await store.fetchMessages(for: conversationID) {
                messagesByID[message.id] = message
            }
        }
        let localThumbnails = await localPresentationThumbnails(for: records)
        return records.map {
            Self.snapshot(
                for: $0,
                messagesByID: messagesByID,
                localThumbnails: localThumbnails
            )
        }
    }

    /// Builds transient previews from the device-local vault. The resulting
    /// bytes exist only in this repository's memory and the presentation
    /// snapshot: they are never written back to Core Data and therefore never
    /// enter CloudKit. ImageIO reads directly from the file URL off the main
    /// actor, keeping both UI responsiveness and the no-synced-file-content
    /// privacy invariant intact.
    private func localPresentationThumbnails(
        for records: [WorkItemRecord]
    ) async -> [UUID: Data] {
        let candidates = records
            .flatMap(\.materials)
            .filter {
                $0.kind == .image
                    && $0.thumbnailData == nil
                    && $0.availability == .availableLocally
            }
            .sorted {
                ($0.updatedAt, $0.id.uuidString) > ($1.updatedAt, $1.id.uuidString)
            }
        let boundedCandidates = Array(candidates.prefix(Self.maximumLiveLocalThumbnails))
        let candidateIDs = Set(boundedCandidates.map(\.id))
        localThumbnailCache = localThumbnailCache.filter { candidateIDs.contains($0.key) }

        var result: [UUID: Data] = [:]
        var jobs: [(id: UUID, revision: Int64, url: URL)] = []
        for material in boundedCandidates {
            let revision = Self.revision(for: material.updatedAt)
            if let cached = localThumbnailCache[material.id], cached.revision == revision {
                result[material.id] = cached.data
                continue
            }
            guard let url = try? await store.localURLForWorkMaterial(id: material.id) else {
                localThumbnailCache.removeValue(forKey: material.id)
                continue
            }
            jobs.append((material.id, revision, url))
        }

        let generated = await withTaskGroup(
            of: (UUID, Int64, Data?).self,
            returning: [(UUID, Int64, Data?)].self
        ) { group in
            for job in jobs {
                group.addTask {
                    (
                        job.id,
                        job.revision,
                        ImageProcessor.thumbnailOnly(fromFileAt: job.url)
                    )
                }
            }
            var values: [(UUID, Int64, Data?)] = []
            for await value in group { values.append(value) }
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

    private func snapshot(for record: WorkItemRecord) async throws -> WorkboardItemSnapshot {
        let mapped = try await snapshots(for: [record])
        guard let first = mapped.first else {
            throw WorkboardLiveRepositoryError.itemNotFound
        }
        return first
    }

    /// Shared bit-exact projection used by autosave and transport revalidation.
    static func revision(for date: Date) -> Int64 {
        WorkboardRevision.value(for: date)
    }

    private static func snapshot(
        for record: WorkItemRecord,
        messagesByID: [UUID: MessageRecord],
        localThumbnails: [UUID: Data] = [:]
    ) -> WorkboardItemSnapshot {
        let runs = record.dispatches
            .sorted { ($0.occurredAt, $0.id.uuidString) < ($1.occurredAt, $1.id.uuidString) }
            .compactMap { runSnapshot(for: $0, messagesByID: messagesByID) }
        let latestStartedDispatch = record.dispatches
            .filter { $0.dispatchedAt != nil }
            .max { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }

        return WorkboardItemSnapshot(
            id: record.id,
            title: record.content.title,
            objective: record.content.objective,
            context: record.content.context,
            desiredResult: record.content.desiredOutcome,
            constraints: record.content.constraints,
            reviewBy: record.content.dueAt,
            state: presentationState(record.state),
            materials: record.materials
                .sorted { ($0.sequence, $0.createdAt, $0.id.uuidString) < ($1.sequence, $1.createdAt, $1.id.uuidString) }
                .map { materialSnapshot($0, transientThumbnail: localThumbnails[$0.id]) },
            runs: runs,
            isPinned: record.content.isPinned,
            createdAt: record.createdAt,
            modifiedAt: record.updatedAt,
            boardOrder: record.boardOrder,
            revision: revision(for: record.updatedAt),
            lastSentRevision: latestStartedDispatch.map { revision(for: $0.createdAt) },
            wasCapturedExternally: record.captureEnvelopeID != nil
        )
    }

    private static func presentationState(_ state: WorkItemState) -> WorkboardItemState {
        switch state {
        case .draft: return .draft
        case .waiting: return .waiting
        case .review: return .review
        case .done: return .done
        }
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
            createdAt: record.createdAt,
            revision: revision(for: record.updatedAt)
        )
    }

    private static func presentationAvailability(
        _ record: WorkMaterialRecord
    ) -> WorkboardMaterialAvailability {
        switch record.availability {
        case .synced:
            return .available
        case .availableLocally:
            return .localOnly
        case .unavailableOnThisDevice:
            return .unavailableOnThisDevice
        case .metadataOnly:
            // Notes and links intentionally have no binary payload. A binary
            // metadata row without bytes is visible provenance, not sendable.
            switch record.kind {
            case .note, .link, .transcript:
                return .available
            case .image, .file, .unknown:
                return .unavailableOnThisDevice
            }
        }
    }

    private static func presentationKind(_ record: WorkMaterialRecord) -> WorkboardMaterialKind {
        switch record.kind {
        case .image: return .image
        case .file: return .file
        case .link: return .link
        case .note, .transcript: return .note
        case .unknown:
            return record.filename != nil || record.hasPayload ? .file : .note
        }
    }

    private static func materialName(_ record: WorkMaterialRecord) -> String {
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
        }
    }

    private static func materialDetail(_ record: WorkMaterialRecord) -> String? {
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
                defaultValue: "Reattach on this device before sending"
            ))
        case .metadataOnly, .synced:
            break
        }

        if parts.isEmpty, record.byteSize > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: record.byteSize, countStyle: .file))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private static func runSnapshot(
        for dispatch: WorkDispatchRecord,
        messagesByID: [UUID: MessageRecord]
    ) -> WorkboardRunSnapshot? {
        guard let ref = RemoteAgentRef(rawString: dispatch.gatewayRef) else { return nil }

        let state: WorkboardRunState
        let resultMarkdown: String?
        let resultAttachments: [AttachmentRecord]
        let failureMessage: String?
        let finishedAt: Date?
        switch dispatch.activity {
        case .prepared:
            state = .failed
            resultMarkdown = nil
            resultAttachments = []
            failureMessage = String(
                localized: "workboard.run.preparedNotSent",
                defaultValue: "This brief was prepared but did not start. You can review and send it again."
            )
            finishedAt = nil
        case .waiting:
            state = .waiting
            resultMarkdown = nil
            resultAttachments = []
            failureMessage = nil
            finishedAt = nil
        case .replied(let messageID):
            state = .replied
            resultMarkdown = messagesByID[messageID]?.text
            resultAttachments = messagesByID[messageID]?.attachments ?? []
            failureMessage = nil
            finishedAt = messagesByID[messageID]?.createdAt
        case .replyPendingSync:
            state = .replied
            resultMarkdown = nil
            resultAttachments = []
            failureMessage = nil
            finishedAt = nil
        case .failed(let messageID, _):
            let message = messagesByID[messageID]
            if message?.failureCode == AppError.turnStoppedBeforeSend.errorCode {
                state = .cancelled
            } else {
                state = .failed
            }
            resultMarkdown = nil
            resultAttachments = []
            failureMessage = safeFailureMessage(message, ref: ref)
            finishedAt = message?.createdAt
        case .conversationRemoved:
            state = .cancelled
            resultMarkdown = nil
            resultAttachments = []
            failureMessage = String(
                localized: "workboard.run.conversationRemoved",
                defaultValue: "The linked conversation was removed. The sent brief remains here for your records."
            )
            finishedAt = dispatch.conversationRemovedAt
        }

        let materialNames: [String] = dispatch.briefSnapshot?.materials
            .sorted { ($0.sequence, $0.id.uuidString) < ($1.sequence, $1.id.uuidString) }
            .map { material in
                let candidates = [material.title, material.filename ?? "", material.urlString ?? ""]
                return candidates.first(where: {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }) ?? String(localized: "workboard.material.item", defaultValue: "Material")
            } ?? []

        return WorkboardRunSnapshot(
            id: dispatch.id,
            state: state,
            gatewayRef: ref,
            gatewayName: dispatch.gatewayNameSnapshot,
            conversationID: dispatch.conversationID,
            sentPrompt: dispatch.promptSnapshot,
            includedMaterialNames: materialNames,
            resultMarkdown: resultMarkdown,
            resultAttachments: resultAttachments,
            failureMessage: failureMessage,
            needsReview: dispatch.stateFacts.needsReview,
            canAcknowledgeReview: dispatch.activity.resultKey != nil,
            reviewResultKey: dispatch.activity.resultKey,
            startedAt: dispatch.dispatchedAt ?? dispatch.createdAt,
            finishedAt: finishedAt
        )
    }

    private static func safeFailureMessage(_ message: MessageRecord?, ref: RemoteAgentRef) -> String {
        guard let code = message?.failureCode else {
            return String(
                localized: "workboard.run.failed.generic",
                defaultValue: "The request did not complete. Open its conversation to review or retry it."
            )
        }
        return AppError.from(errorCode: code, message: nil).descriptionWithRecovery(for: ref)
    }

    // MARK: - Gateway roster

    private func loadGateways() async throws -> ([WorkboardGatewayChoice], [CustomGateway]) {
        let refs = await settings.configuredRemoteAgentRefs()
        let badgeRoster = await settings.gatewayBadgeRoster()
        var choices: [WorkboardGatewayChoice] = []
        choices.reserveCapacity(refs.count)

        for ref in refs {
            var capabilities: Set<WorkboardGatewayCapability> = [.text, .images]
            let fileTransferReady = await settings.fileTransferReadySnapshot(for: ref) != nil
            if fileTransferReady {
                capabilities.insert(.files)
            }
            choices.append(WorkboardGatewayChoice(
                ref: ref,
                name: RemoteAgentRefMetadata.displayName(for: ref, customs: badgeRoster),
                detail: gatewayDetail(ref),
                capabilities: capabilities,
                availability: .configured(String(
                    localized: "workboard.gateway.configured.status",
                    defaultValue: fileTransferReady
                        ? "Configured on this device; full file transfer is ready."
                        : "Configured on this device; reachability is verified when you send."
                )),
                isRecommended: false
            ))
        }
        return (choices, badgeRoster)
    }

    private func gatewayDetail(_ ref: RemoteAgentRef) -> String {
        switch ref {
        case .builtin(.openrouter):
            return String(localized: "workboard.gateway.hosted", defaultValue: "Hosted model")
        case .builtin:
            return String(localized: "workboard.gateway.selfHosted", defaultValue: "Self-hosted agent")
        case .custom:
            return String(localized: "workboard.gateway.custom", defaultValue: "Custom endpoint")
        }
    }

    // MARK: - Editable brief operations

    private func saveDraft(_ draft: WorkboardEditDraft) async throws -> WorkboardItemSnapshot {
        let existing = try await store.fetchWorkItem(id: draft.id)
        if existing == nil, draft.baseRevision != 0 {
            throw WorkboardLiveRepositoryError.itemNotFound
        }
        if let existing,
           draft.baseRevision != 0,
           Self.revision(for: existing.updatedAt) != draft.baseRevision {
            throw WorkboardLiveRepositoryError.staleDraft
        }

        let content = WorkItemContent(
            title: draft.title,
            objective: draft.objective,
            context: draft.context,
            desiredOutcome: draft.desiredResult,
            constraints: draft.constraints,
            dueAt: draft.reviewBy,
            preferredGatewayRef: existing?.content.preferredGatewayRef,
            isPinned: draft.isPinned
        )

        let saved: WorkItemRecord
        do {
            saved = try await store.saveWorkItemDraft(
                id: draft.id,
                expectedRevision: draft.baseRevision,
                content: content,
                orderedMaterialIDs: draft.materials.map(\.id)
            )
        } catch WorkboardStoreError.staleRevision {
            throw WorkboardLiveRepositoryError.staleDraft
        }
        return try await snapshot(for: saved)
    }

    /// Preserve a conflicted local edit without overwriting the newer remote
    /// card. When the source still exists its materials are duplicated through
    /// the store's provenance-aware copy path; if it was deleted remotely, the
    /// person's authored fields are still rescued into a fresh text-only brief.
    private func saveDraftAsCopy(_ draft: WorkboardEditDraft) async throws -> WorkboardItemSnapshot {
        let content = WorkItemContent(
            title: draft.title,
            objective: draft.objective,
            context: draft.context,
            desiredOutcome: draft.desiredResult,
            constraints: draft.constraints,
            dueAt: draft.reviewBy,
            preferredGatewayRef: nil,
            isPinned: draft.isPinned
        )
        let copied: WorkItemRecord
        if try await store.fetchWorkItem(id: draft.id) != nil {
            let duplicate = try await store.duplicateWorkItem(id: draft.id)
            guard let updated = try await store.updateWorkItem(id: duplicate.id, content: content) else {
                throw WorkboardLiveRepositoryError.itemNotFound
            }
            copied = updated
        } else {
            copied = try await store.createWorkItem(WorkItemDraft(content: content))
        }
        return try await snapshot(for: copied)
    }

    private func importMaterial(
        _ material: WorkboardMaterialImport,
        to workItemID: UUID,
        expectedRevision: Int64,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> WorkboardItemSnapshot {
        // Validate and prepare the material before creating a provisional owner.
        // Most failures therefore happen while New Work is still purely in memory.
        let payload: Data?
        let sourceFileURL: URL?
        let thumbnail: Data?
        let textContent: String?
        let urlString: String?
        switch material.kind {
        case .image:
            if let url = material.fileURL {
                payload = nil
                sourceFileURL = url
                let byteCount = material.byteCount ?? -1
                if WorkAssetVault.shouldMirror(byteCount: byteCount),
                   let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) {
                    thumbnail = await Task.detached(priority: .userInitiated) {
                        ImageProcessor.thumbnailOnly(from: data)
                    }.value
                } else {
                    thumbnail = nil
                }
            } else {
                guard let data = material.data, !data.isEmpty else {
                    throw WorkboardLiveRepositoryError.missingPayload
                }
                payload = data
                sourceFileURL = nil
                thumbnail = await Task.detached(priority: .userInitiated) {
                    ImageProcessor.thumbnailOnly(from: data)
                }.value
            }
            textContent = nil
            urlString = nil
        case .file:
            if let url = material.fileURL {
                payload = nil
                sourceFileURL = url
                textContent = nil
            } else {
                guard let data = material.data, !data.isEmpty else {
                    throw WorkboardLiveRepositoryError.missingPayload
                }
                payload = data
                sourceFileURL = nil
                textContent = nil
            }
            thumbnail = nil
            urlString = nil
        case .link:
            guard let value = material.urlString,
                  WorkCaptureEnvelope.isAcceptedWebURL(value) else {
                throw WorkboardLiveRepositoryError.invalidLink
            }
            payload = nil
            sourceFileURL = nil
            thumbnail = nil
            textContent = nil
            urlString = value
        case .note:
            let text = material.textContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { throw WorkboardLiveRepositoryError.emptyNote }
            payload = nil
            sourceFileURL = nil
            thumbnail = nil
            textContent = text
            urlString = nil
        }

        let owner: WorkItemRecord?
        if let existing = try await store.fetchWorkItem(id: workItemID) {
            guard expectedRevision != 0,
                  Self.revision(for: existing.updatedAt) == expectedRevision else {
                throw WorkboardLiveRepositoryError.staleDraft
            }
            owner = existing
        } else {
            guard expectedRevision == 0 else {
                throw WorkboardLiveRepositoryError.itemNotFound
            }
            owner = nil
        }
        let sequence = (owner?.materials.map(\.sequence).max() ?? -1) + 1

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
                thumbnailData: thumbnail,
                byteSize: material.byteCount ?? payload.map { Int64($0.count) },
                sequence: sequence,
                sourceDevice: SourceDevice.current
        )
        do {
            if owner == nil {
                let created = try await store.createWorkItemWithInitialMaterial(
                    WorkItemDraft(
                        id: workItemID,
                        content: WorkItemContent(
                            title: WorkboardWorkspaceCaptureLogic.title(for: material.name)
                        )
                    ),
                    material: draft,
                    sourceFileURL: sourceFileURL,
                    sourceFileByteSize: material.byteCount ?? -1,
                    onProgress: onProgress
                )
                return try await snapshot(for: created)
            }

            guard let owner else { throw WorkboardLiveRepositoryError.itemNotFound }
            let ownerRevision = Self.revision(for: owner.updatedAt)
            if let sourceFileURL {
                _ = try await store.addWorkMaterialFile(
                    draft,
                    from: sourceFileURL,
                    byteSize: material.byteCount ?? -1,
                    to: workItemID,
                    expectedOwnerRevision: ownerRevision,
                    onProgress: onProgress
                )
            } else {
                _ = try await store.addWorkMaterial(
                    draft,
                    to: workItemID,
                    expectedOwnerRevision: ownerRevision
                )
                onProgress(1)
            }
        } catch {
            if case WorkboardStoreError.staleRevision = error {
                throw WorkboardLiveRepositoryError.staleDraft
            }
            throw error
        }
        guard let refreshed = try await store.fetchWorkItem(id: workItemID) else {
            throw WorkboardLiveRepositoryError.itemNotFound
        }
        return try await snapshot(for: refreshed)
    }

    private func storageKind(_ kind: WorkboardMaterialKind) -> WorkMaterialKind {
        switch kind {
        case .image: return .image
        case .file: return .file
        case .link: return .link
        case .note: return .note
        }
    }

    private func removeMaterial(
        _ materialID: UUID,
        from workItemID: UUID,
        expectedRevision: Int64
    ) async throws -> WorkboardItemSnapshot {
        guard let item = try await store.fetchWorkItem(id: workItemID) else {
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
                workItemID: workItemID,
                expectedOwnerRevision: expectedRevision
            )
        } catch WorkboardStoreError.staleRevision {
            throw WorkboardLiveRepositoryError.staleDraft
        }
        guard let refreshed = try await store.fetchWorkItem(id: workItemID) else {
            throw WorkboardLiveRepositoryError.itemNotFound
        }
        return try await snapshot(for: refreshed)
    }

    private func replaceMaterial(
        _ materialID: UUID,
        in workItemID: UUID,
        expectedRevision: Int64,
        with replacement: WorkboardMaterialImport,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> WorkboardItemSnapshot {
        guard let item = try await store.fetchWorkItem(id: workItemID) else {
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
        // Reattachment replaces local bytes and metadata only. Persisting an
        // extract here would copy user file content into private CloudKit.
        let replacementText: String? = nil
        let replacementThumbnail: Data?
        if replacement.kind == .image,
           WorkAssetVault.shouldMirror(byteCount: byteSize),
           let data = try? Data(contentsOf: sourceURL, options: [.mappedIfSafe]) {
            replacementThumbnail = await Task.detached(priority: .userInitiated) {
                ImageProcessor.thumbnailOnly(from: data)
            }.value
        } else {
            replacementThumbnail = nil
        }
        do {
            guard try await store.replaceWorkMaterialPayloadFile(
                id: materialID,
                from: sourceURL,
                byteSize: byteSize,
                filename: replacement.name,
                mimeType: replacement.mimeType,
                textContent: replacementText,
                thumbnailData: replacementThumbnail,
                sourceDevice: SourceDevice.current,
                expectedOwnerRevision: expectedRevision,
                onProgress: onProgress
            ) != nil else {
                throw WorkboardLiveRepositoryError.itemNotFound
            }
        } catch WorkboardStoreError.staleRevision {
            throw WorkboardLiveRepositoryError.staleDraft
        }
        guard let refreshed = try await store.fetchWorkItem(id: workItemID) else {
            throw WorkboardLiveRepositoryError.itemNotFound
        }
        return try await snapshot(for: refreshed)
    }

    private func duplicateItem(id: UUID) async throws -> WorkboardItemSnapshot {
        guard let source = try await store.fetchWorkItem(id: id) else {
            throw WorkboardLiveRepositoryError.itemNotFound
        }
        var duplicate = try await store.duplicateWorkItem(id: id)
        var content = duplicate.content
        let baseTitle = source.content.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = source.content.objective
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = baseTitle.isEmpty ? fallback : baseTitle
        if !title.isEmpty {
            content.title = String(
                localized: "workboard.item.copyTitle",
                defaultValue: "\(title) — Copy"
            )
            if let renamed = try await store.updateWorkItem(id: duplicate.id, content: content) {
                duplicate = renamed
            }
        }
        return try await snapshot(for: duplicate)
    }

    /// Persist global project-strip order independently from brief activity.
    /// A stale rank compare is an ordering conflict, not a draft-content conflict;
    /// the view model reloads before showing the shared action failure surface.
    private func reorderItems(
        _ reorder: WorkItemBoardReorder
    ) async throws -> [WorkboardItemSnapshot] {
        let records: [WorkItemRecord]
        do {
            records = try await store.reorderWorkItems(reorder)
        } catch WorkboardStoreError.staleRevision {
            throw WorkboardLiveRepositoryError.staleBoardOrder
        }
        return try await snapshots(for: records)
    }

    private func setState(
        _ requestedState: WorkboardItemState,
        for itemID: UUID
    ) async throws -> WorkboardItemSnapshot {
        guard var item = try await store.fetchWorkItem(id: itemID) else {
            throw WorkboardLiveRepositoryError.itemNotFound
        }

        switch requestedState {
        case .done:
            guard let completed = try await store.completeWorkItem(id: itemID) else {
                throw WorkboardLiveRepositoryError.itemNotFound
            }
            item = completed
        case .draft:
            if item.completedAt != nil {
                guard let reopened = try await store.reopenWorkItem(id: itemID) else {
                    throw WorkboardLiveRepositoryError.itemNotFound
                }
                item = reopened
            }
            if item.state == .review { throw WorkboardLiveRepositoryError.derivedState }
        case .waiting, .review:
            // These are transport-derived facts, never human-writable lanes.
            throw WorkboardLiveRepositoryError.derivedState
        }
        return try await snapshot(for: item)
    }

    private func dispatch(_ request: WorkboardDispatchRequest) async throws -> WorkboardDispatchReceipt {
        let (choices, _) = try await loadGateways()
        guard let gateway = choices.first(where: { $0.ref == request.gatewayRef }) else {
            throw WorkboardLiveRepositoryError.gatewayUnavailable
        }
        // The prompt and material IDs are forwarded byte-for-byte from the
        // preflight request. Only the human-selected gateway's display name is
        // added for the immutable audit snapshot.
        let result = try await dispatchHandler(request, gateway.name)
        // Transport has started when the handler returns. Mapping refreshes are
        // best-effort from this point onward: a transient Core Data/CloudKit read
        // cannot truthfully become "Nothing was sent" or keep the send sheet open.
        let itemSnapshot = (try? await snapshot(for: result.workItem))
            ?? Self.snapshot(for: result.workItem, messagesByID: [:])
        return WorkboardDispatchReceipt(
            item: itemSnapshot,
            conversationID: result.conversationID,
            runID: result.dispatchID
        )
    }
}

enum WorkboardLiveRepositoryError: LocalizedError, Equatable {
    case itemNotFound
    case staleDraft
    case staleBoardOrder
    case missingPayload
    case invalidLink
    case emptyNote
    case derivedState
    case gatewayUnavailable

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return String(
                localized: "workboard.error.itemMissing",
                defaultValue: "This brief is no longer available."
            )
        case .staleDraft:
            return String(
                localized: "workboard.error.staleDraft",
                defaultValue: "This brief changed on another device. Reopen it to keep the latest version."
            )
        case .staleBoardOrder:
            return String(
                localized: "workboard.error.staleBoardOrder",
                defaultValue: "The project order changed on another device. The latest order is shown."
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
        case .derivedState:
            return String(
                localized: "workboard.error.derivedState",
                defaultValue: "Waiting and Review are updated by the linked conversation."
            )
        case .gatewayUnavailable:
            return String(
                localized: "workboard.error.gatewayUnavailable",
                defaultValue: "That gateway is not ready on this device. Nothing was sent."
            )
        }
    }
}

#endif
