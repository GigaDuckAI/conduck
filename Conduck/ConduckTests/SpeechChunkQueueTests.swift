// Conduck
// SpeechChunkQueueTests.swift
//
// Behavioral tests for `SpeechChunkQueue` — the ONE chunked-TTS playback
// pipeline shared by every chunk-capable surface (iOS/macOS `ReplyVoice`,
// Watch `WatchReplySpeaker`). Drives the queue purely through its injectable
// seams (a controllable per-chunk fetch closure + a fake `ChunkPlayerProviding`
// factory), so no network, no audio hardware, no audio session is touched.
//
// What this suite locks (the file-header contract of SpeechChunkQueue.swift):
//   - bounded lookahead: at most 2 fetches in flight, never beyond
//     `currentIndex + 2`, never past a failed index;
//   - STRICT in-order playback regardless of fetch ARRIVAL order;
//   - `onFirstAudio` at most once; `onFinished`/`onFallback` mutually
//     exclusive, at most once total; `cancel()` fires nothing at all;
//   - fallback semantics: a failed chunk k never interrupts audio already
//     playing, hands exactly `segments[k...].joined()` to the caller, and is
//     DEFERRED while user-paused (audio must never start under a pause);
//   - queue-wide pause/resume: mid-chunk pauses the player in place; between
//     chunks the queue parks so a landing fetch cannot auto-start audio.
//
// Determinism: fetches suspend on stored continuations the TEST releases in a
// chosen order; fake players NEVER fire their terminal from inside `play()`
// (real `AVAudioPlayer` terminals are always async) — the test calls
// `finish()` by hand. Async seams are drained with a `Task.yield()` loop,
// mirroring `ReplyVoiceFallbackTests`. No clock dependence anywhere. Privacy:
// no reply text, audio bytes, or errors are ever logged; segment strings are
// neutral fixtures.

#if !os(watchOS)
import XCTest
@testable import Conduck

@MainActor
final class SpeechChunkQueueTests: XCTestCase {

    // MARK: - Fakes

    /// Fake per-chunk player. Records every call; `play(onFinish:)` STORES the
    /// terminal and returns a preconfigured Bool — it never fires the terminal
    /// synchronously (a real `AVAudioPlayer` finish/decode-error delegate is
    /// always async). The TEST ends the clip by calling `finish()`.
    final class FakeChunkPlayer: ChunkPlaying {
        /// The audio payload this player was built from — `FetchController`
        /// tags chunk `i`'s data as `Data([UInt8(i)])`, so a player can be
        /// looked up by chunk index even when creation order differs.
        let data: Data
        /// What `play(onFinish:)` returns (false = "session not ready").
        var playReturns = true
        /// Settable playback truth for `playbackStatus` reflection tests.
        var status: PlaybackStatus = .active

        private(set) var prepareCount = 0
        private(set) var playCount = 0
        private(set) var pauseCount = 0
        private(set) var resumeCount = 0
        private(set) var stopCount = 0

        private var onFinish: (@MainActor @Sendable (Bool) -> Void)?

        init(data: Data) { self.data = data }

        func prepare() { prepareCount += 1 }

        func play(onFinish: @escaping @MainActor @Sendable (Bool) -> Void) -> Bool {
            playCount += 1
            guard playReturns else { return false }
            self.onFinish = onFinish
            return true
        }

        func pause() { pauseCount += 1 }
        func resume() { resumeCount += 1 }

        func stop() {
            stopCount += 1
            onFinish = nil  // mirrors AVChunkPlayer: a stopped clip never fires
        }

        /// TEST-DRIVEN terminal — simulates the clip ending. `success == false`
        /// models a mid-clip death (`didFinish(successfully: false)` / decode
        /// error) → the queue treats it as a chunk failure. Exactly-once per
        /// clip (the stored closure is nil-then-called), mirroring
        /// `AVChunkPlayer.fireFinish`.
        func finish(success: Bool = true) {
            let pending = onFinish
            onFinish = nil
            pending?(success)
        }
    }

    /// Fake factory: vends one `FakeChunkPlayer` per `makePlayer` call (kept in
    /// creation order), configurable to THROW (undecodable audio) or to preset
    /// `playReturns == false` for specific CALL indices.
    final class FakeChunkPlayerFactory: ChunkPlayerProviding {
        struct MakeFailed: Error {}

        private(set) var players: [FakeChunkPlayer] = []
        private(set) var makeCalls = 0
        /// Call indices (0-based, counting every `makePlayer` call) that throw.
        var throwOnCallIndices: Set<Int> = []
        /// Call indices whose vended player will refuse to start playback.
        var playReturnsFalseOnCallIndices: Set<Int> = []

        func makePlayer(data: Data) throws -> ChunkPlaying {
            let call = makeCalls
            makeCalls += 1
            if throwOnCallIndices.contains(call) { throw MakeFailed() }
            let player = FakeChunkPlayer(data: data)
            player.playReturns = !playReturnsFalseOnCallIndices.contains(call)
            players.append(player)
            return player
        }

        /// The player built for chunk `index` (via the data tag), independent
        /// of creation order — load-bearing for the out-of-order-arrival test.
        func player(forChunk index: Int) -> FakeChunkPlayer? {
            players.first { $0.data == Data([UInt8(index)]) }
        }
    }

    /// Controllable per-chunk fetch: each index either returns tagged Data
    /// immediately, throws immediately, or SUSPENDS on a stored continuation
    /// until the test releases it (with a success or failure outcome). Tracks
    /// the concurrent-in-flight count + its high-water mark — the probe for
    /// the lookahead cap.
    @MainActor
    final class FetchController {
        enum Mode { case succeed, fail, suspend }
        enum ReleaseOutcome { case success, failure }
        struct FetchFailed: Error {}

        /// Per-chunk behavior; unlisted indices succeed immediately.
        var modes: [Int: Mode] = [:]
        /// Chunk indices whose fetch BODY has actually begun executing, in
        /// execution order (a created-but-unrun Task does not appear).
        private(set) var begun: [Int] = []
        private(set) var inFlight = 0
        private(set) var highWaterMark = 0

        private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
        private var releaseOutcomes: [Int: ReleaseOutcome] = [:]

        func fetch(index: Int) async throws -> Data {
            begun.append(index)
            inFlight += 1
            highWaterMark = max(highWaterMark, inFlight)
            defer { inFlight -= 1 }
            switch modes[index] ?? .succeed {
            case .succeed:
                return Data([UInt8(index)])
            case .fail:
                throw FetchFailed()
            case .suspend:
                await withCheckedContinuation { continuations[index] = $0 }
                if releaseOutcomes[index] == .failure { throw FetchFailed() }
                return Data([UInt8(index)])
            }
        }

        /// Let chunk `index`'s suspended fetch resolve with `outcome`. Fails
        /// the test loudly (instead of deadlocking) if that fetch never
        /// reached its suspension point.
        func release(_ index: Int, as outcome: ReleaseOutcome = .success,
                     file: StaticString = #filePath, line: UInt = #line) {
            releaseOutcomes[index] = outcome
            guard let continuation = continuations.removeValue(forKey: index) else {
                XCTFail("No suspended fetch for chunk \(index) to release.", file: file, line: line)
                return
            }
            continuation.resume()
        }

        /// Hygiene: resume every still-suspended fetch so no
        /// `CheckedContinuation` leaks past the test. Post-terminal these are
        /// inert — the queue's `Task.isCancelled`/`terminated` guards drop them.
        func releaseAllRemaining() {
            for (index, continuation) in continuations {
                releaseOutcomes[index] = .success
                continuation.resume()
            }
            continuations.removeAll()
        }
    }

    /// Counts the queue's three callbacks + captures the last fallback payload,
    /// so every test can assert the exactly-once / mutual-exclusion terms.
    @MainActor
    final class TerminalRecorder {
        private(set) var firstAudioCount = 0
        private(set) var finishedCount = 0
        private(set) var fallbackCount = 0
        private(set) var lastFallbackRemaining: String?
        private(set) var lastFallbackFirstAudioFired: Bool?

        func recordFirstAudio() { firstAudioCount += 1 }
        func recordFinished() { finishedCount += 1 }
        func recordFallback(_ remaining: String, _ firstAudioFired: Bool) {
            fallbackCount += 1
            lastFallbackRemaining = remaining
            lastFallbackFirstAudioFired = firstAudioFired
        }

        var terminalCount: Int { finishedCount + fallbackCount }
    }

    // MARK: - Helpers

    /// Drain the main actor so the queue's `@MainActor` fetch Tasks (and the
    /// continuations the test just released) run to their next stable point.
    private func drain() async {
        for _ in 0..<25 { await Task.yield() }
    }

    /// Build a queue wired to a fresh recorder. The fetch closure drops the
    /// chunk TEXT on the floor (the controller never touches reply text;
    /// it keys purely off the index).
    private func makeQueue(
        segments: [String],
        fetches: FetchController,
        factory: FakeChunkPlayerFactory
    ) -> (SpeechChunkQueue, TerminalRecorder) {
        let recorder = TerminalRecorder()
        let queue = SpeechChunkQueue(
            segments: segments,
            fetch: { index, _ in try await fetches.fetch(index: index) },
            players: factory,
            onFirstAudio: { recorder.recordFirstAudio() },
            onFinished: { recorder.recordFinished() },
            onFallback: { remaining, fired in recorder.recordFallback(remaining, fired) }
        )
        return (queue, recorder)
    }

    /// The universal terminal contract (case 16, asserted in EVERY scenario):
    /// across a queue's whole life, at most ONE of {onFinished, onFallback}
    /// ever fires, at most once total.
    private func assertTerminalExclusivity(
        _ recorder: TerminalRecorder,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertLessThanOrEqual(recorder.terminalCount, 1,
                                 "At most ONE terminal (onFinished/onFallback) may ever fire, once total.",
                                 file: file, line: line)
        XCTAssertFalse(recorder.finishedCount > 0 && recorder.fallbackCount > 0,
                       "onFinished and onFallback are mutually exclusive.",
                       file: file, line: line)
    }

    // MARK: - 1. Bounded lookahead

    /// Locks the lookahead contract: `start()` launches chunk 0 AND chunk 1
    /// concurrently (chunk 1's immediate launch is what buys the tail its synth
    /// runway) but NOT chunk 2 — and across a whole 5-chunk run the in-flight
    /// high-water mark never exceeds 2 (deeper prefetch only spikes the user's
    /// BYO rate-limit exposure).
    func testStartFetchesHeadPairConcurrentlyAndNeverExceedsLookaheadCap() async throws {
        let segments = ["One. ", "Two. ", "Three. ", "Four. ", "Five."]
        let fetches = FetchController()
        for i in 0..<5 { fetches.modes[i] = .suspend }
        let factory = FakeChunkPlayerFactory()
        let (queue, recorder) = makeQueue(segments: segments, fetches: fetches, factory: factory)

        queue.start()
        await drain()

        // Chunks 0 + 1 in flight together BEFORE anything plays; chunk 2 not launched.
        XCTAssertEqual(Set(fetches.begun), Set([0, 1]),
                       "start() must launch exactly the head pair (chunk 0 and chunk 1).")
        XCTAssertEqual(fetches.highWaterMark, 2,
                       "Chunk 0 and chunk 1 must fetch CONCURRENTLY, not serially.")
        XCTAssertTrue(factory.players.isEmpty, "Nothing may play before a fetch lands.")

        // Run the whole 5-chunk turn: release fetches in order, finish each
        // clip by hand. The cap must hold at every stage.
        fetches.release(0); await drain()               // chunk 0 plays → chunk 2 launches
        fetches.release(1); await drain()
        try XCTUnwrap(factory.player(forChunk: 0)).finish(); await drain()  // chunk 1 plays → chunk 3 launches
        fetches.release(2); await drain()
        try XCTUnwrap(factory.player(forChunk: 1)).finish(); await drain()  // chunk 2 plays → chunk 4 launches
        fetches.release(3); await drain()
        try XCTUnwrap(factory.player(forChunk: 2)).finish(); await drain()
        fetches.release(4); await drain()
        try XCTUnwrap(factory.player(forChunk: 3)).finish(); await drain()
        try XCTUnwrap(factory.player(forChunk: 4)).finish(); await drain()

        XCTAssertEqual(fetches.highWaterMark, 2,
                       "The in-flight high-water mark must NEVER exceed the lookahead cap of 2.")
        XCTAssertEqual(Set(fetches.begun), Set([0, 1, 2, 3, 4]))
        XCTAssertEqual(fetches.begun.count, 5, "Each chunk must be fetched exactly once.")
        XCTAssertEqual(recorder.finishedCount, 1)
        assertTerminalExclusivity(recorder)
    }

    // MARK: - 2. Strict in-order playback

    /// Locks strict ordering: chunk 1's audio landing BEFORE chunk 0's must not
    /// start playback — chunk 0 plays first when it lands, and chunk 1 plays
    /// only after chunk 0's terminal. (The whole point of the queue: seams are
    /// gapless but order is sacred.)
    func testOutOfOrderFetchArrivalStillPlaysStrictlyInOrder() async throws {
        let segments = ["Head. ", "Tail."]
        let fetches = FetchController()
        fetches.modes = [0: .suspend, 1: .suspend]
        let factory = FakeChunkPlayerFactory()
        let (queue, recorder) = makeQueue(segments: segments, fetches: fetches, factory: factory)

        queue.start()
        await drain()

        // Chunk 1 lands FIRST — prepared (preroll) but nothing plays.
        fetches.release(1); await drain()
        let player1 = try XCTUnwrap(factory.player(forChunk: 1))
        XCTAssertEqual(factory.players.count, 1)
        XCTAssertEqual(player1.prepareCount, 1, "A landed chunk prerolls while it waits.")
        XCTAssertEqual(player1.playCount, 0, "Chunk 1 must NOT play before chunk 0.")
        XCTAssertEqual(recorder.firstAudioCount, 0, "No audio started → no onFirstAudio.")

        // Chunk 0 lands — it plays first.
        fetches.release(0); await drain()
        let player0 = try XCTUnwrap(factory.player(forChunk: 0))
        XCTAssertEqual(player0.playCount, 1, "Chunk 0 plays the moment it lands.")
        XCTAssertEqual(player1.playCount, 0, "Chunk 1 still waits for chunk 0's terminal.")

        // Chunk 1 plays only after chunk 0's clip ends.
        player0.finish(); await drain()
        XCTAssertEqual(player1.playCount, 1, "Chunk 1 plays only after chunk 0 finished.")

        player1.finish(); await drain()
        XCTAssertEqual(recorder.finishedCount, 1)
        assertTerminalExclusivity(recorder)
    }

    // MARK: - 3. onFirstAudio exactly once

    /// Locks the one-utterance model: `onFirstAudio` fires exactly once (when
    /// chunk 0's play actually starts) and never again on later chunks — the UI
    /// stays `.playing` across every seam; there is no "chunk 2 of 4" state.
    func testOnFirstAudioFiresExactlyOnceOnHeadChunkOnly() async throws {
        let segments = ["A. ", "B. ", "C."]
        let fetches = FetchController()
        for i in 0..<3 { fetches.modes[i] = .suspend }
        let factory = FakeChunkPlayerFactory()
        let (queue, recorder) = makeQueue(segments: segments, fetches: fetches, factory: factory)

        queue.start(); await drain()

        fetches.release(0); await drain()
        XCTAssertEqual(recorder.firstAudioCount, 1, "onFirstAudio fires when chunk 0 starts.")

        fetches.release(1); await drain()
        try XCTUnwrap(factory.player(forChunk: 0)).finish(); await drain()   // chunk 1 plays
        XCTAssertEqual(recorder.firstAudioCount, 1, "Chunk 1 starting must NOT re-fire onFirstAudio.")

        fetches.release(2); await drain()
        try XCTUnwrap(factory.player(forChunk: 1)).finish(); await drain()   // chunk 2 plays
        XCTAssertEqual(recorder.firstAudioCount, 1, "Chunk 2 starting must NOT re-fire onFirstAudio.")

        try XCTUnwrap(factory.player(forChunk: 2)).finish(); await drain()
        XCTAssertEqual(recorder.firstAudioCount, 1)
        XCTAssertEqual(recorder.finishedCount, 1)
        assertTerminalExclusivity(recorder)
    }

    // MARK: - 4. onFinished exactly once, only at the FINAL chunk

    /// Locks the success terminal: `onFinished` fires exactly once, only after
    /// the LAST chunk's clip ends — never on an intermediate seam — and
    /// `onFallback` never fires on the happy path. Callers wire this into their
    /// exactly-once completion funnels (CarPlay deactivate-once heritage).
    func testOnFinishedFiresExactlyOnceAfterFinalChunkAndFallbackNeverFires() async throws {
        let segments = ["A. ", "B. ", "C."]
        let fetches = FetchController()
        for i in 0..<3 { fetches.modes[i] = .suspend }
        let factory = FakeChunkPlayerFactory()
        let (queue, recorder) = makeQueue(segments: segments, fetches: fetches, factory: factory)

        queue.start(); await drain()
        fetches.release(0); await drain()
        fetches.release(1); await drain()
        try XCTUnwrap(factory.player(forChunk: 0)).finish(); await drain()
        XCTAssertEqual(recorder.finishedCount, 0, "An intermediate seam must NOT fire onFinished.")

        fetches.release(2); await drain()
        try XCTUnwrap(factory.player(forChunk: 1)).finish(); await drain()
        XCTAssertEqual(recorder.finishedCount, 0, "Still not the last chunk — no onFinished.")

        try XCTUnwrap(factory.player(forChunk: 2)).finish(); await drain()
        XCTAssertEqual(recorder.finishedCount, 1, "onFinished fires after the FINAL chunk's terminal.")
        XCTAssertEqual(recorder.fallbackCount, 0, "onFallback never fires on the happy path.")
        assertTerminalExclusivity(recorder)
    }

    // MARK: - 5. cancel() is a hard stop that fires nothing

    /// Locks the cancel contract: `cancel()` while chunk 1's fetch is suspended
    /// kills every fetch and player and fires NO callbacks — and the late fetch
    /// resolving afterwards is structurally inert (no player built, no play, no
    /// terminal). The surface's supersede/cancel machinery owns silence.
    func testCancelWhileFetchSuspendedFiresNothingAndStopsPlayers() async throws {
        let segments = ["Head. ", "Tail."]
        let fetches = FetchController()
        fetches.modes = [0: .suspend, 1: .suspend]
        let factory = FakeChunkPlayerFactory()
        let (queue, recorder) = makeQueue(segments: segments, fetches: fetches, factory: factory)

        queue.start(); await drain()
        fetches.release(0); await drain()   // chunk 0 playing, chunk 1 still fetching
        let player0 = try XCTUnwrap(factory.player(forChunk: 0))
        XCTAssertEqual(player0.playCount, 1)

        queue.cancel()
        XCTAssertEqual(player0.stopCount, 1, "cancel() must hard-stop the playing chunk.")

        // The late fetch resolves AFTER cancel — it must change nothing.
        fetches.release(1); await drain()
        XCTAssertEqual(factory.players.count, 1, "A post-cancel fetch must not build a player.")
        XCTAssertEqual(recorder.finishedCount, 0, "cancel() must never fire onFinished.")
        XCTAssertEqual(recorder.fallbackCount, 0, "cancel() must never fire onFallback.")
        XCTAssertEqual(queue.playbackStatus, .inactive, "A cancelled queue reports .inactive.")

        // A stray clip terminal after stop is inert (the stop cleared it).
        player0.finish(); await drain()
        XCTAssertEqual(recorder.terminalCount, 0)
        assertTerminalExclusivity(recorder)
    }

    // MARK: - 6. Fallback mid-turn never interrupts playing audio

    /// Locks the failure model: chunk 1's fetch failing while chunk 0 plays
    /// must NOT interrupt chunk 0 — the Apple handoff happens exactly when
    /// playback reaches the failed index, with `segments[1...].joined()` and
    /// `firstAudioFired == true` (the caller must not re-emit the start
    /// signal). `onFinished` never fires on a fallback turn.
    func testMidTurnFetchFailureLetsCurrentChunkFinishThenFallsBack() async throws {
        let segments = ["A. ", "B. ", "C."]
        let fetches = FetchController()
        for i in 0..<3 { fetches.modes[i] = .suspend }
        let factory = FakeChunkPlayerFactory()
        let (queue, recorder) = makeQueue(segments: segments, fetches: fetches, factory: factory)

        queue.start(); await drain()
        fetches.release(0); await drain()   // chunk 0 playing; chunk 2's fetch launched
        let player0 = try XCTUnwrap(factory.player(forChunk: 0))

        fetches.release(1, as: .failure); await drain()
        XCTAssertEqual(player0.stopCount, 0, "A failed later chunk must NOT interrupt playing audio.")
        XCTAssertEqual(recorder.fallbackCount, 0, "Fallback waits until playback reaches the failed index.")

        player0.finish(); await drain()
        XCTAssertEqual(recorder.fallbackCount, 1, "Fallback fires exactly when playback hits the failure.")
        XCTAssertEqual(recorder.lastFallbackRemaining, segments[1...].joined(),
                       "The remainder is segments[1...].joined() — loss-free, no double-speak.")
        XCTAssertEqual(recorder.lastFallbackFirstAudioFired, true,
                       "Audio already started → firstAudioFired must be true.")
        XCTAssertEqual(recorder.finishedCount, 0, "A fallback turn never fires onFinished.")
        XCTAssertEqual(factory.players.count, 1, "No player may be built for the failed/abandoned tail.")

        // Hygiene: chunk 2's abandoned fetch resolves late — must stay inert.
        fetches.releaseAllRemaining(); await drain()
        XCTAssertEqual(recorder.terminalCount, 1)
        assertTerminalExclusivity(recorder)
    }

    // MARK: - 7. Head-chunk fetch failure → full-text fallback

    /// Locks the head-failure arm: chunk 0's fetch throwing means NOTHING
    /// played — `onFallback` carries the FULL joined text with
    /// `firstAudioFired == false` (the caller re-speaks everything via Apple
    /// and still emits the start signal itself).
    func testHeadChunkFetchFailureFallsBackWithFullText() async {
        let segments = ["Head. ", "Tail."]
        let fetches = FetchController()
        fetches.modes = [0: .fail, 1: .suspend]
        let factory = FakeChunkPlayerFactory()
        let (queue, recorder) = makeQueue(segments: segments, fetches: fetches, factory: factory)

        queue.start(); await drain()

        XCTAssertEqual(recorder.fallbackCount, 1)
        XCTAssertEqual(recorder.lastFallbackRemaining, segments.joined(),
                       "Head failure → the WHOLE reply goes to Apple.")
        XCTAssertEqual(recorder.lastFallbackFirstAudioFired, false,
                       "Nothing played → firstAudioFired must be false.")
        XCTAssertEqual(recorder.firstAudioCount, 0)
        XCTAssertEqual(recorder.finishedCount, 0)
        XCTAssertTrue(factory.players.isEmpty)

        fetches.releaseAllRemaining(); await drain()   // abandoned chunk 1 stays inert
        XCTAssertEqual(recorder.terminalCount, 1)
        assertTerminalExclusivity(recorder)
    }

    // MARK: - 8. makePlayer throw on the head chunk = same as a fetch throw

    /// Locks the undecodable-audio arm: `makePlayer` throwing for chunk 0 is a
    /// chunk failure exactly like a fetch throw — full-text fallback,
    /// `firstAudioFired == false` (a spoken reply must never go silent).
    func testMakePlayerThrowOnHeadChunkFallsBackWithFullText() async {
        let segments = ["Head. ", "Tail."]
        let fetches = FetchController()
        fetches.modes = [0: .succeed, 1: .suspend]
        let factory = FakeChunkPlayerFactory()
        factory.throwOnCallIndices = [0]
        let (queue, recorder) = makeQueue(segments: segments, fetches: fetches, factory: factory)

        queue.start(); await drain()

        XCTAssertEqual(factory.makeCalls, 1, "Chunk 0's data reached the factory.")
        XCTAssertTrue(factory.players.isEmpty, "The throwing call vends no player.")
        XCTAssertEqual(recorder.fallbackCount, 1)
        XCTAssertEqual(recorder.lastFallbackRemaining, segments.joined())
        XCTAssertEqual(recorder.lastFallbackFirstAudioFired, false)
        XCTAssertEqual(recorder.firstAudioCount, 0)
        XCTAssertEqual(recorder.finishedCount, 0)

        fetches.releaseAllRemaining(); await drain()
        XCTAssertEqual(recorder.terminalCount, 1)
        assertTerminalExclusivity(recorder)
    }

    // MARK: - 9. play() == false on the head chunk

    /// Locks the "session not ready" arm at the head: `play()` returning false
    /// for chunk 0 means unplayable here = unplayable for every later chunk —
    /// full-text fallback with `firstAudioFired == false` (mirrors the
    /// single-blob "play() == false" fallback).
    func testPlayFalseOnHeadChunkFallsBackWithFullText() async throws {
        let segments = ["Head. ", "Tail."]
        let fetches = FetchController()
        fetches.modes = [0: .succeed, 1: .suspend]
        let factory = FakeChunkPlayerFactory()
        factory.playReturnsFalseOnCallIndices = [0]
        let (queue, recorder) = makeQueue(segments: segments, fetches: fetches, factory: factory)

        queue.start(); await drain()

        let player0 = try XCTUnwrap(factory.player(forChunk: 0))
        XCTAssertEqual(player0.playCount, 1, "The queue attempted to start chunk 0.")
        XCTAssertEqual(recorder.fallbackCount, 1)
        XCTAssertEqual(recorder.lastFallbackRemaining, segments.joined())
        XCTAssertEqual(recorder.lastFallbackFirstAudioFired, false,
                       "A refused play() means audio never started.")
        XCTAssertEqual(recorder.firstAudioCount, 0,
                       "onFirstAudio must not fire when play() refused to start.")
        XCTAssertEqual(recorder.finishedCount, 0)

        fetches.releaseAllRemaining(); await drain()
        XCTAssertEqual(recorder.terminalCount, 1)
        assertTerminalExclusivity(recorder)
    }

    // MARK: - 10. play() == false on a MIDDLE chunk

    /// Locks the mid-turn "session died" arm: chunks 0–1 played fine, chunk 2's
    /// `play()` returns false → fallback carries only the UNPLAYED remainder
    /// (`segments[2...].joined()`) with `firstAudioFired == true`, and any
    /// already-fetched later chunk is released (stopped), never played.
    func testPlayFalseOnMiddleChunkFallsBackWithUnplayedRemainder() async throws {
        let segments = ["A. ", "B. ", "C. ", "D."]
        let fetches = FetchController()
        for i in 0..<4 { fetches.modes[i] = .suspend }
        let factory = FakeChunkPlayerFactory()
        factory.playReturnsFalseOnCallIndices = [2]   // creation order == chunk order below
        let (queue, recorder) = makeQueue(segments: segments, fetches: fetches, factory: factory)

        queue.start(); await drain()
        fetches.release(0); await drain()   // chunk 0 plays → chunk 2 launches
        fetches.release(1); await drain()
        try XCTUnwrap(factory.player(forChunk: 0)).finish(); await drain()   // chunk 1 plays → chunk 3 launches
        fetches.release(2); await drain()
        fetches.release(3); await drain()
        try XCTUnwrap(factory.player(forChunk: 1)).finish(); await drain()   // chunk 2 attempts play → false

        let player2 = try XCTUnwrap(factory.player(forChunk: 2))
        let player3 = try XCTUnwrap(factory.player(forChunk: 3))
        XCTAssertEqual(player2.playCount, 1, "Chunk 2's start was attempted.")
        XCTAssertEqual(recorder.fallbackCount, 1)
        XCTAssertEqual(recorder.lastFallbackRemaining, segments[2...].joined(),
                       "Only the UNPLAYED remainder goes to Apple — played chunks are never re-spoken.")
        XCTAssertEqual(recorder.lastFallbackFirstAudioFired, true)
        XCTAssertEqual(player3.playCount, 0, "A fetched-ahead later chunk must never play after the fallback.")
        XCTAssertEqual(player3.stopCount, 1, "The abandoned ready chunk is released at the terminal.")
        XCTAssertEqual(recorder.finishedCount, 0)
        assertTerminalExclusivity(recorder)
    }

    // MARK: - 11. pause()/resume() mid-chunk

    /// Locks the mid-chunk pause contract: `pause()` pauses the playing player
    /// in place (position preserved, no re-synthesis) and `resume()` resumes
    /// that same player — a chunk landing ready meanwhile must not advance the
    /// queue, and the next chunk plays only after the current one's terminal.
    func testPauseMidChunkPausesPlayerAndResumeResumesWithoutAdvance() async throws {
        let segments = ["Head. ", "Tail."]
        let fetches = FetchController()
        fetches.modes = [0: .suspend, 1: .suspend]
        let factory = FakeChunkPlayerFactory()
        let (queue, recorder) = makeQueue(segments: segments, fetches: fetches, factory: factory)

        queue.start(); await drain()
        fetches.release(0); await drain()   // chunk 0 playing
        let player0 = try XCTUnwrap(factory.player(forChunk: 0))

        queue.pause()
        XCTAssertEqual(player0.pauseCount, 1, "Mid-chunk pause must pause the player in place.")

        fetches.release(1); await drain()   // chunk 1 lands under the pause
        let player1 = try XCTUnwrap(factory.player(forChunk: 1))
        XCTAssertEqual(player1.playCount, 0, "No queue advance while paused.")

        queue.resume()
        XCTAssertEqual(player0.resumeCount, 1, "Resume continues the SAME player from position.")
        XCTAssertEqual(player1.playCount, 0, "Resume must not skip ahead past the paused chunk.")

        player0.finish(); await drain()
        XCTAssertEqual(player1.playCount, 1)
        player1.finish(); await drain()
        XCTAssertEqual(recorder.finishedCount, 1)
        assertTerminalExclusivity(recorder)
    }

    // MARK: - 12. Pause BETWEEN chunks parks the queue

    /// Locks the between-chunks pause contract: pausing while the next chunk is
    /// still fetching parks the queue — the landing fetch must NOT auto-start
    /// audio under the pause; `resume()` starts the parked chunk.
    func testPauseBetweenChunksParksLandingChunkUntilResume() async throws {
        let segments = ["Head. ", "Tail."]
        let fetches = FetchController()
        fetches.modes = [0: .suspend, 1: .suspend]
        let factory = FakeChunkPlayerFactory()
        let (queue, recorder) = makeQueue(segments: segments, fetches: fetches, factory: factory)

        queue.start(); await drain()
        fetches.release(0); await drain()
        try XCTUnwrap(factory.player(forChunk: 0)).finish(); await drain()   // between chunks now

        queue.pause()                        // park while chunk 1 is still fetching
        fetches.release(1); await drain()    // chunk 1 lands under the pause
        let player1 = try XCTUnwrap(factory.player(forChunk: 1))
        XCTAssertEqual(player1.prepareCount, 1, "The parked chunk still prerolls on landing.")
        XCTAssertEqual(player1.playCount, 0,
                       "A fetch landing under a user pause must NOT auto-start audio.")

        queue.resume()
        XCTAssertEqual(player1.playCount, 1, "resume() starts the parked ready chunk.")

        player1.finish(); await drain()
        XCTAssertEqual(recorder.finishedCount, 1)
        assertTerminalExclusivity(recorder)
    }

    // MARK: - 13. Fallback is DEFERRED under a user pause

    /// Locks the pause/fallback interaction: with the queue parked between
    /// chunks, the awaited chunk's fetch failing must NOT fire `onFallback`
    /// while paused — audio (the caller's Apple leg) must never start under a
    /// user pause. `resume()` then fires the deferred fallback.
    func testFetchFailureWhilePausedDefersFallbackUntilResume() async throws {
        let segments = ["Head. ", "Tail."]
        let fetches = FetchController()
        fetches.modes = [0: .suspend, 1: .suspend]
        let factory = FakeChunkPlayerFactory()
        let (queue, recorder) = makeQueue(segments: segments, fetches: fetches, factory: factory)

        queue.start(); await drain()
        fetches.release(0); await drain()
        try XCTUnwrap(factory.player(forChunk: 0)).finish(); await drain()   // awaiting chunk 1

        queue.pause()
        fetches.release(1, as: .failure); await drain()
        XCTAssertEqual(recorder.fallbackCount, 0,
                       "A fetch failure under a user pause must DEFER the fallback (no audio under a pause).")

        queue.resume(); await drain()
        XCTAssertEqual(recorder.fallbackCount, 1, "resume() releases the deferred fallback.")
        XCTAssertEqual(recorder.lastFallbackRemaining, segments[1...].joined())
        XCTAssertEqual(recorder.lastFallbackFirstAudioFired, true)
        XCTAssertEqual(recorder.finishedCount, 0)
        assertTerminalExclusivity(recorder)
    }

    // MARK: - 14. A later-index failure never poisons earlier in-flight chunks

    /// Locks the failure boundary: chunk 2 failing while chunk 1's fetch is
    /// STILL in flight must not abandon chunk 1 — it lands, plays after chunk 0,
    /// and only when playback reaches index 2 does the fallback fire with
    /// `segments[2...].joined()`. The switch to Apple happens exactly at the
    /// first unplayable chunk, and no fetch launches past the failed index.
    func testLaterIndexFailureStillPlaysEarlierInFlightChunkThenFallsBack() async throws {
        let segments = ["A. ", "B. ", "C. ", "D."]
        let fetches = FetchController()
        for i in 0..<4 { fetches.modes[i] = .suspend }
        let factory = FakeChunkPlayerFactory()
        let (queue, recorder) = makeQueue(segments: segments, fetches: fetches, factory: factory)

        queue.start(); await drain()
        fetches.release(0); await drain()          // chunk 0 plays → chunk 2's fetch launches
        fetches.release(2, as: .failure); await drain()   // chunk 2 fails while chunk 1 in flight
        XCTAssertEqual(recorder.fallbackCount, 0, "Playback hasn't reached the failure yet.")

        fetches.release(1); await drain()          // chunk 1 lands AFTER the later failure
        try XCTUnwrap(factory.player(forChunk: 0)).finish(); await drain()

        let player1 = try XCTUnwrap(factory.player(forChunk: 1))
        XCTAssertEqual(player1.playCount, 1,
                       "A chunk BEFORE the failed index still plays — the failure only poisons k and beyond.")
        XCTAssertEqual(recorder.fallbackCount, 0)

        player1.finish(); await drain()
        XCTAssertEqual(recorder.fallbackCount, 1)
        XCTAssertEqual(recorder.lastFallbackRemaining, segments[2...].joined())
        XCTAssertEqual(recorder.lastFallbackFirstAudioFired, true)
        XCTAssertEqual(recorder.finishedCount, 0)
        XCTAssertEqual(Set(fetches.begun), Set([0, 1, 2]),
                       "No fetch may launch past a failed index (chunk 3 falls back anyway).")
        assertTerminalExclusivity(recorder)
    }

    // MARK: - 15. playbackStatus across the pipeline's phases

    /// Locks the Watch dim-cut reconcile input: `.active` while fetching with
    /// nothing played yet (the queue is alive, audio imminent — reconcile must
    /// not kill it); the live player's own truth mid-chunk; `.inactive` after
    /// the success terminal and after `cancel()`.
    func testPlaybackStatusReflectsPipelinePhases() async throws {
        let segments = ["Head. ", "Tail."]
        let fetches = FetchController()
        fetches.modes = [0: .suspend, 1: .suspend]
        let factory = FakeChunkPlayerFactory()
        let (queue, recorder) = makeQueue(segments: segments, fetches: fetches, factory: factory)

        queue.start(); await drain()
        XCTAssertEqual(queue.playbackStatus, .active,
                       "While fetching (nothing played yet) the queue reports .active.")

        fetches.release(0); await drain()
        let player0 = try XCTUnwrap(factory.player(forChunk: 0))
        XCTAssertEqual(queue.playbackStatus, .active, "Mid-chunk it mirrors the playing player (.active).")
        player0.status = .pausedResumable
        XCTAssertEqual(queue.playbackStatus, .pausedResumable,
                       "Mid-chunk it mirrors the playing player's real state (OS pause).")
        player0.status = .active

        fetches.release(1); await drain()
        player0.finish(); await drain()
        try XCTUnwrap(factory.player(forChunk: 1)).finish(); await drain()
        XCTAssertEqual(recorder.finishedCount, 1)
        XCTAssertEqual(queue.playbackStatus, .inactive, "After the terminal the queue is .inactive.")

        // A second, cancelled queue also reports .inactive.
        let fetches2 = FetchController()
        fetches2.modes = [0: .suspend, 1: .suspend]
        let factory2 = FakeChunkPlayerFactory()
        let (queue2, recorder2) = makeQueue(segments: segments, fetches: fetches2, factory: factory2)
        queue2.start(); await drain()
        queue2.cancel()
        XCTAssertEqual(queue2.playbackStatus, .inactive, "After cancel() the queue is .inactive.")
        fetches2.releaseAllRemaining(); await drain()
        XCTAssertEqual(recorder2.terminalCount, 0)
        assertTerminalExclusivity(recorder)
        assertTerminalExclusivity(recorder2)
    }

    // MARK: - 16. Terminal exclusivity survives post-terminal noise

    /// Locks the `terminated` latch: after a fallback terminal, every further
    /// prod — resume, a late abandoned fetch resolving, a stray clip terminal,
    /// even a subsequent cancel() — must produce NO additional terminal. At
    /// most ONE of {onFinished, onFallback} ever fires, once total. (Every
    /// other test also asserts this via `assertTerminalExclusivity`.)
    func testTerminalExclusivityUnderPostFallbackNoise() async throws {
        let segments = ["A. ", "B. ", "C."]
        let fetches = FetchController()
        for i in 0..<3 { fetches.modes[i] = .suspend }
        let factory = FakeChunkPlayerFactory()
        let (queue, recorder) = makeQueue(segments: segments, fetches: fetches, factory: factory)

        queue.start(); await drain()
        fetches.release(0); await drain()                 // chunk 0 plays; chunk 2 launches
        fetches.release(1, as: .failure); await drain()   // mid-turn failure
        let player0 = try XCTUnwrap(factory.player(forChunk: 0))
        player0.finish(); await drain()                   // → the ONE terminal (fallback)
        XCTAssertEqual(recorder.fallbackCount, 1)

        // Post-terminal noise, in every flavor:
        queue.resume(); await drain()
        queue.pause()
        queue.resume(); await drain()
        fetches.releaseAllRemaining(); await drain()      // abandoned chunk 2 resolves late
        player0.finish(); await drain()                   // stray duplicate clip terminal
        queue.cancel()

        XCTAssertEqual(recorder.terminalCount, 1,
                       "Exactly one terminal total, no matter what happens afterwards.")
        XCTAssertEqual(recorder.fallbackCount, 1)
        XCTAssertEqual(recorder.finishedCount, 0)
        XCTAssertEqual(recorder.firstAudioCount, 1)
        XCTAssertEqual(queue.playbackStatus, .inactive)
        assertTerminalExclusivity(recorder)
    }

    // MARK: - 17. A chunk dying mid-clip (success=false) → fallback FROM that chunk

    /// A clip that ends with `success == false` (a mid-clip decode death /
    /// `didFinish(successfully: false)`) at chunk k is a chunk FAILURE, not a
    /// completion: `onFallback` carries `segments[k...].joined()` — INCLUDING
    /// chunk k (audio-time → text mapping is unreliable, so content preservation
    /// wins over de-dup) — with `firstAudioFired == true`, and `onFinished`
    /// never fires. The success path is exercised by every other test.
    func testChunkDyingMidClipFallsBackFromThatChunkInclusive() async throws {
        let segments = ["A. ", "B. ", "C."]
        let fetches = FetchController()
        for i in 0..<3 { fetches.modes[i] = .suspend }
        let factory = FakeChunkPlayerFactory()
        let (queue, recorder) = makeQueue(segments: segments, fetches: fetches, factory: factory)

        queue.start(); await drain()
        fetches.release(0); await drain()          // chunk 0 plays; chunk 2 launches
        fetches.release(1); await drain()
        try XCTUnwrap(factory.player(forChunk: 0)).finish(); await drain()   // chunk 1 plays
        let player1 = try XCTUnwrap(factory.player(forChunk: 1))
        XCTAssertEqual(player1.playCount, 1, "Chunk 1 is playing.")

        // Chunk 1 dies mid-clip.
        player1.finish(success: false); await drain()

        XCTAssertEqual(recorder.fallbackCount, 1, "A mid-clip death fires the fallback terminal.")
        XCTAssertEqual(recorder.lastFallbackRemaining, segments[1...].joined(),
                       "Apple speaks segments[k...] INCLUDING the chunk that died — no silent tail.")
        XCTAssertEqual(recorder.lastFallbackFirstAudioFired, true, "Audio already started.")
        XCTAssertEqual(recorder.finishedCount, 0, "A mid-clip death never fires onFinished.")

        fetches.releaseAllRemaining(); await drain()
        XCTAssertEqual(recorder.terminalCount, 1)
        assertTerminalExclusivity(recorder)
    }
}
#endif
