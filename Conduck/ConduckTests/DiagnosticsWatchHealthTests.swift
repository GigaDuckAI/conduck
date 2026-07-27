// SPDX-License-Identifier: Apache-2.0

// Conduck
// DiagnosticsWatchHealthTests.swift
//
// Coverage for the Diagnostics Watch deep-dive + the Phase-D silent-failure
// helpers: the watch row's recency-bearing state, the settings-freshness
// verdict (narrow by design — see `WatchSettingsFreshness`), the tolerant wire
// decode (`[:]`/version-less → unsupported, NEVER an all-unknown report), the
// fake-transport query round trip (reply / no-response / stale-snapshot
// preservation), the lock-backed one-shot latch under real concurrency, and
// the pure Phase-D rules (storage buckets, pending-retry TTL math, custom-STT
// ordinal, background-refresh LPM disambiguation).
//
// Isolation: everything here is pure or fake-transport-driven — no WCSession,
// no Keychain, no network. Runs on the unsigned sim.

import XCTest
@testable import Conduck

// MARK: - Fake transport

/// Scripted transport — returns the queued results in order (last one repeats),
/// so one runner can be driven through reply-then-failure sequences.
private final class FakeWatchHealthTransport: WatchHealthTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [WatchHealthTransportResult]

    init(_ script: [WatchHealthTransportResult]) {
        precondition(!script.isEmpty)
        self.script = script
    }

    func query(timeout: TimeInterval) async -> WatchHealthTransportResult {
        lock.lock()
        defer { lock.unlock() }
        return script.count > 1 ? script.removeFirst() : script[0]
    }
}

/// A versioned wire reply built from a dict — the convenience the tests share.
private func wireReply(_ overrides: [String: Any] = [:]) -> WatchHealthWireReply {
    typealias Key = Constants.WatchDiagnosticsReplyKey
    var dict: [String: Any] = [
        Key.version: Key.schemaVersion,
        Key.appVersion: "1.0",
        Key.appBuild: "42",
        Key.osVersion: "26.5.0",
        Key.sttEnvelopeTs: 1000.0,
        Key.agentEnvelopeTs: 2000.0,
        Key.relayQueueDepth: 0,
        Key.micPermission: "granted",
        Key.notificationPermission: "authorized",
        Key.companionReachable: true,
    ]
    for (k, v) in overrides { dict[k] = v }
    return WatchHealthWireReply(dict: dict)
}

@MainActor
final class DiagnosticsWatchHealthTests: XCTestCase {

    // MARK: - watchRowState recency matrix

    // The watch-row helpers live inside DiagnosticsRunner's `#if os(iOS)` block
    // (WatchConnectivity reads) — gate their tests the same way so a non-iOS
    // test compile of this target doesn't break on missing symbols.
    #if os(iOS)
    /// Status derives from installed/reachable ALONE (spec-locked INFO-not-red);
    /// the recency only enriches the detail. "Never" gets the end-to-end nudge,
    /// a known turn gets a relative date.
    func testWatchRowStateMatrix() {
        // Not installed → the one warning state, regardless of turn history.
        let notInstalled = DiagnosticsRunner.watchRowState(installed: false, reachable: false, lastTurn: Date())
        XCTAssertEqual(notInstalled.status, .warning)

        // Installed + reachable + never a turn → green, with the nudge.
        let neverTurn = DiagnosticsRunner.watchRowState(installed: true, reachable: true, lastTurn: nil)
        XCTAssertEqual(neverTurn.status, .passed)
        XCTAssertTrue(neverTurn.detail.contains("hasn't observed"),
                      "a never-worked watch must say so in the detail:\n\(neverTurn.detail)")

        // Installed + asleep + a known turn → still green, with the relative date.
        let knownTurn = DiagnosticsRunner.watchRowState(
            installed: true, reachable: false, lastTurn: Date().addingTimeInterval(-3600))
        XCTAssertEqual(knownTurn.status, .passed)
        XCTAssertTrue(knownTurn.detail.contains("Last Watch reply landed"),
                      "a known turn shows its recency:\n\(knownTurn.detail)")
        XCTAssertFalse(knownTurn.detail.contains("hasn't observed"))
    }

    /// The 7-day recent/stale boundary + never, for the copy-block bucket.
    func testWatchTurnRecencyBuckets() {
        XCTAssertEqual(DiagnosticsRunner.watchTurnRecency(nil), "never")
        XCTAssertEqual(DiagnosticsRunner.watchTurnRecency(Date().addingTimeInterval(-6 * 24 * 3600)), "recent")
        XCTAssertEqual(DiagnosticsRunner.watchTurnRecency(Date().addingTimeInterval(-8 * 24 * 3600)), "stale")
    }

    /// Broadcast-stamp buckets: 0 = never; <24h recent; older stale.
    func testStampRecencyBuckets() {
        let now = Date()
        XCTAssertEqual(DiagnosticsRunner.stampRecency(0, now: now), "never")
        XCTAssertEqual(DiagnosticsRunner.stampRecency(now.timeIntervalSinceReferenceDate - 3600, now: now), "recent")
        XCTAssertEqual(DiagnosticsRunner.stampRecency(now.timeIntervalSinceReferenceDate - 25 * 3600, now: now), "stale")
    }

    /// The courier-failing line shows ONLY when a failure stamp exists and is
    /// newer than any success — an old failure a later success recovered from
    /// must not keep crying wolf.
    func testCourierFailureIsCurrent() {
        XCTAssertFalse(DiagnosticsRunner.courierFailureIsCurrent(successAt: 0, failureAt: 0), "no stamps → no line")
        XCTAssertTrue(DiagnosticsRunner.courierFailureIsCurrent(successAt: 0, failureAt: 100), "failure with no success → current")
        XCTAssertTrue(DiagnosticsRunner.courierFailureIsCurrent(successAt: 50, failureAt: 100), "failure newer than success → current")
        XCTAssertFalse(DiagnosticsRunner.courierFailureIsCurrent(successAt: 200, failureAt: 100), "recovered by a later success → quiet")
        XCTAssertFalse(DiagnosticsRunner.courierFailureIsCurrent(successAt: 200, failureAt: 0), "success only → quiet")
    }
    #endif

    // MARK: - Settings freshness verdict (narrow by design)

    func testSettingsFreshnessVerdicts() {
        // Watch never accepted an envelope → never, regardless of the phone side.
        XCTAssertEqual(WatchHealthState.settingsFreshness(watchAgentTs: 0, phoneAgentTs: 0), .never)
        XCTAssertEqual(WatchHealthState.settingsFreshness(watchAgentTs: 0, phoneAgentTs: 500), .never)
        // Phone never assembled one → no basis to compare.
        XCTAssertEqual(WatchHealthState.settingsFreshness(watchAgentTs: 100, phoneAgentTs: 0), .unknown)
        // Watch at or ahead of the newest phone-minted envelope → current.
        XCTAssertEqual(WatchHealthState.settingsFreshness(watchAgentTs: 500, phoneAgentTs: 500), .current)
        XCTAssertEqual(WatchHealthState.settingsFreshness(watchAgentTs: 600, phoneAgentTs: 500), .current)
        // Phone minted something newer than the watch accepted → behind.
        XCTAssertEqual(WatchHealthState.settingsFreshness(watchAgentTs: 400, phoneAgentTs: 500), .behind)
    }

    // MARK: - Tolerant wire decode

    /// Missing/mistyped keys decode to nil — NEVER a failure; an empty dict is
    /// a valid decode whose `version` is nil (the "unsupported" signal).
    func testWireReplyTolerantDecode() {
        let full = wireReply()
        XCTAssertEqual(full.version, 1)
        XCTAssertEqual(full.appVersion, "1.0")
        XCTAssertEqual(full.agentEnvelopeTs, 2000.0)
        XCTAssertEqual(full.relayQueueDepth, 0)
        XCTAssertEqual(full.micPermission, "granted")
        XCTAssertEqual(full.companionReachable, true)

        let empty = WatchHealthWireReply(dict: [:])
        XCTAssertNil(empty.version)
        XCTAssertNil(empty.appVersion)
        XCTAssertNil(empty.agentEnvelopeTs)
        XCTAssertNil(empty.relayQueueDepth)

        typealias Key = Constants.WatchDiagnosticsReplyKey
        let mistyped = WatchHealthWireReply(dict: [
            Key.version: "one",            // wrong type → nil, not a crash
            Key.relayQueueDepth: "three",
            Key.micPermission: 7,
        ])
        XCTAssertNil(mistyped.version)
        XCTAssertNil(mistyped.relayQueueDepth)
        XCTAssertNil(mistyped.micPermission)
    }

    // MARK: - Query round trip (fake transport)

    /// A versioned reply lands as `.reply`: outcome + preserved facts both set;
    /// the checklist rows are NEVER status-mutated by the query.
    func testRunWatchHealthCheckReplyOutcome() async {
        let transport = FakeWatchHealthTransport([.reply(wireReply())])
        let runner = DiagnosticsRunner(watchHealthTransport: transport)
        await runner.runAutoReads()
        let statusesBefore = runner.checks.map(\.status)

        await runner.runWatchHealthCheck()

        guard case .reply(let state)? = runner.watchHealthLastOutcome else {
            return XCTFail("a versioned reply must decode to .reply, got \(String(describing: runner.watchHealthLastOutcome))")
        }
        XCTAssertEqual(runner.watchHealth, state, "the good snapshot is preserved")
        XCTAssertEqual(state.relayQueueDepth, 0)
        XCTAssertEqual(state.micPermission, "granted")
        XCTAssertEqual(runner.checks.map(\.status), statusesBefore,
                       "the health query must never mutate a check row's status")
        XCTAssertFalse(runner.isCheckingWatch, "the in-flight flag resets unconditionally")
    }

    /// A version-less reply (`[:]` from a build that doesn't know the kind) is
    /// `.unsupported` — never an all-unknown health report.
    func testVersionlessReplyIsUnsupported() async {
        let transport = FakeWatchHealthTransport([.reply(WatchHealthWireReply(dict: [:]))])
        let runner = DiagnosticsRunner(watchHealthTransport: transport)

        await runner.runWatchHealthCheck()

        XCTAssertEqual(runner.watchHealthLastOutcome, .unsupported)
        XCTAssertNil(runner.watchHealth, "an unsupported reply must not fabricate a facts snapshot")
    }

    /// Codex refinement: a failed refresh PRESERVES the last good snapshot (the
    /// view shows "couldn't refresh" over the last-known facts) while the last
    /// outcome records the failure.
    func testFailedRefreshPreservesLastGoodSnapshot() async {
        let transport = FakeWatchHealthTransport([
            .reply(wireReply()),
            .noResponse(.timedOut),
        ])
        let runner = DiagnosticsRunner(watchHealthTransport: transport)

        await runner.runWatchHealthCheck()
        guard case .reply(let good)? = runner.watchHealthLastOutcome else {
            return XCTFail("first query must produce the good snapshot")
        }

        await runner.runWatchHealthCheck()
        XCTAssertEqual(runner.watchHealthLastOutcome, .noResponse(.timedOut),
                       "the newest outcome records the failure")
        XCTAssertEqual(runner.watchHealth, good,
                       "the last good snapshot survives a failed refresh")
    }

    /// Transport errors carry the numeric WCError code (allowlist-safe) into
    /// the outcome and the copy block.
    func testTransportErrorCarriesCode() async {
        let transport = FakeWatchHealthTransport([.noResponse(.transportError(code: 7014))])
        let runner = DiagnosticsRunner(watchHealthTransport: transport)
        await runner.runWatchHealthCheck()
        XCTAssertEqual(runner.watchHealthLastOutcome, .noResponse(.transportError(code: 7014)))
    }

    /// Wrist-side denied permissions register in the summary's attention count
    /// (via `WatchHealthState.attentionCount`) — a green "Checks passed" must
    /// not sit above a visible amber denied line.
    func testWatchHealthAttentionCountsDeniedPermissions() {
        typealias Key = Constants.WatchDiagnosticsReplyKey
        let healthy = wireReply()
        let denied = wireReply([Key.micPermission: "denied", Key.notificationPermission: "denied"])

        func state(_ wire: WatchHealthWireReply) -> WatchHealthState {
            WatchHealthState(
                appVersion: wire.appVersion, appBuild: wire.appBuild, osVersion: wire.osVersion,
                agentEnvelopeTs: wire.agentEnvelopeTs ?? 0,
                settingsFreshness: .current,
                relayQueueDepth: wire.relayQueueDepth,
                micPermission: wire.micPermission,
                notificationPermission: wire.notificationPermission,
                receivedAt: Date())
        }
        XCTAssertEqual(state(healthy).attentionCount, 0)
        XCTAssertEqual(state(denied).attentionCount, 2)
    }

    // MARK: - One-shot latch under real concurrency

    /// The reply/error/timeout paths race on different queues — the latch must
    /// admit EXACTLY one claimant no matter how many race it.
    func testLockedOnceAdmitsExactlyOneClaimUnderConcurrency() async {
        let latch = LockedOnce()
        let claims = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<100 {
                group.addTask { latch.claim() }
            }
            var wins = 0
            for await didClaim in group where didClaim { wins += 1 }
            return wins
        }
        XCTAssertEqual(claims, 1, "exactly one concurrent claimant may win")
    }

    // MARK: - Courier marker disjointness

    #if os(iOS)   // AppleSpeechRelayCoordinator (phone side) is iOS-only
    /// The settings-courier filter selects on its OWN payload key — relay
    /// transcript replies (which also ride `transferUserInfo`) mark themselves
    /// under the relay wire's `kind` key, a DIFFERENT literal, so they can
    /// never read as settings couriers.
    func testSettingsCourierMarkerDisjointFromRelayWire() {
        XCTAssertNotEqual(Constants.watchBroadcastKindKey, AppleSpeechRelayCoordinator.Wire.kindKey,
                          "the courier marker must live under its own payload key")
        XCTAssertNotEqual(Constants.watchBroadcastKindSettings, AppleSpeechRelayCoordinator.Wire.replyKind,
                          "the courier marker value must not collide with a relay kind")
    }
    #endif

    // MARK: - Phase D pure rules

    /// 1-based roster-order ordinal for the anonymous `custom-stt#N` tag; nil
    /// for built-ins / unknown ids.
    func testCustomSTTOrdinal() {
        let e1 = CustomVoiceEndpoint(id: UUID(), name: "A")
        let e2 = CustomVoiceEndpoint(id: UUID(), name: "B")
        XCTAssertEqual(DiagnosticsRunner.customSTTOrdinal(activePresetID: e1.sttPresetID, roster: [e1, e2]), 1)
        XCTAssertEqual(DiagnosticsRunner.customSTTOrdinal(activePresetID: e2.sttPresetID, roster: [e1, e2]), 2)
        XCTAssertNil(DiagnosticsRunner.customSTTOrdinal(activePresetID: "openai-gpt4o-transcribe", roster: [e1, e2]))
        XCTAssertNil(DiagnosticsRunner.customSTTOrdinal(activePresetID: e1.sttPresetID, roster: []))
    }

    /// Remaining-TTL math: fresh → the full 10; near-expiry → 1; expired → 0.
    func testPendingRetryRemainingMinutes() {
        let now = Date()
        XCTAssertEqual(DiagnosticsRunner.pendingRetryRemainingMinutes(createdAt: now, now: now), 10)
        XCTAssertEqual(DiagnosticsRunner.pendingRetryRemainingMinutes(createdAt: now.addingTimeInterval(-570), now: now), 1)
        XCTAssertEqual(DiagnosticsRunner.pendingRetryRemainingMinutes(createdAt: now.addingTimeInterval(-700), now: now), 0)
    }

    /// Storage thresholds: nil = unknown (hidden, NEVER healthy-green); ≥500 MB
    /// hidden; <500 low; <100 critical — amber both tiers.
    func testStorageRowStateAndBuckets() {
        let mb: (Int64) -> Int64 = { $0 * 1024 * 1024 }

        XCTAssertNil(DiagnosticsRunner.storageRowState(freeBytes: nil), "unknown probe → hidden row")
        XCTAssertEqual(DiagnosticsRunner.storageBucket(freeBytes: nil), "unknown")

        XCTAssertNil(DiagnosticsRunner.storageRowState(freeBytes: mb(600)))
        XCTAssertEqual(DiagnosticsRunner.storageBucket(freeBytes: mb(600)), "ok")
        XCTAssertNil(DiagnosticsRunner.storageRowState(freeBytes: mb(500)), "exactly 500 MB is healthy")

        let low = DiagnosticsRunner.storageRowState(freeBytes: mb(300))
        XCTAssertEqual(low?.status, .warning)
        XCTAssertEqual(DiagnosticsRunner.storageBucket(freeBytes: mb(300)), "low")

        let critical = DiagnosticsRunner.storageRowState(freeBytes: mb(50))
        XCTAssertEqual(critical?.status, .warning, "critical stays amber — never over-bubbles to red")
        XCTAssertTrue(critical?.detail.contains("critically") ?? false)
        XCTAssertEqual(DiagnosticsRunner.storageBucket(freeBytes: mb(50)), "critical")
    }

    /// The pending-retry presence force-shows the Voice section (its row lives
    /// there; a recording waiting to expire must never hide).
    func testPendingRetryForceShowsVoiceSection() {
        XCTAssertFalse(DiagnosticsRunner.shouldShowVoiceSection(
            hasStoredKeys: false, sttInProcess: true, ttsIsApple: true,
            micGranted: false, micDenied: false, speechDeniedOrRestricted: false,
            hasPendingRetry: false))
        XCTAssertTrue(DiagnosticsRunner.shouldShowVoiceSection(
            hasStoredKeys: false, sttInProcess: true, ttsIsApple: true,
            micGranted: false, micDenied: false, speechDeniedOrRestricted: false,
            hasPendingRetry: true),
            "a parked retry must reveal the Voice section")
    }
}
