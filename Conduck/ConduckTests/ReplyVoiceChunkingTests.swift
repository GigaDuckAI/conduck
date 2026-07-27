// SPDX-License-Identifier: Apache-2.0

// Conduck
// ReplyVoiceChunkingTests.swift
//
// Integration tests for ReplyVoice's CHUNKED speak path (SpeechSegmenter →
// SpeechChunkQueue → per-chunk players), driven entirely through the injectable
// seams (fetcher / player / snapshot / chunkPolicy / chunkPlayers) — no
// network, no audio hardware, no SettingsManager actor. Companion to
// ReplyVoiceFallbackTests (the single-blob fallback tree); this file locks the
// invariants the chunk pipeline ADDED:
//   - short replies stay byte-identical on the proven one-POST path;
//   - long replies split loss-free (per-chunk texts joined == the input) and
//     play strictly in creation order;
//   - the turn models ONE utterance (`.startedPlaying` once; completion once,
//     only after the LAST chunk);
//   - the TTS snapshot is frozen per turn across every chunk fetch;
//   - a failed chunk hands EXACTLY the unplayed remainder to Apple;
//   - cancel / supersede fire nothing and stop every live chunk player;
//   - pause/resume route to the ACTIVE chunk player (or, after a fallback
//     handoff, the Apple `SpeechPlaying` seam).
//
// The fakes in ReplyVoiceFallbackTests are NESTED in that class (and its await
// helpers are private), so this file defines its own distinctly-named fakes.
// Per the chunk-player contract, `FakeChunkPlayer` NEVER fires its finish
// callback from inside `play()` — real `AVAudioPlayer` terminals are always
// async; tests drive the test-only `finish()` explicitly. No wall-clock
// (`Date`)-dependent logic anywhere; sleeps below are only bounded executor
// pumps around condition checks.

#if !os(watchOS)
import XCTest
@testable import Conduck

@MainActor
final class ReplyVoiceChunkingTests: XCTestCase {

    // MARK: - Fakes

    /// Recording cloud-fetch fake: appends every synthesize call (text + the
    /// full non-text snapshot params, in call order) so the tests can assert
    /// both the loss-free split AND the frozen-per-turn snapshot. Configurable
    /// per call by chunk TEXT (`failingTexts`) — ReplyVoice's queue-fetch
    /// wrapper discards the chunk index, so text is the reliable per-call key.
    /// `@MainActor` like the fallback tests' `BlockingFetcher` (an isolated
    /// async witness satisfies the nonisolated async requirement).
    @MainActor
    final class RecordingChunkFetcher: TTSFetching {
        struct Call: Equatable {
            let text: String
            let providerID: String
            let voice: String?
            let customModel: String?
            let apiKey: String
        }
        private(set) var calls: [Call] = []
        var bytes = Data([0x01, 0x02])
        /// Chunk texts that THROW instead of returning bytes.
        var failingTexts: Set<String> = []

        func synthesize(text: String, provider: TTSProvider, voice: String?, customModel: String?, apiKey: String, customConfig: CustomTTSConfig?) async throws -> Data {
            calls.append(Call(
                text: text,
                providerID: provider.id,
                voice: voice,
                customModel: customModel,
                apiKey: apiKey
            ))
            if failingTexts.contains(text) { throw AppError.ttsSynthesisFailed }
            return bytes
        }
    }

    /// A cloud fetch that HANGS — neither returns nor throws until the (very
    /// long) sleep ends or the task is cancelled. Models the wedged synth POST
    /// from the CarPlay field freeze; drives the first-audio watchdog test.
    @MainActor
    final class StallingFetcher: TTSFetching {
        private(set) var calls = 0
        func synthesize(text: String, provider: TTSProvider, voice: String?, customModel: String?, apiKey: String, customConfig: CustomTTSConfig?) async throws -> Data {
            calls += 1
            try await Task.sleep(for: .seconds(3600))
            return Data()
        }
    }

    /// Fake for the single-blob `SpeechPlaying` seam. Mirrors the fallback
    /// tests' `FakePlayer` (fires `onStart` then `onDone` synchronously — that
    /// seam's contract, unlike the chunk players'), but RECORDS the Apple
    /// texts so the exact-remainder fallback assertions are possible.
    final class ChunkSpeechPlayerFake: SpeechPlaying {
        private(set) var cloudCount = 0
        private(set) var appleTexts: [String] = []
        private(set) var stopCount = 0
        private(set) var pauseCount = 0
        private(set) var resumeCount = 0
        /// When false, the fake never calls `onDone` — models playback still
        /// in flight (needed to pause a post-fallback Apple leg mid-play).
        var invokeDone = true
        var invokeStart = true
        /// Typed cloud terminal (default: a clean finish) for the single-blob path.
        var cloudOutcome: CloudPlaybackOutcome = .finished

        func playCloud(
            _ data: Data,
            onStart: (@MainActor @Sendable () -> Void)?,
            onDone: @escaping @MainActor @Sendable (CloudPlaybackOutcome) -> Void
        ) {
            cloudCount += 1
            if invokeStart { onStart?() }
            if invokeDone { onDone(cloudOutcome) }
        }
        func playApple(
            _ text: String,
            onStart: (@MainActor @Sendable () -> Void)?,
            onDone: @escaping @MainActor @Sendable () -> Void
        ) {
            appleTexts.append(text)
            if invokeStart { onStart?() }
            if invokeDone { onDone() }
        }
        func stop() { stopCount += 1 }
        func pause() { pauseCount += 1 }
        func resume() { resumeCount += 1 }
    }

    /// Snapshot fake — a CLOUD provider with a non-empty key so `route()`
    /// takes the cloud path, plus a voice + customModel so the frozen-snapshot
    /// assertions have non-nil material to compare.
    struct ChunkSnapshotFake: TTSSnapshotResolving {
        let providerID: String
        let apiKey: String?
        let voice: String?
        let customModel: String?
        func activeTTSSnapshot() async -> TTSSnapshot {
            // A non-empty key → `.present`; else `.missing` (mirrors production).
            let keyState: APIKeyState = (apiKey?.isEmpty == false) ? .present : .missing
            return TTSSnapshot(
                providerID: providerID,
                apiKey: keyState == .present ? apiKey : nil,
                keyState: keyState,
                voice: voice,
                customModel: customModel,
                customConfig: nil
            )
        }
    }

    /// Per-chunk player fake. NEVER fires its terminal from inside `play()` —
    /// the real `AVChunkPlayer` terminal (`audioPlayerDidFinishPlaying`) is
    /// always an async delegate callback; the test drives `finish()` instead.
    /// Records pause/resume/stop so routing + teardown are assertable.
    @MainActor
    final class FakeChunkPlayer: ChunkPlaying {
        private let recordPlay: @MainActor () -> Void
        private var onFinish: (@MainActor @Sendable (Bool) -> Void)?
        private(set) var prepareCount = 0
        private(set) var playCount = 0
        private(set) var pauseCount = 0
        private(set) var resumeCount = 0
        private(set) var stopCount = 0

        init(recordPlay: @escaping @MainActor () -> Void) {
            self.recordPlay = recordPlay
        }

        func prepare() { prepareCount += 1 }

        func play(onFinish: @escaping @MainActor @Sendable (Bool) -> Void) -> Bool {
            playCount += 1
            self.onFinish = onFinish
            recordPlay()
            return true
        }

        func pause() { pauseCount += 1 }
        func resume() { resumeCount += 1 }
        /// Hard stop releases the terminal WITHOUT firing it (contract).
        func stop() {
            onFinish = nil
            stopCount += 1
        }
        var status: PlaybackStatus { .active }

        /// TEST-DRIVEN terminal — the stand-in for the clip's audio ending.
        /// `success == false` models a mid-clip death (→ chunk failure).
        /// Exactly-once (nils the pending callback), like the real funnel.
        func finish(success: Bool = true) {
            let pending = onFinish
            onFinish = nil
            pending?(success)
        }
    }

    /// Chunk-player factory fake: records every created player (creation
    /// order == chunk order for successful fetches) and the cross-player
    /// PLAY order, so strict in-order playback is assertable.
    @MainActor
    final class FakeChunkPlayerFactory: ChunkPlayerProviding {
        private(set) var created: [FakeChunkPlayer] = []
        /// Creation-ids in the order their `play()` was called.
        private(set) var playOrder: [Int] = []

        func makePlayer(data: Data) throws -> ChunkPlaying {
            let id = created.count
            let player = FakeChunkPlayer(recordPlay: { [weak self] in
                self?.playOrder.append(id)
            })
            created.append(player)
            return player
        }
    }

    /// Records the additive `.startedPlaying` signal and the exactly-once
    /// completion, plus their relative ORDER. `@MainActor` — all callbacks
    /// land on the main actor (same shape as the fallback tests' OrderBox).
    @MainActor
    final class TurnRecorder {
        private(set) var startedPlaying = 0
        private(set) var completions = 0
        private(set) var events: [String] = []
        func recordStart() { startedPlaying += 1; events.append("start") }
        func recordDone() { completions += 1; events.append("done") }
    }

    // MARK: - Fixtures

    /// Deterministic per-LINE chunking policy: newline boundaries are
    /// hand-coded in `SpeechSegmenter.atoms` (no NLTokenizer dependence), so
    /// N lines → exactly N chunks. Lets the failure/cancel/pause cases pin
    /// exact chunk texts without depending on sentence-tokenizer behavior.
    private static let perLine = SpeechSegmentationPolicy(
        singleChunkMax: 1, headTarget: 1, tailTarget: 1, maxChunks: 64, minTailChars: 1
    )

    private static let threeLineText =
        "Alpha leads the reply\nBravo follows in the middle\nCharlie closes the turn"
    private static let fourLineText =
        "Alpha leads the reply\nBravo follows in the middle\nCharlie keeps it moving\nDelta closes the turn"
    private static let twoLineText =
        "Echo starts the second turn\nFoxtrot finishes it"

    /// ~1450-char multi-sentence reply. Newline-joined so atom boundaries are
    /// guaranteed by the segmenter's hand-coded line-start splitting (the
    /// `.standard` head/tail packing is still what's under test).
    private static let longReply: String = (1...16)
        .map { "Sentence number \($0) carries plenty of spoken words so the segmenter has real material to pack." }
        .joined(separator: "\n")

    private struct Rig {
        let rv: ReplyVoice
        let fetcher: RecordingChunkFetcher
        let player: ChunkSpeechPlayerFake
        let factory: FakeChunkPlayerFactory
    }

    private func makeRig(policy: SpeechSegmentationPolicy = .standard) -> Rig {
        let fetcher = RecordingChunkFetcher()
        let player = ChunkSpeechPlayerFake()
        let factory = FakeChunkPlayerFactory()
        let rv = ReplyVoice(
            fetcher: fetcher,
            player: player,
            snapshot: ChunkSnapshotFake(
                providerID: "openai-tts",
                apiKey: "key-123",
                voice: "nova",
                customModel: "tts-mini"
            ),
            outcomeLog: makeThrowawayOutcomeLog(),
            chunkPolicy: policy,
            chunkPlayers: factory
        )
        return Rig(rv: rv, fetcher: fetcher, player: player, factory: factory)
    }

    /// Speak with a recorder wired to both the additive progress signal and
    /// the exactly-once completion. `sanitize: false` so the sanitized text
    /// IS the input — the split/remainder assertions stay byte-exact.
    private func speak(_ rig: Rig, _ text: String, into rec: TurnRecorder) {
        rig.rv.speak(
            text,
            sanitize: false,
            onStateChange: { activity in
                if case .startedPlaying = activity { rec.recordStart() }
            },
            completion: { rec.recordDone() }
        )
    }

    // MARK: - Async pumping

    /// Fixed executor drain: `ReplyVoice.speak` hops through an async snapshot
    /// resolve, and `SpeechChunkQueue` runs its fetches in `@MainActor` Tasks
    /// — yields let those queued jobs land; the 1 ms sleeps let the
    /// (nonisolated-async) snapshot fake's off-main hop come home. Used after
    /// triggering work and before NEGATIVE assertions (give stray late
    /// callbacks a chance to incorrectly fire).
    private func drain(_ iterations: Int = 25) async {
        for _ in 0..<iterations {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// Condition-driven drain (bounded, deterministic outcome): pump until
    /// `condition` holds; the assertions that follow report any real mismatch.
    private func drain(until condition: @autoclosure @MainActor () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// Finish chunk players one at a time (whichever played last), pumping
    /// between finishes so lookahead fetches land — the deterministic stand-in
    /// for clips ending — until the turn reaches `done`.
    private func finishChunks(
        _ factory: FakeChunkPlayerFactory,
        until done: @autoclosure @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<24 {
            if done() { return }
            guard let playingID = factory.playOrder.last else {
                XCTFail("No chunk player has played yet — nothing to finish.", file: file, line: line)
                return
            }
            factory.created[playingID].finish()
            await drain(until: done() || factory.playOrder.last != playingID)
        }
        XCTAssertTrue(done(), "Turn never reached its terminal after finishing every chunk.", file: file, line: line)
    }

    // MARK: - 1. Short reply stays single-blob, byte-identical

    /// A reply under `.standard`'s `singleChunkMax` must keep today's proven
    /// one-POST path BYTE-IDENTICAL: exactly one synthesize call carrying the
    /// FULL text, played via the `SpeechPlaying` seam's `playCloud`, with the
    /// chunk factory never touched. Chunking must never make short replies
    /// worse (extra requests / new player machinery).
    func testShortReplyStaysSingleBlobByteIdentical() async {
        let text = "This is a short reply that stays well under the single-chunk ceiling."
        XCTAssertEqual(SpeechSegmenter.segments(for: text, policy: .standard), [text],
                       "Precondition: a short reply must segment to a single chunk.")

        let rig = makeRig()
        let rec = TurnRecorder()
        speak(rig, text, into: rec)
        await drain(until: rec.completions == 1)

        XCTAssertEqual(rig.fetcher.calls.count, 1, "A short reply must make exactly ONE synthesize call.")
        XCTAssertEqual(rig.fetcher.calls.first?.text, text, "The single call must carry the FULL text.")
        XCTAssertEqual(rig.player.cloudCount, 1, "Short replies play through the SpeechPlaying seam's playCloud.")
        XCTAssertTrue(rig.player.appleTexts.isEmpty)
        XCTAssertTrue(rig.factory.created.isEmpty, "The chunk factory must NEVER be touched for a single-chunk reply.")
        XCTAssertEqual(rec.completions, 1)
    }

    // MARK: - 2. Long reply chunks loss-free and plays strictly in order

    /// A long reply must split into >= 2 synthesize calls whose texts joined()
    /// reproduce the input EXACTLY (the segmenter's loss-free contract — the
    /// basis of the Apple-remainder fallback), bypass the single-blob
    /// `playCloud` seam entirely, and play chunk players STRICTLY in creation
    /// order — out-of-order audio would garble the reply.
    func testLongReplyChunksLossFreeAndPlaysInOrder() async {
        let text = Self.longReply
        let segments = SpeechSegmenter.segments(for: text, policy: .standard)
        XCTAssertGreaterThanOrEqual(segments.count, 2, "Precondition: the long reply must chunk.")

        let rig = makeRig()
        let rec = TurnRecorder()
        speak(rig, text, into: rec)

        await drain(until: rig.factory.playOrder.count == 1)
        await finishChunks(rig.factory, until: rec.completions == 1)

        XCTAssertGreaterThanOrEqual(rig.fetcher.calls.count, 2, "A long reply must synthesize in >= 2 calls.")
        XCTAssertEqual(rig.fetcher.calls.map(\.text), segments, "Each chunk must be fetched exactly once, in order.")
        XCTAssertEqual(rig.fetcher.calls.map(\.text).joined(), text,
                       "The per-call texts joined() must equal the input EXACTLY (loss-free split).")
        XCTAssertEqual(rig.player.cloudCount, 0, "The single-blob playCloud seam must NEVER run on a chunked turn.")
        XCTAssertEqual(rig.factory.created.count, segments.count)
        XCTAssertEqual(rig.factory.playOrder, Array(0..<segments.count),
                       "Chunk players must play strictly in creation order.")
        XCTAssertEqual(rec.completions, 1)
    }

    // MARK: - 3. One utterance to the UI: started once, completion after LAST chunk

    /// The queue models ONE utterance: `.startedPlaying` fires exactly once
    /// (first chunk's play), never per-chunk (there is no "chunk 2 of 4" UI
    /// state), and the exactly-once completion fires only after the FINAL
    /// chunk finishes — firing early would tear down the UI / CarPlay session
    /// mid-reply.
    func testStartedPlayingFiresOnceAndCompletionOnlyAfterLastChunk() async {
        let text = Self.threeLineText
        let segments = SpeechSegmenter.segments(for: text, policy: Self.perLine)
        XCTAssertEqual(segments.count, 3, "Precondition: per-line policy must yield 3 chunks.")

        let rig = makeRig(policy: Self.perLine)
        let rec = TurnRecorder()
        speak(rig, text, into: rec)

        await drain(until: rig.factory.playOrder == [0])
        XCTAssertEqual(rec.startedPlaying, 1, ".startedPlaying must fire when the FIRST chunk starts.")
        XCTAssertEqual(rec.completions, 0, "Completion must not fire before the last chunk.")

        rig.factory.created[0].finish()
        await drain(until: rig.factory.playOrder.count == 2)
        XCTAssertEqual(rec.startedPlaying, 1, ".startedPlaying must NOT re-fire on later chunks.")
        XCTAssertEqual(rec.completions, 0)

        rig.factory.created[1].finish()
        await drain(until: rig.factory.playOrder.count == 3)
        XCTAssertEqual(rec.completions, 0, "Completion must still be pending on the final chunk.")

        rig.factory.created[2].finish()
        await drain(until: rec.completions == 1)
        await drain()  // let any stray late callback (incorrectly) double-fire
        XCTAssertEqual(rec.completions, 1, "Completion must fire EXACTLY once, after the LAST chunk.")
        XCTAssertEqual(rec.startedPlaying, 1)
        XCTAssertEqual(rec.events, ["start", "done"], "started must precede the completion; nothing else fires.")
    }

    // MARK: - 4. Snapshot frozen per turn

    /// The TTS snapshot is resolved ONCE at turn start; every chunk fetch must
    /// carry the identical provider/voice/key/model even though the fetches
    /// run over several seconds of playback — Settings changed mid-turn must
    /// never make a reply switch voice halfway through.
    func testSnapshotFrozenAcrossAllChunkFetches() async {
        let text = Self.fourLineText
        let segments = SpeechSegmenter.segments(for: text, policy: Self.perLine)
        XCTAssertEqual(segments.count, 4, "Precondition: per-line policy must yield 4 chunks.")

        let rig = makeRig(policy: Self.perLine)
        let rec = TurnRecorder()
        speak(rig, text, into: rec)
        await drain(until: rig.factory.playOrder.count == 1)
        await finishChunks(rig.factory, until: rec.completions == 1)

        XCTAssertEqual(rig.fetcher.calls.count, segments.count)
        for call in rig.fetcher.calls {
            XCTAssertEqual(call.providerID, "openai-tts", "Every chunk must use the turn-start provider.")
            XCTAssertEqual(call.voice, "nova", "Every chunk must use the turn-start voice.")
            XCTAssertEqual(call.apiKey, "key-123", "Every chunk must use the turn-start key.")
            XCTAssertEqual(call.customModel, "tts-mini", "Every chunk must use the turn-start model override.")
        }
    }

    // MARK: - 5. Mid-turn chunk failure → Apple speaks EXACTLY the unplayed remainder

    /// When chunk 2's synthesis fails on a 3-chunk turn, the already-playing
    /// chunk 1 finishes normally, then Apple speaks segments[1...] joined —
    /// never re-speaking played audio, never going silent mid-reply — and the
    /// completion fires exactly once with NO re-fired `.startedPlaying` (the
    /// UI already shows playing; a second start signal would glitch it).
    func testMidTurnChunkFailureFallsBackWithExactUnplayedRemainder() async {
        let text = Self.threeLineText
        let segments = SpeechSegmenter.segments(for: text, policy: Self.perLine)
        XCTAssertEqual(segments.count, 3, "Precondition: per-line policy must yield 3 chunks.")

        let rig = makeRig(policy: Self.perLine)
        rig.fetcher.failingTexts = [segments[1]]
        let rec = TurnRecorder()
        speak(rig, text, into: rec)

        await drain(until: rig.factory.playOrder == [0])
        await drain()  // let the chunk-2 failure land while chunk 1 still plays
        XCTAssertEqual(rec.startedPlaying, 1, "Chunk 1 started before the failure.")
        XCTAssertTrue(rig.player.appleTexts.isEmpty,
                      "The Apple handoff must WAIT for the playing chunk — never interrupt mid-audio.")
        XCTAssertEqual(rec.completions, 0)

        rig.factory.created[0].finish()
        await drain(until: rec.completions == 1)

        XCTAssertEqual(rig.player.appleTexts, [segments[1...].joined()],
                       "Apple must speak EXACTLY the unplayed remainder (joined tail) — no loss, no double-speak.")
        XCTAssertEqual(rig.player.cloudCount, 0)
        XCTAssertEqual(rec.completions, 1, "Completion must fire exactly once via the Apple leg's funnel.")
        XCTAssertEqual(rec.startedPlaying, 1, ".startedPlaying must NOT re-fire on the fallback handoff.")
    }

    // MARK: - 6. First-chunk failure → Apple speaks the FULL text, start via Apple leg

    /// If the very FIRST chunk's synthesis fails, nothing has played yet, so
    /// Apple must receive the FULL text (segments[0...] joined == input) and
    /// `.startedPlaying` must arrive via the Apple leg's own onStart — the UI
    /// still needs its loading→playing transition even though the cloud path
    /// never produced audio.
    func testFirstChunkFailureFallsBackWithFullTextAndAppleOnStart() async {
        let text = Self.threeLineText
        let segments = SpeechSegmenter.segments(for: text, policy: Self.perLine)
        XCTAssertEqual(segments.count, 3, "Precondition: per-line policy must yield 3 chunks.")

        let rig = makeRig(policy: Self.perLine)
        rig.fetcher.failingTexts = [segments[0]]
        let rec = TurnRecorder()
        speak(rig, text, into: rec)
        await drain(until: rec.completions == 1)

        XCTAssertEqual(rig.player.appleTexts, [text],
                       "A head-chunk failure must hand Apple the FULL text (no chunk ever played).")
        XCTAssertEqual(rig.player.cloudCount, 0)
        XCTAssertTrue(rig.factory.playOrder.isEmpty, "No chunk player may play on a head-chunk failure.")
        XCTAssertEqual(rec.startedPlaying, 1, ".startedPlaying must arrive via the Apple leg's onStart.")
        XCTAssertEqual(rec.events, ["start", "done"], "The Apple leg fires start BEFORE the completion.")
        XCTAssertEqual(rec.completions, 1)
    }

    // MARK: - 7. cancel() mid-chunked-turn: silent teardown, engine stays usable

    /// `cancel()` is a hard stop: the completion must NEVER fire (the caller
    /// is abandoning the turn — firing it would advance CarPlay's loop /
    /// flip UI state), every live chunk player (playing AND prefetched-ready)
    /// must get `stop()`, and the engine must accept a fresh `speak` that
    /// completes normally afterwards.
    func testCancelMidChunkedTurnStopsPlayersFiresNothingAndNextSpeakWorks() async {
        let rig = makeRig(policy: Self.perLine)
        let rec = TurnRecorder()
        speak(rig, Self.threeLineText, into: rec)
        await drain(until: rig.factory.playOrder == [0] && rig.factory.created.count == 3)

        rig.rv.cancel()
        await drain()  // give any (incorrect) post-cancel terminal a chance to fire

        XCTAssertEqual(rec.completions, 0, "cancel() abandons the turn — completion must NEVER fire.")
        for (index, player) in rig.factory.created.enumerated() {
            XCTAssertGreaterThanOrEqual(player.stopCount, 1,
                                        "Chunk player \(index) (playing or prefetched-ready) must be stopped on cancel.")
        }
        XCTAssertGreaterThanOrEqual(rig.player.stopCount, 1, "cancel() must also stop the SpeechPlaying seam.")

        // A subsequent turn must work normally on the same engine.
        let rec2 = TurnRecorder()
        speak(rig, "A short follow-up reply.", into: rec2)
        await drain(until: rec2.completions == 1)
        XCTAssertEqual(rec2.completions, 1, "A speak AFTER cancel must complete normally.")
        XCTAssertEqual(rig.player.cloudCount, 1, "The follow-up single-blob turn plays via playCloud.")
        XCTAssertEqual(rec.completions, 0, "The cancelled turn must stay silent forever.")
    }

    // MARK: - 8. Supersede: a second speak() tears down the live chunk queue

    /// A new `speak` while a chunked turn is mid-play must cancel the first
    /// queue at entry — its players stopped, its completion never fired
    /// (otherwise the old queue keeps fetching + starting chunks UNDER the new
    /// turn's audio) — and the new chunked turn must complete normally.
    func testSupersedingSpeakCancelsChunkedTurnAndNewTurnCompletes() async {
        let rig = makeRig(policy: Self.perLine)
        let seg2 = SpeechSegmenter.segments(for: Self.twoLineText, policy: Self.perLine)
        XCTAssertEqual(seg2.count, 2, "Precondition: the second turn must chunk into 2.")

        let rec1 = TurnRecorder()
        speak(rig, Self.threeLineText, into: rec1)
        await drain(until: rig.factory.playOrder == [0] && rig.factory.created.count == 3)

        let rec2 = TurnRecorder()
        speak(rig, Self.twoLineText, into: rec2)

        // The old queue's teardown is synchronous at speak() entry.
        for (index, player) in rig.factory.created[0..<3].enumerated() {
            XCTAssertGreaterThanOrEqual(player.stopCount, 1,
                                        "Superseded turn's chunk player \(index) must be stopped.")
        }

        await drain(until: rig.factory.playOrder.count == 2)  // new turn's head chunk playing
        await finishChunks(rig.factory, until: rec2.completions == 1)

        XCTAssertEqual(rec1.completions, 0, "The superseded turn's completion must NEVER fire.")
        XCTAssertEqual(rec2.completions, 1, "The new turn must complete normally.")
        XCTAssertEqual(rig.factory.playOrder, [0, 3, 4],
                       "Only the old head chunk played; the new turn's players (3, 4) play in order.")
        XCTAssertEqual(rig.fetcher.calls.suffix(2).map(\.text), seg2,
                       "The new turn's chunks fetch in order after the supersede.")
    }

    // MARK: - 9. .off policy (whole-blob escape hatch): no chunk machinery

    /// Under `.off` even a huge reply must stay ONE synthesize call on the
    /// whole-blob path with zero chunk-factory usage — the escape hatch that
    /// restores pre-chunking behavior must actually bypass the queue.
    func testOffPolicyKeepsWholeBlobSinglePost() async {
        let text = String(repeating: "All work and no play makes the duck a dull duck. ", count: 110)
        XCTAssertGreaterThanOrEqual(text.count, 5000, "Precondition: genuinely huge text.")

        let rig = makeRig(policy: .off)
        let rec = TurnRecorder()
        speak(rig, text, into: rec)
        await drain(until: rec.completions == 1)

        XCTAssertEqual(rig.fetcher.calls.count, 1, ".off must make exactly ONE synthesize call regardless of length.")
        XCTAssertEqual(rig.fetcher.calls.first?.text, text, "The single call carries the whole blob.")
        XCTAssertEqual(rig.player.cloudCount, 1)
        XCTAssertTrue(rig.factory.created.isEmpty, "The chunk factory must never be touched under .off.")
        XCTAssertEqual(rec.completions, 1)
    }

    // MARK: - 9b. First-audio watchdog: a stalled cloud leg can never freeze the turn

    /// A cloud synth that neither returns nor throws (hung connection — the
    /// CarPlay "stuck on Thinking" field freeze) must not strand the surface
    /// on a silent loading state until the transport timeout: after
    /// `firstAudioTimeout` with no audio the watchdog kills the stalled leg
    /// (which fires nothing, like `cancel()`) and Apple speaks the WHOLE
    /// reply, with the start signal and the exactly-once completion flowing
    /// through the normal funnel.
    func testFirstAudioWatchdogHandsStalledCloudTurnToApple() async {
        let fetcher = StallingFetcher()
        let player = ChunkSpeechPlayerFake()
        let factory = FakeChunkPlayerFactory()
        let rv = ReplyVoice(
            fetcher: fetcher,
            player: player,
            snapshot: ChunkSnapshotFake(providerID: "openai-tts", apiKey: "key", voice: nil, customModel: nil),
            outcomeLog: makeThrowawayOutcomeLog(),
            chunkPolicy: .standard,
            chunkPlayers: factory,
            firstAudioTimeout: .milliseconds(50)
        )
        let rec = TurnRecorder()
        rv.speak(
            Self.longReply,
            sanitize: false,
            onStateChange: { if case .startedPlaying = $0 { rec.recordStart() } },
            completion: { rec.recordDone() }
        )
        await drain(until: rec.completions == 1)

        XCTAssertEqual(rec.completions, 1, "the watchdog handoff must settle the turn exactly once")
        XCTAssertEqual(player.appleTexts, [Self.longReply],
                       "Apple must speak the WHOLE un-spoken reply after the stall")
        XCTAssertEqual(rec.startedPlaying, 1, "the Apple leg still emits the start signal")
        XCTAssertGreaterThanOrEqual(fetcher.calls, 1, "construction: the stalled cloud leg was actually attempted")
        XCTAssertTrue(factory.created.allSatisfy { $0.playCount == 0 },
                      "no chunk audio may start after the watchdog handoff")
    }

    // MARK: - 10a. pause()/resume() route to the ACTIVE chunk player

    /// During a chunked turn, pause/resume must land on the chunk player
    /// actually holding the audio (position preserved, no re-synthesis) — NOT
    /// on the single-blob `SpeechPlaying` seam, which owns nothing here.
    func testPauseResumeRouteToActiveChunkPlayer() async {
        let rig = makeRig(policy: Self.perLine)
        let rec = TurnRecorder()
        speak(rig, Self.threeLineText, into: rec)
        await drain(until: rig.factory.playOrder == [0])

        rig.rv.pause()
        XCTAssertEqual(rig.factory.created[0].pauseCount, 1, "pause() must reach the ACTIVE chunk player.")
        XCTAssertEqual(rig.player.pauseCount, 0, "pause() must NOT reach the SpeechPlaying seam mid-chunked-turn.")

        rig.rv.resume()
        XCTAssertEqual(rig.factory.created[0].resumeCount, 1, "resume() must reach the ACTIVE chunk player.")
        XCTAssertEqual(rig.player.resumeCount, 0)
        XCTAssertEqual(rec.completions, 0, "pause/resume are not terminals.")
    }

    // MARK: - 10b. After a fallback handoff, pause() routes to the SpeechPlaying seam

    /// Once a chunk failure hands the remainder to Apple, the chunk queue is
    /// gone — pause/resume must now reach the Apple `SpeechPlaying` seam, not
    /// a dead chunk player; otherwise the user's pause tap would be swallowed
    /// mid-Apple-speech.
    func testPauseAfterFallbackHandoffRoutesToSpeechPlayingSeam() async {
        let text = Self.threeLineText
        let segments = SpeechSegmenter.segments(for: text, policy: Self.perLine)
        XCTAssertEqual(segments.count, 3, "Precondition: per-line policy must yield 3 chunks.")

        let rig = makeRig(policy: Self.perLine)
        rig.fetcher.failingTexts = [segments[1]]
        rig.player.invokeDone = false  // keep the Apple leg "in flight" so pause is meaningful
        let rec = TurnRecorder()
        speak(rig, text, into: rec)

        await drain(until: rig.factory.playOrder == [0])
        rig.factory.created[0].finish()  // playback reaches the failed chunk → Apple handoff
        await drain(until: rig.player.appleTexts.count == 1)
        XCTAssertEqual(rig.player.appleTexts, [segments[1...].joined()])

        rig.rv.pause()
        XCTAssertEqual(rig.player.pauseCount, 1,
                       "After the fallback handoff, pause() must reach the SpeechPlaying seam.")
        XCTAssertEqual(rig.factory.created[0].pauseCount, 0,
                       "The dead chunk queue's players must NOT receive the pause.")

        rig.rv.resume()
        XCTAssertEqual(rig.player.resumeCount, 1,
                       "resume() likewise routes to the SpeechPlaying seam after the handoff.")
        XCTAssertEqual(rig.factory.created[0].resumeCount, 0)
        XCTAssertEqual(rec.completions, 0, "The Apple leg is still in flight — no terminal yet.")
    }
}
#endif
