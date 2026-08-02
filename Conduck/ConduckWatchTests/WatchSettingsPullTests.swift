// SPDX-License-Identifier: Apache-2.0

// Conduck — watchOS-only contract tests for the interactive settings pull
// (`WatchSessionManager.pullSettingsFromPhone` + the `SettingsPullTransport`
// seam) and the "Enable on Watch" cache courier.
//
// The pull is the fresh-install/fresh-launch freshness upgrade: one
// `sendMessage` round-trip resolves the active STT provider instead of
// waiting on the lazy `transferUserInfo` queue drain. These tests pin the
// three contracts the capture path leans on:
//   1. COALESCING — concurrent callers share ONE transport round-trip (the
//      prefetch + post-compression budget wait can overlap, and a
//      reachability flap must not stack round-trips), while a pull AFTER
//      resolution performs a FRESH round-trip by design.
//   2. DEADLINE — a caller's `maxWait` expiry resolves false AT the deadline
//      (not WCSession's own reply timeout), without cancelling the shared
//      task or wedging later pulls.
//   3. INLINE APPLY — a reply is fully committed through
//      `applyEnvelopePayload` (monotonic high-water mark advanced) BEFORE
//      the pull resolves true, so callers resolve the active provider the
//      moment the await returns.
//
// The fake transport owns BOTH the reachability gate and the round-trip
// (mirroring `WCSessionSettingsPullTransport`), so `.failure` models
// not-activated / unreachable / send-error uniformly. Envelopes carry
// apiKey == nil so the apply path skips the Keychain write (signing-gated
// on the sim) — same posture as WatchSettingsApplyAndQueueTests.

import XCTest
@testable import ConduckWatch_Watch_App

/// Scripted `SettingsPullTransport`: parks each round-trip on a continuation
/// the test resolves explicitly, or replies/fails immediately via `mode`.
@MainActor
private final class FakeSettingsPullTransport: SettingsPullTransport {
    enum Mode {
        /// Park each round-trip until `resolveAll(with:)`.
        case park
        /// Resolve each round-trip immediately with this payload.
        case reply([String: Any])
        /// Resolve each round-trip immediately with nil (gate closed / send error).
        case failure
    }

    var mode: Mode = .park
    private(set) var callCount = 0
    private var parked: [CheckedContinuation<[String: Any]?, Never>] = []

    func performPull() async -> [String: Any]? {
        callCount += 1
        switch mode {
        case .park:
            return await withCheckedContinuation { parked.append($0) }
        case .reply(let payload):
            return payload
        case .failure:
            return nil
        }
    }

    /// Resume every parked round-trip with `payload`.
    func resolveAll(with payload: [String: Any]?) {
        let waiters = parked
        parked = []
        for waiter in waiters { waiter.resume(returning: payload) }
    }
}

@MainActor
final class WatchSettingsPullTests: XCTestCase {

    // MARK: - Coalescing

    func testConcurrentPullsCoalesceOntoOneTransportRoundTrip() async {
        let fake = FakeSettingsPullTransport()
        let manager = WatchSessionManager(pullTransport: fake)

        // Start BOTH awaits before resolving — the coalescing contract is one
        // round-trip serving every in-flight awaiter.
        async let first = manager.pullSettingsFromPhone(maxWait: 5)
        async let second = manager.pullSettingsFromPhone(maxWait: 5)

        // Drain the main executor until the shared task reaches the transport,
        // then a few extra passes so the second caller attaches to the
        // in-flight task (everything here is MainActor-serialized, so a
        // handful of yields settles both callers).
        for _ in 0..<10_000 where fake.callCount < 1 { await Task.yield() }
        for _ in 0..<25 { await Task.yield() }

        // Empty dict = a VALID reply (nothing configured on the iPhone yet):
        // it applies as a no-op and the pull still reports success.
        fake.resolveAll(with: [:])
        let results = await (first, second)
        XCTAssertTrue(results.0, "First awaiter must resolve true on the shared reply.")
        XCTAssertTrue(results.1, "Second awaiter must resolve true on the shared reply.")
        XCTAssertEqual(fake.callCount, 1,
                       "Two concurrent pulls must coalesce onto ONE transport round-trip.")

        // A pull AFTER resolution performs a FRESH round-trip by design
        // (settings may have changed iPhone-side between pulls).
        fake.mode = .reply([:])
        let third = await manager.pullSettingsFromPhone(maxWait: 5)
        XCTAssertTrue(third)
        XCTAssertEqual(fake.callCount, 2,
                       "A pull after the shared task cleared must issue a fresh round-trip.")
    }

    // MARK: - Deadline budget

    func testMaxWaitExpiryResolvesFalseWithoutWedgingLaterPulls() async {
        let fake = FakeSettingsPullTransport()   // parks: models a reply window exceeding the budget
        let manager = WatchSessionManager(pullTransport: fake)

        let started = Date()
        let expired = await manager.pullSettingsFromPhone(maxWait: 0.15)
        XCTAssertFalse(expired, "A pull with no reply inside maxWait must resolve false.")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3.0,
                          "Expiry must land at the caller's deadline TIME, not WCSession's own reply timeout.")

        // The shared task keeps running past the deadline (`awaitValue` never
        // cancels it); its late reply still applies. Later pulls must not be
        // wedged: whether the next caller attaches to the just-resolved task
        // or issues a fresh round-trip, it resolves true promptly.
        fake.resolveAll(with: [:])
        fake.mode = .reply([:])
        let later = await manager.pullSettingsFromPhone(maxWait: 5)
        XCTAssertTrue(later, "A pull after deadline expiry must not be wedged by the expired waiter.")
    }

    // MARK: - Inline apply (reply → applyEnvelopePayload → high-water mark)

    func testPullReplyInlineAppliesEnvelopeBeforeResolving() async {
        let reader = WatchSettingsReader.shared
        // Strictly newer than any high-water-mark a prior test left (the reader
        // is a process singleton), so this envelope always applies.
        let ts = reader.lastEnvelopeTimestamp + 1000
        let envelope = STTBroadcastEnvelope(
            presetID: "openai-gpt4o-transcribe",
            apiKey: nil,                      // keyless path — no Keychain write
            timestamp: ts
        )
        let fake = FakeSettingsPullTransport()
        fake.mode = .reply([Constants.sttActivePresetEnvelopeKey: envelope.encodedDict()])
        let manager = WatchSessionManager(pullTransport: fake)

        let applied = await manager.pullSettingsFromPhone(maxWait: 5)
        XCTAssertTrue(applied)
        // Inline-await contract: the envelope is committed BEFORE the pull
        // resolves — assert immediately, no settling wait.
        XCTAssertEqual(reader.activePresetID, "openai-gpt4o-transcribe",
                       "The pull reply must hydrate the active STT preset before resolving.")
        XCTAssertEqual(reader.lastEnvelopeTimestamp, ts,
                       "The pull reply must advance the monotonic high-water mark before resolving.")
    }

    func testTransportFailureResolvesFalseWithoutApply() async {
        let reader = WatchSettingsReader.shared
        let highWaterBefore = reader.lastEnvelopeTimestamp
        let fake = FakeSettingsPullTransport()
        fake.mode = .failure   // gate closed (not activated / unreachable) or send error
        let manager = WatchSessionManager(pullTransport: fake)

        let result = await manager.pullSettingsFromPhone(maxWait: 5)
        XCTAssertFalse(result, "A transport-level failure must resolve false — callers proceed on current state.")
        XCTAssertEqual(reader.lastEnvelopeTimestamp, highWaterBefore,
                       "A failed pull must not touch the applied-settings state.")
    }

    // MARK: - "Enable on Watch" cache courier

    /// The master switch rides applicationContext (low latency) + iCloud KVS
    /// (cold launch). `updateFromContext` must persist the couriered flag to
    /// the App-Group mirror and refresh the render-path cache; a context
    /// WITHOUT the key must leave the cache untouched (tolerant decoder).
    func testApplicationContextCourierRefreshesWatchEnabledCache() {
        let reader = WatchSettingsReader.shared
        defer {
            // Restore the default-ON state for sibling tests — App-Group
            // mirror included (the refresh path reads it first).
            TestStores.defaults
                .removeObject(forKey: Constants.watchEnabledKey)
            reader.refreshWatchEnabledCache()
        }

        reader.updateFromContext([Constants.watchEnabledKey: false])
        XCTAssertFalse(reader.isWatchEnabled(),
                       "The applicationContext courier must refresh the cached master switch.")

        reader.updateFromContext([:])
        XCTAssertFalse(reader.isWatchEnabled(),
                       "A context without the key must leave the cached flag untouched.")

        reader.updateFromContext([Constants.watchEnabledKey: true])
        XCTAssertTrue(reader.isWatchEnabled())
    }
}
