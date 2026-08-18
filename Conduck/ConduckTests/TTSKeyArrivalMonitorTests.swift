// SPDX-License-Identifier: Apache-2.0

// Conduck
// TTSKeyArrivalMonitorTests.swift
//
// Deterministic coverage of the bounded key-arrival poller via its injected
// seams (probe source, sleeper, arrival post) — no live Keychain, no real
// notifications, no wall-clock backoff. The invariants under test are the
// design-review bounds:
//   - the arrival post fires ONLY from a timer-discovered missing→present
//     transition, exactly once;
//   - unrelated settings changes never restart (or un-exhaust) a window;
//   - resign-active cancels the window and a late read can't post;
//   - a fingerprint change (provider/slot switch) restarts the window;
//   - keyless / healthy probes never poll.

import XCTest
@testable import Conduck

@MainActor
final class TTSKeyArrivalMonitorTests: XCTestCase {

    // MARK: - Seams

    /// Thread-safe mutable probe script + counters (the probe provider and
    /// sleeper run inside the monitor's poll Task, off the main actor).
    private final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var _probe: ActiveTTSKeyProbe
        private var _probeAfterFirstRead: ActiveTTSKeyProbe?
        private var _probeReads = 0
        private var _sleeps = 0

        init(_ probe: ActiveTTSKeyProbe) { _probe = probe }

        var probe: ActiveTTSKeyProbe {
            get { lock.lock(); defer { lock.unlock() }; return _probe }
            set { lock.lock(); defer { lock.unlock() }; _probe = newValue }
        }
        /// When set, every read AFTER the first returns this probe instead —
        /// a read-count-scripted flip that stays deterministic under the
        /// INSTANT sleeper (a test-task-side `probe =` flip races the
        /// microsecond-long window and can land after exhaustion).
        var probeAfterFirstRead: ActiveTTSKeyProbe? {
            get { lock.lock(); defer { lock.unlock() }; return _probeAfterFirstRead }
            set { lock.lock(); defer { lock.unlock() }; _probeAfterFirstRead = newValue }
        }
        func readProbe() -> ActiveTTSKeyProbe {
            lock.lock(); defer { lock.unlock() }
            _probeReads += 1
            if _probeReads > 1, let next = _probeAfterFirstRead { return next }
            return _probe
        }
        var probeReads: Int { lock.lock(); defer { lock.unlock() }; return _probeReads }
        func bumpSleeps() { lock.lock(); defer { lock.unlock() }; _sleeps += 1 }
        var sleeps: Int { lock.lock(); defer { lock.unlock() }; return _sleeps }
    }

    /// Main-actor post counter (the arrival closure is @MainActor).
    private final class PostBox {
        var posts = 0
    }

    private static let missingOpenAI = ActiveTTSKeyProbe(
        providerID: "openai-tts",
        keySlotID: "openai-gpt4o-transcribe",
        keyState: .missing
    )
    private static let presentOpenAI = ActiveTTSKeyProbe(
        providerID: "openai-tts",
        keySlotID: "openai-gpt4o-transcribe",
        keyState: .present
    )
    private static let missingMistral = ActiveTTSKeyProbe(
        providerID: "mistral-tts",
        keySlotID: "mistral-voxtral",
        keyState: .missing
    )
    private static let appleKeyless = ActiveTTSKeyProbe(
        providerID: "apple-tts",
        keySlotID: nil,
        keyState: .notRequired
    )

    /// Build a monitor with an INSTANT sleeper (the whole window runs in
    /// microseconds) or a BLOCKING one (sleeps until cancelled — freezes the
    /// window mid-backoff so state can be asserted).
    private func makeMonitor(
        script: Script,
        posts: PostBox,
        blockingSleeper: Bool
    ) -> KeyArrivalMonitor {
        KeyArrivalMonitor(
            probeProvider: { script.readProbe().arrivalReading },
            sleeper: { _ in
                script.bumpSleeps()
                if blockingSleeper {
                    // Far longer than any test — relies on cancellation.
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                }
            },
            onKeyArrival: { posts.posts += 1 }
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }

    /// A short settle so a NON-event can be asserted (nothing to wait FOR).
    private func settle() async throws {
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    // MARK: - Arrival

    func testPollDiscoveredArrivalPostsExactlyOnce() async throws {
        let script = Script(Self.missingOpenAI)
        // Scripted by READ COUNT: the evaluation read (read 1) sees .missing →
        // the window opens; the FIRST poll read (read 2) discovers .present.
        // Deterministic under the instant sleeper — a test-task-side flip
        // after observing read 1 races the microsecond-long window and the
        // monitor can exhaust before the flip lands.
        script.probeAfterFirstRead = Self.presentOpenAI
        let posts = PostBox()
        let monitor = makeMonitor(script: script, posts: posts, blockingSleeper: false)

        monitor.handleDidBecomeActive()
        try await waitUntil { posts.posts == 1 }
        try await settle()
        XCTAssertEqual(posts.posts, 1, "arrival must post exactly once")
        XCTAssertEqual(monitor.state, .idle)
    }

    func testActivationWithHealthyKeyNeverPosts() async throws {
        let script = Script(Self.presentOpenAI)
        let posts = PostBox()
        let monitor = makeMonitor(script: script, posts: posts, blockingSleeper: false)

        monitor.handleDidBecomeActive()
        try await waitUntil { script.probeReads >= 1 }
        try await settle()
        XCTAssertEqual(posts.posts, 0, "a key that was never observed missing must not post")
        XCTAssertEqual(monitor.state, .idle)
        XCTAssertEqual(script.sleeps, 0)
    }

    func testKeylessProviderNeverPolls() async throws {
        let script = Script(Self.appleKeyless)
        let posts = PostBox()
        let monitor = makeMonitor(script: script, posts: posts, blockingSleeper: false)

        monitor.handleDidBecomeActive()
        try await waitUntil { script.probeReads >= 1 }
        try await settle()
        XCTAssertEqual(monitor.state, .idle)
        XCTAssertEqual(script.sleeps, 0)
        XCTAssertEqual(posts.posts, 0)
    }

    // MARK: - Exhaustion

    func testExhaustsAfterScheduleAndStaysExhaustedThroughSettingsChurn() async throws {
        let script = Script(Self.missingOpenAI)
        let posts = PostBox()
        let monitor = makeMonitor(script: script, posts: posts, blockingSleeper: false)

        monitor.handleDidBecomeActive()
        let key = Self.missingOpenAI.arrivalReading.requirementKey
        try await waitUntil { monitor.state == .exhausted(requirementKey: key) }
        XCTAssertEqual(script.sleeps, KeyArrivalMonitor.backoffSchedule.count)
        XCTAssertEqual(posts.posts, 0)

        // Unrelated settings churn with the SAME fingerprint must not re-arm.
        let sleepsAtExhaustion = script.sleeps
        monitor.handleSettingsChanged()
        try await settle()
        XCTAssertEqual(monitor.state, .exhausted(requirementKey: key))
        XCTAssertEqual(script.sleeps, sleepsAtExhaustion)

        // A genuine re-activation DOES re-arm.
        monitor.handleDidBecomeActive()
        try await waitUntil { script.sleeps > sleepsAtExhaustion }
    }

    // MARK: - Window stability

    func testUnrelatedSettingsChangeDoesNotRestartWindow() async throws {
        let script = Script(Self.missingOpenAI)
        let posts = PostBox()
        let monitor = makeMonitor(script: script, posts: posts, blockingSleeper: true)

        monitor.handleDidBecomeActive()
        try await waitUntil { script.sleeps == 1 }
        XCTAssertEqual(monitor.state, .polling(requirementKey: Self.missingOpenAI.arrivalReading.requirementKey))

        monitor.handleSettingsChanged()
        try await settle()
        // Same fingerprint → the frozen window is untouched (a restart would
        // cancel the blocked sleep and enter a second one).
        XCTAssertEqual(script.sleeps, 1)
        XCTAssertEqual(monitor.state, .polling(requirementKey: Self.missingOpenAI.arrivalReading.requirementKey))
    }

    func testFingerprintChangeRestartsWindow() async throws {
        let script = Script(Self.missingOpenAI)
        let posts = PostBox()
        let monitor = makeMonitor(script: script, posts: posts, blockingSleeper: true)

        monitor.handleDidBecomeActive()
        try await waitUntil { script.sleeps == 1 }

        script.probe = Self.missingMistral
        monitor.handleSettingsChanged()
        try await waitUntil { script.sleeps == 2 }
        XCTAssertEqual(monitor.state, .polling(requirementKey: Self.missingMistral.arrivalReading.requirementKey))
    }

    func testLocalKeySaveSettlesWindowWithoutPosting() async throws {
        let script = Script(Self.missingOpenAI)
        let posts = PostBox()
        let monitor = makeMonitor(script: script, posts: posts, blockingSleeper: true)

        monitor.handleDidBecomeActive()
        try await waitUntil { script.sleeps == 1 }

        // A local paste already posted `.settingsDidChangeRemotely` itself;
        // the monitor's re-evaluation sees healthy and must go idle WITHOUT
        // a second post (no duplicate fan-out).
        script.probe = Self.presentOpenAI
        monitor.handleSettingsChanged()
        try await waitUntil { monitor.state == .idle }
        try await settle()
        XCTAssertEqual(posts.posts, 0)
    }

    // MARK: - Resign-active

    func testResignActiveCancelsWindowAndLateArrivalCannotPost() async throws {
        let script = Script(Self.missingOpenAI)
        let posts = PostBox()
        let monitor = makeMonitor(script: script, posts: posts, blockingSleeper: true)

        monitor.handleDidBecomeActive()
        try await waitUntil { script.sleeps == 1 }

        monitor.handleWillResignActive()
        XCTAssertEqual(monitor.state, .idle)

        // The key "arrives" after the cancel — the dead window must not post,
        // and no new window may open while inactive.
        script.probe = Self.presentOpenAI
        monitor.handleSettingsChanged()   // ignored: app not active
        try await settle()
        XCTAssertEqual(posts.posts, 0)
        XCTAssertEqual(monitor.state, .idle)
        XCTAssertEqual(script.sleeps, 1)
    }

    // MARK: - Schedule contract

    func testBackoffScheduleIsBoundedAndExponential() {
        let schedule = KeyArrivalMonitor.backoffSchedule
        XCTAssertEqual(schedule.count, 6)
        XCTAssertEqual(schedule.first, .seconds(5))
        XCTAssertEqual(schedule.last, .seconds(160))
        // Strictly doubling — the review-locked shape (~5.25 min total).
        for index in 1..<schedule.count {
            XCTAssertEqual(schedule[index], schedule[index - 1] * 2)
        }
    }

    // MARK: - Probe semantics

    func testProbeDegradedStates() {
        XCTAssertTrue(Self.missingOpenAI.isDegraded)
        XCTAssertTrue(ActiveTTSKeyProbe(
            providerID: "openai-tts",
            keySlotID: "openai-gpt4o-transcribe",
            keyState: .unreadable
        ).isDegraded)
        XCTAssertFalse(Self.presentOpenAI.isDegraded)
        XCTAssertFalse(Self.appleKeyless.isDegraded)
    }

    /// The erased reading the monitor actually polls, so a future edit to
    /// `arrivalReading` cannot silently stop a degraded provider from arming a
    /// window while `isDegraded` still says it should.
    func testArrivalReadingMirrorsTheDegradedPredicate() {
        XCTAssertEqual(Self.missingOpenAI.arrivalReading.reading, .degraded)
        XCTAssertEqual(Self.presentOpenAI.arrivalReading.reading, .arrived)
        XCTAssertEqual(Self.appleKeyless.arrivalReading.reading, .notRequired)
    }

    /// The requirement key is what decides whether a window survives. Two
    /// providers must never share one, or switching voices would leave a window
    /// open on the question the user just stopped asking.
    func testRequirementKeySeparatesProviders() {
        XCTAssertNotEqual(
            Self.missingOpenAI.arrivalReading.requirementKey,
            Self.missingMistral.arrivalReading.requirementKey
        )
        XCTAssertEqual(
            Self.missingOpenAI.arrivalReading.requirementKey,
            Self.presentOpenAI.arrivalReading.requirementKey,
            "Same provider + slot: the key must be stable so an arrival closes the window it opened"
        )
    }
}
