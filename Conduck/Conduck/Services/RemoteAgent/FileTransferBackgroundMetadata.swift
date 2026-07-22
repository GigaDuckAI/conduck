//
//  FileTransferBackgroundMetadata.swift
//  Conduck
//
//  Recovery envelope persisted alongside a background file-transfer URLSession
//  task so a relaunched app process can re-resolve which gateway/file an
//  in-flight upload or download belongs to.
//
//  WHY: a background URLSession can outlive the app process. On relaunch the
//  system hands us the task again (via ConduckApp's 4th .backgroundTask
//  handler) but BackgroundFileTransfer's in-memory in-flight registry is gone.
//  The metadata — encoded into the task's taskDescription — lets us rebuild
//  enough context (which file-server ref, which storedKey, which direction) to
//  finish or discard delivery.
//
//  Mirrors RemoteAgentBackgroundMetadata. PRIVACY: storedKey is
//  an opaque "<shortid>__<sanitized name>" token, not user content, but it is
//  still never logged — it lives only inside taskDescription.
//

import Foundation

/// Recovery envelope for a background file-transfer task. Encoded into the
/// task's `taskDescription` (a String) so it survives app relaunch.
struct FileTransferBackgroundMetadata: Codable, Sendable {

    /// Whether the task is pushing bytes up to, or pulling bytes down from, the
    /// file-server.
    enum Direction: String, Codable, Sendable {
        case upload
        case download
    }

    /// The flat-folder stored name on the file-server (`<shortid>__<name>`).
    let storedKey: String

    /// The file-server ref this task targets (storage-key suffix form).
    let refSuffix: String

    /// Whether this task uploads or downloads `storedKey`.
    let direction: Direction

    /// Share-Extension envelope id, when this upload belongs to a shared-inbox
    /// drain (`nil` for the in-app composer's uploads). The drainer's
    /// cross-launch reconcile matches this + `sequence` against live upload
    /// tasks (`hasLiveUploadTask(shareEnvelopeID:sequence:)`) to decide
    /// task-alive-defer vs. no-task-re-PUT (the deterministic key makes a re-PUT
    /// idempotent — WebDAV PUT to the same path overwrites identical bytes, no
    /// orphan). ADDITIVE + TOLERANT: an `Optional` property's synthesized
    /// `Codable` decoder uses `decodeIfPresent`, so a taskDescription written
    /// before these fields existed still decodes (keys absent → `nil`).
    let shareEnvelopeID: UUID?

    /// The attachment's 0-based ordinal within the share envelope (pairs with
    /// `shareEnvelopeID` to identify a single attachment's upload). `nil` for
    /// non-share uploads.
    let sequence: Int?

    /// Explicit memberwise init with `shareEnvelopeID` + `sequence` DEFAULTED to
    /// `nil` so the existing construction sites (the in-app upload/download in
    /// `BackgroundFileTransfer`, tests) stay byte-identical — only the
    /// Share-Extension drain path passes non-nil values. (A synthesized
    /// memberwise init can't carry a default, hence the hand-written one.)
    init(
        storedKey: String,
        refSuffix: String,
        direction: Direction,
        shareEnvelopeID: UUID? = nil,
        sequence: Int? = nil
    ) {
        self.storedKey = storedKey
        self.refSuffix = refSuffix
        self.direction = direction
        self.shareEnvelopeID = shareEnvelopeID
        self.sequence = sequence
    }

    // MARK: - taskDescription bridging

    /// Encode to a JSON string for `URLSessionTask.taskDescription`.
    func encoded() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decode from a `URLSessionTask.taskDescription` JSON string.
    static func decoded(from string: String?) -> FileTransferBackgroundMetadata? {
        guard let string, let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(FileTransferBackgroundMetadata.self, from: data)
    }
}
