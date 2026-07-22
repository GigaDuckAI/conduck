// Conduck
// ThreadSpeakerFallbackMarkerTests.swift
//
// Locks `ThreadSpeaker`'s per-message "used the built-in (Apple) fallback voice"
// marker (`fallbackVoiceMessageIDs` / `usedFallbackVoice(for:)`): it is SET when
// the engine emits `.fallbackStarted`, SURVIVES same-message pause/resume (the
// attempt it describes is still the latest one), is CLEARED only by a FRESH
// speak for that same message, and is KEPT when a DIFFERENT message is spoken.
//
// Driven through a controllable `SpeakEngine` fake that latches the
// `onStateChange` / `completion` closures so the test emits `.startedPlaying`,
// `.fallbackStarted`, and the terminal by hand — no ReplyVoice, no audio.
// iOS/macOS only (`ThreadSpeaker` is shared, but the injected fake + this file
// build against the iOS/macOS test target).

#if !os(watchOS)
import XCTest
@testable import Conduck

@MainActor
final class ThreadSpeakerFallbackMarkerTests: XCTestCase {

    /// A `SpeakEngine` that CAPTURES the latest turn's progress + completion
    /// closures instead of driving real audio, so the test fires each signal by
    /// hand. `playbackStatus` inherits the protocol default (`.active`).
    private final class FakeSpeakEngine: SpeakEngine {
        private(set) var speakCount = 0
        private(set) var cancelCount = 0
        private(set) var pauseCount = 0
        private(set) var resumeCount = 0
        private var onStateChange: (@MainActor @Sendable (SpeechActivity) -> Void)?
        private var completion: (@MainActor @Sendable () -> Void)?

        func speak(
            _ text: String,
            sanitize: Bool,
            onStateChange: (@MainActor @Sendable (SpeechActivity) -> Void)?,
            completion: @escaping @MainActor @Sendable () -> Void
        ) {
            speakCount += 1
            self.onStateChange = onStateChange
            self.completion = completion
        }
        func pause() { pauseCount += 1 }
        func resume() { resumeCount += 1 }
        func cancel() { cancelCount += 1 }

        func emitStarted() { onStateChange?(.startedPlaying) }
        func emitFallback() { onStateChange?(.fallbackStarted) }
        func complete() { completion?() }
    }

    func testFallbackMarkerSetSurvivesPauseResumeAndClearsOnFreshSpeak() {
        let engine = FakeSpeakEngine()
        let speaker = ThreadSpeaker(engine: engine)
        let msg = UUID()

        // Start → playing; no marker yet.
        speaker.speak("A reply.", messageID: msg)
        engine.emitStarted()
        XCTAssertEqual(speaker.speakState(for: msg), .playing)
        XCTAssertFalse(speaker.usedFallbackVoice(for: msg), "No fallback yet → no marker.")

        // The Apple fallback leg's audio begins → the marker is set.
        engine.emitFallback()
        XCTAssertTrue(speaker.usedFallbackVoice(for: msg),
                      ".fallbackStarted must mark the bubble as having used the built-in voice.")

        // Same-message pause keeps the marker (the attempt it describes is still latest).
        speaker.speak("A reply.", messageID: msg)
        XCTAssertEqual(speaker.speakState(for: msg), .paused, "Re-tap while playing pauses.")
        XCTAssertTrue(speaker.usedFallbackVoice(for: msg), "Pause must KEEP the fallback marker.")

        // Same-message resume keeps it too.
        speaker.speak("A reply.", messageID: msg)
        XCTAssertEqual(speaker.speakState(for: msg), .playing, "Re-tap while paused resumes.")
        XCTAssertTrue(speaker.usedFallbackVoice(for: msg), "Resume must KEEP the fallback marker.")

        // Reach idle, then a FRESH speak for the SAME message clears the marker.
        engine.complete()
        XCTAssertEqual(speaker.speakState(for: msg), .idle)
        speaker.speak("A reply.", messageID: msg)
        XCTAssertFalse(speaker.usedFallbackVoice(for: msg),
                       "A fresh playback attempt for the same message must CLEAR its stale marker.")
    }

    func testFallbackMarkerForOneMessageSurvivesSpeakingAnother() {
        let engine = FakeSpeakEngine()
        let speaker = ThreadSpeaker(engine: engine)
        let first = UUID()
        let second = UUID()

        // Mark `first`.
        speaker.speak("First reply.", messageID: first)
        engine.emitStarted()
        engine.emitFallback()
        XCTAssertTrue(speaker.usedFallbackVoice(for: first))

        // Speaking a DIFFERENT message supersedes but must NOT clear `first`'s marker
        // (the fresh-speak clear only drops the marker of the message being spoken).
        speaker.speak("Second reply.", messageID: second)
        XCTAssertEqual(speaker.speakingMessageID, second, "The new message is active.")
        XCTAssertFalse(speaker.usedFallbackVoice(for: second), "The new message has no marker.")
        XCTAssertTrue(speaker.usedFallbackVoice(for: first),
                      "A different message's speak must KEEP the prior message's fallback marker.")
    }
}
#endif
