// Conduck
// ReplyVoiceFallbackTests.swift
//
// Highest-value Half-A test: the cloud→Apple fallback tree + the
// completion-fires-EXACTLY-ONCE contract at the single TTS orchestration
// boundary (`ReplyVoice`). Uses the injectable seams (fetcher / player /
// snapshot) so no network, no audio hardware, no `SettingsManager` actor is
// touched. iOS/macOS only (ReplyVoice is not in the Watch target).

#if !os(watchOS)
import XCTest
@testable import Conduck

@MainActor
final class ReplyVoiceFallbackTests: XCTestCase {

    // MARK: - Fakes

    /// Fake fetcher — returns bytes on success, or throws the given AppError.
    /// `error` non-nil → throw it; nil → return `bytes`. Avoids storing an
    /// `AppError` payload inside a Sendable wrapper.
    struct FakeFetcher: TTSFetching {
        var bytes: Data = Data([0x01, 0x02])
        var error: AppError?
        func synthesize(text: String, provider: TTSProvider, voice: String?, customModel: String?, apiKey: String, customConfig: CustomTTSConfig?) async throws -> Data {
            if let error { throw error }
            return bytes
        }
    }

    /// Fake player — records which path ran + invokes the done-handler
    /// synchronously (no audio hardware). Tracks how many times each fired.
    /// `playCloud` reports the TYPED `cloudOutcome` (default `.finished` = a
    /// successful clip); tests set `.failed(stage)` to drive the cloud→Apple
    /// handoff. The cloud `onStart` fires only when the clip actually began —
    /// i.e. NOT for `.undecodable` / `.startRefused` (playback never started),
    /// but YES for `.finished` and `.playbackFailed` (began, then died) —
    /// mirroring the real `SpeechPlayer`. `appleHoldsCompletion` lets a test
    /// keep the Apple leg "in flight" (onStart fired, onDone withheld) so a
    /// `cancel()` can land mid-handoff.
    final class FakePlayer: SpeechPlaying {
        private(set) var cloudCount = 0
        private(set) var appleCount = 0
        private(set) var appleTexts: [String] = []
        private(set) var stopCount = 0
        private(set) var pauseCount = 0
        private(set) var resumeCount = 0
        /// Typed cloud terminal the fake reports (default: a clean finish).
        var cloudOutcome: CloudPlaybackOutcome = .finished
        // When false, the player does NOT call onDone (simulates the
        // pathological "playback never calls back" leaf).
        var invokeDone = true
        // When false, the player does NOT call onStart (simulates "play() failed
        // to start" — playback never began).
        var invokeStart = true
        /// When true, the Apple leg fires onStart but WITHHOLDS onDone (the leg
        /// stays in flight) — for the cancel-mid-handoff test.
        var appleHoldsCompletion = false

        func playCloud(
            _ data: Data,
            onStart: (@MainActor @Sendable () -> Void)?,
            onDone: @escaping @MainActor @Sendable (CloudPlaybackOutcome) -> Void
        ) {
            cloudCount += 1
            // Only signal start when the clip genuinely began (matches
            // SpeechPlayer: undecodable / startRefused never post a start).
            let began: Bool
            switch cloudOutcome {
            case .finished, .failed(.playbackFailed): began = true
            case .failed(.undecodable), .failed(.startRefused): began = false
            }
            if invokeStart && began { onStart?() }
            if invokeDone { onDone(cloudOutcome) }
        }
        func playApple(
            _ text: String,
            onStart: (@MainActor @Sendable () -> Void)?,
            onDone: @escaping @MainActor @Sendable () -> Void
        ) {
            appleCount += 1
            appleTexts.append(text)
            if invokeStart { onStart?() }
            if appleHoldsCompletion { return }
            if invokeDone { onDone() }
        }
        func stop() { stopCount += 1 }
        func pause() { pauseCount += 1 }
        func resume() { resumeCount += 1 }
    }

    /// Snapshot fake — resolves to a `TTSSnapshot`. Key state derives HONESTLY
    /// from the provider + key (Apple → `.notRequired`; non-empty key →
    /// `.present`; else `.missing`), unless `keyStateOverride` pins it (the
    /// missing/unreadable-key fallback tests). The `apiKey`/`keyState` invariant
    /// (`apiKey != nil ⇔ .present`) is preserved regardless of override.
    struct FakeSnapshot: TTSSnapshotResolving {
        let snap: (providerID: String, apiKey: String?, voice: String?)
        var keyStateOverride: APIKeyState? = nil
        func activeTTSSnapshot() async -> TTSSnapshot {
            let keyState: APIKeyState
            if let keyStateOverride {
                keyState = keyStateOverride
            } else if snap.providerID == TTSProvider.appleTTS.id {
                keyState = .notRequired
            } else if snap.apiKey?.isEmpty == false {
                keyState = .present
            } else {
                keyState = .missing
            }
            return TTSSnapshot(
                providerID: snap.providerID,
                apiKey: keyState == .present ? snap.apiKey : nil,
                keyState: keyState,
                voice: snap.voice,
                customModel: nil,
                customConfig: nil
            )
        }
    }

    /// Fetcher that SUSPENDS until `release()` is called, so a test can call
    /// `cancel()` while the fetch is genuinely in flight, then let it resolve
    /// late and assert nothing resurrects playback. `@MainActor` (the test +
    /// `ReplyVoice` are main-actor; the fetch hop awaits this gate).
    @MainActor
    final class BlockingFetcher: TTSFetching {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var didStart = false

        func synthesize(text: String, provider: TTSProvider, voice: String?, customModel: String?, apiKey: String, customConfig: CustomTTSConfig?) async throws -> Data {
            didStart = true
            // Suspend here. `await withCheckedContinuation` yields control back to
            // the main run loop, so the test's `cancel()` can run while we're
            // "in flight"; `release()` resumes us afterwards.
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                self.continuation = c
            }
            return Data([0xAB, 0xCD])
        }

        /// Let the suspended fetch resume (it then returns bytes).
        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    /// A cloud fetch that HANGS — neither returns nor throws until the (very
    /// long) sleep ends or the task is cancelled. Drives the first-audio
    /// watchdog: the surface must not stay stuck on `.loading` forever.
    @MainActor
    final class StallingFetcher: TTSFetching {
        private(set) var calls = 0
        func synthesize(text: String, provider: TTSProvider, voice: String?, customModel: String?, apiKey: String, customConfig: CustomTTSConfig?) async throws -> Data {
            calls += 1
            try await Task.sleep(for: .seconds(3600))
            return Data()
        }
    }

    // MARK: - Helpers

    /// Drive `speak`/`previewSample` and wait for the async route to settle.
    private func awaitCompletion(
        timeout: TimeInterval = 2,
        _ body: (@escaping @MainActor @Sendable () -> Void) -> Void
    ) -> Int {
        let exp = expectation(description: "completion")
        let counter = CounterBox()
        body { counter.bump(); exp.fulfill() }
        wait(for: [exp], timeout: timeout)
        // Give any stray late callbacks a runloop turn to (incorrectly) fire.
        let spin = expectation(description: "spin")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { spin.fulfill() }
        wait(for: [spin], timeout: 1)
        return counter.count
    }

    final class CounterBox { var count = 0; func bump() { count += 1 } }

    /// Box capturing a `previewSample` outcome across the async route. `@MainActor`
    /// (the latch + route fire on the main actor).
    @MainActor
    final class OutcomeBox {
        private(set) var count = 0
        private(set) var last: Result<Void, AppError>?
        func record(_ r: Result<Void, AppError>) { count += 1; last = r }
        var didSucceed: Bool { if case .success = last { return true }; return false }
        var didFail: Bool { if case .failure = last { return true }; return false }
    }

    /// Drive `previewSample` (Result completion) and wait for the async route to
    /// settle. Returns the recorded outcome box (count + last result). Mirrors
    /// `awaitCompletion`, but the payload is the preview `Result`.
    private func awaitOutcome(
        timeout: TimeInterval = 2,
        _ body: (@escaping @MainActor @Sendable (Result<Void, AppError>) -> Void) -> Void
    ) -> OutcomeBox {
        let exp = expectation(description: "outcome")
        let box = OutcomeBox()
        body { result in box.record(result); exp.fulfill() }
        wait(for: [exp], timeout: timeout)
        // Give any stray late callbacks a runloop turn to (incorrectly) fire.
        let spin = expectation(description: "spin")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { spin.fulfill() }
        wait(for: [spin], timeout: 1)
        return box
    }

    // MARK: - Cloud success → cloud path + fires once

    func testCloudSuccessPlaysCloudAndFiresOnce() {
        let player = FakePlayer()
        let fetcher = FakeFetcher(bytes: Data([0x01, 0x02]))
        let snapshot = FakeSnapshot(snap: ("openai-tts", "key-123", nil))
        let rv = ReplyVoice(fetcher: fetcher, player: player, snapshot: snapshot, outcomeLog: makeThrowawayOutcomeLog())

        let fires = awaitCompletion { done in
            rv.speak("Hello there.", sanitize: false, completion: done)
        }

        XCTAssertEqual(fires, 1, "Completion must fire EXACTLY once on the cloud-success path.")
        XCTAssertEqual(player.cloudCount, 1, "Cloud audio must be played.")
        XCTAssertEqual(player.appleCount, 0, "Apple must NOT be used when cloud succeeds.")
    }

    // MARK: - Cloud failure → Apple fallback + fires once

    func testCloudFailureFallsBackToAppleAndFiresOnce() {
        let player = FakePlayer()
        let fetcher = FakeFetcher(error: .ttsProviderUnreachable)
        let snapshot = FakeSnapshot(snap: ("openai-tts", "key-123", nil))
        let rv = ReplyVoice(fetcher: fetcher, player: player, snapshot: snapshot, outcomeLog: makeThrowawayOutcomeLog())

        let fires = awaitCompletion { done in
            rv.speak("Hello there.", sanitize: false, completion: done)
        }

        XCTAssertEqual(fires, 1, "Completion must fire EXACTLY once on the cloud-fail→Apple path.")
        XCTAssertEqual(player.cloudCount, 0, "Cloud must NOT play when the fetch threw.")
        XCTAssertEqual(player.appleCount, 1, "Apple fallback must run when the cloud fetch throws.")
    }

    // MARK: - Apple-active / no key → Apple path, no cloud fetch

    func testAppleActiveUsesAppleNoCloudFetch() {
        let player = FakePlayer()
        let fetcher = FakeFetcher()
        let snapshot = FakeSnapshot(snap: ("apple-tts", nil, nil))
        let rv = ReplyVoice(fetcher: fetcher, player: player, snapshot: snapshot, outcomeLog: makeThrowawayOutcomeLog())

        let fires = awaitCompletion { done in
            rv.speak("Read this.", sanitize: false, completion: done)
        }

        XCTAssertEqual(fires, 1)
        XCTAssertEqual(player.appleCount, 1, "Apple-active must play via Apple.")
        XCTAssertEqual(player.cloudCount, 0)
    }

    func testCloudProviderWithNoKeyFallsToApple() {
        let player = FakePlayer()
        let snapshot = FakeSnapshot(snap: ("openai-tts", nil, nil))  // configured active but key cleared
        let rv = ReplyVoice(fetcher: FakeFetcher(), player: player, snapshot: snapshot, outcomeLog: makeThrowawayOutcomeLog())

        let fires = awaitCompletion { done in
            rv.speak("No key here.", sanitize: false, completion: done)
        }

        XCTAssertEqual(fires, 1)
        XCTAssertEqual(player.appleCount, 1, "A cloud provider with no key must fall back to Apple.")
        XCTAssertEqual(player.cloudCount, 0)
    }

    // MARK: - Empty text after sanitize → no cloud call, fires once

    func testEmptyAfterSanitizeFiresOnceNoCloud() {
        let player = FakePlayer()
        let snapshot = FakeSnapshot(snap: ("openai-tts", "key-123", nil))
        let rv = ReplyVoice(fetcher: FakeFetcher(), player: player, snapshot: snapshot, outcomeLog: makeThrowawayOutcomeLog())

        // An all-emoji reply sanitizes to empty.
        let fires = awaitCompletion { done in
            rv.speak("🎉🎈✨", sanitize: true, completion: done)
        }

        XCTAssertEqual(fires, 1, "Empty-after-sanitize must still fire the completion exactly once.")
        XCTAssertEqual(player.cloudCount, 0, "Empty text must make NO cloud call.")
        XCTAssertEqual(player.appleCount, 0, "Empty text must make NO Apple call either.")
    }

    // MARK: - Pathological all-fail leaf → still fires exactly once

    func testPathologicalAllFailStillFiresOnce() {
        let player = FakePlayer()
        player.invokeDone = false  // player NEVER calls back on either path
        let fetcher = FakeFetcher(error: .ttsSynthesisFailed)
        let snapshot = FakeSnapshot(snap: ("openai-tts", "key-123", nil))
        let rv = ReplyVoice(fetcher: fetcher, player: player, snapshot: snapshot, outcomeLog: makeThrowawayOutcomeLog())

        // The fetch throws → Apple fallback invoked → but the fake player never
        // calls onDone. The one-shot latch guarantees no double-fire; here we
        // assert the Apple fallback at least RAN (the contract handed off to a
        // player path; a real SpeechPlayer's funnel would then fire).
        let exp = expectation(description: "settle")
        var fires = 0
        rv.speak("Hello.", sanitize: false) { fires += 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1)

        XCTAssertEqual(player.appleCount, 1, "Cloud-fail must hand off to the Apple player even if it never calls back.")
        XCTAssertLessThanOrEqual(fires, 1, "The one-shot latch must never let the completion fire more than once.")
    }

    // MARK: - previewSample (explicit provider) → reports outcome exactly once

    func testPreviewSampleCloudSuccessReportsSuccessOnce() {
        let player = FakePlayer()
        let fetcher = FakeFetcher(bytes: Data([0x09]))
        // Snapshot is irrelevant for preview — it uses the explicit args.
        let snapshot = FakeSnapshot(snap: ("apple-tts", nil, nil))
        let rv = ReplyVoice(fetcher: fetcher, player: player, snapshot: snapshot, outcomeLog: makeThrowawayOutcomeLog())

        let outcome = awaitOutcome { done in
            rv.previewSample(providerID: "elevenlabs-tts", voice: "Aria", apiKey: "k", completion: done)
        }

        XCTAssertEqual(outcome.count, 1, "previewSample must report the outcome EXACTLY once.")
        XCTAssertTrue(outcome.didSucceed, "A cloud-success preview must report `.success`.")
        XCTAssertEqual(player.cloudCount, 1, "previewSample with a key must play cloud audio.")
        XCTAssertEqual(player.appleCount, 0)
    }

    func testPreviewSampleNoKeyUsesAppleAndReportsSuccess() {
        let player = FakePlayer()
        let log = makeThrowawayOutcomeLog()
        let rv = ReplyVoice(
            fetcher: FakeFetcher(bytes: Data([0x09])),
            player: player, snapshot: FakeSnapshot(snap: ("apple-tts", nil, nil)),
            outcomeLog: log
        )

        let outcome = awaitOutcome { done in
            rv.previewSample(providerID: "apple-tts", voice: nil, apiKey: nil, completion: done)
        }

        XCTAssertEqual(outcome.count, 1)
        XCTAssertTrue(outcome.didSucceed, "A keyless Apple preview is a legit `.success` (this provider uses Apple).")
        XCTAssertEqual(player.appleCount, 1, "previewSample of Apple (no key) must play via Apple.")
        XCTAssertEqual(player.cloudCount, 0)
        // Ring honesty: an intended-Apple preview records `appleOK`, NEVER the
        // `appleFallback` a cloud substitution would (preview never substitutes).
        XCTAssertEqual(log.events().map(\.outcome), [.appleOK],
                       "An Apple-sentinel preview records appleOK, never appleFallback.")
    }

    // MARK: - previewSample fail-loud: cloud throw → `.failure`, NO Apple fallback

    func testPreviewSampleCloudFailureReportsFailureAndDoesNotPlayApple() {
        // The whole bug being fixed: auditioning a cloud voice that silently
        // becomes Apple. The preview path must fail LOUD — report `.failure` and
        // play NOTHING (no Apple fallback, unlike the chat `speak` path below).
        let player = FakePlayer()
        let fetcher = FakeFetcher(error: .ttsSynthesisFailed)
        let snapshot = FakeSnapshot(snap: ("apple-tts", nil, nil))  // irrelevant for preview
        let rv = ReplyVoice(fetcher: fetcher, player: player, snapshot: snapshot, outcomeLog: makeThrowawayOutcomeLog())

        let outcome = awaitOutcome { done in
            rv.previewSample(providerID: "mistral-tts", voice: "not_a_voice", apiKey: "k", completion: done)
        }

        XCTAssertEqual(outcome.count, 1, "previewSample must report the failure EXACTLY once.")
        XCTAssertTrue(outcome.didFail, "A cloud-synth throw in preview must report `.failure`.")
        XCTAssertEqual(player.cloudCount, 0, "A failed cloud synth must NOT play cloud audio.")
        XCTAssertEqual(player.appleCount, 0,
                       "Preview must NOT silently fall back to Apple on a cloud failure (the bug).")
    }

    // MARK: - cancel() aborts the in-flight fetch (teardown-safety)

    func testCancelDuringFetchAbortsPlaybackAndNeverFires() async {
        let player = FakePlayer()
        let fetcher = BlockingFetcher()
        let rv = ReplyVoice(
            fetcher: fetcher, player: player,
            snapshot: FakeSnapshot(snap: ("openai-tts", "key-123", nil)),
            outcomeLog: makeThrowawayOutcomeLog()
        )

        var fires = 0
        rv.speak("Hello there.", sanitize: false) { fires += 1 }

        // Let the cloud Task reach the suspended fetch (snapshot resolves + the
        // fetch awaits the gate). Yield until the fetcher actually started.
        for _ in 0..<100 where !fetcher.didStart { await Task.yield() }
        XCTAssertTrue(fetcher.didStart, "Fetch should be in flight before cancel.")

        // Caller tears down the turn (e.g. CarPlay End / scene resign).
        rv.cancel()
        XCTAssertGreaterThanOrEqual(player.stopCount, 1, "cancel() must stop the player.")

        // Now let the late fetch resolve — it must see Task.isCancelled and bail.
        fetcher.release()
        // Drain the runloop so any (incorrect) post-cancel player call would land.
        for _ in 0..<10 { await Task.yield() }
        let drain = expectation(description: "drain")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { drain.fulfill() }
        await fulfillment(of: [drain], timeout: 1)

        XCTAssertEqual(player.cloudCount, 0, "A cancelled fetch must NOT start cloud playback.")
        XCTAssertEqual(player.appleCount, 0, "A cancelled fetch must NOT fall back to Apple playback.")
        XCTAssertEqual(fires, 0, "cancel() abandons the turn — the completion must NOT fire.")
    }

    // MARK: - onStateChange (P3, additive) fires BEFORE completion

    /// Box recording the ORDER of the additive progress signal vs the terminal
    /// completion. `@MainActor` — both land on the main actor.
    @MainActor
    final class OrderBox {
        private(set) var events: [String] = []
        func record(_ e: String) { events.append(e) }
    }

    func testOnStateChangeFiresBeforeCompletionOnCloudSuccess() {
        let player = FakePlayer()  // invokeStart + invokeDone both true → start, then done
        let fetcher = FakeFetcher(bytes: Data([0x01, 0x02]))
        let snapshot = FakeSnapshot(snap: ("openai-tts", "key-123", nil))
        let rv = ReplyVoice(fetcher: fetcher, player: player, snapshot: snapshot, outcomeLog: makeThrowawayOutcomeLog())

        let order = OrderBox()
        let exp = expectation(description: "completion")
        rv.speak(
            "Hello there.",
            sanitize: false,
            onStateChange: { activity in
                if case .startedPlaying = activity { order.record("startedPlaying") }
            },
            completion: { order.record("completion"); exp.fulfill() }
        )
        wait(for: [exp], timeout: 2)

        XCTAssertEqual(order.events, ["startedPlaying", "completion"],
                       "On cloud success, onStateChange(.startedPlaying) must fire BEFORE completion.")
        XCTAssertEqual(player.cloudCount, 1)
    }

    func testOnStateChangeFiresBeforeCompletionOnAppleFallback() {
        let player = FakePlayer()
        let fetcher = FakeFetcher(error: .ttsProviderUnreachable)  // cloud throws → Apple fallback
        let snapshot = FakeSnapshot(snap: ("openai-tts", "key-123", nil))
        let rv = ReplyVoice(fetcher: fetcher, player: player, snapshot: snapshot, outcomeLog: makeThrowawayOutcomeLog())

        let order = OrderBox()
        let exp = expectation(description: "completion")
        rv.speak(
            "Hello there.",
            sanitize: false,
            onStateChange: { activity in
                if case .startedPlaying = activity { order.record("startedPlaying") }
            },
            completion: { order.record("completion"); exp.fulfill() }
        )
        wait(for: [exp], timeout: 2)

        XCTAssertEqual(order.events, ["startedPlaying", "completion"],
                       "On the Apple-fallback path, onStateChange(.startedPlaying) must STILL fire before completion.")
        XCTAssertEqual(player.cloudCount, 0)
        XCTAssertEqual(player.appleCount, 1, "Cloud failure must hand off to the Apple player.")
    }

    // MARK: - cancel() suppresses BOTH onStateChange and completion

    func testCancelDuringFetchSuppressesBothOnStateChangeAndCompletion() async {
        let player = FakePlayer()
        let fetcher = BlockingFetcher()
        let rv = ReplyVoice(
            fetcher: fetcher, player: player,
            snapshot: FakeSnapshot(snap: ("openai-tts", "key-123", nil)),
            outcomeLog: makeThrowawayOutcomeLog()
        )

        var stateChanges = 0
        var completions = 0
        rv.speak(
            "Hello there.",
            sanitize: false,
            onStateChange: { _ in stateChanges += 1 },
            completion: { completions += 1 }
        )

        // Let the cloud Task reach the suspended fetch before cancelling.
        for _ in 0..<100 where !fetcher.didStart { await Task.yield() }
        XCTAssertTrue(fetcher.didStart, "Fetch should be in flight before cancel.")

        rv.cancel()

        // Let the late fetch resolve — it must see Task.isCancelled and bail
        // before touching the player (so neither onStart nor onDone can fire).
        fetcher.release()
        for _ in 0..<10 { await Task.yield() }
        let drain = expectation(description: "drain")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { drain.fulfill() }
        await fulfillment(of: [drain], timeout: 1)

        XCTAssertEqual(stateChanges, 0,
                       "cancel() during an in-flight fetch must suppress onStateChange (playback never began).")
        XCTAssertEqual(completions, 0,
                       "cancel() during an in-flight fetch must suppress completion (the turn is abandoned).")
        XCTAssertEqual(player.cloudCount, 0)
        XCTAssertEqual(player.appleCount, 0)
    }

    // MARK: - B1. Cloud PLAYBACK failure (not fetch) → Apple speaks the WHOLE text

    /// A fetched-but-unplayable clip (undecodable bytes / refused start / mid-clip
    /// death) must fall back to the Apple leg speaking the WHOLE reply, fire the
    /// completion exactly once, and emit `.fallbackStarted` when the Apple leg's
    /// audio actually begins. The old bare-completion contract swallowed these
    /// silently — this is the typed-outcome fix.
    func testCloudPlaybackFailureFallsBackToAppleWithWholeText() {
        for stage in [CloudPlaybackFailureStage.undecodable, .startRefused, .playbackFailed] {
            let player = FakePlayer()
            player.cloudOutcome = .failed(stage)
            let snapshot = FakeSnapshot(snap: ("openai-tts", "key-123", nil))
            let rv = ReplyVoice(fetcher: FakeFetcher(), player: player, snapshot: snapshot,
                                outcomeLog: makeThrowawayOutcomeLog())

            let exp = expectation(description: "completion")
            var fires = 0
            var fallbackStarted = 0
            rv.speak(
                "Hello whole reply.",
                sanitize: false,
                onStateChange: { if case .fallbackStarted = $0 { fallbackStarted += 1 } },
                completion: { fires += 1; exp.fulfill() }
            )
            wait(for: [exp], timeout: 2)

            XCTAssertEqual(fires, 1, "stage \(stage): completion fires EXACTLY once on cloud-playback-fail→Apple.")
            XCTAssertEqual(player.cloudCount, 1, "stage \(stage): the cloud clip was attempted.")
            XCTAssertEqual(player.appleTexts, ["Hello whole reply."],
                           "stage \(stage): Apple speaks the WHOLE reply (content preservation).")
            XCTAssertEqual(fallbackStarted, 1,
                           "stage \(stage): .fallbackStarted fires when the Apple leg's onStart fires.")
        }
    }

    // MARK: - B2. Preview: fetched-but-unplayable → loud .failure, NO Apple

    /// The false-green fix: a cloud clip that fetched but won't play must report
    /// `.failure(.ttsSynthesisFailed)` in preview and play NOTHING — no Apple
    /// substitution (unlike chat). (A fetch throw already reports `.failure`, and
    /// the Apple-sentinel preview reports `.success`, both covered above.)
    func testPreviewSampleFetchedButUnplayableReportsSynthesisFailureNoApple() {
        let player = FakePlayer()
        player.cloudOutcome = .failed(.undecodable)  // fetched, but the bytes won't play
        let rv = ReplyVoice(
            fetcher: FakeFetcher(bytes: Data([0x09])),
            player: player, snapshot: FakeSnapshot(snap: ("apple-tts", nil, nil)),
            outcomeLog: makeThrowawayOutcomeLog()
        )

        let outcome = awaitOutcome { done in
            rv.previewSample(providerID: "elevenlabs-tts", voice: "Aria", apiKey: "k", completion: done)
        }

        XCTAssertEqual(outcome.count, 1, "previewSample reports the outcome exactly once.")
        XCTAssertTrue(outcome.didFail, "Fetched-but-unplayable audio must fail LOUD in preview.")
        if case .failure(let err)? = outcome.last {
            XCTAssertEqual(err.errorCode, AppError.ttsSynthesisFailed.errorCode,
                           "The surfaced error is the synthesis-failed bucket.")
        }
        XCTAssertEqual(player.cloudCount, 1, "The preview attempted to play the fetched clip.")
        XCTAssertEqual(player.appleCount, 0, "Preview must NOT fall back to Apple on an unplayable clip.")
    }

    // MARK: - B3. Missing / unreadable key chat turn → Apple fallback + honest ring

    /// A cloud provider whose key is missing (or unreadable) on THIS device must
    /// fall back to Apple, emit `.fallbackStarted`, and record ONE ring event with
    /// outcome `appleFallback`, stage `key`, and the HONEST key state — the
    /// distinction the old nil-collapse couldn't make.
    func testMissingAndUnreadableKeyChatFallBackToAppleWithKeyStageRing() {
        for (override, expectedKeyState) in [(APIKeyState.missing, "missing"),
                                             (APIKeyState.unreadable, "unreadable")] {
            let log = makeThrowawayOutcomeLog()
            let player = FakePlayer()
            let snapshot = FakeSnapshot(snap: ("openai-tts", nil, nil), keyStateOverride: override)
            let rv = ReplyVoice(fetcher: FakeFetcher(), player: player, snapshot: snapshot, outcomeLog: log)

            let exp = expectation(description: "completion")
            var fires = 0
            var fallbackStarted = 0
            rv.speak(
                "Speak me.",
                sanitize: false,
                onStateChange: { if case .fallbackStarted = $0 { fallbackStarted += 1 } },
                completion: { fires += 1; exp.fulfill() }
            )
            wait(for: [exp], timeout: 2)

            XCTAssertEqual(fires, 1, "\(expectedKeyState): completion fires once via the Apple leg.")
            XCTAssertEqual(player.appleCount, 1, "\(expectedKeyState): an unusable key falls back to Apple.")
            XCTAssertEqual(player.cloudCount, 0, "\(expectedKeyState): no cloud clip is attempted.")
            XCTAssertEqual(fallbackStarted, 1, "\(expectedKeyState): .fallbackStarted fires on the Apple leg.")

            let events = log.events()
            XCTAssertEqual(events.count, 1, "\(expectedKeyState): exactly one ring event is recorded.")
            XCTAssertEqual(events.last?.outcome, .appleFallback, "\(expectedKeyState): outcome is appleFallback.")
            XCTAssertEqual(events.last?.stage, .key, "\(expectedKeyState): the stage is `key`.")
            XCTAssertEqual(events.last?.keyState, expectedKeyState,
                           "\(expectedKeyState): the ring records the HONEST key state.")
        }
    }

    // MARK: - B4. A fallback whose Apple leg never starts → gaveUp (ring honesty)

    /// If the fallback Apple leg produces NO audio at all (no onStart, no onDone),
    /// the inactivity watchdog must still settle the turn exactly once, and the
    /// ring must record `gaveUp` — NOT `appleFallback` (which claims audio that
    /// never happened).
    func testFallbackAppleLegThatNeverStartsSettlesAsGaveUp() {
        let log = makeThrowawayOutcomeLog()
        let player = FakePlayer()
        player.invokeStart = false
        player.invokeDone = false   // the Apple leg produces NOTHING
        let snapshot = FakeSnapshot(snap: ("openai-tts", "key-123", nil))
        let rv = ReplyVoice(
            fetcher: FakeFetcher(error: .ttsProviderUnreachable),  // fetch throw → fallback leg
            player: player, snapshot: snapshot, outcomeLog: log,
            appleInactivityTimeout: .milliseconds(50)
        )

        let fires = awaitCompletion { done in rv.speak("Silent leg.", sanitize: false, completion: done) }

        XCTAssertEqual(fires, 1, "The inactivity watchdog settles the turn once even when Apple is dead.")
        XCTAssertEqual(player.appleCount, 1, "The Apple leg was attempted.")
        let events = log.events()
        XCTAssertEqual(events.map(\.outcome), [.gaveUp],
                       "A fallback whose Apple leg never started records gaveUp, never appleFallback.")
        XCTAssertEqual(events.last?.stage, .apple, "The gaveUp settlement records the `apple` stage.")
    }

    // MARK: - B5. First-audio watchdog: no double-handoff race + expiry path

    /// A fetch THROW disarms the first-audio watchdog by entering the single Apple
    /// leg — even with a tiny first-audio deadline, exactly ONE Apple leg runs and
    /// the completion fires once (the two watchdogs never both fire).
    func testFetchThrowEntersSingleAppleLegDespiteTinyFirstAudioTimeout() {
        let player = FakePlayer()
        let snapshot = FakeSnapshot(snap: ("openai-tts", "key-123", nil))
        let rv = ReplyVoice(
            fetcher: FakeFetcher(error: .ttsProviderUnreachable),
            player: player, snapshot: snapshot, outcomeLog: makeThrowawayOutcomeLog(),
            firstAudioTimeout: .milliseconds(50)
        )

        let fires = awaitCompletion { done in rv.speak("Reply.", sanitize: false, completion: done) }

        XCTAssertEqual(fires, 1, "Exactly one settlement — the fetch-throw Apple leg disarms the first-audio watchdog.")
        XCTAssertEqual(player.appleCount, 1, "Exactly ONE Apple leg runs (no watchdog double-handoff).")
    }

    /// The watchdog EXPIRY path itself: a cloud fetch that HANGS must, after the
    /// first-audio deadline, hand the WHOLE reply to a single Apple leg and settle
    /// the completion exactly once.
    func testFirstAudioWatchdogExpiryHandsWholeReplyToApple() {
        let player = FakePlayer()
        let snapshot = FakeSnapshot(snap: ("openai-tts", "key-123", nil))
        let rv = ReplyVoice(
            fetcher: StallingFetcher(),
            player: player, snapshot: snapshot, outcomeLog: makeThrowawayOutcomeLog(),
            firstAudioTimeout: .milliseconds(50)
        )

        let fires = awaitCompletion { done in rv.speak("Whole reply here.", sanitize: false, completion: done) }

        XCTAssertEqual(fires, 1, "The first-audio watchdog settles a stalled cloud turn exactly once.")
        XCTAssertEqual(player.appleCount, 1, "The watchdog hands the reply to a single Apple leg.")
        XCTAssertEqual(player.appleTexts, ["Whole reply here."], "Apple speaks the WHOLE reply after the stall.")
        XCTAssertEqual(player.cloudCount, 0, "No cloud audio played — the fetch never returned.")
    }

    // MARK: - B6. Cancel/supersede during the failure→Apple handoff

    /// `cancel()` landing after the cloud failure handed off to Apple, but BEFORE
    /// the Apple leg's own terminal, must suppress the completion entirely — and a
    /// fresh `speak()` on the same engine must then proceed cleanly.
    func testCancelDuringFailureToAppleHandoffSuppressesCompletionThenNextSpeakWorks() async {
        let player = FakePlayer()
        player.cloudOutcome = .failed(.playbackFailed)  // cloud began then died → Apple fallback
        player.appleHoldsCompletion = true              // Apple leg starts but never finishes
        let snapshot = FakeSnapshot(snap: ("openai-tts", "key-123", nil))
        let rv = ReplyVoice(fetcher: FakeFetcher(), player: player, snapshot: snapshot,
                            outcomeLog: makeThrowawayOutcomeLog())

        var fires = 0
        rv.speak("Reply.", sanitize: false) { fires += 1 }

        // Wait until the cloud failure has handed off to the (in-flight) Apple leg.
        for _ in 0..<200 where player.appleCount == 0 { await Task.yield() }
        XCTAssertEqual(player.appleCount, 1, "The cloud failure handed off to the Apple leg.")
        XCTAssertEqual(fires, 0, "No completion yet — the Apple leg is still in flight.")

        rv.cancel()
        for _ in 0..<10 { await Task.yield() }
        let drain = expectation(description: "drain")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { drain.fulfill() }
        await fulfillment(of: [drain], timeout: 1)
        XCTAssertEqual(fires, 0, "cancel() during the failure→Apple handoff must suppress the completion.")

        // A fresh speak proceeds cleanly (cloud success this time).
        player.cloudOutcome = .finished
        player.appleHoldsCompletion = false
        let exp = expectation(description: "second")
        var secondFires = 0
        rv.speak("Second reply.", sanitize: false) { secondFires += 1; exp.fulfill() }
        await fulfillment(of: [exp], timeout: 2)

        XCTAssertEqual(secondFires, 1, "A fresh speak after cancel completes normally.")
        XCTAssertEqual(fires, 0, "The cancelled turn stays silent forever.")
    }
}
#endif
