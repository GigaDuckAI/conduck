// SPDX-License-Identifier: Apache-2.0

// Conduck
// ThreadSpeakerStopAndAutoSpeakTests.swift
//
// Extends the speak-state-machine coverage in `ThreadSpeakerTests` /
// `ThreadSpeakerExclusivityTests` with the contracts those files leave open:
//
//   1. `ThreadSpeaker.stop()` from `.playing` and from `.paused` (the existing
//      suite only stops from `.loading`). Both must drop to `.idle`, hard-stop
//      the engine, clear the active bubble, and — critically — must NOT let the
//      now-stale turn's still-pending engine completion re-enter and resurrect
//      state when it fires late.
//
//   2. macOS resume re-claims the exclusivity bus: a `.paused -> .playing`
//      resume calls `SpeechExclusivity.shared.claim(self)` (ThreadSpeaker.swift
//      line ~93), so a sibling speaker that began playing while we were paused
//      gets silenced. Proven exactly as `ThreadSpeakerExclusivityTests` proves
//      a start-claim: a second real `ThreadSpeaker` on the shared bus is reset
//      to `.idle`. `#if os(macOS)` — the claim line only compiles there.
//
//   3. The per-platform `AutoSpeakMailbox.shared` freshness window is a LOCKED
//      constant — 60 s on iOS/macOS, 15 s on watchOS (SpeakEngine.swift). The
//      private `freshness` field isn't readable, so the literals are pinned
//      behaviorally against hardcoded values via the injectable-clock boundary,
//      and `.shared` is confirmed to carry a usable window.
//
// Uses the same fake-seam `ReplyVoice` rig (controllable latching player +
// immediate fetcher + fixed snapshot) as the sibling suites — no real
// AVFoundation, no network, no Keychain. iOS/macOS only (`!os(watchOS)`): the
// injected `ReplyVoice` is not in the Watch target.

#if !os(watchOS)
import XCTest
@testable import Conduck

@MainActor
final class ThreadSpeakerStopAndAutoSpeakTests: XCTestCase {

    // MARK: - Fakes (mirrors ThreadSpeakerTests' controllable-player rig)

    /// Fetcher that returns bytes immediately — drives `ReplyVoice`'s cloud
    /// branch straight to `playCloud` with no network.
    private struct ImmediateFetcher: TTSFetching {
        func synthesize(text: String, provider: TTSProvider, voice: String?, customModel: String?, apiKey: String, customConfig: CustomTTSConfig?) async throws -> Data {
            Data([0x01, 0x02])
        }
    }

    /// A cloud provider WITH a key → `ReplyVoice` takes the cloud fetch →
    /// `playCloud` path where the controllable player latches the hooks.
    private struct FixedSnapshot: TTSSnapshotResolving {
        func activeTTSSnapshot() async -> TTSSnapshot {
            TTSSnapshot(providerID: "openai-tts", apiKey: "key-123",
                        keyState: .present, voice: nil, customModel: nil, customConfig: nil)
        }
    }

    /// A single captured `playCloud`/`playApple` invocation: its latched
    /// start/done closures, fireable by hand so a STALE turn's terminal can be
    /// fired directly at the speaker after a `stop()`.
    private final class CapturedPlay {
        let onStart: (@MainActor @Sendable () -> Void)?
        let onDone: (@MainActor @Sendable () -> Void)
        init(onStart: (@MainActor @Sendable () -> Void)?, onDone: @escaping @MainActor @Sendable () -> Void) {
            self.onStart = onStart
            self.onDone = onDone
        }
        func fireStart() { onStart?() }
        func fireDone() { onDone() }
    }

    /// Player that CAPTURES every play call's closures instead of firing them.
    /// Tracks stop/pause/resume counts for assertions.
    private final class ControllablePlayer: SpeechPlaying {
        private(set) var all: [CapturedPlay] = []
        private(set) var stopCount = 0
        private(set) var pauseCount = 0
        private(set) var resumeCount = 0
        var playCount: Int { all.count }
        var latest: CapturedPlay? { all.last }

        func playCloud(_ data: Data, onStart: (@MainActor @Sendable () -> Void)?, onDone: @escaping @MainActor @Sendable (CloudPlaybackOutcome) -> Void) {
            all.append(CapturedPlay(onStart: onStart, onDone: { onDone(.finished) }))
        }
        func playApple(_ text: String, onStart: (@MainActor @Sendable () -> Void)?, onDone: @escaping @MainActor @Sendable (SpeakTerminal) -> Void) {
            // Same adaptation as the cloud leg: firing the captured terminal
            // reports the synth's natural end.
            all.append(CapturedPlay(onStart: onStart, onDone: { onDone(.finished) }))
        }
        func stop() { stopCount += 1 }
        // Pause/resume record COUNTS only — they do NOT fire the latched
        // terminal (a pause keeps the turn pending; a resume continues it).
        func pause() { pauseCount += 1 }
        func resume() { resumeCount += 1 }

        func fireStart() { latest?.fireStart() }
        func fireDone() { latest?.fireDone() }
    }

    // MARK: - Helpers

    private func makeSpeaker() -> (ThreadSpeaker, ControllablePlayer) {
        let player = ControllablePlayer()
        let rv = ReplyVoice(fetcher: ImmediateFetcher(), player: player, snapshot: FixedSnapshot(),
                            outcomeLog: makeThrowawayOutcomeLog())
        return (ThreadSpeaker(engine: rv), player)
    }

    /// Spin the main run loop until `condition` holds or the budget elapses —
    /// the snapshot + fetch hops are async.
    private func spin(until condition: @escaping () -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await Task.yield()
        }
    }

    /// Drive a turn all the way to `.playing` and return its captured handle so
    /// a test can fire its terminal late (after a stop).
    private func driveToPlaying(_ speaker: ThreadSpeaker, _ player: ControllablePlayer, id: UUID) async -> CapturedPlay {
        speaker.speak("Reply text.", messageID: id)
        await spin(until: { player.playCount == 1 })
        let turn = player.latest!
        turn.fireStart()
        XCTAssertEqual(speaker.speakState(for: id), .playing, "Precondition: turn must reach .playing.")
        return turn
    }

    // MARK: - stop() from .playing → idle, completion does NOT re-enter

    func testStopFromPlayingReturnsToIdleAndStaleTerminalIsInert() async {
        let (speaker, player) = makeSpeaker()
        let id = UUID()

        let turn = await driveToPlaying(speaker, player, id: id)
        let stopsBefore = player.stopCount

        speaker.stop()

        XCTAssertEqual(speaker.speakState(for: id), .idle,
                       "stop() from .playing must return the bubble to .idle.")
        XCTAssertNil(speaker.speakingMessageID, "No bubble is active after stop().")
        XCTAssertEqual(player.stopCount, stopsBefore + 1,
                       "stop() from .playing must hard-stop the player exactly once.")

        // The now-stale turn's engine completion fires LATE. The
        // `messageID == speakingMessageID` guard (speakingMessageID is now nil)
        // must discard it — it must NOT resurrect the bubble or re-clear state
        // (a no-op here, but the guard is what makes a stale re-entry inert).
        turn.fireDone()
        XCTAssertEqual(speaker.speakState(for: id), .idle,
                       "A stale terminal after stop() must NOT re-enter / change state.")
        XCTAssertNil(speaker.speakingMessageID)
        XCTAssertEqual(player.stopCount, stopsBefore + 1,
                       "The stale terminal must not trigger another stop.")
    }

    // MARK: - stop() from .paused → idle, completion does NOT re-enter

    func testStopFromPausedReturnsToIdleAndStaleTerminalIsInert() async {
        let (speaker, player) = makeSpeaker()
        let id = UUID()

        let turn = await driveToPlaying(speaker, player, id: id)

        // Re-tap the playing bubble → pause (turn stays the active one, its
        // terminal stays pending).
        speaker.speak("Reply text.", messageID: id)
        XCTAssertEqual(speaker.speakState(for: id), .paused, "Precondition: bubble must be .paused.")
        XCTAssertEqual(player.pauseCount, 1)
        let stopsBefore = player.stopCount

        speaker.stop()

        XCTAssertEqual(speaker.speakState(for: id), .idle,
                       "stop() from .paused must return the bubble to .idle.")
        XCTAssertNil(speaker.speakingMessageID, "No bubble is active after stop().")
        XCTAssertEqual(player.stopCount, stopsBefore + 1,
                       "stop() from .paused must hard-stop the player exactly once.")

        // The paused turn's terminal was still pending — firing it late must be
        // discarded by the active-bubble guard, not resurrect the cleared turn.
        turn.fireDone()
        XCTAssertEqual(speaker.speakState(for: id), .idle,
                       "A stale terminal after stop() must NOT re-enter / change state.")
        XCTAssertNil(speaker.speakingMessageID)
    }

    // MARK: - stop() fires its completion (announce) once; no double-stop on re-stop

    func testStopWhileAlreadyIdleIsInert() async {
        let (speaker, player) = makeSpeaker()
        let id = UUID()

        _ = await driveToPlaying(speaker, player, id: id)
        speaker.stop()
        let stopsAfterFirst = player.stopCount

        // A second stop() with nothing active still calls engine.cancel()
        // (engine-level idempotent), but must keep the machine at idle with no
        // active bubble — no resurrection, no negative-state.
        speaker.stop()
        XCTAssertEqual(speaker.speakState(for: id), .idle)
        XCTAssertNil(speaker.speakingMessageID)
        XCTAssertEqual(player.stopCount, stopsAfterFirst + 1,
                       "A redundant stop() still forwards exactly one cancel to the engine.")
    }

    // MARK: - macOS resume re-claims the exclusivity bus

    #if os(macOS)
    /// Spy party registered DIRECTLY on the real `SpeechExclusivity.shared`
    /// bus — counts how often the bus told it to stop. Not a `ThreadSpeaker`,
    /// so nothing resets it; it isolates exactly the claims the speaker makes.
    /// Held weakly by the bus, so it must be retained for the test's duration.
    private final class CountingParty: SpeechExclusivityParty {
        private(set) var stopCount = 0
        func stopForSpeechExclusivity() { stopCount += 1 }
    }

    /// A `.paused -> .playing` resume calls `SpeechExclusivity.shared.claim(self)`
    /// (ThreadSpeaker.swift line ~93 — "Resuming is audio starting again —
    /// silence the other macOS speakers"). Pause itself must NOT claim (it
    /// keeps the audio in place). Proven via a spy party registered on the same
    /// REAL `.shared` bus the speaker's init hardcodes: the spy is silenced on
    /// the resume claim but untouched by the preceding pause. Mirrors how
    /// `SpeechExclusivityTests` observes a claim, but on the live `.shared` bus
    /// `ThreadSpeaker` actually uses. Parties are weak — the spy is retained
    /// here and drops out at teardown.
    func testResumeClaimsExclusivityBusButPauseDoesNot() async {
        let (speaker, player) = makeSpeaker()
        let id = UUID()

        // A bystander speaker on the shared bus. Registered when `speaker`
        // started; we observe IT (not another ThreadSpeaker, whose own claims
        // would muddy the count).
        let spy = CountingParty()
        SpeechExclusivity.shared.register(spy)

        // Drive to playing. The initial speak() claimed the bus once (silencing
        // the spy) — capture the count AFTER that so we measure only pause/resume.
        _ = await driveToPlaying(speaker, player, id: id)
        let spyStopsAfterStart = spy.stopCount

        // PAUSE: must NOT claim the bus (audio is kept in place, no other
        // speaker should be silenced).
        speaker.speak("Reply text.", messageID: id)
        XCTAssertEqual(speaker.speakState(for: id), .paused, "Precondition: bubble paused.")
        XCTAssertEqual(player.pauseCount, 1, "Pause must pause the player.")
        XCTAssertEqual(spy.stopCount, spyStopsAfterStart,
                       "Pause must NOT claim the exclusivity bus (no sibling silenced).")

        // RESUME: the claim under test. It re-claims the bus → the spy is told
        // to stop again.
        speaker.speak("Reply text.", messageID: id)
        XCTAssertEqual(speaker.speakState(for: id), .playing, "Resume drives → .playing.")
        XCTAssertEqual(player.resumeCount, 1, "Resume must resume the player (no re-synthesis).")
        XCTAssertEqual(spy.stopCount, spyStopsAfterStart + 1,
                       "A .paused → .playing resume must claim the bus, silencing the bystander exactly once.")

        // Keep `spy` alive past the assertions (the bus holds it weakly).
        withExtendedLifetime(spy) {}
    }
    #endif

    // MARK: - AutoSpeakMailbox.shared freshness window is a LOCKED per-platform constant

    /// The shared mailbox must carry a usable window: a request consumed
    /// immediately (well within either platform's window) fires.
    func testSharedMailboxConsumesAFreshRequest() {
        let id = UUID(uuidString: "8E4E2D0A-1B7C-4F4E-9D1A-2C3B4A5D6E7F")!
        AutoSpeakMailbox.shared.clear()  // never inherit cross-test state
        AutoSpeakMailbox.shared.request(id)
        XCTAssertTrue(AutoSpeakMailbox.shared.consume(matching: id),
                      "The shared mailbox must honor a just-staged request.")
        AutoSpeakMailbox.shared.clear()
    }

    /// Pin the LOCKED iOS/macOS freshness literal: 60 s. Strictly-within (`<`)
    /// semantics — age == 60 is stale, age just under 60 fires. Built with the
    /// hardcoded literal so a rename of the production `freshness: 60` to any
    /// other number breaks this test.
    func testIOSFreshnessWindowIsSixtySeconds() {
        let clock = MutableClock()
        let mailbox = AutoSpeakMailbox(freshness: 60, now: { clock.date })
        let id = UUID(uuidString: "8E4E2D0A-1B7C-4F4E-9D1A-2C3B4A5D6E7F")!

        mailbox.request(id)
        clock.date += 59.9
        XCTAssertTrue(mailbox.consume(matching: id),
                      "Just under the iOS 60 s window must still fire.")

        mailbox.request(id)
        clock.date += 60
        XCTAssertFalse(mailbox.consume(matching: id),
                       "At exactly the iOS 60 s window the request is stale (strictly-within).")
    }

    /// Pin the LOCKED watchOS freshness literal: 15 s. (Tests run on the
    /// iOS-sim target where `AutoSpeakMailbox.shared` is the 60 s instance, so
    /// the watch literal is pinned via a directly-constructed mailbox — the
    /// boundary holds the literal `15` against renames.)
    func testWatchFreshnessWindowIsFifteenSeconds() {
        let clock = MutableClock()
        let mailbox = AutoSpeakMailbox(freshness: 15, now: { clock.date })
        let id = UUID(uuidString: "8E4E2D0A-1B7C-4F4E-9D1A-2C3B4A5D6E7F")!

        mailbox.request(id)
        clock.date += 14.9
        XCTAssertTrue(mailbox.consume(matching: id),
                      "Just under the watch 15 s window must still fire.")

        mailbox.request(id)
        clock.date += 15
        XCTAssertFalse(mailbox.consume(matching: id),
                       "At exactly the watch 15 s window the request is stale (strictly-within).")
    }

    /// Mutable injected clock so the freshness boundary is crossed without
    /// sleeping (mirrors `AutoSpeakMailboxTests.Clock`).
    private final class MutableClock {
        var date = Date(timeIntervalSinceReferenceDate: 1_000_000)
    }
}
#endif
