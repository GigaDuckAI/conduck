// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// AudioExclusivityCrossSurfaceTests.swift
//
// The `SpeechExclusivity` bus as the app's THREE audio surfaces actually use
// it — the composer microphone, the chat read-aloud, and the desk's voice-note
// cards — rather than as spy parties talking to a throwaway registry
// (`SpeechExclusivityTests`) or one surface talking to an injected one
// (`WorkboardAudioCardTests`). What only this level can see is whether a
// surface is WIRED to the bus on the platform under test: a claim that reaches
// nobody looks identical to a claim that reached everybody until real parties
// are on the other end.
//
// Every case here therefore drives production objects against the REAL
// `SpeechExclusivity.shared`, which those objects hardcode. That is safe for
// the same reason `ThreadSpeakerExclusivityTests` gives: parties and
// authorities are held weakly, so each test's instances drop out of the
// registry when they die, and no other suite holds a playing speaker or a live
// capture.
//
// Two things stay out of the bus by construction and are asserted as such:
// CarPlay's own speaker (a separate `ReplyVoice` instance that registers
// nothing, so no claim can preempt the car's exactly-once / deactivate-once
// legs) and, unreachable from a headless run, a live CarPlay voice session —
// `CarPlayRecordingService.anySessionActive` is written only by a real car
// connection, so the desk's refusal against it stays a founder-QA item.

import Speech
import XCTest
@testable import Conduck

@MainActor
final class AudioExclusivityCrossSurfaceTests: XCTestCase {

    // MARK: - Rigs

    /// A granted-by-default arbiter, so a card's bus behaviour is observable
    /// without an `AVAudioSession`. Playback itself still needs real hardware:
    /// these cases stop at the claim, which is where the wiring lives.
    @MainActor
    private final class StubArbiter: WorkboardAudioOutputArbiter {
        var captureIsLive = false
        func claim(for client: AnyObject) -> WorkboardAudioOutputClaim { .granted }
        func release(for client: AnyObject) {}
    }

    /// Holds a payload read open so a card can be observed mid-`.loading` —
    /// the one phase reachable without decodable audio.
    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    // The fake-seam `ReplyVoice` rig, same shape as `ThreadSpeakerTests`: a
    // fetcher that answers immediately and a player that LATCHES the start
    // callback, so the loading → playing transition is driven by hand.

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

    private func makeVoice() -> (ReplyVoice, ControllablePlayer) {
        let player = ControllablePlayer()
        let voice = ReplyVoice(fetcher: ImmediateFetcher(), player: player, snapshot: FixedSnapshot(),
                               outcomeLog: makeThrowawayOutcomeLog())
        return (voice, player)
    }

    private func makeSpeaker() -> (ThreadSpeaker, ControllablePlayer) {
        let (voice, player) = makeVoice()
        return (ThreadSpeaker(engine: voice), player)
    }

    /// A card parked on the real bus with no session behind it.
    private func makeCard() -> WorkboardAudioCardPlayer {
        WorkboardAudioCardPlayer(
            exclusivity: WorkboardAudioExclusivity(),
            output: StubArbiter(),
            speechBus: .shared
        )
    }

    /// A composer recorder whose microphone comes up on demand — there is no
    /// input device on a simulator, and what these cases need is the ORDER the
    /// start path claims things in, not real audio.
    private func makeRecorder() -> InAppAudioRecorder {
        let recorder = InAppAudioRecorder(retryDestination: .chat)
        recorder.microphoneStartForTesting = { true }
        // The Speech-Recognition preflight sits ABOVE that microphone seam and
        // reads the machine's live TCC row — it never prompts under XCTest — so
        // a device or CI image whose row for this bundle is `denied` bails
        // before the capture starts and every ordering claim here fails for a
        // reason that is not the code. Pinned so these cases stay about audio.
        recorder.speechAuthorizationForTesting = .authorized
        return recorder
    }

    private func spin(
        until condition: () -> Bool,
        attempts: Int = 200
    ) async {
        for _ in 0..<attempts {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - The microphone

    func testTheComposerMicrophoneIsALiveCaptureTheDeskCanSee() async {
        let recorder = makeRecorder()

        await recorder.startRecording()
        guard case .recording = recorder.state else {
            return XCTFail("the capture must actually be recording for the probe to mean anything")
        }

        XCTAssertTrue(
            SpeechExclusivity.shared.isRecordingActive,
            "the composer mic must register as a recording authority on this platform"
        )
        XCTAssertTrue(
            WorkboardAudioOutput.shared.captureIsLive,
            """
            The desk asks exactly this question before it plays a note. Without \
            the registration it answers "no capture" while the session is on \
            .record, and the card reports playback over silence.
            """
        )
    }

    func testAStartingMicrophoneStopsACardThatIsBringingAudioUp() async {
        let card = makeCard()
        let gate = Gate()
        card.toggle {
            await gate.wait()
            return Data("not audio".utf8)
        }
        XCTAssertEqual(card.phase, .loading)

        // The recorder's own broadcast, from its real start path.
        let recorder = makeRecorder()
        await recorder.startRecording()
        guard case .recording = recorder.state else {
            return XCTFail("the capture must actually be recording")
        }

        XCTAssertEqual(
            card.phase, .idle,
            "a capture starting mid-read must take the card down rather than race it to output"
        )
        await gate.open()
    }

    func testAStartingMicrophoneStopsAReplyThatIsBeingReadAloud() async {
        let (speaker, player) = makeSpeaker()
        let id = UUID()
        speaker.speak("A spoken reply.", messageID: id)
        await spin(until: { player.playCount == 1 })
        player.fireStart()
        XCTAssertEqual(speaker.speakState(for: id), .playing)

        let recorder = makeRecorder()
        await recorder.startRecording()

        XCTAssertEqual(
            speaker.speakState(for: id), .idle,
            "a reply must not go on reading into a live capture"
        )
    }

    // MARK: - Chat read-aloud and the desk

    func testAReplyStartingStopsACardThatIsBringingAudioUp() async {
        let card = makeCard()
        let gate = Gate()
        card.toggle {
            await gate.wait()
            return Data("not audio".utf8)
        }
        XCTAssertEqual(card.phase, .loading)

        let (speaker, _) = makeSpeaker()
        speaker.speak("A spoken reply.", messageID: UUID())

        XCTAssertEqual(
            card.phase, .idle,
            "a read-aloud and a voice note are two players on one session — the newer one wins"
        )
        await gate.open()
    }

    func testACardTakingOutputStopsAReplyThatIsBeingReadAloud() async {
        let (speaker, player) = makeSpeaker()
        let id = UUID()
        speaker.speak("A spoken reply.", messageID: id)
        await spin(until: { player.playCount == 1 })
        player.fireStart()
        XCTAssertEqual(speaker.speakState(for: id), .playing)
        let stopsBefore = player.stopCount

        // The card claims the bus BEFORE it decodes, so the read-aloud stops
        // whether or not these bytes turn out to be playable — they are not,
        // which is why the card itself lands on `.failed`.
        let card = makeCard()
        card.toggle { Data("not audio".utf8) }
        await spin(until: { card.phase == .failed })

        XCTAssertEqual(
            speaker.speakState(for: id), .idle,
            "tapping a voice note must stop the reply rather than play over it"
        )
        XCTAssertGreaterThan(player.stopCount, stopsBefore)
    }

    func testTwoChatSpeakersDoNotOverlapOnThisPlatform() async {
        let (first, firstPlayer) = makeSpeaker()
        let (second, secondPlayer) = makeSpeaker()
        let firstID = UUID()

        first.speak("First voice.", messageID: firstID)
        await spin(until: { firstPlayer.playCount == 1 })
        firstPlayer.fireStart()
        XCTAssertEqual(first.speakState(for: firstID), .playing)

        second.speak("Second voice.", messageID: UUID())
        await spin(until: { secondPlayer.playCount == 1 })

        XCTAssertEqual(
            first.speakState(for: firstID), .idle,
            """
            Each thread view owns its own engine, so cancelling one's engine \
            cannot reach the other. Two columns on an iPad, or a window and a \
            popover, would otherwise speak at once.
            """
        )
    }

    // MARK: - CarPlay stays outside the bus

    func testTheCarPlaySpeakerIsOutOfReachOfEveryClaim() async {
        // CarPlay builds its OWN `ReplyVoice` rather than using the shared one,
        // and registers it nowhere — this is that instance.
        let (carVoice, carPlayer) = makeVoice()
        carVoice.speak("Turn left.", sanitize: true, completion: { _ in })
        await spin(until: { carPlayer.playCount == 1 })
        carPlayer.fireStart()
        let stopsBefore = carPlayer.stopCount

        // The two broadcasts that stop everything else: a mic start, and a
        // speaker taking over.
        SpeechExclusivity.shared.claim(nil)
        let (speaker, _) = makeSpeaker()
        speaker.speak("A spoken reply.", messageID: UUID())

        XCTAssertEqual(
            carPlayer.stopCount, stopsBefore,
            """
            The car's speak leg owes an exactly-once completion and a \
            deactivate-once session. Nothing on this bus may cut it short.
            """
        )
    }
}
