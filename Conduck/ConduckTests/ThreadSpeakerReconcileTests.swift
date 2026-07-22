// Conduck
// ThreadSpeakerReconcileTests.swift
//
// Drives `ThreadSpeaker`'s Watch dim-cut RECONCILIATION deterministically. On
// real Apple Watch hardware watchOS silently suspends built-in-speaker TTS the
// moment the always-on screen dims — firing NO terminal delegate — so the state
// machine would stay stuck at `.playing` (pause glyph frozen; two taps to
// resume). `reconcileSystemPauseIfNeeded()` reads the engine's real
// `playbackStatus` and flips the stuck `.playing` to `.paused` (marking it a
// SYSTEM pause), and `autoResumeIfSystemPaused()` continues a dim-interrupted
// reply on the wrist-raise within a freshness window — never a reply the user
// paused by hand.
//
// The existing `ThreadSpeakerTests` inject a real `ReplyVoice`, whose
// `playbackStatus` is the protocol default `.active` — useless for driving the
// reconcile branches. So this suite injects a bespoke `FakeSpeakEngine` with a
// settable `playbackStatus` + an injectable clock (for the auto-resume window).
// iOS/macOS only (`ThreadSpeaker` is shared; the Watch drives the SAME machine).

#if !os(watchOS)
import XCTest
@testable import Conduck

@MainActor
final class ThreadSpeakerReconcileTests: XCTestCase {

    // MARK: - Fakes

    /// A `SpeakEngine` whose `playbackStatus` the test sets directly, and which
    /// latches `onStateChange`/`completion` (fired by hand) + counts
    /// pause/resume/cancel. No audio, no async hops — the state machine is driven
    /// synchronously.
    final class FakeSpeakEngine: SpeakEngine {
        var status: PlaybackStatus = .active
        var playbackStatus: PlaybackStatus { status }

        private(set) var pauseCount = 0
        private(set) var resumeCount = 0
        private(set) var cancelCount = 0

        private var onStateChange: (@MainActor @Sendable (SpeechActivity) -> Void)?
        private var completion: (@MainActor @Sendable () -> Void)?

        func speak(
            _ text: String,
            sanitize: Bool,
            onStateChange: (@MainActor @Sendable (SpeechActivity) -> Void)?,
            completion: @escaping @MainActor @Sendable () -> Void
        ) {
            self.onStateChange = onStateChange
            self.completion = completion
        }

        func pause() { pauseCount += 1 }
        func resume() { resumeCount += 1 }
        func cancel() {
            cancelCount += 1
            onStateChange = nil
            completion = nil
        }

        /// Drive loading → playing (mirrors real `.startedPlaying`).
        func fireStart() { onStateChange?(.startedPlaying) }
        /// Fire the turn's terminal.
        func fireDone() { let c = completion; completion = nil; c?() }
    }

    /// Mutable clock so a test can advance time past the auto-resume window.
    final class Clock {
        var date: Date
        init(_ date: Date) { self.date = date }
    }

    // MARK: - Helpers

    /// A speaker whose one active reply is `.playing`, plus its engine + clock +
    /// message id. Starts at a fixed epoch so window math is deterministic.
    private func makePlaying() -> (ThreadSpeaker, FakeSpeakEngine, Clock, UUID) {
        let engine = FakeSpeakEngine()
        let clock = Clock(Date(timeIntervalSince1970: 10_000))
        let speaker = ThreadSpeaker(engine: engine, now: { clock.date })
        let id = UUID()
        speaker.speak("A reasonably long reply.", messageID: id)  // → .loading (latches)
        engine.fireStart()                                        // → .playing
        XCTAssertEqual(speaker.speakState(for: id), .playing)
        return (speaker, engine, clock, id)
    }

    // MARK: - reconcile: the three engine truths

    func testReconcileFlipsStuckPlayingToSystemPaused() {
        let (speaker, engine, _, id) = makePlaying()
        engine.status = .pausedResumable   // OS paused us on the dim

        speaker.reconcileSystemPauseIfNeeded()

        XCTAssertEqual(speaker.speakState(for: id), .paused,
                       "A stuck .playing must reconcile to .paused when the engine is paused.")
        XCTAssertTrue(speaker.pausedBySystem,
                      "A reconcile-driven pause is a SYSTEM pause (auto-resume eligible).")
        XCTAssertEqual(engine.pauseCount, 0,
                       "Reconcile reflects the OS pause — it must not call engine.pause().")
    }

    func testReconcileNoOpWhileGenuinelyActive() {
        let (speaker, engine, _, id) = makePlaying()
        engine.status = .active   // still playing

        speaker.reconcileSystemPauseIfNeeded()

        XCTAssertEqual(speaker.speakState(for: id), .playing, "An actively-playing reply stays .playing.")
        XCTAssertFalse(speaker.pausedBySystem)
    }

    func testReconcileInactiveSilentlyResetsToIdle() {
        let (speaker, engine, _, id) = makePlaying()
        engine.status = .inactive   // truly dead, no terminal fired

        speaker.reconcileSystemPauseIfNeeded()

        XCTAssertEqual(speaker.speakState(for: id), .idle, "Dead playback reconciles to .idle.")
        XCTAssertNil(speaker.speakingMessageID, "No bubble is active after a silent reset.")
        XCTAssertFalse(speaker.pausedBySystem)
        XCTAssertGreaterThanOrEqual(engine.cancelCount, 1, "Silent reset must cancel the engine.")
    }

    func testReconcileNoOpWhenIdle() {
        let engine = FakeSpeakEngine()
        let speaker = ThreadSpeaker(engine: engine)
        engine.status = .pausedResumable

        speaker.reconcileSystemPauseIfNeeded()   // nothing active

        XCTAssertNil(speaker.speakingMessageID)
        XCTAssertFalse(speaker.pausedBySystem)
    }

    // MARK: - auto-resume

    func testAutoResumeContinuesSystemPausedReplyWithinWindow() {
        let (speaker, engine, clock, id) = makePlaying()
        engine.status = .pausedResumable
        speaker.reconcileSystemPauseIfNeeded()      // → .paused + pausedBySystem @ t0
        XCTAssertTrue(speaker.pausedBySystem)

        clock.date = clock.date.addingTimeInterval(10)   // within 30s
        speaker.autoResumeIfSystemPaused()

        XCTAssertEqual(speaker.speakState(for: id), .playing, "A system-paused reply auto-resumes on raise.")
        XCTAssertEqual(engine.resumeCount, 1, "Auto-resume must resume the engine.")
        XCTAssertFalse(speaker.pausedBySystem, "The mark is cleared once resumed.")
    }

    func testAutoResumeExpiresPastWindowAndStaysPaused() {
        let (speaker, engine, clock, id) = makePlaying()
        engine.status = .pausedResumable
        speaker.reconcileSystemPauseIfNeeded()      // → .paused + pausedBySystem @ t0

        clock.date = clock.date.addingTimeInterval(31)   // past 30s
        speaker.autoResumeIfSystemPaused()

        XCTAssertEqual(speaker.speakState(for: id), .paused,
                       "Past the window the reply stays paused (still tappable → one-tap resume).")
        XCTAssertEqual(engine.resumeCount, 0, "Expired auto-resume must NOT resume.")
        XCTAssertFalse(speaker.pausedBySystem, "Expiry clears the auto-resume eligibility.")
    }

    func testAutoResumeIsIdempotentAcrossRepeatedRaiseEdges() {
        let (speaker, engine, clock, _) = makePlaying()
        engine.status = .pausedResumable
        speaker.reconcileSystemPauseIfNeeded()
        clock.date = clock.date.addingTimeInterval(5)

        speaker.autoResumeIfSystemPaused()
        speaker.autoResumeIfSystemPaused()   // second raise edge (scenePhase + luminance)

        XCTAssertEqual(engine.resumeCount, 1, "A resumed reply must not resume twice on the paired edges.")
    }

    // MARK: - the cardinal rule: a USER pause never auto-resumes

    func testUserPausedReplyNeverAutoResumes() {
        let (speaker, engine, _, id) = makePlaying()
        engine.status = .active

        // User taps the playing bubble → pause (NOT a system pause).
        speaker.speak("A reasonably long reply.", messageID: id)
        XCTAssertEqual(speaker.speakState(for: id), .paused)
        XCTAssertFalse(speaker.pausedBySystem, "A hand pause must never be marked system-paused.")

        speaker.autoResumeIfSystemPaused()

        XCTAssertEqual(speaker.speakState(for: id), .paused, "A user-paused reply must stay paused on raise.")
        XCTAssertEqual(engine.resumeCount, 0, "A user-paused reply must NEVER auto-resume.")
    }

    // MARK: - tap preflight: ONE tap resumes a dim-stuck reply

    func testTapPreflightResumesStuckPlayingInOneTap() {
        let (speaker, engine, _, id) = makePlaying()
        // The OS paused playback on the dim, but no delegate fired → UI still
        // stuck at .playing while the engine is actually paused.
        engine.status = .pausedResumable

        // A SINGLE tap on the same bubble: the preflight reconcile flips the stuck
        // .playing → .paused, then the toggle's .paused branch resumes — one tap.
        speaker.speak("A reasonably long reply.", messageID: id)

        XCTAssertEqual(speaker.speakState(for: id), .playing, "One tap must resume a dim-stuck reply.")
        XCTAssertEqual(engine.resumeCount, 1, "The single tap resumes the engine.")
        XCTAssertEqual(engine.pauseCount, 0, "The tap must NOT pause (the reconcile already reflected the OS pause).")
        XCTAssertFalse(speaker.pausedBySystem)
    }

    // MARK: - systemDimPause: owning the cut at the dim edge

    func testSystemDimPausePausesPlayingReplyAndArmsAutoResume() {
        let (speaker, engine, _, id) = makePlaying()

        speaker.systemDimPause()

        XCTAssertEqual(speaker.speakState(for: id), .paused,
                       "The dim-edge pause must flip .playing → .paused (truthful button).")
        XCTAssertTrue(speaker.pausedBySystem,
                      "A dim-edge pause is a SYSTEM pause — the raise auto-resume acts on it.")
        XCTAssertEqual(engine.pauseCount, 1,
                       "Unlike the reconcile, the dim edge pauses the ENGINE itself — the cut is ours, not reconstructed.")
    }

    func testSystemDimPauseThenRaiseWithinWindowAutoResumes() {
        let (speaker, engine, clock, id) = makePlaying()
        speaker.systemDimPause()                       // dim @ t0
        clock.date = clock.date.addingTimeInterval(10) // raise 10 s later

        speaker.autoResumeIfSystemPaused()

        XCTAssertEqual(speaker.speakState(for: id), .playing,
                       "A raise within the window must auto-resume a dim-paused reply.")
        XCTAssertEqual(engine.resumeCount, 1)
        XCTAssertFalse(speaker.pausedBySystem)
    }

    func testSystemDimPauseThenLateRaiseStaysPausedOneTapResume() {
        let (speaker, engine, clock, id) = makePlaying()
        speaker.systemDimPause()                       // dim @ t0
        clock.date = clock.date.addingTimeInterval(60) // raise past the 30 s window

        speaker.autoResumeIfSystemPaused()

        XCTAssertEqual(speaker.speakState(for: id), .paused,
                       "A late raise must NOT jump-scare — the reply stays paused.")
        XCTAssertEqual(engine.resumeCount, 0)
        XCTAssertFalse(speaker.pausedBySystem, "Past the window the mark is dropped.")

        // The button truthfully shows paused, so ONE tap resumes.
        engine.status = .pausedResumable
        speaker.speak("A reasonably long reply.", messageID: id)
        XCTAssertEqual(speaker.speakState(for: id), .playing, "One tap resumes after a late raise.")
        XCTAssertEqual(engine.resumeCount, 1)
    }

    func testSystemDimPauseNeverOverridesUserPause() {
        let (speaker, engine, _, id) = makePlaying()
        speaker.speak("A reasonably long reply.", messageID: id)  // user taps pause
        XCTAssertEqual(speaker.speakState(for: id), .paused)
        XCTAssertFalse(speaker.pausedBySystem)

        speaker.systemDimPause()   // dim lands on the already-user-paused reply

        XCTAssertFalse(speaker.pausedBySystem,
                       "A user-paused reply must never gain auto-resume eligibility from a later dim.")
        XCTAssertEqual(engine.pauseCount, 1, "No second engine pause — the guard skips non-.playing states.")

        speaker.autoResumeIfSystemPaused()
        XCTAssertEqual(speaker.speakState(for: id), .paused,
                       "The raise must not auto-resume what the user paused by hand.")
        XCTAssertEqual(engine.resumeCount, 0)
    }

    func testSystemDimPauseNoOpWhenIdleOrLoading() {
        let engine = FakeSpeakEngine()
        let speaker = ThreadSpeaker(engine: engine)

        speaker.systemDimPause()   // idle — nothing to pause
        XCTAssertNil(speaker.speakingMessageID)
        XCTAssertEqual(engine.pauseCount, 0)

        let id = UUID()
        speaker.speak("A reasonably long reply.", messageID: id)  // → .loading
        speaker.systemDimPause()   // loading — no audio started yet
        XCTAssertEqual(speaker.speakState(for: id), .loading,
                       "A loading turn has no audio to save — the dim edge must not disturb it.")
        XCTAssertEqual(engine.pauseCount, 0)
        XCTAssertFalse(speaker.pausedBySystem)
    }
}
#endif
