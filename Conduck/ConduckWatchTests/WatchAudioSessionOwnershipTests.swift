// SPDX-License-Identifier: Apache-2.0

// Conduck — watchOS-only contract tests.
//
// Locks the record⇄playback session-ownership contract in two layers:
//
//   1. `WatchAudioSessionCoordinator` token semantics — a claim supersedes the
//      live claim (whose later release is a stale no-op); plain `release`
//      never deactivates; `releaseAndDeactivate` on a LIVE claim fires the
//      injected deactivate exactly once after the grace; a claim landing
//      inside the grace cancels the pending teardown; a STALE
//      `releaseAndDeactivate` fires nothing.
//
//   2. `WatchReplySpeaker` integration through the injected coordinator —
//      `speak` claims `.playback` per turn SYNCHRONOUSLY (before its chained
//      category/activation IPC task, so the claim is observable the moment
//      `speak` returns); `cancel()` releases the claim and the deferred
//      duck-restore deactivation follows the grace; the empty-after-sanitize
//      early return neither claims nor releases; a superseding `speak` inside
//      the grace re-claims immediately, so back-to-back turns never bounce
//      the session through setActive(false); a turn superseded BEFORE its
//      chained category op issues never activates — the superseding owner
//      keeps the session untouched.
//
// The deactivate closure is injected (no audio-server IPC) and the grace is
// shortened to 50 ms; every wait is a bounded condition-driven drain, and the
// injected Apple leg keeps the real `AVSpeechSynthesizer` out of the loop
// (mirrors WatchReplySpeakerFallbackTests' seam posture).

import XCTest
@testable import ConduckWatch_Watch_App

@MainActor
final class WatchAudioSessionOwnershipTests: XCTestCase {

    // MARK: - Fakes

    /// Counts injected-deactivate invocations. `@MainActor` (hence Sendable),
    /// so the coordinator's `@Sendable` deactivate closure can hop into it.
    @MainActor
    final class DeactivateProbe {
        private(set) var count = 0
        func record() { count += 1 }
    }

    /// Recorder for the injected Apple leg (same shape as
    /// WatchReplySpeakerFallbackTests' AppleLegRecorder): stores the funnels;
    /// the test fires start/done by hand.
    @MainActor
    final class AppleLegRecorder {
        struct Leg {
            let text: String
            let onStart: @MainActor () -> Void
            let onDone: @MainActor () -> Void
        }
        private(set) var legs: [Leg] = []

        func speak(_ text: String,
                   _ onStart: @escaping @MainActor () -> Void,
                   _ onDone: @escaping @MainActor () -> Void) {
            legs.append(Leg(text: text, onStart: onStart, onDone: onDone))
        }
        func fireDone(_ index: Int = 0) { legs[index].onDone() }
    }

    /// Exactly-once completion counter (Sendable-safe box for the `speak`
    /// completion closure — a captured local `var` would not be).
    @MainActor
    final class Counter {
        private(set) var value = 0
        func bump() { value += 1 }
    }

    // MARK: - Fixtures & helpers

    private static let grace: Duration = .milliseconds(50)
    private static let reply = "The gateway reply arrives here."

    private func makeCoordinator() -> (WatchAudioSessionCoordinator, DeactivateProbe) {
        let probe = DeactivateProbe()
        let coordinator = WatchAudioSessionCoordinator(
            deactivationGrace: Self.grace,
            deactivate: { await probe.record() }
        )
        return (coordinator, probe)
    }

    /// Apple-default TTS path (no `WatchSettingsReader` seeding needed — the
    /// claim under test is taken before the engine branch either way), with a
    /// generous watchdog: ownership, not stalls, is under test here.
    private func makeSpeaker(
        coordinator: WatchAudioSessionCoordinator, apple: AppleLegRecorder
    ) -> WatchReplySpeaker {
        WatchReplySpeaker(
            synthesize: { _, _, _, _, _ in Data() },
            firstAudioTimeout: .seconds(60),
            appleLeg: { apple.speak($0, $1, $2) },
            sessionCoordinator: coordinator
        )
    }

    /// Bounded executor pump — used before NEGATIVE assertions.
    private func drain(_ iterations: Int = 25) async {
        for _ in 0..<iterations {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// Condition-driven drain (bounded): pump until `condition` holds; the
    /// assertions that follow report any real mismatch. The budget covers the
    /// async session activation + the 50 ms grace windows.
    private func drain(until condition: @autoclosure @MainActor () -> Bool) async {
        for _ in 0..<600 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    // MARK: - 1. Coordinator: claim supersedes claim; stale release is a no-op

    func testClaimSupersedesClaimAndOlderReleaseIsStaleNoOp() {
        let (coordinator, _) = makeCoordinator()
        let first = coordinator.claim(.playback)
        let second = coordinator.claim(.recording)
        XCTAssertFalse(coordinator.release(first),
                       "A superseded claim's release is a stale no-op.")
        XCTAssertTrue(coordinator.isClaimed,
                      "The live claim survives the stale release.")
        XCTAssertEqual(coordinator.current, second)
        XCTAssertTrue(coordinator.release(second),
                      "The live claim's release reports true.")
        XCTAssertFalse(coordinator.isClaimed)
    }

    // MARK: - 2. Coordinator: plain release never deactivates

    func testPlainReleaseNeverFiresDeactivate() async {
        let (coordinator, probe) = makeCoordinator()
        let claim = coordinator.claim(.recording)
        XCTAssertTrue(coordinator.release(claim))
        // Well past the grace: plain release drops ownership only.
        try? await Task.sleep(for: .milliseconds(250)); await drain()
        XCTAssertEqual(probe.count, 0,
                       "Plain release must never touch the session.")
    }

    // MARK: - 3. Coordinator: live releaseAndDeactivate fires once, after grace

    func testReleaseAndDeactivateOnLiveClaimFiresExactlyOnceAfterGrace() async {
        let (coordinator, probe) = makeCoordinator()
        let claim = coordinator.claim(.playback)
        coordinator.releaseAndDeactivate(claim)
        XCTAssertFalse(coordinator.isClaimed, "Ownership drops synchronously.")
        XCTAssertEqual(probe.count, 0, "Deactivation defers for the grace window.")

        await drain(until: probe.count == 1)
        XCTAssertEqual(probe.count, 1)
        // Well past the grace: still exactly once.
        try? await Task.sleep(for: .milliseconds(250)); await drain()
        XCTAssertEqual(probe.count, 1)
    }

    // MARK: - 4. Coordinator: a claim inside the grace cancels the teardown

    func testClaimWithinGraceCancelsPendingDeactivation() async {
        let (coordinator, probe) = makeCoordinator()
        let claim = coordinator.claim(.playback)
        coordinator.releaseAndDeactivate(claim)
        _ = coordinator.claim(.recording)   // lands inside the grace window

        try? await Task.sleep(for: .milliseconds(250)); await drain()
        XCTAssertEqual(probe.count, 0,
                       "A claim inside the grace aborts the pending deactivation.")
        XCTAssertTrue(coordinator.isClaimed, "The new claimant keeps ownership.")
    }

    // MARK: - 5. Coordinator: stale releaseAndDeactivate fires nothing

    func testStaleReleaseAndDeactivateFiresNothing() async {
        let (coordinator, probe) = makeCoordinator()
        let stale = coordinator.claim(.playback)
        let live = coordinator.claim(.recording)   // supersedes `stale`
        coordinator.releaseAndDeactivate(stale)

        try? await Task.sleep(for: .milliseconds(250)); await drain()
        XCTAssertEqual(probe.count, 0,
                       "A stale release must never schedule a teardown.")
        XCTAssertEqual(coordinator.current, live, "The live claim is untouched.")
    }

    // MARK: - 6. Speaker: speak takes a .playback claim

    func testSpeakTakesPlaybackClaim() {
        let (coordinator, _) = makeCoordinator()
        let apple = AppleLegRecorder()
        let speaker = makeSpeaker(coordinator: coordinator, apple: apple)

        speaker.speak(Self.reply, sanitize: false, onStateChange: nil, completion: { _ in })
        XCTAssertEqual(coordinator.current?.owner, .playback,
                       "speak claims the session before the category write.")
        speaker.cancel()   // leave no live turn behind
    }

    // MARK: - 7. Speaker: cancel releases the claim + deferred duck-restore

    func testCancelReleasesClaimAndDeactivateFollowsGrace() async {
        let (coordinator, probe) = makeCoordinator()
        let apple = AppleLegRecorder()
        let speaker = makeSpeaker(coordinator: coordinator, apple: apple)

        speaker.speak(Self.reply, sanitize: false, onStateChange: nil, completion: { _ in })
        XCTAssertTrue(coordinator.isClaimed)

        speaker.cancel()
        XCTAssertFalse(coordinator.isClaimed,
                       "cancel releases the turn's claim synchronously.")
        await drain(until: probe.count == 1)
        XCTAssertEqual(probe.count, 1,
                       "The duck-restore setActive(false) fires after the grace.")
    }

    // MARK: - 8. Speaker: empty-after-sanitize speak never churns ownership

    func testEmptyTextSpeakNeitherClaimsNorReleases() async {
        let (coordinator, probe) = makeCoordinator()
        let apple = AppleLegRecorder()
        let speaker = makeSpeaker(coordinator: coordinator, apple: apple)
        let completions = Counter()

        speaker.speak("", sanitize: false, onStateChange: nil,
                      completion: { _ in completions.bump() })
        XCTAssertEqual(completions.value, 1,
                       "Empty text still completes synchronously.")
        XCTAssertFalse(coordinator.isClaimed,
                       "The empty-after-sanitize early return takes no claim.")

        // Well past the grace: no claim was taken, so nothing may deactivate.
        try? await Task.sleep(for: .milliseconds(250)); await drain()
        XCTAssertEqual(probe.count, 0, "No claim ⇒ no deferred deactivation.")
        XCTAssertTrue(apple.legs.isEmpty)
    }

    // MARK: - 9. Speaker: a superseding speak inside the grace keeps the session

    func testSecondSpeakBeforeGraceElapsesKeepsSessionClaimed() async {
        let (coordinator, probe) = makeCoordinator()
        let apple = AppleLegRecorder()
        let speaker = makeSpeaker(coordinator: coordinator, apple: apple)

        speaker.speak(Self.reply, sanitize: false, onStateChange: nil, completion: { _ in })
        let firstClaim = coordinator.current
        // Supersede before the first turn's grace elapses: stopInFlight's
        // release schedules a deactivation, the new claim cancels it.
        speaker.speak("A different reply supersedes the first.",
                      sanitize: false, onStateChange: nil, completion: { _ in })
        XCTAssertTrue(coordinator.isClaimed,
                      "The superseding turn re-claims inside the grace.")
        XCTAssertNotEqual(coordinator.current, firstClaim,
                          "A fresh tenure token — the old claim is stale.")

        // Well past the grace: the session never bounced through setActive(false).
        try? await Task.sleep(for: .milliseconds(250)); await drain()
        XCTAssertEqual(probe.count, 0,
                       "Back-to-back speaks never bounce the session.")
        XCTAssertTrue(coordinator.isClaimed)
        speaker.cancel()   // leave no live turn behind
    }

    // MARK: - 10. Speaker: supersede before the chained category op issues

    func testSupersededBeforeChainedCategoryIssuesLeavesNewOwnerUntouched() async {
        let (coordinator, probe) = makeCoordinator()
        let apple = AppleLegRecorder()
        let speaker = makeSpeaker(coordinator: coordinator, apple: apple)

        speaker.speak(Self.reply, sanitize: false, onStateChange: nil, completion: { _ in })
        // Another owner claims IMMEDIATELY — synchronously after `speak`
        // returns, so the speak turn's chained category op is still queued.
        // At issue time `runConfig` sees the stale claim and returns false:
        // the turn's category never lands on the new owner's session and its
        // activation never starts.
        let recorder = coordinator.claim(.recording)

        // Bounded pump so the queued config op reaches issue time and settles.
        await drain()
        XCTAssertEqual(coordinator.current, recorder,
                       "The superseding owner keeps the session; the stale turn's config is skipped.")
        XCTAssertTrue(apple.legs.isEmpty,
                      "The stale turn's activation never issues, so no engine leg runs.")

        // Well past the grace: the stale turn issued nothing and released no
        // live claim, so nothing may deactivate under the recorder.
        try? await Task.sleep(for: .milliseconds(250)); await drain()
        XCTAssertEqual(probe.count, 0,
                       "No deactivation lands under the superseding owner.")
        XCTAssertEqual(coordinator.current, recorder)
        speaker.cancel()   // stale-claim release is a coordinator no-op
    }
}
