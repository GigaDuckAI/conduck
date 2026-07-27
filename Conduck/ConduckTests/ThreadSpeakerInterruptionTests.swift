// SPDX-License-Identifier: Apache-2.0

// Conduck
// ThreadSpeakerInterruptionTests.swift
//
// Drives `ThreadSpeaker`'s iOS SYSTEM-interruption reconciliation
// (`handleAudioInterruption`) deterministically. A phone call / Siri / alarm
// mid-playback makes the system pause our audio and take the session while
// firing NO terminal callback (`AVAudioPlayer` fires `didFinish` only on a
// natural end; the synth auto-pauses without `didFinish`/`didCancel`) — so
// without the handler the state machine would stick at `.playing` over dead
// audio. The iOS-chat analog of the Watch dim-cut reconcile suite.
//
// Same fake pattern as `ThreadSpeakerReconcileTests`: a synchronous
// `FakeSpeakEngine` with latched closures + pause/resume/cancel counters — no
// audio, no async hops (except the one wiring test that posts a real
// notification). iOS-only: the handler exists only under `#if os(iOS)`.

#if os(iOS)
import XCTest
import AVFoundation
@testable import Conduck

@MainActor
final class ThreadSpeakerInterruptionTests: XCTestCase {

    // MARK: - Fakes

    /// Latches `onStateChange`/`completion` (fired by hand) + counts
    /// pause/resume/cancel. No audio — the state machine is driven synchronously.
    final class FakeSpeakEngine: SpeakEngine {
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
    }

    // MARK: - Helpers

    /// A speaker whose one active reply is `.playing`, plus its engine + id.
    private func makePlaying() -> (ThreadSpeaker, FakeSpeakEngine, UUID) {
        let engine = FakeSpeakEngine()
        let speaker = ThreadSpeaker(engine: engine)
        let id = UUID()
        speaker.speak("A reasonably long reply.", messageID: id)  // → .loading (latches)
        engine.fireStart()                                        // → .playing
        XCTAssertEqual(speaker.speakState(for: id), .playing)
        return (speaker, engine, id)
    }

    /// Spin the main run loop until `condition` holds or the budget elapses —
    /// lets the wiring test's OperationQueue + Task hops settle.
    private func spin(until condition: @escaping () -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await Task.yield()
        }
    }

    // MARK: - .began while .playing → resumable pause

    func testInterruptionBeganWhilePlayingPausesResumably() {
        let (speaker, engine, id) = makePlaying()

        speaker.handleAudioInterruption(.began)

        XCTAssertEqual(speaker.speakState(for: id), .paused,
                       "An interruption mid-playback must flip .playing → .paused (truthful glyph).")
        XCTAssertEqual(speaker.speakingMessageID, id,
                       "The turn stays active — position preserved, one tap resumes.")
        XCTAssertEqual(engine.pauseCount, 1,
                       "The engine pauses (parks a chunk queue; idempotent on system-paused audio).")
        XCTAssertFalse(speaker.pausedBySystem,
                       "The iOS interruption pause never gains the Watch's auto-resume eligibility.")
    }

    // MARK: - .ended never auto-resumes

    func testInterruptionEndedNeverAutoResumes() {
        let (speaker, engine, id) = makePlaying()
        speaker.handleAudioInterruption(.began)
        XCTAssertEqual(speaker.speakState(for: id), .paused)

        speaker.handleAudioInterruption(.ended)

        XCTAssertEqual(speaker.speakState(for: id), .paused,
                       "The reply must stay paused when the interruption ends — never a jump-scare.")
        XCTAssertEqual(engine.resumeCount, 0, ".ended must NOT resume the engine.")
    }

    // MARK: - one tap resumes after an interruption pause

    func testTapAfterInterruptionPauseResumes() {
        let (speaker, engine, id) = makePlaying()
        speaker.handleAudioInterruption(.began)
        XCTAssertEqual(speaker.speakState(for: id), .paused)

        speaker.speak("A reasonably long reply.", messageID: id)  // the resume tap

        XCTAssertEqual(speaker.speakState(for: id), .playing,
                       "One tap must resume an interruption-paused reply from position.")
        XCTAssertEqual(engine.resumeCount, 1, "The tap resumes the engine — no re-synthesis.")
        XCTAssertEqual(engine.pauseCount, 1, "No second pause on the resume tap.")
    }

    // MARK: - .began while .loading → silent reset

    func testInterruptionBeganWhileLoadingResetsSilently() {
        let engine = FakeSpeakEngine()
        let speaker = ThreadSpeaker(engine: engine)
        let id = UUID()
        speaker.speak("A reasonably long reply.", messageID: id)  // → .loading
        XCTAssertEqual(speaker.speakState(for: id), .loading)

        speaker.handleAudioInterruption(.began)

        XCTAssertEqual(speaker.speakState(for: id), .idle,
                       "A loading turn resets — its fetch would land into the dead session.")
        XCTAssertNil(speaker.speakingMessageID, "No bubble stays active after the reset.")
        XCTAssertGreaterThanOrEqual(engine.cancelCount, 1,
                                    "The reset must cancel the in-flight fetch (nothing may speak later).")
    }

    // MARK: - .began no-ops on idle + user-paused

    func testInterruptionBeganNoOpWhenIdle() {
        let engine = FakeSpeakEngine()
        let speaker = ThreadSpeaker(engine: engine)

        speaker.handleAudioInterruption(.began)

        XCTAssertNil(speaker.speakingMessageID)
        XCTAssertEqual(engine.pauseCount, 0)
        XCTAssertEqual(engine.cancelCount, 0, "An idle speaker must not react — no cross-talk.")
    }

    func testInterruptionBeganNoOpWhenUserPaused() {
        let (speaker, engine, id) = makePlaying()
        speaker.speak("A reasonably long reply.", messageID: id)  // user taps pause
        XCTAssertEqual(speaker.speakState(for: id), .paused)
        XCTAssertEqual(engine.pauseCount, 1)

        speaker.handleAudioInterruption(.began)

        XCTAssertEqual(speaker.speakState(for: id), .paused, "Already paused — nothing to reconcile.")
        XCTAssertEqual(engine.pauseCount, 1, "No second engine pause on an already-paused reply.")
    }

    // MARK: - wiring: a real posted notification reaches the handler

    func testPostedInterruptionNotificationFlipsPlayingToPaused() async {
        let (speaker, _, id) = makePlaying()

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey:
                        AVAudioSession.InterruptionType.began.rawValue]
        )
        await spin(until: { speaker.speakState(for: id) == .paused })

        XCTAssertEqual(speaker.speakState(for: id), .paused,
                       "The registered observer must parse the notification and pause the reply.")
    }
}
#endif
