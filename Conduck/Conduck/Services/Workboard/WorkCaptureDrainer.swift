// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkCaptureDrainer.swift
//
// Imports the Workboard's inert App-Group capture queue into private Workboard
// persistence. A capture may append to an open Work item selected in the Share
// Extension; a stale missing/Done destination falls back to a clearly labelled
// new draft. Envelope and entry UUIDs are reused as database identities, so a
// crash after any individual write is repaired by replay rather than by making a
// second card or material. A claim is acknowledged only after the card and every
// material are durable. This type has no gateway dependency and no dispatch API:
// opening the app can drain captures, but can never turn one into network work.

#if !os(watchOS)

import Foundation

actor WorkCaptureDrainer {
    struct Report: Sendable, Equatable {
        let importedCaptureCount: Int
        let replayedCaptureCount: Int
        let invalidCaptureCount: Int
        let importedMaterialCount: Int

        static let empty = Report(
            importedCaptureCount: 0,
            replayedCaptureCount: 0,
            invalidCaptureCount: 0,
            importedMaterialCount: 0
        )
    }

    private struct PersistedCapture: Sendable {
        let wasReplay: Bool
        let materialCount: Int
    }

    private struct Destination: Sendable {
        let item: WorkItemRecord
        let appendsToExistingItem: Bool
        let wasReplay: Bool
        let startingSequence: Int
    }

    private let inbox: WorkCaptureInbox
    private let store: ConversationStore
    private let sourceDevice: String

    init(
        inbox: WorkCaptureInbox = .shared,
        store: ConversationStore = .shared,
        sourceDevice: String
    ) {
        self.inbox = inbox
        self.store = store
        self.sourceDevice = sourceDevice
    }

    /// Reconcile crash-stranded claims, then consume the queue oldest-first.
    /// Malformed captures have already been removed by `claimNext`; they do not
    /// prevent a later valid capture from importing. A persistence failure puts
    /// the active claim back before surfacing the error, preserving its bytes.
    func drainAvailableCaptures() async throws -> Report {
        _ = await inbox.reconcile()

        var importedCaptureCount = 0
        var replayedCaptureCount = 0
        var invalidCaptureCount = 0
        var importedMaterialCount = 0

        while true {
            let claim: WorkCaptureInbox.Claim?
            do {
                claim = try await inbox.claimNext()
            } catch let error as WorkCaptureInbox.InboxError {
                if case .invalidEnvelope = error {
                    invalidCaptureCount += 1
                    continue
                }
                throw error
            }

            guard let claim else { break }
            do {
                let persisted = try await persist(claim)
                try await inbox.acknowledge(claim)
                if persisted.wasReplay {
                    replayedCaptureCount += 1
                } else {
                    importedCaptureCount += 1
                }
                importedMaterialCount += persisted.materialCount
            } catch {
                // Best effort is deliberately only for the ownership rollback.
                // The original persistence error remains the useful diagnosis;
                // a failed release is repaired by `reconcile` after relaunch.
                try? await inbox.release(claim)
                throw error
            }
        }

        return Report(
            importedCaptureCount: importedCaptureCount,
            replayedCaptureCount: replayedCaptureCount,
            invalidCaptureCount: invalidCaptureCount,
            importedMaterialCount: importedMaterialCount
        )
    }

    private func persist(_ claim: WorkCaptureInbox.Claim) async throws -> PersistedCapture {
        let envelope = claim.envelope
        let destination = try await destination(for: envelope)
        let item = destination.item

        var materialCount = 0
        var nextSequence = destination.startingSequence

        // On an append, the share-sheet note is source material, not a rewrite of
        // the existing objective. Persist it first as a visible note. Its UUID is
        // deterministic from the envelope, so it is also the crash marker that
        // keeps a partially appended capture on the same destination after replay.
        let trimmedNote = envelope.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if destination.appendsToExistingItem, !trimmedNote.isEmpty {
            _ = try await store.addWorkMaterial(
                WorkMaterialDraft(
                    id: try Self.noteMaterialID(for: envelope),
                    kind: .note,
                    title: String(localized: "workboard.capture.note", defaultValue: "Share note"),
                    textContent: trimmedNote,
                    sequence: nextSequence,
                    storageMode: .metadataOnly,
                    sourceDevice: sourceDevice,
                    createdAt: envelope.createdAt
                ),
                to: item.id
            )
            nextSequence += 1
            materialCount += 1
        }

        for entry in envelope.entries.sorted(by: Self.entryOrder) {
            let draft = try Self.materialDraft(
                for: entry,
                in: claim,
                sourceDevice: sourceDevice,
                createdAt: envelope.createdAt,
                sequence: destination.appendsToExistingItem ? nextSequence : entry.sequence
            )
            if let payloadURL = claim.payloadURL(for: entry) {
                let byteSize: Int64
                if let capturedByteCount = entry.byteCount {
                    byteSize = capturedByteCount
                } else {
                    byteSize = Int64(
                        try payloadURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    )
                }
                _ = try await store.addWorkMaterialFile(
                    draft,
                    from: payloadURL,
                    byteSize: byteSize,
                    to: item.id
                )
            } else {
                _ = try await store.addWorkMaterial(draft, to: item.id)
            }
            nextSequence += 1
            materialCount += 1
        }

        return PersistedCapture(wasReplay: destination.wasReplay, materialCount: materialCount)
    }

    /// Resolve the destination before writing the first material. A capture-made
    /// card (identified by `captureEnvelopeID`) always wins on replay. Otherwise
    /// an explicitly selected item is accepted while open. If at least one of
    /// this envelope's deterministic material IDs already exists there, a replay
    /// continues on that same item even if it became Done after the first write;
    /// this is the durable decision marker that prevents split/duplicate imports.
    private func destination(for envelope: WorkCaptureEnvelope) async throws -> Destination {
        if let replay = try await store.fetchWorkItem(captureEnvelopeID: envelope.id) {
            return Destination(
                item: replay,
                appendsToExistingItem: false,
                wasReplay: true,
                startingSequence: 0
            )
        }

        if let targetID = envelope.targetWorkItemID,
           let target = try await store.fetchWorkItem(id: targetID) {
            let expectedIDs = try Self.materialIDs(for: envelope)
            let didStartAppending = target.materials.contains { expectedIDs.contains($0.id) }
            if target.state != .done || didStartAppending {
                let nextSequence = (target.materials.map(\.sequence).max() ?? -1) + 1
                return Destination(
                    item: target,
                    appendsToExistingItem: true,
                    wasReplay: didStartAppending,
                    startingSequence: nextSequence
                )
            }
        }

        let fellBackFromUnavailableTarget = envelope.targetWorkItemID != nil
        let item = try await store.createWorkItem(
            WorkItemDraft(
                id: envelope.id,
                captureEnvelopeID: envelope.id,
                content: Self.content(
                    for: envelope,
                    fellBackFromUnavailableTarget: fellBackFromUnavailableTarget
                ),
                createdAt: envelope.createdAt
            )
        )
        return Destination(
            item: item,
            appendsToExistingItem: false,
            wasReplay: false,
            startingSequence: 0
        )
    }

    // MARK: - Deterministic capture mapping

    private static func content(
        for envelope: WorkCaptureEnvelope,
        fellBackFromUnavailableTarget: Bool
    ) -> WorkItemContent {
        let note = envelope.note.trimmingCharacters(in: .whitespacesAndNewlines)
        return WorkItemContent(
            title: inferredTitle(note: note, entries: envelope.entries),
            objective: note,
            context: fellBackFromUnavailableTarget
                ? String(
                    localized: "workboard.capture.targetUnavailable",
                    defaultValue: "The selected Work item was no longer open, so this capture was saved as a new draft."
                )
                : "",
            desiredOutcome: "",
            constraints: "",
            dueAt: nil,
            preferredGatewayRef: nil,
            isPinned: false
        )
    }

    private static func inferredTitle(
        note: String,
        entries: [WorkCaptureEnvelope.Entry]
    ) -> String {
        if let line = firstUsefulLine(in: note) { return line }

        for entry in entries.sorted(by: entryOrder) {
            if let name = entry.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                return String(name.prefix(72))
            }
            switch entry.kind {
            case .url:
                if let value = entry.text,
                   let host = URLComponents(string: value)?.host,
                   !host.isEmpty {
                    return String(host.prefix(72))
                }
            case .text:
                if let text = entry.text, let line = firstUsefulLine(in: text) {
                    return line
                }
            case .image, .file, .webPage:
                continue
            }
        }

        return String(localized: "workboard.capture.untitled", defaultValue: "Captured material")
    }

    private static func firstUsefulLine(in value: String) -> String? {
        value
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            .map { String($0.prefix(72)) }
    }

    private static func entryOrder(
        _ lhs: WorkCaptureEnvelope.Entry,
        _ rhs: WorkCaptureEnvelope.Entry
    ) -> Bool {
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// IDs that prove this capture started appending to a target. The note ID is
    /// included only when a visible note will actually be written.
    private static func materialIDs(for envelope: WorkCaptureEnvelope) throws -> Set<UUID> {
        var ids = Set(envelope.entries.map(\.id))
        if !envelope.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ids.insert(try noteMaterialID(for: envelope))
        }
        return ids
    }

    /// Stable visible-note identity without expanding the cross-process manifest.
    /// Normally the envelope UUID itself is available. In the pathological case
    /// an entry already uses it, walk deterministic suffix variants; validation
    /// caps entries, so one of the first `maximumEntryCount + 1` variants must be
    /// free.
    private static func noteMaterialID(for envelope: WorkCaptureEnvelope) throws -> UUID {
        let entryIDs = Set(envelope.entries.map(\.id))
        if !entryIDs.contains(envelope.id) { return envelope.id }

        let raw = envelope.id.uuidString.lowercased()
        let prefix = String(raw.dropLast(2))
        let suffix = Int(raw.suffix(2), radix: 16) ?? 0
        for offset in 1...(WorkCaptureEnvelope.maximumEntryCount + 1) {
            let candidateString = prefix + String(format: "%02x", (suffix + offset) & 0xff)
            if let candidate = UUID(uuidString: candidateString), !entryIDs.contains(candidate) {
                return candidate
            }
        }
        // `entries` is bounded below the candidate count, so this is unreachable
        // for every validated envelope. Fail closed rather than ever letting an
        // ID collision make the note mask a different source material.
        throw WorkCaptureInbox.InboxError.invalidEnvelope(envelope.id, .duplicateEntry)
    }

    private static func materialDraft(
        for entry: WorkCaptureEnvelope.Entry,
        in claim: WorkCaptureInbox.Claim,
        sourceDevice: String,
        createdAt: Date,
        sequence: Int
    ) throws -> WorkMaterialDraft {
        switch entry.kind {
        case .text:
            let text = entry.text ?? ""
            return WorkMaterialDraft(
                id: entry.id,
                kind: .note,
                title: entry.displayName
                    ?? String(localized: "workboard.capture.sharedText", defaultValue: "Shared text"),
                textContent: text,
                sequence: sequence,
                storageMode: .metadataOnly,
                sourceDevice: sourceDevice,
                createdAt: createdAt
            )

        case .url:
            let value = entry.text ?? ""
            let host = URLComponents(string: value)?.host
            return WorkMaterialDraft(
                id: entry.id,
                kind: .link,
                title: entry.displayName ?? host ?? value,
                urlString: value,
                sequence: sequence,
                storageMode: .metadataOnly,
                sourceDevice: sourceDevice,
                createdAt: createdAt
            )

        case .image, .file, .webPage:
            guard let payloadURL = claim.payloadURL(for: entry) else {
                throw WorkCaptureInbox.InboxError.invalidEnvelope(claim.id, .missingPayload)
            }
            let byteSize: Int64
            if let capturedByteCount = entry.byteCount {
                byteSize = capturedByteCount
            } else {
                byteSize = Int64(
                    try payloadURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                )
            }
            let isImage = entry.kind == .image
            let isWebPage = entry.kind == .webPage
            let fallbackTitle: String = {
                if isImage {
                    return String(localized: "workboard.capture.image", defaultValue: "Image")
                }
                if isWebPage {
                    return String(localized: "workboard.capture.webPage", defaultValue: "Web page")
                }
                return String(localized: "workboard.capture.file", defaultValue: "File")
            }()
            let filename = entry.displayName ?? entry.relativePath
            return WorkMaterialDraft(
                id: entry.id,
                kind: isImage ? .image : .file,
                title: entry.displayName ?? fallbackTitle,
                // A text extract is still the user's file content. Files stay
                // device-local, so only their metadata enters the synced row.
                textContent: nil,
                filename: filename,
                mimeType: entry.mimeType,
                payload: nil,
                thumbnailData: isImage ? thumbnail(from: payloadURL, byteSize: byteSize) : nil,
                byteSize: byteSize,
                sequence: sequence,
                storageMode: WorkAssetVault.shouldMirror(byteCount: byteSize)
                    ? .syncedPayload : .localVault,
                sourceDevice: sourceDevice,
                createdAt: createdAt
            )
        }
    }

    private static func thumbnail(from url: URL, byteSize: Int64) -> Data? {
        guard WorkAssetVault.shouldMirror(byteCount: byteSize),
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        return ImageProcessor.thumbnailOnly(from: data)
    }
}

#endif
