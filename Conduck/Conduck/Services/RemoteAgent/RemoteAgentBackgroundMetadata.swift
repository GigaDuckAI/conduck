// Conduck
// RemoteAgentBackgroundMetadata.swift
//
// Codable envelope attached to the converse upload task's
// `URLSessionTask.taskDescription`. Analogous to
// `STTBackgroundTaskMetadata` (Services/STT/STTBackgroundTaskMetadata.swift):
// when the system relaunches us after a kill mid-converse, the delegate
// decodes this from `taskDescription` and recovers both the request-body
// file path (for request-body cleanup) and the conversation ID (so the decoded
// agent reply lands on the right thread in the store).
//
// JSON-encoded for parse safety (paths can contain `|` etc — same rationale
// as `STTBackgroundTaskMetadata`). Also carries the backend raw value so the
// status map can be recovered after a cross-launch resume.

import Foundation

/// Metadata persisted via `URLSessionTask.taskDescription` so the converse
/// background URLSession delegate can recover context even after the app
/// process is recycled.
struct RemoteAgentBackgroundMetadata: Codable, Sendable {
    /// Absolute path to the request-body file on disk (used for `removeItem`
    /// cleanup in the delegate completion handler).
    let bodyPath: String

    /// The conversation the agent reply should append to (UUID string).
    let conversationID: String

    /// Backend raw value (`"openclaw"` / `"hermes"`) — recovers the status
    /// map after a cross-launch resume. Defaults to `.openclaw` on decode
    /// miss (mirrors `STTBackgroundTaskMetadata`'s provider fallback).
    let backendRawValue: String

    /// The TRUE gateway identity (`RemoteAgentRef.rawString`:
    /// `"openclaw"` / `"hermes"` / `"custom_<uuid>"`). Distinct from
    /// `backendRawValue`, which is the status-map CARRIER and is `"openclaw"`
    /// for EVERY custom gateway (a custom snapshot's `backend` is `.openclaw`).
    /// The cert-pin trust delegate recovers this after a cross-launch resume
    /// and resolves the per-ref pin LIVE from App-Group UserDefaults — keying
    /// off the backend would mis-pin every custom gateway to OpenClaw's cert.
    /// ADDITIVE + TOLERANT — same `decodeIfPresent` rationale as
    /// `shareEnvelopeID`: a `taskDescription` written before this field existed
    /// (an in-flight task enqueued pre-upgrade) decodes with `refRawValue` nil,
    /// and the delegate falls through to default ATS (the pre-fix behavior, not
    /// a crash).
    let refRawValue: String?

    /// Share-Extension envelope id, when this converse turn originated from a
    /// shared-inbox drain (`nil` for every other caller — in-app, headless
    /// Shortcut, Watch, CarPlay). The drainer's cross-launch reconcile matches
    /// this against live converse tasks (`hasLiveConverseTask(shareEnvelopeID:)`)
    /// to avoid a duplicate gateway dispatch after a kill. ADDITIVE + TOLERANT:
    /// an `Optional` property's synthesized `Codable` decoder uses
    /// `decodeIfPresent`, so a taskDescription written before this field existed
    /// still decodes (the key is simply absent → `nil`).
    let shareEnvelopeID: UUID?

    /// The `Message.id` of THIS turn's user message, when the dispatch site
    /// knows it (in-app VM, headless intent, share drain). Enables EXACT
    /// per-message status flips in the delegates: the conversation-wide
    /// `markPendingUserTurns` aliases SIBLING in-flight turns (two concurrent
    /// `sending` turns in one conversation — a long headless think + an in-app
    /// follow-up — and whichever resolves first flips both). `nil` (old
    /// taskDescription blobs, callers not yet threading it) falls back to the
    /// conversation-wide flip. ADDITIVE + TOLERANT — same `decodeIfPresent`
    /// rationale as `shareEnvelopeID`.
    let userMessageID: UUID?

    /// True when this turn originated from a HEADLESS quick capture
    /// (ConverseIntent, Watch headless trigger) and the delegate's reply
    /// path should stamp the per-device quick-capture pointer
    /// (`recordActiveConversation`). `nil`/`false` (in-app VM, share drain,
    /// pinned Watch composer, old in-flight blobs) → never stamp. Explicit
    /// surfaces must not retarget the quick lane — the pointer is written by
    /// implicit captures only. ADDITIVE + TOLERANT — same `decodeIfPresent`
    /// rationale as `shareEnvelopeID`.
    let stampsActiveConversation: Bool?

    /// Whether the dispatched request carried historical `image_url` parts —
    /// recorded at dispatch (post-policy, post-compat) so a cross-launch
    /// failure can still persist the poisoned-chat classification (the
    /// image-history policy can demote stored images to file references, so
    /// nothing derivable at failure time is trustworthy). `nil` = unknown
    /// (old blobs / callers not yet threading it) → hedged copy. ADDITIVE +
    /// TOLERANT — same `decodeIfPresent` rationale as `shareEnvelopeID`.
    let requestHadHistoryImages: Bool?

    /// Explicit memberwise init with `shareEnvelopeID` / `userMessageID` /
    /// `stampsActiveConversation` / `requestHadHistoryImages` DEFAULTED to
    /// `nil` so the existing construction sites (CarPlay uploader, the
    /// converse `send(...)`'s non-share callers, tests) stay byte-identical —
    /// only sites that know the value pass one. (A synthesized memberwise
    /// init can't carry a default, hence the hand-written one.)
    init(
        bodyPath: String,
        conversationID: String,
        backendRawValue: String,
        refRawValue: String? = nil,
        shareEnvelopeID: UUID? = nil,
        userMessageID: UUID? = nil,
        stampsActiveConversation: Bool? = nil,
        requestHadHistoryImages: Bool? = nil
    ) {
        self.bodyPath = bodyPath
        self.conversationID = conversationID
        self.backendRawValue = backendRawValue
        self.refRawValue = refRawValue
        self.shareEnvelopeID = shareEnvelopeID
        self.userMessageID = userMessageID
        self.stampsActiveConversation = stampsActiveConversation
        self.requestHadHistoryImages = requestHadHistoryImages
    }

    /// JSON-encode + UTF-8 stringify for attachment to
    /// `URLSessionTask.taskDescription`.
    func encodedString() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let str = String(data: data, encoding: .utf8) else {
            throw AppError.remoteAgentInvalidResponse
        }
        return str
    }

    /// Decode from the string previously written to `taskDescription`.
    static func decode(_ s: String) throws -> RemoteAgentBackgroundMetadata {
        guard let data = s.data(using: .utf8) else {
            throw AppError.remoteAgentInvalidResponse
        }
        return try JSONDecoder().decode(RemoteAgentBackgroundMetadata.self, from: data)
    }
}
