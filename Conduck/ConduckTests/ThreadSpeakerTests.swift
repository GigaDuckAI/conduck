// SPDX-License-Identifier: Apache-2.0

// Conduck
// ThreadSpeakerTests.swift
//
// Drives the `ThreadSpeaker` per-message speak-state machine (Part 3 of the
// voice/chat-control plan) deterministically. `ThreadSpeaker` is the UI source
// of truth for the footer Speak control: idle → loading → playing → idle, plus
// the toggle/supersede/stale-callback guards.
//
// To test it with no audio hardware, `ThreadSpeaker` exposes an injectable
// `init(engine:)`. We inject a real `ReplyVoice` (a `SpeakEngine`) built with the
// same fake seams the TTS suite uses (a controllable player + a fake fetcher + a
// fixed snapshot), and a `ControllablePlayer` whose `playCloud` LATCHES the
// `onStart` and `onDone` closures instead of firing them — so the test can fire
// each one by hand and assert the resulting state transition. iOS/macOS only
// (the injected `ReplyVoice` is not in the Watch target; `ThreadSpeaker` is now
// shared, and the Watch drives the SAME state machine via `WatchReplySpeaker`).

#if !os(watchOS)
import XCTest
@testable import Conduck

@MainActor
final class ThreadSpeakerTests: XCTestCase {

    // MARK: - Fakes

    /// Fetcher that returns bytes immediately (no network). Drives the cloud
    /// branch of `ReplyVoice.route`, which then hands off to `playCloud`.
    struct ImmediateFetcher: TTSFetching {
        func synthesize(text: String, provider: TTSProvider, voice: String?, customModel: String?, apiKey: String, customConfig: CustomTTSConfig?) async throws -> Data {
            Data([0x01, 0x02])
        }
    }

    /// One captured `playCloud`/`playApple` invocation: its latched start/done
    /// closures, fireable by hand. Lets a test fire a STALE turn's terminal
    /// (a closure captured BEFORE a supersede) directly at the speaker to prove
    /// the `messageID == speakingMessageID` guard discards it.
    final class CapturedPlay {
        let onStart: (@MainActor @Sendable () -> Void)?
        let onDone: (@MainActor @Sendable () -> Void)
        init(onStart: (@MainActor @Sendable () -> Void)?, onDone: @escaping @MainActor @Sendable () -> Void) {
            self.onStart = onStart
            self.onDone = onDone
        }
        func fireStart() { onStart?() }
        func fireDone() { onDone() }
    }

    /// Player that CAPTURES every `playCloud` / `playApple` call's closures
    /// instead of firing them, so the test drives each transition by hand and can
    /// reach back to a superseded turn's captured terminal. Production `ReplyVoice`
    /// only ever calls `playCloud`/`playApple` ONCE per turn here (immediate
    /// fetch), so `latest` is that turn's handle; `all` retains the history for
    /// stale-fire tests. Tracks call/stop counts for assertions.
    final class ControllablePlayer: SpeechPlaying {
        private(set) var all: [CapturedPlay] = []
        private(set) var stopCount = 0
        private(set) var pauseCount = 0
        private(set) var resumeCount = 0
        var playCount: Int { all.count }
        var latest: CapturedPlay? { all.last }

        func playCloud(
            _ data: Data,
            onStart: (@MainActor @Sendable () -> Void)?,
            onDone: @escaping @MainActor @Sendable (CloudPlaybackOutcome) -> Void
        ) {
            // Adapt the typed cloud terminal to the parameterless "fire the
            // terminal" abstraction the tests drive — firing it reports a clean
            // finish (these tests exercise the cloud-success state machine).
            all.append(CapturedPlay(onStart: onStart, onDone: { onDone(.finished) }))
        }

        func playApple(
            _ text: String,
            onStart: (@MainActor @Sendable () -> Void)?,
            onDone: @escaping @MainActor @Sendable (SpeakTerminal) -> Void
        ) {
            // Same adaptation as the cloud leg: firing the captured terminal
            // reports the synth's natural end (these tests drive the
            // played-to-completion state machine).
            all.append(CapturedPlay(onStart: onStart, onDone: { onDone(.finished) }))
        }

        func stop() { stopCount += 1 }

        // Pause/resume record COUNTS only — they do NOT fire the latched
        // `onDone` (a pause keeps the turn pending; a resume continues it), so
        // the captured terminal stays available for the test to fire by hand.
        func pause() { pauseCount += 1 }
        func resume() { resumeCount += 1 }

        /// Fire the most-recent turn's "playback began" signal.
        func fireStart() { latest?.fireStart() }
        /// Fire the most-recent turn's terminal.
        func fireDone() { latest?.fireDone() }
    }

    struct FixedSnapshot: TTSSnapshotResolving {
        func activeTTSSnapshot() async -> TTSSnapshot {
            // A cloud provider WITH a key → ReplyVoice takes the cloud fetch →
            // playCloud path (where our controllable player latches the hooks).
            TTSSnapshot(providerID: "openai-tts", apiKey: "key-123",
                        keyState: .present, voice: nil, customModel: nil, customConfig: nil)
        }
    }

    // MARK: - Helpers

    private func makeSpeaker() -> (ThreadSpeaker, ControllablePlayer) {
        let player = ControllablePlayer()
        let rv = ReplyVoice(fetcher: ImmediateFetcher(), player: player, snapshot: FixedSnapshot(),
                            outcomeLog: makeThrowawayOutcomeLog())
        let speaker = ThreadSpeaker(engine: rv)
        return (speaker, player)
    }

    /// Spin the main run loop until `condition` holds or the budget elapses. The
    /// snapshot + fetch hops are async; this lets them settle before assertions.
    private func spin(until condition: @escaping () -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await Task.yield()
        }
    }

    // MARK: - idle → loading on speak

    func testSpeakEntersLoadingImmediately() {
        let (speaker, _) = makeSpeaker()
        let id = UUID()

        speaker.speak("Hello there.", messageID: id)

        XCTAssertEqual(speaker.speakingMessageID, id, "speak must claim the tapped message synchronously.")
        XCTAssertEqual(speaker.speakState(for: id), .loading,
                       "Before the player starts, the tapped bubble must be .loading.")
    }

    // MARK: - loading → playing when the player's onStart fires

    func testLoadingTransitionsToPlayingOnStart() async {
        let (speaker, player) = makeSpeaker()
        let id = UUID()

        speaker.speak("Hello there.", messageID: id)
        // Wait for the async snapshot+fetch hops to reach playCloud.
        await spin(until: { player.playCount == 1 })
        XCTAssertEqual(speaker.speakState(for: id), .loading,
                       "Still .loading until the player reports playback began.")

        player.fireStart()

        XCTAssertEqual(speaker.speakState(for: id), .playing,
                       "onStart (.startedPlaying) must drive loading → playing.")
        XCTAssertEqual(speaker.speakingMessageID, id)
    }

    // MARK: - playing → idle when completion fires

    func testCompletionReturnsToIdle() async {
        let (speaker, player) = makeSpeaker()
        let id = UUID()

        speaker.speak("Hello there.", messageID: id)
        await spin(until: { player.playCount == 1 })
        player.fireStart()
        XCTAssertEqual(speaker.speakState(for: id), .playing)

        player.fireDone()

        XCTAssertEqual(speaker.speakState(for: id), .idle,
                       "completion must return the bubble to .idle.")
        XCTAssertNil(speaker.speakingMessageID, "No bubble is active after completion.")
    }

    // MARK: - tapping the SAME bubble while .playing PAUSES, then RESUMES
    //         (no stop, no re-synthesis)

    func testTapSamePlayingMessagePausesThenResumes() async {
        let (speaker, player) = makeSpeaker()
        let id = UUID()

        speaker.speak("Hello there.", messageID: id)
        await spin(until: { player.playCount == 1 })
        player.fireStart()
        XCTAssertEqual(speaker.speakState(for: id), .playing)

        let playsBefore = player.playCount
        // The initial speak()'s supersede-guard `cancel()` already called stop()
        // once before playback began — pause must add NO further stop.
        let stopsBefore = player.stopCount

        // Re-tap the PLAYING bubble → pause (NOT stop, NOT idle). The bubble
        // stays the active one and the turn's terminal stays pending.
        speaker.speak("Hello there.", messageID: id)
        XCTAssertEqual(speaker.speakState(for: id), .paused,
                       "Re-tapping the playing bubble must PAUSE it (→ paused).")
        XCTAssertEqual(speaker.speakingMessageID, id,
                       "A paused bubble is still the active one.")
        XCTAssertEqual(player.pauseCount, 1, "Re-tap must pause the player.")
        XCTAssertEqual(player.stopCount, stopsBefore,
                       "Pause must NOT stop/tear down the player.")

        // Re-tap the PAUSED bubble → resume from position. No new play() call —
        // the audio was never torn down, so there is NO re-synthesis.
        speaker.speak("Hello there.", messageID: id)
        XCTAssertEqual(speaker.speakState(for: id), .playing,
                       "Re-tapping the paused bubble must RESUME it (→ playing).")
        XCTAssertEqual(player.resumeCount, 1, "Re-tap must resume the player.")

        // Prove no fresh snapshot+fetch+play hop ran across pause→resume.
        await spin(until: { player.playCount > playsBefore }, timeout: 0.3)
        XCTAssertEqual(player.playCount, playsBefore,
                       "Pause→resume must NOT re-synthesize (no new playCloud).")

        // The turn's legitimate terminal still returns the bubble to idle.
        player.fireDone()
        XCTAssertEqual(speaker.speakState(for: id), .idle)
        XCTAssertNil(speaker.speakingMessageID)
    }

    // MARK: - tapping a DIFFERENT bubble while one is PAUSED supersedes

    func testTapDifferentMessageWhilePausedSupersedes() async {
        let (speaker, player) = makeSpeaker()
        let first = UUID()
        let second = UUID()

        speaker.speak("First reply.", messageID: first)
        await spin(until: { player.playCount == 1 })
        player.fireStart()
        speaker.speak("First reply.", messageID: first)  // pause `first`
        XCTAssertEqual(speaker.speakState(for: first), .paused)

        let stopsBefore = player.stopCount
        speaker.speak("Second reply.", messageID: second)  // a different bubble

        XCTAssertEqual(speaker.speakingMessageID, second,
                       "Tapping a different bubble supersedes the paused one.")
        XCTAssertEqual(speaker.speakState(for: first), .idle,
                       "The superseded (paused) bubble reverts to .idle.")
        XCTAssertGreaterThan(player.stopCount, stopsBefore,
                             "Superseding a paused turn must hard-stop the player.")
    }

    // MARK: - tapping a DIFFERENT bubble supersedes (cancels prior, new claims)

    func testTapDifferentMessageSupersedes() async {
        let (speaker, player) = makeSpeaker()
        let first = UUID()
        let second = UUID()

        speaker.speak("First reply.", messageID: first)
        await spin(until: { player.playCount == 1 })
        player.fireStart()
        XCTAssertEqual(speaker.speakState(for: first), .playing)

        let stopsBefore = player.stopCount
        speaker.speak("Second reply.", messageID: second)

        XCTAssertEqual(speaker.speakingMessageID, second,
                       "Tapping a different bubble must make it the active one.")
        XCTAssertEqual(speaker.speakState(for: second), .loading,
                       "The new bubble starts in .loading.")
        XCTAssertEqual(speaker.speakState(for: first), .idle,
                       "The superseded bubble reverts to .idle.")
        XCTAssertGreaterThan(player.stopCount, stopsBefore,
                             "Superseding must cancel the prior turn (stop the player).")

        // The new turn drives its own play → start → playing.
        await spin(until: { player.playCount == 2 })
        player.fireStart()
        XCTAssertEqual(speaker.speakState(for: second), .playing)
    }

    // MARK: - a STALE callback from a superseded message is IGNORED

    func testStaleCallbackFromSupersededTurnIsIgnored() async {
        let (speaker, player) = makeSpeaker()
        let first = UUID()
        let second = UUID()

        // Start the first turn and let it reach playback; grab its captured
        // closures so we can fire its TERMINAL late (after a supersede).
        speaker.speak("First reply.", messageID: first)
        await spin(until: { player.playCount == 1 })
        let firstTurn = player.latest!
        firstTurn.fireStart()
        XCTAssertEqual(speaker.speakState(for: first), .playing)

        // Supersede with a second turn — now `second` is the active bubble.
        speaker.speak("Second reply.", messageID: second)
        await spin(until: { player.playCount == 2 })
        player.fireStart()  // the SECOND turn's start
        XCTAssertEqual(speaker.speakingMessageID, second)
        XCTAssertEqual(speaker.speakState(for: second), .playing)

        // A STALE terminal from the superseded FIRST turn arrives late. The
        // `messageID == speakingMessageID` guard inside ThreadSpeaker must
        // discard it — it must NOT clear the second turn's active state.
        firstTurn.fireDone()

        XCTAssertEqual(speaker.speakingMessageID, second,
                       "A stale callback from the superseded turn must NOT change the active bubble.")
        XCTAssertEqual(speaker.speakState(for: second), .playing,
                       "A stale terminal must NOT knock the current turn out of .playing.")

        // A stale START from the first turn must also be inert.
        firstTurn.fireStart()
        XCTAssertEqual(speaker.speakState(for: second), .playing)
        XCTAssertEqual(speaker.speakState(for: first), .idle,
                       "The superseded first bubble stays idle.")

        // The LEGITIMATE terminal for the second turn still returns to idle.
        player.fireDone()
        XCTAssertEqual(speaker.speakState(for: second), .idle)
        XCTAssertNil(speaker.speakingMessageID)
    }

    // MARK: - stop() from any state returns to idle

    func testStopFromLoadingReturnsToIdle() async {
        let (speaker, player) = makeSpeaker()
        let id = UUID()

        speaker.speak("Hello there.", messageID: id)
        await spin(until: { player.playCount == 1 })
        XCTAssertEqual(speaker.speakState(for: id), .loading)

        speaker.stop()

        XCTAssertEqual(speaker.speakState(for: id), .idle)
        XCTAssertNil(speaker.speakingMessageID)
        XCTAssertGreaterThanOrEqual(player.stopCount, 1, "stop() must stop the player.")
    }
}
#endif
