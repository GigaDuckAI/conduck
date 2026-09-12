// SPDX-License-Identifier: Apache-2.0

// ConduckWatch Watch App
// WorkboardCaptureIntent.swift
//
// A text-only Siri and Shortcuts lane onto the single Work desk. This is
// deliberately separate from `RecordNoteIntent`: it appends one inert note card
// and has no gateway, conversation, message, or dispatch codepath. The shared
// ConversationStore keeps the capture in the same private CloudKit-backed model
// the other devices read. With content sync disabled, an explicit capture goes
// to the paired phone's durable Work inbox instead: the wrist has no board UI,
// so announcing a note saved only here would strand it invisibly. The phone's
// receipt means queued durably, and the confirmation says where to find it.
//
// The wrist writes the desk with raw Core Data because
// `ConversationStore+Workboard.swift` is not a member of this target, so
// `upsertDeskMaterial` — the app's one authoritative desk write — cannot be
// called here. The logic below mirrors that op's contract for the one shape the
// wrist produces (a note, no payload): resolve-or-create the desk row, then
// insert-or-return the material by id, all inside ONE managed-object context so
// a capture can never leave a desk without its card. Entity and column names,
// and the `kind`/`storageMode` raw values, are restated here for the same
// reason; `WorkboardRecords.swift` is canonical for them.

import AppIntents
import CoreData
import Foundation
import WatchConnectivity

/// One note card's worth of prepared text: the wrist's shape of the same
/// thought the iOS `CaptureWorkboardIntent` hands `WorkMaterialDraft`, so the
/// field names are the material's, not a heading's.
nonisolated struct WatchWorkboardCapture: Equatable, Sendable {
    let title: String
    let textContent: String
}

nonisolated enum WatchWorkboardCaptureText {
    /// Mirrors `WorkCaptureEnvelope.maximumNoteCharacters`, the bound every
    /// other capture ingress enforces — named identically so the source guard
    /// comparing the two spellings has something to compare. The Watch target
    /// does not compile the envelope, so the value is restated here; a Shortcut
    /// can pipe a whole document into this parameter, and an unbounded note is
    /// both unexportable to CloudKit and a cost on every board load.
    static let maximumNoteCharacters = 16_000

    static func prepare(_ rawValue: String) throws -> WatchWorkboardCapture {
        let normalized = rawValue
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw WatchWorkboardCaptureError.emptyThought }
        // Refuse rather than truncate: a silently shortened note looks like a
        // successful capture and loses the part the person cared about.
        guard normalized.count <= maximumNoteCharacters else {
            throw WatchWorkboardCaptureError.thoughtTooLong
        }

        let title = normalized
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            .map { String($0.prefix(72)) }
            ?? String(localized: "workboard.item.untitled", defaultValue: "Untitled note")
        return WatchWorkboardCapture(title: title, textContent: normalized)
    }
}

/// Explicit text capture uses the paired phone when the wrist's desk cannot
/// mirror. A positive result means the phone's durable Work inbox accepted the
/// capture, not that WatchConnectivity merely queued a message. No automatic
/// retry follows an ambiguous acknowledgement; that could duplicate a thought.
protocol WatchWorkTextCaptureTransport {
    func send(_ capture: WatchWorkTextCapture) async throws -> [String: Any]
}

struct WCSessionWorkTextCaptureTransport: WatchWorkTextCaptureTransport {
    func send(_ capture: WatchWorkTextCapture) async throws -> [String: Any] {
        // A cold Siri launch calls App.init's activate(), but activation is
        // asynchronous. Give that handshake a short, cancellable opportunity
        // before judging whether the phone itself can be reached.
        try await WatchWorkTextRelay.awaitSessionActivation(
            isActivated: { WCSession.default.activationState == .activated },
            activate: { WatchSessionManager.shared.activate() }
        )
        guard WCSession.default.isReachable else { throw WatchWorkTextRelayError.phoneUnavailable }
        try Task.checkCancellation()
        let response: SendablePlistPayload? = await withCheckedContinuation { continuation in
            WCSession.default.sendMessage(
                WatchWorkTextCaptureWire.request(capture),
                replyHandler: { continuation.resume(returning: SendablePlistPayload($0)) },
                errorHandler: { _ in continuation.resume(returning: nil) }
            )
        }
        guard let payload = response?.dictionary() else { throw WatchWorkTextRelayError.unconfirmed }
        return payload
    }
}

enum WatchWorkTextRelayError: LocalizedError {
    case connectionStarting, phoneUnavailable, unsupported, refused, unconfirmed, tooLong

    var errorDescription: String? {
        switch self {
        case .connectionStarting:
            String(localized: "intent.workboardCapture.relay.starting",
                   defaultValue: "Your Watch connection is still starting. Try again in a moment.")
        case .phoneUnavailable:
            String(localized: "intent.workboardCapture.relay.unavailable",
                   defaultValue: "Your paired phone is unavailable. Open Conduck there, then try again, or turn on content sync in General settings.")
        case .unsupported:
            String(localized: "intent.workboardCapture.relay.unsupported",
                   defaultValue: "Update Conduck on your paired phone to add this note while content sync is off.")
        case .refused:
            String(localized: "intent.workboardCapture.relay.refused",
                   defaultValue: "Your paired phone couldn’t save this note. Open Conduck there and check available storage, then try again.")
        case .unconfirmed:
            String(localized: "intent.workboardCapture.relay.unconfirmed",
                   defaultValue: "Couldn’t confirm that your paired phone saved the note. Check Work there before trying again.")
        case .tooLong:
            String(localized: "intent.workboardCapture.relay.tooLong",
                   defaultValue: "This note is too long to send from your watch. Shorten it, then try again.")
        }
    }
}

enum WatchWorkTextRelay {
    /// Activation only: this never sends or retries a capture. The injectable
    /// pause proves a cold launch waits without making a test sleep in real time.
    static func awaitSessionActivation(
        isActivated: () -> Bool,
        activate: () -> Void,
        pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(50)) },
        maximumAttempts: Int = 40
    ) async throws {
        guard !isActivated() else { return }
        activate()
        for _ in 0..<maximumAttempts {
            if isActivated() { return }
            try await pause()
        }
        guard isActivated() else { throw WatchWorkTextRelayError.connectionStarting }
    }

    static func send(
        _ capture: WatchWorkTextCapture,
        using transport: any WatchWorkTextCaptureTransport = WCSessionWorkTextCaptureTransport()
    ) async throws {
        guard WatchWorkTextCaptureWire.decode(WatchWorkTextCaptureWire.request(capture)) != nil else {
            throw WatchWorkTextRelayError.tooLong
        }
        let reply = try await transport.send(capture)
        guard let accepted = WatchWorkTextCaptureWire.accepted(reply, for: capture.id) else {
            throw WatchWorkTextRelayError.unsupported
        }
        guard accepted else { throw WatchWorkTextRelayError.refused }
    }

    /// OFF arriving during a committed Watch write cannot turn that successful
    /// save into an "unsaved, try again" error: a new Shortcut invocation owns a
    /// new id and would later create a duplicate. Attempt the same-id relay once,
    /// then describe exactly which durable copy is known to exist.
    static func finishCommittedWatchCapture(
        _ capture: WatchWorkTextCapture,
        using transport: any WatchWorkTextCaptureTransport = WCSessionWorkTextCaptureTransport()
    ) async -> WatchWorkCaptureCompletion {
        do {
            try await send(capture, using: transport)
            return .phone
        } catch let error as WatchWorkTextRelayError {
            switch error {
            case .connectionStarting, .phoneUnavailable, .refused, .tooLong:
                return .watchOnly
            case .unsupported, .unconfirmed:
                return .watchAndUnconfirmedPhone
            }
        } catch {
            return .watchAndUnconfirmedPhone
        }
    }
}

enum WatchWorkCaptureCompletion: Equatable {
    case mirroredWatch, phone, watchOnly, watchAndUnconfirmedPhone

    var confirmation: String {
        switch self {
        case .mirroredWatch:
            String(localized: "intent.workboardCapture.confirmation", defaultValue: "Added to Work. Nothing was sent.")
        case .phone:
            String(localized: "intent.workboardCapture.relay.confirmation",
                   defaultValue: "Saved for Work on your paired phone. Open Conduck there to see it.")
        case .watchOnly:
            String(localized: "intent.workboardCapture.relay.retainedOnWatch",
                   defaultValue: "Saved on your Watch. Turn on content sync in General settings to make it available on your other devices.")
        case .watchAndUnconfirmedPhone:
            String(localized: "intent.workboardCapture.relay.retainedUnconfirmedPhone",
                   defaultValue: "Saved on your Watch; it may also be on your paired phone. Turn on content sync in General settings to make the saved note available on your other devices.")
        }
    }
}

nonisolated enum WatchWorkboardCaptureError: LocalizedError {
    case emptyThought
    case thoughtTooLong

    var errorDescription: String? {
        switch self {
        case .emptyThought:
            return String(
                localized: "intent.workboardCapture.error.empty",
                defaultValue: "Say or type what you want to prepare first."
            )
        case .thoughtTooLong:
            return String(
                localized: "intent.workboardCapture.error.tooLong",
                defaultValue: "That’s too long to add to Work. Shorten it, then try again."
            )
        }
    }
}

extension ConversationStore {
    /// Append one note card to the Work desk from the wrist.
    ///
    /// DESK IDENTITY comes from `Constants.workboardDeskItemID`, the same
    /// compile-time id every other surface names — `Constants.swift` is a
    /// member of this target, so the wrist reads the canonical value rather
    /// than a copy of it. The desk row is created lazily by the first capture,
    /// holds no editable heading (title and objective stay nil columns) and is
    /// never deleted.
    ///
    /// NO DEDUP. CloudKit forbids a Core Data uniqueness constraint, so two
    /// devices capturing at once can each insert a physical desk row under that
    /// one id. Both writes must stand: the board projects one logical desk and
    /// unions the materials of every physical row, so a duplicate row is
    /// invisible rather than lossy. Deleting the loser would export a deletion
    /// of valid data to every other device.
    ///
    /// IDEMPOTENCY is on `id`: a replayed capture finds its own material and
    /// gets its title back instead of adding a second card.
    ///
    /// RANK is decided here rather than by the caller. The wrist cannot see the
    /// board, so the append position is read inside the same transaction that
    /// writes it.
    func upsertDeskMaterial(
        _ capture: WatchWorkboardCapture,
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) async throws -> String {
        try await ensureLoaded()
        let contextLease = try await newWriteContextLease()
        defer { contextLease.finish() }
        let context = contextLease.context
        let deskID = Constants.workboardDeskItemID
        let title = try await context.perform { [context] in
            let deskRequest = NSFetchRequest<NSManagedObject>(entityName: "WorkItem")
            deskRequest.predicate = NSPredicate(format: "id == %@", deskID as CVarArg)
            deskRequest.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
            deskRequest.fetchLimit = 1

            var createdDesk = false
            let desk: NSManagedObject
            if let existing = try context.fetch(deskRequest).first {
                desk = existing
            } else {
                desk = NSEntityDescription.insertNewObject(forEntityName: "WorkItem", into: context)
                desk.setValue(deskID, forKey: "id")
                desk.setValue(createdAt, forKey: "createdAt")
                desk.setValue(createdAt, forKey: "updatedAt")
                createdDesk = true
            }

            let materialRequest = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
            materialRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            materialRequest.sortDescriptors = [
                NSSortDescriptor(key: "updatedAt", ascending: false)
            ]
            materialRequest.fetchLimit = 1
            if let existing = try context.fetch(materialRequest).first {
                // The card is already on the desk. The desk row may still be
                // the one this call just created — CloudKit can import a
                // material before its owner — so a re-ensured desk is saved
                // even though the material is untouched.
                if createdDesk { try context.save() }
                return existing.value(forKey: "title") as? String ?? capture.title
            }

            let rankRequest = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
            rankRequest.predicate = NSPredicate(format: "workItemID == %@", deskID as CVarArg)
            rankRequest.sortDescriptors = [NSSortDescriptor(key: "sequence", ascending: false)]
            rankRequest.fetchLimit = 1
            let highestRank = try context.fetch(rankRequest).first
                .flatMap { ($0.value(forKey: "sequence") as? NSNumber)?.intValue }

            let row = NSEntityDescription.insertNewObject(
                forEntityName: "WorkMaterial",
                into: context
            )
            row.setValue(id, forKey: "id")
            row.setValue(deskID, forKey: "workItemID")
            row.setValue("note", forKey: "kind")
            row.setValue(capture.title, forKey: "title")
            row.setValue("", forKey: "caption")
            row.setValue(capture.textContent, forKey: "textContent")
            row.setValue(NSNumber(value: 0), forKey: "byteSize")
            row.setValue(NSNumber(value: Int32(clamping: (highestRank ?? -1) + 1)), forKey: "sequence")
            row.setValue("metadataOnly", forKey: "storageMode")
            // `cardSize` stays nil: standard is the absent value, and the wrist
            // never sizes a card.
            row.setValue("watch", forKey: "sourceDevice")
            row.setValue(createdAt, forKey: "createdAt")
            row.setValue(createdAt, forKey: "updatedAt")
            desk.setValue(createdAt, forKey: "updatedAt")
            try context.save()
            return capture.title
        }
        await postDidChange()
        return title
    }
}

struct CaptureWorkboardIntent: AppIntent {
    static var title: LocalizedStringResource = LocalizedStringResource(
        "intent.workboardCapture.title",
        defaultValue: "Add to Work"
    )

    static var description = IntentDescription(
        LocalizedStringResource(
            "intent.workboardCapture.description",
            defaultValue: "Save a thought to your private Work desk without sending it to an AI."
        )
    )

    static var supportedModes: IntentModes = [.background]

    @Parameter(
        title: LocalizedStringResource(
            "intent.workboardCapture.thought",
            defaultValue: "What needs doing?"
        )
    )
    var thought: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$thought) to Work")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let capture = try WatchWorkboardCaptureText.prepare(thought)
        let relayCapture = WatchWorkTextCapture(id: UUID(), text: capture.textContent, createdAt: Date())
        // Each run of the Shortcut is its own capture, so the material id is
        // minted per invocation rather than derived from the text: two runs
        // carrying the same words are two cards the person asked for.
        let completion: WatchWorkCaptureCompletion
        if ContentSyncPreferenceStore.shared.isEnabled {
            _ = try await ConversationStore.shared.upsertDeskMaterial(
                capture, id: relayCapture.id, createdAt: relayCapture.createdAt
            )
            // A remote OFF can arrive while the database write suspends. Reuse
            // this capture id on the phone so later mirroring still identifies
            // one logical note; never announce a newly stranded wrist note.
            if ContentSyncPreferenceStore.shared.isEnabled {
                completion = .mirroredWatch
            } else {
                completion = await WatchWorkTextRelay.finishCommittedWatchCapture(relayCapture)
            }
        } else {
            try await WatchWorkTextRelay.send(relayCapture)
            completion = .phone
        }
        let title = capture.title
        let confirmation = completion.confirmation
        return .result(value: title, dialog: IntentDialog(stringLiteral: confirmation))
    }
}
