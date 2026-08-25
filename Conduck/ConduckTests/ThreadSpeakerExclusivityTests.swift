// SPDX-License-Identifier: Apache-2.0

// Conduck
// ThreadSpeakerExclusivityTests.swift
//
// macOS-only integration coverage for `ThreadSpeaker`'s wiring onto the
// `SpeechExclusivity` bus: each speaker registers itself in `init`, and
// starting (or resuming) an utterance claims the bus — silencing every OTHER
// registered speaker. This is the cross-INSTANCE arbitration the pure
// `SpeechExclusivityTests` can't see (those use spy parties); here two real
// `ThreadSpeaker`s built on the same fake-seam `ReplyVoice` rig as
// `ThreadSpeakerTests` prove that one speaker starting resets the other's
// bubble state to `.idle`. `#if os(macOS)` because the registration/claim
// lines inside `ThreadSpeaker` only exist there — and they use the REAL
// `SpeechExclusivity.shared` (the init hardcodes it), which is safe here:
// parties are weak (test instances die with the test) and no other live
// suite holds a playing speaker.

#if os(macOS)
import XCTest
@testable import Conduck

@MainActor
final class ThreadSpeakerExclusivityTests: XCTestCase {

    // Reuse the controllable-player pattern from ThreadSpeakerTests: a fetcher
    // that returns bytes immediately and a player that LATCHES the start/done
    // closures so the test drives transitions by hand.

    private struct ImmediateFetcher: TTSFetching {
        func synthesize(text: String, provider: TTSProvider, voice: String?, customModel: String?, apiKey: String, customConfig: CustomTTSConfig?) async throws -> Data {
            Data([0x01])
        }
    }

    private struct FixedSnapshot: TTSSnapshotResolving {
        func activeTTSSnapshot() async -> TTSSnapshot {
            TTSSnapshot(providerID: "openai-tts", apiKey: "key-123",
                        keyState: .present, voice: nil, customModel: nil, customConfig: nil)
        }
    }

    private final class ControllablePlayer: SpeechPlaying {
        private(set) var starts: [(@MainActor @Sendable () -> Void)?] = []
        private(set) var stopCount = 0
        func playCloud(_ data: Data, onStart: (@MainActor @Sendable () -> Void)?, onDone: @escaping @MainActor @Sendable (CloudPlaybackOutcome) -> Void) {
            starts.append(onStart)
        }
        func playApple(_ text: String, onStart: (@MainActor @Sendable () -> Void)?, onDone: @escaping @MainActor @Sendable (SpeakTerminal) -> Void) {
            starts.append(onStart)
        }
        func stop() { stopCount += 1 }
        func pause() {}
        func resume() {}
        var playCount: Int { starts.count }
        func fireStart() { starts.last??() }
    }

    private func makeSpeaker() -> (ThreadSpeaker, ControllablePlayer) {
        let player = ControllablePlayer()
        let rv = ReplyVoice(fetcher: ImmediateFetcher(), player: player, snapshot: FixedSnapshot(),
                            outcomeLog: makeThrowawayOutcomeLog())
        return (ThreadSpeaker(engine: rv), player)
    }

    private func spin(until condition: @escaping () -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await Task.yield()
        }
    }

    // MARK: - one speaker starting silences the other

    func testSpeakOnSecondSpeakerStopsFirst() async {
        let (speakerA, playerA) = makeSpeaker()
        let (speakerB, playerB) = makeSpeaker()
        let idA = UUID(), idB = UUID()

        speakerA.speak("First voice.", messageID: idA)
        // B was IDLE when A claimed the bus — the idle guard in
        // `stopForSpeechExclusivity` must leave it completely untouched (no
        // engine stop, no spurious VoiceOver "Stopped").
        XCTAssertEqual(playerB.stopCount, 0,
                       "A claim must not touch an idle speaker's engine.")
        await spin(until: { playerA.playCount == 1 })
        playerA.fireStart()
        XCTAssertEqual(speakerA.speakState(for: idA), .playing)

        let aStopsBefore = playerA.stopCount
        speakerB.speak("Second voice.", messageID: idB)

        XCTAssertEqual(speakerA.speakState(for: idA), .idle,
                       "Speaker B claiming the bus must reset speaker A's bubble to .idle.")
        XCTAssertNil(speakerA.speakingMessageID)
        XCTAssertGreaterThan(playerA.stopCount, aStopsBefore,
                             "The preempted speaker must hard-stop its player (no orphan audio).")

        // B's own turn proceeds normally.
        await spin(until: { playerB.playCount == 1 })
        playerB.fireStart()
        XCTAssertEqual(speakerB.speakState(for: idB), .playing,
                       "The claiming speaker's own turn must be unaffected by its claim.")
    }

    // MARK: - the mic's nil claim silences every speaker

    func testMicClaimStopsAllSpeakers() async {
        let (speakerA, playerA) = makeSpeaker()
        let idA = UUID()

        speakerA.speak("Playing when the mic starts.", messageID: idA)
        await spin(until: { playerA.playCount == 1 })
        playerA.fireStart()
        XCTAssertEqual(speakerA.speakState(for: idA), .playing)

        // What DictationService.startRecording does (mic wins, stop ALL).
        SpeechExclusivity.shared.claim(nil)

        XCTAssertEqual(speakerA.speakState(for: idA), .idle,
                       "A mic claim must silence a playing view speaker (the TTS→mic bleed fix).")
        XCTAssertNil(speakerA.speakingMessageID)
    }
}
#endif
