// SPDX-License-Identifier: Apache-2.0

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

    /// Stable one-way identity of the exact READY file-transfer lane captured
    /// for this dispatch. Credentials and URLs never enter task metadata.
    /// Optional for backward compatibility with tasks enqueued before v7.
    let fileTransferLaneID: String?

    /// The per-dispatch output folder (`<conversationID>/out-<hex>`) this turn
    /// named on the wire. Rides the task metadata for the same reason
    /// `fileTransferLaneID` does: it is a DISPATCH-TIME fact that cannot be
    /// reconstructed when the reply lands, and this is the ONLY channel that
    /// survives a process kill mid-turn — a relaunched delegate has nothing but
    /// `taskDescription` to tell it which folder this reply was told to write
    /// into. Carries no secret: a folder path, no credential, no URL.
    ///
    /// `nil` = unknown (a task enqueued before this field existed, a surface
    /// that mints no folder). Nil is UNKNOWN, never EMPTY — the landing path
    /// persists nil and the row selects itself out of the automatic pass rather
    /// than concluding the reply produced nothing. ADDITIVE + TOLERANT — same
    /// `decodeIfPresent` rationale as `shareEnvelopeID`.
    let outputBoxKey: String?

    /// The gateway CONFIG signature captured at dispatch
    /// (`GatewayChatSuccess.signature`). Rides the task metadata for the same
    /// reason `requestHadHistoryImages` does: it is a DISPATCH-TIME fact that
    /// cannot be reconstructed when the reply lands. A turn can run for minutes
    /// and the user can edit the gateway meanwhile, so recomputing at landing
    /// would credit the NEW configuration with a success the OLD one earned.
    ///
    /// Carries no secret: it is a truncated SHA-256 over canonical config
    /// strings, with the token contributing presence only.
    ///
    /// `nil` = unknown (old in-flight blobs, or a ref that wasn't configured at
    /// dispatch) → no success is recorded, which is the fail-closed direction.
    /// ADDITIVE + TOLERANT — same `decodeIfPresent` rationale as
    /// `shareEnvelopeID`.
    let dispatchChatSignature: String?

    /// The gateway-attempt ledger row THIS dispatch opened, when one was opened.
    /// Carried so the terminal callback can close the exact row it belongs to
    /// after a relaunch — `taskDescription` is the only channel that survives a
    /// process kill mid-turn, and an attempt whose id died with the old process
    /// could never be closed by anyone.
    ///
    /// `nil` is a FIRST-CLASS value, not a degraded one: capture is fail-open, so
    /// a dispatch whose ledger insert failed (or a build that predates the
    /// ledger) carries nil here and lands through the same path it always did,
    /// measuring nothing and fabricating nothing. That is why the enqueue site
    /// pre-encodes BOTH variants of this envelope before the insert is attempted
    /// — no encode may fail between a successful insert and `task.resume()`.
    /// ADDITIVE + TOLERANT — same `decodeIfPresent` rationale as
    /// `shareEnvelopeID`.
    let attemptID: UUID?

    /// The `Message.id` the agent reply will be inserted under, minted at
    /// dispatch. Makes reply insertion idempotent INDEPENDENTLY OF THE LEDGER: a
    /// duplicate or replayed terminal callback probes for this id, finds the
    /// reply it would have written, and returns that instead of a second bubble.
    ///
    /// Deliberately NOT derived from `attemptID`: the fail-open measurement layer
    /// must never be the only duplicate guard, so this field is carried on both
    /// pre-encoded variants — including the one whose `attemptID` is nil.
    /// `nil` (old blobs) falls back to a freshly minted id, i.e. exactly today's
    /// behaviour. ADDITIVE + TOLERANT — same `decodeIfPresent` rationale as
    /// `shareEnvelopeID`.
    let agentMessageID: UUID?

    /// Explicit memberwise init with `shareEnvelopeID` / `userMessageID` /
    /// `stampsActiveConversation` / `requestHadHistoryImages` /
    /// `outputBoxKey` / `dispatchChatSignature` / `attemptID` /
    /// `agentMessageID` DEFAULTED to `nil` so the
    /// existing construction sites (CarPlay uploader, the converse `send(...)`'s
    /// non-share callers, tests) stay byte-identical — only sites that know the
    /// value pass one. (A synthesized memberwise init can't carry a default,
    /// hence the hand-written one.)
    init(
        bodyPath: String,
        conversationID: String,
        backendRawValue: String,
        refRawValue: String? = nil,
        shareEnvelopeID: UUID? = nil,
        userMessageID: UUID? = nil,
        stampsActiveConversation: Bool? = nil,
        requestHadHistoryImages: Bool? = nil,
        fileTransferLaneID: String? = nil,
        outputBoxKey: String? = nil,
        dispatchChatSignature: String? = nil,
        attemptID: UUID? = nil,
        agentMessageID: UUID? = nil
    ) {
        self.bodyPath = bodyPath
        self.conversationID = conversationID
        self.backendRawValue = backendRawValue
        self.refRawValue = refRawValue
        self.shareEnvelopeID = shareEnvelopeID
        self.userMessageID = userMessageID
        self.stampsActiveConversation = stampsActiveConversation
        self.requestHadHistoryImages = requestHadHistoryImages
        self.fileTransferLaneID = fileTransferLaneID
        self.outputBoxKey = outputBoxKey
        self.dispatchChatSignature = dispatchChatSignature
        self.attemptID = attemptID
        self.agentMessageID = agentMessageID
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
