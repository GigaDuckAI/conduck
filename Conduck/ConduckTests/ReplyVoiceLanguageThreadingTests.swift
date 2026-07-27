// SPDX-License-Identifier: Apache-2.0

// Conduck
// ReplyVoiceLanguageThreadingTests.swift
//
// Proves the per-turn content-language hint actually REACHES the Apple leg
// through the `SpeechPlaying` seam — the detector unit tests prove `detect`
// returns the right code, this proves `ReplyVoice.speak` threads that code into
// `player.playApple(_:language:...)`. Uses a recording player fake (implements
// the 4-arg language-aware requirement) + the injectable snapshot seam, so no
// network, no audio hardware, no `SettingsManager` actor is touched.
//
// The 5 pre-existing `SpeechPlaying` fakes stay on the 3-arg requirement and
// inherit the extension's language-ignoring default (zero edits) — they compile
// but say nothing about threading, which is exactly why this dedicated recording
// fake exists. iOS/macOS only (ReplyVoice is not in the Watch target).

#if !os(watchOS)
import XCTest
@testable import Conduck

@MainActor
final class ReplyVoiceLanguageThreadingTests: XCTestCase {

    /// Player fake that records the `language` hint of every Apple leg. Provides
    /// BOTH the 3-arg witness (required, no default) and the 4-arg override that
    /// records — so whichever path runs, the recorded value reflects reality.
    final class LanguageRecordingPlayer: SpeechPlaying {
        private(set) var appleLanguages: [String?] = []

        func playCloud(
            _ data: Data,
            onStart: (@MainActor @Sendable () -> Void)?,
            onDone: @escaping @MainActor @Sendable (CloudPlaybackOutcome) -> Void
        ) {
            onStart?()
            onDone(.finished)
        }
        func playApple(
            _ text: String,
            onStart: (@MainActor @Sendable () -> Void)?,
            onDone: @escaping @MainActor @Sendable () -> Void
        ) {
            playApple(text, language: nil, onStart: onStart, onProgress: nil, onDone: onDone)
        }
        /// Overrides the 5-arg language/progress-aware requirement — `ReplyVoice`
        /// calls THIS with the per-turn hint, so `appleLanguages` reflects reality.
        func playApple(
            _ text: String,
            language: String?,
            onStart: (@MainActor @Sendable () -> Void)?,
            onProgress: (@MainActor @Sendable () -> Void)?,
            onDone: @escaping @MainActor @Sendable () -> Void
        ) {
            appleLanguages.append(language)
            onStart?()
            onProgress?()
            onDone()
        }
        func stop() {}
        func pause() {}
        func resume() {}
    }

    /// Snapshot fake pinned to Apple TTS (no key) so `route` takes the direct
    /// Apple leg — the simplest path that exercises `playApple(_:language:...)`.
    struct AppleSnapshot: TTSSnapshotResolving {
        func activeTTSSnapshot() async -> TTSSnapshot {
            TTSSnapshot(providerID: TTSProvider.appleTTS.id, apiKey: nil,
                        keyState: .notRequired, voice: nil, customModel: nil, customConfig: nil)
        }
    }

    private func speakAndWait(_ rv: ReplyVoice, _ text: String) {
        let exp = expectation(description: "completion")
        rv.speak(text, sanitize: false) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
    }

    func testGermanReplyThreadsGermanHintToAppleLeg() {
        let player = LanguageRecordingPlayer()
        let rv = ReplyVoice(player: player, snapshot: AppleSnapshot(), outcomeLog: makeThrowawayOutcomeLog())
        speakAndWait(rv, "Guten Morgen, wie geht es dir heute? Ich hoffe, du hast gut geschlafen.")
        XCTAssertEqual(player.appleLanguages, ["de-DE"])
    }

    func testShortReplyThreadsNilHintToAppleLeg() {
        // Below the confidence floor → detector returns nil → device voice.
        let player = LanguageRecordingPlayer()
        let rv = ReplyVoice(player: player, snapshot: AppleSnapshot(), outcomeLog: makeThrowawayOutcomeLog())
        speakAndWait(rv, "OK")
        XCTAssertEqual(player.appleLanguages, [nil])
    }
}
#endif
