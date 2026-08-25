// SPDX-License-Identifier: Apache-2.0

// Conduck — watchOS-only contract tests.
//
// Locks `WatchReplySpeaker`'s cloud-fail → Apple handoff tree — the wrist's
// only never-silent guarantee — driven through the injectable seams
// (`synthesize` + `firstAudioTimeout` + the test-only Apple leg), so no
// network and no real `AVSpeechSynthesizer` delegate is awaited (those are
// unreliable in watch-sim unit tests; the injected leg records the text and
// drives the SAME start/completion funnels the delegates would):
//   - a THROWN cloud synth falls back to Apple with the FULL text and the
//     exactly-once completion (a duplicate terminal is inert);
//   - a HUNG cloud synth is bounded by the first-audio watchdog — expiry
//     hands the WHOLE reply to Apple, and the stale fetch resolving later is
//     inert (no re-speak, no double completion);
//   - a hung CHUNKED head gets the same handoff with the FULL text (nothing
//     played yet ⇒ never a remainder);
//   - a supersede/cancel disarms the pending watchdog (no stale expiry may
//     re-speak an abandoned turn);
//   - the empty-after-sanitize early return completes synchronously and arms
//     nothing.
//
// The cloud path is reached by seeding `WatchSettingsReader.shared` with a
// cloud-TTS-active snapshot via `updateActiveSTT` (strictly-newer timestamps —
// the monotonic envelope guard the settings-apply suite locks — and the TTS
// key is in-memory only, so no Keychain/signing dependency); each test
// restores the Apple default in teardown. The real audio-session activation
// still runs (watch-sim activation completes quickly); every wait is a
// bounded condition-driven drain, never an unbounded await.

import XCTest
@testable import ConduckWatch_Watch_App

@MainActor
final class WatchReplySpeakerFallbackTests: XCTestCase {

    // MARK: - Fakes

    /// Recorder for the injected Apple leg: stores the text + the funnels; the
    /// test fires start/done BY HAND (real terminals are always async — same
    /// posture as SpeechChunkQueueTests' fake players).
    @MainActor
    final class AppleLegRecorder {
        struct Leg {
            let text: String
            let onStart: @MainActor () -> Void
            let onDone: @MainActor () -> Void
        }
        private(set) var legs: [Leg] = []
        var texts: [String] { legs.map(\.text) }

        func speak(_ text: String,
                   _ onStart: @escaping @MainActor () -> Void,
                   _ onDone: @escaping @MainActor () -> Void) {
            legs.append(Leg(text: text, onStart: onStart, onDone: onDone))
        }
        func fireStart(_ index: Int = 0) { legs[index].onStart() }
        func fireDone(_ index: Int = 0) { legs[index].onDone() }
    }

    /// A cloud synth that HANGS — suspends every call on a stored continuation
    /// until the test resolves it (as a failure). Models the wedged POST from
    /// the field's -1001 sessions; `failAll()` doubles as the late-stale-
    /// resolution probe AND the continuation-hygiene release.
    @MainActor
    final class HangingSynth {
        private(set) var calls = 0
        private var pending: [CheckedContinuation<Data, Error>] = []

        func next() async throws -> Data {
            calls += 1
            return try await withCheckedThrowingContinuation { pending.append($0) }
        }
        func failAll() {
            let waiting = pending
            pending.removeAll()
            for continuation in waiting {
                continuation.resume(throwing: AppError.ttsSynthesisFailed)
            }
        }
    }

    /// Records the additive `.startedPlaying` + `.fallbackStarted` signals and
    /// the exactly-once completion (mirrors ReplyVoiceChunkingTests' TurnRecorder).
    @MainActor
    final class TurnRecorder {
        private(set) var startedPlaying = 0
        private(set) var fallbackStarted = 0
        private(set) var completions = 0
        func recordStart() { startedPlaying += 1 }
        func recordFallback() { fallbackStarted += 1 }
        func recordDone() { completions += 1 }
    }

    // MARK: - Fixtures & helpers

    /// Short (single-segment under `.wristConservative`) and long (multi-
    /// segment) neutral fixtures. Newline-joined so atom boundaries are
    /// guaranteed by the segmenter's line-start splitting.
    private static let shortReply = "The gateway reply arrives here."
    private static let longReply: String = (1...12)
        .map { "Sentence number \($0) carries plenty of spoken words so the segmenter has real material to pack." }
        .joined(separator: "\n")

    /// Seed the process-shared reader with a cloud-TTS-active snapshot so
    /// `speak` takes the cloud path (Mistral + an in-memory key — no Keychain
    /// write, no signing dependency). Strictly-newer timestamps respect the
    /// monotonic stale-guard; teardown restores the Apple default the same way.
    private func seedCloudTTS() {
        let reader = WatchSettingsReader.shared
        reader.updateActiveSTT(
            presetID: reader.activePresetID,
            apiKey: nil,
            ttsProviderID: "mistral-tts",
            ttsApiKey: "unit-test-key",
            timestamp: reader.lastEnvelopeTimestamp + 1000
        )
        addTeardownBlock { @MainActor in
            let reader = WatchSettingsReader.shared
            reader.updateActiveSTT(
                presetID: reader.activePresetID,
                apiKey: nil,
                ttsProviderID: Constants.ttsActiveProviderIDDefault,
                ttsApiKey: nil,
                timestamp: reader.lastEnvelopeTimestamp + 1000
            )
        }
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
    /// async session activation + the 150 ms test watchdogs.
    private func drain(until condition: @autoclosure @MainActor () -> Bool) async {
        for _ in 0..<600 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func speak(
        _ speaker: WatchReplySpeaker, _ text: String, into recorder: TurnRecorder
    ) {
        speaker.speak(
            text,
            sanitize: false,
            onStateChange: {
                switch $0 {
                case .startedPlaying: recorder.recordStart()
                case .fallbackStarted: recorder.recordFallback()
                }
            },
            completion: { _ in recorder.recordDone() }
        )
    }

    /// Seed the shared reader with an arbitrary TTS provider + key under the
    /// monotonic envelope guard; teardown restores the Apple default. Used by
    /// the `.missingKey`-split + intended-Apple tests (a cloud provider with NO
    /// key, and the Apple sentinel).
    private func seedTTS(providerID: String, ttsApiKey: String?) {
        let reader = WatchSettingsReader.shared
        _ = reader.updateActiveSTT(
            presetID: reader.activePresetID,
            apiKey: nil,
            ttsProviderID: providerID,
            ttsApiKey: ttsApiKey,
            timestamp: reader.lastEnvelopeTimestamp + 1000
        )
        addTeardownBlock { @MainActor in
            let reader = WatchSettingsReader.shared
            _ = reader.updateActiveSTT(
                presetID: reader.activePresetID,
                apiKey: nil,
                ttsProviderID: Constants.ttsActiveProviderIDDefault,
                ttsApiKey: nil,
                timestamp: reader.lastEnvelopeTimestamp + 1000
            )
        }
    }

    // MARK: - 1. Thrown cloud synth → Apple leg, exactly-once completion

    func testCloudSynthThrowFallsBackToAppleExactlyOnce() async {
        seedCloudTTS()
        let apple = AppleLegRecorder()
        // Watchdog generous on purpose: the THROW path must be the trigger.
        let speaker = WatchReplySpeaker(
            synthesize: { _, _, _, _, _ in throw AppError.ttsProviderUnreachable },
            firstAudioTimeout: .seconds(60),
            appleLeg: { apple.speak($0, $1, $2) }
        )
        let rec = TurnRecorder()
        speak(speaker, Self.shortReply, into: rec)

        await drain(until: apple.legs.count == 1)
        XCTAssertEqual(apple.texts, [Self.shortReply],
                       "The throw path hands the FULL text to Apple.")
        XCTAssertEqual(rec.completions, 0, "Completion waits for the Apple leg's terminal.")

        apple.fireStart()
        XCTAssertEqual(rec.startedPlaying, 1, "The Apple leg still emits the start signal.")
        apple.fireDone()
        XCTAssertEqual(rec.completions, 1)
        apple.fireDone()   // stray duplicate terminal — the nil-then-call latch
        XCTAssertEqual(rec.completions, 1, "Completion fires exactly once.")
        XCTAssertEqual(rec.startedPlaying, 1)
    }

    // MARK: - 2. Hung cloud synth → watchdog handoff; late resolution inert

    func testHungSynthWatchdogHandsReplyToAppleAndLateResolutionIsInert() async {
        seedCloudTTS()
        let synth = HangingSynth()
        let apple = AppleLegRecorder()
        let speaker = WatchReplySpeaker(
            synthesize: { _, _, _, _, _ in try await synth.next() },
            firstAudioTimeout: .milliseconds(150),
            appleLeg: { apple.speak($0, $1, $2) }
        )
        let rec = TurnRecorder()
        speak(speaker, Self.shortReply, into: rec)

        await drain(until: apple.legs.count == 1)
        XCTAssertEqual(apple.texts, [Self.shortReply],
                       "Watchdog expiry hands the WHOLE sanitized reply to Apple.")
        apple.fireStart()
        apple.fireDone()
        XCTAssertEqual(rec.completions, 1, "The handoff settles the turn exactly once.")

        // The stalled fetch resolving AFTER the handoff must be inert.
        synth.failAll(); await drain()
        XCTAssertEqual(apple.legs.count, 1, "A late stale fetch must not re-speak.")
        XCTAssertEqual(rec.completions, 1)
        XCTAssertEqual(rec.startedPlaying, 1)
    }

    // MARK: - 3. Hung CHUNKED head → watchdog hands the FULL text to Apple

    func testHungChunkedHeadWatchdogHandsFullTextToApple() async {
        seedCloudTTS()
        let synth = HangingSynth()
        let apple = AppleLegRecorder()
        let speaker = WatchReplySpeaker(
            synthesize: { _, _, _, _, _ in try await synth.next() },
            firstAudioTimeout: .milliseconds(150),
            appleLeg: { apple.speak($0, $1, $2) }
        )
        let rec = TurnRecorder()
        speak(speaker, Self.longReply, into: rec)

        await drain(until: apple.legs.count == 1)
        // Nothing played by definition of first-audio, so the handoff carries
        // the ENTIRE reply — not a chunk remainder.
        XCTAssertEqual(apple.texts, [Self.longReply])
        apple.fireStart()
        apple.fireDone()
        XCTAssertEqual(rec.completions, 1)

        // The queue's abandoned chunk fetches resolving late stay inert
        // (queue cancelled + nil'd without firing at expiry).
        synth.failAll(); await drain()
        XCTAssertEqual(apple.legs.count, 1)
        XCTAssertEqual(rec.completions, 1)
    }

    // MARK: - 4a. A supersede disarms the pending watchdog

    func testSupersedeDisarmsPriorTurnsWatchdog() async {
        seedCloudTTS()
        let synth = HangingSynth()
        let apple = AppleLegRecorder()
        let speaker = WatchReplySpeaker(
            synthesize: { _, _, _, _, _ in try await synth.next() },
            firstAudioTimeout: .milliseconds(150),
            appleLeg: { apple.speak($0, $1, $2) }
        )
        let rec1 = TurnRecorder()
        let rec2 = TurnRecorder()
        let secondReply = "A different reply supersedes the first."
        speak(speaker, Self.shortReply, into: rec1)
        speak(speaker, secondReply, into: rec2)   // supersede before any expiry

        await drain(until: apple.legs.count == 1)
        XCTAssertEqual(apple.texts, [secondReply],
                       "Only the LIVE turn's watchdog may hand off — never the superseded one's.")
        apple.fireStart()
        apple.fireDone()
        XCTAssertEqual(rec1.completions, 0, "The superseded turn's completion must NEVER fire.")
        XCTAssertEqual(rec2.completions, 1)

        // Past the superseded turn's original deadline: still exactly one leg.
        try? await Task.sleep(for: .milliseconds(400)); await drain()
        synth.failAll(); await drain()
        XCTAssertEqual(apple.legs.count, 1)
        XCTAssertEqual(rec1.completions, 0)
        XCTAssertEqual(rec2.completions, 1)
    }

    // MARK: - 4b. cancel() disarms the watchdog (no expiry after teardown)

    func testCancelPreventsWatchdogExpiry() async {
        seedCloudTTS()
        let synth = HangingSynth()
        let apple = AppleLegRecorder()
        let speaker = WatchReplySpeaker(
            synthesize: { _, _, _, _, _ in try await synth.next() },
            firstAudioTimeout: .milliseconds(150),
            appleLeg: { apple.speak($0, $1, $2) }
        )
        let rec = TurnRecorder()
        speak(speaker, Self.shortReply, into: rec)
        speaker.cancel()

        try? await Task.sleep(for: .milliseconds(400)); await drain()
        XCTAssertTrue(apple.legs.isEmpty, "A cancelled turn's watchdog must never hand off.")
        XCTAssertEqual(rec.completions, 0, "cancel() abandons the turn without firing.")

        synth.failAll(); await drain()
        XCTAssertTrue(apple.legs.isEmpty)
        XCTAssertEqual(rec.completions, 0)
    }

    // MARK: - 5. Empty text completes synchronously and arms nothing

    func testEmptyTextCompletesSynchronouslyAndArmsNoWatchdog() async {
        let apple = AppleLegRecorder()
        let speaker = WatchReplySpeaker(
            synthesize: { _, _, _, _, _ in Data() },
            firstAudioTimeout: .milliseconds(150),
            appleLeg: { apple.speak($0, $1, $2) }
        )
        let rec = TurnRecorder()
        speak(speaker, "", into: rec)
        XCTAssertEqual(rec.completions, 1, "Empty text fires the completion synchronously.")
        XCTAssertEqual(rec.startedPlaying, 0, "Nothing plays.")

        // Past the would-be deadline: the early return must not have armed it.
        try? await Task.sleep(for: .milliseconds(400)); await drain()
        XCTAssertTrue(apple.legs.isEmpty, "No watchdog may be armed on the empty-text path.")
        XCTAssertEqual(rec.completions, 1)
    }

    // MARK: - 6. Mid-play cloud failure → Apple leg with the WHOLE reply

    func testMidPlayFailureFallsBackToAppleWithWholeReply() async {
        seedCloudTTS()
        // The fetch hangs so the turn parks in the "cloud in flight" state with
        // the turn text frozen + completion pending; the injected playback-
        // failure then models the clip dying mid-play. Both watchdogs are
        // generous so ONLY the injected failure drives the handoff.
        let synth = HangingSynth()
        let apple = AppleLegRecorder()
        let speaker = WatchReplySpeaker(
            synthesize: { _, _, _, _, _ in try await synth.next() },
            firstAudioTimeout: .seconds(60),
            appleLeg: { apple.speak($0, $1, $2) },
            appleInactivityTimeout: .seconds(60)
        )
        let rec = TurnRecorder()
        speak(speaker, Self.shortReply, into: rec)

        // Let the async activation + fetch reach the in-flight (hung) state.
        await drain(until: synth.calls == 1)
        speaker.simulatePlaybackFailureForTesting()

        await drain(until: apple.legs.count == 1)
        XCTAssertEqual(apple.texts, [Self.shortReply],
                       "A mid-play failure re-speaks the WHOLE reply, never a truncated tail.")
        XCTAssertEqual(rec.completions, 0, "Completion waits for the fallback Apple leg's terminal.")

        apple.fireStart()
        XCTAssertEqual(rec.startedPlaying, 1, "The fallback leg still emits the start signal.")
        XCTAssertEqual(rec.fallbackStarted, 1,
                       "The fallback leg's real audio start emits `.fallbackStarted`.")
        apple.fireDone()
        XCTAssertEqual(rec.completions, 1)
        apple.fireDone()   // stray duplicate — the nil-then-call latch
        XCTAssertEqual(rec.completions, 1, "Completion fires exactly once.")

        // Hygiene: the hung fetch resolving after the turn settled is inert.
        synth.failAll(); await drain()
        XCTAssertEqual(apple.legs.count, 1)
        XCTAssertEqual(rec.completions, 1)
    }

    // MARK: - 7. Missing-key split: cloud provider + no key → Apple FALLBACK

    func testCloudProviderMissingKeyTakesAppleFallbackLegWithMarker() async {
        // Cloud provider selected but NO key on the wrist — the split branch.
        seedTTS(providerID: "mistral-tts", ttsApiKey: nil)
        let apple = AppleLegRecorder()
        let speaker = WatchReplySpeaker(
            synthesize: { _, _, _, _, _ in
                XCTFail("A missing key must never reach the cloud fetch.")
                return Data()
            },
            firstAudioTimeout: .seconds(60),
            appleLeg: { apple.speak($0, $1, $2) },
            appleInactivityTimeout: .seconds(60)
        )
        let rec = TurnRecorder()
        speak(speaker, Self.shortReply, into: rec)

        await drain(until: apple.legs.count == 1)
        XCTAssertEqual(apple.texts, [Self.shortReply],
                       "The missing-key case hands the full reply to Apple.")

        apple.fireStart()
        XCTAssertEqual(rec.startedPlaying, 1)
        XCTAssertEqual(rec.fallbackStarted, 1,
                       "A cloud-provider-with-no-key turn is a FALLBACK → `.fallbackStarted`.")
        apple.fireDone()
        XCTAssertEqual(rec.completions, 1)
    }

    // MARK: - 8. Intended Apple turn never emits `.fallbackStarted`

    func testIntendedAppleTurnEmitsNoFallbackMarker() async {
        // The Apple sentinel is the ACTIVE engine — an INTENDED Apple turn.
        seedTTS(providerID: Constants.ttsActiveProviderIDDefault, ttsApiKey: nil)
        let apple = AppleLegRecorder()
        let speaker = WatchReplySpeaker(
            synthesize: { _, _, _, _, _ in
                XCTFail("An intended-Apple turn must never fetch cloud audio.")
                return Data()
            },
            firstAudioTimeout: .seconds(60),
            appleLeg: { apple.speak($0, $1, $2) },
            appleInactivityTimeout: .seconds(60)
        )
        let rec = TurnRecorder()
        speak(speaker, Self.shortReply, into: rec)

        await drain(until: apple.legs.count == 1)
        apple.fireStart()
        XCTAssertEqual(rec.startedPlaying, 1, "The intended Apple leg emits the start signal.")
        XCTAssertEqual(rec.fallbackStarted, 0,
                       "An INTENDED Apple turn must never emit `.fallbackStarted`.")
        apple.fireDone()
        XCTAssertEqual(rec.completions, 1)
    }

    // MARK: - 9. Dead Apple leg settled by the inactivity watchdog

    func testDeadAppleLegSettlesViaInactivityWatchdog() async {
        // Intended-Apple leg via an override that NEVER calls back — exactly the
        // dead-leg case the inactivity watchdog must settle (a wedged synth with
        // no `didStart`/`didFinish`), so the shared spinner can't hang forever.
        seedTTS(providerID: Constants.ttsActiveProviderIDDefault, ttsApiKey: nil)
        let apple = AppleLegRecorder()   // records the leg but never fires back
        let speaker = WatchReplySpeaker(
            synthesize: { _, _, _, _, _ in Data() },
            firstAudioTimeout: .seconds(60),
            appleLeg: { apple.speak($0, $1, $2) },
            appleInactivityTimeout: .milliseconds(150)
        )
        let rec = TurnRecorder()
        speak(speaker, Self.shortReply, into: rec)

        await drain(until: rec.completions == 1)
        XCTAssertEqual(apple.legs.count, 1, "The Apple leg was entered (and then abandoned).")
        XCTAssertEqual(rec.startedPlaying, 0, "Nothing ever started — the leg was dead.")
        XCTAssertEqual(rec.completions, 1,
                       "The inactivity watchdog SETTLES a dead Apple leg exactly once.")

        // Past the deadline again: still exactly once (no second expiry fires).
        try? await Task.sleep(for: .milliseconds(300)); await drain()
        XCTAssertEqual(rec.completions, 1)
    }

    // MARK: - 10. Cancel during the failure → Apple handoff fires nothing

    func testCancelDuringPlaybackFailureHandoffFiresNothing() async {
        seedCloudTTS()
        let synth = HangingSynth()
        let apple = AppleLegRecorder()
        let speaker = WatchReplySpeaker(
            synthesize: { _, _, _, _, _ in try await synth.next() },
            firstAudioTimeout: .seconds(60),
            appleLeg: { apple.speak($0, $1, $2) },
            appleInactivityTimeout: .seconds(60)
        )
        let rec = TurnRecorder()
        speak(speaker, Self.shortReply, into: rec)
        await drain(until: synth.calls == 1)

        speaker.simulatePlaybackFailureForTesting()   // → Apple fallback leg queued
        await drain(until: apple.legs.count == 1)

        speaker.cancel()          // abandon before the Apple leg starts
        apple.fireStart()         // stale — must be inert
        apple.fireDone()          // stale — must be inert
        await drain()

        XCTAssertEqual(rec.startedPlaying, 0)
        XCTAssertEqual(rec.fallbackStarted, 0)
        XCTAssertEqual(rec.completions, 0, "A cancelled handoff fires nothing.")

        synth.failAll(); await drain()
        XCTAssertEqual(rec.completions, 0)
    }
}
