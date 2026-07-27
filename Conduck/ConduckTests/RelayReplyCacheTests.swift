// SPDX-License-Identifier: Apache-2.0

// Conduck
// RelayReplyCacheTests.swift
//
// Relay-convergence rework, Stage B. Deterministic tests for
// `RelayReplyCache` — the bounded LRU idempotency ledger that lets the
// iPhone re-serve a prior verdict when the Watch retries with the SAME
// requestID (instead of re-transcribing or dropping). Coverage:
//   1. Store/retrieve round trip for both verdict shapes (success text,
//      failure errorCode).
//   2. Miss returns nil.
//   3. Overwriting the same key replaces the value without growing the
//      cache.
//   4. LRU eviction at capacity — and retrieval REFRESHES recency (a
//      retried requestID is the hottest key), so the evictee is the
//      least-recently-USED entry, not merely the oldest insert.
//   5. The default capacity is 16 (covers the Watch's 10-entry deferred
//      queue with headroom).
//
// PLATFORM GATE: wrap in `#if !os(watchOS)` per the membership-exceptions
// trap (see AppleSpeechRunnerTests). The LRU itself is platform-neutral;
// the wire-payload rebuild method is exercised separately in
// RelayWireContractTests (iOS-gated, where `Wire` exists).

#if !os(watchOS)

import XCTest
@testable import Conduck

final class RelayReplyCacheTests: XCTestCase {

    // MARK: - Store / retrieve

    func testStoreAndRetrieveSuccessVerdict() {
        let cache = RelayReplyCache()
        cache.store(.init(text: "hello duck", errorCode: nil), forKey: "req-A")

        let reply = cache.cachedReply(forKey: "req-A")
        XCTAssertEqual(reply?.text, "hello duck")
        XCTAssertNil(reply?.errorCode)
    }

    func testStoreAndRetrieveErrorVerdict() {
        let cache = RelayReplyCache()
        cache.store(.init(text: nil, errorCode: 18), forKey: "req-B")

        let reply = cache.cachedReply(forKey: "req-B")
        XCTAssertNil(reply?.text)
        XCTAssertEqual(reply?.errorCode, 18)
    }

    func testMissReturnsNil() {
        let cache = RelayReplyCache()
        cache.store(.init(text: "something", errorCode: nil), forKey: "req-A")
        XCTAssertNil(cache.cachedReply(forKey: "req-unknown"))
    }

    // MARK: - Overwrite

    func testOverwriteSameKeyReplacesValueWithoutGrowing() {
        let cache = RelayReplyCache(capacity: 2)
        cache.store(.init(text: "first", errorCode: nil), forKey: "req-A")
        cache.store(.init(text: nil, errorCode: 24), forKey: "req-A")

        XCTAssertEqual(cache.count, 1, "Overwrite must not add a second entry")
        let reply = cache.cachedReply(forKey: "req-A")
        XCTAssertNil(reply?.text)
        XCTAssertEqual(reply?.errorCode, 24, "Overwrite must surface the NEW verdict")
    }

    func testOverwriteDoesNotEvict() {
        let cache = RelayReplyCache(capacity: 2)
        cache.store(.init(text: "a", errorCode: nil), forKey: "req-A")
        cache.store(.init(text: "b", errorCode: nil), forKey: "req-B")
        // Same-key overwrite at capacity: nothing may be evicted.
        cache.store(.init(text: "a2", errorCode: nil), forKey: "req-A")

        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.cachedReply(forKey: "req-A")?.text, "a2")
        XCTAssertEqual(cache.cachedReply(forKey: "req-B")?.text, "b")
    }

    // MARK: - LRU eviction

    func testEvictsLeastRecentlyUsedAtCapacity() {
        let cache = RelayReplyCache(capacity: 3)
        cache.store(.init(text: "a", errorCode: nil), forKey: "req-A")
        cache.store(.init(text: "b", errorCode: nil), forKey: "req-B")
        cache.store(.init(text: "c", errorCode: nil), forKey: "req-C")

        // Touch A: B becomes the least-recently-used entry.
        XCTAssertNotNil(cache.cachedReply(forKey: "req-A"))

        cache.store(.init(text: "d", errorCode: nil), forKey: "req-D")

        XCTAssertNil(
            cache.cachedReply(forKey: "req-B"),
            "Least-recently-USED entry must be evicted (retrieval refreshes recency)"
        )
        XCTAssertNotNil(cache.cachedReply(forKey: "req-A"))
        XCTAssertNotNil(cache.cachedReply(forKey: "req-C"))
        XCTAssertNotNil(cache.cachedReply(forKey: "req-D"))
        XCTAssertEqual(cache.count, 3, "Eviction must keep the cache at capacity")
    }

    func testDefaultCapacityIsSixteen() {
        let cache = RelayReplyCache()
        for index in 0..<16 {
            cache.store(.init(text: "t\(index)", errorCode: nil), forKey: "req-\(index)")
        }
        XCTAssertEqual(cache.count, 16)

        // Touch req-0 so req-1 is the LRU entry, then overflow by one.
        XCTAssertNotNil(cache.cachedReply(forKey: "req-0"))
        cache.store(.init(text: "t16", errorCode: nil), forKey: "req-16")

        XCTAssertEqual(cache.count, 16, "Default capacity must be 16")
        XCTAssertNil(cache.cachedReply(forKey: "req-1"), "LRU entry must be evicted on overflow")
        XCTAssertNotNil(cache.cachedReply(forKey: "req-0"), "Touched entry must survive overflow")
        XCTAssertNotNil(cache.cachedReply(forKey: "req-16"))
    }

    // MARK: - Verdict admission policy (coordinator-adjacent, pure logic)
    //
    // The cache must hold SETTLED verdicts only. A retryable error cached
    // here would be re-served on every same-requestID re-fire from the
    // Watch — which deliberately leaves retryable entries queued expecting
    // a FRESH attempt — permanently poisoning the request and blocking the
    // head of the Watch's drain queue. The admission gate
    // (`shouldCacheVerdict(for:)`) lives on the iOS coordinator, hence the
    // os(iOS) gate inside this otherwise platform-neutral file.

    #if os(iOS)
    func testRetryableErrorVerdictsAreNotAdmitted() {
        // sttProviderUnreachable (20) is the exact defect class: a
        // transient BYO-endpoint outage the Watch retries through.
        XCTAssertFalse(AppleSpeechRelayCoordinator.shouldCacheVerdict(for: .sttProviderUnreachable))
        XCTAssertFalse(AppleSpeechRelayCoordinator.shouldCacheVerdict(for: .sttServerError))
        XCTAssertFalse(AppleSpeechRelayCoordinator.shouldCacheVerdict(for: .sttTooManyRequests))
        XCTAssertFalse(AppleSpeechRelayCoordinator.shouldCacheVerdict(for: .requestTimeout))
    }

    func testPermanentErrorVerdictsAreAdmitted() {
        // Permanent verdicts re-yield identically on retry — replaying the
        // cached verdict is pure savings, so these MUST stay cacheable.
        XCTAssertTrue(AppleSpeechRelayCoordinator.shouldCacheVerdict(for: .appleSpeechModelNotInstalled))
        XCTAssertTrue(AppleSpeechRelayCoordinator.shouldCacheVerdict(for: .audioInvalid))
        XCTAssertTrue(AppleSpeechRelayCoordinator.shouldCacheVerdict(for: .audioTooLarge))
        XCTAssertTrue(AppleSpeechRelayCoordinator.shouldCacheVerdict(for: .sttCustomEndpointNotConfigured))
        XCTAssertTrue(AppleSpeechRelayCoordinator.shouldCacheVerdict(for: .audioProcessingFailed))
    }
    #endif // os(iOS)
}

#endif // !os(watchOS)
