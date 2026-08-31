// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardDispatchCoordinator.swift
//
// The deliberate Workboard -> Conversation boundary. The user approves one
// exact prompt, material manifest and gateway in preflight. This coordinator
// re-derives that packet from the latest private store row, deep-copies every
// selected material into the new conversation, freezes an immutable dispatch
// snapshot, then hands the prepared turn to Conduck's existing retry pipeline.
// It does not implement a second gateway client: retry already owns routing,
// certificate trust, client-owned history, usage attempts and at-most-once CAS.

#if !os(watchOS)
import Foundation

nonisolated enum WorkboardRevision {
    /// Bit-exact persisted Date token. A coarse millisecond floor can approve a
    /// different payload/metadata write that happened inside the same tick.
    static func value(for date: Date) -> Int64 {
        Int64(bitPattern: date.timeIntervalSinceReferenceDate.bitPattern)
    }
}

nonisolated struct WorkboardDispatchResult: Sendable {
    let workItem: WorkItemRecord
    let conversationID: UUID
    let dispatchID: UUID
}

nonisolated enum WorkboardDispatchError: Error, Sendable, Equatable {
    case itemChanged
    case gatewayUnavailable
    case materialChanged
    case materialUnavailable
    case fileServerRequired
    case fileTransferFailed
    case unsupportedMaterial
    case previewMismatch
    case alreadyStarted
}

extension WorkboardDispatchError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .itemChanged:
            return String(localized: "workboard.error.itemChanged", defaultValue: "This brief changed after the preview opened. Review the latest version before sending.")
        case .gatewayUnavailable:
            return String(localized: "workboard.error.gatewayUnavailable", defaultValue: "That gateway is not ready on this device. Nothing was sent.")
        case .materialChanged:
            return String(localized: "workboard.error.materialChanged", defaultValue: "The selected materials changed after the preview opened. Review them again before sending.")
        case .materialUnavailable:
            return String(localized: "workboard.error.materialUnavailable", defaultValue: "A selected material is not available on this device. Reattach it here before sending.")
        case .fileServerRequired:
            return String(localized: "workboard.error.fileServerRequired", defaultValue: "A selected file needs this gateway's file transfer connection. Set it up or choose another gateway.")
        case .fileTransferFailed:
            return String(localized: "workboard.error.fileTransferFailed", defaultValue: "A selected file could not be transferred through this gateway. Nothing was sent; check the connection and try again.")
        case .unsupportedMaterial:
            return String(localized: "workboard.error.unsupportedMaterial", defaultValue: "One selected material cannot be prepared safely. Remove or replace it before sending.")
        case .previewMismatch:
            return String(localized: "workboard.error.previewMismatch", defaultValue: "The final prompt no longer matches the preview. Nothing was sent; reopen Review & Send.")
        case .alreadyStarted:
            return String(localized: "workboard.error.alreadyStarted", defaultValue: "This exact dispatch has already started. Conduck will not send it twice.")
        }
    }
}

@MainActor
final class WorkboardDispatchCoordinator {
    static let shared = WorkboardDispatchCoordinator()

    private let store: ConversationStore
    private let settings: SettingsManager

    init(
        store: ConversationStore = .shared,
        settings: SettingsManager = .shared
    ) {
        self.store = store
        self.settings = settings
    }

    /// Starts transport and returns as soon as the prepared turn is handed to
    /// the existing pipeline. On macOS the foreground request may live for
    /// minutes, so its VM is retained by the child task rather than holding the
    /// preflight sheet open until the answer arrives.
    func dispatch(
        _ request: WorkboardDispatchRequest,
        gatewayName: String
    ) async throws -> WorkboardDispatchResult {
        guard (await settings.configuredRemoteAgentRefs()).contains(request.gatewayRef) else {
            throw WorkboardDispatchError.gatewayUnavailable
        }

        let captured: CapturedWorkDispatch
        do {
            captured = try await store.captureWorkDispatch(
                workItemID: request.itemID,
                expectedRevision: request.expectedRevision,
                dispatchID: request.id,
                includedMaterialIDs: request.includedMaterialIDs,
                expectedMaterialVersions: request.includedMaterialVersions
            )
        } catch WorkboardStoreError.itemNotFound {
            throw WorkboardStoreError.itemNotFound
        } catch WorkboardStoreError.identifierCollision {
            throw WorkboardDispatchError.alreadyStarted
        } catch WorkboardStoreError.materialPayloadUnavailable {
            throw WorkboardDispatchError.materialUnavailable
        } catch {
            throw WorkboardDispatchError.itemChanged
        }
        // Local-vault files are stable copies owned by this dispatch attempt.
        // Every attachment either deep-copies their bytes or uploads them before
        // this method returns, so they can be reclaimed on every exit path.
        defer {
            for url in captured.temporaryFileURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let selected = captured.materials.map(\.record)

        let packet = WorkBriefPromptBuilder.build(
            workItemID: captured.workItemID,
            title: captured.content.title,
            objective: captured.content.objective,
            context: captured.content.context,
            constraints: captured.content.constraints,
            desiredResult: captured.content.desiredOutcome,
            reviewBy: captured.content.dueAt,
            materials: selected.map(WorkBriefMaterialPacket.init(record:))
        )
        guard packet.canonicalPrompt == request.prompt else {
            throw WorkboardDispatchError.previewMismatch
        }

        let conversationID = UUID()
        let fileLane = await settings.fileTransferReadySnapshot(for: request.gatewayRef)
        let uploadLedger = WorkboardUploadLedger(
            dispatchID: request.id,
            conversationID: conversationID,
            gatewayRef: request.gatewayRef,
            durableLaneID: fileLane?.durableLaneID
        )
        await WorkboardUploadJournal.shared.beginActivity(dispatchID: request.id)
        defer {
            Task {
                await WorkboardUploadJournal.shared.endActivity(dispatchID: request.id)
            }
        }
        let preparedMaterials: PreparedMaterials
        do {
            preparedMaterials = try await prepareAttachments(
                captured.materials,
                conversationID: conversationID,
                fileLane: fileLane,
                uploadLedger: uploadLedger
            )
        } catch {
            await cleanupUploads(uploadLedger, fileLane: fileLane)
            throw error
        }

        // Uploads and the durable message must describe one exact lane. A
        // Settings edit while a large file was transferring cannot silently
        // bind old-server keys to a conversation whose gateway now points
        // somewhere else.
        if !uploadLedger.uploads.isEmpty, let fileLane {
            let currentLane = await settings.fileTransferSnapshot(for: request.gatewayRef)
            guard currentLane?.identitySignature == fileLane.identitySignature else {
                await cleanupUploads(uploadLedger, fileLane: fileLane)
                throw WorkboardDispatchError.gatewayUnavailable
            }
        }
        let snapshot = WorkBriefSnapshot(
            title: packet.title,
            objective: packet.objective,
            context: packet.context,
            desiredOutcome: packet.desiredResult,
            constraints: packet.constraints,
            dueAt: packet.reviewBy,
            materials: selected.map(WorkMaterialSnapshot.init(record:))
        )
        let preparation = WorkDispatchPreparation(
            dispatchID: request.id,
            workItemID: captured.workItemID,
            conversationID: conversationID,
            gatewayRef: request.gatewayRef.rawString,
            gatewayName: gatewayName,
            canonicalPrompt: packet.canonicalPrompt,
            briefSnapshot: snapshot,
            expectedWorkItemRevision: WorkboardRevision.value(for: captured.updatedAt),
            expectedMaterialVersions: captured.materials
                .map {
                    WorkboardMaterialVersion(
                        id: $0.record.id,
                        revision: WorkboardRevision.value(for: $0.record.updatedAt)
                    )
                }
                .sorted { $0.id.uuidString < $1.id.uuidString },
            sourceDevice: SourceDevice.current + "-text",
            fileTransferLaneID: fileLane?.durableLaneID,
            attachments: preparedMaterials.attachments,
            preparedAt: request.createdAt
        )

        var uploadsBoundToStore = false
        do {
            let prepared: PreparedWorkDispatch
            do {
                prepared = try await store.prepareWorkDispatch(preparation)
            } catch WorkboardStoreError.identifierCollision {
                throw WorkboardDispatchError.alreadyStarted
            }
            // A committed prepare is the irreversible boundary: the run is
            // already stamped as dispatched. From here onward the file-lane
            // objects belong to the durable, retryable message, and nothing may
            // delete payloads the conversation now references or flow back
            // through the UI's "Nothing was sent" branch.
            uploadsBoundToStore = true
            await WorkboardUploadJournal.shared.finish(dispatchID: request.id)

            // Strongly captured until retry finishes. retry's failed->sending
            // compare-and-set is the single network-attempt authority.
            let viewModel = ConversationDetailViewModel(conversationID: prepared.conversation.id)
            Task { @MainActor in
                await viewModel.retry(prepared.message)
            }

            return WorkboardDispatchResult(
                workItem: Self.receipt(for: prepared),
                conversationID: prepared.conversation.id,
                dispatchID: prepared.dispatch.id
            )
        } catch {
            // Uploads happened before the all-or-nothing Core Data prepare. If
            // that prepare did not bind them to a message, reclaim best-effort
            // from the user's own file lane; never let cleanup mask the cause.
            if !uploadsBoundToStore {
                await cleanupUploads(uploadLedger, fileLane: fileLane)
            }
            throw error
        }
    }

    private struct PreparedMaterials {
        var attachments: [AttachmentDraft] = []
    }

    private final class WorkboardUploadLedger {
        let dispatchID: UUID
        let conversationID: UUID
        let gatewayRef: String
        let durableLaneID: String?
        var uploads: [WorkboardPendingUpload.Upload] = []

        init(
            dispatchID: UUID,
            conversationID: UUID,
            gatewayRef: RemoteAgentRef,
            durableLaneID: String?
        ) {
            self.dispatchID = dispatchID
            self.conversationID = conversationID
            self.gatewayRef = gatewayRef.rawString
            self.durableLaneID = durableLaneID
        }
    }

    private func prepareAttachments(
        _ materials: [CapturedWorkMaterial],
        conversationID: UUID,
        fileLane: SettingsManager.FileTransferSnapshot?,
        uploadLedger: WorkboardUploadLedger
    ) async throws -> PreparedMaterials {
        var result = PreparedMaterials()
        var attachmentSequence = 0
        var inlineTextBudget = Constants.textInlineTurnBudgetBytes

        for captured in materials {
            let material = captured.record
            switch material.kind {
            case .note, .link, .transcript:
                continue
            case .unknown:
                throw WorkboardDispatchError.unsupportedMaterial
            case .image:
                let payload = try await Self.exactPayload(captured)
                let processed: ProcessedImage
                do {
                    processed = try await ImageProcessor.shared.process(payload)
                } catch {
                    throw WorkboardDispatchError.unsupportedMaterial
                }
                var draft = AttachmentDraft(
                    mimeType: "image/jpeg",
                    filename: material.filename,
                    data: processed.jpegData,
                    thumbnailData: processed.thumbnailData,
                    width: processed.width,
                    height: processed.height,
                    byteSize: processed.byteSize,
                    sequence: attachmentSequence
                )
                if let fileLane {
                    let name = Self.safeFilename(material, fallback: "image.jpg")
                    let key = Self.storedKey(
                        for: material,
                        filename: name,
                        conversationID: conversationID,
                        folderCapable: fileLane.folderCapable
                    )
                    let localURL = try await Self.temporaryFile(data: payload, filename: name)
                    defer { try? FileManager.default.removeItem(at: localURL) }
                    try await uploadServerFile(
                        localURL: localURL,
                        storedKey: key,
                        sequence: attachmentSequence,
                        snapshot: fileLane,
                        uploadLedger: uploadLedger
                    )
                    draft.storedKey = key
                }
                result.attachments.append(draft)
                attachmentSequence += 1

            case .file:
                let filename = Self.safeFilename(material, fallback: "file.dat")
                let localURL: URL
                let materializedTemporaryURL: URL?
                if let stableURL = captured.localFileURL {
                    localURL = stableURL
                    materializedTemporaryURL = nil
                } else if let payload = captured.payload {
                    let url = try await Self.temporaryFile(data: payload, filename: filename)
                    localURL = url
                    materializedTemporaryURL = url
                } else {
                    throw WorkboardDispatchError.materialUnavailable
                }
                defer {
                    if let materializedTemporaryURL {
                        try? FileManager.default.removeItem(at: materializedTemporaryURL)
                    }
                }

                let mayProbeText = material.byteSize <= Int64(Constants.textProbeMaxBytes)
                let extracted: TextFileExtractor.ExtractedFile?
                if mayProbeText {
                    extracted = await Task.detached(priority: .userInitiated) {
                        try? TextFileExtractor.extract(from: localURL)
                    }.value
                } else {
                    extracted = nil
                }
                if let extracted, let textData = extracted.text.data(using: .utf8) {
                    let plan = AttachmentDeliveryPlanner.plan(
                        extractedByteCount: textData.count,
                        fileServerPresent: fileLane != nil,
                        inlineBudgetRemaining: inlineTextBudget
                    )
                    var uploadedKey: String?
                    if let fileLane, plan.serverCopy != .none {
                        let key = Self.storedKey(
                            for: material,
                            filename: filename,
                            conversationID: conversationID,
                            folderCapable: fileLane.folderCapable
                        )
                        try await uploadServerFile(
                            localURL: localURL,
                            storedKey: key,
                            sequence: attachmentSequence,
                            snapshot: fileLane,
                            uploadLedger: uploadLedger
                        )
                        uploadedKey = key
                    }

                    if plan.inline {
                        var draft = AttachmentDraft(
                            mimeType: extracted.mimeType,
                            filename: filename,
                            data: textData,
                            thumbnailData: nil,
                            width: 0,
                            height: 0,
                            byteSize: textData.count,
                            sequence: attachmentSequence
                        )
                        draft.storedKey = uploadedKey
                        result.attachments.append(draft)
                        inlineTextBudget = max(0, inlineTextBudget - textData.count)
                    } else {
                        guard let uploadedKey else {
                            throw WorkboardDispatchError.fileServerRequired
                        }
                        result.attachments.append(Self.serverReference(
                            material: material,
                            filename: filename,
                            mimeType: material.mimeType ?? extracted.mimeType,
                            byteSize: Int(clamping: material.byteSize),
                            storedKey: uploadedKey,
                            previewText: extracted.text,
                            sequence: attachmentSequence
                        ))
                    }
                    attachmentSequence += 1
                    continue
                }

                guard let fileLane else {
                    throw WorkboardDispatchError.fileServerRequired
                }
                let key = Self.storedKey(
                    for: material,
                    filename: filename,
                    conversationID: conversationID,
                    folderCapable: fileLane.folderCapable
                )
                try await uploadServerFile(
                    localURL: localURL,
                    storedKey: key,
                    sequence: attachmentSequence,
                    snapshot: fileLane,
                    uploadLedger: uploadLedger
                )
                result.attachments.append(Self.serverReference(
                    material: material,
                    filename: filename,
                    mimeType: material.mimeType ?? "application/octet-stream",
                    byteSize: Int(clamping: material.byteSize),
                    storedKey: key,
                    previewText: nil,
                    sequence: attachmentSequence
                ))
                attachmentSequence += 1
            }
        }
        return result
    }

    /// The receipt for a send this coordinator has just performed. The store
    /// commits the initial turn as `failed` so retry's failed->sending CAS stays
    /// the single network-attempt authority, and it honestly projects that
    /// unclaimed window as a reviewable failure for every OTHER reader — a crash
    /// there must stay recoverable. This caller is not another reader: it has
    /// already handed the turn to that authority, so its own receipt says the
    /// run is waiting rather than sending the person back to a "Send Again"
    /// button for a brief that is in flight.
    private nonisolated static func receipt(for prepared: PreparedWorkDispatch) -> WorkItemRecord {
        let item = prepared.workItem
        let run = prepared.dispatch
        let waiting = WorkDispatchRecord(
            id: run.id,
            workItemID: run.workItemID,
            conversationID: run.conversationID,
            userMessageID: run.userMessageID,
            gatewayRef: run.gatewayRef,
            gatewayNameSnapshot: run.gatewayNameSnapshot,
            titleSnapshot: run.titleSnapshot,
            promptSnapshot: run.promptSnapshot,
            briefSnapshot: run.briefSnapshot,
            createdAt: run.createdAt,
            dispatchedAt: run.dispatchedAt ?? run.createdAt,
            reviewAcknowledgedAt: run.reviewAcknowledgedAt,
            reviewAcknowledgedResultKey: run.reviewAcknowledgedResultKey,
            conversationRemovedAt: run.conversationRemovedAt,
            activity: .waiting
        )
        // This run is the newest, so appending keeps the store's
        // dispatched-ascending order intact.
        let dispatches = item.dispatches.filter { $0.id != waiting.id } + [waiting]
        return WorkItemRecord(
            id: item.id,
            content: item.content,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt,
            boardOrder: item.boardOrder,
            completedAt: item.completedAt,
            captureEnvelopeID: item.captureEnvelopeID,
            currentDispatchID: item.currentDispatchID,
            materials: item.materials,
            dispatches: dispatches,
            state: WorkItemStateResolver.resolve(
                completedAt: item.completedAt,
                dispatches: dispatches.map(\.stateFacts)
            )
        )
    }

    @concurrent
    private nonisolated static func exactPayload(_ captured: CapturedWorkMaterial) async throws -> Data {
        if let payload = captured.payload { return payload }
        guard let url = captured.localFileURL else {
            throw WorkboardDispatchError.materialUnavailable
        }
        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw WorkboardDispatchError.materialUnavailable
        }
    }

    private nonisolated static func safeFilename(
        _ material: WorkMaterialRecord,
        fallback: String
    ) -> String {
        WorkCaptureEnvelope.safeDisplayName(material.filename ?? material.title) ?? fallback
    }

    private nonisolated static func storedKey(
        for material: WorkMaterialRecord,
        filename: String,
        conversationID: UUID,
        folderCapable: Bool
    ) -> String {
        FileServerClient.makeStoredKey(
            originalName: filename,
            // A new immutable dispatch must never overwrite the flat-server key
            // referenced by an older conversation that reused this material.
            uuid: UUID(),
            folder: ComposerMintFolder.storedKeyFolder(
                bound: nil,
                pending: conversationID,
                folderCapable: folderCapable
            )
        )
    }

    private nonisolated static func serverReference(
        material: WorkMaterialRecord,
        filename: String,
        mimeType: String,
        byteSize: Int,
        storedKey: String,
        previewText: String?,
        sequence: Int
    ) -> AttachmentDraft {
        var draft = AttachmentDraft(
            mimeType: mimeType,
            filename: filename,
            data: Data(),
            thumbnailData: nil,
            width: 0,
            height: 0,
            byteSize: byteSize,
            sequence: sequence
        )
        draft.isServerReference = true
        draft.storedKey = storedKey
        if let previewText {
            draft.previewData = Data(previewText.utf8.prefix(Constants.webPageCaptureMaxBytes))
            draft.previewKind = "text"
        }
        return draft
    }

    private func uploadServerFile(
        localURL: URL,
        storedKey: String,
        sequence: Int,
        snapshot: SettingsManager.FileTransferSnapshot,
        uploadLedger: WorkboardUploadLedger
    ) async throws {
        // Register before I/O: a timeout/cancellation can occur after the server
        // accepted bytes but before the client observed success.
        guard let durableLaneID = uploadLedger.durableLaneID else {
            throw WorkboardDispatchError.fileTransferFailed
        }
        do {
            try await WorkboardUploadJournal.shared.register(
                dispatchID: uploadLedger.dispatchID,
                conversationID: uploadLedger.conversationID,
                gatewayRef: uploadLedger.gatewayRef,
                durableLaneID: durableLaneID,
                storedKey: storedKey,
                sequence: sequence
            )
        } catch {
            throw WorkboardDispatchError.fileTransferFailed
        }
        let upload = WorkboardPendingUpload.Upload(storedKey: storedKey, sequence: sequence)
        if !uploadLedger.uploads.contains(upload) {
            uploadLedger.uploads.append(upload)
        }
        do {
            try await ConversationDetailViewModel.uploadServerFile(
                localURL: localURL,
                storedKey: storedKey,
                snapshot: snapshot,
                recoveryID: uploadLedger.dispatchID,
                recoverySequence: sequence,
                onProgress: { _ in }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Raw URL/TLS errors can contain a private hostname. The Workboard
            // surface exposes a fixed remedy while Diagnostics retains detail.
            throw WorkboardDispatchError.fileTransferFailed
        }
    }

    private func cleanupUploads(
        _ ledger: WorkboardUploadLedger,
        fileLane: SettingsManager.FileTransferSnapshot?
    ) async {
        guard let fileLane else { return }
        // Store failure means "prove nothing": retain every journal key and
        // delete nothing. A cleanup path may never trade uncertainty for loss.
        guard let referenced = try? await store.referencedStoredKeys(
            Set(ledger.uploads.map(\.storedKey))
        ) else { return }
        for upload in ledger.uploads {
            guard !referenced.contains(upload.storedKey) else {
                await WorkboardUploadJournal.shared.acknowledgeReclaimed(
                    dispatchID: ledger.dispatchID,
                    storedKey: upload.storedKey
                )
                continue
            }
            let live = await BackgroundFileTransfer.shared.hasLiveUploadTask(
                shareEnvelopeID: ledger.dispatchID,
                sequence: upload.sequence
            )
            guard !live else { continue }
            let reclaimed = await BackgroundFileTransfer.shared.deleteFileForRecovery(
                snapshot: fileLane,
                storedKey: upload.storedKey
            )
            if reclaimed {
                await WorkboardUploadJournal.shared.acknowledgeReclaimed(
                    dispatchID: ledger.dispatchID,
                    storedKey: upload.storedKey
                )
            }
        }
    }

    @concurrent
    private nonisolated static func temporaryFile(data: Data, filename: String) async throws -> URL {
        let ext = WorkCaptureEnvelope.safePathExtension((filename as NSString).pathExtension)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-workboard-\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
#endif
