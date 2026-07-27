// SPDX-License-Identifier: Apache-2.0

// Conduck
// RelayReplyCache.swift
//
// Watch→iPhone Apple-speech relay — idempotency ledger (defect 3 of the
// relay convergence rework). The Watch's claim-token design retries an
// undelivered relay request with the SAME requestID (inline `sendMessage`
// attempt, `transferFile` fallback, deferred-queue drain re-fires). A
// duplicate that arrives AFTER the iPhone already transcribed must be
// answered with the prior verdict — never re-transcribed (a second agent
// hop / second model run / second notification for ONE utterance) and
// never dropped (the Watch would re-fire forever and never converge).
// This cache remembers the last N verdicts keyed by requestID so a
// duplicate request is a cheap dictionary hit.
//
// Bounded LRU, default capacity 16: the Watch's deferred queue caps at 10
// entries, so 16 comfortably covers every requestID that can legally still
// be retried while keeping worst-case memory trivial (one transcript
// string per slot).
//
// Admission is the COORDINATOR's job, not this type's: only SETTLED
// verdicts (success or PERMANENT error) are ever stored — retryable errors
// (e.g. `sttProviderUnreachable`) stay un-cached so a same-requestID
// re-fire re-attempts the transcription instead of replaying a transient
// outage. See `AppleSpeechRelayCoordinator.shouldCacheVerdict(for:)`.
//
// The cached value is a tiny `text`/`errorCode` struct rather than the raw
// `[String: Any]` payload: Codable-free, plist-type-erasure-free, hence
// directly assertable in unit tests
// (ConduckTests/RelayReplyCacheTests.swift). The wire payload is rebuilt
// on demand via `payload(requestID:)` from the SAME `Wire` literals the
// live reply path uses — cached and fresh replies cannot drift apart.
//
// Concurrency: NOT internally synchronized. The @MainActor
// `AppleSpeechRelayCoordinator` is the sole owner; the explicit @MainActor
// annotation documents (and under Swift 6 mode will enforce) that
// contract.

import Foundation

/// Bounded least-recently-used cache of relay verdicts keyed by requestID.
/// Exists so same-requestID retries from the Watch re-receive the prior
/// verdict instead of triggering a re-transcription (see header comment).
@MainActor
final class RelayReplyCache {

    /// One transcription verdict. Exactly one of `text` (success) or
    /// `errorCode` (`AppError.errorCode`, failure) is non-nil — mirrors
    /// the reply wire shape, which carries one result slot or the other.
    struct CachedReply {
        let text: String?
        let errorCode: Int?
    }

    private let capacity: Int

    /// Verdicts by requestID. Invariant: `Set(storage.keys) == Set(recency)`.
    private var storage: [String: CachedReply] = [:]

    /// LRU bookkeeping — least-recently-used FIRST, most-recent LAST.
    /// Linear scans are fine at capacity 16; a linked-list LRU would be
    /// pure overhead here.
    private var recency: [String] = []

    init(capacity: Int = 16) {
        self.capacity = max(1, capacity)
    }

    /// Number of cached verdicts (test hook).
    var count: Int { storage.count }

    /// Store (or overwrite) the verdict for `requestID`, evicting the
    /// least-recently-used entry when inserting a NEW key at capacity.
    func store(_ reply: CachedReply, forKey requestID: String) {
        if storage[requestID] == nil, storage.count >= capacity,
           let evictee = recency.first {
            recency.removeFirst()
            storage.removeValue(forKey: evictee)
        }
        storage[requestID] = reply
        touch(requestID)
    }

    /// The cached verdict for `requestID` (nil = never completed or
    /// already evicted), refreshing its recency — a retried requestID is
    /// the hottest key we have.
    func cachedReply(forKey requestID: String) -> CachedReply? {
        guard let reply = storage[requestID] else { return nil }
        touch(requestID)
        return reply
    }

    private func touch(_ requestID: String) {
        if let index = recency.firstIndex(of: requestID) {
            recency.remove(at: index)
        }
        recency.append(requestID)
    }
}

#if os(iOS)
extension RelayReplyCache.CachedReply {
    /// Rebuild the exact reply payload `AppleSpeechRelayCoordinator` ships
    /// over the wire. This is the SINGLE payload-shape site for both fresh
    /// and cached replies; the cross-target drift guard
    /// (ConduckTests/RelayWireContractTests.swift) asserts these literals
    /// against the raw key strings the Watch target mirrors.
    /// iOS-gated because the coordinator (and thus `Wire`) only exists on
    /// iOS; the macOS slice compiles the bare LRU and never uses it.
    func payload(requestID: String) -> [String: Any] {
        typealias Wire = AppleSpeechRelayCoordinator.Wire
        var payload: [String: Any] = [
            Wire.requestIDKey: requestID,
            Wire.kindKey: Wire.replyKind,
        ]
        if let text {
            payload[Wire.resultTextKey] = text
        }
        if let errorCode {
            payload[Wire.resultErrorCodeKey] = errorCode
        }
        return payload
    }
}
#endif
