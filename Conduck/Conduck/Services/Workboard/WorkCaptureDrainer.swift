// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkCaptureDrainer.swift
//
// Imports the Workboard's inert App-Group capture queue into private Workboard
// persistence. Work is a single desk, so the drainer resolves no destination: a
// share-sheet capture, a menu-bar capture and a GigaAction voice note all land
// on `Constants.workboardDeskItemID` through `ConversationStore.upsertDeskMaterial`,
// and `targetWorkItemID` — which the share extension cannot resolve from its
// sandbox anyway — is carried by the envelope but never honoured here. Envelope
// and entry UUIDs are reused as database identities, so a crash after any
// individual write is repaired by replay rather than by making a second
// material. A claim is acknowledged only after every material this capture
// wrote reads back out of the store, because the queue holds the only copy of a
// shared file until then. This type has no gateway dependency and no dispatch
// API: opening the app can drain captures, but can never turn one into network
// work.

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
        /// Every material this capture published, in the order it was written.
        /// The acknowledgement barrier reads these back before the queue copy
        /// of the bytes is destroyed.
        let materialIDs: [UUID]

        var materialCount: Int { materialIDs.count }
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
                try await confirmDurablyImported(persisted.materialIDs)
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

    /// Publish one claimed capture onto the desk. Publication order is the
    /// order the cards appear in: the person's own note first, then the shared
    /// entries by their captured sequence. Rank itself is decided inside the
    /// desk write, which is the only place that can count the desk's existing
    /// cards without racing a concurrent capture.
    private func persist(_ claim: WorkCaptureInbox.Claim) async throws -> PersistedCapture {
        let envelope = claim.envelope
        // A capture whose deterministic ids are already on the desk is the
        // replay of an import that was interrupted before its claim could be
        // acknowledged. The desk's material set answers that in one fetch.
        let expectedIDs = try Self.materialIDs(for: envelope)
        let wasReplay = try await !deskMaterialIDs().isDisjoint(with: expectedIDs)

        var materialIDs: [UUID] = []

        // The share-sheet note is source material in its own right, and every
        // capture carries it onto the desk — including the first one ever made,
        // which has no earlier card to be read as an annotation of. Its UUID is
        // deterministic from the envelope, so a replay repairs the same card.
        let trimmedNote = envelope.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNote.isEmpty {
            let note = try await store.upsertDeskMaterial(
                WorkMaterialDraft(
                    id: try Self.noteMaterialID(for: envelope),
                    kind: .note,
                    title: String(localized: "workboard.capture.note", defaultValue: "Share note"),
                    textContent: trimmedNote,
                    storageMode: .metadataOnly,
                    sourceDevice: sourceDevice,
                    createdAt: envelope.createdAt
                )
            )
            materialIDs.append(note.id)
        }

        for entry in envelope.entries.sorted(by: Self.entryOrder) {
            let draft = try Self.materialDraft(
                for: entry,
                in: claim,
                sourceDevice: sourceDevice,
                createdAt: envelope.createdAt
            )
            let record: WorkMaterialRecord
            if let payloadURL = claim.payloadURL(for: entry) {
                let byteSize: Int64
                if let capturedByteCount = entry.byteCount {
                    byteSize = capturedByteCount
                } else {
                    byteSize = Int64(
                        try payloadURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    )
                }
                record = try await store.upsertDeskMaterial(
                    draft,
                    sourceFileURL: payloadURL,
                    sourceFileByteSize: byteSize
                )
            } else {
                record = try await store.upsertDeskMaterial(draft)
            }
            materialIDs.append(record.id)
        }

        return PersistedCapture(wasReplay: wasReplay, materialIDs: materialIDs)
    }

    /// The material ids the desk currently holds. The projection unions every
    /// physical desk row, so a duplicate row imported from another device does
    /// not hide a card this drainer already wrote.
    private func deskMaterialIDs() async throws -> Set<UUID> {
        let desk = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        return Set(desk?.materials.map(\.id) ?? [])
    }

    /// The acknowledgement barrier. `WorkCaptureInbox.acknowledge` is the only
    /// thing that deletes a capture's bytes, and for a shared file the queue
    /// holds the only copy, so nothing is acknowledged until everything this
    /// capture wrote reads back out of the store. A material that does not read
    /// back throws, which returns the claim to the queue for a later replay.
    ///
    /// BYTE-SYNC EXTENSION POINT: when payload bytes move out of the device
    /// vault into their own blob store, widen "durable" here — a material row
    /// naming a blob is not durable until that blob row is readable too. The
    /// publication protocol writes the blob first, the material second and
    /// acknowledges third, and this one function is where the third step waits
    /// for the first two. Extending it here keeps the barrier in a single place
    /// instead of once per capture surface.
    private func confirmDurablyImported(_ materialIDs: [UUID]) async throws {
        guard !materialIDs.isEmpty else { return }
        let durable = try await deskMaterialIDs()
        guard Set(materialIDs).isSubset(of: durable) else {
            throw WorkboardStoreError.materialNotFound
        }
    }

    // MARK: - Deterministic capture mapping

    private static func entryOrder(
        _ lhs: WorkCaptureEnvelope.Entry,
        _ rhs: WorkCaptureEnvelope.Entry
    ) -> Bool {
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// Every database identity this capture will publish. Their presence on the
    /// desk is what tells a replay from a first import; the note ID is included
    /// only when a visible note will actually be written. Publication validation
    /// refuses an envelope with neither a note nor an entry, so this is never
    /// empty for a claimed capture.
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

    /// Map one envelope entry to its card. `sequence` is deliberately left at the
    /// draft default: the desk write assigns rank inside its own transaction.
    private static func materialDraft(
        for entry: WorkCaptureEnvelope.Entry,
        in claim: WorkCaptureInbox.Claim,
        sourceDevice: String,
        createdAt: Date
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
                // A text extract is still the user's file content, and only the
                // metadata of a file enters the material row: the bytes are
                // staged by the storage path the desk write chooses.
                textContent: nil,
                filename: filename,
                mimeType: entry.mimeType,
                payload: nil,
                byteSize: byteSize,
                storageMode: .localVault,
                sourceDevice: sourceDevice,
                createdAt: createdAt
            )
        }
    }
}

#endif
