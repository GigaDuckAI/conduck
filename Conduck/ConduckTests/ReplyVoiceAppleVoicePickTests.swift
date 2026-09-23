// SPDX-License-Identifier: Apache-2.0

// Conduck
// ReplyVoiceAppleVoicePickTests.swift
//
// The picked-Apple-voice guard in `ReplyVoice`: a leg that speaks in the
// user's picked voice must reach a word boundary, or the system default voice
// re-speaks the reply — marked (`.fallbackStarted`), recorded
// (`appleVoiceSubstituted`), with the pick flagged unavailable and the turn's
// completion still firing EXACTLY ONCE. The Settings preview of a picked voice
// fails loud instead of substituting. A scripted player drives the synth
// events; no audio hardware, no `SettingsManager`. iOS/macOS only.

#if !os(watchOS)
import XCTest
@testable import Conduck

@MainActor
final class ReplyVoiceAppleVoicePickTests: XCTestCase {

    // MARK: - Fakes

    /// Plays Apple legs by script: one behavior for a picked voice
    /// (`voiceIdentifier != nil`), one for the default voice. Event order
    /// mirrors `SpeechPlayer`: `didStart` = `onStart` + one progress tick,
    /// then one tick per spoken word.
    final class ScriptedPlayer: SpeechPlaying {
        enum Behavior {
            /// didStart, one word, natural finish.
            case speaks
            /// Nothing at all — no start, no words, no finish.
            case silent
            /// didStart, then nothing (no words, no finish).
            case startsWithoutWords
            /// didStart, then a natural finish with no word in between.
            case finishesWithoutWords
            /// didStart, then a system cancel before any word.
            case cancelledBeforeWords
            /// didStart and a word, then the finish is HELD in `heldDone`
            /// for the test to deliver later.
            case speaksAndHolds
        }

        var pickedBehavior: Behavior = .speaks
        var defaultBehavior: Behavior = .speaks
        /// Consumed first, one per Apple leg, before the two behaviors above.
        var queuedBehaviors: [Behavior] = []
        private(set) var voiceIDs: [String?] = []
        private(set) var stopCount = 0
        private(set) var heldDone: (@MainActor @Sendable (SpeakTerminal) -> Void)?

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
            onDone: @escaping @MainActor @Sendable (SpeakTerminal) -> Void
        ) {
            playApple(text, language: nil, voiceIdentifier: nil, onStart: onStart, onProgress: nil, onDone: onDone)
        }

        func playApple(
            _ text: String,
            language: String?,
            onStart: (@MainActor @Sendable () -> Void)?,
            onProgress: (@MainActor @Sendable () -> Void)?,
            onDone: @escaping @MainActor @Sendable (SpeakTerminal) -> Void
        ) {
            playApple(text, language: language, voiceIdentifier: nil, onStart: onStart, onProgress: onProgress, onDone: onDone)
        }

        func playApple(
            _ text: String,
            language: String?,
            voiceIdentifier: String?,
            onStart: (@MainActor @Sendable () -> Void)?,
            onProgress: (@MainActor @Sendable () -> Void)?,
            onDone: @escaping @MainActor @Sendable (SpeakTerminal) -> Void
        ) {
            voiceIDs.append(voiceIdentifier)
            let behavior = queuedBehaviors.isEmpty
                ? (voiceIdentifier == nil ? defaultBehavior : pickedBehavior)
                : queuedBehaviors.removeFirst()
            switch behavior {
            case .speaks:
                onStart?(); onProgress?()
                onProgress?()
                onDone(.finished)
            case .silent:
                break
            case .startsWithoutWords:
                onStart?(); onProgress?()
            case .finishesWithoutWords:
                onStart?(); onProgress?()
                onDone(.finished)
            case .cancelledBeforeWords:
                onStart?(); onProgress?()
                onDone(.incomplete)
            case .speaksAndHolds:
                onStart?(); onProgress?()
                onProgress?()
                heldDone = onDone
            }
        }

        func stop() { stopCount += 1 }
        func pause() { }
        func resume() { }
    }

    /// Resolves a snapshot carrying `pick`; records every unavailable mark.
    final class PickSnapshot: TTSSnapshotResolving {
        var providerID = TTSProvider.appleTTS.id
        var apiKey: String?
        var pick: AppleVoicePick?
        private(set) var marked: [AppleVoicePick] = []

        func activeTTSSnapshot() async -> TTSSnapshot {
            let keyState: APIKeyState
            if providerID == TTSProvider.appleTTS.id {
                keyState = .notRequired
            } else {
                keyState = apiKey == nil ? .missing : .present
            }
            return TTSSnapshot(
                providerID: providerID, apiKey: apiKey, keyState: keyState,
                voice: nil, customModel: nil, customConfig: nil, appleVoice: pick
            )
        }

        func markAppleVoiceUnavailable(_ pick: AppleVoicePick) {
            marked.append(pick)
        }
    }

    /// A cloud fetch that never returns until its task is cancelled.
    struct HangingFetcher: TTSFetching {
        func synthesize(text: String, provider: TTSProvider, voice: String?, customModel: String?, apiKey: String, customConfig: CustomTTSConfig?) async throws -> Data {
            try await Task.sleep(for: .seconds(60))
            return Data()
        }
    }

    struct FailingFetcher: TTSFetching {
        func synthesize(text: String, provider: TTSProvider, voice: String?, customModel: String?, apiKey: String, customConfig: CustomTTSConfig?) async throws -> Data {
            throw AppError.ttsProviderUnreachable
        }
    }

    @MainActor
    final class Counter {
        private(set) var value = 0
        func bump() { value += 1 }
    }

    @MainActor
    final class Recorder {
        private(set) var terminals: [SpeakTerminal] = []
        private(set) var startedPlaying = 0
        private(set) var fallbackStarted = 0
        func record(_ t: SpeakTerminal) { terminals.append(t) }
        func activity(_ a: SpeechActivity) {
            switch a {
            case .startedPlaying: startedPlaying += 1
            case .fallbackStarted: fallbackStarted += 1
            }
        }
    }

    // MARK: - Helpers

    private let pick = AppleVoicePick(identifier: "com.apple.voice.premium.en-US.Ava", locale: "en-US")
    private let englishReply = "Here is the summary you asked for, with the three open items listed below."

    private func makeVoice(
        player: ScriptedPlayer,
        snapshot: PickSnapshot,
        log: TTSOutcomeLog,
        fetcher: TTSFetching? = nil,
        firstAudioTimeout: Duration = .seconds(45),
        pickedVoiceStartTimeout: Duration = .milliseconds(50)
    ) -> ReplyVoice {
        ReplyVoice(
            fetcher: fetcher,
            player: player,
            snapshot: snapshot,
            outcomeLog: log,
            chunkPolicy: .off,
            firstAudioTimeout: firstAudioTimeout,
            pickedVoiceStartTimeout: pickedVoiceStartTimeout
        )
    }

    /// Speak and wait for the (exactly-once) completion, then give stray late
    /// callbacks time to fire incorrectly.
    private func speak(_ rv: ReplyVoice, _ text: String, _ recorder: Recorder) {
        let exp = expectation(description: "completion")
        rv.speak(text, sanitize: false, onStateChange: { recorder.activity($0) }) { terminal in
            recorder.record(terminal)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
        spin(0.15)
    }

    private func spin(_ seconds: TimeInterval) {
        let exp = expectation(description: "spin")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exp.fulfill() }
        wait(for: [exp], timeout: seconds + 1)
    }

    // MARK: - Chat turns

    func testAPickedVoiceThatSpeaksIsUsedWithoutAnyReplacement() {
        let player = ScriptedPlayer()
        let snapshot = PickSnapshot()
        snapshot.pick = pick
        let log = makeThrowawayOutcomeLog()
        let recorder = Recorder()

        speak(makeVoice(player: player, snapshot: snapshot, log: log), englishReply, recorder)

        XCTAssertEqual(player.voiceIDs, [pick.identifier])
        XCTAssertEqual(recorder.terminals, [.finished])
        XCTAssertEqual(recorder.startedPlaying, 1)
        XCTAssertEqual(recorder.fallbackStarted, 0, "A working pick is not a substitution.")
        XCTAssertTrue(snapshot.marked.isEmpty)
        XCTAssertTrue(log.events().isEmpty, "Routine intended-Apple playback records nothing.")
    }

    func testASilentPickedVoiceIsReplacedByTheDefaultVoiceAtTheDeadline() {
        let player = ScriptedPlayer()
        player.pickedBehavior = .silent
        let snapshot = PickSnapshot()
        snapshot.pick = pick
        let log = makeThrowawayOutcomeLog()
        let recorder = Recorder()

        speak(makeVoice(player: player, snapshot: snapshot, log: log), englishReply, recorder)

        XCTAssertEqual(player.voiceIDs, [pick.identifier, nil], "The default voice re-speaks the reply.")
        XCTAssertEqual(recorder.terminals, [.finished], "The completion fires exactly once, after the replacement.")
        XCTAssertEqual(recorder.startedPlaying, 1)
        XCTAssertEqual(recorder.fallbackStarted, 1, "The substitution is marked on the message.")
        XCTAssertEqual(snapshot.marked, [pick])
        XCTAssertEqual(log.events().map(\.outcome), [.appleVoiceSubstituted])
        XCTAssertEqual(log.events().last?.stage, .apple)
    }

    func testAPickedVoiceThatStartsButSpeaksNoWordIsReplacedAtTheDeadline() {
        let player = ScriptedPlayer()
        player.pickedBehavior = .startsWithoutWords
        let snapshot = PickSnapshot()
        snapshot.pick = pick
        let recorder = Recorder()

        speak(makeVoice(player: player, snapshot: snapshot, log: makeThrowawayOutcomeLog()), englishReply, recorder)

        XCTAssertEqual(player.voiceIDs, [pick.identifier, nil],
                       "didStart alone is not proof of audio — only a word boundary is.")
        XCTAssertEqual(recorder.terminals, [.finished])
        XCTAssertEqual(recorder.startedPlaying, 1,
                       "`.startedPlaying` is held back until audio is proven, then emitted once.")
    }

    func testAPickedVoiceThatFinishesWithoutAWordIsReplacedImmediately() {
        let player = ScriptedPlayer()
        player.pickedBehavior = .finishesWithoutWords
        let snapshot = PickSnapshot()
        snapshot.pick = pick
        let recorder = Recorder()

        speak(makeVoice(player: player, snapshot: snapshot, log: makeThrowawayOutcomeLog()), englishReply, recorder)

        XCTAssertEqual(player.voiceIDs, [pick.identifier, nil])
        XCTAssertEqual(recorder.terminals, [.finished])
        XCTAssertEqual(snapshot.marked, [pick])
    }

    func testASystemCancelBeforeTheFirstWordSettlesWithoutAReplacement() {
        let player = ScriptedPlayer()
        player.pickedBehavior = .cancelledBeforeWords
        let snapshot = PickSnapshot()
        snapshot.pick = pick
        let recorder = Recorder()

        speak(makeVoice(player: player, snapshot: snapshot, log: makeThrowawayOutcomeLog()), englishReply, recorder)

        XCTAssertEqual(player.voiceIDs, [pick.identifier],
                       "An interruption is not a broken voice — nothing is re-spoken over it.")
        XCTAssertEqual(recorder.terminals, [.incomplete])
        XCTAssertTrue(snapshot.marked.isEmpty)
    }

    func testAReplyInAnotherLanguageKeepsItsDefaultVoice() {
        let player = ScriptedPlayer()
        player.pickedBehavior = .silent   // would stall if it were (wrongly) used
        let snapshot = PickSnapshot()
        snapshot.pick = pick
        let recorder = Recorder()
        let german = "Hier ist die Zusammenfassung, die du angefordert hast, mit den drei offenen Punkten unten."

        speak(makeVoice(player: player, snapshot: snapshot, log: makeThrowawayOutcomeLog()), german, recorder)

        XCTAssertEqual(player.voiceIDs, [nil], "An English pick never reads a German reply.")
        XCTAssertEqual(recorder.terminals, [.finished])
    }

    func testNoPickSpeaksTheDefaultVoiceAsBefore() {
        let player = ScriptedPlayer()
        let snapshot = PickSnapshot()
        let recorder = Recorder()

        speak(makeVoice(player: player, snapshot: snapshot, log: makeThrowawayOutcomeLog()), englishReply, recorder)

        XCTAssertEqual(player.voiceIDs, [nil])
        XCTAssertEqual(recorder.terminals, [.finished])
        XCTAssertEqual(recorder.fallbackStarted, 0)
    }

    func testCancelDuringAPickedAttemptNeitherReplacesNorFires() {
        let player = ScriptedPlayer()
        player.pickedBehavior = .silent
        let snapshot = PickSnapshot()
        snapshot.pick = pick
        let recorder = Recorder()
        let rv = makeVoice(player: player, snapshot: snapshot, log: makeThrowawayOutcomeLog())

        rv.speak(englishReply, sanitize: false) { recorder.record($0) }
        spin(0.02)   // let the snapshot resolve and the picked leg start
        rv.cancel()
        spin(0.2)    // well past the picked-voice deadline

        XCTAssertEqual(player.voiceIDs, [pick.identifier], "A cancelled turn is never re-spoken.")
        XCTAssertTrue(recorder.terminals.isEmpty, "cancel() never fires the completion.")
        XCTAssertTrue(snapshot.marked.isEmpty)
    }

    func testAPausedPickedAttemptWaitsAndResumesItsDeadline() {
        let player = ScriptedPlayer()
        player.pickedBehavior = .silent
        let snapshot = PickSnapshot()
        snapshot.pick = pick
        let recorder = Recorder()
        let rv = makeVoice(player: player, snapshot: snapshot, log: makeThrowawayOutcomeLog())

        let exp = expectation(description: "completion")
        rv.speak(englishReply, sanitize: false) { recorder.record($0); exp.fulfill() }
        spin(0.02)
        rv.pause()
        spin(0.2)
        XCTAssertEqual(player.voiceIDs, [pick.identifier], "A paused synth speaks no words; the deadline waits.")

        rv.resume()
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(player.voiceIDs, [pick.identifier, nil], "After resume the deadline runs again.")
        XCTAssertEqual(recorder.terminals, [.finished])
    }

    func testACloudFallbackThatLosesItsPickKeepsTheCloudReason() {
        let player = ScriptedPlayer()
        player.pickedBehavior = .silent
        let snapshot = PickSnapshot()
        snapshot.providerID = "openai-tts"
        snapshot.apiKey = "key"
        snapshot.pick = pick
        let log = makeThrowawayOutcomeLog()
        let recorder = Recorder()

        speak(makeVoice(player: player, snapshot: snapshot, log: log, fetcher: FailingFetcher()), englishReply, recorder)

        XCTAssertEqual(player.voiceIDs, [pick.identifier, nil],
                       "The Apple fallback uses the pick, and replaces it when it is silent.")
        XCTAssertEqual(recorder.terminals, [.finished])
        XCTAssertEqual(recorder.fallbackStarted, 1)
        XCTAssertEqual(log.events().map(\.outcome), [.appleFallback, .appleVoiceSubstituted],
                       "Both causes are recorded: the cloud failure and the silent pick.")
        XCTAssertEqual(snapshot.marked, [pick])
    }

    func testAPickAlreadyMarkedUnavailableSpeaksTheDefaultStillMarked() {
        let player = ScriptedPlayer()
        player.pickedBehavior = .silent   // would stall if it were (wrongly) retried
        let snapshot = PickSnapshot()
        snapshot.pick = AppleVoicePick(identifier: pick.identifier, locale: pick.locale, isUnavailable: true)
        let log = makeThrowawayOutcomeLog()
        let recorder = Recorder()

        speak(makeVoice(player: player, snapshot: snapshot, log: log), englishReply, recorder)

        XCTAssertEqual(player.voiceIDs, [nil], "A known-unavailable pick is not retried — no start delay.")
        XCTAssertEqual(recorder.terminals, [.finished])
        XCTAssertEqual(recorder.fallbackStarted, 1, "Every reply the pick would have spoken is still marked.")
        XCTAssertTrue(log.events().isEmpty, "The failure was recorded once, when it happened.")
        XCTAssertTrue(snapshot.marked.isEmpty)
    }

    /// A superseded reply that finishes naturally after the next turn began
    /// must not disarm the NEW turn's watchdogs: here the new turn's cloud
    /// fetch hangs, and only its first-audio watchdog can settle it.
    func testALateFinishFromASupersededReplyLeavesTheNewTurnsWatchdogArmed() {
        let player = ScriptedPlayer()
        player.queuedBehaviors = [.speaksAndHolds]
        let snapshot = PickSnapshot()
        let rv = makeVoice(
            player: player, snapshot: snapshot, log: makeThrowawayOutcomeLog(),
            fetcher: HangingFetcher(), firstAudioTimeout: .milliseconds(150)
        )

        let first = Recorder()
        rv.speak(englishReply, sanitize: false) { first.record($0) }
        spin(0.05)
        XCTAssertEqual(player.voiceIDs.count, 1)

        snapshot.providerID = "openai-tts"
        snapshot.apiKey = "key"
        let second = Recorder()
        let exp = expectation(description: "second turn settles")
        rv.speak(englishReply, sanitize: false) { second.record($0); exp.fulfill() }
        spin(0.02)
        player.heldDone?(.finished)   // the superseded utterance finishes late

        wait(for: [exp], timeout: 2)
        XCTAssertEqual(second.terminals, [.finished],
                       "The stall watchdog still hands the hung turn to the Apple voice.")
    }

    // MARK: - Settings preview

    private func preview(_ rv: ReplyVoice, pick: AppleVoicePick?) -> Result<Void, AppError>? {
        let exp = expectation(description: "preview")
        var outcome: Result<Void, AppError>?
        rv.previewSample(providerID: TTSProvider.appleTTS.id, voice: nil, apiKey: nil, appleVoice: pick) {
            outcome = $0
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
        spin(0.15)
        return outcome
    }

    func testPreviewOfASilentPickFailsLoudAndNeverSubstitutes() {
        let player = ScriptedPlayer()
        player.pickedBehavior = .silent
        let log = makeThrowawayOutcomeLog()
        let rv = makeVoice(player: player, snapshot: PickSnapshot(), log: log)

        let outcome = preview(rv, pick: pick)

        guard case .failure(let error) = outcome else { return XCTFail("Expected a loud failure, got \(String(describing: outcome))") }
        XCTAssertEqual(error.errorCode, AppError.ttsSynthesisFailed.errorCode)
        XCTAssertEqual(player.voiceIDs, [pick.identifier], "The preview never plays the default in its place.")
        XCTAssertEqual(log.events().map(\.outcome), [.failedLoud])
    }

    func testPreviewOfAPickThatFinishesWithoutAWordFailsLoud() {
        let player = ScriptedPlayer()
        player.pickedBehavior = .finishesWithoutWords
        let rv = makeVoice(player: player, snapshot: PickSnapshot(), log: makeThrowawayOutcomeLog())

        guard case .failure = preview(rv, pick: pick) else { return XCTFail("Expected a loud failure.") }
    }

    func testCancellingAPickedPreviewSignalsAbandonmentNotCompletion() {
        let player = ScriptedPlayer()
        player.pickedBehavior = .silent
        let rv = makeVoice(player: player, snapshot: PickSnapshot(), log: makeThrowawayOutcomeLog(),
                           pickedVoiceStartTimeout: .seconds(10))
        let abandoned = Counter()
        let completed = Counter()
        rv.previewSample(providerID: TTSProvider.appleTTS.id, voice: nil, apiKey: nil, appleVoice: pick,
                         onAbandoned: { abandoned.bump() }) { _ in completed.bump() }

        rv.cancel()
        rv.cancel()
        spin(0.1)

        XCTAssertEqual(abandoned.value, 1, "The waiting Settings row is released exactly once.")
        XCTAssertEqual(completed.value, 0, "cancel() still never fires the completion.")
    }

    func testANewReplySupersedingAPreviewSignalsAbandonment() {
        let player = ScriptedPlayer()
        player.pickedBehavior = .silent
        let rv = makeVoice(player: player, snapshot: PickSnapshot(), log: makeThrowawayOutcomeLog(),
                           pickedVoiceStartTimeout: .seconds(10))
        let abandoned = Counter()
        rv.previewSample(providerID: TTSProvider.appleTTS.id, voice: nil, apiKey: nil, appleVoice: pick,
                         onAbandoned: { abandoned.bump() }) { _ in }

        speak(rv, englishReply, Recorder())

        XCTAssertEqual(abandoned.value, 1)
    }

    func testASettledPreviewIsNotAbandonedLater() {
        let player = ScriptedPlayer()
        let rv = makeVoice(player: player, snapshot: PickSnapshot(), log: makeThrowawayOutcomeLog())
        let abandoned = Counter()
        let exp = expectation(description: "preview")
        rv.previewSample(providerID: TTSProvider.appleTTS.id, voice: nil, apiKey: nil, appleVoice: pick,
                         onAbandoned: { abandoned.bump() }) { _ in exp.fulfill() }
        wait(for: [exp], timeout: 2)

        rv.cancel()

        XCTAssertEqual(abandoned.value, 0, "Only a preview that never reported is abandoned.")
    }

    func testPreviewOfASpeakingPickSucceeds() {
        let player = ScriptedPlayer()
        let log = makeThrowawayOutcomeLog()
        let rv = makeVoice(player: player, snapshot: PickSnapshot(), log: log)

        guard case .success = preview(rv, pick: pick) else { return XCTFail("Expected success.") }
        XCTAssertEqual(player.voiceIDs, [pick.identifier])
        XCTAssertEqual(log.events().map(\.outcome), [.appleOK])
    }
}
#endif
